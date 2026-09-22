//! POSIX.1-2024 (IEEE Std 1003.1-2024) compliant implementation of `mkdir`.
//!
//! Specification References:
//! - IEEE Std 1003.1-2024, Shell & Utilities (XCU), Section: `mkdir`
//!   - SYNOPSIS: `mkdir [-p] [-m mode] dir...`
//!   - OPTIONS:
//!       -m mode: Set the file permission bits of the newly-created directory
//!                to the specified mode value (octal or symbolic per chmod).
//!       -p: Create any missing intermediate pathname components.
//!           Intermediate directories are created with (S_IWUSR|S_IXUSR|~umask)&0777.
//!           Operands that name an existing directory are ignored without error.
//!   - OPERANDS:
//!       dir: A pathname of a directory to be created.
//!   - STDERR: Used only for diagnostic messages.
//!   - EXIT STATUS:
//!       0: All specified directories created successfully (or existed with -p).
//!       >0: An error occurred.
//!
//! Resource Constraint:
//! - Zero dynamic heap allocations in core logic (stack buffers only).

const std = @import("std");
const builtin = @import("builtin");
const common_args = @import("../common/args.zig");
const common_error = @import("../common/error.zig");

/// Retrieve the process file mode creation mask (umask).
pub fn getProcessUmask() std.posix.mode_t {
    if (builtin.os.tag == .linux) {
        const cur = std.os.linux.syscall1(.umask, 0);
        _ = std.os.linux.syscall1(.umask, cur);
        return @as(std.posix.mode_t, @intCast(cur));
    } else if (builtin.link_libc) {
        const cur = std.c.umask(0);
        _ = std.c.umask(cur);
        return cur;
    } else {
        return 0o022; // Standard default umask fallback
    }
}

/// Parse non-negative octal mode string (e.g. "755", "0755").
pub fn parseOctalMode(str: []const u8) ?std.posix.mode_t {
    if (str.len == 0 or str.len > 7) return null;
    var mode: std.posix.mode_t = 0;
    for (str) |c| {
        if (c < '0' or c > '7') return null;
        mode = (mode << 3) | (c - '0');
    }
    return mode & 0o7777;
}

/// Parse symbolic mode clause per POSIX.1-2024 chmod specification.
/// In mkdir -m, initial assumed mode is `a=rwx` (0777), modified by umask.
pub fn parseSymbolicMode(str: []const u8, initial_mode: std.posix.mode_t, umask_val: std.posix.mode_t) ?std.posix.mode_t {
    if (str.len == 0) return null;

    var current_mode = initial_mode;
    var clause_it = std.mem.splitScalar(u8, str, ',');

    while (clause_it.next()) |clause| {
        if (clause.len == 0) return null;

        // 1. Parse optional wholist: 'u', 'g', 'o', 'a'
        var idx: usize = 0;
        var who_mask: std.posix.mode_t = 0;
        var who_specified = false;

        while (idx < clause.len) : (idx += 1) {
            switch (clause[idx]) {
                'u' => {
                    who_mask |= 0o4700;
                    who_specified = true;
                },
                'g' => {
                    who_mask |= 0o2070;
                    who_specified = true;
                },
                'o' => {
                    who_mask |= 0o0007;
                    who_specified = true;
                },
                'a' => {
                    who_mask |= 0o7777;
                    who_specified = true;
                },
                '+', '-', '=' => break,
                else => return null,
            }
        }

        if (idx >= clause.len) return null;

        // 2. Parse actionlist: action+
        while (idx < clause.len) {
            const op = clause[idx];
            if (op != '+' and op != '-' and op != '=') return null;
            idx += 1;

            var perm_bits: std.posix.mode_t = 0;
            var is_permcopy = false;
            var permcopy_char: u8 = 0;

            if (idx < clause.len) {
                const next_char = clause[idx];
                if (next_char == 'u' or next_char == 'g' or next_char == 'o') {
                    // Check if followed by other perm chars or if it's permcopy
                    if (idx + 1 == clause.len or clause[idx + 1] == '+' or clause[idx + 1] == '-' or clause[idx + 1] == '=') {
                        is_permcopy = true;
                        permcopy_char = next_char;
                        idx += 1;
                    }
                }
            }

            if (is_permcopy) {
                const src_bits: std.posix.mode_t = switch (permcopy_char) {
                    'u' => (current_mode >> 6) & 0o7,
                    'g' => (current_mode >> 3) & 0o7,
                    'o' => current_mode & 0o7,
                    else => 0,
                };
                perm_bits = (src_bits << 6) | (src_bits << 3) | src_bits;
            } else {
                while (idx < clause.len) {
                    const c = clause[idx];
                    switch (c) {
                        'r' => perm_bits |= 0o444,
                        'w' => perm_bits |= 0o222,
                        'x', 'X' => perm_bits |= 0o111,
                        's' => perm_bits |= 0o6000,
                        't' => perm_bits |= 0o1000,
                        '+', '-', '=' => break,
                        else => return null,
                    }
                    idx += 1;
                }
            }

            // Apply action
            if (who_specified) {
                const mask = who_mask;
                const affected = perm_bits & mask;
                switch (op) {
                    '+' => current_mode |= affected,
                    '-' => current_mode &= ~affected,
                    '=' => {
                        current_mode &= ~mask;
                        current_mode |= affected;
                    },
                    else => unreachable,
                }
            } else {
                // When who is not specified, operation affects ugo except masked by umask
                const umask_filter = ~umask_val & 0o777;
                switch (op) {
                    '+' => current_mode |= (perm_bits & umask_filter),
                    '-' => current_mode &= ~(perm_bits & umask_filter),
                    '=' => {
                        current_mode = (perm_bits & umask_filter);
                    },
                    else => unreachable,
                }
            }
        }
    }

    return current_mode & 0o7777;
}

