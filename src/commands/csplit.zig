//! POSIX.1-2024 (IEEE Std 1003.1-2024) compliant implementation of `csplit`.
//!
//! Specification References:
//! - IEEE Std 1003.1-2024, Shell & Utilities (XCU), Section: `csplit`
//!   - SYNOPSIS:
//!       csplit [-ks] [-f prefix] [-n number] file arg...
//!   - OPTIONS:
//!       -f prefix: Name created files prefix00, prefix01, ... (default: xx).
//!       -n number: Number of decimal digits for suffix (default: 2).
//!       -k: Leave previously created files intact on error.
//!       -s: Suppress writing of file size messages to stdout.
//!   - OPERANDS:
//!       file: Path of text file to split ('-' for standard input).
//!       arg: Split pattern operands:
//!            /rexp/[offset] : Split up to line matching BRE +/- offset.
//!            %rexp%[offset] : Same, but skip section (no file created).
//!            line_no        : Split up to line number (1-based).
//!            {num}          : Repeat preceding pattern num times.
//!   - EXIT STATUS:
//!       0: Successful completion.
//!       >0: An error occurred.

const std = @import("std");
const common_args = @import("../common/args.zig");
const common_error = @import("../common/error.zig");
const common_regex = @import("../common/regex.zig");

pub const BUFFER_SIZE: usize = 16 * 1024;

const ArgType = enum {
    create_rexp,
    skip_rexp,
    line_no,
};

const SplitPattern = struct {
    arg_type: ArgType,
    pattern: []const u8 = "",
    offset: i32 = 0,
    target_line: usize = 0,
    repeat_count: usize = 0,
};

fn parseOffset(s: []const u8) !i32 {
    if (s.len == 0) return 0;
    var slice = s;
    if (slice[0] == '+') {
        slice = slice[1..];
    }
    return std.fmt.parseInt(i32, slice, 10);
}

