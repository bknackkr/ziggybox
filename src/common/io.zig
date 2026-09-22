const std = @import("std");

pub const BUFFER_SIZE: usize = 16 * 1024; // 16 KB safe for 32-bit stack limits

/// Copies all data from `src` to `dst` using an internal stack buffer.
/// Returns total bytes written or an error.
pub fn pump(src: std.posix.fd_t, dst: std.posix.fd_t) !u64 {
    var buf: [BUFFER_SIZE]u8 = undefined;
    var total: u64 = 0;
    while (true) {
        const bytes_read = try std.posix.read(src, &buf);
        if (bytes_read == 0) break;
        
        var written: usize = 0;
        while (written < bytes_read) {
            const w = try std.posix.write(dst, buf[written..bytes_read]);
            if (w == 0) return error.UnexpectedZeroWrite; // Safeguard against weird descriptors
            written += w;
        }
        total += bytes_read;
    }
    return total;
}

/// Standardized unbuffered write to stderr for warnings/errors.
pub fn printError(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}
