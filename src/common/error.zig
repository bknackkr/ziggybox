const std = @import("std");

pub const EXIT_SUCCESS: u8 = 0;
pub const EXIT_FAILURE: u8 = 1;
pub const EXIT_SYNTAX: u8 = 2;
pub const EXIT_CANNOT_EXEC: u8 = 126;
pub const EXIT_NOT_FOUND: u8 = 127;

/// Prints: "<cmd>: <context>: <error description>\n" to stderr
pub fn report(cmd: []const u8, context: ?[]const u8, err: anyerror) void {
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
        error.DirNotEmpty => "Directory not empty",
        error.ReadOnlyFileSystem => "Read-only file system",
        error.FileBusy => "Device or resource busy",
        error.PermissionDenied => "Permission denied",
        error.NotLink => "Invalid argument",
        error.CrossDevice => "Invalid cross-device link",
        error.LinkQuotaExceeded => "Too many links",
        error.OperationUnsupported => "Operation not supported",
        error.DiskQuota => "Disk quota exceeded",
        error.HardwareFailure => "Input/output error",
        error.BadPathName => "Invalid argument",
        error.NetworkNotFound => "No such host or network path",
        error.FileSystem => "File system error",
        else => @errorName(err),
    };

    if (context) |ctx| {
        std.debug.print("{s}: {s}: {s}\n", .{ cmd, ctx, err_str });
    } else {
        std.debug.print("{s}: {s}\n", .{ cmd, err_str });
    }
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

// ============================================================================
// Unit Tests
// ============================================================================

test "error: exit code mapping" {
    try std.testing.expectEqual(EXIT_FAILURE, toExitCode(error.FileNotFound));
    try std.testing.expectEqual(EXIT_FAILURE, toExitCode(error.AccessDenied));
    try std.testing.expectEqual(EXIT_SYNTAX, toExitCode(error.InvalidArgument));
    try std.testing.expectEqual(@as(u8, 141), toExitCode(error.BrokenPipe));
    try std.testing.expectEqual(EXIT_FAILURE, toExitCode(error.Unexpected));
}

test "error: report execution" {
    report("test_cmd", "test_context", error.FileNotFound);
    report("test_cmd", null, error.AccessDenied);
}

