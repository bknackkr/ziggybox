//! POSIX.1-2024 (IEEE Std 1003.1-2024) compliant implementation of `sed`.
//!
//! Specification References:
//! - IEEE Std 1003.1-2024, Shell & Utilities (XCU), Section: `sed`
//!   - SYNOPSIS:
//!       sed [-En] script [file...]
//!       sed [-En] -e script [-e script]... [-f script_file]... [file...]
//!   - OPTIONS:
//!       -E: Use Extended Regular Expressions (ERE) instead of BRE.
//!       -n: Suppress default output of pattern space.
//!       -e script: Append script commands.
//!       -f script_file: Read script commands from file.
//!   - EDITING COMMANDS:
//!       { }, a, b, c, d, D, g, G, h, H, i, l, n, N, p, P, q, r, s, t, w, x, y, :, =, #
//!   - EXIT STATUS:
//!       0: Successful completion.
//!       >0: An error occurred.

const std = @import("std");
const common_args = @import("../common/args.zig");
const common_error = @import("../common/error.zig");
const common_regex = @import("../common/regex.zig");

pub const BUFFER_SIZE: usize = 16 * 1024;

pub const AddressType = enum {
    line_num,
    last_line,
    regex,
};

pub const Address = struct {
    addr_type: AddressType,
    line_num: usize = 0,
    pattern: []const u8 = "",
    compiled_re: ?common_regex.Regex = null,
};

pub const Verb = enum {
    block_start,
    block_end,
    append,
    branch,
    change,
    delete,
    delete_first_line,
    get_hold,
    append_hold,
    hold,
    append_pattern,
    insert,
    list,
    next,
    append_next,
    print,
    print_first_line,
    quit,
    read_file,
    substitute,
    test_branch,
    write_file,
    exchange,
    transliterate,
    label,
    line_number,
};

pub const SubFlags = struct {
    global: bool = false,
    print: bool = false,
    case_insensitive: bool = false,
    nth: usize = 0, // 0 means first (or all if global)
    write_file: ?[]const u8 = null,
};

pub const Command = struct {
    addr1: ?Address = null,
    addr2: ?Address = null,
    invert: bool = false,
    in_range: bool = false,
    verb: Verb,

    // Command arguments
    text: []const u8 = "",
    label_name: []const u8 = "",
    target_pc: ?usize = null, // for branching and blocks
    file_path: []const u8 = "",

    // Substitute data
    sub_re: ?common_regex.Regex = null,
    sub_repl: []const u8 = "",
    sub_flags: SubFlags = .{},

    // Transliterate data
    trans_from: []const u8 = "",
    trans_to: []const u8 = "",
};

