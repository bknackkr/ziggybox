//! POSIX.1-2024 (IEEE Std 1003.1-2024) compliant implementation of `rm`.
//!
//! Specification References:
//! - IEEE Std 1003.1-2024, Shell & Utilities (XCU), Section: `rm`
//!   - SYNOPSIS:
//!       rm [-diRrv] file...
//!       rm -f [-diRrv] [file...]
//!   - OPTIONS:
//!       -d: Remove empty directories.
//!       -f: Do not prompt for confirmation. Do not write diagnostic messages
//!           or modify exit status for non-existent operands. Exit status 0 if no operands.
//!       -i: Prompt for confirmation before removing each directory entry.
//!       -R, -r: Remove file hierarchies (recursive).
//!       -v: Verbose. After each file has been removed, write a message to stdout.
//!   - OPERANDS:
//!       file: A pathname of a directory entry to be removed.
//!       If dot or dot-dot are specified as basename or operand resolves to root,
//!       rm shall write diagnostic to stderr and do nothing with such operand.
//!   - EXIT STATUS:
//!       0: All requested directory entries were successfully deleted.
//!       >0: An error occurred.

const std = @import("std");
const common_args = @import("../common/args.zig");
const common_error = @import("../common/error.zig");

/// Strips redundant trailing slashes, preserving root "/" or "//".
pub fn stripTrailingSlashes(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and path[end - 1] == '/') {
        if (end == 2 and path[0] == '/') break; // preserve "//"
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

/// Checks if path represents the root directory ("/" or "//").
pub fn isRootDirectory(path: []const u8) bool {
    const trimmed = stripTrailingSlashes(path);
    return std.mem.eql(u8, trimmed, "/") or std.mem.eql(u8, trimmed, "//");
}

/// Checks if the last component of the path is "." or "..".
pub fn isDotOrDotDot(path: []const u8) bool {
    const base = getLastComponent(path);
    return std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, "..");
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

/// Print verbose removal message to stdout.
fn printVerbose(io: std.Io, path: []const u8) void {
    const stdout = std.Io.File.stdout();
    var buf: [512]u8 = undefined;
    var writer = stdout.writer(io, &buf);
    _ = writer.interface.print("removed '{s}'\n", .{path}) catch {};
    _ = writer.flush() catch {};
}

/// Print verbose removal of directory message to stdout.
fn printVerboseDir(io: std.Io, path: []const u8) void {
    const stdout = std.Io.File.stdout();
    var buf: [512]u8 = undefined;
    var writer = stdout.writer(io, &buf);
    _ = writer.interface.print("removed directory '{s}'\n", .{path}) catch {};
    _ = writer.flush() catch {};
}

/// Join parent path and child name into a fixed buffer.
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

/// Configuration options for removal operations.
pub const RmOptions = struct {
    force: bool = false,
    interactive: bool = false,
    recursive: bool = false,
    empty_dirs: bool = false,
    verbose: bool = false,
};

/// Recursively removes a directory and all of its contents.
fn removeHierarchy(io: std.Io, path: []const u8, opts: RmOptions) bool {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{
        .follow_symlinks = false,
        .iterate = true,
    }) catch |err| {
        common_error.report("rm", path, err);
        return false;
    };
    defer dir.close(io);

    var it = dir.iterate();
    var all_success = true;

    while (true) {
        const maybe_entry = it.next(io) catch |err| {
            common_error.report("rm", path, err);
            return false;
        };
        const entry = maybe_entry orelse break;

        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) {
            continue;
        }

        var child_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const child_path = joinPath(&child_buf, path, entry.name) catch |err| {
            common_error.report("rm", entry.name, err);
            all_success = false;
            continue;
        };

        // Stat the child entry without following symlinks
        const child_stat = std.Io.Dir.cwd().statFile(io, child_path, .{ .follow_symlinks = false }) catch |err| {
            common_error.report("rm", child_path, err);
            all_success = false;
            continue;
        };

        if (child_stat.kind == .directory) {
            if (opts.interactive) {
                if (!promptUser(io, "rm: descend into directory '{s}'? ", .{child_path})) {
                    all_success = false;
                    continue;
                }
            }
            if (!removeHierarchy(io, child_path, opts)) {
                all_success = false;
            }
        } else {
            if (opts.interactive) {
                if (!promptUser(io, "rm: remove file '{s}'? ", .{child_path})) {
                    all_success = false;
                    continue;
                }
            }
            std.Io.Dir.cwd().deleteFile(io, child_path) catch |err| {
                common_error.report("rm", child_path, err);
                all_success = false;
                continue;
            };
            if (opts.verbose) {
                printVerbose(io, child_path);
            }
        }
    }

    if (!all_success) return false;

    if (opts.interactive) {
        if (!promptUser(io, "rm: remove directory '{s}'? ", .{path})) {
            return false;
        }
    }

    std.Io.Dir.cwd().deleteDir(io, path) catch |err| {
        common_error.report("rm", path, err);
        return false;
    };
    if (opts.verbose) {
        printVerboseDir(io, path);
    }

    return true;
}

