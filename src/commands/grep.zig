//! POSIX.1-2024 (IEEE Std 1003.1-2024) compliant implementation of `grep`.
//!
//! Specification References:
//! - IEEE Std 1003.1-2024, Shell & Utilities (XCU), Section: `grep`
//!   - SYNOPSIS:
//!       grep [-E|-F] [-c|-l|-q] [-insvx] -e pattern_list... [-f pattern_file...] [file...]
//!       grep [-E|-F] [-c|-l|-q] [-insvx] [-e pattern_list...] -f pattern_file... [file...]
//!       grep [-E|-F] [-c|-l|-q] [-insvx] pattern_list [file...]
//!   - OPTIONS:
//!       -E: Match using extended regular expressions (ERE).
//!       -F: Match using fixed strings.
//!       -c: Write only a count of selected lines to standard output.
//!       -e: Specify pattern list (newline-separated). Multiple -e accepted.
//!       -f: Read patterns from pattern file (newline-terminated). Multiple -f accepted.
//!       -i: Case-insensitive matching.
//!       -l: Write only the names of files containing selected lines.
//!       -n: Precede each output line by its relative 1-based line number.
//!       -q: Quiet mode (exit 0 immediately if line selected; suppress output).
//!       -s: Suppress error messages ordinarily written for nonexistent or unreadable files.
//!       -v: Select lines not matching any specified pattern.
//!       -x: Match entire line (excluding terminating newline).
//!   - EXIT STATUS:
//!       0: One or more lines were selected.
//!       1: No lines were selected.
//!       >1 (2): An error occurred (syntax, unreadable file), unless -q matched.

const std = @import("std");
const common_args = @import("../common/args.zig");
const common_error = @import("../common/error.zig");
const common_regex = @import("../common/regex.zig");

pub const BUFFER_SIZE: usize = 16 * 1024;