pub fn run(allocator: std.mem.Allocator, args: []const [:0]const u8) u8 {
    const io = std.Io.Threaded.global_single_threaded.io();

    var is_ere = false;
    var suppress_default = false;

    var script_parts: std.ArrayList([]const u8) = .empty;
    defer script_parts.deinit(allocator);

    var file_scripts: std.ArrayList([]u8) = .empty;
    defer {
        for (file_scripts.items) |fs| allocator.free(fs);
        file_scripts.deinit(allocator);
    }

    var parser = common_args.ArgParser.init(args);
    while (parser.next("Ene:f:")) |opt| {
        switch (opt) {
            'E' => is_ere = true,
            'n' => suppress_default = true,
            'e' => {
                const s = parser.optarg orelse {
                    common_error.report("sed", "option requires an argument: -e", error.InvalidArgument);
                    return common_error.EXIT_SYNTAX;
                };
                script_parts.append(allocator, s) catch {
                    common_error.report("sed", null, error.OutOfMemory);
                    return common_error.EXIT_FAILURE;
                };
            },
            'f' => {
                const fpath = parser.optarg orelse {
                    common_error.report("sed", "option requires an argument: -f", error.InvalidArgument);
                    return common_error.EXIT_SYNTAX;
                };
                const content = std.Io.Dir.cwd().readFileAlloc(io, fpath, allocator, .unlimited) catch |err| {
                    common_error.report("sed", fpath, err);
                    return common_error.EXIT_SYNTAX;
                };
                file_scripts.append(allocator, content) catch {
                    common_error.report("sed", null, error.OutOfMemory);
                    return common_error.EXIT_FAILURE;
                };
                script_parts.append(allocator, content) catch {
                    common_error.report("sed", null, error.OutOfMemory);
                    return common_error.EXIT_FAILURE;
                };
            },
            else => {
                common_error.report("sed", "invalid option", error.InvalidArgument);
                return common_error.EXIT_SYNTAX;
            },
        }
    }

    const operands = parser.remaining();
    var file_operands: []const [:0]const u8 = &.{};

    if (script_parts.items.len == 0) {
        if (operands.len == 0) {
            common_error.report("sed", "missing script operand", error.InvalidArgument);
            return common_error.EXIT_SYNTAX;
        }
        script_parts.append(allocator, operands[0]) catch {
            common_error.report("sed", null, error.OutOfMemory);
            return common_error.EXIT_FAILURE;
        };
        file_operands = operands[1..];
    } else {
        file_operands = operands;
    }

    // Join all script parts with newlines
    var combined_script: std.ArrayList(u8) = .empty;
    defer combined_script.deinit(allocator);

    for (script_parts.items, 0..) |part, idx| {
        if (idx > 0) combined_script.append(allocator, '\n') catch {};
        combined_script.appendSlice(allocator, part) catch {};
    }

    const script_str = combined_script.items;
    // Check for #n at beginning of script
    if (script_str.len >= 2 and script_str[0] == '#' and script_str[1] == 'n') {
        suppress_default = true;
    }

    // Parse script into commands
    var commands_list = parseScript(allocator, script_str, is_ere) catch |err| {
        common_error.report("sed", "script syntax error", err);
        return common_error.EXIT_SYNTAX;
    };
    defer {
        for (commands_list.items) |*cmd| {
            if (cmd.addr1) |*a| {
                if (a.compiled_re) |*r| r.deinit(allocator);
            }
            if (cmd.addr2) |*a| {
                if (a.compiled_re) |*r| r.deinit(allocator);
            }
            if (cmd.sub_re) |*r| r.deinit(allocator);
        }
        commands_list.deinit(allocator);
    }

    // Resolve labels and branch targets
    resolveBranches(commands_list.items) catch |err| {
        common_error.report("sed", "undefined label or branch error", err);
        return common_error.EXIT_SYNTAX;
    };

    // Pre-create any write_files referenced by 'w' or 's///w'
    for (commands_list.items) |cmd| {
        if (cmd.file_path.len > 0 and (cmd.verb == .write_file or cmd.sub_flags.write_file != null)) {
            const path = if (cmd.file_path.len > 0) cmd.file_path else cmd.sub_flags.write_file.?;
            const f = std.Io.Dir.cwd().createFile(io, path, .{}) catch |err| {
                common_error.report("sed", path, err);
                return common_error.EXIT_FAILURE;
            };
            f.close(io);
        }
    }

    // Read all input lines into memory to know total line count and last line index
    var line_arena = std.heap.ArenaAllocator.init(allocator);
    defer line_arena.deinit();
    const l_alloc = line_arena.allocator();

    var input_lines: std.ArrayList([]const u8) = .empty;

    const default_operands = [_][:0]const u8{"-"};
    const files_to_read: []const [:0]const u8 = if (file_operands.len == 0) &default_operands else file_operands;

    for (files_to_read) |path| {
        const is_stdin = std.mem.eql(u8, path, "-");
        const f = if (is_stdin)
            std.Io.File.stdin()
        else
            std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch |err| {
                common_error.report("sed", path, err);
                return common_error.EXIT_FAILURE;
            };
        defer if (!is_stdin) f.close(io);

        var r_buf: [BUFFER_SIZE]u8 = undefined;
        var r = f.readerStreaming(io, &r_buf);

        while (true) {
            const maybe_line = r.interface.takeDelimiter('\n') catch |err| {
                common_error.report("sed", path, err);
                return common_error.EXIT_FAILURE;
            };
            const raw_l = maybe_line orelse break;
            const l = if (raw_l.len > 0 and raw_l[raw_l.len - 1] == '\r')
                raw_l[0 .. raw_l.len - 1]
            else
                raw_l;

            const l_copy = l_alloc.dupe(u8, l) catch {
                common_error.report("sed", null, error.OutOfMemory);
                return common_error.EXIT_FAILURE;
            };
            input_lines.append(l_alloc, l_copy) catch {
                common_error.report("sed", null, error.OutOfMemory);
                return common_error.EXIT_FAILURE;
            };
        }
    }

    const total_lines = input_lines.items.len;

    // Pattern and hold spaces
    var pattern_space: std.ArrayList(u8) = .empty;
    defer pattern_space.deinit(allocator);

    var hold_space: std.ArrayList(u8) = .empty;
    defer hold_space.deinit(allocator);

    var append_queue: std.ArrayList([]const u8) = .empty;
    defer append_queue.deinit(allocator);

    var read_queue: std.ArrayList([]const u8) = .empty;
    defer read_queue.deinit(allocator);

    const stdout_file = std.Io.File.stdout();
    var stdout_buf: [BUFFER_SIZE]u8 = undefined;
    var stdout_fw = stdout_file.writerStreaming(io, &stdout_buf);
    const writer = &stdout_fw.interface;
    defer stdout_fw.flush() catch {};

    const flushQueues = struct {
        fn run_flush(io_ctx: std.Io, w: anytype, appends: *std.ArrayList([]const u8), reads: *std.ArrayList([]const u8)) void {
            for (appends.items) |txt| {
                _ = w.writeAll(txt) catch {};
                _ = w.writeByte('\n') catch {};
            }
            appends.clearRetainingCapacity();

            for (reads.items) |rpath| {
                const rf = std.Io.Dir.cwd().openFile(io_ctx, rpath, .{ .mode = .read_only }) catch continue;
                defer rf.close(io_ctx);
                var fbuf: [BUFFER_SIZE]u8 = undefined;
                while (true) {
                    const n = rf.readStreaming(io_ctx, &.{&fbuf}) catch break;
                    if (n == 0) break;
                    _ = w.writeAll(fbuf[0..n]) catch {};
                }
            }
            reads.clearRetainingCapacity();
        }
    }.run_flush;

    var input_idx: usize = 0;
    while (input_idx < total_lines) {
        pattern_space.clearRetainingCapacity();
        pattern_space.appendSlice(allocator, input_lines.items[input_idx]) catch {};

        var subst_success = false;
        var pc: usize = 0;
        var restart_cycle = false;
        var cycle_line_consumed = true;

        while (pc < commands_list.items.len) {
            const cmd = &commands_list.items[pc];
            const current_lineno = input_idx + 1;
            const is_last_line = (current_lineno == total_lines);

            const selected = evalAddress(cmd, current_lineno, is_last_line, pattern_space.items);
            if (!selected) {
                if (cmd.verb == .block_start) {
                    pc = cmd.target_pc orelse (pc + 1);
                } else {
                    pc += 1;
                }
                continue;
            }

            switch (cmd.verb) {
                .block_start => pc += 1,
                .block_end => pc += 1,
                .label => pc += 1,
                .branch => {
                    if (cmd.target_pc) |tpc| {
                        pc = tpc;
                    } else {
                        // Branch to end of script
                        break;
                    }
                },
                .test_branch => {
                    if (subst_success) {
                        subst_success = false;
                        if (cmd.target_pc) |tpc| {
                            pc = tpc;
                        } else {
                            break;
                        }
                    } else {
                        pc += 1;
                    }
                },
                .print => {
                    _ = writer.writeAll(pattern_space.items) catch {};
                    _ = writer.writeByte('\n') catch {};
                    pc += 1;
                },
                .print_first_line => {
                    const newline_pos = std.mem.indexOfScalar(u8, pattern_space.items, '\n');
                    const slice = if (newline_pos) |np| pattern_space.items[0..np] else pattern_space.items;
                    _ = writer.writeAll(slice) catch {};
                    _ = writer.writeByte('\n') catch {};
                    pc += 1;
                },
                .line_number => {
                    _ = writer.print("{d}\n", .{current_lineno}) catch {};
                    pc += 1;
                },
                .delete => {
                    pattern_space.clearRetainingCapacity();
                    restart_cycle = true;
                    break;
                },
                .delete_first_line => {
                    if (std.mem.indexOfScalar(u8, pattern_space.items, '\n')) |np| {
                        const remaining_len = pattern_space.items.len - (np + 1);
                        std.mem.copyForwards(u8, pattern_space.items[0..remaining_len], pattern_space.items[np + 1 ..]);
                        pattern_space.items.len = remaining_len;
                        pc = 0;
                        cycle_line_consumed = false;
                        continue;
                    } else {
                        pattern_space.clearRetainingCapacity();
                        restart_cycle = true;
                        break;
                    }
                },
                .append => {
                    append_queue.append(allocator, cmd.text) catch {};
                    pc += 1;
                },
                .insert => {
                    _ = writer.writeAll(cmd.text) catch {};
                    _ = writer.writeByte('\n') catch {};
                    pc += 1;
                },
                .change => {
                    pattern_space.clearRetainingCapacity();
                    // Output text on 0/1 addr or at end of 2-addr range
                    if (cmd.addr2 == null or !cmd.in_range) {
                        _ = writer.writeAll(cmd.text) catch {};
                        _ = writer.writeByte('\n') catch {};
                    }
                    restart_cycle = true;
                    break;
                },
                .hold => {
                    hold_space.clearRetainingCapacity();
                    hold_space.appendSlice(allocator, pattern_space.items) catch {};
                    pc += 1;
                },
                .append_hold => {
                    if (hold_space.items.len > 0) hold_space.append(allocator, '\n') catch {};
                    hold_space.appendSlice(allocator, pattern_space.items) catch {};
                    pc += 1;
                },
                .get_hold => {
                    pattern_space.clearRetainingCapacity();
                    pattern_space.appendSlice(allocator, hold_space.items) catch {};
                    pc += 1;
                },
                .append_pattern => {
                    pattern_space.append(allocator, '\n') catch {};
                    pattern_space.appendSlice(allocator, hold_space.items) catch {};
                    pc += 1;
                },
                .exchange => {
                    const temp = pattern_space;
                    pattern_space = hold_space;
                    hold_space = temp;
                    pc += 1;
                },
                .read_file => {
                    read_queue.append(allocator, cmd.file_path) catch {};
                    pc += 1;
                },
                .write_file => {
                    appendToFile(io, cmd.file_path, pattern_space.items);
                    pc += 1;
                },
                .next => {
                    if (!suppress_default) {
                        _ = writer.writeAll(pattern_space.items) catch {};
                        _ = writer.writeByte('\n') catch {};
                    }
                    flushQueues(io, writer, &append_queue, &read_queue);
                    input_idx += 1;
                    if (input_idx >= total_lines) return common_error.EXIT_SUCCESS;
                    pattern_space.clearRetainingCapacity();
                    pattern_space.appendSlice(allocator, input_lines.items[input_idx]) catch {};
                    pc += 1;
                },
                .append_next => {
                    input_idx += 1;
                    if (input_idx >= total_lines) return common_error.EXIT_SUCCESS;
                    pattern_space.append(allocator, '\n') catch {};
                    pattern_space.appendSlice(allocator, input_lines.items[input_idx]) catch {};
                    pc += 1;
                },
                .quit => {
                    if (!suppress_default) {
                        _ = writer.writeAll(pattern_space.items) catch {};
                        _ = writer.writeByte('\n') catch {};
                    }
                    flushQueues(io, writer, &append_queue, &read_queue);
                    return common_error.EXIT_SUCCESS;
                },
                .list => {
                    printVisuallyUnambiguous(writer, pattern_space.items);
                    pc += 1;
                },
                .transliterate => {
                    transliterateString(pattern_space.items, cmd.trans_from, cmd.trans_to);
                    pc += 1;
                },
                .substitute => {
                    const changed = applySubstitute(allocator, &pattern_space, cmd, io);
                    if (changed) subst_success = true;
                    pc += 1;
                },
            }
        }

        if (!restart_cycle) {
            if (!suppress_default and pattern_space.items.len > 0) {
                _ = writer.writeAll(pattern_space.items) catch {};
                _ = writer.writeByte('\n') catch {};
            } else if (!suppress_default and pattern_space.items.len == 0) {
                _ = writer.writeByte('\n') catch {};
            }
            flushQueues(io, writer, &append_queue, &read_queue);
        }

        if (cycle_line_consumed) {
            input_idx += 1;
        }
    }

    return common_error.EXIT_SUCCESS;
}

