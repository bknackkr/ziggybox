//! POSIX.1-2024 (IEEE Std 1003.1-2024) compliant implementation of `ln`.
//!
//! Specification References:
//! - IEEE Std 1003.1-2024, Shell & Utilities (XCU), Section: `ln`
//!   - SYNOPSIS:
//!       ln [-fs] [-L|-P] source_file target_file
//!       ln [-fs] [-L|-P] source_file... target_dir
//!   - OPTIONS:
//!       -f: Force existing destination pathnames to be removed to allow the link.
//!       -L: For each source_file operand that names a file of type symbolic link,
//!           create a hard link to the file referenced by the symbolic link.
//!       -P: For each source_file operand that names a file of type symbolic link,
//!           create a hard link to the symbolic link itself.
//!       -s: Create symbolic links instead of hard links. If -s is specified,
//!           -L and -P are silently ignored.
//!   - OPERANDS:
//!       source_file: A pathname of a file to be linked.
//!       target_file: The pathname of the new directory entry to be created.
//!       target_dir: A pathname of an existing directory in which new entries are created.
//!   - EXIT STATUS:
//!       0: Successful completion.
//!       >0: An error occurred.
//!
//! Resource Constraint:
//! - Zero dynamic heap allocations in core logic (stack buffers only).

const std = @import("std");
const common_args = @import("../common/args.zig");
const common_error = @import("../common/error.zig");

/// Extract the last pathname component of a path, ignoring trailing slashes.
pub fn getLastComponent(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and path[end - 1] == '/') {
        if (end == 2 and path[0] == '/') break; // preserve "//"
        end -= 1;
    }
    if (end == 0) return "";
    const trimmed = path[0..end];
    if (std.mem.lastIndexOfScalar(u8, trimmed, '/')) |idx| {
        if (idx + 1 == end) return trimmed;
        return trimmed[idx + 1 ..];
    }
    return trimmed;
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

/// Test whether target path represents an existing directory (following symlinks).
fn isExistingDirectory(io: std.Io, path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = true }) catch return false;
    return stat.kind == .directory;
}

/// Test whether source and destination refer to the same directory entry.
pub fn isSameEntry(io: std.Io, src: []const u8, dst: []const u8) bool {
    if (std.mem.eql(u8, src, dst)) return true;

    const src_base = getLastComponent(src);
    const dst_base = getLastComponent(dst);
    if (!std.mem.eql(u8, src_base, dst_base)) return false;

    const src_dir = getParentDir(src) orelse ".";
    const dst_dir = getParentDir(dst) orelse ".";

    const src_dstat = std.Io.Dir.cwd().statFile(io, src_dir, .{ .follow_symlinks = true }) catch return false;
    const dst_dstat = std.Io.Dir.cwd().statFile(io, dst_dir, .{ .follow_symlinks = true }) catch return false;

    return src_dstat.inode == dst_dstat.inode;
}

/// Format destination path into a fixed buffer: dir + "/" + comp.
fn formatDestPath(buf: []u8, dir: []const u8, comp: []const u8) ![]const u8 {
    if (dir.len > 0 and dir[dir.len - 1] == '/') {
        return std.fmt.bufPrint(buf, "{s}{s}", .{ dir, comp });
    } else {
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ dir, comp });
    }
}

