//! POSIX.1-2024 (IEEE Std 1003.1-2024) compliant implementation of `basename`.
//!
//! Specification References:
//! - IEEE Std 1003.1-2024, Shell & Utilities (XCU), Section: `basename`
//!   - SYNOPSIS: `basename string [suffix]`
//!   - OPTIONS: None. Conforms to Section 12.2 Utility Syntax Guidelines
//!     (Guideline 10: '--' ends option processing).
//!   - OPERANDS:
//!       string: A string representing a pathname or filename.
//!       suffix: An optional suffix string to strip from the resulting basename.
//!   - STDOUT: "%s\n", <resulting string>
//!   - STDERR: Used only for diagnostic messages.
//!   - EXIT STATUS:
//!       0: Successful completion.
//!       >0: An error occurred.
//!
//! Resource Constraint:
//! - Zero dynamic allocations. Operates on slices and uses fixed-size stack buffers.

const std = @import("std");

const builtin_is_windows = @import("builtin").os.tag == .windows;

fn isSep(c: u8) bool {
    return c == '/' or (builtin_is_windows and c == '\\');
}

/// POSIX.1-2024 basename algorithm:
/// 1. If string is empty, the result is an empty string.
/// 2. If string is "//", the result is "//".
/// 3. If string consists entirely of slashes, the result is a single slash.
/// 4. If there are trailing slashes, they are removed.
/// 5. Remove prefix up to and including the last slash.
/// 6. If suffix operand is present, is not identical to the remaining characters,
///    and is identical to a suffix of the remaining characters, remove suffix.
pub fn posixBasename(path: []const u8, suffix: ?[]const u8) []const u8 {
    // 1. If string is empty, return empty string
    if (path.len == 0) return "";

    // 2. If "//", return "//"
    if (path.len == 2 and isSep(path[0]) and isSep(path[1])) {
        return path;
    }

    // 3. If string consists entirely of slashes, return single slash
    var all_slashes = true;
    for (path) |c| {
        if (!isSep(c)) {
            all_slashes = false;
            break;
        }
    }
    if (all_slashes) {
        return path[0..1];
    }

    // 4. Remove trailing slashes
    var end = path.len;
    while (end > 0 and isSep(path[end - 1])) {
        end -= 1;
    }
    const trimmed = path[0..end];

    // 5. Remove prefix up to and including last slash
    var start: usize = 0;
    var i: usize = trimmed.len;
    while (i > 0) {
        i -= 1;
        if (isSep(trimmed[i])) {
            start = i + 1;
            break;
        }
    }
    var res = trimmed[start..];

    // 6. Suffix removal
    if (suffix) |sfx| {
        if (sfx.len > 0 and sfx.len < res.len and std.mem.endsWith(u8, res, sfx)) {
            res = res[0 .. res.len - sfx.len];
        }
    }

    return res;
}

fn printError(io: std.Io, comptime msg: []const u8) void {
    const stderr_file = std.Io.File.stderr();
    var err_buf: [256]u8 = undefined;
    var err_fw = stderr_file.writerStreaming(io, &err_buf);
    const err_writer = &err_fw.interface;
    _ = err_writer.writeAll("basename: " ++ msg) catch {};
    _ = err_fw.flush() catch {};
}

/// Entry point matching the ziggybox command interface standard:
/// `pub fn run(allocator: std.mem.Allocator, args: []const [:0]const u8) u8`
pub fn run(allocator: std.mem.Allocator, args: []const [:0]const u8) u8 {
    _ = allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var operands_start: usize = 0;
    if (args.len > 0) {
        const first_arg = args[0];
        if (std.mem.eql(u8, first_arg, "--")) {
            operands_start = 1;
        } else if (first_arg.len > 1 and first_arg[0] == '-') {
            printError(io, "unknown option\n");
            return 1;
        }
    }

    const operands = args[operands_start..];
    if (operands.len == 0) {
        printError(io, "missing operand\n");
        return 1;
    }
    if (operands.len > 2) {
        printError(io, "extra operand\n");
        return 1;
    }

    const path = operands[0];
    const suffix = if (operands.len == 2) operands[1] else null;
    const base = posixBasename(path, suffix);

    const stdout_file = std.Io.File.stdout();
    var buf: [4096]u8 = undefined;
    var fw = stdout_file.writerStreaming(io, &buf);
    const writer = &fw.interface;

    writer.writeAll(base) catch {
        printError(io, "write error\n");
        return 1;
    };
    writer.writeByte('\n') catch {
        printError(io, "write error\n");
        return 1;
    };
    fw.flush() catch {
        printError(io, "write error\n");
        return 1;
    };

    return 0;
}

pub fn main(init: std.process.Init) u8 {
    const all_args = init.minimal.args.toSlice(init.arena.allocator()) catch {
        printError(init.io, "out of memory\n");
        return 1;
    };
    const cmd_args = if (all_args.len > 1) all_args[1..] else &.{};
    return run(init.arena.allocator(), cmd_args);
}

// ============================================================================
// Unit Tests
// ============================================================================

test "basename: POSIX.1-2024 table examples" {
    try std.testing.expectEqualStrings("usr", posixBasename("usr", null));
    try std.testing.expectEqualStrings("usr", posixBasename("usr/", null));
    try std.testing.expectEqualStrings("", posixBasename("", null));
    try std.testing.expectEqualStrings("/", posixBasename("/", null));
    try std.testing.expectEqualStrings("//", posixBasename("//", null));
    try std.testing.expectEqualStrings("/", posixBasename("///", null));
    try std.testing.expectEqualStrings("usr", posixBasename("/usr/", null));
    try std.testing.expectEqualStrings("lib", posixBasename("/usr/lib", null));
    try std.testing.expectEqualStrings("lib", posixBasename("//usr//lib//", null));
    try std.testing.expectEqualStrings("test", posixBasename("/home//dwc//test", null));
    try std.testing.expectEqualStrings("test", posixBasename("/home/.././test", null));
    try std.testing.expectEqualStrings(".", posixBasename("/home/dwc/.", null));
}

test "basename: suffix handling" {
    try std.testing.expectEqualStrings("cat", posixBasename("/usr/src/cmd/cat.c", ".c"));
    try std.testing.expectEqualStrings("cat", posixBasename("cat.c", ".c"));
    try std.testing.expectEqualStrings(".c", posixBasename(".c", ".c"));
    try std.testing.expectEqualStrings("cat.c", posixBasename("cat.c", ".h"));
    try std.testing.expectEqualStrings("cat.c", posixBasename("cat.c", ""));
}

test "basename: run execution" {
    const code1 = run(std.testing.allocator, &.{"/usr/bin/sort"});
    try std.testing.expectEqual(@as(u8, 0), code1);

    const code2 = run(std.testing.allocator, &.{ "--", "/usr/bin/sort" });
    try std.testing.expectEqual(@as(u8, 0), code2);

    const code3 = run(std.testing.allocator, &.{ "sort.c", ".c" });
    try std.testing.expectEqual(@as(u8, 0), code3);

    const code4 = run(std.testing.allocator, &.{"-"});
    try std.testing.expectEqual(@as(u8, 0), code4);

    const code5 = run(std.testing.allocator, &.{});
    try std.testing.expectEqual(@as(u8, 1), code5);

    const code6 = run(std.testing.allocator, &.{ "-invalid" });
    try std.testing.expectEqual(@as(u8, 1), code6);

    const code7 = run(std.testing.allocator, &.{ "a", "b", "c" });
    try std.testing.expectEqual(@as(u8, 1), code7);
}
