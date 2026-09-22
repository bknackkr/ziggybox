//! ziggybox - auditable, POSIX-compliant multicall binary
//!
//! Entry point and multicall router:
//! 1. Identify the invocation name by stripping directory paths from argv[0].
//! 2. If argv[0] matches ziggybox (or root binary name), argv[1] determines the command.
//! 3. If symlinked/hardlinked directly as a command (e.g. /bin/cat -> /bin/ziggybox),
//!    dispatch immediately to that command's run function.
//! 4. If no command matches, display an auditable list of built-in applets and exit with status 1.

const std = @import("std");

pub const commands = struct {
    pub const basename = @import("commands/basename.zig");
    pub const dirname = @import("commands/dirname.zig");
    pub const echo = @import("commands/echo.zig");
    pub const false_cmd = @import("commands/false.zig");
    pub const logname = @import("commands/logname.zig");
    pub const pwd = @import("commands/pwd.zig");
    pub const sleep = @import("commands/sleep.zig");
    pub const @"true" = @import("commands/true.zig");
    pub const uname = @import("commands/uname.zig");
};

pub const common = struct {
    pub const args = @import("common/args.zig");
    pub const error_mod = @import("common/error.zig");
    pub const io = @import("common/io.zig");
};

pub const Applet = struct {
    name: []const u8,
    run: *const fn (allocator: std.mem.Allocator, args: []const [:0]const u8) u8,
    description: []const u8,
};

/// Registry of all currently implemented applets in ziggybox.
pub const applets = [_]Applet{
    .{
        .name = "basename",
        .run = commands.basename.run,
        .description = "return non-directory portion of a pathname",
    },
    .{
        .name = "dirname",
        .run = commands.dirname.run,
        .description = "return directory portion of a pathname",
    },
    .{
        .name = "echo",
        .run = commands.echo.run,
        .description = "write arguments to standard output",
    },
    .{
        .name = "false",
        .run = commands.false_cmd.run,
        .description = "return false value",
    },
    .{
        .name = "logname",
        .run = commands.logname.run,
        .description = "return the user's login name",
    },
    .{
        .name = "pwd",
        .run = commands.pwd.run,
        .description = "return working directory name",
    },
    .{
        .name = "sleep",
        .run = commands.sleep.run,
        .description = "suspend execution for an interval",
    },
    .{
        .name = "true",
        .run = commands.@"true".run,
        .description = "return true value",
    },
    .{
        .name = "uname",
        .run = commands.uname.run,
        .description = "return system name",
    },
};

/// Locate an applet by exact name.
pub fn findApplet(name: []const u8) ?Applet {
    for (applets) |applet| {
        if (std.mem.eql(u8, applet.name, name)) {
            return applet;
        }
    }
    return null;
}

/// Strip directory prefixes (both '/' and '\') and optional '.exe' suffix.
pub fn getBaseName(path: []const u8) []const u8 {
    var last_sep: ?usize = null;
    for (path, 0..) |c, i| {
        if (c == '/' or c == '\\') {
            last_sep = i;
        }
    }
    const name = if (last_sep) |idx| path[idx + 1 ..] else path;
    if (name.len > 4 and std.ascii.eqlIgnoreCase(name[name.len - 4 ..], ".exe")) {
        return name[0 .. name.len - 4];
    }
    return name;
}

/// Print formatted usage and list of built-in applets.
pub fn printUsage(io: std.Io, is_error: bool) void {
    const file = if (is_error) std.Io.File.stderr() else std.Io.File.stdout();
    var buf: [1024]u8 = undefined;
    var fw = file.writerStreaming(io, &buf);
    const writer = &fw.interface;

    _ = writer.writeAll(
        \\ziggybox - POSIX multicall binary
        \\
        \\Usage: ziggybox <applet> [arguments...]
        \\   or: <applet> [arguments...] (when symlinked/hardlinked)
        \\
        \\Currently defined applets:
        \\
    ) catch {};

    for (applets, 0..) |applet, idx| {
        if (idx > 0) {
            _ = writer.writeAll(", ") catch {};
        } else {
            _ = writer.writeAll("    ") catch {};
        }
        _ = writer.writeAll(applet.name) catch {};
    }
    _ = writer.writeAll("\n\n") catch {};
    _ = fw.flush() catch {};
}

/// Print unknown applet error message followed by usage.
pub fn printUnknownApplet(io: std.Io, applet_name: []const u8) void {
    const stderr = std.Io.File.stderr();
    var buf: [256]u8 = undefined;
    var fw = stderr.writerStreaming(io, &buf);
    const writer = &fw.interface;

    _ = writer.print("ziggybox: unknown applet '{s}'\n\n", .{applet_name}) catch {};
    _ = fw.flush() catch {};
    printUsage(io, true);
}

pub fn main(init: std.process.Init) u8 {
    const io = init.io;
    const allocator = init.arena.allocator();

    const all_args = init.minimal.args.toSlice(allocator) catch |err| {
        @import("common/error.zig").report("ziggybox", null, err);
        return 1;
    };

    if (all_args.len == 0) {
        printUsage(io, true);
        return 1;
    }

    const invocation_name = getBaseName(all_args[0]);

    if (std.mem.eql(u8, invocation_name, "ziggybox")) {
        // Multicall router mode
        if (all_args.len < 2) {
            printUsage(io, true);
            return 1;
        }

        const applet_name = all_args[1];
        if (std.mem.eql(u8, applet_name, "--help") or std.mem.eql(u8, applet_name, "-h")) {
            printUsage(io, false);
            return 0;
        }

        if (findApplet(applet_name)) |applet| {
            return applet.run(allocator, all_args[2..]);
        } else {
            printUnknownApplet(io, applet_name);
            return 1;
        }
    } else {
        // Direct / symlinked applet mode
        if (findApplet(invocation_name)) |applet| {
            return applet.run(allocator, all_args[1..]);
        } else {
            printUnknownApplet(io, invocation_name);
            return 1;
        }
    }
}

// ============================================================================
// Multicall Router Tests
// ============================================================================

test "getBaseName extraction" {
    try std.testing.expectEqualStrings("echo", getBaseName("echo"));
    try std.testing.expectEqualStrings("echo", getBaseName("/bin/echo"));
    try std.testing.expectEqualStrings("echo", getBaseName("/usr/bin/echo"));
    try std.testing.expectEqualStrings("ziggybox", getBaseName("C:\\bin\\ziggybox.exe"));
    try std.testing.expectEqualStrings("ziggybox", getBaseName("ziggybox.EXE"));
    try std.testing.expectEqualStrings("false", getBaseName("false.exe"));
}

test "findApplet lookup" {
    try std.testing.expect(findApplet("basename") != null);
    try std.testing.expect(findApplet("dirname") != null);
    try std.testing.expect(findApplet("echo") != null);
    try std.testing.expect(findApplet("false") != null);
    try std.testing.expect(findApplet("logname") != null);
    try std.testing.expect(findApplet("pwd") != null);
    try std.testing.expect(findApplet("sleep") != null);
    try std.testing.expect(findApplet("true") != null);
    try std.testing.expect(findApplet("uname") != null);
    try std.testing.expect(findApplet("nonexistent") == null);
}

test {
    std.testing.refAllDecls(common);
}

