//! POSIX.1-2024 (IEEE Std 1003.1-2024) compliant implementation of `cut`.
//!
//! Specification References:
//! - IEEE Std 1003.1-2024, Shell & Utilities (XCU), Section: `cut`
//!   - SYNOPSIS:
//!       cut -b list [-n] [file...]
//!       cut -c list [file...]
//!       cut -f list [-d delim] [-s] [file...]
//!   - OPTIONS:
//!       -b list: Cut based on a list of bytes.
//!       -c list: Cut based on a list of characters.
//!       -d delim: Set the field delimiter character (default is tab).
//!       -f list: Cut based on a list of fields separated by delim.
//!       -n: Do not split characters (when used with -b).
//!       -s: Suppress lines with no delimiter characters (when used with -f).
//!   - EXIT STATUS:
//!       0: All input files were output successfully.
//!       >0: An error occurred.

const std = @import("std");
const common_args = @import("../common/args.zig");
const common_error = @import("../common/error.zig");

pub const BUFFER_SIZE: usize = 64 * 1024;

pub const Range = struct {
    low: usize, // 1-based, inclusive
    high: usize, // 1-based, inclusive (std.math.maxInt(usize) for open ended)
};

pub const Mode = enum {
    bytes,
    chars,
    fields,
};

/// Parses a comma- or blank-separated list of ranges (e.g. "1,3-5,-2,8-").
pub fn parseRangeList(allocator: std.mem.Allocator, list_str: []const u8) ![]Range {
    var ranges: std.ArrayList(Range) = .empty;
    defer ranges.deinit(allocator);

    var idx: usize = 0;
    while (idx < list_str.len) {
        // Skip spaces and commas
        while (idx < list_str.len and (list_str[idx] == ' ' or list_str[idx] == '\t' or list_str[idx] == ',')) {
            idx += 1;
        }
        if (idx >= list_str.len) break;

        const start_idx = idx;
        while (idx < list_str.len and list_str[idx] != ' ' and list_str[idx] != '\t' and list_str[idx] != ',') {
            idx += 1;
        }
        const item = list_str[start_idx..idx];
        if (item.len == 0) continue;

        if (std.mem.indexOfScalar(u8, item, '-')) |dash_pos| {
            var low: usize = 1;
            var high: usize = std.math.maxInt(usize);

            if (dash_pos > 0) {
                const low_part = item[0..dash_pos];
                low = std.fmt.parseInt(usize, low_part, 10) catch return error.InvalidRange;
                if (low == 0) return error.InvalidRange;
            }

            if (dash_pos + 1 < item.len) {
                const high_part = item[dash_pos + 1 ..];
                high = std.fmt.parseInt(usize, high_part, 10) catch return error.InvalidRange;
                if (high == 0 or high < low) return error.InvalidRange;
            }

            try ranges.append(allocator, .{ .low = low, .high = high });
        } else {
            const num = std.fmt.parseInt(usize, item, 10) catch return error.InvalidRange;
            if (num == 0) return error.InvalidRange;
            try ranges.append(allocator, .{ .low = num, .high = num });
        }
    }

    if (ranges.items.len == 0) return error.EmptyRange;

    // Sort and merge overlapping / adjacent intervals
    std.mem.sort(Range, ranges.items, {}, struct {
        fn lessThan(_: void, a: Range, b: Range) bool {
            if (a.low != b.low) return a.low < b.low;
            return a.high < b.high;
        }
    }.lessThan);

    var merged: std.ArrayList(Range) = .empty;
    defer merged.deinit(allocator);

    var current = ranges.items[0];
    for (ranges.items[1..]) |next| {
        if (next.low <= current.high or (current.high != std.math.maxInt(usize) and next.low == current.high + 1)) {
            if (next.high > current.high) {
                current.high = next.high;
            }
        } else {
            try merged.append(allocator, current);
            current = next;
        }
    }
    try merged.append(allocator, current);

    return merged.toOwnedSlice(allocator);
}

/// Checks if a 1-based index falls within any merged range.
pub fn isSelected(ranges: []const Range, index: usize) bool {
    for (ranges) |r| {
        if (index >= r.low and index <= r.high) return true;
        if (index < r.low) break;
    }
    return false;
}

