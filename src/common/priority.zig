//! POSIX process scheduling priority (nice value) abstractions.
//!
//! Specification References:
//! - IEEE Std 1003.1-2024, System Interfaces (XSH), Section: `getpriority`, `setpriority`
//! - Linux man pages: getpriority(2), setpriority(2)

const std = @import("std");
const builtin = @import("builtin");

/// Specifies the target entity whose priority is to be retrieved or set.
pub const Which = enum(u32) {
    process = 0, // PRIO_PROCESS (who is a PID)
    pgrp = 1, // PRIO_PGRP (who is a process group ID)
    user = 2, // PRIO_USER (who is a UID)
};

pub const PRIO_MIN: i32 = -20;
pub const PRIO_MAX: i32 = 19;

/// Retrieve the nice value of a process, process group, or user.
/// `who = 0` denotes the calling process, process group, or user.
pub fn getPriority(which: Which, who: u32) !i32 {
    if (builtin.os.tag == .linux) {
        const rc = std.os.linux.syscall2(.getpriority, @intFromEnum(which), who);
        const err = std.posix.errno(rc);
        if (err != .SUCCESS) {
            return switch (err) {
                .SRCH => error.ProcessNotFound,
                .INVAL => error.InvalidArgument,
                .PERM, .ACCES => error.AccessDenied,
                else => error.Unexpected,
            };
        }
        // Linux kernel returns 20 - niceval (in range 1..40 for nice -20..19).
        return 20 - @as(i32, @intCast(rc));
    } else if (builtin.os.tag == .windows) {
        // Fallback for non-POSIX platforms
        return 0;
    } else {
        return error.OperationUnsupported;
    }
}

/// Set the nice value of a process, process group, or user.
/// The requested `nice_val` is clamped to the system range [PRIO_MIN, PRIO_MAX].
pub fn setPriority(which: Which, who: u32, nice_val: i32) !void {
    const clamped_nice = std.math.clamp(nice_val, PRIO_MIN, PRIO_MAX);

    if (builtin.os.tag == .linux) {
        const rc = std.os.linux.syscall3(
            .setpriority,
            @intFromEnum(which),
            who,
            @as(usize, @bitCast(@as(isize, clamped_nice))),
        );
        const err = std.posix.errno(rc);
        if (err != .SUCCESS) {
            return switch (err) {
                .SRCH => error.ProcessNotFound,
                .INVAL => error.InvalidArgument,
                .PERM, .ACCES => error.AccessDenied,
                else => error.Unexpected,
            };
        }
    } else if (builtin.os.tag == .windows) {
        return;
    } else {
        return error.OperationUnsupported;
    }
}

// ============================================================================
// Unit Tests
// ============================================================================

test "priority: getPriority current process" {
    if (builtin.os.tag == .linux) {
        const prio = try getPriority(.process, 0);
        // Valid nice range in Linux is -20 to 19
        try std.testing.expect(prio >= PRIO_MIN and prio <= PRIO_MAX);
    }
}

test "priority: getPriority non-existent process" {
    if (builtin.os.tag == .linux) {
        // PID 4194303 is typically non-existent (exceeds standard pid_max or unallocated)
        const res = getPriority(.process, 4194300);
        try std.testing.expectError(error.ProcessNotFound, res);
    }
}

test "priority: clamp bounds" {
    try std.testing.expectEqual(PRIO_MIN, std.math.clamp(-50, PRIO_MIN, PRIO_MAX));
    try std.testing.expectEqual(PRIO_MAX, std.math.clamp(100, PRIO_MIN, PRIO_MAX));
    try std.testing.expectEqual(@as(i32, 5), std.math.clamp(5, PRIO_MIN, PRIO_MAX));
}
