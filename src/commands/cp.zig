//! POSIX.1-2024 (IEEE Std 1003.1-2024) compliant implementation of `cp`.
//!
//! Specification References:
//! - IEEE Std 1003.1-2024, Shell & Utilities (XCU), Section: `cp`
//!   - SYNOPSIS:
//!       cp [-Pfip] source_file target_file
//!       cp [-Pfip] source_file... target
//!       cp -R [-H|-L|-P] [-fip] source_file... target
//!   - OPTIONS:
//!       -f: Unlink destination and retry if open for writing fails.
//!       -i: Prompt on stderr before overwriting existing destination.
//!       -p: Duplicate atime, mtime, permissions, and owner/group if possible.
//!       -R, -r: Copy file hierarchies.
//!       -H: Follow symlinks specified as operands.
//!       -L: Follow all symlinks.
//!       -P: Do not follow symlinks (default for -R).
//!   - OPERANDS:
//!       source_file: A pathname of a file to be copied.
//!       target_file: The pathname of the output file.
//!       target: A pathname of an existing directory.
//!   - EXIT STATUS:
//!       0: All requested files were successfully copied.
//!       >0: An error occurred.

const std = @import("std");
const common_args = @import("../common/args.zig");
const common_error = @import("../common/error.zig");

pub const SymlinkPolicy = enum {
    follow_none,     // -P
    follow_operands, // -H
    follow_all,      // -L
};

