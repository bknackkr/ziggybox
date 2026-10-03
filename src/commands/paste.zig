//! POSIX.1-2024 (IEEE Std 1003.1-2024) compliant implementation of `paste`.
//!
//! Specification References:
//! - IEEE Std 1003.1-2024, Shell & Utilities (XCU), Section: `paste`
//!   - SYNOPSIS:
//!       paste [-s] [-d list] file...
//!   - OPTIONS:
//!       -d list: Circular list of delimiter characters.
//!                Supports escapes: \n, \t, \\, \0 (empty string). Default is tab.
//!       -s: Concatenate all lines from each input file into one line per file.
//!   - OPERANDS:
//!       file: Input file pathname. '-' represents standard input.
//!             If multiple '-' appear, lines from stdin are consumed circularly.
//!   - EXIT STATUS:
//!       0: Successful completion.
//!       >0: An error occurred.

const std = @import("std");
const common_args = @import("../common/args.zig");
const common_error = @import("../common/error.zig");

pub const BUFFER_SIZE: usize = 16 * 1024;

pub fn parseDelimList(allocator: std.mem.Allocator, list_str: []const u8) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(allocator);

    var i: usize = 0;
    while (i < list_str.len) {
        if (list_str[i] == '\\' and i + 1 < list_str.len) {
            const next = list_str[i + 1];
            switch (next) {
                'n' => try list.append(allocator, "\n"),
                't' => try list.append(allocator, "\t"),
                '\\' => try list.append(allocator, "\\"),
                '0' => try list.append(allocator, ""), // POSIX \0 = empty string
                else => try list.append(allocator, list_str[i + 1 .. i + 2]),
            }
            i += 2;
        } else {
            try list.append(allocator, list_str[i .. i + 1]);
            i += 1;
        }
    }

    if (list.items.len == 0) {
        try list.append(allocator, "\t");
    }

    return list.toOwnedSlice(allocator);
}

const FileSource = struct {
    file: std.Io.File,
    is_stdin: bool,
    eof: bool = false,
    read_buf: [BUFFER_SIZE]u8 = undefined,
    reader: std.Io.File.Reader,
};

pub fn run(allocator: std.mem.Allocator, args: []const [:0]const u8) u8 {
    const io = std.Io.Threaded.global_single_threaded.io();

    var serial_mode = false;
    var raw_delim_str: ?[]const u8 = null;

    var parser = common_args.ArgParser.init(args);
    while (parser.next("sd:")) |opt| {
        switch (opt) {
            's' => serial_mode = true,
            'd' => {
                raw_delim_str = parser.optarg orelse {
                    common_error.report("paste", "option requires an argument: -d", error.InvalidArgument);
                    return common_error.EXIT_SYNTAX;
                };
            },
            else => {
                common_error.report("paste", "invalid option", error.InvalidArgument);
                return common_error.EXIT_SYNTAX;
            },
        }
    }

    const operands = parser.remaining();
    if (operands.len == 0) {
        common_error.report("paste", "missing file operand", error.InvalidArgument);
        return common_error.EXIT_SYNTAX;
    }

    const default_delim = [_][]const u8{"\t"};
    const delims: [][]const u8 = if (raw_delim_str) |ds|
        parseDelimList(allocator, ds) catch {
            common_error.report("paste", null, error.OutOfMemory);
            return common_error.EXIT_FAILURE;
        }
    else
        allocator.dupe([]const u8, &default_delim) catch {
            common_error.report("paste", null, error.OutOfMemory);
            return common_error.EXIT_FAILURE;
        };
    defer allocator.free(delims);

    const stdout_file = std.Io.File.stdout();
    var stdout_buf: [BUFFER_SIZE]u8 = undefined;
    var stdout_fw = stdout_file.writerStreaming(io, &stdout_buf);
    const writer = &stdout_fw.interface;
    defer stdout_fw.flush() catch {};

    if (serial_mode) {
        // Serial mode (-s): process each file sequentially
        var had_error = false;

        for (operands) |path| {
            const is_stdin = std.mem.eql(u8, path, "-");
            const file = if (is_stdin)
                std.Io.File.stdin()
            else
                std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch |err| {
                    common_error.report("paste", path, err);
                    had_error = true;
                    continue;
                };
            defer if (!is_stdin) file.close(io);

            var read_buf: [BUFFER_SIZE]u8 = undefined;
            var r = file.readerStreaming(io, &read_buf);

            var delim_idx: usize = 0;
            var line_count: usize = 0;

            while (true) {
                const maybe_line = r.interface.takeDelimiter('\n') catch |err| {
                    common_error.report("paste", path, err);
                    had_error = true;
                    break;
                };

                const raw_line = maybe_line orelse break;
                const line = if (raw_line.len > 0 and raw_line[raw_line.len - 1] == '\r')
                    raw_line[0 .. raw_line.len - 1]
                else
                    raw_line;

                if (line_count > 0) {
                    const d = delims[delim_idx % delims.len];
                    _ = writer.writeAll(d) catch {};
                    delim_idx += 1;
                }
                _ = writer.writeAll(line) catch {};
                line_count += 1;
            }

            _ = writer.writeByte('\n') catch {};
        }

        return if (had_error) common_error.EXIT_FAILURE else common_error.EXIT_SUCCESS;
    } else {
        // Parallel mode (default)
        // Set up sources
        var sources = allocator.alloc(FileSource, operands.len) catch {
            common_error.report("paste", null, error.OutOfMemory);
            return common_error.EXIT_FAILURE;
        };
        defer allocator.free(sources);

        // Share single stdin reader if multiple '-' appear
        var shared_stdin_buf: [BUFFER_SIZE]u8 = undefined;
        var shared_stdin_r = std.Io.File.stdin().readerStreaming(io, &shared_stdin_buf);

        var opened_count: usize = 0;
        defer {
            for (sources[0..opened_count]) |s| {
                if (!s.is_stdin) s.file.close(io);
            }
        }

        for (operands, 0..) |path, i| {
            const is_stdin = std.mem.eql(u8, path, "-");
            if (is_stdin) {
                sources[i] = .{
                    .file = std.Io.File.stdin(),
                    .is_stdin = true,
                    .reader = shared_stdin_r,
                };
                opened_count += 1;
            } else {
                const file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch |err| {
                    common_error.report("paste", path, err);
                    return common_error.EXIT_FAILURE;
                };
                sources[i] = .{
                    .file = file,
                    .is_stdin = false,
                    .reader = undefined,
                };
                sources[i].reader = sources[i].file.readerStreaming(io, &sources[i].read_buf);
                opened_count += 1;
            }
        }

        // Loop reading one line from each file
        while (true) {
            var any_active = false;
            var any_data = false;

            // Check if any source is not EOF yet
            for (sources) |s| {
                if (!s.eof) {
                    any_active = true;
                    break;
                }
            }
            if (!any_active) break;

            for (sources, 0..) |*src, idx| {
                if (idx > 0) {
                    const d = delims[(idx - 1) % delims.len];
                    _ = writer.writeAll(d) catch {};
                }

                if (!src.eof) {
                    const maybe_line = if (src.is_stdin)
                        shared_stdin_r.interface.takeDelimiter('\n') catch null
                    else
                        src.reader.interface.takeDelimiter('\n') catch null;

                    if (maybe_line) |raw_line| {
                        any_data = true;
                        const line = if (raw_line.len > 0 and raw_line[raw_line.len - 1] == '\r')
                            raw_line[0 .. raw_line.len - 1]
                        else
                            raw_line;
                        _ = writer.writeAll(line) catch {};
                    } else {
                        src.eof = true;
                    }
                }
            }

            if (!any_data) {
                // All remaining files encountered EOF on this iteration
                break;
            }

            _ = writer.writeByte('\n') catch {};
        }

        return common_error.EXIT_SUCCESS;
    }
}