/// Execute ln utility per IEEE Std 1003.1-2024.
pub fn run(allocator: std.mem.Allocator, args: []const [:0]const u8) u8 {
    _ = allocator;

    var opt_f = false;
    var opt_s = false;
    var opt_follow = false; // default is -P per Linux / standard conventions

    var parser = common_args.ArgParser.init(args);

    while (parser.next("fsLP")) |opt| {
        switch (opt) {
            'f' => opt_f = true,
            's' => opt_s = true,
            'L' => opt_follow = true,
            'P' => opt_follow = false,
            '?' => {
                common_error.report("ln", "invalid option", error.InvalidArgument);
                return common_error.EXIT_SYNTAX;
            },
            ':' => {
                common_error.report("ln", "missing argument", error.InvalidArgument);
                return common_error.EXIT_SYNTAX;
            },
            else => {
                common_error.report("ln", "invalid option", error.InvalidArgument);
                return common_error.EXIT_SYNTAX;
            },
        }
    }

    const operands = parser.remaining();
    if (operands.len < 2) {
        common_error.report("ln", "missing operand", error.InvalidArgument);
        return common_error.EXIT_SYNTAX;
    }

    const io = std.Io.Threaded.global_single_threaded.io();
    const final_operand = operands[operands.len - 1];
    const target_is_dir = isExistingDirectory(io, final_operand);

    if (operands.len > 2 and !target_is_dir) {
        common_error.report("ln", "target is not a directory", error.NotDir);
        return common_error.EXIT_FAILURE;
    }

    const source_files = operands[0 .. operands.len - 1];
    var exit_code: u8 = common_error.EXIT_SUCCESS;

    for (source_files) |src| {
        var dest_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const dest_path = if (target_is_dir) blk: {
            const comp = getLastComponent(src);
            break :blk formatDestPath(&dest_buf, final_operand, comp) catch |err| {
                common_error.report("ln", final_operand, err);
                exit_code = common_error.EXIT_FAILURE;
                continue;
            };
        } else final_operand;

        // Check if destination exists without following symlinks
        const dest_stat = std.Io.Dir.cwd().statFile(io, dest_path, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => null,
            else => null,
        };

        if (dest_stat != null) {
            if (!opt_f) {
                common_error.report("ln", dest_path, error.PathAlreadyExists);
                exit_code = common_error.EXIT_FAILURE;
                continue;
            }

            // If destination names the same directory entry as src, report error and do not unlink
            if (isSameEntry(io, src, dest_path)) {
                common_error.report("ln", dest_path, error.PathAlreadyExists);
                exit_code = common_error.EXIT_FAILURE;
                continue;
            }

            // Unlink destination before linking
            std.Io.Dir.cwd().deleteFile(io, dest_path) catch |err| {
                common_error.report("ln", dest_path, err);
                exit_code = common_error.EXIT_FAILURE;
                continue;
            };
        }

        if (opt_s) {
            std.Io.Dir.cwd().symLink(io, src, dest_path, .{}) catch |err| {
                common_error.report("ln", dest_path, err);
                exit_code = common_error.EXIT_FAILURE;
                continue;
            };
        } else {
            std.Io.Dir.cwd().hardLink(src, .cwd(), dest_path, io, .{ .follow_symlinks = opt_follow }) catch |err| {
                common_error.report("ln", dest_path, err);
                exit_code = common_error.EXIT_FAILURE;
                continue;
            };
        }
    }

    return exit_code;
}

pub fn main(init: std.process.Init) u8 {
    const all_args = init.minimal.args.toSlice(init.arena.allocator()) catch |err| {
        common_error.report("ln", null, err);
        return common_error.EXIT_FAILURE;
    };
    const cmd_args = if (all_args.len > 1) all_args[1..] else &.{};
    return run(init.arena.allocator(), cmd_args);
}

// ============================================================================
// Unit Tests
// ============================================================================

test "ln: getLastComponent extraction" {
    try std.testing.expectEqualStrings("foo", getLastComponent("foo"));
    try std.testing.expectEqualStrings("foo", getLastComponent("dir/foo"));
    try std.testing.expectEqualStrings("foo", getLastComponent("dir/foo/"));
    try std.testing.expectEqualStrings("foo", getLastComponent("dir/foo///"));
    try std.testing.expectEqualStrings("/", getLastComponent("/"));
    try std.testing.expectEqualStrings("//", getLastComponent("//"));
}

test "ln: getParentDir computation" {
    try std.testing.expectEqualStrings("a", getParentDir("a/b").?);
    try std.testing.expectEqualStrings("a", getParentDir("a/b/").?);
    try std.testing.expectEqualStrings("/", getParentDir("/a").?);
    try std.testing.expect(getParentDir("a") == null);
}