pub const CpOptions = struct {
    force: bool = false,
    interactive: bool = false,
    preserve: bool = false,
    recursive: bool = false,
    symlink_policy: SymlinkPolicy = .follow_none,
    symlink_policy_set: bool = false,
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

/// Prompt the user on stderr and read affirmative response ('y' or 'Y') from stdin.
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

/// Copy contents of regular file `src` to `dest`.
fn copyRegularFile(io: std.Io, src: []const u8, dest: []const u8, src_stat: std.Io.File.Stat, opts: CpOptions) bool {
    // 1. Check if destination exists
    const dest_stat = std.Io.Dir.cwd().statFile(io, dest, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => |e| {
            common_error.report("cp", dest, e);
            return false;
        },
    };

    if (dest_stat != null) {
        if (opts.interactive) {
            if (!promptUser(io, "cp: overwrite '{s}'? ", .{dest})) {
                return true; // Affirmative decline: skip file without error
            }
        }

        // Try opening dest for writing / truncating
        var opened_file = std.Io.Dir.cwd().createFile(io, dest, .{ .truncate = true }) catch |err| blk: {
            if (opts.force) {
                // Unlink destination and retry
                std.Io.Dir.cwd().deleteFile(io, dest) catch |unlink_err| {
                    common_error.report("cp", dest, unlink_err);
                    return false;
                };
                break :blk std.Io.Dir.cwd().createFile(io, dest, .{ .truncate = true }) catch |retry_err| {
                    common_error.report("cp", dest, retry_err);
                    return false;
                };
            } else {
                common_error.report("cp", dest, err);
                return false;
            }
        };
        defer opened_file.close(io);

        return pumpFileData(io, src, dest, opened_file, src_stat, opts);
    } else {
        // Destination does not exist: create it
        const dest_file = std.Io.Dir.cwd().createFile(io, dest, .{ .truncate = true }) catch |err| {
            common_error.report("cp", dest, err);
            return false;
        };
        defer dest_file.close(io);

        return pumpFileData(io, src, dest, dest_file, src_stat, opts);
    }
}

/// Stream file contents from src to dest_file and apply -p metadata if required.
fn pumpFileData(
    io: std.Io,
    src: []const u8,
    dest: []const u8,
    dest_file: std.Io.File,
    src_stat: std.Io.File.Stat,
    opts: CpOptions,
) bool {
    const src_file = std.Io.Dir.cwd().openFile(io, src, .{ .mode = .read_only }) catch |err| {
        common_error.report("cp", src, err);
        return false;
    };
    defer src_file.close(io);

    var buf: [16 * 1024]u8 = undefined;
    var offset: u64 = 0;

    while (true) {
        const bytes_read = src_file.readPositional(io, &.{&buf}, offset) catch |err| {
            common_error.report("cp", src, err);
            return false;
        };
        if (bytes_read == 0) break;

        dest_file.writePositionalAll(io, buf[0..bytes_read], offset) catch |err| {
            common_error.report("cp", dest, err);
            return false;
        };
        offset += bytes_read;
    }

    if (opts.preserve) {
        // Apply permissions
        dest_file.setPermissions(io, src_stat.permissions) catch |err| {
            common_error.report("cp", dest, err);
        };

        // Apply timestamps
        dest_file.setTimestamps(io, .{
            .access_timestamp = .init(src_stat.atime),
            .modify_timestamp = .init(src_stat.mtime),
        }) catch |err| {
            common_error.report("cp", dest, err);
        };
    }

    return true;
}

/// Copy a symbolic link as a symlink without following.
fn copySymLink(io: std.Io, src: []const u8, dest: []const u8, opts: CpOptions) bool {
    var target_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const target_len = std.Io.Dir.cwd().readLink(io, src, &target_buf) catch |err| {
        common_error.report("cp", src, err);
        return false;
    };
    const target_path = target_buf[0..target_len];

    const dest_stat = std.Io.Dir.cwd().statFile(io, dest, .{ .follow_symlinks = false }) catch null;
    if (dest_stat != null) {
        if (opts.interactive) {
            if (!promptUser(io, "cp: overwrite '{s}'? ", .{dest})) {
                return true;
            }
        }
        std.Io.Dir.cwd().deleteFile(io, dest) catch |err| {
            common_error.report("cp", dest, err);
            return false;
        };
    }

    std.Io.Dir.cwd().symLink(io, target_path, dest, .{}) catch |err| {
        common_error.report("cp", dest, err);
        return false;
    };

    return true;
}

/// Recursively copy a directory hierarchy.
fn copyDirectoryRecursive(
    io: std.Io,
    src: []const u8,
    dest: []const u8,
    src_stat: std.Io.File.Stat,
    opts: CpOptions,
) bool {
    // 1. Ensure destination directory exists
    const dest_stat = std.Io.Dir.cwd().statFile(io, dest, .{ .follow_symlinks = false }) catch null;
    if (dest_stat) |st| {
        if (st.kind != .directory) {
            common_error.report("cp", dest, error.NotDir);
            return false;
        }
    } else {
        std.Io.Dir.cwd().createDir(io, dest, src_stat.permissions) catch |err| {
            common_error.report("cp", dest, err);
            return false;
        };
    }

    // 2. Open source directory to iterate entries
    var src_dir = std.Io.Dir.cwd().openDir(io, src, .{
        .follow_symlinks = false,
        .iterate = true,
    }) catch |err| {
        common_error.report("cp", src, err);
        return false;
    };
    defer src_dir.close(io);

    var it = src_dir.iterate();
    var all_success = true;

    while (true) {
        const maybe_entry = it.next(io) catch |err| {
            common_error.report("cp", src, err);
            return false;
        };
        const entry = maybe_entry orelse break;

        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) {
            continue;
        }

        var child_src_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const child_src = joinPath(&child_src_buf, src, entry.name) catch |err| {
            common_error.report("cp", entry.name, err);
            all_success = false;
            continue;
        };

        var child_dest_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const child_dest = joinPath(&child_dest_buf, dest, entry.name) catch |err| {
            common_error.report("cp", entry.name, err);
            all_success = false;
            continue;
        };

        if (!copyNode(io, child_src, child_dest, opts, false)) {
            all_success = false;
        }
    }

    if (opts.preserve) {
        std.Io.Dir.cwd().setFilePermissions(io, dest, src_stat.permissions, .{}) catch {};
        std.Io.Dir.cwd().setTimestamps(io, dest, .{
            .access_timestamp = .init(src_stat.atime),
            .modify_timestamp = .init(src_stat.mtime),
        }) catch {};
    }

    return all_success;
}

/// Copy a single filesystem node (file, directory, or symlink).
pub fn copyNode(
    io: std.Io,
    src: []const u8,
    dest: []const u8,
    opts: CpOptions,
    is_top_level: bool,
) bool {
    // POSIX same-file check
    if (isSameFile(io, src, dest)) {
        common_error.report("cp", "'src' and 'dest' are the same file", error.InvalidArgument);
        return false;
    }

    // Determine whether to follow symlinks
    const follow_symlinks = if (!opts.recursive)
        (opts.symlink_policy != .follow_none)
    else switch (opts.symlink_policy) {
        .follow_all => true,
        .follow_operands => is_top_level,
        .follow_none => false,
    };

    // Stat source file
    const src_stat = std.Io.Dir.cwd().statFile(io, src, .{ .follow_symlinks = follow_symlinks }) catch |err| {
        common_error.report("cp", src, err);
        return false;
    };

    if (src_stat.kind == .directory) {
        if (!opts.recursive) {
            common_error.report("cp", "-r not specified; omitting directory", error.IsDir);
            return false;
        }
        if (isSubdirectoryOf(io, src, dest)) {
            common_error.report("cp", "cannot copy directory into a subdirectory of itself", error.InvalidArgument);
            return false;
        }
        return copyDirectoryRecursive(io, src, dest, src_stat, opts);
    } else if (src_stat.kind == .sym_link) {
        return copySymLink(io, src, dest, opts);
    } else {
        return copyRegularFile(io, src, dest, src_stat, opts);
    }
}

