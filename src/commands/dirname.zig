//! POSIX.1-2024 (IEEE Std 1003.1-2024) compliant implementation of `dirname`.
//!
//! Specification References:
//! - IEEE Std 1003.1-2024, Shell & Utilities (XCU), Section: `dirname`
//!   - SYNOPSIS: `dirname string`
//!   - OPTIONS: None. Conforms to Section 12.2 Utility Syntax Guidelines
//!     (Guideline 10: '--' ends option processing).
//!   - OPERANDS:
//!       string: A string representing a pathname.
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

fn isTwoSlashRoot(path: []const u8) bool {
    return path.len >= 2 and isSep(path[0]) and isSep(path[1]) and (path.len == 2 or !isSep(path[2]));
}

/// POSIX.1-2024 dirname algorithm:
/// 1. If string is empty, result is ".".
/// 2. If string is "//", result is "//".
/// 3. If string consists entirely of slashes, result is "/".
/// 4. If there are trailing slashes, they are removed.
/// 5. Remove trailing non-slash characters (last component).
/// 6. If no slashes remain, result is ".".
/// 7. Remove trailing slashes from the directory portion, unless remaining is "/" or "//".
pub fn posixDirname(path: []const u8) []const u8 {
    // 1. If string is empty, return "."
    if (path.len == 0) return ".";

    // 2. If "//", return "//"
    if (path.len == 2 and isSep(path[0]) and isSep(path[1])) {
        return path;
    }

    // 3. If string consists entirely of slashes, return "/"
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

    // 5. Remove trailing non-slash characters
    while (end > 0 and !isSep(path[end - 1])) {
        end -= 1;
    }

    // 6. If no slash remaining, result is "."
    if (end == 0) return ".";

    // 7. Remove trailing slashes from directory portion
    if (isTwoSlashRoot(path)) {
        while (end > 2 and isSep(path[end - 1])) {
            end -= 1;
        }
    } else {
        while (end > 1 and isSep(path[end - 1])) {
            end -= 1;
        }
    }

    return path[0..end];
}

pub fn run(allocator: std.mem.Allocator, args: []const [:0]const u8) u8 {
    _ = allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var parser = common_args.ArgParser.init(args);
    while (parser.next("")) |opt| {
        switch (opt) {
            else => {
                common_error.report("dirname", "invalid option", error.InvalidArgument);
                return common_error.EXIT_SYNTAX;
            },
        }
    }

    const operands = parser.remaining();
    if (operands.len == 0) {
        common_error.report("dirname", "missing operand", error.InvalidArgument);
        return common_error.EXIT_SYNTAX;
    }
    if (operands.len > 1) {
        common_error.report("dirname", "extra operand", error.InvalidArgument);
        return common_error.EXIT_SYNTAX;
    }

    const dir = posixDirname(operands[0]);

    const stdout_file = std.Io.File.stdout();
    var buf: [4096]u8 = undefined;
    var fw = stdout_file.writerStreaming(io, &buf);
    const writer = &fw.interface;

    writer.writeAll(dir) catch |err| {
        common_error.report("dirname", null, err);
        return common_error.toExitCode(err);
    };
    writer.writeByte('\n') catch |err| {
        common_error.report("dirname", null, err);
        return common_error.toExitCode(err);
    };
    fw.flush() catch |err| {
        common_error.report("dirname", null, err);
        return common_error.toExitCode(err);
    };

    return common_error.EXIT_SUCCESS;
}

pub fn main(init: std.process.Init) u8 {
    const all_args = init.minimal.args.toSlice(init.arena.allocator()) catch |err| {
        common_error.report("dirname", null, err);
        return common_error.EXIT_FAILURE;
    };
    const cmd_args = if (all_args.len > 1) all_args[1..] else &.{};
    return run(init.arena.allocator(), cmd_args);
}

// ============================================================================
// Unit Tests
// ============================================================================

test "dirname: POSIX.1-2024 table examples" {
    try std.testing.expectEqualStrings(".", posixDirname("usr"));
    try std.testing.expectEqualStrings(".", posixDirname("usr/"));
    try std.testing.expectEqualStrings(".", posixDirname(""));
    try std.testing.expectEqualStrings("/", posixDirname("/"));
    try std.testing.expectEqualStrings("//", posixDirname("//"));
    try std.testing.expectEqualStrings("/", posixDirname("///"));
    try std.testing.expectEqualStrings("/", posixDirname("///a"));
    try std.testing.expectEqualStrings("/", posixDirname("/usr/"));
    try std.testing.expectEqualStrings("/usr", posixDirname("/usr/lib"));
    try std.testing.expectEqualStrings("//usr", posixDirname("//usr//lib//"));
    try std.testing.expectEqualStrings("/home//dwc", posixDirname("/home//dwc//test"));
    try std.testing.expectEqualStrings("/home/dwc", posixDirname("/home/dwc/."));
}

test "dirname: run execution" {
    const code1 = run(std.testing.allocator, &.{"/usr/bin/sort"});
    try std.testing.expectEqual(@as(u8, 0), code1);

    const code2 = run(std.testing.allocator, &.{ "--", "/usr/bin/sort" });
    try std.testing.expectEqual(@as(u8, 0), code2);

    const code3 = run(std.testing.allocator, &.{"-"});
    try std.testing.expectEqual(@as(u8, 0), code3);

    const code4 = run(std.testing.allocator, &.{});
    try std.testing.expectEqual(@as(u8, 2), code4);

    const code5 = run(std.testing.allocator, &.{ "-invalid" });
    try std.testing.expectEqual(@as(u8, 2), code5);

    const code6 = run(std.testing.allocator, &.{ "a", "b" });
    try std.testing.expectEqual(@as(u8, 2), code6);
}