pub fn run(allocator: std.mem.Allocator, args: []const [:0]const u8) u8 {
    const io = std.Io.Threaded.global_single_threaded.io();

    var mode: common_regex.Mode = .bre;
    var count_only = false;
    var list_files = false;
    var quiet = false;
    var case_insensitive = false;
    var line_numbers = false;
    var suppress_errors = false;
    var invert_match = false;
    var whole_line = false;

    var raw_patterns: std.ArrayList([]const u8) = .empty;
    defer raw_patterns.deinit(allocator);

    var file_contents: std.ArrayList([]u8) = .empty;
    defer {
        for (file_contents.items) |fc| allocator.free(fc);
        file_contents.deinit(allocator);
    }

    var parser = common_args.ArgParser.init(args);
    while (parser.next("EFclqinsvxe:f:")) |opt| {
        switch (opt) {
            'E' => mode = .ere,
            'F' => mode = .fixed,
            'c' => {
                count_only = true;
                list_files = false;
                quiet = false;
            },
            'l' => {
                list_files = true;
                count_only = false;
                quiet = false;
            },
            'q' => {
                quiet = true;
                count_only = false;
                list_files = false;
            },
            'i' => case_insensitive = true,
            'n' => line_numbers = true,
            's' => suppress_errors = true,
            'v' => invert_match = true,
            'x' => whole_line = true,
            'e' => {
                const pat_list = parser.optarg orelse {
                    common_error.report("grep", "option requires an argument: -e", error.InvalidArgument);
                    return common_error.EXIT_SYNTAX;
                };
                var it = std.mem.splitScalar(u8, pat_list, '\n');
                while (it.next()) |chunk| {
                    raw_patterns.append(allocator, chunk) catch {
                        common_error.report("grep", null, error.OutOfMemory);
                        return common_error.EXIT_FAILURE;
                    };
                }
            },
            'f' => {
                const pat_path = parser.optarg orelse {
                    common_error.report("grep", "option requires an argument: -f", error.InvalidArgument);
                    return common_error.EXIT_SYNTAX;
                };

                const content = std.Io.Dir.cwd().readFileAlloc(io, pat_path, allocator, .unlimited) catch |err| {
                    if (!suppress_errors) common_error.report("grep", pat_path, err);
                    return common_error.EXIT_SYNTAX;
                };
                file_contents.append(allocator, content) catch {
                    common_error.report("grep", null, error.OutOfMemory);
                    return common_error.EXIT_FAILURE;
                };

                var line_slice = content;
                if (line_slice.len > 0 and line_slice[line_slice.len - 1] == '\n') {
                    line_slice = line_slice[0 .. line_slice.len - 1];
                }
                if (line_slice.len > 0) {
                    var it = std.mem.splitScalar(u8, line_slice, '\n');
                    while (it.next()) |chunk| {
                        raw_patterns.append(allocator, chunk) catch {
                            common_error.report("grep", null, error.OutOfMemory);
                            return common_error.EXIT_FAILURE;
                        };
                    }
                } else if (content.len > 0) {
                    // Empty pattern from single newline
                    raw_patterns.append(allocator, "") catch {
                        common_error.report("grep", null, error.OutOfMemory);
                        return common_error.EXIT_FAILURE;
                    };
                }
            },
            else => {
                common_error.report("grep", "invalid option", error.InvalidArgument);
                return common_error.EXIT_SYNTAX;
            },
        }
    }

    const rem = parser.remaining();
    var operands: []const [:0]const u8 = &.{};

    if (raw_patterns.items.len == 0) {
        if (rem.len == 0) {
            common_error.report("grep", "missing pattern", error.InvalidArgument);
            return common_error.EXIT_SYNTAX;
        }

        const pat_list = rem[0];
        var it = std.mem.splitScalar(u8, pat_list, '\n');
        while (it.next()) |chunk| {
            raw_patterns.append(allocator, chunk) catch {
                common_error.report("grep", null, error.OutOfMemory);
                return common_error.EXIT_FAILURE;
            };
        }
        operands = rem[1..];
    } else {
        operands = rem;
    }

    // Default to reading stdin if no file operands are specified
    const default_operands = [_][:0]const u8{"-"};
    const file_list: []const [:0]const u8 = if (operands.len == 0) &default_operands else operands;
    const print_filename = (file_list.len > 1);

    // Compile all patterns
    var compiled_patterns: std.ArrayList(common_regex.Regex) = .empty;
    defer {
        for (compiled_patterns.items) |*pat| pat.deinit(allocator);
        compiled_patterns.deinit(allocator);
    }

    for (raw_patterns.items) |pat_str| {
        const re = common_regex.Regex.compile(allocator, pat_str, mode, case_insensitive, whole_line) catch |err| {
            common_error.report("grep", pat_str, err);
            return common_error.EXIT_SYNTAX;
        };
        compiled_patterns.append(allocator, re) catch {
            common_error.report("grep", null, error.OutOfMemory);
            return common_error.EXIT_FAILURE;
        };
    }

    // Output buffering
    const stdout_file = std.Io.File.stdout();
    var stdout_buf: [BUFFER_SIZE]u8 = undefined;
    var stdout_fw = if (!quiet) stdout_file.writerStreaming(io, &stdout_buf) else null;
    const writer = if (stdout_fw) |*fw| &fw.interface else null;

    var total_selected: usize = 0;
    var had_error = false;

    for (file_list) |path| {
        const is_stdin = std.mem.eql(u8, path, "-");
        const file = if (is_stdin)
            std.Io.File.stdin()
        else
            std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch |err| {
                if (!suppress_errors) common_error.report("grep", path, err);
                had_error = true;
                continue;
            };
        defer if (!is_stdin) file.close(io);

        var read_buf: [BUFFER_SIZE]u8 = undefined;
        var r = file.readerStreaming(io, &read_buf);

        var line_num: usize = 0;
        var file_selected: usize = 0;

        while (true) {
            const maybe_line = r.interface.takeDelimiter('\n') catch |err| {
                if (!suppress_errors) common_error.report("grep", path, err);
                had_error = true;
                break;
            };

            const raw_line = maybe_line orelse break;
            const line = if (raw_line.len > 0 and raw_line[raw_line.len - 1] == '\r')
                raw_line[0 .. raw_line.len - 1]
            else
                raw_line;

            line_num += 1;

            var is_match = false;
            for (compiled_patterns.items) |*re| {
                if (re.matches(line)) {
                    is_match = true;
                    break;
                }
            }

            const selected = if (invert_match) !is_match else is_match;
            if (selected) {
                total_selected += 1;
                file_selected += 1;

                if (quiet) {
                    return common_error.EXIT_SUCCESS;
                }

                if (list_files) {
                    if (is_stdin) {
                        _ = writer.?.writeAll("(standard input)\n") catch {};
                    } else {
                        _ = writer.?.print("{s}\n", .{path}) catch {};
                    }
                    break;
                }

                if (!count_only) {
                    if (print_filename) {
                        _ = writer.?.print("{s}:", .{path}) catch {};
                    }
                    if (line_numbers) {
                        _ = writer.?.print("{d}:", .{line_num}) catch {};
                    }
                    _ = writer.?.print("{s}\n", .{line}) catch {};
                }
            }
        }

        if (count_only) {
            if (print_filename) {
                _ = writer.?.print("{s}:{d}\n", .{ path, file_selected }) catch {};
            } else {
                _ = writer.?.print("{d}\n", .{file_selected}) catch {};
            }
        }
    }

    if (stdout_fw) |*fw| {
        fw.flush() catch {};
    }

    if (quiet) {
        if (had_error) return common_error.EXIT_SYNTAX;
        return common_error.EXIT_FAILURE;
    }

    if (had_error) return common_error.EXIT_SYNTAX;
    return if (total_selected > 0) common_error.EXIT_SUCCESS else common_error.EXIT_FAILURE;
}