/// Execute cp utility per IEEE Std 1003.1-2024.
pub fn run(allocator: std.mem.Allocator, args: []const [:0]const u8) u8 {
    _ = allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var opts: CpOptions = .{};

    var parser = common_args.ArgParser.init(args);
    while (parser.next("fipRrHLP")) |opt| {
        switch (opt) {
            'f' => opts.force = true,
            'i' => opts.interactive = true,
            'p' => opts.preserve = true,
            'R', 'r' => opts.recursive = true,
            'H' => {
                opts.symlink_policy = .follow_operands;
                opts.symlink_policy_set = true;
            },
            'L' => {
                opts.symlink_policy = .follow_all;
                opts.symlink_policy_set = true;
            },
            'P' => {
                opts.symlink_policy = .follow_none;
                opts.symlink_policy_set = true;
            },
            else => {
                common_error.report("cp", "invalid option", error.InvalidArgument);
                return common_error.EXIT_SYNTAX;
            },
        }
    }

    // Default symlink policy: for -R default is -P; for non-R default is follow symlinks
    if (!opts.symlink_policy_set) {
        opts.symlink_policy = if (opts.recursive) .follow_none else .follow_all;
    }

    const operands = parser.remaining();
    if (operands.len < 2) {
        common_error.report("cp", "missing operand", error.InvalidArgument);
        return common_error.EXIT_SYNTAX;
    }

    const final_operand = operands[operands.len - 1];
    const target_is_dir = isExistingDirectory(io, final_operand);

    if (operands.len > 2 and !target_is_dir) {
        common_error.report("cp", "target is not a directory", error.NotDir);
        return common_error.EXIT_FAILURE;
    }

    const source_files = operands[0 .. operands.len - 1];
    var exit_code: u8 = common_error.EXIT_SUCCESS;

    for (source_files) |src| {
        var dest_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const dest_path = if (target_is_dir) blk: {
            const comp = getLastComponent(src);
            break :blk joinPath(&dest_buf, final_operand, comp) catch |err| {
                common_error.report("cp", final_operand, err);
                exit_code = common_error.EXIT_FAILURE;
                continue;
            };
        } else final_operand;

        if (!copyNode(io, src, dest_path, opts, true)) {
            exit_code = common_error.EXIT_FAILURE;
        }
    }

    return exit_code;
}

pub fn main(init: std.process.Init) u8 {
    const all_args = init.minimal.args.toSlice(init.arena.allocator()) catch |err| {
        common_error.report("cp", null, err);
        return common_error.EXIT_FAILURE;
    };
    const cmd_args = if (all_args.len > 1) all_args[1..] else &.{};
    return run(init.arena.allocator(), cmd_args);
}

// ============================================================================
// Unit Tests
// ============================================================================

test "cp: getLastComponent extraction" {
    try std.testing.expectEqualStrings("foo", getLastComponent("foo"));
    try std.testing.expectEqualStrings("foo", getLastComponent("dir/foo"));
    try std.testing.expectEqualStrings("foo", getLastComponent("dir/foo/"));
    try std.testing.expectEqualStrings("foo", getLastComponent("dir/foo///"));
    try std.testing.expectEqualStrings("/", getLastComponent("/"));
}

test "cp: argument parsing and missing operands" {
    const allocator = std.testing.allocator;

    try std.testing.expectEqual(common_error.EXIT_SYNTAX, run(allocator, &.{}));
    try std.testing.expectEqual(common_error.EXIT_SYNTAX, run(allocator, &.{"single_arg"}));
    try std.testing.expectEqual(common_error.EXIT_SYNTAX, run(allocator, &.{ "-z", "a", "b" }));
}

