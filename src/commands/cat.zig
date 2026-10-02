//! POSIX.1-2024 (IEEE Std 1003.1-2024) compliant implementation of `cat`.
//!
//! Specification References:
//! - IEEE Std 1003.1-2024, Shell & Utilities (XCU), Section: `cat`
//!   - SYNOPSIS: `cat [-u] [file...]`
//!   - DESCRIPTION: Reads files in sequence and writes their contents to standard
//!     output in the same sequence.
//!   - OPTIONS:
//!       -u: Write bytes from the input file to the standard output without delay
//!           as each is read (unbuffered write).
//!       Conforms to Utility Syntax Guidelines (Guideline 10: '--' terminates options).
//!   - OPERANDS:
//!       file: Pathname of an input file. If no file operands are specified,
//!             the standard input shall be used. If a file is '-', read from
//!             standard input at that point. Do not close standard input when
//!             referenced this way, and accept multiple occurrences of '-'.
//!   - STDOUT: Sequence of bytes read from input files. If stdout is a regular file
//!             and is the same file as any input file operands, treat as an error.
//!   - STDERR: Used only for diagnostic messages.
//!   - EXIT STATUS:
//!       0: All input files were output successfully.
//!       >0: An error occurred.
//!
//! Resource Constraint:
//! - Zero dynamic allocations. Uses fixed-size stack buffers for I/O.

const std = @import("std");
const common_args = @import("../common/args.zig");
const common_error = @import("../common/error.zig");

pub const BUFFER_SIZE: usize = 16 * 1024; // 16 KiB buffer safe for 32-bit and 64-bit stacks

pub const PumpResult = union(enum) {
    success: void,
    read_err: anyerror,
    write_err: anyerror,
};

/// Pump data from `in_file` to standard output.
/// If `unbuffered` is true, write directly via `writeStreamingAll` without delay.
/// If `unbuffered` is false, write to the buffered `stdout_writer`.
pub fn pumpFile(
    io: std.Io,
    in_file: std.Io.File,
    stdout_file: std.Io.File,
    stdout_writer: ?*std.Io.File.Writer,
    unbuffered: bool,
) PumpResult {
    var buf: [BUFFER_SIZE]u8 = undefined;

    while (true) {
        const bytes_read = in_file.readStreaming(io, &.{&buf}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return .{ .read_err = e },
        };
        if (bytes_read == 0) break;

        if (unbuffered) {
            stdout_file.writeStreamingAll(io, buf[0..bytes_read]) catch |err| {
                return .{ .write_err = err };
            };
        } else {
            stdout_writer.?.interface.writeAll(buf[0..bytes_read]) catch |err| {
                return .{ .write_err = err };
            };
        }
    }

    return .success;
}

/// Checks if two open file handles refer to the exact same regular file.
pub fn isSameRegularFile(io: std.Io, f1: std.Io.File, f2: std.Io.File) bool {
    const s1 = f1.stat(io) catch return false;
    if (s1.kind != .file) return false;

    const s2 = f2.stat(io) catch return false;
    if (s2.kind != .file) return false;

    return s1.inode != 0 and s1.inode == s2.inode;
}

pub fn run(allocator: std.mem.Allocator, args: []const [:0]const u8) u8 {
    // Zero dynamic allocations for cat.
    _ = allocator;

    const io = std.Io.Threaded.global_single_threaded.io();
    var unbuffered = false;

    var parser = common_args.ArgParser.init(args);
    while (parser.next("u")) |opt| {
        switch (opt) {
            'u' => unbuffered = true,
            else => {
                common_error.report("cat", "invalid option", error.InvalidArgument);
                return common_error.EXIT_SYNTAX;
            },
        }
    }

    const operands = parser.remaining();
    const stdout_file = std.Io.File.stdout();

    // 16 KiB buffer for deterministic, high-throughput buffered output.
    var stdout_buf: [BUFFER_SIZE]u8 = undefined;
    var fw = if (!unbuffered) stdout_file.writerStreaming(io, &stdout_buf) else null;

    var exit_status: u8 = common_error.EXIT_SUCCESS;

    if (operands.len == 0) {
        // No operands: read from stdin
        const res = pumpFile(io, std.Io.File.stdin(), stdout_file, if (fw) |*w| w else null, unbuffered);
        switch (res) {
            .success => {},
            .read_err => |err| {
                common_error.report("cat", null, err);
                exit_status = common_error.toExitCode(err);
            },
            .write_err => |err| {
                common_error.report("cat", null, err);
                return common_error.toExitCode(err);
            },
        }
    } else {
        for (operands) |path| {
            if (std.mem.eql(u8, path, "-")) {
                // '-' specifies reading from standard input at this position.
                // Do not close stdin.
                const res = pumpFile(io, std.Io.File.stdin(), stdout_file, if (fw) |*w| w else null, unbuffered);
                switch (res) {
                    .success => {},
                    .read_err => |err| {
                        common_error.report("cat", "-", err);
                        exit_status = common_error.toExitCode(err);
                    },
                    .write_err => |err| {
                        common_error.report("cat", null, err);
                        return common_error.toExitCode(err);
                    },
                }
            } else {
                const in_file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch |err| {
                    common_error.report("cat", path, err);
                    exit_status = common_error.toExitCode(err);
                    continue;
                };
                defer in_file.close(io);

                // POSIX: If standard output is a regular file, and is the same file
                // as any of the input file operands, treat this as an error.
                if (isSameRegularFile(io, in_file, stdout_file)) {
                    common_error.report("cat", path, error.InvalidArgument);
                    exit_status = common_error.EXIT_FAILURE;
                    continue;
                }

                const res = pumpFile(io, in_file, stdout_file, if (fw) |*w| w else null, unbuffered);
                switch (res) {
                    .success => {},
                    .read_err => |err| {
                        common_error.report("cat", path, err);
                        exit_status = common_error.toExitCode(err);
                    },
                    .write_err => |err| {
                        common_error.report("cat", null, err);
                        return common_error.toExitCode(err);
                    },
                }
            }
        }
    }

    if (fw) |*w| {
        w.flush() catch |err| {
            common_error.report("cat", null, err);
            return common_error.toExitCode(err);
        };
    }

    return exit_status;
}