pub fn run(allocator: std.mem.Allocator, args: []const [:0]const u8) u8 {
    const io = std.Io.Threaded.global_single_threaded.io();

    var mode: ?Mode = null;
    var range_str: ?[]const u8 = null;
    var delim: []const u8 = "\t";
    var suppress_no_delim = false;
    var do_not_split = false;

    var parser = common_args.ArgParser.init(args);
    while (parser.next("b:c:f:d:sn")) |opt| {
        switch (opt) {
            'b' => {
                if (mode != null) {
                    common_error.report("cut", "only one type of list may be specified", error.InvalidArgument);
                    return common_error.EXIT_SYNTAX;
                }
                mode = .bytes;
                range_str = parser.optarg;
            },
            'c' => {
                if (mode != null) {
                    common_error.report("cut", "only one type of list may be specified", error.InvalidArgument);
                    return common_error.EXIT_SYNTAX;
                }
                mode = .chars;
                range_str = parser.optarg;
            },
            'f' => {
                if (mode != null) {
                    common_error.report("cut", "only one type of list may be specified", error.InvalidArgument);
                    return common_error.EXIT_SYNTAX;
                }
                mode = .fields;
                range_str = parser.optarg;
            },
            'd' => {
                const d = parser.optarg orelse {
                    common_error.report("cut", "missing delimiter", error.InvalidArgument);
                    return common_error.EXIT_SYNTAX;
                };
                if (d.len == 0) {
                    common_error.report("cut", "empty delimiter", error.InvalidArgument);
                    return common_error.EXIT_SYNTAX;
                }
                delim = d;
            },
            's' => suppress_no_delim = true,
            'n' => do_not_split = true,
            else => {
                common_error.report("cut", "invalid option", error.InvalidArgument);
                return common_error.EXIT_SYNTAX;
            },
        }
    }

    if (mode == null or range_str == null) {
        common_error.report("cut", "you must specify a list of bytes, characters, or fields", error.InvalidArgument);
        return common_error.EXIT_SYNTAX;
    }

    const ranges = parseRangeList(allocator, range_str.?) catch |err| {
        common_error.report("cut", "invalid byte/character/field list", err);
        return common_error.EXIT_SYNTAX;
    };
    defer allocator.free(ranges);

    const operands = parser.remaining();
    const default_operands = [_][:0]const u8{"-"};
    const file_list: []const [:0]const u8 = if (operands.len == 0) &default_operands else operands;

    const stdout_file = std.Io.File.stdout();
    var stdout_buf: [BUFFER_SIZE]u8 = undefined;
    var stdout_fw = stdout_file.writerStreaming(io, &stdout_buf);
    const writer = &stdout_fw.interface;
    defer stdout_fw.flush() catch {};

    var had_error = false;

    for (file_list) |path| {
        const is_stdin = std.mem.eql(u8, path, "-");
        const file = if (is_stdin)
            std.Io.File.stdin()
        else
            std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch |err| {
                common_error.report("cut", path, err);
                had_error = true;
                continue;
            };
        defer if (!is_stdin) file.close(io);

        var read_buf: [BUFFER_SIZE]u8 = undefined;
        var r = file.readerStreaming(io, &read_buf);

        while (true) {
            const maybe_line = r.interface.takeDelimiter('\n') catch |err| {
                common_error.report("cut", path, err);
                had_error = true;
                break;
            };

            const raw_line = maybe_line orelse break;
            const line = if (raw_line.len > 0 and raw_line[raw_line.len - 1] == '\r')
                raw_line[0 .. raw_line.len - 1]
            else
                raw_line;

            switch (mode.?) {
                .bytes => {
                    if (do_not_split) {
                        // Multi-byte aware byte cutting (-b with -n)
                        var b_idx: usize = 0;
                        while (b_idx < line.len) {
                            const cp_len = std.unicode.utf8ByteSequenceLength(line[b_idx]) catch 1;
                            const end_idx = @min(b_idx + cp_len, line.len);
                            // Character spans [b_idx + 1, end_idx] (1-based)
                            // A character is output if all of its bytes are selected by the range list
                            var all_selected = true;
                            var k: usize = b_idx + 1;
                            while (k <= end_idx) : (k += 1) {
                                if (!isSelected(ranges, k)) {
                                    all_selected = false;
                                    break;
                                }
                            }
                            if (all_selected) {
                                _ = writer.writeAll(line[b_idx..end_idx]) catch {};
                            }
                            b_idx = end_idx;
                        }
                    } else {
                        // Raw byte cutting
                        for (line, 0..) |byte, idx_0| {
                            if (isSelected(ranges, idx_0 + 1)) {
                                _ = writer.writeByte(byte) catch {};
                            }
                        }
                    }
                    _ = writer.writeByte('\n') catch {};
                },
                .chars => {
                    // Character cutting (-c)
                    var c_idx: usize = 0;
                    var b_idx: usize = 0;
                    while (b_idx < line.len) {
                        c_idx += 1;
                        const cp_len = std.unicode.utf8ByteSequenceLength(line[b_idx]) catch 1;
                        const end_idx = @min(b_idx + cp_len, line.len);
                        if (isSelected(ranges, c_idx)) {
                            _ = writer.writeAll(line[b_idx..end_idx]) catch {};
                        }
                        b_idx = end_idx;
                    }
                    _ = writer.writeByte('\n') catch {};
                },
                .fields => {
                    // Field cutting (-f)
                    const delim_byte = delim[0];
                    if (std.mem.indexOfScalar(u8, line, delim_byte) == null) {
                        // No delimiter found in line
                        if (!suppress_no_delim) {
                            _ = writer.writeAll(line) catch {};
                            _ = writer.writeByte('\n') catch {};
                        }
                    } else {
                        var field_it = std.mem.splitScalar(u8, line, delim_byte);
                        var f_idx: usize = 0;
                        var first_written = false;

                        while (field_it.next()) |field| {
                            f_idx += 1;
                            if (isSelected(ranges, f_idx)) {
                                if (first_written) {
                                    _ = writer.writeAll(delim) catch {};
                                }
                                _ = writer.writeAll(field) catch {};
                                first_written = true;
                            }
                        }
                        _ = writer.writeByte('\n') catch {};
                    }
                },
            }
        }
    }

    return if (had_error) common_error.EXIT_FAILURE else common_error.EXIT_SUCCESS;
}