/// Execute rm utility per IEEE Std 1003.1-2024.
pub fn run(allocator: std.mem.Allocator, args: []const [:0]const u8) u8 {
    _ = allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var opts: RmOptions = .{};

    var parser = common_args.ArgParser.init(args);
    while (parser.next("dfiRrv")) |opt| {
        switch (opt) {
            'd' => opts.empty_dirs = true,
            'f' => {
                opts.force = true;
                opts.interactive = false;
            },
            'i' => {
                opts.interactive = true;
                opts.force = false;
            },
            'R', 'r' => opts.recursive = true,
            'v' => opts.verbose = true,
            else => {
                common_error.report("rm", "invalid option", error.InvalidArgument);
                return common_error.EXIT_SYNTAX;
            },
        }
    }

    const operands = parser.remaining();

    // IEEE Std 1003.1-2024: rm -f without operands returns 0
    if (operands.len == 0) {
        if (opts.force) {
            return common_error.EXIT_SUCCESS;
        }
        common_error.report("rm", "missing operand", error.InvalidArgument);
        return common_error.EXIT_SYNTAX;
    }

    var exit_code: u8 = common_error.EXIT_SUCCESS;

    for (operands) |raw_arg| {
        const arg = stripTrailingSlashes(raw_arg);

        // POSIX requirement: Cannot remove '.' or '..'
        if (isDotOrDotDot(arg)) {
            common_error.report("rm", arg, error.InvalidArgument);
            exit_code = common_error.EXIT_FAILURE;
            continue;
        }

        // POSIX requirement: Cannot remove root directory
        if (isRootDirectory(arg)) {
            common_error.report("rm", "refusing to remove root directory", error.InvalidArgument);
            exit_code = common_error.EXIT_FAILURE;
            continue;
        }

        // Stat the target file without following symlinks
        const stat = std.Io.Dir.cwd().statFile(io, arg, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => {
                if (!opts.force) {
                    common_error.report("rm", arg, error.FileNotFound);
                    exit_code = common_error.EXIT_FAILURE;
                }
                continue;
            },
            else => |e| {
                common_error.report("rm", arg, e);
                exit_code = common_error.EXIT_FAILURE;
                continue;
            },
        };

        if (stat.kind == .directory) {
            if (!opts.recursive and !opts.empty_dirs) {
                common_error.report("rm", arg, error.IsDir);
                exit_code = common_error.EXIT_FAILURE;
                continue;
            }

            if (opts.empty_dirs and !opts.recursive) {
                // Remove empty directory only
                if (opts.interactive) {
                    if (!promptUser(io, "rm: remove directory '{s}'? ", .{arg})) {
                        continue;
                    }
                }

                std.Io.Dir.cwd().deleteDir(io, arg) catch |err| {
                    common_error.report("rm", arg, err);
                    exit_code = common_error.EXIT_FAILURE;
                    continue;
                };

                if (opts.verbose) {
                    printVerboseDir(io, arg);
                }
            } else if (opts.recursive) {
                // Recursively remove directory hierarchy
                if (opts.interactive) {
                    if (!promptUser(io, "rm: descend into directory '{s}'? ", .{arg})) {
                        continue;
                    }
                }

                if (!removeHierarchy(io, arg, opts)) {
                    exit_code = common_error.EXIT_FAILURE;
                }
            }
        } else {
            // Regular file, symlink, pipe, socket, etc.
            if (opts.interactive) {
                if (!promptUser(io, "rm: remove file '{s}'? ", .{arg})) {
                    continue;
                }
            }

            std.Io.Dir.cwd().deleteFile(io, arg) catch |err| {
                common_error.report("rm", arg, err);
                exit_code = common_error.EXIT_FAILURE;
                continue;
            };

            if (opts.verbose) {
                printVerbose(io, arg);
            }
        }
    }

    return exit_code;
}

pub fn main(init: std.process.Init) u8 {
    const all_args = init.minimal.args.toSlice(init.arena.allocator()) catch |err| {
        common_error.report("rm", null, err);
        return common_error.EXIT_FAILURE;
    };
    const cmd_args = if (all_args.len > 1) all_args[1..] else &.{};
    return run(init.arena.allocator(), cmd_args);
}

// ============================================================================
// Unit Tests
// ============================================================================

test "rm: getLastComponent and isDotOrDotDot" {
    try std.testing.expect(isDotOrDotDot("."));
    try std.testing.expect(isDotOrDotDot(".."));
    try std.testing.expect(isDotOrDotDot("a/b/."));
    try std.testing.expect(isDotOrDotDot("a/b/.."));
    try std.testing.expect(isDotOrDotDot("a/b/../"));
    try std.testing.expect(!isDotOrDotDot("a/b/foo"));
    try std.testing.expect(!isDotOrDotDot(".foo"));
    try std.testing.expect(!isDotOrDotDot("..foo"));
}

