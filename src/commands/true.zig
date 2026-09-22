//! POSIX.1-2024 (IEEE Std 1003.1-2024) compliant implementation of `true`.
//!
//! Specification References:
//! - IEEE Std 1003.1-2024, Shell & Utilities (XCU), Section: `true`
//!   - SYNOPSIS: `true`
//!   - DESCRIPTION: "The true utility shall return with exit code zero."
//!   - EXIT STATUS: 0

const std = @import("std");

/// Entry point matching the ziggybox command interface standard:
/// `pub fn run(allocator: std.mem.Allocator, args: []const [:0]const u8) u8`
pub fn run(allocator: std.mem.Allocator, args: []const [:0]const u8) u8 {
    _ = allocator;
    _ = args;
    return 0;
}

pub fn main() u8 {
    return 0;
}
