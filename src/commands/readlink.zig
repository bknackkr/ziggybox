//! POSIX.1-2024 (IEEE Std 1003.1-2024) compliant implementation of `readlink`.
//!
//! Specification References:
//! - IEEE Std 1003.1-2024, Shell & Utilities (XCU), Section: `readlink`
//!   - SYNOPSIS: `readlink [-n] file`
//!   - OPTIONS:
//!       -n: Do not output a trailing <newline> character.
//!   - OPERANDS:
//!       file: A pathname of a symbolic link to be read.
//!   - DESCRIPTION:
//!       If the file operand names a symbolic link, the readlink utility shall
//!       not follow the symbolic link when resolving file and shall write the
//!       contents of the symbolic link to standard output. If the -n option is
//!       not specified, the output to standard output shall be followed by a
//!       <newline> character.
//!       If file does not name a symbolic link, readlink shall write a diagnostic
//!       message to standard error and exit with non-zero status.
//!   - EXIT STATUS:
//!       0: Successful completion.
//!       >0: An error occurred.
//!
//! Resource Constraint:
//! - Zero dynamic heap allocations in core logic (stack buffers only).

const std = @import("std");
const common_args = @import("../common/args.zig");
const common_error = @import("../common/error.zig");

/// Execute readlink utility per IEEE Std 1003.1-2024.
pub fn run(allocator: std.mem.Allocator, args: []const [:0]const u8) u8 {
    _ = allocator;

    var opt_n = false;
    var parser = common_args.ArgParser.init(args);

    while (parser.next("n")) |opt| {
        switch (opt) {
            'n' => opt_n = true,
            '?' => {
                common_error.report("readlink", "invalid option", error.InvalidArgument);
                return common_error.EXIT_SYNTAX;
            },
            ':' => {
                common_error.report("readlink", "missing argument", error.InvalidArgument);
                return common_error.EXIT_SYNTAX;
            },
            else => {
                common_error.report("readlink", "invalid option", error.InvalidArgument);
                return common_error.EXIT_SYNTAX;
            },
        }
    }

    const operands = parser.remaining();
    if (operands.len == 0) {
        common_error.report("readlink", "missing operand", error.InvalidArgument);
        return common_error.EXIT_SYNTAX;
    }
    if (operands.len > 1) {
        common_error.report("readlink", "extra operand", error.InvalidArgument);
        return common_error.EXIT_SYNTAX;
    }

    const file_path = operands[0];
    const io = std.Io.Threaded.global_single_threaded.io();

    var target_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const link_len = std.Io.Dir.cwd().readLink(io, file_path, &target_buf) catch |err| {
        common_error.report("readlink", file_path, err);
        return common_error.toExitCode(err);
    };

    const link_target = target_buf[0..link_len];

    const stdout_file = std.Io.File.stdout();
    var write_buf: [4096]u8 = undefined;
    var fw = stdout_file.writerStreaming(io, &write_buf);
    const writer = &fw.interface;

    writer.writeAll(link_target) catch |err| {
        common_error.report("readlink", null, err);
        return common_error.toExitCode(err);
    };

    if (!opt_n) {
        writer.writeByte('\n') catch |err| {
            common_error.report("readlink", null, err);
            return common_error.toExitCode(err);
        };
    }

    fw.flush() catch |err| {
        common_error.report("readlink", null, err);
        return common_error.toExitCode(err);
    };

    return common_error.EXIT_SUCCESS;
}

pub fn main(init: std.process.Init) u8 {
    const all_args = init.minimal.args.toSlice(init.arena.allocator()) catch |err| {
        common_error.report("readlink", null, err);
        return common_error.EXIT_FAILURE;
    };
    const cmd_args = if (all_args.len > 1) all_args[1..] else &.{};
    return run(init.arena.allocator(), cmd_args);
}

// ============================================================================
// Unit Tests
// ============================================================================

test "readlink: argument parsing and missing operands" {
    const allocator = std.testing.allocator;

    const exit_missing = run(allocator, &.{});
    try std.testing.expectEqual(common_error.EXIT_SYNTAX, exit_missing);

    const exit_extra = run(allocator, &.{ "file1", "file2" });
    try std.testing.expectEqual(common_error.EXIT_SYNTAX, exit_extra);

    const exit_invalid_opt = run(allocator, &.{"-z"});
    try std.testing.expectEqual(common_error.EXIT_SYNTAX, exit_invalid_opt);
}

test "readlink: read valid symlink" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const test_dir = "zig-cache/tmp_test_readlink";
    std.Io.Dir.cwd().deleteTree(io, test_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, test_dir);
    defer std.Io.Dir.cwd().deleteTree(io, test_dir) catch {};

    const target_content = "some_target_value";
    const link_path = test_dir ++ "/test_link";

    try std.Io.Dir.cwd().symLink(io, target_content, link_path, .{});

    // Test with default newline
    const exit_code = run(allocator, &.{link_path});
    try std.testing.expectEqual(common_error.EXIT_SUCCESS, exit_code);

    // Test with -n flag
    const exit_code_n = run(allocator, &.{ "-n", link_path });
    try std.testing.expectEqual(common_error.EXIT_SUCCESS, exit_code_n);

    // Test with -- delimiter
    const exit_code_delim = run(allocator, &.{ "--", link_path });
    try std.testing.expectEqual(common_error.EXIT_SUCCESS, exit_code_delim);
}

test "readlink: error on non-symlink and nonexistent file" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const test_dir = "zig-cache/tmp_test_readlink_err";
    std.Io.Dir.cwd().deleteTree(io, test_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, test_dir);
    defer std.Io.Dir.cwd().deleteTree(io, test_dir) catch {};

    const reg_file = test_dir ++ "/regular_file";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = reg_file, .data = "hello" });

    // Reading regular file should fail (NotLink -> 1)
    const exit_regular = run(allocator, &.{reg_file});
    try std.testing.expectEqual(common_error.EXIT_FAILURE, exit_regular);

    // Reading nonexistent file should fail (FileNotFound -> 1)
    const exit_nonexistent = run(allocator, &.{test_dir ++ "/does_not_exist"});
    try std.testing.expectEqual(common_error.EXIT_FAILURE, exit_nonexistent);
}