fn appendToFile(io: std.Io, path: []const u8, content: []const u8) void {
    const f = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .write_only }) catch return;
    defer f.close(io);
    const end_offset = f.length(io) catch 0;
    f.writePositionalAll(io, content, end_offset) catch return;
    f.writePositionalAll(io, "\n", end_offset + content.len) catch return;
}

fn printVisuallyUnambiguous(writer: anytype, text: []const u8) void {
    for (text) |c| {
        switch (c) {
            '\\' => _ = writer.writeAll("\\\\") catch {},
            0x07 => _ = writer.writeAll("\\a") catch {},
            0x08 => _ = writer.writeAll("\\b") catch {},
            0x0c => _ = writer.writeAll("\\f") catch {},
            '\r' => _ = writer.writeAll("\\r") catch {},
            '\t' => _ = writer.writeAll("\\t") catch {},
            0x0b => _ = writer.writeAll("\\v") catch {},
            else => {
                if (std.ascii.isPrint(c)) {
                    _ = writer.writeByte(c) catch {};
                } else {
                    _ = writer.print("\\{o:0>3}", .{c}) catch {};
                }
            },
        }
    }
    _ = writer.writeAll("$\n") catch {};
}

fn transliterateString(buf: []u8, from: []const u8, to: []const u8) void {
    const len = @min(from.len, to.len);
    for (buf) |*b| {
        for (from[0..len], 0..) |from_c, idx| {
            if (b.* == from_c) {
                b.* = to[idx];
                break;
            }
        }
    }
}

