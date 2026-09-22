//! POSIX.1-2024 (IEEE Std 1003.1-2024) compliant implementation of `mv`.
//!
//! Specification References:
//! - IEEE Std 1003.1-2024, Shell & Utilities (XCU), Section: `mv`
//!   - SYNOPSIS:
//!       mv [-if] source_file target_file
//!       mv [-if] source_file... target_dir
//!   - OPTIONS:
//!       -f: Do not prompt for confirmation if destination path exists. Overrides -i.
//!       -i: Prompt for confirmation if destination path exists. Overrides -f.
//!   - OPERANDS:
//!       source_file: A pathname of a file or directory to be moved.
//!       target_file: A new pathname for the file or directory being moved.
//!       target_dir: A pathname of an existing directory.
//!   - EXIT STATUS:
//!       0: All requested files were successfully moved.
//!       >0: An error occurred.

const std = @import("std");
const common_args = @import("../common/args.zig");
const common_error = @import("../common/error.zig");

pub const MvOptions = struct {
    force: bool = false,
    interactive: bool = false,
};

/// Strips redundant trailing slashes, preserving root "/" or "//".
pub fn stripTrailingSlashes(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and path[end - 1] == '/') {
        if (end == 2 and path[0] == '/') break;
        end -= 1;
    }
    return path[0..end];
}

/// Extract the last pathname component of a path, ignoring trailing slashes.
pub fn getLastComponent(path: []const u8) []const u8 {
    const trimmed = stripTrailingSlashes(path);
    if (trimmed.len == 0) return "";
    if (std.mem.lastIndexOfScalar(u8, trimmed, '/')) |idx| {
        if (idx + 1 == trimmed.len) return trimmed;
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
pub fn isExistingDirectory(io: std.Io, path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = true }) catch return false;
    return stat.kind == .directory;
}

/// Checks if source and destination refer to the exact same file.
pub fn isSameFile(io: std.Io, src: []const u8, dst: []const u8) bool {
    if (std.mem.eql(u8, src, dst)) return true;

    var src_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var dst_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;

    const src_len = std.Io.Dir.cwd().realPathFile(io, src, &src_buf) catch return false;
    const dst_len = std.Io.Dir.cwd().realPathFile(io, dst, &dst_buf) catch return false;

    return std.mem.eql(u8, src_buf[0..src_len], dst_buf[0..dst_len]);
}

/// Checks if dest is a subdirectory of src.
pub fn isSubdirectoryOf(io: std.Io, src: []const u8, dst: []const u8) bool {
    var src_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var dst_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;

    const src_len = std.Io.Dir.cwd().realPathFile(io, src, &src_buf) catch return false;
    const dst_parent = getParentDir(dst) orelse ".";
    const dst_len = std.Io.Dir.cwd().realPathFile(io, dst_parent, &dst_buf) catch return false;

    const src_real = src_buf[0..src_len];
    const dst_parent_real = dst_buf[0..dst_len];

    if (std.mem.eql(u8, src_real, dst_parent_real)) return true;
    if (dst_parent_real.len > src_real.len and
        std.mem.startsWith(u8, dst_parent_real, src_real) and
        dst_parent_real[src_real.len] == '/')
    {
        return true;
    }
    return false;
}

/// Join parent directory and component into a fixed buffer.
pub fn joinPath(buf: []u8, parent: []const u8, child: []const u8) ![]const u8 {
    if (parent.len == 0 or std.mem.eql(u8, parent, ".")) {
        if (child.len > buf.len) return error.NameTooLong;
        @memcpy(buf[0..child.len], child);
        return buf[0..child.len];
    }
    const trimmed = stripTrailingSlashes(parent);
    if (std.mem.eql(u8, trimmed, "/")) {
        return std.fmt.bufPrint(buf, "/{s}", .{child});
    } else {
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ trimmed, child });
    }
}

/// Prompt the user on stderr and read response from stdin. Returns true if affirmative ('y' or 'Y').
fn promptUser(io: std.Io, comptime fmt: []const u8, args: anytype) bool {
    const stderr = std.Io.File.stderr();
    var pbuf: [512]u8 = undefined;
    var writer = stderr.writer(io, &pbuf);
    _ = writer.interface.print(fmt, args) catch {};
    _ = writer.flush() catch {};

    var buf: [64]u8 = undefined;
    const n = std.Io.File.stdin().readStreaming(io, &.{&buf}) catch return false;
    if (n == 0) return false;
    const line = buf[0..n];
    return line.len > 0 and (line[0] == 'y' or line[0] == 'Y');
}

