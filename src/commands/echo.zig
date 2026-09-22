//! POSIX.1-2024 (IEEE Std 1003.1-2024) compliant implementation of `echo`.
//!
//! Specification References:
//! - IEEE Std 1003.1-2024, Shell & Utilities (XCU), Section: `echo`
//!   - SYNOPSIS: `echo [string...]`
//!   - OPTIONS: "Implementations shall not support any options."
//!              "The echo utility shall not recognize the '--' argument...
//!               '--' shall be recognized as a string operand."
//!   - OPERANDS: Under [XSI] conformant behavior:
//!       - If the first operand consists of '-' followed by chars from {'e', 'E', 'n'},
//!         it is treated as a string operand to be written.
//!       - Escape sequences supported within operands:
//!           \a     Write an <alert> (ASCII 0x07).
//!           \b     Write a <backspace> (ASCII 0x08).
//!           \c     Suppress the <newline> that otherwise follows the final argument.
//!                  All characters following the '\c' in the arguments shall be ignored.
//!           \f     Write a <form-feed> (ASCII 0x0C).
//!           \n     Write a <newline> (ASCII 0x0A).
//!           \r     Write a <carriage-return> (ASCII 0x0D).
//!           \t     Write a <tab> (ASCII 0x09).
//!           \v     Write a <vertical-tab> (ASCII 0x0B).
//!           \\     Write a <backslash> character ('\').
//!           \0num  Write an 8-bit value that is the zero, one, two, or
//!                  three-digit octal number num.
//!       - Unrecognized backslash sequences write the backslash and character.
//!   - STDOUT: Operands separated by single <space> characters; trailing <newline>
//!             follows the last argument unless suppressed by \c.
//!   - STDERR: Used only for diagnostic messages.
//!   - EXIT STATUS:
//!       0: Successful completion.
//!       >0: An error occurred.
//!
//! Resource Constraint:
//! - Zero dynamic allocations. Uses fixed-size stack buffers for I/O.

const std = @import("std");

/// Core echo writing logic decoupled from the underlying I/O destination for testability.
/// Returns `true` if trailing newline should be output, or `false` if `\c` suppressed it.
fn writeEcho(writer: *std.Io.Writer, args: []const [:0]const u8) !bool {
    for (args, 0..) |arg, arg_idx| {
        // POSIX: Arguments shall be separated by single <space> characters.
        if (arg_idx > 0) {
            try writer.writeByte(' ');
        }

        var i: usize = 0;
        while (i < arg.len) {
            const c = arg[i];
            if (c == '\\') {
                i += 1;
                if (i >= arg.len) {
                    // Trailing backslash at end of argument is written literally.
                    try writer.writeByte('\\');
                    break;
                }
                switch (arg[i]) {
                    // Alert (bell)
                    'a' => try writer.writeByte(0x07),
                    // Backspace
                    'b' => try writer.writeByte(0x08),
                    // Suppress trailing newline and terminate output immediately
                    'c' => return false,
                    // Form feed
                    'f' => try writer.writeByte(0x0c),
                    // Newline
                    'n' => try writer.writeByte('\n'),
                    // Carriage return
                    'r' => try writer.writeByte('\r'),
                    // Horizontal tab
                    't' => try writer.writeByte('\t'),
                    // Vertical tab
                    'v' => try writer.writeByte(0x0b),
                    // Backslash
                    '\\' => try writer.writeByte('\\'),
                    // \0num: 0, 1, 2, or 3-digit octal sequence
                    '0' => {
                        i += 1;
                        var oct_val: u8 = 0;
                        var digits: usize = 0;
                        while (digits < 3 and i < arg.len and arg[i] >= '0' and arg[i] <= '7') : ({
                            digits += 1;
                            i += 1;
                        }) {
                            oct_val = @truncate((@as(u16, oct_val) << 3) | (arg[i] - '0'));
                        }
                        try writer.writeByte(oct_val);
                        // Digits already consumed, avoid double increment
                        continue;
                    },
                    // Non-standard or unrecognized escape: output backslash and character literally
                    else => {
                        try writer.writeByte('\\');
                        try writer.writeByte(arg[i]);
                    },
                }
                i += 1;
            } else {
                try writer.writeByte(c);
                i += 1;
            }
        }
    }

    return true;
}

/// Print diagnostic error message to stderr in POSIX standard format:
/// `<command>: <error message>\n`
fn printError(io: std.Io, comptime msg: []const u8) void {
    const stderr_file = std.Io.File.stderr();
    var err_buf: [256]u8 = undefined;
    var err_fw = stderr_file.writerStreaming(io, &err_buf);
    const err_writer = &err_fw.interface;
    _ = err_writer.writeAll("echo: " ++ msg) catch {};
    _ = err_fw.flush() catch {};
}

