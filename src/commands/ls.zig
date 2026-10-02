//! POSIX.1-2024 (IEEE Std 1003.1-2024) compliant implementation of `ls`.
//!
//! Specification References:
//! - IEEE Std 1003.1-2024, Shell & Utilities (XCU), Section: `ls`
//!   - SYNOPSIS:
//!       ls [-ikqrs] [-gln|o] [-A|-a] [-C|-m|-x|-1] [-F|-p] [-H|-L]
//!          [-R|-d] [-S|-f|-t] [-c|-u] [file...]
//!   - DESCRIPTION:
//!       For each operand naming a non-directory file, writes file name and
//!       requested info. For each directory operand, writes names and info of
//!       contained files. Non-directory operands are output first, followed by
//!       directory operands. If no operands specified, defaults to dot ('.').
//!   - OPTIONS:
//!       -a: Write all directory entries including '.' and '..'.
//!       -A: Write all directory entries including '.*' but excluding '.' and '..'.
//!       -d: Do not treat directories differently than other files (list directory itself).
//!       -1: Force one entry per line output.
//!       -C: Multi-column output, sorted down columns.
//!       -x: Multi-column output, sorted across columns.
//!       -m: Stream format output (comma-separated list across line width).
//!       -l: Long format: mode, nlink, owner, group, size/device, date/time, name.
//!       -n: Long format with numeric UIDs and GIDs.
//!       -g: Long format, disable owner name/ID.
//!       -o: Long format, disable group name/ID.
//!       -F: Append indicator: '/' (dir), '*' (exec), '|' (FIFO), '=' (socket), '@' (symlink).
//!       -p: Append '/' indicator to directories.
//!       -i: Output file serial number (inode).
//!       -s: Output number of allocated file system blocks.
//!       -k: Set block size for -s and directory total to 1024-byte units (default 512).
//!       -t: Sort by modification time (most recent first). Secondary key: filename.
//!       -S: Sort by file size (largest first). Secondary key: filename.
//!       -f: List in directory order; turns on -a; ignores -r, -S, -t.
//!       -r: Reverse sort order.
//!       -c: Use status change time (ctime) for sorting (-t) or writing (-l).
//!       -u: Use access time (atime) for sorting (-t) or writing (-l).
//!       -H: Follow symlinks named on command line.
//!       -L: Follow all symlinks (operands and within hierarchy).
//!       -R: Recursively list subdirectories encountered; detect loops.
//!       -q: Replace non-printable characters in filenames with '?'.
//!   - EXIT STATUS:
//!       0: Successful completion.
//!       >0: An error occurred.

const std = @import("std");
const builtin = @import("builtin");
const common_args = @import("../common/args.zig");
const common_error = @import("../common/error.zig");
const common_user = @import("../common/user.zig");

pub const FormatMode = enum {
    single_column, // -1 or default
    long, // -l, -n, -g, -o
    columns_down, // -C
    columns_across, // -x
    stream, // -m
};

pub const SortKey = enum {
    name,
    time, // -t
    size, // -S
    none, // -f (directory order)
};

pub const TimeType = enum {
    mtime, // default
    ctime, // -c
    atime, // -u
};

pub const FilterMode = enum {
    default, // hide starting with '.'
    all, // -a
    almost_all, // -A
};

pub const LsOptions = struct {
    filter: FilterMode = .default,
    format: FormatMode = .single_column,
    sort: SortKey = .name,
    time_type: TimeType = .mtime,
    reverse_sort: bool = false, // -r
    directory_itself: bool = false, // -d
    recursive: bool = false, // -R
    follow_operands: bool = false, // -H
    follow_all: bool = false, // -L
    classify: bool = false, // -F
    slash_dirs: bool = false, // -p
    show_inode: bool = false, // -i
    show_blocks: bool = false, // -s
    kib_blocks: bool = false, // -k
    hide_owner: bool = false, // -g
    hide_group: bool = false, // -o
    numeric_ids: bool = false, // -n
    question_unprintable: bool = false, // -q
};

pub const FileInfo = struct {
    name: []const u8,
    full_path: []const u8,
    ino: u64,
    nlink: u32,
    uid: u32,
    gid: u32,
    mode: u32,
    size: u64,
    blocks: u64, // in 512-byte blocks
    mtime_sec: i64,
    mtime_nsec: u32,
    ctime_sec: i64,
    ctime_nsec: u32,
    atime_sec: i64,
    atime_nsec: u32,
    kind: std.Io.File.Kind,
    link_target: ?[]const u8 = null,
    target_kind: ?std.Io.File.Kind = null,
    target_mode: ?u32 = null,
    dev: u64 = 0,
};