fn applySubstitute(allocator: std.mem.Allocator, pattern_space: *std.ArrayList(u8), cmd: *Command, io: std.Io) bool {
    const re = &(cmd.sub_re orelse return false);
    const text = pattern_space.items;

    var new_buf: std.ArrayList(u8) = .empty;
    defer new_buf.deinit(allocator);

    var match_count: usize = 0;
    var last_end: usize = 0;
    var search_start: usize = 0;
    var any_replaced = false;

    while (search_start <= text.len) {
        const slice = text[search_start..];
        const res = re.search(slice) orelse break;

        const abs_start = search_start + res.start;
        const abs_end = search_start + res.end;

        match_count += 1;
        const should_replace = if (cmd.sub_flags.nth > 0)
            (match_count == cmd.sub_flags.nth)
        else
            (cmd.sub_flags.global or match_count == 1);

        if (should_replace) {
            any_replaced = true;
            new_buf.appendSlice(allocator, text[last_end..abs_start]) catch {};

            // Expand replacement string
            var r_i: usize = 0;
            while (r_i < cmd.sub_repl.len) {
                const c = cmd.sub_repl[r_i];
                if (c == '&') {
                    new_buf.appendSlice(allocator, text[abs_start..abs_end]) catch {};
                    r_i += 1;
                } else if (c == '\\' and r_i + 1 < cmd.sub_repl.len) {
                    const next = cmd.sub_repl[r_i + 1];
                    if (next >= '1' and next <= '9') {
                        const group_id = next - '0';
                        if (res.captures[group_id]) |cap| {
                            const c_start = search_start + cap[0];
                            const c_end = search_start + cap[1];
                            new_buf.appendSlice(allocator, text[c_start..c_end]) catch {};
                        }
                    } else if (next == '&') {
                        new_buf.append(allocator, '&') catch {};
                    } else if (next == '\\') {
                        new_buf.append(allocator, '\\') catch {};
                    } else if (next == 'n') {
                        new_buf.append(allocator, '\n') catch {};
                    } else {
                        new_buf.append(allocator, next) catch {};
                    }
                    r_i += 2;
                } else {
                    new_buf.append(allocator, c) catch {};
                    r_i += 1;
                }
            }

            last_end = abs_end;
        }

        if (cmd.sub_flags.nth > 0 and match_count >= cmd.sub_flags.nth) break;
        if (!cmd.sub_flags.global and match_count >= 1) break;

        if (res.end == 0) {
            search_start += 1;
        } else {
            search_start = abs_end;
        }
    }

    if (any_replaced) {
        new_buf.appendSlice(allocator, text[last_end..]) catch {};
        pattern_space.clearRetainingCapacity();
        pattern_space.appendSlice(allocator, new_buf.items) catch {};

        if (cmd.sub_flags.print) {
            std.debug.print("{s}\n", .{pattern_space.items});
        }
        if (cmd.sub_flags.write_file) |wpath| {
            appendToFile(io, wpath, pattern_space.items);
        }
        return true;
    }

    return false;
}

