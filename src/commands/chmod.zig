//! POSIX.1-2024 (IEEE Std 1003.1-2024) compliant implementation of `chmod`.
//!
//! Specification References:
//! - IEEE Std 1003.1-2024, Shell & Utilities (XCU), Section: `chmod`
//!   - SYNOPSIS: `chmod [-R] mode file...`
//!   - OPTIONS:
//!       -R: Recursively change file mode bits. For each file operand that names
//!           a directory, chmod alters the mode of the directory and all files in it.
//!           If a symbolic link is encountered during traversal, it is not followed.
//!   - OPERANDS:
//!       mode: Represents the change to be made to the file mode bits of each file (octal or symbolic).
//!       file: A pathname of a file whose mode bits shall be modified.
//!   - EXIT STATUS:
//!       0: Successful completion.
//!       >0: An error occurred.

const std = @import("std");
const common_args = @import("../common/args.zig");
const common_error = @import("../common/error.zig");
const common_mode = @import("../common/mode.zig");

pub const ChmodOptions = struct {
    recursive: bool = false,
};

/// Retrieve the process file mode creation mask (umask).
pub fn getProcessUmask() std.posix.mode_t {
    const builtin = @import("builtin");
    if (builtin.os.tag == .linux) {
        const cur = std.os.linux.syscall1(.umask, 0);
        _ = std.os.linux.syscall1(.umask, cur);
        return @as(std.posix.mode_t, @intCast(cur));
    } else if (builtin.link_libc) {
        const cur = std.c.umask(0);
        _ = std.c.umask(cur);
        return cur;
    } else {
        return 0o022; // Standard default umask fallback
    }
}

fn toPermissions(mode: std.posix.mode_t) std.Io.Dir.Permissions {
    if (@hasDecl(std.Io.Dir.Permissions, "fromMode")) {
        return std.Io.Dir.Permissions.fromMode(mode);
    } else {
        return .default_dir;
    }
}

fn changeMode(
    io: std.Io,
    path: []const u8,
    mode_str: []const u8,
    umask_val: std.posix.mode_t,
    follow_symlinks: bool,
) !void {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = follow_symlinks }) catch |err| {
        return err;
    };

    const current_mode = if (@hasDecl(std.Io.Dir.Permissions, "toMode"))
        stat.permissions.toMode()
    else
        @intFromEnum(stat.permissions);

    const new_mode = common_mode.parseMode(mode_str, current_mode, umask_val);
    if (new_mode == null) {
        return error.InvalidArgument;
    }

    const perms = toPermissions(new_mode.?);
    try std.Io.Dir.cwd().setFilePermissions(io, path, perms, .{ .follow_symlinks = follow_symlinks });
}

fn joinPath(buf: []u8, parent: []const u8, child: []const u8) ![]const u8 {
    if (parent.len == 0 or std.mem.eql(u8, parent, ".")) {
        if (child.len > buf.len) return error.NameTooLong;
        @memcpy(buf[0..child.len], child);
        return buf[0..child.len];
    }
    
    // Simple join
    var end = parent.len;
    while (end > 1 and parent[end - 1] == '/') {
        if (end == 2 and parent[0] == '/') break;
        end -= 1;
    }
    const trimmed = parent[0..end];
    
    if (std.mem.eql(u8, trimmed, "/")) {
        return std.fmt.bufPrint(buf, "/{s}", .{child});
    } else {
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ trimmed, child });
    }
}

fn changeHierarchy(
    io: std.Io,
    path: []const u8,
    mode_str: []const u8,
    umask_val: std.posix.mode_t,
) bool {
    var all_success = true;

    var dir = std.Io.Dir.cwd().openDir(io, path, .{
        .follow_symlinks = false,
        .iterate = true,
    }) catch |err| {
        common_error.report("chmod", path, err);
        return false;
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (true) {
        const maybe_entry = it.next(io) catch |err| {
            common_error.report("chmod", path, err);
            return false;
        };
        const entry = maybe_entry orelse break;

        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) {
            continue;
        }

        var child_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const child_path = joinPath(&child_buf, path, entry.name) catch |err| {
            common_error.report("chmod", entry.name, err);
            all_success = false;
            continue;
        };

        const stat = std.Io.Dir.cwd().statFile(io, child_path, .{ .follow_symlinks = false }) catch |err| {
            common_error.report("chmod", child_path, err);
            all_success = false;
            continue;
        };

        if (stat.kind == .sym_link) {
            // POSIX: do not change symlink mode during traversal
            continue;
        }

        changeMode(io, child_path, mode_str, umask_val, false) catch |err| {
            common_error.report("chmod", child_path, err);
            all_success = false;
        };

        if (stat.kind == .directory) {
            if (!changeHierarchy(io, child_path, mode_str, umask_val)) {
                all_success = false;
            }
        }
    }

    return all_success;
}