/// Retrieve unified file information.
pub fn getFileInfo(
    io: std.Io,
    allocator: std.mem.Allocator,
    name: []const u8,
    full_path: []const u8,
    follow_symlinks: bool,
    need_link_info: bool,
) !FileInfo {
    var info = FileInfo{
        .name = name,
        .full_path = full_path,
        .ino = 0,
        .nlink = 1,
        .uid = 0,
        .gid = 0,
        .mode = 0,
        .size = 0,
        .blocks = 0,
        .mtime_sec = 0,
        .mtime_nsec = 0,
        .ctime_sec = 0,
        .ctime_nsec = 0,
        .atime_sec = 0,
        .atime_nsec = 0,
        .kind = .file,
    };

    if (builtin.os.tag == .linux) {
        var path_buf: [std.Io.Dir.max_path_bytes:0]u8 = undefined;
        if (full_path.len >= path_buf.len) return error.NameTooLong;
        @memcpy(path_buf[0..full_path.len], full_path);
        path_buf[full_path.len] = 0;

        var stx = std.mem.zeroes(std.os.linux.Statx);
        const flags: u32 = if (follow_symlinks) 0 else std.os.linux.AT.SYMLINK_NOFOLLOW;
        const rc = std.os.linux.statx(std.os.linux.AT.FDCWD, &path_buf, flags, std.os.linux.STATX.BASIC_STATS, &stx);
        const err = std.posix.errno(rc);
        if (err != .SUCCESS) {
            return switch (err) {
                .NOENT => error.FileNotFound,
                .ACCES => error.AccessDenied,
                .NOTDIR => error.NotDir,
                .LOOP => error.SymLinkLoop,
                else => error.Unexpected,
            };
        }

        info.ino = stx.ino;
        info.nlink = stx.nlink;
        info.uid = stx.uid;
        info.gid = stx.gid;
        info.mode = stx.mode;
        info.size = stx.size;
        info.blocks = stx.blocks;
        info.mtime_sec = stx.mtime.sec;
        info.mtime_nsec = stx.mtime.nsec;
        info.ctime_sec = stx.ctime.sec;
        info.ctime_nsec = stx.ctime.nsec;
        info.atime_sec = stx.atime.sec;
        info.atime_nsec = stx.atime.nsec;
        info.dev = (@as(u64, stx.dev_major) << 32) | stx.dev_minor;

        const S_IFMT: u32 = 0o170000;
        info.kind = switch (stx.mode & S_IFMT) {
            0o040000 => .directory,
            0o020000 => .character_device,
            0o060000 => .block_device,
            0o100000 => .file,
            0o120000 => .sym_link,
            0o010000 => .named_pipe,
            0o140000 => .unix_domain_socket,
            else => .unknown,
        };
    } else {
        // Fallback for non-Linux platforms
        const stat = try std.Io.Dir.cwd().statFile(io, full_path, .{ .follow_symlinks = follow_symlinks });
        info.ino = stat.inode;
        info.nlink = stat.nlink;
        info.size = stat.size;
        info.kind = stat.kind;
        const base_perms = if (@hasDecl(std.Io.Dir.Permissions, "toMode"))
            stat.permissions.toMode()
        else
            @intFromEnum(stat.permissions);
        const type_bits: u32 = switch (stat.kind) {
            .directory => 0o040000,
            .character_device => 0o020000,
            .block_device => 0o060000,
            .file => 0o100000,
            .sym_link => 0o120000,
            .named_pipe => 0o010000,
            .unix_domain_socket => 0o140000,
            else => 0,
        };
        info.mode = type_bits | (base_perms & 0o7777);
        info.blocks = (stat.size + 511) / 512;
        const m_ns = stat.mtime.nanoseconds;
        info.mtime_sec = @intCast(@divTrunc(m_ns, std.time.ns_per_s));
        info.mtime_nsec = @intCast(@mod(m_ns, std.time.ns_per_s));
        const c_ns = stat.ctime.nanoseconds;
        info.ctime_sec = @intCast(@divTrunc(c_ns, std.time.ns_per_s));
        info.ctime_nsec = @intCast(@mod(c_ns, std.time.ns_per_s));
        if (stat.atime) |at| {
            info.atime_sec = @intCast(@divTrunc(at.nanoseconds, std.time.ns_per_s));
            info.atime_nsec = @intCast(@mod(at.nanoseconds, std.time.ns_per_s));
        }
    }

    if (info.kind == .sym_link and need_link_info) {
        var link_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const link_len = std.Io.Dir.cwd().readLink(io, full_path, &link_buf) catch 0;
        if (link_len > 0) {
            const target_slice = try allocator.dupe(u8, link_buf[0..link_len]);
            info.link_target = target_slice;

            // Stat the target without following further links to get its indicator
            if (builtin.os.tag == .linux) {
                var target_full_buf: [std.Io.Dir.max_path_bytes:0]u8 = undefined;
                const target_full = if (link_buf[0] == '/')
                    link_buf[0..link_len]
                else blk: {
                    const parent = getParentDir(full_path) orelse ".";
                    if (std.mem.eql(u8, parent, ".")) {
                        break :blk link_buf[0..link_len];
                    } else {
                        break :blk std.fmt.bufPrint(&target_full_buf, "{s}/{s}", .{ parent, link_buf[0..link_len] }) catch link_buf[0..link_len];
                    }
                };
                if (target_full.len < target_full_buf.len) {
                    @memcpy(target_full_buf[0..target_full.len], target_full);
                    target_full_buf[target_full.len] = 0;
                    var tgt_stx = std.mem.zeroes(std.os.linux.Statx);
                    const rc_tgt = std.os.linux.statx(std.os.linux.AT.FDCWD, &target_full_buf, 0, std.os.linux.STATX.BASIC_STATS, &tgt_stx);
                    if (std.posix.errno(rc_tgt) == .SUCCESS) {
                        info.target_mode = tgt_stx.mode;
                        const S_IFMT: u32 = 0o170000;
                        info.target_kind = switch (tgt_stx.mode & S_IFMT) {
                            0o040000 => .directory,
                            0o020000 => .character_device,
                            0o060000 => .block_device,
                            0o100000 => .file,
                            0o120000 => .sym_link,
                            0o010000 => .named_pipe,
                            0o140000 => .unix_domain_socket,
                            else => .unknown,
                        };
                    }
                }
            }
        }
    }

    return info;
}

pub fn getParentDir(path: []const u8) ?[]const u8 {
    var last_sep: ?usize = null;
    for (path, 0..) |c, i| {
        if (c == '/') last_sep = i;
    }
    if (last_sep) |idx| {
        if (idx == 0) return "/";
        return path[0..idx];
    }
    return null;
}

pub fn joinPath(buf: []u8, parent: []const u8, child: []const u8) ![]const u8 {
    if (parent.len == 0 or std.mem.eql(u8, parent, ".")) {
        if (child.len > buf.len) return error.NameTooLong;
        @memcpy(buf[0..child.len], child);
        return buf[0..child.len];
    }
    if (parent.len > 0 and parent[parent.len - 1] == '/') {
        return std.fmt.bufPrint(buf, "{s}{s}", .{ parent, child });
    }
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ parent, child });
}

/// Comparison function for sorting entries.
pub fn compareEntries(opts: LsOptions, a: FileInfo, b: FileInfo) bool {
    var result: std.math.Order = .eq;

    switch (opts.sort) {
        .name => {
            result = std.mem.order(u8, a.name, b.name);
        },
        .size => {
            if (a.size > b.size) {
                result = .lt; // larger sizes come first
            } else if (a.size < b.size) {
                result = .gt;
            } else {
                result = std.mem.order(u8, a.name, b.name);
            }
        },
        .time => {
            const a_sec = switch (opts.time_type) {
                .mtime => a.mtime_sec,
                .ctime => a.ctime_sec,
                .atime => a.atime_sec,
            };
            const b_sec = switch (opts.time_type) {
                .mtime => b.mtime_sec,
                .ctime => b.ctime_sec,
                .atime => b.atime_sec,
            };
            if (a_sec > b_sec) {
                result = .lt; // newer times come first
            } else if (a_sec < b_sec) {
                result = .gt;
            } else {
                const a_nsec = switch (opts.time_type) {
                    .mtime => a.mtime_nsec,
                    .ctime => a.ctime_nsec,
                    .atime => a.atime_nsec,
                };
                const b_nsec = switch (opts.time_type) {
                    .mtime => b.mtime_nsec,
                    .ctime => b.ctime_nsec,
                    .atime => b.atime_nsec,
                };
                if (a_nsec > b_nsec) {
                    result = .lt;
                } else if (a_nsec < b_nsec) {
                    result = .gt;
                } else {
                    result = std.mem.order(u8, a.name, b.name);
                }
            }
        },
        .none => {
            return false;
        },
    }

    if (opts.reverse_sort and opts.sort != .none) {
        return result == .gt;
    }
    return result == .lt;
}

