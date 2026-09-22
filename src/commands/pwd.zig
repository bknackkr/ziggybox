//! POSIX.1-2024 (IEEE Std 1003.1-2024) compliant implementation of `pwd`.
//!
//! Specification References:
//! - IEEE Std 1003.1-2024, Shell & Utilities (XCU), Section: `pwd`
//!   - SYNOPSIS: `pwd [-L|-P]`
//!   - DESCRIPTION: Writes an absolute pathname of current working directory,
//!     without dot or dot-dot components.
//!   - OPTIONS:
//!     -L: Logical mode (default). If PWD environment variable contains an
//!         absolute pathname without '.' or '..' and refers to current directory,
//!         write PWD. Otherwise behave as -P.
//!     -P: Physical mode. Written pathname does not contain symbolic link components.
//!         Single leading slash preferred over multiple slashes.
//!   - STDOUT: "%s\n", <directory pathname>
//!   - STDERR: Used only for diagnostic messages.
//!   - EXIT STATUS: 0 on success, >0 on error.

const std = @import("std");

const Mode = enum {
    logical,
    physical,
};

/// Print diagnostic error message to stderr in POSIX standard format:
/// `pwd: <error message>\n`
fn printError(io: std.Io, comptime msg: []const u8) void {
    const stderr_file = std.Io.File.stderr();
    var err_buf: [256]u8 = undefined;
    var err_fw = stderr_file.writerStreaming(io, &err_buf);
    const err_writer = &err_fw.interface;
    _ = err_writer.writeAll("pwd: " ++ msg) catch {};
    _ = err_fw.flush() catch {};
}

/// Check if a logical PWD string is a valid absolute pathname with no '.' or '..' components.
fn isValidLogicalPath(path: []const u8) bool {
    if (path.len == 0) return false;
    if (!std.fs.path.isAbsolute(path)) return false;

    var it = std.mem.tokenizeAny(u8, path, "/\\");
    while (it.next()) |comp| {
        if (std.mem.eql(u8, comp, ".") or std.mem.eql(u8, comp, "..")) {
            return false;
        }
    }
    return true;
}

/// Check if a logical path actually matches the current working directory.
fn matchesCurrentDir(io: std.Io, logical_path: []const u8, phys_path: []const u8) bool {
    if (std.mem.eql(u8, logical_path, phys_path)) return true;
    if (@import("builtin").os.tag == .windows and std.ascii.eqlIgnoreCase(logical_path, phys_path)) return true;

    // Verify whether both paths refer to the same directory via directory stat
    var log_dir = std.Io.Dir.openDirAbsolute(io, logical_path, .{}) catch return false;
    defer log_dir.close(io);
    const log_stat = log_dir.stat(io) catch return false;

    var phys_dir = std.Io.Dir.openDirAbsolute(io, phys_path, .{}) catch return false;
    defer phys_dir.close(io);
    const phys_stat = phys_dir.stat(io) catch return false;

    return log_stat.inode == phys_stat.inode;
}

/// Entry point matching the ziggybox command interface standard:
/// `pub fn run(allocator: std.mem.Allocator, args: []const [:0]const u8) u8`
pub fn run(allocator: std.mem.Allocator, args: []const [:0]const u8) u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    var mode: Mode = .logical;

    var arg_idx: usize = 0;
    while (arg_idx < args.len) : (arg_idx += 1) {
        const arg = args[arg_idx];
        if (std.mem.eql(u8, arg, "--")) {
            arg_idx += 1;
            break;
        }
        if (arg.len > 1 and arg[0] == '-') {
            for (arg[1..]) |flag| {
                switch (flag) {
                    'L' => mode = .logical,
                    'P' => mode = .physical,
                    else => {
                        printError(io, "invalid option\n");
                        return 1;
                    },
                }
            }
        } else {
            break;
        }
    }

    if (arg_idx < args.len) {
        printError(io, "too many arguments\n");
        return 1;
    }

    // Retrieve physical current working directory
    var phys_buf: [std.fs.max_path_bytes]u8 = undefined;
    const phys_len = std.process.currentPath(io, &phys_buf) catch {
        printError(io, "cannot determine current directory\n");
        return 1;
    };
    const phys_path = phys_buf[0..phys_len];

    var out_path: []const u8 = phys_path;
    var allocated_pwd: ?[]u8 = null;
    defer if (allocated_pwd) |p| allocator.free(p);

    if (mode == .logical) {
        const t = std.Io.Threaded.global_single_threaded;
        if (t.environ.process_environ.getAlloc(allocator, "PWD")) |pwd_env| {
            allocated_pwd = pwd_env;
            if (isValidLogicalPath(pwd_env) and matchesCurrentDir(io, pwd_env, phys_path)) {
                out_path = pwd_env;
            }
        } else |_| {}
    }

    // Output directory followed by newline
    const stdout_file = std.Io.File.stdout();
    var out_buf: [4096]u8 = undefined;
    var fw = stdout_file.writerStreaming(io, &out_buf);
    const writer = &fw.interface;

    writer.writeAll(out_path) catch {
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

test "pwd: path validation" {
    try std.testing.expect(isValidLogicalPath("/usr/bin"));
    try std.testing.expect(!isValidLogicalPath(""));
    try std.testing.expect(!isValidLogicalPath("usr/bin"));
    try std.testing.expect(!isValidLogicalPath("/usr/./bin"));
    try std.testing.expect(!isValidLogicalPath("/usr/../bin"));
    try std.testing.expect(!isValidLogicalPath("/usr/bin/."));
    try std.testing.expect(!isValidLogicalPath("/usr/bin/.."));
}

test "pwd: execution basic" {
    const code = run(std.testing.allocator, &.{});
    try std.testing.expectEqual(@as(u8, 0), code);
}

test "pwd: physical flag" {
    const code = run(std.testing.allocator, &.{"-P"});
    try std.testing.expectEqual(@as(u8, 0), code);
}

test "pwd: combined flags -LP" {
    const code = run(std.testing.allocator, &.{"-LP"});
    try std.testing.expectEqual(@as(u8, 0), code);
}

test "pwd: extra arguments rejected" {
    const code = run(std.testing.allocator, &.{"extra"});
    try std.testing.expectEqual(@as(u8, 1), code);
}

test "pwd: invalid option rejected" {
    const code = run(std.testing.allocator, &.{"-z"});
    try std.testing.expectEqual(@as(u8, 1), code);
}