// ============================================================================
// Unit Tests
// ============================================================================

test "paste: parseDelimList escape sequences" {
    const allocator = std.testing.allocator;

    const d1 = try parseDelimList(allocator, "\\t,\\n");
    defer allocator.free(d1);
    try std.testing.expectEqual(@as(usize, 3), d1.len);
    try std.testing.expectEqualStrings("\t", d1[0]);
    try std.testing.expectEqualStrings(",", d1[1]);
    try std.testing.expectEqualStrings("\n", d1[2]);

    // \0 empty string escape
    const d2 = try parseDelimList(allocator, "\\0");
    defer allocator.free(d2);
    try std.testing.expectEqual(@as(usize, 1), d2.len);
    try std.testing.expectEqualStrings("", d2[0]);
}

test "paste: option validation" {
    const allocator = std.testing.allocator;

    // Missing file operand
    try std.testing.expectEqual(common_error.EXIT_SYNTAX, run(allocator, &.{}));

    // Invalid option
    try std.testing.expectEqual(common_error.EXIT_SYNTAX, run(allocator, &.{ "-z", "file.txt" }));
}

test "paste: file execution parallel and serial" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const path1 = "zig-cache/tmp_paste_1.txt";
    const path2 = "zig-cache/tmp_paste_2.txt";

    {
        const f1 = try std.Io.Dir.cwd().createFile(io, path1, .{});
        defer f1.close(io);
        try f1.writeStreamingAll(io, "1\n2\n3\n");

        const f2 = try std.Io.Dir.cwd().createFile(io, path2, .{});
        defer f2.close(io);
        try f2.writeStreamingAll(io, "a\nb\nc\n");
    }
    defer {
        std.Io.Dir.cwd().deleteFile(io, path1) catch {};
        std.Io.Dir.cwd().deleteFile(io, path2) catch {};
    }

    // Parallel paste
    const res_par = run(allocator, &.{ path1, path2 });
    try std.testing.expectEqual(common_error.EXIT_SUCCESS, res_par);

    // Serial paste with delimiter
    const res_ser = run(allocator, &.{ "-s", "-d", ",", path1, path2 });
    try std.testing.expectEqual(common_error.EXIT_SUCCESS, res_ser);
}