/// Format the 10-character POSIX file mode string (e.g. "drwxr-xr-x").
pub fn formatFileMode(buf: *[10]u8, mode: u32, kind: std.Io.File.Kind) void {
    buf[0] = switch (kind) {
        .directory => 'd',
        .block_device => 'b',
        .character_device => 'c',
        .sym_link => 'l',
        .named_pipe => 'p',
        .unix_domain_socket => 's',
        else => '-',
    };

    // Owner permissions
    buf[1] = if ((mode & 0o400) != 0) 'r' else '-';
    buf[2] = if ((mode & 0o200) != 0) 'w' else '-';
    const is_setuid = (mode & 0o4000) != 0;
    const is_owner_exec = (mode & 0o100) != 0;
    buf[3] = if (is_setuid) (if (is_owner_exec) 's' else 'S') else (if (is_owner_exec) 'x' else '-');

    // Group permissions
    buf[4] = if ((mode & 0o040) != 0) 'r' else '-';
    buf[5] = if ((mode & 0o020) != 0) 'w' else '-';
    const is_setgid = (mode & 0o2000) != 0;
    const is_group_exec = (mode & 0o010) != 0;
    buf[6] = if (is_setgid) (if (is_group_exec) 's' else 'S') else (if (is_group_exec) 'x' else '-');

    // Other permissions
    buf[7] = if ((mode & 0o004) != 0) 'r' else '-';
    buf[8] = if ((mode & 0o002) != 0) 'w' else '-';
    const is_sticky = (mode & 0o1000) != 0;
    const is_other_exec = (mode & 0o001) != 0;
    if (kind == .directory and is_sticky) {
        buf[9] = if (is_other_exec) 't' else 'T';
    } else {
        buf[9] = if (is_other_exec) 'x' else '-';
    }
}

/// Format the POSIX date/time string: "%b %e %H:%M" or "%b %e  %Y".
pub fn formatDate(buf: []u8, timestamp_sec: i64, now_sec: i64) []const u8 {
    const months = [_][]const u8{
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    };

    const sec: u64 = if (timestamp_sec < 0) 0 else @intCast(timestamp_sec);
    const epoch_sec = std.time.epoch.EpochSeconds{ .secs = sec };
    const epoch_day = epoch_sec.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_sec = epoch_sec.getDaySeconds();

    const month_idx = month_day.month.numeric() - 1;
    const month_str = if (month_idx < months.len) months[month_idx] else "???";
    const day = month_day.day_index + 1;

    // Six months rule: within last 182 days and not in the future (with 60s slack)
    const six_months_sec: i64 = 182 * 24 * 3600;
    const is_recent = (timestamp_sec <= now_sec + 60) and (timestamp_sec >= now_sec - six_months_sec);

    if (is_recent) {
        const hours = day_sec.getHoursIntoDay();
        const mins = day_sec.getMinutesIntoHour();
        return std.fmt.bufPrint(buf, "{s} {d:>2} {d:0>2}:{d:0>2}", .{ month_str, day, hours, mins }) catch "??? ?? ??:??";
    } else {
        const year = year_day.year;
        return std.fmt.bufPrint(buf, "{s} {d:>2}  {d:>4}", .{ month_str, day, year }) catch "??? ??  ????";
    }
}

/// Get the file indicator character for -F or -p options.
pub fn getIndicator(opts: LsOptions, entry: FileInfo) ?u8 {
    if (opts.classify) {
        return switch (entry.kind) {
            .directory => '/',
            .sym_link => '@',
            .named_pipe => '|',
            .unix_domain_socket => '=',
            .file => if ((entry.mode & 0o111) != 0) '*' else null,
            else => null,
        };
    } else if (opts.slash_dirs) {
        if (entry.kind == .directory) return '/';
    }
    return null;
}

/// Write an entry name, converting non-printable characters to '?' if -q is enabled.
pub fn writeEntryName(writer: anytype, name: []const u8, question_unprintable: bool) !void {
    if (!question_unprintable) {
        try writer.writeAll(name);
        return;
    }
    for (name) |c| {
        if (std.ascii.isPrint(c)) {
            try writer.writeByte(c);
        } else {
            try writer.writeByte('?');
        }
    }
}

/// Render a single entry in single-column or stream format.
pub fn writeEntryFormatted(
    writer: anytype,
    opts: LsOptions,
    entry: FileInfo,
) !void {
    if (opts.show_inode) {
        try writer.print("{d} ", .{entry.ino});
    }
    if (opts.show_blocks) {
        const blocks = if (opts.kib_blocks) (entry.blocks + 1) / 2 else entry.blocks;
        try writer.print("{d} ", .{blocks});
    }
    try writeEntryName(writer, entry.name, opts.question_unprintable);
    if (getIndicator(opts, entry)) |ind| {
        try writer.writeByte(ind);
    }
}

/// Output entries in Single Column format (-1).
pub fn printSingleColumn(
    writer: anytype,
    opts: LsOptions,
    entries: []const FileInfo,
) !void {
    for (entries) |entry| {
        try writeEntryFormatted(writer, opts, entry);
        try writer.writeByte('\n');
    }
}

/// Output entries in Stream format (-m).
pub fn printStream(
    writer: anytype,
    opts: LsOptions,
    entries: []const FileInfo,
    line_width: usize,
) !void {
    if (entries.len == 0) return;

    var current_col: usize = 0;
    var name_buf: [std.Io.Dir.max_path_bytes + 64]u8 = undefined;

    for (entries, 0..) |entry, idx| {
        var fw = std.Io.Writer.fixed(&name_buf);
        try writeEntryFormatted(&fw, opts, entry);
        const text = fw.buffered();

        const is_last = (idx == entries.len - 1);
        const sep_len: usize = if (is_last) 1 else 2; // '\n' or ", "

        if (current_col > 0 and current_col + text.len + sep_len > line_width) {
            try writer.writeAll(",\n");
            current_col = 0;
        } else if (current_col > 0) {
            try writer.writeAll(", ");
            current_col += 2;
        }

        try writer.writeAll(text);
        current_col += text.len;
    }
    try writer.writeByte('\n');
}

