//! POSIX.1-2024 (IEEE Std 1003.1-2024) compliant implementation of `nice`.
//!
//! Specification References:
//! - IEEE Std 1003.1-2024, Shell & Utilities (XCU), Section: `nice`
//!   - SYNOPSIS: `nice [-n increment] utility [argument...]`
//!   - DESCRIPTION: Invokes a utility with an altered nice value.
//!   - OPTIONS:
//!       -n increment: A positive or negative decimal integer to adjust nice value.
//!   - OPERANDS:
//!       utility: The name of the utility to be invoked.
//!       argument: Any arguments supplied to the utility.
//!   - EXIT STATUS:
//!       If utility is invoked, the exit status of nice shall be the exit status of utility.
//!       Otherwise:
//!       1-125: An error occurred in the nice utility itself.
//!       126: Utility was found but could not be invoked.
//!       127: Utility could not be found.

const std = @import("std");
const builtin = @import("builtin");
const common_args = @import("../common/args.zig");
const common_error = @import("../common/error.zig");
const common_priority = @import("../common/priority.zig");

/// Parse a signed integer string (e.g. "10", "+10", "-10").
fn parseIncrement(str: []const u8) ?i32 {
    if (str.len == 0) return null;
    var s = str;
    var sign: i32 = 1;
    if (s[0] == '+') {
        s = s[1..];
    } else if (s[0] == '-') {
        sign = -1;
        s = s[1..];
    }
    if (s.len == 0) return null;
    const val = std.fmt.parseInt(i32, s, 10) catch return null;
    return val * sign;
}

pub fn run(allocator: std.mem.Allocator, args: []const [:0]const u8) u8 {
    var increment: i32 = 10; // POSIX default increment
    var arg_idx: usize = 0;

    // Handle options
    while (arg_idx < args.len) {
        const arg = args[arg_idx];

        // End of options marker
        if (std.mem.eql(u8, arg, "--")) {
            arg_idx += 1;
            break;
        }

        // Non-option argument terminates option parsing
        if (arg.len < 2 or (arg[0] != '-' and arg[0] != '+')) {
            break;
        }

        // Check for -n option
        if (std.mem.eql(u8, arg, "-n")) {
            arg_idx += 1;
            if (arg_idx >= args.len) {
                common_error.report("nice", "option requires an argument -- 'n'", error.InvalidArgument);
                return common_error.EXIT_FAILURE;
            }
            const inc_str = args[arg_idx];
            increment = parseIncrement(inc_str) orelse {
                common_error.report("nice", inc_str, error.InvalidArgument);
                return common_error.EXIT_FAILURE;
            };
            arg_idx += 1;
            continue;
        } else if (std.mem.startsWith(u8, arg, "-n")) {
            // Attached option argument: -n10, -n-5
            const inc_str = arg[2..];
            increment = parseIncrement(inc_str) orelse {
                common_error.report("nice", inc_str, error.InvalidArgument);
                return common_error.EXIT_FAILURE;
            };
            arg_idx += 1;
            continue;
        }

        // Check for historical obsolete form: -<digits> or +<digits>
        if ((arg[0] == '-' or arg[0] == '+') and arg.len > 1 and std.ascii.isDigit(arg[1])) {
            increment = parseIncrement(arg) orelse {
                common_error.report("nice", arg, error.InvalidArgument);
                return common_error.EXIT_FAILURE;
            };
            arg_idx += 1;
            continue;
        }

        // Unknown option flag
        common_error.report("nice", arg, error.InvalidArgument);
        return common_error.EXIT_FAILURE;
    }

    if (arg_idx >= args.len) {
        common_error.report("nice", "missing operand", error.InvalidArgument);
        return common_error.EXIT_FAILURE;
    }

    const utility_args = args[arg_idx..];

    // Query current process priority
    const cur_prio = common_priority.getPriority(.process, 0) catch 0;
    const target_prio = cur_prio + increment;

    // Apply requested nice value
    common_priority.setPriority(.process, 0, target_prio) catch |err| {
        switch (err) {
            error.AccessDenied => {
                // POSIX specification:
                // "If the user lacks appropriate privileges to affect the nice value
                // in the requested manner, the nice utility shall not affect the nice value;
                // in this case, a warning message may be written to standard error, but this
                // shall not prevent the invocation of utility or affect the exit status."
                std.debug.print("nice: cannot set priority: Permission denied\n", .{});
            },
            else => {},
        }
    };

    // When running inside unit tests, restore initial priority upon completion to avoid
    // modifying the test runner environment.
    if (builtin.is_test) {
        defer _ = common_priority.setPriority(.process, 0, cur_prio) catch {};
    }

    // Convert utility args to slice of []const u8 for process spawn
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var child = std.process.spawn(io, .{
        .argv = utility_args,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| {
        switch (err) {
            error.FileNotFound => {
                common_error.report("nice", utility_args[0], error.FileNotFound);
                return common_error.EXIT_NOT_FOUND; // 127
            },
            error.AccessDenied, error.PermissionDenied => {
                common_error.report("nice", utility_args[0], error.AccessDenied);
                return common_error.EXIT_CANNOT_EXEC; // 126
            },
            else => {
                common_error.report("nice", utility_args[0], err);
                return common_error.EXIT_CANNOT_EXEC; // 126
            },
        }
    };

    const term = child.wait(io) catch |err| {
        common_error.report("nice", utility_args[0], err);
        return common_error.EXIT_FAILURE;
    };

    return switch (term) {
        .exited => |code| code,
        .signal => |sig| @as(u8, @truncate(128 + @intFromEnum(sig))),
        .stopped => |sig| @as(u8, @truncate(128 + @intFromEnum(sig))),
        .unknown => |val| @as(u8, @truncate(val)),
    };
}

pub fn main(init: std.process.Init) u8 {
    const all_args = init.minimal.args.toSlice(init.arena.allocator()) catch |err| {
        common_error.report("nice", null, err);
        return common_error.EXIT_FAILURE;
    };
    const cmd_args = if (all_args.len > 1) all_args[1..] else &.{};
    return run(init.arena.allocator(), cmd_args);
}

// ============================================================================
// Unit Tests
// ============================================================================

test "nice: missing operand returns failure" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqual(common_error.EXIT_FAILURE, run(allocator, &.{}));
    try std.testing.expectEqual(common_error.EXIT_FAILURE, run(allocator, &.{"--"}));
}

test "nice: missing argument for -n" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqual(common_error.EXIT_FAILURE, run(allocator, &.{"-n"}));
}

