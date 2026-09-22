const std = @import("std");

pub const EXIT_SUCCESS: u8 = 0;
pub const EXIT_FAILURE: u8 = 1;
pub const EXIT_SYNTAX: u8 = 2;
pub const EXIT_CANNOT_EXEC: u8 = 126;
pub const EXIT_NOT_FOUND: u8 = 127;

/// Prints: "<cmd>: <context>: <error description>\n" to stderr
pub fn report(cmd: []const u8, context: ?[]const u8, err: anyerror) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const stderr_file = std.Io.File.stderr();
    var buf: [256]u8 = undefined;
    var fw = stderr_file.writerStreaming(io, &buf);
    const stderr = &fw.interface;
    
    // Translates Zig error set to POSIX strerror equivalent and outputs
    // cleanly without allocating heap memory.
    const err_str = switch (err) {
        error.FileNotFound => "No such file or directory",
        error.AccessDenied => "Permission denied",
        error.IsDir => "Is a directory",
        error.NotDir => "Not a directory",
        error.FileTooBig => "File too large",
        error.NoSpaceLeft => "No space left on device",
        error.BrokenPipe => "Broken pipe",
        error.InvalidArgument => "Invalid argument",
        error.NameTooLong => "File name too long",
        error.SystemResources => "Resource temporarily unavailable",
        error.PathAlreadyExists => "File exists",
        error.SymLinkLoop => "Too many levels of symbolic links",
        error.NotOpenForReading => "Bad file descriptor",
        error.NotOpenForWriting => "Bad file descriptor",
        else => @errorName(err),
    };

    if (context) |ctx| {
        stderr.print("{s}: {s}: {s}\n", .{ cmd, ctx, err_str }) catch {};
    } else {
        stderr.print("{s}: {s}\n", .{ cmd, err_str }) catch {};
    }
    _ = fw.flush() catch {};
}

/// Maps an unexpected error to a standard exit status code.
pub fn toExitCode(err: anyerror) u8 {
    return switch (err) {
        error.FileNotFound => EXIT_FAILURE,
        error.AccessDenied => EXIT_FAILURE,
        error.InvalidArgument => EXIT_SYNTAX,
        error.BrokenPipe => 141, // 128 + SIGPIPE (13)
        else => EXIT_FAILURE,
    };
}