/// Output entries in Multi-Column format (-C or -x).
pub fn printColumns(
    writer: anytype,
    opts: LsOptions,
    entries: []const FileInfo,
    line_width: usize,
    across: bool,
) !void {
    if (entries.len == 0) return;

    // Calculate maximum rendered item length
    var max_item_len: usize = 0;
    var item_buf: [std.Io.Dir.max_path_bytes + 64]u8 = undefined;

    for (entries) |entry| {
        var fw = std.Io.Writer.fixed(&item_buf);
        try writeEntryFormatted(&fw, opts, entry);
        const len = fw.buffered().len;
        if (len > max_item_len) max_item_len = len;
    }

    const col_width = max_item_len + 2; // 2 space padding between columns
    var num_cols = line_width / col_width;
    if (num_cols == 0) num_cols = 1;
    if (num_cols > entries.len) num_cols = entries.len;

    const num_rows = (entries.len + num_cols - 1) / num_cols;

    for (0..num_rows) |row| {
        for (0..num_cols) |col| {
            const idx = if (across)
                row * num_cols + col
            else
                col * num_rows + row;

            if (idx >= entries.len) continue;

            const entry = entries[idx];
            var fw = std.Io.Writer.fixed(&item_buf);
            try writeEntryFormatted(&fw, opts, entry);
            const text = fw.buffered();

            try writer.writeAll(text);

            const is_last_col = (col + 1 == num_cols) or (if (across) (idx + 1 == entries.len) else ((col + 1) * num_rows + row >= entries.len));
            if (!is_last_col) {
                const padding = col_width - text.len;
                for (0..padding) |_| {
                    try writer.writeByte(' ');
                }
            }
        }
        try writer.writeByte('\n');
    }
}

pub fn numDigits(val: anytype) usize {
    var count: usize = 0;
    var v = val;
    if (v == 0) return 1;
    while (v > 0) {
        count += 1;
        v = @divTrunc(v, 10);
    }
    return count;
}

pub fn getOwnerString(io: std.Io, uid: u32, buf: []u8, numeric_ids: bool) []const u8 {
    if (!numeric_ids) {
        if (common_user.findNameByUid(io, uid, buf)) |name| {
            return name;
        }
    }
    return std.fmt.bufPrint(buf, "{d}", .{uid}) catch "???";
}

pub fn getGroupString(io: std.Io, gid: u32, buf: []u8, numeric_ids: bool) []const u8 {
    if (!numeric_ids) {
        if (common_user.findNameByGid(io, gid, buf)) |name| {
            return name;
        }
    }
    return std.fmt.bufPrint(buf, "{d}", .{gid}) catch "???";
}

/// Long listing format (-l, -n, -g, -o).
pub fn printLong(
    io: std.Io,
    writer: anytype,
    opts: LsOptions,
    entries: []const FileInfo,
    now_sec: i64,
) !void {
    if (entries.len == 0) return;

    // Precalculate column alignments
    var max_nlink: u32 = 0;
    var max_size: u64 = 0;
    var max_owner_len: usize = 0;
    var max_group_len: usize = 0;
    var max_ino: u64 = 0;
    var max_blocks: u64 = 0;

    var owner_buf: [64]u8 = undefined;
    var group_buf: [64]u8 = undefined;

    for (entries) |entry| {
        if (entry.nlink > max_nlink) max_nlink = entry.nlink;
        if (entry.size > max_size) max_size = entry.size;
        if (entry.ino > max_ino) max_ino = entry.ino;
        const b = if (opts.kib_blocks) (entry.blocks + 1) / 2 else entry.blocks;
        if (b > max_blocks) max_blocks = b;

        if (!opts.hide_owner) {
            const owner_str = getOwnerString(io, entry.uid, &owner_buf, opts.numeric_ids);
            if (owner_str.len > max_owner_len) max_owner_len = owner_str.len;
        }

        if (!opts.hide_group) {
            const group_str = getGroupString(io, entry.gid, &group_buf, opts.numeric_ids);
            if (group_str.len > max_group_len) max_group_len = group_str.len;
        }
    }

    // Determine field widths
    const nlink_width = numDigits(max_nlink);
    const size_width = numDigits(max_size);
    const ino_width = numDigits(max_ino);
    const blocks_width = numDigits(max_blocks);

    var mode_buf: [10]u8 = undefined;
    var date_buf: [32]u8 = undefined;

    for (entries) |entry| {
        if (opts.show_inode) {
            try writer.print("{d:>[1]} ", .{ entry.ino, ino_width });
        }
        if (opts.show_blocks) {
            const b = if (opts.kib_blocks) (entry.blocks + 1) / 2 else entry.blocks;
            try writer.print("{d:>[1]} ", .{ b, blocks_width });
        }

        formatFileMode(&mode_buf, entry.mode, entry.kind);
        try writer.writeAll(&mode_buf);

        try writer.print(" {d:>[1]}", .{ entry.nlink, nlink_width });

        if (!opts.hide_owner) {
            const owner_str = getOwnerString(io, entry.uid, &owner_buf, opts.numeric_ids);
            try writer.print(" {s:<[1]}", .{ owner_str, max_owner_len });
        }

        if (!opts.hide_group) {
            const group_str = getGroupString(io, entry.gid, &group_buf, opts.numeric_ids);
            try writer.print(" {s:<[1]}", .{ group_str, max_group_len });
        }

        // Size or Device info
        if (entry.kind == .character_device or entry.kind == .block_device) {
            const dev_major = entry.dev >> 32;
            const dev_minor = entry.dev & 0xffffffff;
            try writer.print(" {d:>3}, {d:>3}", .{ dev_major, dev_minor });
        } else {
            try writer.print(" {d:>[1]}", .{ entry.size, size_width });
        }

        // Date and time
        const t_sec = switch (opts.time_type) {
            .mtime => entry.mtime_sec,
            .ctime => entry.ctime_sec,
            .atime => entry.atime_sec,
        };
        const date_str = formatDate(&date_buf, t_sec, now_sec);
        try writer.print(" {s} ", .{date_str});

        // Pathname
        try writeEntryName(writer, entry.name, opts.question_unprintable);
        if (getIndicator(opts, entry)) |ind| {
            try writer.writeByte(ind);
        }

        // Symbolic link target
        if (entry.kind == .sym_link and entry.link_target != null) {
            try writer.writeAll(" -> ");
            try writeEntryName(writer, entry.link_target.?, opts.question_unprintable);
            if (opts.classify and entry.target_kind != null) {
                const tgt_entry = FileInfo{
                    .name = "",
                    .full_path = "",
                    .ino = 0,
                    .nlink = 0,
                    .uid = 0,
                    .gid = 0,
                    .mode = entry.target_mode orelse 0,
                    .size = 0,
                    .blocks = 0,
                    .mtime_sec = 0,
                    .mtime_nsec = 0,
                    .ctime_sec = 0,
                    .ctime_nsec = 0,
                    .atime_sec = 0,
                    .atime_nsec = 0,
                    .kind = entry.target_kind.?,
                };
                if (getIndicator(opts, tgt_entry)) |tgt_ind| {
                    try writer.writeByte(tgt_ind);
                }
            }
        }

        try writer.writeByte('\n');
    }
}