fn evalAddress(cmd: *Command, lineno: usize, is_last: bool, line_text: []const u8) bool {
    var raw_selected = false;

    if (cmd.addr1 == null and cmd.addr2 == null) {
        raw_selected = true;
    } else if (cmd.addr2 == null) {
        // Single address
        raw_selected = matchSingleAddr(cmd.addr1.?, lineno, is_last, line_text);
    } else {
        // 2-address range
        if (cmd.in_range) {
            raw_selected = true;
            if (matchSingleAddr(cmd.addr2.?, lineno, is_last, line_text)) {
                cmd.in_range = false;
            }
        } else {
            if (matchSingleAddr(cmd.addr1.?, lineno, is_last, line_text)) {
                raw_selected = true;
                const a2 = cmd.addr2.?;
                if (a2.addr_type == .line_num and a2.line_num <= lineno) {
                    cmd.in_range = false;
                } else if (matchSingleAddr(a2, lineno, is_last, line_text)) {
                    cmd.in_range = false;
                } else {
                    cmd.in_range = true;
                }
            }
        }
    }

    return if (cmd.invert) !raw_selected else raw_selected;
}

fn matchSingleAddr(addr: Address, lineno: usize, is_last: bool, line_text: []const u8) bool {
    switch (addr.addr_type) {
        .line_num => return lineno == addr.line_num,
        .last_line => return is_last,
        .regex => {
            if (addr.compiled_re) |*re| {
                return re.matches(line_text);
            }
            return false;
        },
    }
}