test "rm: isRootDirectory" {
    try std.testing.expect(isRootDirectory("/"));
    try std.testing.expect(isRootDirectory("//"));
    try std.testing.expect(isRootDirectory("///"));
    try std.testing.expect(!isRootDirectory("/foo"));
    try std.testing.expect(!isRootDirectory("."));
}

test "rm: joinPath formatting" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("a/b", try joinPath(&buf, "a", "b"));
    try std.testing.expectEqualStrings("a/b", try joinPath(&buf, "a/", "b"));
    try std.testing.expectEqualStrings("/b", try joinPath(&buf, "/", "b"));
    try std.testing.expectEqualStrings("b", try joinPath(&buf, ".", "b"));
}

test "rm: argument parsing and missing operands" {
    const allocator = std.testing.allocator;

    // Missing operands without -f should return EXIT_SYNTAX
    try std.testing.expectEqual(common_error.EXIT_SYNTAX, run(allocator, &.{}));

    // With -f and no operands, POSIX specifies exit 0
    try std.testing.expectEqual(common_error.EXIT_SUCCESS, run(allocator, &.{"-f"}));

    // Invalid option returns EXIT_SYNTAX
    try std.testing.expectEqual(common_error.EXIT_SYNTAX, run(allocator, &.{"-z"}));

    // Rejection of dot / dot-dot
    try std.testing.expectEqual(common_error.EXIT_FAILURE, run(allocator, &.{"."}));
    try std.testing.expectEqual(common_error.EXIT_FAILURE, run(allocator, &.{".."}));
}

test "rm: basic file removal and -f behavior" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const test_dir = "zig-cache/tmp_test_rm_file";
    std.Io.Dir.cwd().createDirPath(io, test_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, test_dir) catch {};

    const test_file = "zig-cache/tmp_test_rm_file/file.txt";
    const file = try std.Io.Dir.cwd().createFile(io, test_file, .{});
    file.close(io);

    // File should exist
    try std.testing.expect((std.Io.Dir.cwd().statFile(io, test_file, .{}) catch null) != null);

    // Remove file
    const exit_code = run(allocator, &.{test_file});
    try std.testing.expectEqual(common_error.EXIT_SUCCESS, exit_code);

    // File should now be gone
    try std.testing.expect((std.Io.Dir.cwd().statFile(io, test_file, .{}) catch null) == null);

    // Removing non-existent file without -f fails
    const fail_code = run(allocator, &.{test_file});
    try std.testing.expectEqual(common_error.EXIT_FAILURE, fail_code);

    // Removing non-existent file with -f succeeds
    const force_code = run(allocator, &.{ "-f", test_file });
    try std.testing.expectEqual(common_error.EXIT_SUCCESS, force_code);
}

test "rm: directory removal with -d and -r" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const test_root = "zig-cache/tmp_test_rm_dir";
    std.Io.Dir.cwd().createDirPath(io, test_root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, test_root) catch {};

    const empty_dir = "zig-cache/tmp_test_rm_dir/empty";
    std.Io.Dir.cwd().createDirPath(io, empty_dir) catch {};

    // Removing directory without -r or -d fails with IsDir
    const isdir_code = run(allocator, &.{empty_dir});
    try std.testing.expectEqual(common_error.EXIT_FAILURE, isdir_code);

    // Removing empty directory with -d succeeds
    const d_code = run(allocator, &.{ "-d", empty_dir });
    try std.testing.expectEqual(common_error.EXIT_SUCCESS, d_code);
    try std.testing.expect((std.Io.Dir.cwd().statFile(io, empty_dir, .{}) catch null) == null);

    // Create nested hierarchy for -r
    const nested_dir = "zig-cache/tmp_test_rm_dir/tree/sub";
    std.Io.Dir.cwd().createDirPath(io, nested_dir) catch {};
    const nested_file = "zig-cache/tmp_test_rm_dir/tree/sub/test.txt";
    const file = try std.Io.Dir.cwd().createFile(io, nested_file, .{});
    file.close(io);

    // -d on non-empty directory fails
    const tree_path = "zig-cache/tmp_test_rm_dir/tree";
    const d_fail = run(allocator, &.{ "-d", tree_path });
    try std.testing.expectEqual(common_error.EXIT_FAILURE, d_fail);

    // -r removes entire hierarchy
    const r_code = run(allocator, &.{ "-r", tree_path });
    try std.testing.expectEqual(common_error.EXIT_SUCCESS, r_code);
    try std.testing.expect((std.Io.Dir.cwd().statFile(io, tree_path, .{}) catch null) == null);
}