/// Print formatted list of entries according to the chosen format mode.
pub fn outputEntries(
    io: std.Io,
    writer: anytype,
    opts: LsOptions,
    entries: []const FileInfo,
    is_directory_listing: bool,
    now_sec: i64,
) !void {
    if (is_directory_listing and (opts.format == .long or opts.show_blocks)) {
        var total_blocks: u64 = 0;
        for (entries) |entry| {
            const b = if (opts.kib_blocks) (entry.blocks + 1) / 2 else entry.blocks;
            total_blocks += b;
        }
        try writer.print("total {d}\n", .{total_blocks});
    }

    switch (opts.format) {
        .single_column => try printSingleColumn(writer, opts, entries),
        .long => try printLong(io, writer, opts, entries, now_sec),
        .columns_down => try printColumns(writer, opts, entries, 80, false),
        .columns_across => try printColumns(writer, opts, entries, 80, true),
        .stream => try printStream(writer, opts, entries, 80),
    }
}

pub const Ancestor = struct {
    dev: u64,
    ino: u64,
};

/// List contents of a single directory, recursing if -R is set.
pub fn listDirectory(
    io: std.Io,
    writer: anytype,
    allocator: std.mem.Allocator,
    opts: LsOptions,
    dir_path: []const u8,
    print_header: bool,
    now_sec: i64,
    ancestors: *std.ArrayList(Ancestor),
    first_output_done: *bool,
) bool {
    var all_success = true;

    // Stat the directory itself for loop detection and validity
    const self_info = getFileInfo(io, allocator, dir_path, dir_path, opts.follow_all or opts.follow_operands, false) catch |err| {
        common_error.report("ls", dir_path, err);
        return false;
    };

    // Cycle detection for recursive listings
    if (self_info.dev != 0 and self_info.ino != 0) {
        for (ancestors.items) |anc| {
            if (anc.dev == self_info.dev and anc.ino == self_info.ino) {
                common_error.report("ls", dir_path, error.SymLinkLoop);
                return false;
            }
        }
        ancestors.append(allocator, .{ .dev = self_info.dev, .ino = self_info.ino }) catch return false;
    }
    defer if (self_info.dev != 0 and self_info.ino != 0) {
        _ = ancestors.pop();
    };

    if (print_header) {
        if (first_output_done.*) {
            writer.print("\n{s}:\n", .{dir_path}) catch return false;
        } else {
            writer.print("{s}:\n", .{dir_path}) catch return false;
            first_output_done.* = true;
        }
    } else {
        first_output_done.* = true;
    }

    var entries: std.ArrayList(FileInfo) = .empty;
    defer {
        for (entries.items) |e| {
            if (e.link_target) |lt| allocator.free(lt);
            allocator.free(e.full_path);
            allocator.free(e.name);
        }
        entries.deinit(allocator);
    }

    // Explicitly synthesize '.' and '..' when -a is active (Dir.iterate filters them out)
    if (opts.filter == .all) {
        var dot_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const dot_path = joinPath(&dot_buf, dir_path, ".") catch ".";
        if (getFileInfo(io, allocator, ".", dot_path, false, false)) |info| {
            const owned_name = allocator.dupe(u8, ".") catch return false;
            const owned_path = allocator.dupe(u8, dot_path) catch return false;
            var item = info;
            item.name = owned_name;
            item.full_path = owned_path;
            entries.append(allocator, item) catch return false;
        } else |_| {}

        const dotdot_path = joinPath(&dot_buf, dir_path, "..") catch "..";
        if (getFileInfo(io, allocator, "..", dotdot_path, false, false)) |info| {
            const owned_name = allocator.dupe(u8, "..") catch return false;
            const owned_path = allocator.dupe(u8, dotdot_path) catch return false;
            var item = info;
            item.name = owned_name;
            item.full_path = owned_path;
            entries.append(allocator, item) catch return false;
        } else |_| {}
    }

    // Read directory entries
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{
        .iterate = true,
        .follow_symlinks = opts.follow_all or opts.follow_operands,
    }) catch |err| {
        common_error.report("ls", dir_path, err);
        return false;
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (true) {
        const maybe_entry = it.next(io) catch |err| {
            common_error.report("ls", dir_path, err);
            all_success = false;
            break;
        };
        const entry = maybe_entry orelse break;

        // Skip '.' and '..' if returned
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;

        // Filter hidden files
        if (entry.name.len > 0 and entry.name[0] == '.') {
            if (opts.filter == .default) continue;
        }

        var child_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const child_full_path = joinPath(&child_buf, dir_path, entry.name) catch continue;

        const follow_child = opts.follow_all;
        const need_link_info = (opts.format == .long) or opts.classify;

        const info = getFileInfo(io, allocator, entry.name, child_full_path, follow_child, need_link_info) catch |err| {
            common_error.report("ls", child_full_path, err);
            all_success = false;
            continue;
        };

        const owned_name = allocator.dupe(u8, entry.name) catch continue;
        const owned_path = allocator.dupe(u8, child_full_path) catch continue;

        var stored_info = info;
        stored_info.name = owned_name;
        stored_info.full_path = owned_path;

        entries.append(allocator, stored_info) catch continue;
    }

    // Sort directory entries
    if (opts.sort != .none) {
        std.mem.sort(FileInfo, entries.items, opts, compareEntries);
    }

    // Output formatted entries
    outputEntries(io, writer, opts, entries.items, true, now_sec) catch return false;

    // Recurse into subdirectories if -R is specified
    if (opts.recursive) {
        for (entries.items) |e| {
            if (std.mem.eql(u8, e.name, ".") or std.mem.eql(u8, e.name, "..")) continue;
            // POSIX: When a symbolic link to a directory is encountered, do not recurse unless -L is specified
            const is_recurse_dir = if (e.kind == .directory)
                true
            else if (e.kind == .sym_link and opts.follow_all and e.target_kind == .directory)
                true
            else
                false;

            if (is_recurse_dir) {
                if (!listDirectory(io, writer, allocator, opts, e.full_path, true, now_sec, ancestors, first_output_done)) {
                    all_success = false;
                }
            }
        }
    }

    return all_success;
}

