//! POSIX.1-2024 (IEEE Std 1003.1-2024) compliant implementation of `logname`.
//!
//! Specification References:
//! - IEEE Std 1003.1-2024, Shell & Utilities (XCU), Section: `logname`
//!   - SYNOPSIS: `logname`
//!   - DESCRIPTION: Writes the user's login name to standard output. The login name
//!     shall be the string that would be returned by the getlogin() function defined
//!     in POSIX.1-2024. Under conditions where getlogin() would fail, logname writes
//!     a diagnostic message to standard error and exits with a non-zero status.
//!   - OPTIONS: None. Conforms to Section 12.2 Utility Syntax Guidelines
//!     (Guideline 10: '--' terminates option processing).
//!   - OPERANDS: None. Extraneous operands are rejected with EXIT_SYNTAX (2).
//!   - STDOUT: Single line consisting of the user's login name:
//!       "%s\n", <login name>
//!   - STDERR: Used only for diagnostic messages.
//!   - EXIT STATUS:
//!       0: Successful completion.
//!       >0: An error occurred (1 for login name failure, 2 for syntax error).
//!   - APPLICATION USAGE: Explicitly ignores the LOGNAME environment variable.
//!
//! Resource Constraint:
//! - Zero dynamic heap allocations in core logic (stack buffers only).

const std = @import("std");
const builtin = @import("builtin");
const common_args = @import("../common/args.zig");
const common_error = @import("../common/error.zig");

pub const USER_PROCESS: i16 = 7;
pub const UT_LINESIZE: usize = 32;
pub const UT_NAMESIZE: usize = 32;
pub const UTMP_RECORD_SIZE: usize = 384;

/// Parse a single line from /etc/passwd and return the username if the UID matches.
/// Passwd format: username:password:uid:gid:gecos:homedir:shell
pub fn parsePasswdLine(line: []const u8, target_uid: u32) ?[]const u8 {
    var it = std.mem.splitScalar(u8, line, ':');
    const username = it.next() orelse return null;
    if (username.len == 0) return null;
    _ = it.next() orelse return null; // skip password
    const uid_str = it.next() orelse return null;
    const uid = std.fmt.parseInt(u32, uid_str, 10) catch return null;
    if (uid == target_uid) {
        return username;
    }
    return null;
}

/// Search /etc/passwd for a record matching `target_uid` and copy the username into `out_buf`.
pub fn findUserInPasswd(io: std.Io, target_uid: u32, out_buf: []u8) ?[]const u8 {
    var file = std.Io.Dir.openFileAbsolute(io, "/etc/passwd", .{}) catch return null;
    defer file.close(io);

    var file_buf: [2048]u8 = undefined;
    var reader = file.readerStreaming(io, &file_buf);

    while (reader.interface.takeDelimiter('\n') catch null) |line| {
        if (parsePasswdLine(line, target_uid)) |username| {
            if (username.len <= out_buf.len) {
                @memcpy(out_buf[0..username.len], username);
                return out_buf[0..username.len];
            }
        }
    }
    return null;
}

/// Read Linux audit session loginuid from /proc/self/loginuid.
/// Returns null if unavailable or if set to the kernel sentinel (uid_t)-1 (4294967295).
pub fn readLoginUid(io: std.Io) ?u32 {
    var file = std.Io.Dir.openFileAbsolute(io, "/proc/self/loginuid", .{}) catch return null;
    defer file.close(io);

    var buf: [32]u8 = undefined;
    const n = file.readPositionalAll(io, &buf, 0) catch return null;
    if (n == 0) return null;

    const trimmed = std.mem.trim(u8, buf[0..n], " \t\r\n\x00");
    const uid = std.fmt.parseInt(u32, trimmed, 10) catch return null;
    if (uid == std.math.maxInt(u32)) return null;
    return uid;
}

/// Parse a raw binary utmp record and extract the username if it matches the target terminal line.
/// In Linux utmp:
/// - ut_type: i16 at offset 0 (USER_PROCESS == 7)
/// - ut_line: [32]u8 at offset 8
/// - ut_user: [32]u8 at offset 44
pub fn parseUtmpRecord(record: []const u8, target_line: []const u8) ?[]const u8 {
    if (record.len < 76) return null;
    const ut_type = std.mem.readInt(i16, record[0..2], builtin.cpu.arch.endian());
    if (ut_type != USER_PROCESS) return null;

    const ut_line = std.mem.sliceTo(record[8..40], 0);
    if (std.mem.eql(u8, ut_line, target_line)) {
        const ut_user = std.mem.sliceTo(record[44..76], 0);
        if (ut_user.len > 0) return ut_user;
    }
    return null;
}

