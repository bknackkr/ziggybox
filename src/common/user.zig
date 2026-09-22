const std = @import("std");

/// Search /etc/passwd for a username and return the UID if found.
pub fn findUidByName(io: std.Io, username: []const u8) ?u32 {
    if (username.len == 0) return null;

    var file = std.Io.Dir.openFileAbsolute(io, "/etc/passwd", .{}) catch return null;
    defer file.close(io);

    var file_buf: [2048]u8 = undefined;
    var reader = file.readerStreaming(io, &file_buf);

    while (reader.interface.takeDelimiter('\n') catch null) |line| {
        // Format: username:password:uid:gid:gecos:homedir:shell
        var it = std.mem.splitScalar(u8, line, ':');
        const file_username = it.next() orelse continue;
        if (!std.mem.eql(u8, file_username, username)) continue;

        _ = it.next() orelse continue; // password
        const uid_str = it.next() orelse continue;
        const uid = std.fmt.parseInt(u32, uid_str, 10) catch continue;
        return uid;
    }
    return null;
}

/// Search /etc/group for a group name and return the GID if found.
pub fn findGidByName(io: std.Io, groupname: []const u8) ?u32 {
    if (groupname.len == 0) return null;

    var file = std.Io.Dir.openFileAbsolute(io, "/etc/group", .{}) catch return null;
    defer file.close(io);

    var file_buf: [2048]u8 = undefined;
    var reader = file.readerStreaming(io, &file_buf);

    while (reader.interface.takeDelimiter('\n') catch null) |line| {
        // Format: groupname:password:gid:user_list
        var it = std.mem.splitScalar(u8, line, ':');
        const file_groupname = it.next() orelse continue;
        if (!std.mem.eql(u8, file_groupname, groupname)) continue;

        _ = it.next() orelse continue; // password
        const gid_str = it.next() orelse continue;
        const gid = std.fmt.parseInt(u32, gid_str, 10) catch continue;
        return gid;
    }
    return null;
}

// ============================================================================
// Unit Tests
// ============================================================================

test "user: parsing test logic" {
    // Tests for these functions directly depend on system files (/etc/passwd)
    // We will just do a basic test ensuring root is UID 0 on POSIX platforms.
    const builtin = @import("builtin");
    if (builtin.os.tag == .linux or builtin.os.tag == .macos) {
        const io = std.Io.Threaded.global_single_threaded.io();
        const root_uid = findUidByName(io, "root");
        if (root_uid) |uid| {
            try std.testing.expectEqual(@as(u32, 0), uid);
        }
    }
}