pub fn parseOptions(args: []const [:0]const u8, opts: *LsOptions) ![]const [:0]const u8 {
    var parser = common_args.ArgParser.init(args);

    var long_seen = false;
    var last_column_format: ?FormatMode = null;

    while (parser.next("ikqrsglnoAaCmx1FpHLRdfStcu")) |opt| {
        switch (opt) {
            'a' => opts.filter = .all,
            'A' => opts.filter = .almost_all,
            'd' => {
                opts.directory_itself = true;
                opts.recursive = false;
            },
            'R' => {
                opts.recursive = true;
                opts.directory_itself = false;
            },
            'H' => {
                opts.follow_operands = true;
                opts.follow_all = false;
            },
            'L' => {
                opts.follow_all = true;
                opts.follow_operands = false;
            },
            'F' => {
                opts.classify = true;
                opts.slash_dirs = false;
            },
            'p' => {
                opts.slash_dirs = true;
                opts.classify = false;
            },
            'i' => opts.show_inode = true,
            's' => opts.show_blocks = true,
            'k' => opts.kib_blocks = true,
            'q' => opts.question_unprintable = true,
            'r' => opts.reverse_sort = true,
            'f' => {
                opts.filter = .all;
                opts.sort = .none;
            },
            'S' => {
                if (opts.sort != .none) opts.sort = .size;
            },
            't' => {
                if (opts.sort != .none) opts.sort = .time;
            },
            'c' => opts.time_type = .ctime,
            'u' => opts.time_type = .atime,
            'l' => {
                long_seen = true;
                last_column_format = null;
            },
            'n' => {
                long_seen = true;
                opts.numeric_ids = true;
                last_column_format = null;
            },
            'g' => {
                long_seen = true;
                opts.hide_owner = true;
                last_column_format = null;
            },
            'o' => {
                long_seen = true;
                opts.hide_group = true;
                last_column_format = null;
            },
            'C' => last_column_format = .columns_down,
            'x' => last_column_format = .columns_across,
            'm' => last_column_format = .stream,
            '1' => last_column_format = null,
            else => return error.InvalidArgument,
        }
    }

    if (last_column_format) |fmt| {
        opts.format = fmt;
    } else if (long_seen) {
        opts.format = .long;
    } else {
        opts.format = .single_column;
    }

    return parser.remaining();
}

pub fn run(allocator: std.mem.Allocator, args: []const [:0]const u8) u8 {
    const io = std.Io.Threaded.global_single_threaded.io();

    var opts: LsOptions = .{};
    const operands = parseOptions(args, &opts) catch |err| {
        common_error.report("ls", "invalid option", err);
        return common_error.EXIT_SYNTAX;
    };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const stdout_file = std.Io.File.stdout();
    var stdout_buf: [16 * 1024]u8 = undefined;
    var fw = stdout_file.writerStreaming(io, &stdout_buf);
    const writer = &fw.interface;

    const now_ts = std.Io.Clock.real.now(io);
    const now_sec: i64 = @intCast(@divTrunc(now_ts.nanoseconds, std.time.ns_per_s));

    const file_operands = if (operands.len == 0)
        &[_][:0]const u8{"."}
    else
        operands;

    var non_dirs: std.ArrayList(FileInfo) = .empty;
    defer non_dirs.deinit(aa);
    var dirs: std.ArrayList([]const u8) = .empty;
    defer dirs.deinit(aa);
    var exit_status: u8 = common_error.EXIT_SUCCESS;

    for (file_operands) |op| {
        // POSIX: If none of -d, -F, -l specified, or -H/-L specified, follow symlinks to directories
        const follow_for_classification = if (opts.directory_itself or opts.classify or opts.format == .long)
            opts.follow_operands or opts.follow_all
        else
            true;

        const info = getFileInfo(io, aa, op, op, follow_for_classification, (opts.format == .long) or opts.classify) catch |err| {
            common_error.report("ls", op, err);
            exit_status = common_error.EXIT_FAILURE;
            continue;
        };

        if (opts.directory_itself or info.kind != .directory) {
            non_dirs.append(aa, info) catch continue;
        } else {
            dirs.append(aa, op) catch continue;
        }
    }

    var first_output_done = false;

    // 1. Output non-directory operands first
    if (non_dirs.items.len > 0) {
        if (opts.sort != .none) {
            std.mem.sort(FileInfo, non_dirs.items, opts, compareEntries);
        }
        outputEntries(io, writer, opts, non_dirs.items, false, now_sec) catch {
            common_error.report("ls", null, error.BrokenPipe);
            return common_error.toExitCode(error.BrokenPipe);
        };
        first_output_done = true;
    }

    // 2. Output directory operands
    const print_headers = (file_operands.len > 1) or opts.recursive;

    var ancestors: std.ArrayList(Ancestor) = .empty;
    defer ancestors.deinit(aa);
    for (dirs.items) |dir_path| {
        if (!listDirectory(io, writer, aa, opts, dir_path, print_headers, now_sec, &ancestors, &first_output_done)) {
            exit_status = common_error.EXIT_FAILURE;
        }
    }

    fw.flush() catch |err| {
        common_error.report("ls", null, err);
        return common_error.toExitCode(err);
    };

    return exit_status;
}

pub fn main(init: std.process.Init) u8 {
    const all_args = init.minimal.args.toSlice(init.arena.allocator()) catch |err| {
        common_error.report("ls", null, err);
        return common_error.EXIT_FAILURE;
    };
    const cmd_args = if (all_args.len > 1) all_args[1..] else &.{};
    return run(init.arena.allocator(), cmd_args);
}

