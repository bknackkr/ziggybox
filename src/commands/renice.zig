//! POSIX.1-2024 (IEEE Std 1003.1-2024) compliant implementation of `renice`.
//!
//! Specification References:
//! - IEEE Std 1003.1-2024, Shell & Utilities (XCU), Section: `renice`
//!   - SYNOPSIS: `renice [-g|-p|-u] -n increment ID...`
//!   - DESCRIPTION: Sets the nice values of one or more running processes.
//!   - OPTIONS:
//!       -g: Interpret following operands as process group IDs.
//!       -n increment: Adjust nice value by signed decimal integer increment.
//!       -p: Interpret following operands as process IDs (default).
//!       -u: Interpret following operands as users (username or numeric UID).
//!   - OPERANDS:
//!       ID: Process ID, process group ID, or user name/user ID.
//!   - EXIT STATUS:
//!       0: Successful completion.
//!       >0: An error occurred.

const std = @import("std");
const common_args = @import("../common/args.zig");
const common_error = @import("../common/error.zig");
const common_priority = @import("../common/priority.zig");
const common_user = @import("../common/user.zig");

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
    _ = allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    if (args.len == 0) {
        common_error.report("renice", "missing operands", error.InvalidArgument);
        return common_error.EXIT_FAILURE;
    }

    var increment: ?i32 = null;
    var current_target: common_priority.Which = .process;
    var has_targets = false;
    var exit_code: u8 = common_error.EXIT_SUCCESS;

    var arg_idx: usize = 0;

    // Check for legacy/traditional syntax: renice <priority_or_increment> ID...
    if (args.len >= 2 and !std.mem.startsWith(u8, args[0], "-")) {
        if (parseIncrement(args[0])) |inc| {
            increment = inc;
            arg_idx = 1;
        }
    } else if (args.len >= 2 and (args[0][0] == '-' or args[0][0] == '+') and args[0].len > 1 and std.ascii.isDigit(args[0][1])) {
        if (parseIncrement(args[0])) |inc| {
            increment = inc;
            arg_idx = 1;
        }
    }

    // Process arguments respecting Guideline 9 exemption (options -g, -p, -u can be interspersed)
    while (arg_idx < args.len) : (arg_idx += 1) {
        const arg = args[arg_idx];

        if (std.mem.eql(u8, arg, "--")) {
            // End of options, following args are strictly target IDs
            arg_idx += 1;
            while (arg_idx < args.len) : (arg_idx += 1) {
                const target_str = args[arg_idx];
                const inc_val = increment orelse 0;
                if (!reniceTarget(io, current_target, target_str, inc_val)) {
                    exit_code = common_error.EXIT_FAILURE;
                }
                has_targets = true;
            }
            break;
        }

        if (std.mem.eql(u8, arg, "-g")) {
            current_target = .pgrp;
            continue;
        }

        if (std.mem.eql(u8, arg, "-p")) {
            current_target = .process;
            continue;
        }

        if (std.mem.eql(u8, arg, "-u")) {
            current_target = .user;
            continue;
        }

        if (std.mem.eql(u8, arg, "-n")) {
            arg_idx += 1;
            if (arg_idx >= args.len) {
                common_error.report("renice", "option requires an argument -- 'n'", error.InvalidArgument);
                return common_error.EXIT_FAILURE;
            }
            const inc_str = args[arg_idx];
            increment = parseIncrement(inc_str) orelse {
                common_error.report("renice", inc_str, error.InvalidArgument);
                return common_error.EXIT_FAILURE;
            };
            continue;
        }

        if (std.mem.startsWith(u8, arg, "-n")) {
            const inc_str = arg[2..];
            increment = parseIncrement(inc_str) orelse {
                common_error.report("renice", inc_str, error.InvalidArgument);
                return common_error.EXIT_FAILURE;
            };
            continue;
        }

        // Check if unknown option flag
        if (std.mem.startsWith(u8, arg, "-") and arg.len > 1 and !std.ascii.isDigit(arg[1])) {
            common_error.report("renice", arg, error.InvalidArgument);
            return common_error.EXIT_FAILURE;
        }

        // Operand / Target ID
        const inc_val = increment orelse {
            common_error.report("renice", "missing -n increment option", error.InvalidArgument);
            return common_error.EXIT_FAILURE;
        };

        if (!reniceTarget(io, current_target, arg, inc_val)) {
            exit_code = common_error.EXIT_FAILURE;
        }
        has_targets = true;
    }

    if (!has_targets) {
        common_error.report("renice", "no targets specified", error.InvalidArgument);
        return common_error.EXIT_FAILURE;
    }

    return exit_code;
}