/// Search utmp records in `/run/utmp` or `/var/run/utmp` matching the controlling terminal line.
pub fn findUserInUtmp(io: std.Io, tty_line: []const u8, out_buf: []u8) ?[]const u8 {
    var file = std.Io.Dir.openFileAbsolute(io, "/run/utmp", .{}) catch
        (std.Io.Dir.openFileAbsolute(io, "/var/run/utmp", .{}) catch return null);
    defer file.close(io);

    var offset: u64 = 0;
    var record: [UTMP_RECORD_SIZE]u8 = undefined;
    while (true) {
        const n = file.readPositionalAll(io, &record, offset) catch break;
        if (n < UTMP_RECORD_SIZE) break;
        offset += UTMP_RECORD_SIZE;

        if (parseUtmpRecord(&record, tty_line)) |user| {
            if (user.len <= out_buf.len) {
                @memcpy(out_buf[0..user.len], user);
                return out_buf[0..user.len];
            }
        }
    }
    return null;
}

/// Locate controlling terminal line name across file descriptors 0, 1, 2 per POSIX getlogin().
pub fn getControllingTtyLine(io: std.Io, out_line_buf: []u8) ?[]const u8 {
    const std_files = [_]std.Io.File{
        std.Io.File.stdin(),
        std.Io.File.stdout(),
        std.Io.File.stderr(),
    };
    for (std_files, 0..) |file, idx| {
        const is_tty = file.isTty(io) catch false;
        if (!is_tty) continue;

        var proc_path_buf: [32]u8 = undefined;
        const proc_path = std.fmt.bufPrint(&proc_path_buf, "/proc/self/fd/{d}", .{idx}) catch continue;

        var link_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const link_len = std.Io.Dir.readLinkAbsolute(io, proc_path, &link_buf) catch continue;
        var line = link_buf[0..link_len];

        // Strip leading "/dev/" prefix
        if (std.mem.startsWith(u8, line, "/dev/")) {
            line = line[5..];
        }

        if (line.len > 0 and line.len <= out_line_buf.len) {
            @memcpy(out_line_buf[0..line.len], line);
            return out_line_buf[0..line.len];
        }
    }
    return null;
}

/// Retrieve the login name associated with the calling process / controlling terminal.
pub fn getLoginName(allocator: std.mem.Allocator, io: std.Io, out_buf: []u8) ?[]const u8 {
    if (builtin.os.tag == .windows) {
        const t = std.Io.Threaded.global_single_threaded;
        if (t.environ.process_environ.getAlloc(allocator, "USERNAME")) |user| {
            defer allocator.free(user);
            if (user.len > 0 and user.len <= out_buf.len) {
                @memcpy(out_buf[0..user.len], user);
                return out_buf[0..user.len];
            }
        } else |_| {}
        return null;
    }

    // Step 1: Check Linux audit session login UID (/proc/self/loginuid)
    if (readLoginUid(io)) |uid| {
        if (findUserInPasswd(io, uid, out_buf)) |user| {
            return user;
        }
    }

    // Step 2: Check controlling terminal (fds 0, 1, 2) and utmp (/run/utmp)
    var line_buf: [UT_LINESIZE]u8 = undefined;
    if (getControllingTtyLine(io, &line_buf)) |line| {
        if (findUserInUtmp(io, line, out_buf)) |user| {
            return user;
        }
    }

    return null;
}

pub fn run(allocator: std.mem.Allocator, args: []const [:0]const u8) u8 {
    const io = std.Io.Threaded.global_single_threaded.io();

    // POSIX: Options: None. Conforms to Section 12.2 Utility Syntax Guidelines
    // (Guideline 10: '--' terminates option parsing).
    var parser = common_args.ArgParser.init(args);
    while (parser.next("")) |_| {
        common_error.report("logname", "invalid option", error.InvalidArgument);
        return common_error.EXIT_SYNTAX;
    }

    // POSIX: Operands: None. Reject extraneous arguments.
    const operands = parser.remaining();
    if (operands.len > 0) {
        common_error.report("logname", "extra operand", error.InvalidArgument);
        return common_error.EXIT_SYNTAX;
    }

    var name_buf: [256]u8 = undefined;
    const login_name = getLoginName(allocator, io, &name_buf);

    if (login_name) |name| {
        const stdout_file = std.Io.File.stdout();
        var buf: [1024]u8 = undefined;
        var fw = stdout_file.writerStreaming(io, &buf);
        const writer = &fw.interface;

        writer.writeAll(name) catch |err| {
            common_error.report("logname", null, err);
            return common_error.toExitCode(err);
        };
        writer.writeByte('\n') catch |err| {
            common_error.report("logname", null, err);
            return common_error.toExitCode(err);
        };
        fw.flush() catch |err| {
            common_error.report("logname", null, err);
            return common_error.toExitCode(err);
        };

        return common_error.EXIT_SUCCESS;
    } else {
        // POSIX: "Under the conditions where the getlogin() function would fail,
        // the logname utility shall write a diagnostic message to standard error
        // and exit with a non-zero exit status."
        const stderr_file = std.Io.File.stderr();
        var buf: [256]u8 = undefined;
        var fw = stderr_file.writerStreaming(io, &buf);
        const writer = &fw.interface;

        _ = writer.writeAll("logname: no login name\n") catch {};
        _ = fw.flush() catch {};

        return common_error.EXIT_FAILURE;
    }
}