// ============================================================================
// Unit Tests & POSIX Conformance Verification
// ============================================================================

test "ls: option parsing and mutual exclusion" {
    var opts: LsOptions = .{};

    // -1 resets column formats
    _ = try parseOptions(&.{"-C", "-1"}, &opts);
    try std.testing.expectEqual(FormatMode.single_column, opts.format);

    // -l after -C sets long format
    _ = try parseOptions(&.{"-C", "-l"}, &opts);
    try std.testing.expectEqual(FormatMode.long, opts.format);

    // -C after -l disables long format
    _ = try parseOptions(&.{"-l", "-C"}, &opts);
    try std.testing.expectEqual(FormatMode.columns_down, opts.format);

    // -1 after -l and -C re-enables long format
    _ = try parseOptions(&.{"-l", "-C", "-1"}, &opts);
    try std.testing.expectEqual(FormatMode.long, opts.format);

    // -f turns on -a and disables sort
    _ = try parseOptions(&.{"-f"}, &opts);
    try std.testing.expectEqual(FilterMode.all, opts.filter);
    try std.testing.expectEqual(SortKey.none, opts.sort);

    // -A sets almost_all
    _ = try parseOptions(&.{"-A"}, &opts);
    try std.testing.expectEqual(FilterMode.almost_all, opts.filter);
}

test "ls: invalid option returns EXIT_SYNTAX" {
    const res = run(std.testing.allocator, &.{"-Z"});
    try std.testing.expectEqual(common_error.EXIT_SYNTAX, res);
}

test "ls: file mode formatting" {
    var buf: [10]u8 = undefined;

    formatFileMode(&buf, 0o755, .file);
    try std.testing.expectEqualStrings("-rwxr-xr-x", &buf);

    formatFileMode(&buf, 0o755, .directory);
    try std.testing.expectEqualStrings("drwxr-xr-x", &buf);

    formatFileMode(&buf, 0o644, .file);
    try std.testing.expectEqualStrings("-rw-r--r--", &buf);

    formatFileMode(&buf, 0o4755, .file);
    try std.testing.expectEqualStrings("-rwsr-xr-x", &buf);

    formatFileMode(&buf, 0o2755, .file);
    try std.testing.expectEqualStrings("-rwxr-sr-x", &buf);

    formatFileMode(&buf, 0o1777, .directory);
    try std.testing.expectEqualStrings("drwxrwxrwt", &buf);
}

test "ls: date formatting recent vs old" {
    var buf: [32]u8 = undefined;
    const now: i64 = 1700000000;

    // Recent time (1 day ago)
    const recent = formatDate(&buf, now - 86400, now);
    try std.testing.expect(recent.len >= 11);
    try std.testing.expect(std.mem.indexOfScalar(u8, recent, ':') != null);

    // Old time (1 year ago)
    const old = formatDate(&buf, now - 365 * 86400, now);
    try std.testing.expect(old.len >= 11);
    try std.testing.expect(std.mem.indexOfScalar(u8, old, ':') == null);
}

test "ls: classification indicator" {
    const opts_f = LsOptions{ .classify = true };
    const opts_p = LsOptions{ .slash_dirs = true };

    const dir_info = FileInfo{
        .name = "dir",
        .full_path = "dir",
        .ino = 1,
        .nlink = 1,
        .uid = 0,
        .gid = 0,
        .mode = 0o755,
        .size = 0,
        .blocks = 0,
        .mtime_sec = 0,
        .mtime_nsec = 0,
        .ctime_sec = 0,
        .ctime_nsec = 0,
        .atime_sec = 0,
        .atime_nsec = 0,
        .kind = .directory,
    };
    try std.testing.expectEqual(@as(?u8, '/'), getIndicator(opts_f, dir_info));
    try std.testing.expectEqual(@as(?u8, '/'), getIndicator(opts_p, dir_info));

    const exec_info = FileInfo{
        .name = "bin",
        .full_path = "bin",
        .ino = 2,
        .nlink = 1,
        .uid = 0,
        .gid = 0,
        .mode = 0o755,
        .size = 0,
        .blocks = 0,
        .mtime_sec = 0,
        .mtime_nsec = 0,
        .ctime_sec = 0,
        .ctime_nsec = 0,
        .atime_sec = 0,
        .atime_nsec = 0,
        .kind = .file,
    };
    try std.testing.expectEqual(@as(?u8, '*'), getIndicator(opts_f, exec_info));
    try std.testing.expectEqual(@as(?u8, null), getIndicator(opts_p, exec_info));
}

test "ls: sorting logic (alphabetical, size, time, reverse)" {
    const e1 = FileInfo{
        .name = "apple",
        .full_path = "apple",
        .ino = 1,
        .nlink = 1,
        .uid = 0,
        .gid = 0,
        .mode = 0o644,
        .size = 100,
        .blocks = 1,
        .mtime_sec = 1000,
        .mtime_nsec = 0,
        .ctime_sec = 1000,
        .ctime_nsec = 0,
        .atime_sec = 1000,
        .atime_nsec = 0,
        .kind = .file,
    };
    const e2 = FileInfo{
        .name = "banana",
        .full_path = "banana",
        .ino = 2,
        .nlink = 1,
        .uid = 0,
        .gid = 0,
        .mode = 0o644,
        .size = 500,
        .blocks = 1,
        .mtime_sec = 2000,
        .mtime_nsec = 0,
        .ctime_sec = 2000,
        .ctime_nsec = 0,
        .atime_sec = 2000,
        .atime_nsec = 0,
        .kind = .file,
    };

    // Alphabetical
    const opts_name = LsOptions{ .sort = .name };
    try std.testing.expect(compareEntries(opts_name, e1, e2));
    try std.testing.expect(!compareEntries(opts_name, e2, e1));

    // Reverse alphabetical
    const opts_rname = LsOptions{ .sort = .name, .reverse_sort = true };
    try std.testing.expect(!compareEntries(opts_rname, e1, e2));
    try std.testing.expect(compareEntries(opts_rname, e2, e1));

    // Size: larger first
    const opts_size = LsOptions{ .sort = .size };
    try std.testing.expect(!compareEntries(opts_size, e1, e2));
    try std.testing.expect(compareEntries(opts_size, e2, e1));

    // Reverse size: smaller first
    const opts_rsize = LsOptions{ .sort = .size, .reverse_sort = true };
    try std.testing.expect(compareEntries(opts_rsize, e1, e2));

    // Time: newer first
    const opts_time = LsOptions{ .sort = .time, .time_type = .mtime };
    try std.testing.expect(!compareEntries(opts_time, e1, e2));
    try std.testing.expect(compareEntries(opts_time, e2, e1));
}