test "cp: single file copy" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const test_dir = "zig-cache/tmp_test_cp_single";
    std.Io.Dir.cwd().createDirPath(io, test_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, test_dir) catch {};

    const src_file = "zig-cache/tmp_test_cp_single/source.txt";
    const dst_file = "zig-cache/tmp_test_cp_single/dest.txt";

    // Write test content
    {
        const f = try std.Io.Dir.cwd().createFile(io, src_file, .{});
        defer f.close(io);
        try f.writePositionalAll(io, "Hello, Ziggybox!", 0);
    }

    // Run cp
    const code = run(allocator, &.{ src_file, dst_file });
    try std.testing.expectEqual(common_error.EXIT_SUCCESS, code);

    // Verify destination exists and has matching content
    var buf: [64]u8 = undefined;
    const f = try std.Io.Dir.cwd().openFile(io, dst_file, .{ .mode = .read_only });
    defer f.close(io);
    const n = try f.readPositional(io, &.{&buf}, 0);
    try std.testing.expectEqualStrings("Hello, Ziggybox!", buf[0..n]);
}

test "cp: copy into existing directory" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const test_dir = "zig-cache/tmp_test_cp_dir";
    const sub_dir = "zig-cache/tmp_test_cp_dir/target";
    std.Io.Dir.cwd().createDirPath(io, sub_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, test_dir) catch {};

    const src_a = "zig-cache/tmp_test_cp_dir/a.txt";
    const src_b = "zig-cache/tmp_test_cp_dir/b.txt";

    {
        const fa = try std.Io.Dir.cwd().createFile(io, src_a, .{});
        defer fa.close(io);
        try fa.writePositionalAll(io, "content A", 0);
        const fb = try std.Io.Dir.cwd().createFile(io, src_b, .{});
        defer fb.close(io);
        try fb.writePositionalAll(io, "content B", 0);
    }

    // Copy multiple files into directory
    const code = run(allocator, &.{ src_a, src_b, sub_dir });
    try std.testing.expectEqual(common_error.EXIT_SUCCESS, code);

    // Verify both files copied inside target
    const dst_a = "zig-cache/tmp_test_cp_dir/target/a.txt";
    const dst_b = "zig-cache/tmp_test_cp_dir/target/b.txt";
    try std.testing.expect((std.Io.Dir.cwd().statFile(io, dst_a, .{}) catch null) != null);
    try std.testing.expect((std.Io.Dir.cwd().statFile(io, dst_b, .{}) catch null) != null);
}

test "cp: recursive directory copy with -R" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const test_dir = "zig-cache/tmp_test_cp_rec";
    const src_tree = "zig-cache/tmp_test_cp_rec/src_tree/nested";
    const dst_tree = "zig-cache/tmp_test_cp_rec/dst_tree";
    std.Io.Dir.cwd().createDirPath(io, src_tree) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, test_dir) catch {};

    const nested_file = "zig-cache/tmp_test_cp_rec/src_tree/nested/hello.txt";
    {
        const f = try std.Io.Dir.cwd().createFile(io, nested_file, .{});
        defer f.close(io);
        try f.writePositionalAll(io, "Nested Content", 0);
    }

    // cp without -R on directory fails
    const fail_code = run(allocator, &.{ "zig-cache/tmp_test_cp_rec/src_tree", dst_tree });
    try std.testing.expectEqual(common_error.EXIT_FAILURE, fail_code);

    // cp with -R succeeds
    const rec_code = run(allocator, &.{ "-R", "zig-cache/tmp_test_cp_rec/src_tree", dst_tree });
    try std.testing.expectEqual(common_error.EXIT_SUCCESS, rec_code);

    const copied_file = "zig-cache/tmp_test_cp_rec/dst_tree/nested/hello.txt";
    try std.testing.expect((std.Io.Dir.cwd().statFile(io, copied_file, .{}) catch null) != null);
}

test "cp: same file protection" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const test_dir = "zig-cache/tmp_test_cp_same";
    std.Io.Dir.cwd().createDirPath(io, test_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, test_dir) catch {};

    const src_file = "zig-cache/tmp_test_cp_same/same.txt";
    {
        const f = try std.Io.Dir.cwd().createFile(io, src_file, .{});
        defer f.close(io);
        try f.writePositionalAll(io, "Same", 0);
    }

    // Copying file to itself fails
    const code = run(allocator, &.{ src_file, src_file });
    try std.testing.expectEqual(common_error.EXIT_FAILURE, code);
}