/// Fallback cross-device file copy preserving timestamps and permissions.
fn copyFileCrossDevice(io: std.Io, src: []const u8, dest: []const u8, src_stat: std.Io.File.Stat) bool {
    const src_file = std.Io.Dir.cwd().openFile(io, src, .{ .mode = .read_only }) catch |err| {
        common_error.report("mv", src, err);
        return false;
    };
    defer src_file.close(io);

    const dest_file = std.Io.Dir.cwd().createFile(io, dest, .{ .truncate = true }) catch |err| {
        common_error.report("mv", dest, err);
        return false;
    };
    defer dest_file.close(io);

    var buf: [16 * 1024]u8 = undefined;
    var offset: u64 = 0;

    while (true) {
        const bytes_read = src_file.readPositional(io, &.{&buf}, offset) catch |err| {
            common_error.report("mv", src, err);
            return false;
        };
        if (bytes_read == 0) break;

        dest_file.writePositionalAll(io, buf[0..bytes_read], offset) catch |err| {
            common_error.report("mv", dest, err);
            return false;
        };
        offset += bytes_read;
    }

    dest_file.setPermissions(io, src_stat.permissions) catch {};
    dest_file.setTimestamps(io, .{
        .access_timestamp = .init(src_stat.atime),
        .modify_timestamp = .init(src_stat.mtime),
    }) catch {};

    return true;
}

/// Fallback cross-device directory copy preserving metadata.
fn copyDirCrossDevice(io: std.Io, src: []const u8, dest: []const u8, src_stat: std.Io.File.Stat) bool {
    std.Io.Dir.cwd().createDir(io, dest, src_stat.permissions) catch |err| {
        common_error.report("mv", dest, err);
        return false;
    };

    var src_dir = std.Io.Dir.cwd().openDir(io, src, .{
        .follow_symlinks = false,
        .iterate = true,
    }) catch |err| {
        common_error.report("mv", src, err);
        return false;
    };
    defer src_dir.close(io);

    var it = src_dir.iterate();
    var all_success = true;

    while (true) {
        const maybe_entry = it.next(io) catch |err| {
            common_error.report("mv", src, err);
            return false;
        };
        const entry = maybe_entry orelse break;

        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) {
            continue;
        }

        var child_src_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const child_src = joinPath(&child_src_buf, src, entry.name) catch |err| {
            common_error.report("mv", entry.name, err);
            all_success = false;
            continue;
        };

        var child_dest_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const child_dest = joinPath(&child_dest_buf, dest, entry.name) catch |err| {
            common_error.report("mv", entry.name, err);
            all_success = false;
            continue;
        };

        const child_stat = std.Io.Dir.cwd().statFile(io, child_src, .{ .follow_symlinks = false }) catch |err| {
            common_error.report("mv", child_src, err);
            all_success = false;
            continue;
        };

        if (child_stat.kind == .directory) {
            if (!copyDirCrossDevice(io, child_src, child_dest, child_stat)) {
                all_success = false;
            }
        } else if (child_stat.kind == .sym_link) {
            var target_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const target_len = std.Io.Dir.cwd().readLink(io, child_src, &target_buf) catch {
                all_success = false;
                continue;
            };
            std.Io.Dir.cwd().symLink(io, target_buf[0..target_len], child_dest, .{}) catch {
                all_success = false;
            };
        } else {
            if (!copyFileCrossDevice(io, child_src, child_dest, child_stat)) {
                all_success = false;
            }
        }
    }

    std.Io.Dir.cwd().setFilePermissions(io, dest, src_stat.permissions, .{}) catch {};
    std.Io.Dir.cwd().setTimestamps(io, dest, .{
        .access_timestamp = .init(src_stat.atime),
        .modify_timestamp = .init(src_stat.mtime),
    }) catch {};

    return all_success;
}