test "ls: stream formatting output (-m)" {
    var out_buf: [256]u8 = undefined;
    var fw = std.Io.Writer.fixed(&out_buf);

    const entries = [_]FileInfo{
        .{
            .name = "f1",
            .full_path = "f1",
            .ino = 1,
            .nlink = 1,
            .uid = 0,
            .gid = 0,
            .mode = 0o644,
            .size = 10,
            .blocks = 1,
            .mtime_sec = 0,
            .mtime_nsec = 0,
            .ctime_sec = 0,
            .ctime_nsec = 0,
            .atime_sec = 0,
            .atime_nsec = 0,
            .kind = .file,
        },
        .{
            .name = "f2",
            .full_path = "f2",
            .ino = 2,
            .nlink = 1,
            .uid = 0,
            .gid = 0,
            .mode = 0o644,
            .size = 20,
            .blocks = 1,
            .mtime_sec = 0,
            .mtime_nsec = 0,
            .ctime_sec = 0,
            .ctime_nsec = 0,
            .atime_sec = 0,
            .atime_nsec = 0,
            .kind = .file,
        },
    };

    const opts: LsOptions = .{ .format = .stream };
    try printStream(&fw, opts, &entries, 80);
    try std.testing.expectEqualStrings("f1, f2\n", fw.buffered());
}

test "ls: execution against directory and file operands" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const test_dir = "zig-cache/tmp_test_ls_ops";
    std.Io.Dir.cwd().createDirPath(io, test_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, test_dir) catch {};

    const f1_path = "zig-cache/tmp_test_ls_ops/alpha.txt";
    const f2_path = "zig-cache/tmp_test_ls_ops/.beta.txt";

    {
        const f1 = try std.Io.Dir.cwd().createFile(io, f1_path, .{});
        defer f1.close(io);
        try f1.writeStreamingAll(io, "alpha");
    }
    {
        const f2 = try std.Io.Dir.cwd().createFile(io, f2_path, .{});
        defer f2.close(io);
        try f2.writeStreamingAll(io, "beta");
    }

    // Listing valid file operand returns SUCCESS
    const ret_file = run(allocator, &.{f1_path});
    try std.testing.expectEqual(common_error.EXIT_SUCCESS, ret_file);

    // Listing valid directory returns SUCCESS
    const ret_dir = run(allocator, &.{test_dir});
    try std.testing.expectEqual(common_error.EXIT_SUCCESS, ret_dir);

    // Directory itself with -d returns SUCCESS
    const ret_d = run(allocator, &.{ "-d", test_dir });
    try std.testing.expectEqual(common_error.EXIT_SUCCESS, ret_d);

    // Listing with -a and -A returns SUCCESS
    const ret_a = run(allocator, &.{ "-a", test_dir });
    try std.testing.expectEqual(common_error.EXIT_SUCCESS, ret_a);

    const ret_cap_a = run(allocator, &.{ "-A", test_dir });
    try std.testing.expectEqual(common_error.EXIT_SUCCESS, ret_cap_a);

    // Long format options -l, -n, -g, -o
    const ret_l = run(allocator, &.{ "-l", test_dir });
    try std.testing.expectEqual(common_error.EXIT_SUCCESS, ret_l);

    const ret_n = run(allocator, &.{ "-n", test_dir });
    try std.testing.expectEqual(common_error.EXIT_SUCCESS, ret_n);

    const ret_g = run(allocator, &.{ "-g", test_dir });
    try std.testing.expectEqual(common_error.EXIT_SUCCESS, ret_g);

    const ret_o = run(allocator, &.{ "-o", test_dir });
    try std.testing.expectEqual(common_error.EXIT_SUCCESS, ret_o);

    // Indicators and block options -F, -p, -i, -s, -k
    const ret_f = run(allocator, &.{ "-Fisk", test_dir });
    try std.testing.expectEqual(common_error.EXIT_SUCCESS, ret_f);

    // Formats -1, -C, -x, -m
    const ret_1 = run(allocator, &.{ "-1", test_dir });
    try std.testing.expectEqual(common_error.EXIT_SUCCESS, ret_1);

    const ret_c = run(allocator, &.{ "-C", test_dir });
    try std.testing.expectEqual(common_error.EXIT_SUCCESS, ret_c);

    const ret_x = run(allocator, &.{ "-x", test_dir });
    try std.testing.expectEqual(common_error.EXIT_SUCCESS, ret_x);

    const ret_m = run(allocator, &.{ "-m", test_dir });
    try std.testing.expectEqual(common_error.EXIT_SUCCESS, ret_m);

    // Sorting options -S, -t, -r, -f
    const ret_s = run(allocator, &.{ "-S", test_dir });
    try std.testing.expectEqual(common_error.EXIT_SUCCESS, ret_s);

    const ret_t = run(allocator, &.{ "-t", test_dir });
    try std.testing.expectEqual(common_error.EXIT_SUCCESS, ret_t);

    const ret_r = run(allocator, &.{ "-r", test_dir });
    try std.testing.expectEqual(common_error.EXIT_SUCCESS, ret_r);

    const ret_unsorted = run(allocator, &.{ "-f", test_dir });
    try std.testing.expectEqual(common_error.EXIT_SUCCESS, ret_unsorted);

    // Non-existent operand returns FAILURE
    const ret_none = run(allocator, &.{"zig-cache/tmp_test_ls_ops/nonexistent"});
    try std.testing.expectEqual(common_error.EXIT_FAILURE, ret_none);
}

test "ls: recursive listing (-R)" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const base_dir = "zig-cache/tmp_test_ls_rec";
    const sub_dir = "zig-cache/tmp_test_ls_rec/sub";
    std.Io.Dir.cwd().createDirPath(io, sub_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, base_dir) catch {};

    const f1 = try std.Io.Dir.cwd().createFile(io, "zig-cache/tmp_test_ls_rec/f1.txt", .{});
    f1.close(io);

    const f2 = try std.Io.Dir.cwd().createFile(io, "zig-cache/tmp_test_ls_rec/sub/f2.txt", .{});
    f2.close(io);

    const ret_r = run(allocator, &.{ "-R", base_dir });
    try std.testing.expectEqual(common_error.EXIT_SUCCESS, ret_r);
}
