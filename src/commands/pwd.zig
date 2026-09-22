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
const common_args = @import("../common/args.zig");
const common_error = @import("../common/error.zig");

const Mode = enum {
    logical,
    physical,
};

pub fn run(allocator: std.mem.Allocator, args: []const [:0]const u8) u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    var mode: Mode = .logical;

    var parser = common_args.ArgParser.init(args);
    while (parser.next("LP")) |opt| {
        switch (opt) {
            'L' => mode = .logical,
            'P' => mode = .physical,
            else => {
                common_error.report("pwd", "invalid option", error.InvalidArgument);
                return common_error.EXIT_SYNTAX;
            }
        }
    }

    const operands = parser.remaining();
    if (operands.len > 0) {
        common_error.report("pwd", "too many arguments", error.InvalidArgument);
        return common_error.EXIT_SYNTAX;
    }

    // Retrieve physical current working directory
    var phys_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const phys_len = std.process.currentPath(io, &phys_buf) catch |err| {
        common_error.report("pwd", "cannot determine current directory", err);
        return common_error.toExitCode(err);
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

    writer.writeAll(out_path) catch |err| {
        common_error.report("pwd", null, err);
        return common_error.toExitCode(err);
    };
    writer.writeByte('\n') catch |err| {
        common_error.report("pwd", null, err);
        return common_error.toExitCode(err);
    };
    fw.flush() catch |err| {
        common_error.report("pwd", null, err);
        return common_error.toExitCode(err);
    };

    return common_error.EXIT_SUCCESS;
}

pub fn main(init: std.process.Init) u8 {
    const all_args = init.minimal.args.toSlice(init.arena.allocator()) catch |err| {
        common_error.report("pwd", null, err);
        return common_error.EXIT_FAILURE;
    };
    const cmd_args = if (all_args.len > 1) all_args[1..] else &.{};
    return run(init.arena.allocator(), cmd_args);
}


fn isValidLogicalPath(path: []const u8) bool {
    if (path.len == 0 or path[0] != '/') return false;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |component| {
        if (std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) {
            return false;
        }
    }
    return true;
}

fn matchesCurrentDir(io: std.Io, logical: []const u8, physical: []const u8) bool {
    _ = io;
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const real_logical = std.Io.Dir.cwd().realpath(logical, &buf) catch return false;
    return std.mem.eql(u8, real_logical, physical);
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
    try std.testing.expectEqual(@as(u8, 2), code);
}

test "pwd: invalid option rejected" {
    const code = run(std.testing.allocator, &.{"-z"});
    try std.testing.expectEqual(@as(u8, 2), code);
}