/// Entry point matching the ziggybox command interface specification:
/// `pub fn run(allocator: std.mem.Allocator, args: []const [:0]const u8) u8`
pub fn run(allocator: std.mem.Allocator, args: []const [:0]const u8) u8 {
    // Zero dynamic allocations for echo.
    _ = allocator;

    const io = std.Io.Threaded.global_single_threaded.io();
    const stdout_file = std.Io.File.stdout();

    // 4 KiB stack buffer for deterministic, high-throughput buffered output.
    var buf: [4096]u8 = undefined;
    var fw = stdout_file.writerStreaming(io, &buf);
    const writer = &fw.interface;

    const should_print_newline = writeEcho(writer, args) catch {
        printError(io, "write error\n");
        return 1;
    };

    if (should_print_newline) {
        writer.writeByte('\n') catch {
            printError(io, "write error\n");
            return 1;
        };
    }

    fw.flush() catch {
        printError(io, "write error\n");
        return 1;
    };

    return 0;
}

/// Direct standalone execution support (e.g. `zig run src/commands/echo.zig -- ...`)
pub fn main(init: std.process.Init) u8 {
    const all_args = init.minimal.args.toSlice(init.arena.allocator()) catch {
        const io = init.io;
        printError(io, "out of memory\n");
        return 1;
    };
    const cmd_args = if (all_args.len > 1) all_args[1..] else &.{};
    return run(init.arena.allocator(), cmd_args);
}

// ============================================================================
// POSIX Conformance Tests
// ============================================================================

fn testEchoOutput(args: []const [:0]const u8) ![]u8 {
    var alloc_writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    errdefer alloc_writer.deinit();

    const should_nl = try writeEcho(&alloc_writer.writer, args);
    if (should_nl) {
        try alloc_writer.writer.writeByte('\n');
    }
    return alloc_writer.toOwnedSlice();
}

test "echo: empty arguments outputs single newline" {
    const res = try testEchoOutput(&.{});
    defer std.testing.allocator.free(res);
    try std.testing.expectEqualStrings("\n", res);
}

test "echo: single argument" {
    const res = try testEchoOutput(&.{"hello"});
    defer std.testing.allocator.free(res);
    try std.testing.expectEqualStrings("hello\n", res);
}

test "echo: multiple arguments separated by single space" {
    const res = try testEchoOutput(&.{ "hello", "posix", "world" });
    defer std.testing.allocator.free(res);
    try std.testing.expectEqualStrings("hello posix world\n", res);
}

test "echo: '--' treated as string operand (POSIX Guideline 10 disabled)" {
    const res = try testEchoOutput(&.{ "--", "hello" });
    defer std.testing.allocator.free(res);
    try std.testing.expectEqualStrings("-- hello\n", res);
}

test "echo: '-n' and '-e' treated as string operands (POSIX XSI specification)" {
    const res = try testEchoOutput(&.{ "-n", "hello" });
    defer std.testing.allocator.free(res);
    try std.testing.expectEqualStrings("-n hello\n", res);

    const res_e = try testEchoOutput(&.{ "-e", "hello" });
    defer std.testing.allocator.free(res_e);
    try std.testing.expectEqualStrings("-e hello\n", res_e);
}

test "echo: standard XSI escape sequences" {
    const res = try testEchoOutput(&.{"\\a\\b\\f\\n\\r\\t\\v\\\\"});
    defer std.testing.allocator.free(res);
    try std.testing.expectEqualStrings("\x07\x08\x0c\n\r\t\x0b\\\n", res);
}

test "echo: octal escape sequences (\\0num)" {
    const res = try testEchoOutput(&.{ "\\0", "\\07", "\\077", "\\0101", "\\01019" });
    defer std.testing.allocator.free(res);
    // \0 -> 0x00, \07 -> 0x07, \077 -> 63 ('?'), \0101 -> 65 ('A'), \01019 -> 'A' followed by '9'
    try std.testing.expectEqualStrings("\x00 \x07 ? A A9\n", res);
}

test "echo: \\c in argument suppresses newline and drops remaining text and args" {
    const res1 = try testEchoOutput(&.{ "hello\\cworld", "ignored" });
    defer std.testing.allocator.free(res1);
    try std.testing.expectEqualStrings("hello", res1);

    const res2 = try testEchoOutput(&.{ "first", "second\\c", "third" });
    defer std.testing.allocator.free(res2);
    try std.testing.expectEqualStrings("first second", res2);
}

test "echo: unrecognized escape and trailing backslash written literally" {
    const res = try testEchoOutput(&.{ "test\\z", "end\\" });
    defer std.testing.allocator.free(res);
    try std.testing.expectEqualStrings("test\\z end\\\n", res);
}