/// Fallback cross-device move: copy hierarchy to dest and delete from src.
fn moveCrossDevice(io: std.Io, src: []const u8, dest: []const u8, src_stat: std.Io.File.Stat) bool {
    if (src_stat.kind == .directory) {
        if (!copyDirCrossDevice(io, src, dest, src_stat)) {
            return false;
        }
        std.Io.Dir.cwd().deleteTree(io, src) catch |err| {
            common_error.report("mv", src, err);
            return false;
        };
        return true;
    } else if (src_stat.kind == .sym_link) {
        var target_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const target_len = std.Io.Dir.cwd().readLink(io, src, &target_buf) catch |err| {
            common_error.report("mv", src, err);
            return false;
        };
        std.Io.Dir.cwd().symLink(io, target_buf[0..target_len], dest, .{}) catch |err| {
            common_error.report("mv", dest, err);
            return false;
        };
        std.Io.Dir.cwd().deleteFile(io, src) catch |err| {
            common_error.report("mv", src, err);
            return false;
        };
        return true;
    } else {
        if (!copyFileCrossDevice(io, src, dest, src_stat)) {
            return false;
        }
        std.Io.Dir.cwd().deleteFile(io, src) catch |err| {
            common_error.report("mv", src, err);
            return false;
        };
        return true;
    }
}

/// Move a single file or directory from `src` to `dest`.
pub fn moveNode(io: std.Io, src: []const u8, dest: []const u8, opts: MvOptions) bool {
    // 1. Same-file check
    if (isSameFile(io, src, dest)) {
        common_error.report("mv", "'src' and 'dest' are the same file", error.InvalidArgument);
        return false;
    }

    // 2. Stat source (without following symlinks)
    const src_stat = std.Io.Dir.cwd().statFile(io, src, .{ .follow_symlinks = false }) catch |err| {
        common_error.report("mv", src, err);
        return false;
    };

    // Subdirectory check: A directory cannot be moved into a subdirectory of itself
    if (src_stat.kind == .directory and isSubdirectoryOf(io, src, dest)) {
        common_error.report("mv", "cannot move directory to a subdirectory of itself", error.InvalidArgument);
        return false;
    }

    // 3. Stat destination (without following symlinks)
    const dest_stat = std.Io.Dir.cwd().statFile(io, dest, .{ .follow_symlinks = false }) catch null;

    if (dest_stat) |dst_st| {
        // Interactive prompt
        if (opts.interactive) {
            if (!promptUser(io, "mv: overwrite '{s}'? ", .{dest})) {
                return true; // Non-affirmative: skip without error per POSIX
            }
        }

        // Type compatibility checks
        if (dst_st.kind == .directory and src_stat.kind != .directory) {
            common_error.report("mv", dest, error.IsDir);
            return false;
        }
        if (dst_st.kind != .directory and src_stat.kind == .directory) {
            common_error.report("mv", dest, error.NotDir);
            return false;
        }
    }

    // 4. Try atomic rename
    const cwd_dir = std.Io.Dir.cwd();
    std.Io.Dir.rename(cwd_dir, src, cwd_dir, dest, io) catch |err| switch (err) {
        error.CrossDevice => {
            return moveCrossDevice(io, src, dest, src_stat);
        },
        else => |e| {
            common_error.report("mv", src, e);
            return false;
        },
    };

    return true;
}

/// Execute mv utility per IEEE Std 1003.1-2024.
pub fn run(allocator: std.mem.Allocator, args: []const [:0]const u8) u8 {
    _ = allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var opts: MvOptions = .{};

    var parser = common_args.ArgParser.init(args);
    while (parser.next("fi")) |opt| {
        switch (opt) {
            'f' => {
                opts.force = true;
                opts.interactive = false;
            },
            'i' => {
                opts.interactive = true;
                opts.force = false;
            },
            else => {
                common_error.report("mv", "invalid option", error.InvalidArgument);
                return common_error.EXIT_SYNTAX;
            },
        }
    }

    const operands = parser.remaining();
    if (operands.len < 2) {
        common_error.report("mv", "missing operand", error.InvalidArgument);
        return common_error.EXIT_SYNTAX;
    }

    const final_operand = operands[operands.len - 1];
    const target_is_dir = isExistingDirectory(io, final_operand);

    if (operands.len > 2 and !target_is_dir) {
        common_error.report("mv", "target is not a directory", error.NotDir);
        return common_error.EXIT_FAILURE;
    }

    // Trailing slash check: if source is non-directory and target ends with slash
    if (operands.len == 2 and !target_is_dir and final_operand.len > 0 and final_operand[final_operand.len - 1] == '/') {
        const src_stat = std.Io.Dir.cwd().statFile(io, operands[0], .{ .follow_symlinks = false }) catch |err| {
            common_error.report("mv", operands[0], err);
            return common_error.EXIT_FAILURE;
        };
        if (src_stat.kind != .directory) {
            common_error.report("mv", final_operand, error.NotDir);
            return common_error.EXIT_FAILURE;
        }
    }

    const source_files = operands[0 .. operands.len - 1];
    var exit_code: u8 = common_error.EXIT_SUCCESS;

    for (source_files) |src| {
        var dest_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const dest_path = if (target_is_dir) blk: {
            const comp = getLastComponent(src);
            break :blk joinPath(&dest_buf, final_operand, comp) catch |err| {
                common_error.report("mv", final_operand, err);
                exit_code = common_error.EXIT_FAILURE;
                continue;
            };
        } else final_operand;

        if (!moveNode(io, src, dest_path, opts)) {
            exit_code = common_error.EXIT_FAILURE;
        }
    }

    return exit_code;
}

