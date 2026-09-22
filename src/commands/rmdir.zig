//! POSIX.1-2024 (IEEE Std 1003.1-2024) compliant implementation of `rmdir`.
//!
//! Specification References:
//! - IEEE Std 1003.1-2024, Shell & Utilities (XCU), Section: `rmdir`
//!   - SYNOPSIS: `rmdir [-p] dir...`
//!   - OPTIONS:
//!       -p: Remove all directories in a pathname. For each dir operand:
//!           1. The directory entry it names shall be removed.
//!           2. If dir includes more than one pathname component, effects
//!              equivalent to `rmdir -p $(dirname dir)` shall occur.
//!   - OPERANDS:
//!       dir: A pathname of an empty directory to be removed.
//!   - STDERR: Used only for diagnostic messages.
//!   - EXIT STATUS:
//!       0: Each directory entry specified by a dir operand was removed successfully.
//!       >0: An error occurred.
//!
//! Resource Constraint:
//! - Zero dynamic heap allocations in core logic (stack buffers only).

const std = @import("std");
const common_args = @import("../common/args.zig");
const common_error = @import("../common/error.zig");

/// Strips redundant trailing slashes from path, preserving root "/" or "//".
pub fn stripTrailingSlashes(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and path[end - 1] == '/') {
        if (end == 2 and path[0] == '/') break; // preserve "//"
        end -= 1;
    }
    return path[0..end];
}

/// Compute parent directory component of a path, or null if no parent component exists.
pub fn getParentDir(path: []const u8) ?[]const u8 {
    var end = path.len;
    while (end > 0 and path[end - 1] == '/') {
        end -= 1;
    }
    while (end > 0 and path[end - 1] != '/') {
        end -= 1;
    }
    if (end == 0) return null;

    while (end > 1 and path[end - 1] == '/') {
        if (end == 2 and path[0] == '/') break;
        end -= 1;
    }
    return path[0..end];
}

/// Remove a single directory entry.
fn removeSingleDir(io: std.Io, path: []const u8) !void {
    try std.Io.Dir.cwd().deleteDir(io, path);
}

/// Remove a directory and iteratively remove parent components with `rmdir -p`.
/// Returns true if all components were removed, false if an error occurred.
fn removePathRecursive(io: std.Io, raw_path: []const u8) bool {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const initial = stripTrailingSlashes(raw_path);
    if (initial.len == 0 or initial.len > path_buf.len) {
        common_error.report("rmdir", raw_path, error.BadPathName);
        return false;
    }

    @memcpy(path_buf[0..initial.len], initial);
    var current_len: usize = initial.len;

    while (true) {
        const cur = path_buf[0..current_len];
        removeSingleDir(io, cur) catch |err| {
            common_error.report("rmdir", cur, err);
            return false;
        };

        const parent = getParentDir(cur);
        if (parent == null) break;
        const p = parent.?;

        // Stop if parent is root or current working directory
        if (p.len == 0 or std.mem.eql(u8, p, ".") or std.mem.eql(u8, p, "/") or std.mem.eql(u8, p, "//")) {
            break;
        }

        current_len = p.len;
    }

    return true;
}

pub fn run(allocator: std.mem.Allocator, args: []const [:0]const u8) u8 {
    _ = allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var opt_p = false;

    var parser = common_args.ArgParser.init(args);
    while (parser.next("p")) |opt| {
        switch (opt) {
            'p' => opt_p = true,
            else => {
                common_error.report("rmdir", "invalid option", error.InvalidArgument);
                return common_error.EXIT_SYNTAX;
            },
        }
    }

    const operands = parser.remaining();
    if (operands.len == 0) {
        common_error.report("rmdir", "missing operand", error.InvalidArgument);
        return common_error.EXIT_SYNTAX;
    }

    var exit_code: u8 = common_error.EXIT_SUCCESS;

    for (operands) |dir_arg| {
        if (dir_arg.len == 0) {
            common_error.report("rmdir", "failed to remove ''", error.FileNotFound);
            exit_code = common_error.EXIT_FAILURE;
            continue;
        }

        if (opt_p) {
            if (!removePathRecursive(io, dir_arg)) {
                exit_code = common_error.EXIT_FAILURE;
            }
        } else {
            removeSingleDir(io, dir_arg) catch |err| {
                common_error.report("rmdir", dir_arg, err);
                exit_code = common_error.EXIT_FAILURE;
            };
        }
    }

    return exit_code;
}

pub fn main(init: std.process.Init) u8 {
    const all_args = init.minimal.args.toSlice(init.arena.allocator()) catch |err| {
        common_error.report("rmdir", null, err);
        return common_error.EXIT_FAILURE;
    };
    const cmd_args = if (all_args.len > 1) all_args[1..] else &.{};
    return run(init.arena.allocator(), cmd_args);
}

// ============================================================================
// Unit Tests
// ============================================================================

test "rmdir: strip trailing slashes" {
    try std.testing.expectEqualStrings("a/b/c", stripTrailingSlashes("a/b/c/"));
    try std.testing.expectEqualStrings("a/b/c", stripTrailingSlashes("a/b/c///"));
    try std.testing.expectEqualStrings("/", stripTrailingSlashes("/"));
    try std.testing.expectEqualStrings("//", stripTrailingSlashes("//"));
    try std.testing.expectEqualStrings("/a", stripTrailingSlashes("/a/"));
}

test "rmdir: getParentDir computation" {
    try std.testing.expectEqualStrings("a/b", getParentDir("a/b/c").?);
    try std.testing.expectEqualStrings("a", getParentDir("a/b").?);
    try std.testing.expect(getParentDir("a") == null);
    try std.testing.expectEqualStrings("/a/b", getParentDir("/a/b/c").?);
    try std.testing.expectEqualStrings("/a", getParentDir("/a/b").?);
    try std.testing.expectEqualStrings("/", getParentDir("/a").?);
    try std.testing.expectEqualStrings("a", getParentDir("a//b").?);
}

test "rmdir: argument parsing and missing operands" {
    const allocator = std.testing.allocator;
    const exit_missing = run(allocator, &.{});
    try std.testing.expectEqual(common_error.EXIT_SYNTAX, exit_missing);

    const exit_invalid_opt = run(allocator, &.{"-z"});
    try std.testing.expectEqual(common_error.EXIT_SYNTAX, exit_invalid_opt);

    const exit_invalid_flag = run(allocator, &.{ "-p", "-m", "foo" });
    try std.testing.expectEqual(common_error.EXIT_SYNTAX, exit_invalid_flag);
}
