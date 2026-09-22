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
const common_args = @import("../common/args.zig");
const common_error = @import("../common/error.zig");

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

pub fn run(allocator: std.mem.Allocator, args: []const [:0]const u8) u8 {
    _ = allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var parser = common_args.ArgParser.init(args);
    while (parser.next("")) |opt| {
        switch (opt) {
            else => {
                common_error.report("basename", "invalid option", error.InvalidArgument);
                return common_error.EXIT_SYNTAX;
            },
        }
    }

    const operands = parser.remaining();
    if (operands.len == 0) {
        common_error.report("basename", "missing operand", error.InvalidArgument);
        return common_error.EXIT_SYNTAX;
    }
    if (operands.len > 2) {
        common_error.report("basename", "extra operand", error.InvalidArgument);
        return common_error.EXIT_SYNTAX;
    }

    const path = operands[0];
    const suffix = if (operands.len == 2) operands[1] else null;
    const base = posixBasename(path, suffix);

    const stdout_file = std.Io.File.stdout();
    var buf: [4096]u8 = undefined;
    var fw = stdout_file.writerStreaming(io, &buf);
    const writer = &fw.interface;

    writer.writeAll(base) catch |err| {
        common_error.report("basename", null, err);
        return common_error.toExitCode(err);
    };
    writer.writeByte('\n') catch |err| {
        common_error.report("basename", null, err);
        return common_error.toExitCode(err);
    };
    fw.flush() catch |err| {
        common_error.report("basename", null, err);
        return common_error.toExitCode(err);
    };

    return common_error.EXIT_SUCCESS;
}

pub fn main(init: std.process.Init) u8 {
    const all_args = init.minimal.args.toSlice(init.arena.allocator()) catch |err| {
        common_error.report("basename", null, err);
        return common_error.EXIT_FAILURE;
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
    try std.testing.expectEqual(@as(u8, 2), code5);

    const code6 = run(std.testing.allocator, &.{ "-invalid" });
    try std.testing.expectEqual(@as(u8, 2), code6);

    const code7 = run(std.testing.allocator, &.{ "a", "b", "c" });
    try std.testing.expectEqual(@as(u8, 2), code7);
}
