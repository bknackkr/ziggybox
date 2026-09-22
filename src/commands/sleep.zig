//! POSIX.1-2024 (IEEE Std 1003.1-2024) compliant implementation of `sleep`.
//!
//! Specification References:
//! - IEEE Std 1003.1-2024, Shell & Utilities (XCU), Section: `sleep`
//!   - SYNOPSIS: `sleep time`
//!   - DESCRIPTION: Suspend execution for at least `time` seconds.
//!   - OPERANDS: `time` is a non-negative decimal integer specifying seconds.
//!   - OPTIONS: None. (Conforms to standard utility syntax, meaning `--` is supported).
//!   - EXIT STATUS:
//!       0: Successful completion (slept for at least `time`).
//!       >0: An error occurred.

const std = @import("std");
const common_error = @import("../common/error.zig");

pub fn run(allocator: std.mem.Allocator, args: []const [:0]const u8) u8 {
    _ = allocator;

    var operand_idx: usize = 0;

    // Handle standard utility syntax '--'
    if (args.len > 0 and std.mem.eql(u8, args[0], "--")) {
        operand_idx += 1;
    }

    if (operand_idx >= args.len) {
        common_error.report("sleep", "missing operand", error.InvalidArgument);
        return common_error.EXIT_FAILURE;
    }

    const time_str = args[operand_idx];

    // Check for unexpected extra arguments (strictly following POSIX)
    if (operand_idx + 1 < args.len) {
        common_error.report("sleep", "extra operand", error.InvalidArgument);
        return common_error.EXIT_FAILURE;
    }

    const seconds = std.fmt.parseInt(u64, time_str, 10) catch |err| {
        switch (err) {
            error.Overflow => common_error.report("sleep", time_str, error.InvalidArgument),
            error.InvalidCharacter => common_error.report("sleep", time_str, error.InvalidArgument),
        }
        return common_error.EXIT_FAILURE;
    };

    if (seconds > std.math.maxInt(i64)) {
        common_error.report("sleep", time_str, error.InvalidArgument);
        return common_error.EXIT_FAILURE;
    }

    const io = std.Io.Threaded.global_single_threaded.io();
    io.sleep(std.Io.Duration.fromSeconds(@intCast(seconds)), .awake) catch |err| {
        common_error.report("sleep", null, err);
        return common_error.EXIT_FAILURE;
    };

    return common_error.EXIT_SUCCESS;
}

pub fn main(init: std.process.Init) u8 {
    const all_args = init.minimal.args.toSlice(init.arena.allocator()) catch |err| {
        common_error.report("sleep", null, err);
        return common_error.EXIT_FAILURE;
    };
    const cmd_args = if (all_args.len > 1) all_args[1..] else &.{};
    return run(init.arena.allocator(), cmd_args);
}

// ============================================================================
// POSIX Conformance Tests
// ============================================================================

test "sleep: parses valid seconds" {
    // We can't easily test `sleep` running for seconds in unit tests without blocking,
    // so we just test the parsing of invalid/valid arguments where it fails fast.
    try std.testing.expectEqual(common_error.EXIT_FAILURE, run(std.testing.allocator, &.{}));
    try std.testing.expectEqual(common_error.EXIT_FAILURE, run(std.testing.allocator, &.{"--"}));
    try std.testing.expectEqual(common_error.EXIT_FAILURE, run(std.testing.allocator, &.{"invalid"}));
    try std.testing.expectEqual(common_error.EXIT_FAILURE, run(std.testing.allocator, &.{ "1", "2" }));
}

test "sleep: executes without error for zero seconds" {
    try std.testing.expectEqual(common_error.EXIT_SUCCESS, run(std.testing.allocator, &.{"0"}));
    try std.testing.expectEqual(common_error.EXIT_SUCCESS, run(std.testing.allocator, &.{ "--", "0" }));
}