// ============================================================================
// Unit Tests
// ============================================================================

test "cut: parseRangeList validation" {
    const allocator = std.testing.allocator;

    const r1 = try parseRangeList(allocator, "1,3,5");
    defer allocator.free(r1);
    try std.testing.expectEqual(@as(usize, 3), r1.len);
    try std.testing.expectEqual(@as(usize, 1), r1[0].low);
    try std.testing.expectEqual(@as(usize, 1), r1[0].high);
    try std.testing.expectEqual(@as(usize, 3), r1[1].low);
    try std.testing.expectEqual(@as(usize, 5), r1[2].low);

    // Overlapping and adjacent merge
    const r2 = try parseRangeList(allocator, "1-3,2-5,7-8");
    defer allocator.free(r2);
    try std.testing.expectEqual(@as(usize, 2), r2.len);
    try std.testing.expectEqual(@as(usize, 1), r2[0].low);
    try std.testing.expectEqual(@as(usize, 5), r2[0].high);
    try std.testing.expectEqual(@as(usize, 7), r2[1].low);
    try std.testing.expectEqual(@as(usize, 8), r2[1].high);

    // Open ranges
    const r3 = try parseRangeList(allocator, "-3,6-");
    defer allocator.free(r3);
    try std.testing.expectEqual(@as(usize, 2), r3.len);
    try std.testing.expectEqual(@as(usize, 1), r3[0].low);
    try std.testing.expectEqual(@as(usize, 3), r3[0].high);
    try std.testing.expectEqual(@as(usize, 6), r3[1].low);
    try std.testing.expectEqual(std.math.maxInt(usize), r3[1].high);
}

test "cut: isSelected check" {
    const ranges = [_]Range{
        .{ .low = 2, .high = 4 },
        .{ .low = 7, .high = std.math.maxInt(usize) },
    };

    try std.testing.expect(!isSelected(&ranges, 1));
    try std.testing.expect(isSelected(&ranges, 2));
    try std.testing.expect(isSelected(&ranges, 3));
    try std.testing.expect(isSelected(&ranges, 4));
    try std.testing.expect(!isSelected(&ranges, 5));
    try std.testing.expect(!isSelected(&ranges, 6));
    try std.testing.expect(isSelected(&ranges, 7));
    try std.testing.expect(isSelected(&ranges, 100));
}

test "cut: option validation" {
    const allocator = std.testing.allocator;

    // No list specified
    try std.testing.expectEqual(common_error.EXIT_SYNTAX, run(allocator, &.{ "-d", ":" }));

    // Multiple modes specified
    try std.testing.expectEqual(common_error.EXIT_SYNTAX, run(allocator, &.{ "-b", "1-3", "-f", "2" }));

    // Invalid range string
    try std.testing.expectEqual(common_error.EXIT_SYNTAX, run(allocator, &.{ "-b", "0" }));
    try std.testing.expectEqual(common_error.EXIT_SYNTAX, run(allocator, &.{ "-b", "5-2" }));
}

test "cut: file execution" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const tmp_path = "zig-cache/tmp_cut_test.txt";
    const file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{});
    defer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
    try file.writeStreamingAll(io, "root:x:0:0:root:/root:/bin/bash\nuser:x:1000:1000:user:/home/user:/bin/sh\n");
    file.close(io);

    // Test cutting fields 1 and 6 with delimiter ':'
    const res_f = run(allocator, &.{ "-d", ":", "-f", "1,6", tmp_path });
    try std.testing.expectEqual(common_error.EXIT_SUCCESS, res_f);

    // Test cutting characters 1-4
    const res_c = run(allocator, &.{ "-c", "1-4", tmp_path });
    try std.testing.expectEqual(common_error.EXIT_SUCCESS, res_c);
}