pub fn run(allocator: std.mem.Allocator, args: []const [:0]const u8) u8 {
    const io = std.Io.Threaded.global_single_threaded.io();

    var keep_files = false;
    var quiet = false;
    var prefix: []const u8 = "xx";
    var num_digits: usize = 2;

    var parser = common_args.ArgParser.init(args);
    while (parser.next("ksf:n:")) |opt| {
        switch (opt) {
            'k' => keep_files = true,
            's' => quiet = true,
            'f' => {
                prefix = parser.optarg orelse {
                    common_error.report("csplit", "option requires an argument: -f", error.InvalidArgument);
                    return common_error.EXIT_SYNTAX;
                };
            },
            'n' => {
                const n_str = parser.optarg orelse {
                    common_error.report("csplit", "option requires an argument: -n", error.InvalidArgument);
                    return common_error.EXIT_SYNTAX;
                };
                num_digits = std.fmt.parseInt(usize, n_str, 10) catch {
                    common_error.report("csplit", "invalid number of digits", error.InvalidArgument);
                    return common_error.EXIT_SYNTAX;
                };
                if (num_digits == 0) {
                    common_error.report("csplit", "digits must be greater than zero", error.InvalidArgument);
                    return common_error.EXIT_SYNTAX;
                }
            },
            else => {
                common_error.report("csplit", "invalid option", error.InvalidArgument);
                return common_error.EXIT_SYNTAX;
            },
        }
    }

    const operands = parser.remaining();
    if (operands.len < 2) {
        common_error.report("csplit", "missing operand", error.InvalidArgument);
        return common_error.EXIT_SYNTAX;
    }

    const input_path = operands[0];
    const pattern_args = operands[1..];

    // Parse pattern operands and {num} repeats
    var patterns: std.ArrayList(SplitPattern) = .empty;
    defer patterns.deinit(allocator);

    var i: usize = 0;
    while (i < pattern_args.len) {
        const arg = pattern_args[i];
        if (arg.len > 0 and arg[0] == '{') {
            if (patterns.items.len == 0) {
                common_error.report("csplit", "repeat count must follow a pattern", error.InvalidArgument);
                return common_error.EXIT_SYNTAX;
            }
            if (arg[arg.len - 1] != '}') {
                common_error.report("csplit", "malformed repeat count", error.InvalidArgument);
                return common_error.EXIT_SYNTAX;
            }
            const inner = arg[1 .. arg.len - 1];
            const rep = std.fmt.parseInt(usize, inner, 10) catch {
                common_error.report("csplit", "invalid repeat number", error.InvalidArgument);
                return common_error.EXIT_SYNTAX;
            };
            patterns.items[patterns.items.len - 1].repeat_count = rep;
            i += 1;
            continue;
        }

        if (arg.len >= 2 and arg[0] == '/' and std.mem.indexOfScalarPos(u8, arg, 1, '/') != null) {
            const second_slash = std.mem.lastIndexOfScalar(u8, arg, '/').?;
            const pat = arg[1..second_slash];
            const off_str = arg[second_slash + 1 ..];
            const off = parseOffset(off_str) catch {
                common_error.report("csplit", "invalid offset", error.InvalidArgument);
                return common_error.EXIT_SYNTAX;
            };
            patterns.append(allocator, .{
                .arg_type = .create_rexp,
                .pattern = pat,
                .offset = off,
            }) catch {
                common_error.report("csplit", null, error.OutOfMemory);
                return common_error.EXIT_FAILURE;
            };
        } else if (arg.len >= 2 and arg[0] == '%' and std.mem.indexOfScalarPos(u8, arg, 1, '%') != null) {
            const second_pct = std.mem.lastIndexOfScalar(u8, arg, '%').?;
            const pat = arg[1..second_pct];
            const off_str = arg[second_pct + 1 ..];
            const off = parseOffset(off_str) catch {
                common_error.report("csplit", "invalid offset", error.InvalidArgument);
                return common_error.EXIT_SYNTAX;
            };
            patterns.append(allocator, .{
                .arg_type = .skip_rexp,
                .pattern = pat,
                .offset = off,
            }) catch {
                common_error.report("csplit", null, error.OutOfMemory);
                return common_error.EXIT_FAILURE;
            };
        } else {
            // Line number
            const lno = std.fmt.parseInt(usize, arg, 10) catch {
                common_error.report("csplit", "invalid pattern or line number", error.InvalidArgument);
                return common_error.EXIT_SYNTAX;
            };
            if (lno == 0) {
                common_error.report("csplit", "line number must be positive", error.InvalidArgument);
                return common_error.EXIT_SYNTAX;
            }
            patterns.append(allocator, .{
                .arg_type = .line_no,
                .target_line = lno,
            }) catch {
                common_error.report("csplit", null, error.OutOfMemory);
                return common_error.EXIT_FAILURE;
            };
        }
        i += 1;
    }

    // Read all input lines into memory arena
    var line_arena = std.heap.ArenaAllocator.init(allocator);
    defer line_arena.deinit();
    const l_alloc = line_arena.allocator();

    var lines: std.ArrayList([]const u8) = .empty;

    const is_stdin = std.mem.eql(u8, input_path, "-");
    const in_file = if (is_stdin)
        std.Io.File.stdin()
    else
        std.Io.Dir.cwd().openFile(io, input_path, .{ .mode = .read_only }) catch |err| {
            common_error.report("csplit", input_path, err);
            return common_error.EXIT_FAILURE;
        };
    defer if (!is_stdin) in_file.close(io);

    var read_buf: [BUFFER_SIZE]u8 = undefined;
    var r = in_file.readerStreaming(io, &read_buf);

    while (true) {
        const maybe_line = r.interface.takeDelimiter('\n') catch |err| {
            common_error.report("csplit", input_path, err);
            return common_error.EXIT_FAILURE;
        };
        const raw_line = maybe_line orelse break;
        const line = if (raw_line.len > 0 and raw_line[raw_line.len - 1] == '\r')
            raw_line[0 .. raw_line.len - 1]
        else
            raw_line;

        const line_copy = l_alloc.dupe(u8, line) catch {
            common_error.report("csplit", null, error.OutOfMemory);
            return common_error.EXIT_FAILURE;
        };
        lines.append(l_alloc, line_copy) catch {
            common_error.report("csplit", null, error.OutOfMemory);
            return common_error.EXIT_FAILURE;
        };
    }

    // Output file writing and rollback tracker
    var created_files: std.ArrayList([]const u8) = .empty;
    defer {
        for (created_files.items) |cf| allocator.free(cf);
        created_files.deinit(allocator);
    }

    var file_piece_idx: usize = 0;
    var cur_line: usize = 0;
    var has_done_rexp = false;

    const stdout_file = std.Io.File.stdout();
    var stdout_buf: [BUFFER_SIZE]u8 = undefined;
    var stdout_fw = stdout_file.writerStreaming(io, &stdout_buf);
    const writer = &stdout_fw.interface;
    defer stdout_fw.flush() catch {};

    const cleanup_files = struct {
        fn run_cleanup(io_ctx: std.Io, cf_list: []const []const u8) void {
            for (cf_list) |fname| {
                std.Io.Dir.cwd().deleteFile(io_ctx, fname) catch {};
            }
        }
    }.run_cleanup;

    for (patterns.items) |pat_desc| {
        var exec_count: usize = 0;
        const total_times = 1 + pat_desc.repeat_count;

        while (exec_count < total_times) : (exec_count += 1) {
            var target_idx: usize = 0;

            switch (pat_desc.arg_type) {
                .line_no => {
                    const lno_0 = pat_desc.target_line - 1;
                    if (lno_0 < cur_line or lno_0 > lines.items.len) {
                        common_error.report("csplit", "line number out of range", error.InvalidArgument);
                        if (!keep_files) cleanup_files(io, created_files.items);
                        return common_error.EXIT_FAILURE;
                    }
                    target_idx = lno_0;
                },
                .create_rexp, .skip_rexp => {
                    var re = common_regex.Regex.compile(allocator, pat_desc.pattern, .bre, false, false) catch |err| {
                        common_error.report("csplit", pat_desc.pattern, err);
                        if (!keep_files) cleanup_files(io, created_files.items);
                        return common_error.EXIT_FAILURE;
                    };
                    defer re.deinit(allocator);

                    const search_start = if (!has_done_rexp and cur_line == 0) cur_line else cur_line + 1;
                    var match_idx: ?usize = null;
                    var scan = search_start;
                    while (scan < lines.items.len) : (scan += 1) {
                        if (re.matches(lines.items[scan])) {
                            match_idx = scan;
                            break;
                        }
                    }

                    if (match_idx == null) {
                        common_error.report("csplit", "match not found", error.InvalidArgument);
                        if (!keep_files) cleanup_files(io, created_files.items);
                        return common_error.EXIT_FAILURE;
                    }

                    const target_calc = @as(isize, @intCast(match_idx.?)) + pat_desc.offset;
                    if (target_calc < 0 or target_calc > lines.items.len) {
                        common_error.report("csplit", "offset out of range", error.InvalidArgument);
                        if (!keep_files) cleanup_files(io, created_files.items);
                        return common_error.EXIT_FAILURE;
                    }
                    target_idx = @as(usize, @intCast(target_calc));
                    if (target_idx < cur_line) {
                        common_error.report("csplit", "offset before current line", error.InvalidArgument);
                        if (!keep_files) cleanup_files(io, created_files.items);
                        return common_error.EXIT_FAILURE;
                    }
                    has_done_rexp = true;
                },
            }

            if (pat_desc.arg_type == .skip_rexp) {
                // Section is skipped
                cur_line = target_idx;
                continue;
            }

            // Create output file piece
            var fname_buf: [512]u8 = undefined;
            // Format suffix with dynamic zero-padding
            var pad_fmt_buf: [32]u8 = undefined;
            const pad_fmt = std.fmt.bufPrint(&pad_fmt_buf, "{{s}}{{d:0>{d}}}", .{num_digits}) catch "xx00";
            _ = pad_fmt;

            // Manual zero-padding
            var num_buf: [32]u8 = undefined;
            const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{file_piece_idx}) catch "0";
            var piece_name: []const u8 = undefined;
            if (num_str.len < num_digits) {
                var padded_buf: [64]u8 = undefined;
                const zeroes_needed = num_digits - num_str.len;
                @memset(padded_buf[0..zeroes_needed], '0');
                @memcpy(padded_buf[zeroes_needed .. zeroes_needed + num_str.len], num_str);
                piece_name = std.fmt.bufPrint(&fname_buf, "{s}{s}", .{ prefix, padded_buf[0..num_digits] }) catch {
                    common_error.report("csplit", null, error.NameTooLong);
                    if (!keep_files) cleanup_files(io, created_files.items);
                    return common_error.EXIT_FAILURE;
                };
            } else {
                piece_name = std.fmt.bufPrint(&fname_buf, "{s}{s}", .{ prefix, num_str }) catch {
                    common_error.report("csplit", null, error.NameTooLong);
                    if (!keep_files) cleanup_files(io, created_files.items);
                    return common_error.EXIT_FAILURE;
                };
            }

            const owned_fname = allocator.dupe(u8, piece_name) catch {
                common_error.report("csplit", null, error.OutOfMemory);
                if (!keep_files) cleanup_files(io, created_files.items);
                return common_error.EXIT_FAILURE;
            };
            created_files.append(allocator, owned_fname) catch {
                allocator.free(owned_fname);
                common_error.report("csplit", null, error.OutOfMemory);
                if (!keep_files) cleanup_files(io, created_files.items);
                return common_error.EXIT_FAILURE;
            };

            const out_f = std.Io.Dir.cwd().createFile(io, piece_name, .{}) catch |err| {
                common_error.report("csplit", piece_name, err);
                if (!keep_files) cleanup_files(io, created_files.items);
                return common_error.EXIT_FAILURE;
            };
            defer out_f.close(io);

            var bytes_written: usize = 0;
            var l_i = cur_line;
            while (l_i < target_idx) : (l_i += 1) {
                const l = lines.items[l_i];
                out_f.writeStreamingAll(io, l) catch |err| {
                    common_error.report("csplit", piece_name, err);
                    if (!keep_files) cleanup_files(io, created_files.items);
                    return common_error.EXIT_FAILURE;
                };
                out_f.writeStreamingAll(io, "\n") catch |err| {
                    common_error.report("csplit", piece_name, err);
                    if (!keep_files) cleanup_files(io, created_files.items);
                    return common_error.EXIT_FAILURE;
                };
                bytes_written += l.len + 1;
            }

            if (!quiet) {
                _ = writer.print("{d}\n", .{bytes_written}) catch {};
            }

            cur_line = target_idx;
            file_piece_idx += 1;
        }
    }

    // Write final piece if lines remain
    if (cur_line < lines.items.len) {
        var fname_buf: [512]u8 = undefined;
        var num_buf: [32]u8 = undefined;
        const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{file_piece_idx}) catch "0";
        var piece_name: []const u8 = undefined;
        if (num_str.len < num_digits) {
            var padded_buf: [64]u8 = undefined;
            const zeroes_needed = num_digits - num_str.len;
            @memset(padded_buf[0..zeroes_needed], '0');
            @memcpy(padded_buf[zeroes_needed .. zeroes_needed + num_str.len], num_str);
            piece_name = std.fmt.bufPrint(&fname_buf, "{s}{s}", .{ prefix, padded_buf[0..num_digits] }) catch "xx00";
        } else {
            piece_name = std.fmt.bufPrint(&fname_buf, "{s}{s}", .{ prefix, num_str }) catch "xx00";
        }

        const owned_fname = allocator.dupe(u8, piece_name) catch {
            common_error.report("csplit", null, error.OutOfMemory);
            if (!keep_files) cleanup_files(io, created_files.items);
            return common_error.EXIT_FAILURE;
        };
        created_files.append(allocator, owned_fname) catch {
            allocator.free(owned_fname);
            common_error.report("csplit", null, error.OutOfMemory);
            if (!keep_files) cleanup_files(io, created_files.items);
            return common_error.EXIT_FAILURE;
        };

        const out_f = std.Io.Dir.cwd().createFile(io, piece_name, .{}) catch |err| {
            common_error.report("csplit", piece_name, err);
            if (!keep_files) cleanup_files(io, created_files.items);
            return common_error.EXIT_FAILURE;
        };
        defer out_f.close(io);

        var bytes_written: usize = 0;
        var l_i = cur_line;
        while (l_i < lines.items.len) : (l_i += 1) {
            const l = lines.items[l_i];
            out_f.writeStreamingAll(io, l) catch |err| {
                common_error.report("csplit", piece_name, err);
                if (!keep_files) cleanup_files(io, created_files.items);
                return common_error.EXIT_FAILURE;
            };
            out_f.writeStreamingAll(io, "\n") catch |err| {
                common_error.report("csplit", piece_name, err);
                if (!keep_files) cleanup_files(io, created_files.items);
                return common_error.EXIT_FAILURE;
            };
            bytes_written += l.len + 1;
        }

        if (!quiet) {
            _ = writer.print("{d}\n", .{bytes_written}) catch {};
        }
    }

    return common_error.EXIT_SUCCESS;
}

