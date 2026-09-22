//! POSIX.1-2024 (IEEE Std 1003.1-2024) compliant implementation of `uname`.
//!
//! Specification References:
//! - IEEE Std 1003.1-2024, Shell & Utilities (XCU), Section: `uname`
//!   - SYNOPSIS: `uname [-amnrsv]`
//!   - DESCRIPTION: Writes operating system and hardware characteristics to stdout.
//!   - OPTIONS:
//!       -a: Behave as though all options -mnrsv were specified.
//!       -m: Write the name of the hardware type (machine).
//!       -n: Write the name of this node within a communications network.
//!       -r: Write the current release level of the operating system.
//!       -s: Write the name of the operating system implementation (default).
//!       -v: Write the current version level of this release.
//!   - OPERANDS: None. Conforms to Section 12.2 Utility Syntax Guidelines
//!     (Guideline 10: '--' ends option processing).
//!   - STDOUT: Single line with symbols separated by single space characters,
//!     ordered as: sysname, nodename, release, version, machine.
//!   - STDERR: Used only for diagnostic messages.
//!   - EXIT STATUS:
//!       0: Successful completion.
//!       >0: An error occurred.
//!
//! Resource Constraint:
//! - Zero dynamic allocations. Stack-allocated buffers for I/O and utsname structures.

const std = @import("std");
const builtin = @import("builtin");
const common_args = @import("../common/args.zig");
const common_error = @import("../common/error.zig");

pub const Flags = struct {
    sysname: bool = false,
    nodename: bool = false,
    release: bool = false,
    version: bool = false,
    machine: bool = false,

    pub fn setAll(self: *Flags) void {
        self.sysname = true;
        self.nodename = true;
        self.release = true;
        self.version = true;
        self.machine = true;
    }

    pub fn any(self: Flags) bool {
        return self.sysname or self.nodename or self.release or self.version or self.machine;
    }
};

pub const SystemInfo = struct {
    sysname: []const u8,
    nodename: []const u8,
    release: []const u8,
    version: []const u8,
    machine: []const u8,
};

/// Core uname output formatter decoupled from writer destination for testing.
/// Writes selected system symbols in strict POSIX order:
/// sysname, nodename, release, version, machine.
pub fn writeUname(writer: *std.Io.Writer, info: SystemInfo, flags: Flags) !void {
    var has_printed = false;

    if (flags.sysname) {
        try writer.writeAll(info.sysname);
        has_printed = true;
    }
    if (flags.nodename) {
        if (has_printed) try writer.writeByte(' ');
        try writer.writeAll(info.nodename);
        has_printed = true;
    }
    if (flags.release) {
        if (has_printed) try writer.writeByte(' ');
        try writer.writeAll(info.release);
        has_printed = true;
    }
    if (flags.version) {
        if (has_printed) try writer.writeByte(' ');
        try writer.writeAll(info.version);
        has_printed = true;
    }
    if (flags.machine) {
        if (has_printed) try writer.writeByte(' ');
        try writer.writeAll(info.machine);
        has_printed = true;
    }

    try writer.writeByte('\n');
}

/// Retrieve platform system information using stack memory only.
fn getSystemInfo(uts_storage: *std.posix.utsname) SystemInfo {
    if (builtin.os.tag == .windows) {
        return SystemInfo{
            .sysname = "Windows",
            .nodename = "localhost",
            .release = "unknown",
            .version = "unknown",
            .machine = @tagName(builtin.cpu.arch),
        };
    } else {
        uts_storage.* = std.posix.uname();
        return SystemInfo{
            .sysname = std.mem.sliceTo(&uts_storage.sysname, 0),
            .nodename = std.mem.sliceTo(&uts_storage.nodename, 0),
            .release = std.mem.sliceTo(&uts_storage.release, 0),
            .version = std.mem.sliceTo(&uts_storage.version, 0),
            .machine = std.mem.sliceTo(&uts_storage.machine, 0),
        };
    }
}

pub fn run(allocator: std.mem.Allocator, args: []const [:0]const u8) u8 {
    _ = allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var flags = Flags{};
    var parser = common_args.ArgParser.init(args);

    while (parser.next("amnrsv")) |opt| {
        switch (opt) {
            'a' => flags.setAll(),
            'm' => flags.machine = true,
            'n' => flags.nodename = true,
            'r' => flags.release = true,
            's' => flags.sysname = true,
            'v' => flags.version = true,
            else => {
                common_error.report("uname", "invalid option", error.InvalidArgument);
                return common_error.EXIT_SYNTAX;
            },
        }
    }

    // POSIX: Operands: None. Reject any extra arguments.
    const operands = parser.remaining();
    if (operands.len > 0) {
        common_error.report("uname", "extra operand", error.InvalidArgument);
        return common_error.EXIT_SYNTAX;
    }

    // POSIX: If no options are specified, default to -s.
    if (!flags.any()) {
        flags.sysname = true;
    }

    var uts_storage: std.posix.utsname = undefined;
    const info = getSystemInfo(&uts_storage);

    const stdout_file = std.Io.File.stdout();
    var buf: [1024]u8 = undefined;
    var fw = stdout_file.writerStreaming(io, &buf);
    const writer = &fw.interface;

    writeUname(writer, info, flags) catch |err| {
        common_error.report("uname", null, err);
        return common_error.toExitCode(err);
    };

    fw.flush() catch |err| {
        common_error.report("uname", null, err);
        return common_error.toExitCode(err);
    };

    return common_error.EXIT_SUCCESS;
}

