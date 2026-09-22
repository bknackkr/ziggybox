const std = @import("std");

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
pub fn parseMode(str: []const u8, initial_mode: std.posix.mode_t, umask_val: std.posix.mode_t) ?std.posix.mode_t {
    if (parseOctalMode(str)) |octal| {
        return octal;
    }
    return parseSymbolicMode(str, initial_mode, umask_val);
}

// ============================================================================
// Unit Tests
// ============================================================================

test "mode: octal mode parsing" {
    try std.testing.expectEqual(@as(?std.posix.mode_t, 0o755), parseOctalMode("755"));
    try std.testing.expectEqual(@as(?std.posix.mode_t, 0o755), parseOctalMode("0755"));
    try std.testing.expectEqual(@as(?std.posix.mode_t, 0o700), parseOctalMode("700"));
    try std.testing.expectEqual(@as(?std.posix.mode_t, 0o777), parseOctalMode("777"));
    try std.testing.expectEqual(@as(?std.posix.mode_t, 0o1777), parseOctalMode("1777"));
    try std.testing.expectEqual(@as(?std.posix.mode_t, null), parseOctalMode("888"));
    try std.testing.expectEqual(@as(?std.posix.mode_t, null), parseOctalMode(""));
}

test "mode: symbolic mode parsing" {
    const umask_val: std.posix.mode_t = 0o022;
    const initial = 0o777 & ~umask_val; // 0755

    // Exact assignment
    try std.testing.expectEqual(@as(?std.posix.mode_t, 0o755), parseMode("u=rwx,go=rx", initial, umask_val));
    try std.testing.expectEqual(@as(?std.posix.mode_t, 0o700), parseMode("u=rwx,go=", initial, umask_val));
    try std.testing.expectEqual(@as(?std.posix.mode_t, 0o777), parseMode("a=rwx", initial, umask_val));

    // Relative modification with initial (0755)
    // +w without who applies to all except umask (0755 | (0222 & ~022) = 0755 | 0200 = 0755)
    try std.testing.expectEqual(initial, parseMode("+w", initial, umask_val).?);

    // a+w explicitly adds write for all classes (0755 | 0222 = 0777)
    try std.testing.expectEqual(@as(?std.posix.mode_t, 0o777), parseMode("a+w", initial, umask_val));

    // go-w removes write from group and other (0777 -> 0755)
    try std.testing.expectEqual(@as(?std.posix.mode_t, 0o755), parseMode("a=rwx,go-w", 0o777, umask_val));
}