fn parseScript(allocator: std.mem.Allocator, script: []const u8, is_ere: bool) !std.ArrayList(Command) {
    var list: std.ArrayList(Command) = .empty;
    errdefer list.deinit(allocator);

    var idx: usize = 0;
    while (idx < script.len) {
        // Skip leading whitespace and semicolons
        while (idx < script.len and (script[idx] == ' ' or script[idx] == '\t' or script[idx] == ';' or script[idx] == '\n' or script[idx] == '\r')) {
            idx += 1;
        }
        if (idx >= script.len) break;

        // Skip comments
        if (script[idx] == '#') {
            while (idx < script.len and script[idx] != '\n') idx += 1;
            continue;
        }

        // Parse addresses
        var addr1: ?Address = null;
        var addr2: ?Address = null;

        const maybe_a1 = try parseAddress(allocator, script, &idx, is_ere);
        if (maybe_a1) |a1| {
            addr1 = a1;
            while (idx < script.len and (script[idx] == ' ' or script[idx] == '\t')) idx += 1;
            if (idx < script.len and script[idx] == ',') {
                idx += 1;
                while (idx < script.len and (script[idx] == ' ' or script[idx] == '\t')) idx += 1;
                addr2 = try parseAddress(allocator, script, &idx, is_ere);
            }
        }

        while (idx < script.len and (script[idx] == ' ' or script[idx] == '\t')) idx += 1;
        if (idx >= script.len) break;

        // Negation '!'
        var invert = false;
        if (script[idx] == '!') {
            invert = true;
            idx += 1;
            while (idx < script.len and (script[idx] == ' ' or script[idx] == '\t')) idx += 1;
        }

        if (idx >= script.len) return error.UnexpectedEnd;
        const verb_char = script[idx];
        idx += 1;

        var cmd = Command{
            .addr1 = addr1,
            .addr2 = addr2,
            .invert = invert,
            .verb = undefined,
        };

        switch (verb_char) {
            '{' => cmd.verb = .block_start,
            '}' => cmd.verb = .block_end,
            'd' => cmd.verb = .delete,
            'D' => cmd.verb = .delete_first_line,
            'p' => cmd.verb = .print,
            'P' => cmd.verb = .print_first_line,
            'h' => cmd.verb = .hold,
            'H' => cmd.verb = .append_hold,
            'g' => cmd.verb = .get_hold,
            'G' => cmd.verb = .append_pattern,
            'x' => cmd.verb = .exchange,
            'n' => cmd.verb = .next,
            'N' => cmd.verb = .append_next,
            'q' => cmd.verb = .quit,
            '=' => cmd.verb = .line_number,
            ':' => {
                cmd.verb = .label;
                while (idx < script.len and (script[idx] == ' ' or script[idx] == '\t')) idx += 1;
                const start = idx;
                while (idx < script.len and script[idx] != ';' and script[idx] != '\n' and script[idx] != '\r') idx += 1;
                cmd.label_name = script[start..idx];
            },
            'b' => {
                cmd.verb = .branch;
                while (idx < script.len and (script[idx] == ' ' or script[idx] == '\t')) idx += 1;
                const start = idx;
                while (idx < script.len and script[idx] != ';' and script[idx] != '\n' and script[idx] != '\r') idx += 1;
                cmd.label_name = script[start..idx];
            },
            't' => {
                cmd.verb = .test_branch;
                while (idx < script.len and (script[idx] == ' ' or script[idx] == '\t')) idx += 1;
                const start = idx;
                while (idx < script.len and script[idx] != ';' and script[idx] != '\n' and script[idx] != '\r') idx += 1;
                cmd.label_name = script[start..idx];
            },
            'a' => {
                cmd.verb = .append;
                cmd.text = try parseFollowText(script, &idx);
            },
            'i' => {
                cmd.verb = .insert;
                cmd.text = try parseFollowText(script, &idx);
            },
            'c' => {
                cmd.verb = .change;
                cmd.text = try parseFollowText(script, &idx);
            },
            'r' => {
                cmd.verb = .read_file;
                while (idx < script.len and (script[idx] == ' ' or script[idx] == '\t')) idx += 1;
                const start = idx;
                while (idx < script.len and script[idx] != '\n' and script[idx] != '\r' and script[idx] != ';') idx += 1;
                cmd.file_path = script[start..idx];
            },
            'w' => {
                cmd.verb = .write_file;
                while (idx < script.len and (script[idx] == ' ' or script[idx] == '\t')) idx += 1;
                const start = idx;
                while (idx < script.len and script[idx] != '\n' and script[idx] != '\r' and script[idx] != ';') idx += 1;
                cmd.file_path = script[start..idx];
            },
            'y' => {
                cmd.verb = .transliterate;
                if (idx >= script.len) return error.InvalidTransliterate;
                const delim = script[idx];
                idx += 1;
                const from_start = idx;
                while (idx < script.len and script[idx] != delim) idx += 1;
                if (idx >= script.len) return error.InvalidTransliterate;
                cmd.trans_from = script[from_start..idx];
                idx += 1;
                const to_start = idx;
                while (idx < script.len and script[idx] != delim) idx += 1;
                if (idx >= script.len) return error.InvalidTransliterate;
                cmd.trans_to = script[to_start..idx];
                idx += 1;
            },
            's' => {
                cmd.verb = .substitute;
                if (idx >= script.len) return error.InvalidSubstitute;
                const delim = script[idx];
                idx += 1;

                // Parse regex
                var re_buf: std.ArrayList(u8) = .empty;
                defer re_buf.deinit(allocator);

                while (idx < script.len and script[idx] != delim) {
                    if (script[idx] == '\\' and idx + 1 < script.len) {
                        if (script[idx + 1] == delim) {
                            try re_buf.append(allocator, delim);
                            idx += 2;
                            continue;
                        }
                    }
                    try re_buf.append(allocator, script[idx]);
                    idx += 1;
                }
                if (idx >= script.len) return error.InvalidSubstitute;
                idx += 1; // Skip delim

                // Parse replacement
                const repl_start = idx;
                while (idx < script.len and script[idx] != delim) {
                    if (script[idx] == '\\' and idx + 1 < script.len) {
                        idx += 2;
                        continue;
                    }
                    idx += 1;
                }
                if (idx >= script.len) return error.InvalidSubstitute;
                cmd.sub_repl = script[repl_start..idx];
                idx += 1; // Skip delim

                // Parse flags (g, p, w file, i, number)
                var flags = SubFlags{};
                while (idx < script.len and script[idx] != ';' and script[idx] != '\n' and script[idx] != '\r') {
                    const fc = script[idx];
                    if (fc == 'g') {
                        flags.global = true;
                        idx += 1;
                    } else if (fc == 'p') {
                        flags.print = true;
                        idx += 1;
                    } else if (fc == 'i' or fc == 'I') {
                        flags.case_insensitive = true;
                        idx += 1;
                    } else if (fc >= '0' and fc <= '9') {
                        const num_start = idx;
                        while (idx < script.len and script[idx] >= '0' and script[idx] <= '9') idx += 1;
                        flags.nth = try std.fmt.parseInt(usize, script[num_start..idx], 10);
                    } else if (fc == 'w') {
                        idx += 1;
                        while (idx < script.len and (script[idx] == ' ' or script[idx] == '\t')) idx += 1;
                        const wstart = idx;
                        while (idx < script.len and script[idx] != ';' and script[idx] != '\n' and script[idx] != '\r') idx += 1;
                        flags.write_file = script[wstart..idx];
                        break;
                    } else {
                        idx += 1;
                    }
                }
                cmd.sub_flags = flags;

                cmd.sub_re = try common_regex.Regex.compileWithAst(
                    allocator,
                    re_buf.items,
                    if (is_ere) .ere else .bre,
                    flags.case_insensitive,
                    false,
                );
            },
            else => return error.UnknownCommand,
        }

        try list.append(allocator, cmd);
    }

    return list;
}