pub fn main(init: std.process.Init) u8 {
    const all_args = init.minimal.args.toSlice(init.arena.allocator()) catch |err| {
        common_error.report("uname", null, err);
        return common_error.EXIT_FAILURE;
    };
    const cmd_args = if (all_args.len > 1) all_args[1..] else &.{};
    return run(init.arena.allocator(), cmd_args);
}

// ============================================================================
// POSIX Conformance Tests
// ============================================================================

const mock_info = SystemInfo{
    .sysname = "Linux",
    .nodename = "test-node",
    .release = "6.6.87",
    .version = "#1 SMP PREEMPT_DYNAMIC",
    .machine = "x86_64",
};

fn testFormatUname(info: SystemInfo, flags: Flags) ![]u8 {
    var alloc_writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    errdefer alloc_writer.deinit();
    try writeUname(&alloc_writer.writer, info, flags);
    return alloc_writer.toOwnedSlice();
}

test "uname: default behavior writes sysname" {
    var flags = Flags{};
    if (!flags.any()) flags.sysname = true;

    const res = try testFormatUname(mock_info, flags);
    defer std.testing.allocator.free(res);
    try std.testing.expectEqualStrings("Linux\n", res);
}

test "uname: -a writes all fields in POSIX specified order" {
    var flags = Flags{};
    flags.setAll();

    const res = try testFormatUname(mock_info, flags);
    defer std.testing.allocator.free(res);
    try std.testing.expectEqualStrings("Linux test-node 6.6.87 #1 SMP PREEMPT_DYNAMIC x86_64\n", res);
}

test "uname: ordering is invariant of flag order on CLI" {
    // Even if machine (-m) and release (-r) and sysname (-s) are specified in reverse:
    const flags = Flags{ .machine = true, .release = true, .sysname = true };
    const res = try testFormatUname(mock_info, flags);
    defer std.testing.allocator.free(res);
    // Strict POSIX order: sysname, release, machine
    try std.testing.expectEqualStrings("Linux 6.6.87 x86_64\n", res);
}

test "uname: individual flags output single item" {
    const flags_m = Flags{ .machine = true };
    const res_m = try testFormatUname(mock_info, flags_m);
    defer std.testing.allocator.free(res_m);
    try std.testing.expectEqualStrings("x86_64\n", res_m);

    const flags_n = Flags{ .nodename = true };
    const res_n = try testFormatUname(mock_info, flags_n);
    defer std.testing.allocator.free(res_n);
    try std.testing.expectEqualStrings("test-node\n", res_n);

    const flags_r = Flags{ .release = true };
    const res_r = try testFormatUname(mock_info, flags_r);
    defer std.testing.allocator.free(res_r);
    try std.testing.expectEqualStrings("6.6.87\n", res_r);

    const flags_v = Flags{ .version = true };
    const res_v = try testFormatUname(mock_info, flags_v);
    defer std.testing.allocator.free(res_v);
    try std.testing.expectEqualStrings("#1 SMP PREEMPT_DYNAMIC\n", res_v);
}

test "uname: run execution valid options" {
    try std.testing.expectEqual(common_error.EXIT_SUCCESS, run(std.testing.allocator, &.{}));
    try std.testing.expectEqual(common_error.EXIT_SUCCESS, run(std.testing.allocator, &.{"-s"}));
    try std.testing.expectEqual(common_error.EXIT_SUCCESS, run(std.testing.allocator, &.{"-a"}));
    try std.testing.expectEqual(common_error.EXIT_SUCCESS, run(std.testing.allocator, &.{"-sr"}));
    try std.testing.expectEqual(common_error.EXIT_SUCCESS, run(std.testing.allocator, &.{ "-m", "-n" }));
    try std.testing.expectEqual(common_error.EXIT_SUCCESS, run(std.testing.allocator, &.{"--"}));
}

test "uname: run execution invalid flags and operands" {
    // Invalid flag returns EXIT_SYNTAX
    try std.testing.expectEqual(common_error.EXIT_SYNTAX, run(std.testing.allocator, &.{"-z"}));
    // Extra operand returns EXIT_SYNTAX
    try std.testing.expectEqual(common_error.EXIT_SYNTAX, run(std.testing.allocator, &.{"unexpected_arg"}));
    // Operand after '--' returns EXIT_SYNTAX
    try std.testing.expectEqual(common_error.EXIT_SYNTAX, run(std.testing.allocator, &.{ "--", "arg" }));
}