pub fn run(allocator: std.mem.Allocator, args: []const [:0]const u8) u8 {
    _ = allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var opts: ChmodOptions = .{};
    var parser = common_args.ArgParser.init(args);

    while (parser.next("R")) |opt| {
        switch (opt) {
            'R' => opts.recursive = true,
            else => {
                common_error.report("chmod", "invalid option", error.InvalidArgument);
                return common_error.EXIT_SYNTAX;
            },
        }
    }

    const operands = parser.remaining();
    if (operands.len < 2) {
        common_error.report("chmod", "missing operand", error.InvalidArgument);
        return common_error.EXIT_SYNTAX;
    }

    const mode_str = operands[0];
    const files = operands[1..];
    const umask_val = getProcessUmask();

    // Verify mode syntax by checking if it parses against 0
    if (common_mode.parseMode(mode_str, 0, umask_val) == null) {
        common_error.report("chmod", "invalid mode", error.InvalidArgument);
        return common_error.EXIT_SYNTAX;
    }

    var exit_code: u8 = common_error.EXIT_SUCCESS;

    for (files) |arg| {
        changeMode(io, arg, mode_str, umask_val, true) catch |err| {
            common_error.report("chmod", arg, err);
            exit_code = common_error.EXIT_FAILURE;
            continue;
        };

        if (opts.recursive) {
            const stat = std.Io.Dir.cwd().statFile(io, arg, .{ .follow_symlinks = true }) catch continue;
            if (stat.kind == .directory) {
                if (!changeHierarchy(io, arg, mode_str, umask_val)) {
                    exit_code = common_error.EXIT_FAILURE;
                }
            }
        }
    }

    return exit_code;
}

pub fn main(init: std.process.Init) u8 {
    const all_args = init.minimal.args.toSlice(init.arena.allocator()) catch |err| {
        common_error.report("chmod", null, err);
        return common_error.EXIT_FAILURE;
    };
    const cmd_args = if (all_args.len > 1) all_args[1..] else &.{};
    return run(init.arena.allocator(), cmd_args);
}

// ============================================================================
// Unit Tests
// ============================================================================

test "chmod: basic argument parsing" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqual(common_error.EXIT_SYNTAX, run(allocator, &.{}));
    try std.testing.expectEqual(common_error.EXIT_SYNTAX, run(allocator, &.{"755"}));
    try std.testing.expectEqual(common_error.EXIT_SYNTAX, run(allocator, &.{ "-z", "755", "file" }));
    try std.testing.expectEqual(common_error.EXIT_SYNTAX, run(allocator, &.{ "invalid_mode", "file" }));
}

test "chmod: successful operations" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const allocator = std.testing.allocator;

    const test_dir = "zig-cache/tmp_test_chmod";
    std.Io.Dir.cwd().createDirPath(io, test_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, test_dir) catch {};

    const test_file = "zig-cache/tmp_test_chmod/file.txt";
    const f = try std.Io.Dir.cwd().createFile(io, test_file, .{});
    f.close(io);

    // Apply octal mode
    try std.testing.expectEqual(common_error.EXIT_SUCCESS, run(allocator, &.{ "0700", test_file }));
    const stat1 = try std.Io.Dir.cwd().statFile(io, test_file, .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o700), stat1.permissions.toMode() & 0o7777);

    // Apply symbolic mode
    try std.testing.expectEqual(common_error.EXIT_SUCCESS, run(allocator, &.{ "u=rw,go=r", test_file }));
    const stat2 = try std.Io.Dir.cwd().statFile(io, test_file, .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o644), stat2.permissions.toMode() & 0o7777);
}