fn parseFollowText(script: []const u8, idx: *usize) ![]const u8 {
    while (idx.* < script.len and (script[idx.*] == ' ' or script[idx.*] == '\t')) idx.* += 1;
    if (idx.* < script.len and script[idx.*] == '\\') {
        idx.* += 1;
    }
    while (idx.* < script.len and (script[idx.*] == ' ' or script[idx.*] == '\t')) idx.* += 1;
    if (idx.* < script.len and script[idx.*] == '\n') idx.* += 1;

    const start = idx.*;
    while (idx.* < script.len and script[idx.*] != '\n' and script[idx.*] != '\r') idx.* += 1;
    return script[start..idx.*];
}

fn parseAddress(allocator: std.mem.Allocator, script: []const u8, idx: *usize, is_ere: bool) !?Address {
    if (idx.* >= script.len) return null;

    const c = script[idx.*];
    if (c == '$') {
        idx.* += 1;
        return Address{ .addr_type = .last_line };
    }

    if (std.ascii.isDigit(c)) {
        const start = idx.*;
        while (idx.* < script.len and std.ascii.isDigit(script[idx.*])) idx.* += 1;
        const num = try std.fmt.parseInt(usize, script[start..idx.*], 10);
        return Address{ .addr_type = .line_num, .line_num = num };
    }

    if (c == '/' or c == '\\') {
        var delim = c;
        if (c == '\\') {
            idx.* += 1;
            if (idx.* >= script.len) return error.InvalidAddress;
            delim = script[idx.*];
        }
        idx.* += 1;

        const start = idx.*;
        while (idx.* < script.len and script[idx.*] != delim) {
            if (script[idx.*] == '\\' and idx.* + 1 < script.len) {
                idx.* += 2;
                continue;
            }
            idx.* += 1;
        }
        if (idx.* >= script.len) return error.InvalidAddress;
        const pat = script[start..idx.*];
        idx.* += 1; // Skip delim

        const compiled = try common_regex.Regex.compile(allocator, pat, if (is_ere) .ere else .bre, false, false);
        return Address{
            .addr_type = .regex,
            .pattern = pat,
            .compiled_re = compiled,
        };
    }

    return null;
}