pub fn main(init: std.process.Init) u8 {
    const all_args = init.minimal.args.toSlice(init.arena.allocator()) catch |err| {
        common_error.report("cat", null, err);
        return common_error.EXIT_FAILURE;
    };
    const cmd_args = if (all_args.len > 1) all_args[1..] else &.{};
    return run(init.arena.allocator(), cmd_args);
}

// ============================================================================
// POSIX Conformance Tests
// ============================================================================

test "cat: option parsing and invalid flag" {
    const allocator = std.testing.allocator;

    // Invalid option returns EXIT_SYNTAX
    const code = run(allocator, &.{"-z"});
    try std.testing.expectEqual(common_error.EXIT_SYNTAX, code);
}

test "cat: single file content and multiple files concatenation" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const test_dir = "zig-cache/tmp_test_cat";
    std.Io.Dir.cwd().createDirPath(io, test_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, test_dir) catch {};

    const file1_path = "zig-cache/tmp_test_cat/file1.txt";
    const file2_path = "zig-cache/tmp_test_cat/file2.txt";

    // Write test content to file1
    {
        const f1 = try std.Io.Dir.cwd().createFile(io, file1_path, .{});
        defer f1.close(io);
        try f1.writeStreamingAll(io, "First line of content\n");
    }

    // Write test content to file2
    {
        const f2 = try std.Io.Dir.cwd().createFile(io, file2_path, .{});
        defer f2.close(io);
        try f2.writeStreamingAll(io, "Second line of content\n");
    }

    // Test single file
    const exit1 = run(allocator, &.{file1_path});
    try std.testing.expectEqual(common_error.EXIT_SUCCESS, exit1);

    // Test unbuffered flag -u
    const exit_u = run(allocator, &.{ "-u", file1_path });
    try std.testing.expectEqual(common_error.EXIT_SUCCESS, exit_u);

    // Test end of options --
    const exit_opt_end = run(allocator, &.{ "--", file1_path });
    try std.testing.expectEqual(common_error.EXIT_SUCCESS, exit_opt_end);

    const exit_u_opt_end = run(allocator, &.{ "-u", "--", file1_path });
    try std.testing.expectEqual(common_error.EXIT_SUCCESS, exit_u_opt_end);

    // Test multiple files concatenation
    const exit_multi = run(allocator, &.{ file1_path, file2_path });
    try std.testing.expectEqual(common_error.EXIT_SUCCESS, exit_multi);
}

test "cat: nonexistent file and directory error handling" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const test_dir = "zig-cache/tmp_test_cat_err";
    std.Io.Dir.cwd().createDirPath(io, test_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, test_dir) catch {};

    const nonexistent = "zig-cache/tmp_test_cat_err/does_not_exist.txt";
    const valid_file = "zig-cache/tmp_test_cat_err/valid.txt";

    {
        const f = try std.Io.Dir.cwd().createFile(io, valid_file, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "valid data\n");
    }

    // Nonexistent file returns error
    const exit_nonexistent = run(allocator, &.{nonexistent});
    try std.testing.expectEqual(common_error.EXIT_FAILURE, exit_nonexistent);

    // Directory operand returns error
    const exit_dir = run(allocator, &.{test_dir});
    try std.testing.expectEqual(common_error.EXIT_FAILURE, exit_dir);

    // Nonexistent file alongside valid file continues and returns failure
    const exit_mixed = run(allocator, &.{ nonexistent, valid_file });
    try std.testing.expectEqual(common_error.EXIT_FAILURE, exit_mixed);
}

test "cat: pumpFile content verification" {
    const io = std.Io.Threaded.global_single_threaded.io();

    const test_dir = "zig-cache/tmp_test_cat_pump";
    std.Io.Dir.cwd().createDirPath(io, test_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, test_dir) catch {};

    const src_path = "zig-cache/tmp_test_cat_pump/src.bin";
    const dst_path = "zig-cache/tmp_test_cat_pump/dst.bin";

    const payload = "Hello POSIX World! 1234567890\nSpecial characters: \x00\xff\r\n";
    {
        const src = try std.Io.Dir.cwd().createFile(io, src_path, .{});
        defer src.close(io);
        try src.writeStreamingAll(io, payload);
    }

    // Pump unbuffered
    {
        const src = try std.Io.Dir.cwd().openFile(io, src_path, .{ .mode = .read_only });
        defer src.close(io);
        const dst = try std.Io.Dir.cwd().createFile(io, dst_path, .{});
        defer dst.close(io);

        const res = pumpFile(io, src, dst, null, true);
        try std.testing.expectEqual(PumpResult.success, res);
    }

    // Read dst back and verify exact content
    {
        const dst = try std.Io.Dir.cwd().openFile(io, dst_path, .{ .mode = .read_only });
        defer dst.close(io);

        var read_buf: [256]u8 = undefined;
        const n = try dst.readStreaming(io, &.{&read_buf});
        try std.testing.expectEqualStrings(payload, read_buf[0..n]);
    }
}