pub fn main(init: std.process.Init) u8 {
    const all_args = init.minimal.args.toSlice(init.arena.allocator()) catch |err| {
        common_error.report("logname", null, err);
        return common_error.EXIT_FAILURE;
    };
    const cmd_args = if (all_args.len > 1) all_args[1..] else &.{};
    return run(init.arena.allocator(), cmd_args);
}

// ============================================================================
// POSIX Conformance Tests
// ============================================================================

test "logname: parsePasswdLine matches target UID" {
    const entry = "bknackkr:x:1000:1000:Ben,,,:/home/bknackkr:/bin/bash";
    try std.testing.expectEqualStrings("bknackkr", parsePasswdLine(entry, 1000).?);
    try std.testing.expect(parsePasswdLine(entry, 1001) == null);
    try std.testing.expect(parsePasswdLine(entry, 0) == null);

    const root_entry = "root:x:0:0:root:/root:/bin/bash";
    try std.testing.expectEqualStrings("root", parsePasswdLine(root_entry, 0).?);

    // Malformed lines
    try std.testing.expect(parsePasswdLine("", 1000) == null);
    try std.testing.expect(parsePasswdLine("invalid_format", 1000) == null);
    try std.testing.expect(parsePasswdLine("user:x:notanumber:1000:::", 1000) == null);
}

test "logname: parseUtmpRecord matches USER_PROCESS and line" {
    var record: [UTMP_RECORD_SIZE]u8 = [_]u8{0} ** UTMP_RECORD_SIZE;

    // Set ut_type = USER_PROCESS (7)
    std.mem.writeInt(i16, record[0..2], USER_PROCESS, builtin.cpu.arch.endian());

    // Set ut_line = "pts/3"
    @memcpy(record[8..13], "pts/3");

    // Set ut_user = "bknackkr"
    @memcpy(record[44..52], "bknackkr");

    try std.testing.expectEqualStrings("bknackkr", parseUtmpRecord(&record, "pts/3").?);
    try std.testing.expect(parseUtmpRecord(&record, "pts/1") == null);
    try std.testing.expect(parseUtmpRecord(&record, "tty1") == null);

    // When ut_type != USER_PROCESS (e.g. DEAD_PROCESS == 8 or BOOT_TIME == 2), ignore
    std.mem.writeInt(i16, record[0..2], 8, builtin.cpu.arch.endian());
    try std.testing.expect(parseUtmpRecord(&record, "pts/3") == null);
}

test "logname: argument parsing and option rejection" {
    // Rejection of invalid options
    try std.testing.expectEqual(common_error.EXIT_SYNTAX, run(std.testing.allocator, &.{"-a"}));
    try std.testing.expectEqual(common_error.EXIT_SYNTAX, run(std.testing.allocator, &.{"-h"}));
    try std.testing.expectEqual(common_error.EXIT_SYNTAX, run(std.testing.allocator, &.{"--version"}));

    // Rejection of extra operands
    try std.testing.expectEqual(common_error.EXIT_SYNTAX, run(std.testing.allocator, &.{"user"}));
    try std.testing.expectEqual(common_error.EXIT_SYNTAX, run(std.testing.allocator, &.{ "--", "user" }));
    try std.testing.expectEqual(common_error.EXIT_SYNTAX, run(std.testing.allocator, &.{ "arg1", "arg2" }));
}

test "logname: run execution returns valid status code" {
    // When invoked with no arguments or with "--", run() should return either
    // EXIT_SUCCESS (0) if login activity is found or EXIT_FAILURE (1) if no login name.
    const status_no_args = run(std.testing.allocator, &.{});
    try std.testing.expect(status_no_args == common_error.EXIT_SUCCESS or status_no_args == common_error.EXIT_FAILURE);

    const status_dash_dash = run(std.testing.allocator, &.{"--"});
    try std.testing.expect(status_dash_dash == common_error.EXIT_SUCCESS or status_dash_dash == common_error.EXIT_FAILURE);
}