// ============================================================================
// Unit Tests
// ============================================================================

test "csplit: parseOffset validation" {
    try std.testing.expectEqual(@as(i32, 0), try parseOffset(""));
    try std.testing.expectEqual(@as(i32, 5), try parseOffset("5"));
    try std.testing.expectEqual(@as(i32, 5), try parseOffset("+5"));
    try std.testing.expectEqual(@as(i32, -3), try parseOffset("-3"));
}

test "csplit: option validation" {
    const allocator = std.testing.allocator;

    // Missing operands
    try std.testing.expectEqual(common_error.EXIT_SYNTAX, run(allocator, &.{}));
    try std.testing.expectEqual(common_error.EXIT_SYNTAX, run(allocator, &.{"file.txt"}));

    // Invalid digits (-n 0)
    try std.testing.expectEqual(common_error.EXIT_SYNTAX, run(allocator, &.{ "-n", "0", "file.txt", "10" }));
}

test "csplit: file splitting execution" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const tmp_src = "zig-cache/tmp_csplit_src.txt";
    const prefix = "zig-cache/cs_out_";

    {
        const f = try std.Io.Dir.cwd().createFile(io, tmp_src, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "line1\nline2\nSECTION2\nline3\nline4\n");
    }
    defer {
        std.Io.Dir.cwd().deleteFile(io, tmp_src) catch {};
        std.Io.Dir.cwd().deleteFile(io, "zig-cache/cs_out_00") catch {};
        std.Io.Dir.cwd().deleteFile(io, "zig-cache/cs_out_01") catch {};
    }

    // Split on regex /SECTION2/ quietly
    const res = run(allocator, &.{ "-s", "-f", prefix, tmp_src, "/SECTION2/" });
    try std.testing.expectEqual(common_error.EXIT_SUCCESS, res);
}
