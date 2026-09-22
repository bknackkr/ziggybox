//! POSIX.1-2024 (IEEE Std 1003.1-2024) compliant implementation of `false`.
//!
//! Specification References:
//! - IEEE Std 1003.1-2024, Shell & Utilities (XCU), Section: `false`
//!   - SYNOPSIS: `false`
//!   - DESCRIPTION: "The false utility shall return with a non-zero exit code."
//!   - EXIT STATUS: >0 (returns 1)

const std = @import("std");

/// Entry point matching the ziggybox command interface standard:
/// `pub fn run(allocator: std.mem.Allocator, args: []const [:0]const u8) u8`
pub fn run(allocator: std.mem.Allocator, args: []const [:0]const u8) u8 {
    _ = allocator;
    _ = args;
    return 1;
}

pub fn main() u8 {
    return 1;
}