test "ln: argument parsing and missing operands" {
    const allocator = std.testing.allocator;

    const exit_missing0 = run(allocator, &.{});
    try std.testing.expectEqual(common_error.EXIT_SYNTAX, exit_missing0);

    const exit_missing1 = run(allocator, &.{"file1"});
    try std.testing.expectEqual(common_error.EXIT_SYNTAX, exit_missing1);

    const exit_invalid_opt = run(allocator, &.{"-z"});
    try std.testing.expectEqual(common_error.EXIT_SYNTAX, exit_invalid_opt);
}

test "ln: symbolic link creation and overwriting with -f" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const test_dir = "zig-cache/tmp_test_ln_sym";
    std.Io.Dir.cwd().deleteTree(io, test_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, test_dir);
    defer std.Io.Dir.cwd().deleteTree(io, test_dir) catch {};

    const target_str = "target_val";
    const link_path = test_dir ++ "/link1";

    // 1. Create symlink
    const exit1 = run(allocator, &.{ "-s", target_str, link_path });
    try std.testing.expectEqual(common_error.EXIT_SUCCESS, exit1);

    var read_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len1 = try std.Io.Dir.cwd().readLink(io, link_path, &read_buf);
    try std.testing.expectEqualStrings(target_str, read_buf[0..len1]);

    // 2. Attempt overwrite without -f -> fails with 1
    const exit2 = run(allocator, &.{ "-s", "new_target", link_path });
    try std.testing.expectEqual(common_error.EXIT_FAILURE, exit2);

    // 3. Overwrite with -f -> succeeds
    const exit3 = run(allocator, &.{ "-sf", "new_target", link_path });
    try std.testing.expectEqual(common_error.EXIT_SUCCESS, exit3);

    const len3 = try std.Io.Dir.cwd().readLink(io, link_path, &read_buf);
    try std.testing.expectEqualStrings("new_target", read_buf[0..len3]);
}

test "ln: multi-source into directory and hard links" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const test_dir = "zig-cache/tmp_test_ln_multi";
    std.Io.Dir.cwd().deleteTree(io, test_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, test_dir);
    defer std.Io.Dir.cwd().deleteTree(io, test_dir) catch {};

    const sub_dir = test_dir ++ "/dest_dir";
    try std.Io.Dir.cwd().createDirPath(io, sub_dir);

    const file1 = test_dir ++ "/f1";
    const file2 = test_dir ++ "/f2";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file1, .data = "data1" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file2, .data = "data2" });

    // Link multiple files into directory
    const exit_multi = run(allocator, &.{ file1, file2, sub_dir });
    try std.testing.expectEqual(common_error.EXIT_SUCCESS, exit_multi);

    // Verify hard links point to same inode
    const stat_orig1 = try std.Io.Dir.cwd().statFile(io, file1, .{});
    const stat_linked1 = try std.Io.Dir.cwd().statFile(io, sub_dir ++ "/f1", .{});
    try std.testing.expectEqual(stat_orig1.inode, stat_linked1.inode);

    // Test error when >2 operands and final is not a directory
    const exit_notdir = run(allocator, &.{ file1, file2, test_dir ++ "/not_a_dir" });
    try std.testing.expectEqual(common_error.EXIT_FAILURE, exit_notdir);
}

test "ln: self-link protection with -f" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const test_dir = "zig-cache/tmp_test_ln_self";
    std.Io.Dir.cwd().deleteTree(io, test_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, test_dir);
    defer std.Io.Dir.cwd().deleteTree(io, test_dir) catch {};

    const file_a = test_dir ++ "/file_a";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file_a, .data = "preserve_me" });

    // ln -f file_a file_a should fail without deleting file_a
    const exit_self = run(allocator, &.{ "-f", file_a, file_a });
    try std.testing.expectEqual(common_error.EXIT_FAILURE, exit_self);

    // Ensure file_a still exists
    var stat_buf: [100]u8 = undefined;
    const content = try std.Io.Dir.cwd().readFile(io, file_a, &stat_buf);
    try std.testing.expectEqualStrings("preserve_me", content);
}