pub fn main(init: std.process.Init) u8 {
    const all_args = init.minimal.args.toSlice(init.arena.allocator()) catch |err| {
        common_error.report("grep", null, err);
        return common_error.EXIT_FAILURE;
    };
    const cmd_args = if (all_args.len > 1) all_args[1..] else &.{};
    return run(init.arena.allocator(), cmd_args);
}

// ============================================================================
// POSIX Conformance Tests
// ============================================================================

test "grep: basic matching and exit codes" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const tmp_path = "zig-cache/tmp_test_grep_basic.txt";
    const f = try std.Io.Dir.cwd().createFile(io, tmp_path, .{ .truncate = true });
    try f.writeStreamingAll(io, "apple\nbanana\ncherry\ndate\n");
    f.close(io);
    defer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};

    // Match found -> 0
    try std.testing.expectEqual(@as(u8, 0), run(allocator, &.{ "apple", tmp_path }));

    // Match not found -> 1
    try std.testing.expectEqual(@as(u8, 1), run(allocator, &.{ "grape", tmp_path }));

    // Invert match -> 0
    try std.testing.expectEqual(@as(u8, 0), run(allocator, &.{ "-v", "apple", tmp_path }));
}

test "grep: flags -c, -l, -n, -x, -i, -F" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const tmp_path = "zig-cache/tmp_test_grep_flags.txt";
    const f = try std.Io.Dir.cwd().createFile(io, tmp_path, .{ .truncate = true });
    try f.writeStreamingAll(io, "Hello World\nhello world\nHELLO WORLD\nother\n");
    f.close(io);
    defer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};

    // Fixed string & case-insensitive
    try std.testing.expectEqual(@as(u8, 0), run(allocator, &.{ "-F", "-i", "hello world", tmp_path }));

    // Count mode (-c)
    try std.testing.expectEqual(@as(u8, 0), run(allocator, &.{ "-c", "-i", "hello", tmp_path }));

    // Whole line (-x)
    try std.testing.expectEqual(@as(u8, 0), run(allocator, &.{ "-x", "other", tmp_path }));
    try std.testing.expectEqual(@as(u8, 1), run(allocator, &.{ "-x", "oth", tmp_path }));

    // List mode (-l)
    try std.testing.expectEqual(@as(u8, 0), run(allocator, &.{ "-l", "other", tmp_path }));

    // Line number mode (-n)
    try std.testing.expectEqual(@as(u8, 0), run(allocator, &.{ "-n", "other", tmp_path }));
}

test "grep: quiet mode -q and error handling" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const tmp_path = "zig-cache/tmp_test_grep_quiet.txt";
    const f = try std.Io.Dir.cwd().createFile(io, tmp_path, .{ .truncate = true });
    try f.writeStreamingAll(io, "match_me\n");
    f.close(io);
    defer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};

    // -q returns 0 immediately on match
    try std.testing.expectEqual(@as(u8, 0), run(allocator, &.{ "-q", "match_me", tmp_path }));

    // -q returns 1 on no match
    try std.testing.expectEqual(@as(u8, 1), run(allocator, &.{ "-q", "not_there", tmp_path }));

    // Missing file returns 2 (EXIT_SYNTAX)
    try std.testing.expectEqual(@as(u8, 2), run(allocator, &.{ "pattern", "zig-cache/nonexistent_file_123.txt" }));

    // Missing file with -s still returns 2 (errors suppressed from stderr)
    try std.testing.expectEqual(@as(u8, 2), run(allocator, &.{ "-s", "pattern", "zig-cache/nonexistent_file_123.txt" }));
}

test "grep: multi-pattern -e and pattern file -f" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const tmp_data = "zig-cache/tmp_test_grep_data.txt";
    const f1 = try std.Io.Dir.cwd().createFile(io, tmp_data, .{ .truncate = true });
    try f1.writeStreamingAll(io, "first\nsecond\nthird\n");
    f1.close(io);
    defer std.Io.Dir.cwd().deleteFile(io, tmp_data) catch {};

    const tmp_pats = "zig-cache/tmp_test_grep_pats.txt";
    const f2 = try std.Io.Dir.cwd().createFile(io, tmp_pats, .{ .truncate = true });
    try f2.writeStreamingAll(io, "second\nfourth\n");
    f2.close(io);
    defer std.Io.Dir.cwd().deleteFile(io, tmp_pats) catch {};

    // Multi-pattern via -e
    try std.testing.expectEqual(@as(u8, 0), run(allocator, &.{ "-e", "first", "-e", "third", tmp_data }));

    // Pattern file via -f
    try std.testing.expectEqual(@as(u8, 0), run(allocator, &.{ "-f", tmp_pats, tmp_data }));
}