/// Renice an individual process, process group, or user target.
/// Returns true on success, false on error.
fn reniceTarget(
    io: std.Io,
    which: common_priority.Which,
    target_str: []const u8,
    increment: i32,
) bool {
    switch (which) {
        .process, .pgrp => {
            const id = std.fmt.parseInt(u32, target_str, 10) catch {
                common_error.report("renice", target_str, error.InvalidArgument);
                return false;
            };
            return reniceById(which, target_str, id, increment);
        },
        .user => {
            // First lookup username in /etc/passwd
            if (common_user.findUidByName(io, target_str)) |uid| {
                return reniceById(.user, target_str, uid, increment);
            }
            // Fallback: parse numeric UID
            if (std.fmt.parseInt(u32, target_str, 10)) |uid| {
                return reniceById(.user, target_str, uid, increment);
            } else |_| {}
            std.debug.print("renice: {s}: unknown user\n", .{target_str});
            return false;
        },
    }
}

fn reniceById(
    which: common_priority.Which,
    display_str: []const u8,
    id: u32,
    increment: i32,
) bool {
    const cur_prio = common_priority.getPriority(which, id) catch |err| {
        common_error.report("renice", display_str, err);
        return false;
    };

    const target_prio = cur_prio + increment;
    common_priority.setPriority(which, id, target_prio) catch |err| {
        common_error.report("renice", display_str, err);
        return false;
    };

    return true;
}

pub fn main(init: std.process.Init) u8 {
    const all_args = init.minimal.args.toSlice(init.arena.allocator()) catch |err| {
        common_error.report("renice", null, err);
        return common_error.EXIT_FAILURE;
    };
    const cmd_args = if (all_args.len > 1) all_args[1..] else &.{};
    return run(init.arena.allocator(), cmd_args);
}

// ============================================================================
// Unit Tests
// ============================================================================

test "renice: missing operands returns failure" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqual(common_error.EXIT_FAILURE, run(allocator, &.{}));
}

test "renice: missing -n argument returns failure" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqual(common_error.EXIT_FAILURE, run(allocator, &.{"-n"}));
    try std.testing.expectEqual(common_error.EXIT_FAILURE, run(allocator, &.{ "-n", "1234" }));
}

test "renice: invalid increment returns failure" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqual(common_error.EXIT_FAILURE, run(allocator, &.{ "-n", "abc", "1234" }));
}

test "renice: non-existent process target returns failure" {
    const allocator = std.testing.allocator;
    // PID 4194300 is non-existent
    const res = run(allocator, &.{ "-n", "5", "-p", "4194300" });
    try std.testing.expectEqual(common_error.EXIT_FAILURE, res);
}

test "renice: unknown user returns failure" {
    const allocator = std.testing.allocator;
    const res = run(allocator, &.{ "-n", "5", "-u", "nonexistent_user_ziggybox_xyz" });
    try std.testing.expectEqual(common_error.EXIT_FAILURE, res);
}

test "renice: current process adjustment" {
    const allocator = std.testing.allocator;
    // Target PID 0 refers to the calling process in getpriority/setpriority
    const cur = common_priority.getPriority(.process, 0) catch 0;
    defer _ = common_priority.setPriority(.process, 0, cur) catch {};

    // Adjust nice by 0 (noop priority modification)
    const res = run(allocator, &.{ "-n", "0", "-p", "0" });
    try std.testing.expectEqual(common_error.EXIT_SUCCESS, res);
}

test "renice: legacy syntax current process adjustment" {
    const allocator = std.testing.allocator;
    const cur = common_priority.getPriority(.process, 0) catch 0;
    defer _ = common_priority.setPriority(.process, 0, cur) catch {};

    // Adjust nice by 0 via legacy syntax: renice 0 0
    const res = run(allocator, &.{ "0", "0" });
    try std.testing.expectEqual(common_error.EXIT_SUCCESS, res);
}