fn resolveBranches(commands: []Command) !void {
    var block_stack: [64]usize = undefined;
    var stack_top: usize = 0;

    for (commands, 0..) |*cmd, i| {
        if (cmd.verb == .block_start) {
            if (stack_top >= block_stack.len) return error.BlockNestingTooDeep;
            block_stack[stack_top] = i;
            stack_top += 1;
        } else if (cmd.verb == .block_end) {
            if (stack_top == 0) return error.UnmatchedBlockEnd;
            stack_top -= 1;
            const start_idx = block_stack[stack_top];
            commands[start_idx].target_pc = i + 1; // Jump past block on mismatch
        }
    }

    if (stack_top > 0) return error.UnmatchedBlockStart;

    // Resolve labels
    for (commands, 0..) |*cmd, i| {
        if (cmd.verb == .branch or cmd.verb == .test_branch) {
            if (cmd.label_name.len == 0) {
                cmd.target_pc = null; // End of script
            } else {
                var found = false;
                for (commands, 0..) |target_cmd, j| {
                    if (target_cmd.verb == .label and std.mem.eql(u8, target_cmd.label_name, cmd.label_name)) {
                        cmd.target_pc = j;
                        found = true;
                        break;
                    }
                }
                if (!found) return error.LabelNotFound;
            }
        }
        _ = i;
    }
}

// ============================================================================
// Unit Tests
// ============================================================================

test "sed: basic line addressing and substitute" {
    const allocator = std.testing.allocator;

    const script = "s/foo/bar/g";
    var cmds = try parseScript(allocator, script, false);
    defer {
        for (cmds.items) |*cmd| {
            if (cmd.sub_re) |*r| r.deinit(allocator);
        }
        cmds.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 1), cmds.items.len);
    try std.testing.expectEqual(Verb.substitute, cmds.items[0].verb);
    try std.testing.expect(cmds.items[0].sub_flags.global);
}

test "sed: address ranges and block braces" {
    const allocator = std.testing.allocator;

    const script = "1,5{ s/a/b/; d }";
    var cmds = try parseScript(allocator, script, false);
    defer {
        for (cmds.items) |*cmd| {
            if (cmd.sub_re) |*r| r.deinit(allocator);
        }
        cmds.deinit(allocator);
    }

    try resolveBranches(cmds.items);
    try std.testing.expectEqual(@as(usize, 4), cmds.items.len);
    try std.testing.expectEqual(Verb.block_start, cmds.items[0].verb);
    try std.testing.expectEqual(@as(usize, 4), cmds.items[0].target_pc.?);
}

test "sed: file execution" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const tmp_path = "zig-cache/tmp_sed_test.txt";
    const file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{});
    defer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
    try file.writeStreamingAll(io, "hello world\nfoo bar\n");
    file.close(io);

    // Run sed substitution
    const res = run(allocator, &.{ "s/world/universe/", tmp_path });
    try std.testing.expectEqual(common_error.EXIT_SUCCESS, res);
}