test "nice: invalid increment returns failure" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqual(common_error.EXIT_FAILURE, run(allocator, &.{ "-n", "invalid", "echo" }));
    try std.testing.expectEqual(common_error.EXIT_FAILURE, run(allocator, &.{ "-ninvalid", "echo" }));
}

test "nice: non-existent utility returns 127" {
    const allocator = std.testing.allocator;
    const res = run(allocator, &.{"nonexistent_binary_ziggybox_xyz_12345"});
    try std.testing.expectEqual(common_error.EXIT_NOT_FOUND, res);
}

test "nice: executes utility successfully" {
    const allocator = std.testing.allocator;
    const res = run(allocator, &.{ "echo", "ziggybox_nice_test" });
    try std.testing.expectEqual(common_error.EXIT_SUCCESS, res);
}

test "nice: executes with -n increment" {
    const allocator = std.testing.allocator;
    const res = run(allocator, &.{ "-n", "5", "echo", "ziggybox_nice_test" });
    try std.testing.expectEqual(common_error.EXIT_SUCCESS, res);
}

test "nice: executes with attached -n increment" {
    const allocator = std.testing.allocator;
    const res = run(allocator, &.{ "-n5", "echo", "ziggybox_nice_test" });
    try std.testing.expectEqual(common_error.EXIT_SUCCESS, res);
}

test "nice: executes with historical -increment syntax" {
    const allocator = std.testing.allocator;
    const res = run(allocator, &.{ "-5", "echo", "ziggybox_nice_test" });
    try std.testing.expectEqual(common_error.EXIT_SUCCESS, res);
}