pub fn main(init: std.process.Init) u8 {
    const all_args = init.minimal.args.toSlice(init.arena.allocator()) catch |err| {
        common_error.report("mv", null, err);
        return common_error.EXIT_FAILURE;
    };
    const cmd_args = if (all_args.len > 1) all_args[1..] else &.{};
    return run(init.arena.allocator(), cmd_args);
}

// ============================================================================
// Unit Tests
// ============================================================================

test "mv: getLastComponent extraction" {
    try std.testing.expectEqualStrings("foo", getLastComponent("foo"));
    try std.testing.expectEqualStrings("foo", getLastComponent("dir/foo"));
    try std.testing.expectEqualStrings("foo", getLastComponent("dir/foo/"));
    try std.testing.expectEqualStrings("foo", getLastComponent("dir/foo///"));
    try std.testing.expectEqualStrings("/", getLastComponent("/"));
}

test "mv: argument parsing and missing operands" {
    const allocator = std.testing.allocator;

    try std.testing.expectEqual(common_error.EXIT_SYNTAX, run(allocator, &.{}));
    try std.testing.expectEqual(common_error.EXIT_SYNTAX, run(allocator, &.{"single_arg"}));
    try std.testing.expectEqual(common_error.EXIT_SYNTAX, run(allocator, &.{ "-z", "a", "b" }));
}

test "mv: basic file move" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const test_dir = "zig-cache/tmp_test_mv_file";
    std.Io.Dir.cwd().createDirPath(io, test_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, test_dir) catch {};

    const src_file = "zig-cache/tmp_test_mv_file/src.txt";
    const dst_file = "zig-cache/tmp_test_mv_file/dst.txt";

    {
        const f = try std.Io.Dir.cwd().createFile(io, src_file, .{});
        defer f.close(io);
        try f.writePositionalAll(io, "Moving content", 0);
    }

    // Move file
    const code = run(allocator, &.{ src_file, dst_file });
    try std.testing.expectEqual(common_error.EXIT_SUCCESS, code);

    // Old file gone, new file exists
    try std.testing.expect((std.Io.Dir.cwd().statFile(io, src_file, .{}) catch null) == null);
    try std.testing.expect((std.Io.Dir.cwd().statFile(io, dst_file, .{}) catch null) != null);
}

test "mv: move multiple files into directory" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const test_dir = "zig-cache/tmp_test_mv_multi";
    const target_dir = "zig-cache/tmp_test_mv_multi/dest";
    std.Io.Dir.cwd().createDirPath(io, target_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, test_dir) catch {};

    const src_a = "zig-cache/tmp_test_mv_multi/a.txt";
    const src_b = "zig-cache/tmp_test_mv_multi/b.txt";

    {
        const fa = try std.Io.Dir.cwd().createFile(io, src_a, .{});
        fa.close(io);
        const fb = try std.Io.Dir.cwd().createFile(io, src_b, .{});
        fb.close(io);
    }

    // Move into target_dir
    const code = run(allocator, &.{ src_a, src_b, target_dir });
    try std.testing.expectEqual(common_error.EXIT_SUCCESS, code);

    try std.testing.expect((std.Io.Dir.cwd().statFile(io, "zig-cache/tmp_test_mv_multi/dest/a.txt", .{}) catch null) != null);
    try std.testing.expect((std.Io.Dir.cwd().statFile(io, "zig-cache/tmp_test_mv_multi/dest/b.txt", .{}) catch null) != null);
}

test "mv: same file protection" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const test_dir = "zig-cache/tmp_test_mv_same";
    std.Io.Dir.cwd().createDirPath(io, test_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, test_dir) catch {};

    const src_file = "zig-cache/tmp_test_mv_same/same.txt";
    {
        const f = try std.Io.Dir.cwd().createFile(io, src_file, .{});
        f.close(io);
    }

    const code = run(allocator, &.{ src_file, src_file });
    try std.testing.expectEqual(common_error.EXIT_FAILURE, code);
}
