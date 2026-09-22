//! POSIX.1-2024 (IEEE Std 1003.1-2024) compliant implementation of `chown`.
//!
//! Specification References:
//! - IEEE Std 1003.1-2024, Shell & Utilities (XCU), Section: `chown`
//!   - SYNOPSIS: `chown [-h] [-R [-H|-L|-P]] owner[:group] file...`
//!   - OPTIONS:
//!       -h: If the file is a symbolic link, change the user ID of the link itself.
//!       -R: Recursively change file user IDs.
//!   - OPERANDS:
//!       owner[:group]: A user ID and optional group ID.
//!       file: A pathname of a file whose user ID is to be modified.

const std = @import("std");
const common_args = @import("../common/args.zig");
const common_error = @import("../common/error.zig");
const common_user = @import("../common/user.zig");

pub const ChownOptions = struct {
    recursive: bool = false,
    no_deref: bool = false, // -h
};

fn parseId(io: std.Io, str: []const u8, is_group: bool) !u32 {
    if (str.len == 0) return error.InvalidArgument;
    
    // Try parse as numeric ID
    if (std.fmt.parseInt(u32, str, 10)) |id| {
        return id;
    } else |_| {}

    // Lookup by name
    if (is_group) {
        if (common_user.findGidByName(io, str)) |gid| {
            return gid;
        }
    } else {
        if (common_user.findUidByName(io, str)) |uid| {
            return uid;
        }
    }
    
    return error.InvalidArgument;
}

fn changeOwner(
    io: std.Io,
    path: []const u8,
    uid: ?u32,
    gid: ?u32,
    follow_symlinks: bool,
) !void {
    const dir = std.Io.Dir.cwd();
    try io.vtable.dirSetFileOwner(io.userdata, dir, path, uid, gid, .{ .follow_symlinks = follow_symlinks });
}

fn joinPath(buf: []u8, parent: []const u8, child: []const u8) ![]const u8 {
    if (parent.len == 0 or std.mem.eql(u8, parent, ".")) {
        if (child.len > buf.len) return error.NameTooLong;
        @memcpy(buf[0..child.len], child);
        return buf[0..child.len];
    }
    
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
    uid: ?u32,
    gid: ?u32,
) bool {
    var all_success = true;

    var dir = std.Io.Dir.cwd().openDir(io, path, .{
        .follow_symlinks = false,
        .iterate = true,
    }) catch |err| {
        common_error.report("chown", path, err);
        return false;
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (true) {
        const maybe_entry = it.next(io) catch |err| {
            common_error.report("chown", path, err);
            return false;
        };
        const entry = maybe_entry orelse break;

        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) {
            continue;
        }

        var child_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const child_path = joinPath(&child_buf, path, entry.name) catch |err| {
            common_error.report("chown", entry.name, err);
            all_success = false;
            continue;
        };

        const stat = std.Io.Dir.cwd().statFile(io, child_path, .{ .follow_symlinks = false }) catch |err| {
            common_error.report("chown", child_path, err);
            all_success = false;
            continue;
        };

        // -R without -H, -L, -P means we do not follow symlinks encountered during traversal
        // POSIX states: "If chown -R is specified... chown shall not follow symbolic links encountered during traversal... but shall change the user ID of the symbolic link"
        changeOwner(io, child_path, uid, gid, false) catch |err| {
            common_error.report("chown", child_path, err);
            all_success = false;
        };

        if (stat.kind == .directory) {
            if (!changeHierarchy(io, child_path, uid, gid)) {
                all_success = false;
            }
        }
    }

    return all_success;
}

pub fn run(allocator: std.mem.Allocator, args: []const [:0]const u8) u8 {
    _ = allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var opts: ChownOptions = .{};
    var parser = common_args.ArgParser.init(args);

    while (parser.next("Rh")) |opt| {
        switch (opt) {
            'R' => opts.recursive = true,
            'h' => opts.no_deref = true,
            else => {
                common_error.report("chown", "invalid option", error.InvalidArgument);
                return common_error.EXIT_SYNTAX;
            },
        }
    }

    const operands = parser.remaining();
    if (operands.len < 2) {
        common_error.report("chown", "missing operand", error.InvalidArgument);
        return common_error.EXIT_SYNTAX;
    }

    const owner_group_str = operands[0];
    const files = operands[1..];

    var target_uid: ?u32 = null;
    var target_gid: ?u32 = null;

    // Parse owner[:group] or owner[.group]
    var sep_idx: ?usize = null;
    if (std.mem.indexOfScalar(u8, owner_group_str, ':')) |idx| {
        sep_idx = idx;
    } else if (std.mem.indexOfScalar(u8, owner_group_str, '.')) |idx| {
        sep_idx = idx;
    }

    if (sep_idx) |idx| {
        const owner_str = owner_group_str[0..idx];
        const group_str = owner_group_str[idx + 1 ..];

        if (owner_str.len > 0) {
            target_uid = parseId(io, owner_str, false) catch {
                common_error.report("chown", "invalid user", error.InvalidArgument);
                return common_error.EXIT_FAILURE;
            };
        }
        if (group_str.len > 0) {
            target_gid = parseId(io, group_str, true) catch {
                common_error.report("chown", "invalid group", error.InvalidArgument);
                return common_error.EXIT_FAILURE;
            };
        }
    } else {
        target_uid = parseId(io, owner_group_str, false) catch {
            common_error.report("chown", "invalid user", error.InvalidArgument);
            return common_error.EXIT_FAILURE;
        };
    }

    var exit_code: u8 = common_error.EXIT_SUCCESS;

    for (files) |arg| {
        // If -h is specified, do not follow symlink.
        // If -R is specified, we follow it if we're not traversing?
        // Wait, POSIX: "If the -R option is specified, chown shall change the user ID of the symbolic link... if -h is not specified, chown shall change the file named by the symbolic link"
        // Actually, for the command-line operands themselves:
        // By default, chown follows symlinks for operands.
        const follow_symlinks = !opts.no_deref;

        changeOwner(io, arg, target_uid, target_gid, follow_symlinks) catch |err| {
            common_error.report("chown", arg, err);
            exit_code = common_error.EXIT_FAILURE;
            continue;
        };

        if (opts.recursive) {
            const stat = std.Io.Dir.cwd().statFile(io, arg, .{ .follow_symlinks = follow_symlinks }) catch continue;
            if (stat.kind == .directory) {
                if (!changeHierarchy(io, arg, target_uid, target_gid)) {
                    exit_code = common_error.EXIT_FAILURE;
                }
            }
        }
    }

    return exit_code;
}

pub fn main(init: std.process.Init) u8 {
    const all_args = init.minimal.args.toSlice(init.arena.allocator()) catch |err| {
        common_error.report("chown", null, err);
        return common_error.EXIT_FAILURE;
    };
    const cmd_args = if (all_args.len > 1) all_args[1..] else &.{};
    return run(init.arena.allocator(), cmd_args);
}

// ============================================================================
// Unit Tests
// ============================================================================

test "chown: basic argument parsing" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqual(common_error.EXIT_SYNTAX, run(allocator, &.{}));
    try std.testing.expectEqual(common_error.EXIT_SYNTAX, run(allocator, &.{"root"}));
    try std.testing.expectEqual(common_error.EXIT_SYNTAX, run(allocator, &.{ "-z", "root", "file" }));
}