/// Parse mode operand: attempts octal first, then symbolic.
pub fn parseMode(str: []const u8, umask_val: std.posix.mode_t) ?std.posix.mode_t {
    if (parseOctalMode(str)) |octal| {
        return octal;
    }
    const default_mode = 0o777 & ~umask_val;
    return parseSymbolicMode(str, default_mode, umask_val);
}

fn toPermissions(mode: std.posix.mode_t) std.Io.Dir.Permissions {
    if (@hasDecl(std.Io.Dir.Permissions, "fromMode")) {
        return std.Io.Dir.Permissions.fromMode(mode);
    } else {
        return .default_dir;
    }
}

/// Strips redundant trailing slashes from path, preserving root "/" or "//".
fn stripTrailingSlashes(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and path[end - 1] == '/') {
        if (end == 2 and path[0] == '/') break; // preserve "//"
        end -= 1;
    }
    return path[0..end];
}

/// Check if a path exists and is a directory.
fn isExistingDirectory(io: std.Io, path: []const u8) bool {
    var stat_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const normalized = std.fmt.bufPrint(&stat_buf, "{s}", .{path}) catch return false;
    var opened = std.Io.Dir.cwd().openDir(io, normalized, .{}) catch return false;
    opened.close(io);
    return true;
}

/// Create a single directory component and set permissions if requested.
fn makeSingleDir(
    io: std.Io,
    path: []const u8,
    mode: ?std.posix.mode_t,
) !void {
    const default_perms: std.Io.Dir.Permissions = .default_dir;
    try std.Io.Dir.cwd().createDir(io, path, default_perms);
    if (mode) |m| {
        const perms = toPermissions(m);
        std.Io.Dir.cwd().setFilePermissions(io, path, perms, .{}) catch |err| {
            // In case setFilePermissions fails (e.g. read-only filesystem or restricted privileges)
            return err;
        };
    }
}

/// Create intermediate and target directories for `mkdir -p`.
fn makePathRecursive(
    io: std.Io,
    raw_path: []const u8,
    target_mode: ?std.posix.mode_t,
    umask_val: std.posix.mode_t,
) !void {
    const path = stripTrailingSlashes(raw_path);
    if (path.len == 0) return error.BadPathName;

    // Intermediate directories mode per POSIX: (S_IWUSR | S_IXUSR | ~umask) & 0777
    const intermediate_mode = (0o300 | ~umask_val) & 0o777;

    // Walk components from left to right
    var i: usize = 0;
    // Skip leading root slashes
    while (i < path.len and path[i] == '/') : (i += 1) {}

    while (i < path.len) {
        // Find next slash or end of string
        while (i < path.len and path[i] != '/') : (i += 1) {}

        const is_final = (i >= path.len);
        const sub_path = path[0..i];

        if (sub_path.len == 0 or std.mem.eql(u8, sub_path, ".")) {
            while (i < path.len and path[i] == '/') : (i += 1) {}
            continue;
        }

        if (is_final) {
            // Target component
            const create_res = makeSingleDir(io, sub_path, target_mode);
            if (create_res) |_| {
                return;
            } else |err| switch (err) {
                error.PathAlreadyExists => {
                    if (isExistingDirectory(io, sub_path)) {
                        return; // POSIX: existing directory ignored without error
                    }
                    return error.NotDir;
                },
                else => return err,
            }
        } else {
            // Intermediate component
            const create_res = makeSingleDir(io, sub_path, intermediate_mode);
            if (create_res) |_| {} else |err| switch (err) {
                error.PathAlreadyExists => {
                    if (!isExistingDirectory(io, sub_path)) {
                        return error.NotDir;
                    }
                },
                else => return err,
            }
        }

        while (i < path.len and path[i] == '/') : (i += 1) {}
    }
}

pub fn run(allocator: std.mem.Allocator, args: []const [:0]const u8) u8 {
    _ = allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var opt_p = false;
    var mode_str: ?[]const u8 = null;

    var parser = common_args.ArgParser.init(args);
    while (parser.next("pm:")) |opt| {
        switch (opt) {
            'p' => opt_p = true,
            'm' => mode_str = parser.optarg,
            ':' => {
                common_error.report("mkdir", "option requires an argument -- m", error.InvalidArgument);
                return common_error.EXIT_SYNTAX;
            },
            else => {
                common_error.report("mkdir", "invalid option", error.InvalidArgument);
                return common_error.EXIT_SYNTAX;
            },
        }
    }

    const operands = parser.remaining();
    if (operands.len == 0) {
        common_error.report("mkdir", "missing operand", error.InvalidArgument);
        return common_error.EXIT_SYNTAX;
    }

    const umask_val = getProcessUmask();
    var target_mode: ?std.posix.mode_t = null;
    if (mode_str) |m_str| {
        if (parseMode(m_str, umask_val)) |m| {
            target_mode = m;
        } else {
            common_error.report("mkdir", "invalid mode", error.InvalidArgument);
            return common_error.EXIT_SYNTAX;
        }
    }

    var exit_code: u8 = common_error.EXIT_SUCCESS;

    for (operands) |dir_arg| {
        if (dir_arg.len == 0) {
            common_error.report("mkdir", "cannot create directory ''", error.FileNotFound);
            exit_code = common_error.EXIT_FAILURE;
            continue;
        }

        if (opt_p) {
            makePathRecursive(io, dir_arg, target_mode, umask_val) catch |err| {
                common_error.report("mkdir", dir_arg, err);
                exit_code = common_error.EXIT_FAILURE;
            };
        } else {
            makeSingleDir(io, dir_arg, target_mode) catch |err| {
                common_error.report("mkdir", dir_arg, err);
                exit_code = common_error.EXIT_FAILURE;
            };
        }
    }

    return exit_code;
}

pub fn main(init: std.process.Init) u8 {
    const all_args = init.minimal.args.toSlice(init.arena.allocator()) catch |err| {
        common_error.report("mkdir", null, err);
        return common_error.EXIT_FAILURE;
    };
    const cmd_args = if (all_args.len > 1) all_args[1..] else &.{};
    return run(init.arena.allocator(), cmd_args);
}

// ============================================================================
// Unit Tests
// ============================================================================

test "mkdir: octal mode parsing" {
    try std.testing.expectEqual(@as(?std.posix.mode_t, 0o755), parseOctalMode("755"));
    try std.testing.expectEqual(@as(?std.posix.mode_t, 0o755), parseOctalMode("0755"));
    try std.testing.expectEqual(@as(?std.posix.mode_t, 0o700), parseOctalMode("700"));
    try std.testing.expectEqual(@as(?std.posix.mode_t, 0o777), parseOctalMode("777"));
    try std.testing.expectEqual(@as(?std.posix.mode_t, 0o1777), parseOctalMode("1777"));
    try std.testing.expectEqual(@as(?std.posix.mode_t, null), parseOctalMode("888"));
    try std.testing.expectEqual(@as(?std.posix.mode_t, null), parseOctalMode(""));
}

test "mkdir: symbolic mode parsing" {
    const umask_val: std.posix.mode_t = 0o022;
    const default_mode = 0o777 & ~umask_val; // 0755

    // Exact assignment
    try std.testing.expectEqual(@as(?std.posix.mode_t, 0o755), parseMode("u=rwx,go=rx", umask_val));
    try std.testing.expectEqual(@as(?std.posix.mode_t, 0o700), parseMode("u=rwx,go=", umask_val));
    try std.testing.expectEqual(@as(?std.posix.mode_t, 0o777), parseMode("a=rwx", umask_val));

    // Relative modification with initial default_mode (0755)
    // +w without who applies to all except umask (0755 | (0222 & ~022) = 0755 | 0200 = 0755)
    try std.testing.expectEqual(default_mode, parseMode("+w", umask_val).?);

    // a+w explicitly adds write for all classes (0755 | 0222 = 0777)
    try std.testing.expectEqual(@as(?std.posix.mode_t, 0o777), parseMode("a+w", umask_val));

    // go-w removes write from group and other (0777 -> 0755)
    try std.testing.expectEqual(@as(?std.posix.mode_t, 0o755), parseMode("a=rwx,go-w", umask_val));
}

test "mkdir: strip trailing slashes" {
    try std.testing.expectEqualStrings("a/b/c", stripTrailingSlashes("a/b/c/"));
    try std.testing.expectEqualStrings("a/b/c", stripTrailingSlashes("a/b/c///"));
    try std.testing.expectEqualStrings("/", stripTrailingSlashes("/"));
    try std.testing.expectEqualStrings("//", stripTrailingSlashes("//"));
    try std.testing.expectEqualStrings("/a", stripTrailingSlashes("/a/"));
}

test "mkdir: argument parsing and missing operands" {
    const allocator = std.testing.allocator;
    const exit_missing = run(allocator, &.{});
    try std.testing.expectEqual(common_error.EXIT_SYNTAX, exit_missing);

    const exit_missing_dash_m = run(allocator, &.{"-m"});
    try std.testing.expectEqual(common_error.EXIT_SYNTAX, exit_missing_dash_m);

    const exit_invalid_opt = run(allocator, &.{"-z"});
    try std.testing.expectEqual(common_error.EXIT_SYNTAX, exit_invalid_opt);

    const exit_invalid_mode = run(allocator, &.{ "-m", "invalid_mode", "some_dir" });
    try std.testing.expectEqual(common_error.EXIT_SYNTAX, exit_invalid_mode);
}
