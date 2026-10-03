//! POSIX.1-2024 Regular Expression & Pattern Matching Engine
//!
//! Provides:
//! 1. High-throughput Fixed String Matching (`-F`) with case-insensitive ASCII optimization.
//! 2. Bytecode-based Thompson NFA (Pike VM) for Basic (BRE) and Extended (ERE) Regular Expressions:
//!    - Guarantees O(P * N) linear time matching (ReDoS immune).
//!    - Zero dynamic allocations during matching (uses pre-allocated thread and bitset buffers).
//!    - 256-bit character class bitsets for O(1) bracket expression testing.
//!    - POSIX character classes: [:alnum:], [:alpha:], [:blank:], [:cntrl:], [:digit:],
//!      [:graph:], [:lower:], [:print:], [:punct:], [:space:], [:upper:], [:xdigit:].
//!    - Quantifiers: '*', '+', '?', and interval repetition '{m,n}'.
//!    - Alternation and subexpression grouping.
//! 3. AST recursive matcher fallback for BRE patterns with backreferences (`\1`..`\9`).

const std = @import("std");

pub const Mode = enum {
    bre,
    ere,
    fixed,
};

/// 256-bit set representing all possible single-byte characters.
pub const CharSet = struct {
    bits: [4]u64 = [_]u64{ 0, 0, 0, 0 },

    pub fn initEmpty() CharSet {
        return .{};
    }

    pub fn set(self: *CharSet, c: u8) void {
        const idx = c / 64;
        const shift: u6 = @truncate(c % 64);
        self.bits[idx] |= (@as(u64, 1) << shift);
    }

    pub fn isSet(self: CharSet, c: u8) bool {
        const idx = c / 64;
        const shift: u6 = @truncate(c % 64);
        return (self.bits[idx] & (@as(u64, 1) << shift)) != 0;
    }

    pub fn invert(self: *CharSet) void {
        for (&self.bits) |*w| {
            w.* = ~w.*;
        }
    }

    pub fn addRange(self: *CharSet, start: u8, end: u8) void {
        var c = start;
        while (c <= end) {
            self.set(c);
            if (c == 255) break;
            c += 1;
        }
    }

    pub fn applyCaseFold(self: *CharSet) void {
        var c: u8 = 'a';
        while (c <= 'z') : (c += 1) {
            if (self.isSet(c)) {
                self.set(std.ascii.toUpper(c));
            }
        }
        c = 'A';
        while (c <= 'Z') : (c += 1) {
            if (self.isSet(c)) {
                self.set(std.ascii.toLower(c));
            }
        }
    }
};

/// VM instructions for the linear-time Pike VM.
pub const Op = union(enum) {
    match,
    byte: u8,
    byte_ci: u8,
    any, // Matches any byte except '\n' and '\0'
    class: CharSet,
    split: struct { target1: u16, target2: u16 },
    jump: u16,
    assert_start, // '^'
    assert_end,   // '$'
};

pub const ParseError = error{
    InvalidRegularExpression,
    TrailingBackslash,
    UnmatchedParenthesis,
    UnmatchedBracket,
    UnmatchedBrace,
    InvalidInterval,
    InvalidRange,
    InvalidCharacterClass,
    OutOfMemory,
    PatternTooComplex,
};

/// AST node for AST-based matching (used for BRE backreferences).
pub const AstNode = struct {
    kind: Kind,

    pub const Kind = union(enum) {
        literal: u8,
        literal_ci: u8,
        any,
        class: CharSet,
        seq: []const AstNode,
        alt: []const AstNode,
        star: *const AstNode,
        plus: *const AstNode,
        opt: *const AstNode,
        repeat: struct { child: *const AstNode, min: u8, max: ?u8 },
        group: struct { id: u8, child: *const AstNode },
        backref: u8,
        anchor_start,
        anchor_end,
    };
};

pub const Regex = struct {
    mode: Mode,
    pattern: []const u8,
    case_insensitive: bool,
    whole_line: bool,

    // Fixed string mode needle
    fixed_needle: []const u8 = "",

    // Pike VM bytecode instructions
    ops: []const Op = &.{},
    is_anchored_start: bool = false,
    is_anchored_end: bool = false,

    // Pre-allocated buffers for zero-allocation matching
    thread_curr: []u16 = &.{},
    thread_next: []u16 = &.{},
    visited_curr: []u64 = &.{},
    visited_next: []u64 = &.{},

    // Backreference AST fallback
    ast_root: ?AstNode = null,
    has_backref: bool = false,
    arena: ?std.heap.ArenaAllocator = null,

    pub fn compile(
        allocator: std.mem.Allocator,
        pattern: []const u8,
        mode: Mode,
        case_insensitive: bool,
        whole_line: bool,
    ) ParseError!Regex {
        if (mode == .fixed) {
            return Regex{
                .mode = .fixed,
                .pattern = pattern,
                .case_insensitive = case_insensitive,
                .whole_line = whole_line,
                .fixed_needle = pattern,
            };
        }

        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const arena_allocator = arena.allocator();

        var parser = Parser{
            .pattern = pattern,
            .mode = mode,
            .case_insensitive = case_insensitive,
            .whole_line = whole_line,
            .allocator = arena_allocator,
        };

        const ast = try parser.parse();

        if (parser.has_backref) {
            return Regex{
                .mode = mode,
                .pattern = pattern,
                .case_insensitive = case_insensitive,
                .whole_line = whole_line,
                .ast_root = ast,
                .has_backref = true,
                .is_anchored_start = parser.is_anchored_start or whole_line,
                .is_anchored_end = parser.is_anchored_end or whole_line,
                .arena = arena,
            };
        }

        // Compile AST into Pike VM bytecode
        var compiler = Compiler{
            .allocator = arena_allocator,
            .ops = .empty,
        };

        if (whole_line) {
            try compiler.ops.append(arena_allocator, .assert_start);
        }

        try compiler.compileNode(ast);

        if (whole_line) {
            try compiler.ops.append(arena_allocator, .assert_end);
        }

        try compiler.ops.append(arena_allocator, .match);

        const ops_slice = try allocator.dupe(Op, compiler.ops.items);
        errdefer allocator.free(ops_slice);

        const max_insts = ops_slice.len;
        if (max_insts > 65530) return ParseError.PatternTooComplex;

        // Allocate thread lists and visited bitsets
        const thread_curr = try allocator.alloc(u16, max_insts);
        errdefer allocator.free(thread_curr);

        const thread_next = try allocator.alloc(u16, max_insts);
        errdefer allocator.free(thread_next);

        const bitset_words = (max_insts + 63) / 64;
        const visited_curr = try allocator.alloc(u64, bitset_words);
        errdefer allocator.free(visited_curr);

        const visited_next = try allocator.alloc(u64, bitset_words);
        errdefer allocator.free(visited_next);

        // AST is no longer needed when using Pike VM
        arena.deinit();

        return Regex{
            .mode = mode,
            .pattern = pattern,
            .case_insensitive = case_insensitive,
            .whole_line = whole_line,
            .ops = ops_slice,
            .is_anchored_start = parser.is_anchored_start or whole_line,
            .is_anchored_end = parser.is_anchored_end or whole_line,
            .thread_curr = thread_curr,
            .thread_next = thread_next,
            .visited_curr = visited_curr,
            .visited_next = visited_next,
            .has_backref = false,
        };
    }

    pub fn deinit(self: *Regex, allocator: std.mem.Allocator) void {
        if (self.arena) |*arena| {
            arena.deinit();
            self.arena = null;
        }
        if (self.ops.len > 0) {
            allocator.free(self.ops);
            self.ops = &.{};
        }
        if (self.thread_curr.len > 0) {
            allocator.free(self.thread_curr);
            self.thread_curr = &.{};
        }
        if (self.thread_next.len > 0) {
            allocator.free(self.thread_next);
            self.thread_next = &.{};
        }
        if (self.visited_curr.len > 0) {
            allocator.free(self.visited_curr);
            self.visited_curr = &.{};
        }
        if (self.visited_next.len > 0) {
            allocator.free(self.visited_next);
            self.visited_next = &.{};
        }
    }

    /// Matches `line` against the compiled pattern.
    /// Guaranteed zero dynamic heap allocations during execution.
    pub fn matches(self: *const Regex, line: []const u8) bool {
        if (self.mode == .fixed) {
            return self.matchesFixed(line);
        }

        if (self.has_backref) {
            return self.matchesAst(line);
        }

        return self.matchesVm(line);
    }

    fn matchesFixed(self: *const Regex, line: []const u8) bool {
        const needle = self.fixed_needle;
        if (needle.len == 0) {
            if (self.whole_line) {
                return line.len == 0;
            }
            return true;
        }

        if (self.whole_line) {
            if (line.len != needle.len) return false;
            if (self.case_insensitive) {
                return std.ascii.eqlIgnoreCase(line, needle);
            }
            return std.mem.eql(u8, line, needle);
        }

        if (self.case_insensitive) {
            return std.ascii.indexOfIgnoreCase(line, needle) != null;
        }
        return std.mem.indexOf(u8, line, needle) != null;
    }

    fn matchesVm(self: *const Regex, line: []const u8) bool {
        const ops = self.ops;
        if (ops.len == 0) return true;

        var curr_len: usize = 0;
        var next_len: usize = 0;

        @memset(self.visited_curr, 0);
        @memset(self.visited_next, 0);

        // Helper to add thread with epsilon closure
        const add_thread = struct {
            fn run(
                insts: []const Op,
                pc: u16,
                pos: usize,
                total_len: usize,
                visited: []u64,
                threads: []u16,
                t_len: *usize,
            ) bool {
                const word_idx = pc / 64;
                const bit_mask = @as(u64, 1) << @as(u6, @truncate(pc % 64));
                if ((visited[word_idx] & bit_mask) != 0) return false;
                visited[word_idx] |= bit_mask;

                switch (insts[pc]) {
                    .match => return true,
                    .split => |s| {
                        if (run(insts, s.target1, pos, total_len, visited, threads, t_len)) return true;
                        return run(insts, s.target2, pos, total_len, visited, threads, t_len);
                    },
                    .jump => |target| {
                        return run(insts, target, pos, total_len, visited, threads, t_len);
                    },
                    .assert_start => {
                        if (pos == 0) {
                            return run(insts, pc + 1, pos, total_len, visited, threads, t_len);
                        }
                        return false;
                    },
                    .assert_end => {
                        if (pos == total_len) {
                            return run(insts, pc + 1, pos, total_len, visited, threads, t_len);
                        }
                        return false;
                    },
                    .byte, .byte_ci, .any, .class => {
                        threads[t_len.*] = pc;
                        t_len.* += 1;
                        return false;
                    },
                }
            }
        }.run;

        // Position 0 setup
        if (add_thread(ops, 0, 0, line.len, self.visited_curr, self.thread_curr, &curr_len)) {
            return true;
        }

        var pos: usize = 0;
        while (pos <= line.len) {
            if (pos > 0 and !self.is_anchored_start) {
                // For unanchored searches, inject start thread at current position
                if (add_thread(ops, 0, pos, line.len, self.visited_curr, self.thread_curr, &curr_len)) {
                    return true;
                }
            }

            if (pos == line.len) break;

            const b = line[pos];
            next_len = 0;
            @memset(self.visited_next, 0);

            for (self.thread_curr[0..curr_len]) |pc| {
                const matched = switch (ops[pc]) {
                    .byte => |c| b == c,
                    .byte_ci => |c| std.ascii.toLower(b) == c,
                    .any => b != '\n' and b != 0,
                    .class => |cs| cs.isSet(b),
                    else => false,
                };

                if (matched) {
                    if (add_thread(ops, pc + 1, pos + 1, line.len, self.visited_next, self.thread_next, &next_len)) {
                        return true;
                    }
                }
            }

            // Copy next threads into curr
            @memcpy(self.thread_curr[0..next_len], self.thread_next[0..next_len]);
            curr_len = next_len;
            @memcpy(self.visited_curr, self.visited_next);

            pos += 1;
        }

        return false;
    }

    fn matchesAst(self: *const Regex, line: []const u8) bool {
        const root = self.ast_root orelse return false;
        var captures: [10]?[2]usize = [_]?[2]usize{null} ** 10;

        if (self.is_anchored_start) {
            return matchAstNode(root, line, 0, &captures, self.whole_line or self.is_anchored_end) != null;
        }

        var start: usize = 0;
        while (start <= line.len) : (start += 1) {
            @memset(&captures, null);
            if (matchAstNode(root, line, start, &captures, self.whole_line or self.is_anchored_end) != null) {
                return true;
            }
        }
        return false;
    }
};

fn matchAstNode(
    node: AstNode,
    line: []const u8,
    pos: usize,
    captures: *[10]?[2]usize,
    must_reach_end: bool,
) ?usize {
    switch (node.kind) {
        .literal => |c| {
            if (pos < line.len and line[pos] == c) {
                return if (!must_reach_end or pos + 1 == line.len) pos + 1 else null;
            }
            return null;
        },
        .literal_ci => |c| {
            if (pos < line.len and std.ascii.toLower(line[pos]) == c) {
                return if (!must_reach_end or pos + 1 == line.len) pos + 1 else null;
            }
            return null;
        },
        .any => {
            if (pos < line.len and line[pos] != '\n' and line[pos] != 0) {
                return if (!must_reach_end or pos + 1 == line.len) pos + 1 else null;
            }
            return null;
        },
        .class => |cs| {
            if (pos < line.len and cs.isSet(line[pos])) {
                return if (!must_reach_end or pos + 1 == line.len) pos + 1 else null;
            }
            return null;
        },
        .anchor_start => {
            if (pos == 0) return 0;
            return null;
        },
        .anchor_end => {
            if (pos == line.len) return pos;
            return null;
        },
        .group => |g| {
            const start = pos;
            if (matchAstNode(g.child.*, line, pos, captures, false)) |end| {
                if (g.id < 10) captures[g.id] = .{ start, end };
                if (must_reach_end and end != line.len) return null;
                return end;
            }
            return null;
        },
        .backref => |id| {
            if (id >= 10) return null;
            const span = captures[id] orelse return null;
            const ref_str = line[span[0]..span[1]];
            if (pos + ref_str.len <= line.len and std.mem.eql(u8, line[pos .. pos + ref_str.len], ref_str)) {
                const end = pos + ref_str.len;
                if (must_reach_end and end != line.len) return null;
                return end;
            }
            return null;
        },
        .seq => |items| {
            var cur = pos;
            for (items, 0..) |item, idx| {
                const is_last = (idx + 1 == items.len);
                if (matchAstNode(item, line, cur, captures, is_last and must_reach_end)) |next_pos| {
                    cur = next_pos;
                } else {
                    return null;
                }
            }
            return cur;
        },
        .alt => |branches| {
            for (branches) |b| {
                if (matchAstNode(b, line, pos, captures, must_reach_end)) |res| {
                    return res;
                }
            }
            return null;
        },
        .opt => |child| {
            if (matchAstNode(child.*, line, pos, captures, must_reach_end)) |res| {
                return res;
            }
            if (!must_reach_end or pos == line.len) return pos;
            return null;
        },
        .star => |child| {
            var cur = pos;
            while (true) {
                if (matchAstNode(child.*, line, cur, captures, false)) |next_pos| {
                    if (next_pos == cur) break; // Avoid infinite loop on empty match
                    cur = next_pos;
                } else {
                    break;
                }
            }
            if (!must_reach_end or cur == line.len) return cur;
            return null;
        },
        .plus => |child| {
            const first = matchAstNode(child.*, line, pos, captures, false) orelse return null;
            var cur = first;
            while (true) {
                if (matchAstNode(child.*, line, cur, captures, false)) |next_pos| {
                    if (next_pos == cur) break;
                    cur = next_pos;
                } else {
                    break;
                }
            }
            if (!must_reach_end or cur == line.len) return cur;
            return null;
        },
        .repeat => |r| {
            var count: u8 = 0;
            var cur = pos;
            while (count < r.min) : (count += 1) {
                cur = matchAstNode(r.child.*, line, cur, captures, false) orelse return null;
            }
            if (r.max) |max_val| {
                while (count < max_val) : (count += 1) {
                    if (matchAstNode(r.child.*, line, cur, captures, false)) |next_pos| {
                        if (next_pos == cur) break;
                        cur = next_pos;
                    } else break;
                }
            } else {
                while (true) {
                    if (matchAstNode(r.child.*, line, cur, captures, false)) |next_pos| {
                        if (next_pos == cur) break;
                        cur = next_pos;
                    } else break;
                }
            }
            if (!must_reach_end or cur == line.len) return cur;
            return null;
        },
    }
}

// ============================================================================
// Parser
// ============================================================================

const Parser = struct {
    pattern: []const u8,
    mode: Mode,
    case_insensitive: bool,
    whole_line: bool,
    allocator: std.mem.Allocator,

    cursor: usize = 0,
    group_counter: u8 = 0,
    has_backref: bool = false,
    is_anchored_start: bool = false,
    is_anchored_end: bool = false,

    fn parse(self: *Parser) ParseError!AstNode {
        var branches: std.ArrayList(AstNode) = .empty;

        while (true) {
            const branch = try self.parseBranch();
            try branches.append(self.allocator, branch);

            if (self.mode == .ere and self.peek() == '|') {
                _ = self.next();
                continue;
            } else if (self.mode == .bre and self.matchSeq("\\|")) {
                continue;
            }
            break;
        }

        if (self.cursor < self.pattern.len) {
            return ParseError.InvalidRegularExpression;
        }

        if (branches.items.len == 1) {
            return branches.items[0];
        }
        return AstNode{ .kind = .{ .alt = try branches.toOwnedSlice(self.allocator) } };
    }

    fn parseBranch(self: *Parser) ParseError!AstNode {
        var seq: std.ArrayList(AstNode) = .empty;

        while (self.cursor < self.pattern.len) {
            if (self.mode == .ere and (self.peek() == '|' or self.peek() == ')')) break;
            if (self.mode == .bre and (self.matchSeqPreview("\\|") or self.matchSeqPreview("\\)"))) break;

            const piece = try self.parsePiece();
            try seq.append(self.allocator, piece);
        }

        if (seq.items.len == 1) {
            return seq.items[0];
        }
        return AstNode{ .kind = .{ .seq = try seq.toOwnedSlice(self.allocator) } };
    }

    fn parsePiece(self: *Parser) ParseError!AstNode {
        const atom = try self.parseAtom();

        if (self.mode == .ere) {
            if (self.peek() == '*') {
                _ = self.next();
                const node_ptr = try self.allocNode(atom);
                return AstNode{ .kind = .{ .star = node_ptr } };
            } else if (self.peek() == '+') {
                _ = self.next();
                const node_ptr = try self.allocNode(atom);
                return AstNode{ .kind = .{ .plus = node_ptr } };
            } else if (self.peek() == '?') {
                _ = self.next();
                const node_ptr = try self.allocNode(atom);
                return AstNode{ .kind = .{ .opt = node_ptr } };
            } else if (self.peek() == '{') {
                return self.parseInterval(atom);
            }
        } else {
            // BRE quantifiers
            if (self.peek() == '*') {
                _ = self.next();
                const node_ptr = try self.allocNode(atom);
                return AstNode{ .kind = .{ .star = node_ptr } };
            } else if (self.matchSeq("\\+")) {
                const node_ptr = try self.allocNode(atom);
                return AstNode{ .kind = .{ .plus = node_ptr } };
            } else if (self.matchSeq("\\?")) {
                const node_ptr = try self.allocNode(atom);
                return AstNode{ .kind = .{ .opt = node_ptr } };
            } else if (self.matchSeqPreview("\\{")) {
                return self.parseInterval(atom);
            }
        }

        return atom;
    }

    fn parseAtom(self: *Parser) ParseError!AstNode {
        const c = self.peek() orelse return ParseError.InvalidRegularExpression;

        if (c == '^') {
            const is_start = (self.cursor == 0);
            _ = self.next();
            if (self.mode == .bre and !is_start) {
                // In BRE, '^' is only an anchor at start of pattern
                return self.makeLiteral('^');
            }
            if (is_start) self.is_anchored_start = true;
            return AstNode{ .kind = .anchor_start };
        }

        if (c == '$') {
            const is_end = (self.cursor + 1 == self.pattern.len);
            _ = self.next();
            if (self.mode == .bre and !is_end) {
                // In BRE, '$' is only an anchor at end of pattern
                return self.makeLiteral('$');
            }
            if (is_end) self.is_anchored_end = true;
            return AstNode{ .kind = .anchor_end };
        }

        if (c == '.') {
            _ = self.next();
            return AstNode{ .kind = .any };
        }

        if (c == '[') {
            return self.parseBracket();
        }

        if (self.mode == .ere and c == '(') {
            _ = self.next();
            self.group_counter += 1;
            const grp_id = self.group_counter;
            const inner = try self.parseSubExpr(')');
            if (self.peek() != ')') return ParseError.UnmatchedParenthesis;
            _ = self.next();

            const node_ptr = try self.allocNode(inner);
            return AstNode{ .kind = .{ .group = .{ .id = grp_id, .child = node_ptr } } };
        }

        if (self.mode == .bre and self.matchSeq("\\(")) {
            self.group_counter += 1;
            const grp_id = self.group_counter;
            const inner = try self.parseSubExpr(0); // delimiter is "\\)"
            if (!self.matchSeq("\\)")) return ParseError.UnmatchedParenthesis;

            const node_ptr = try self.allocNode(inner);
            return AstNode{ .kind = .{ .group = .{ .id = grp_id, .child = node_ptr } } };
        }

        if (c == '\\') {
            _ = self.next();
            const escaped = self.next() orelse return ParseError.TrailingBackslash;

            if (self.mode == .bre and escaped >= '1' and escaped <= '9') {
                self.has_backref = true;
                return AstNode{ .kind = .{ .backref = escaped - '0' } };
            }

            return self.makeLiteral(escaped);
        }

        _ = self.next();
        return self.makeLiteral(c);
    }

    fn parseSubExpr(self: *Parser, term_char: u8) ParseError!AstNode {
        var branches: std.ArrayList(AstNode) = .empty;

        while (true) {
            const branch = try self.parseBranch();
            try branches.append(self.allocator, branch);

            if (term_char != 0 and self.peek() == term_char) break;
            if (term_char == 0 and self.matchSeqPreview("\\)")) break;

            if (self.mode == .ere and self.peek() == '|') {
                _ = self.next();
                continue;
            } else if (self.mode == .bre and self.matchSeq("\\|")) {
                continue;
            }
            break;
        }

        if (branches.items.len == 1) {
            return branches.items[0];
        }
        return AstNode{ .kind = .{ .alt = try branches.toOwnedSlice(self.allocator) } };
    }

    fn parseBracket(self: *Parser) ParseError!AstNode {
        // Skip '['
        _ = self.next();
        var set = CharSet.initEmpty();

        var invert = false;
        if (self.peek() == '^') {
            invert = true;
            _ = self.next();
        }

        // Special POSIX rule: ']' as first character after '[' or '[^' is literal ']'
        if (self.peek() == ']') {
            set.set(']');
            _ = self.next();
        }

        // Special POSIX rule: '-' as first character after '[' or '[^' is literal '-'
        if (self.peek() == '-') {
            set.set('-');
            _ = self.next();
        }

        while (self.cursor < self.pattern.len) {
            const cur = self.peek().?;
            if (cur == ']') {
                _ = self.next();
                if (self.case_insensitive) set.applyCaseFold();
                if (invert) set.invert();
                return AstNode{ .kind = .{ .class = set } };
            }

            // POSIX character classes: [:class:]
            if (self.matchSeqPreview("[:")) {
                const cls_end = std.mem.indexOf(u8, self.pattern[self.cursor..], ":]") orelse return ParseError.InvalidCharacterClass;
                const cls_name = self.pattern[self.cursor + 2 .. self.cursor + cls_end];
                self.cursor += cls_end + 2;

                try addNamedCharClass(&set, cls_name);
                continue;
            }

            // Range: a-z
            if (self.cursor + 2 < self.pattern.len and self.pattern[self.cursor + 1] == '-' and self.pattern[self.cursor + 2] != ']') {
                const start = self.pattern[self.cursor];
                const end = self.pattern[self.cursor + 2];
                if (start > end) return ParseError.InvalidRange;
                set.addRange(start, end);
                self.cursor += 3;
                continue;
            }

            set.set(cur);
            _ = self.next();
        }

        return ParseError.UnmatchedBracket;
    }

    fn parseInterval(self: *Parser, child: AstNode) ParseError!AstNode {
        if (self.mode == .bre) {
            if (!self.matchSeq("\\{")) return ParseError.InvalidInterval;
        } else {
            if (self.next() != '{') return ParseError.InvalidInterval;
        }

        const start_idx = self.cursor;
        const close_delim = if (self.mode == .bre) "\\}" else "}";
        const close_idx = std.mem.indexOf(u8, self.pattern[start_idx..], close_delim) orelse return ParseError.UnmatchedBrace;

        const content = self.pattern[start_idx .. start_idx + close_idx];
        self.cursor = start_idx + close_idx + close_delim.len;

        var min: u8 = 0;
        var max: ?u8 = null;

        if (std.mem.indexOfScalar(u8, content, ',')) |comma_idx| {
            const min_str = content[0..comma_idx];
            const max_str = content[comma_idx + 1 ..];

            min = std.fmt.parseInt(u8, min_str, 10) catch return ParseError.InvalidInterval;
            if (max_str.len > 0) {
                const max_val = std.fmt.parseInt(u8, max_str, 10) catch return ParseError.InvalidInterval;
                if (min > max_val) return ParseError.InvalidInterval;
                max = max_val;
            } else {
                max = null; // {m,}
            }
        } else {
            min = std.fmt.parseInt(u8, content, 10) catch return ParseError.InvalidInterval;
            max = min; // {m}
        }

        const node_ptr = try self.allocNode(child);
        return AstNode{ .kind = .{ .repeat = .{ .child = node_ptr, .min = min, .max = max } } };
    }

    fn makeLiteral(self: *const Parser, c: u8) AstNode {
        if (self.case_insensitive) {
            return AstNode{ .kind = .{ .literal_ci = std.ascii.toLower(c) } };
        }
        return AstNode{ .kind = .{ .literal = c } };
    }

    fn allocNode(self: *Parser, node: AstNode) ParseError!*const AstNode {
        const ptr = try self.allocator.create(AstNode);
        ptr.* = node;
        return ptr;
    }

    fn peek(self: *const Parser) ?u8 {
        if (self.cursor >= self.pattern.len) return null;
        return self.pattern[self.cursor];
    }

    fn next(self: *Parser) ?u8 {
        if (self.cursor >= self.pattern.len) return null;
        const c = self.pattern[self.cursor];
        self.cursor += 1;
        return c;
    }

    fn matchSeq(self: *Parser, seq: []const u8) bool {
        if (self.matchSeqPreview(seq)) {
            self.cursor += seq.len;
            return true;
        }
        return false;
    }

    fn matchSeqPreview(self: *const Parser, seq: []const u8) bool {
        if (self.cursor + seq.len <= self.pattern.len) {
            return std.mem.eql(u8, self.pattern[self.cursor .. self.cursor + seq.len], seq);
        }
        return false;
    }
};

fn addNamedCharClass(set: *CharSet, name: []const u8) ParseError!void {
    if (std.mem.eql(u8, name, "alnum")) {
        set.addRange('0', '9');
        set.addRange('a', 'z');
        set.addRange('A', 'Z');
    } else if (std.mem.eql(u8, name, "alpha")) {
        set.addRange('a', 'z');
        set.addRange('A', 'Z');
    } else if (std.mem.eql(u8, name, "blank")) {
        set.set(' ');
        set.set('\t');
    } else if (std.mem.eql(u8, name, "cntrl")) {
        set.addRange(0, 31);
        set.set(127);
    } else if (std.mem.eql(u8, name, "digit")) {
        set.addRange('0', '9');
    } else if (std.mem.eql(u8, name, "graph")) {
        set.addRange(33, 126);
    } else if (std.mem.eql(u8, name, "lower")) {
        set.addRange('a', 'z');
    } else if (std.mem.eql(u8, name, "print")) {
        set.addRange(32, 126);
    } else if (std.mem.eql(u8, name, "punct")) {
        var c: u8 = 0;
        while (c < 128) : (c += 1) {
            if (std.ascii.isPunctuation(c)) set.set(c);
        }
    } else if (std.mem.eql(u8, name, "space")) {
        set.set(' ');
        set.set('\t');
        set.set('\n');
        set.set('\r');
        set.set(0x0B); // \v
        set.set(0x0C); // \f
    } else if (std.mem.eql(u8, name, "upper")) {
        set.addRange('A', 'Z');
    } else if (std.mem.eql(u8, name, "xdigit")) {
        set.addRange('0', '9');
        set.addRange('a', 'f');
        set.addRange('A', 'F');
    } else {
        return ParseError.InvalidCharacterClass;
    }
}

// ============================================================================
// Bytecode Compiler
// ============================================================================

const Compiler = struct {
    allocator: std.mem.Allocator,
    ops: std.ArrayList(Op),

    fn compileNode(self: *Compiler, node: AstNode) ParseError!void {
        switch (node.kind) {
            .literal => |c| {
                try self.ops.append(self.allocator, .{ .byte = c });
            },
            .literal_ci => |c| {
                try self.ops.append(self.allocator, .{ .byte_ci = c });
            },
            .any => {
                try self.ops.append(self.allocator, .any);
            },
            .class => |cs| {
                try self.ops.append(self.allocator, .{ .class = cs });
            },
            .anchor_start => {
                try self.ops.append(self.allocator, .assert_start);
            },
            .anchor_end => {
                try self.ops.append(self.allocator, .assert_end);
            },
            .group => |g| {
                try self.compileNode(g.child.*);
            },
            .backref => {
                // Handled in AST mode
                return ParseError.InvalidRegularExpression;
            },
            .seq => |items| {
                for (items) |item| {
                    try self.compileNode(item);
                }
            },
            .alt => |branches| {
                if (branches.len == 0) return;
                if (branches.len == 1) {
                    try self.compileNode(branches[0]);
                    return;
                }

                // Chain alternations
                var jumps: std.ArrayList(usize) = .empty;
                defer jumps.deinit(self.allocator);

                for (branches, 0..) |branch, idx| {
                    const is_last = (idx + 1 == branches.len);
                    if (!is_last) {
                        const split_idx = self.ops.items.len;
                        try self.ops.append(self.allocator, .{ .split = .{ .target1 = @as(u16, @intCast(split_idx + 1)), .target2 = 0 } });
                        try self.compileNode(branch);

                        const jump_idx = self.ops.items.len;
                        try self.ops.append(self.allocator, .{ .jump = 0 });
                        try jumps.append(self.allocator, jump_idx);

                        self.ops.items[split_idx].split.target2 = @as(u16, @intCast(self.ops.items.len));
                    } else {
                        try self.compileNode(branch);
                    }
                }

                const end_target = @as(u16, @intCast(self.ops.items.len));
                for (jumps.items) |j_idx| {
                    self.ops.items[j_idx].jump = end_target;
                }
            },
            .star => |child| {
                const split_idx = self.ops.items.len;
                try self.ops.append(self.allocator, .{ .split = .{ .target1 = @as(u16, @intCast(split_idx + 1)), .target2 = 0 } });
                try self.compileNode(child.*);
                try self.ops.append(self.allocator, .{ .jump = @as(u16, @intCast(split_idx)) });
                self.ops.items[split_idx].split.target2 = @as(u16, @intCast(self.ops.items.len));
            },
            .plus => |child| {
                const start_idx = self.ops.items.len;
                try self.compileNode(child.*);
                try self.ops.append(self.allocator, .{ .split = .{ .target1 = @as(u16, @intCast(start_idx)), .target2 = @as(u16, @intCast(self.ops.items.len + 1)) } });
            },
            .opt => |child| {
                const split_idx = self.ops.items.len;
                try self.ops.append(self.allocator, .{ .split = .{ .target1 = @as(u16, @intCast(split_idx + 1)), .target2 = 0 } });
                try self.compileNode(child.*);
                self.ops.items[split_idx].split.target2 = @as(u16, @intCast(self.ops.items.len));
            },
            .repeat => |r| {
                var count: u8 = 0;
                while (count < r.min) : (count += 1) {
                    try self.compileNode(r.child.*);
                }

                if (r.max) |max_val| {
                    var remaining = max_val - r.min;
                    while (remaining > 0) : (remaining -= 1) {
                        const split_idx = self.ops.items.len;
                        try self.ops.append(self.allocator, .{ .split = .{ .target1 = @as(u16, @intCast(split_idx + 1)), .target2 = 0 } });
                        try self.compileNode(r.child.*);
                        self.ops.items[split_idx].split.target2 = @as(u16, @intCast(self.ops.items.len));
                    }
                } else {
                    // {min,} is min times followed by child*
                    const split_idx = self.ops.items.len;
                    try self.ops.append(self.allocator, .{ .split = .{ .target1 = @as(u16, @intCast(split_idx + 1)), .target2 = 0 } });
                    try self.compileNode(r.child.*);
                    try self.ops.append(self.allocator, .{ .jump = @as(u16, @intCast(split_idx)) });
                    self.ops.items[split_idx].split.target2 = @as(u16, @intCast(self.ops.items.len));
                }
            },
        }
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

test "regex: fixed string matching" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "hello", .fixed, false, false);
    defer re.deinit(allocator);

    try std.testing.expect(re.matches("hello world"));
    try std.testing.expect(re.matches("say hello"));
    try std.testing.expect(!re.matches("Hello World"));
    try std.testing.expect(!re.matches("goodbye"));

    // Case-insensitive
    var re_ci = try Regex.compile(allocator, "hello", .fixed, true, false);
    defer re_ci.deinit(allocator);
    try std.testing.expect(re_ci.matches("HELLO world"));

    // Whole line (-x)
    var re_x = try Regex.compile(allocator, "hello", .fixed, false, true);
    defer re_x.deinit(allocator);
    try std.testing.expect(re_x.matches("hello"));
    try std.testing.expect(!re_x.matches("hello world"));
}

test "regex: character classes and brackets" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "[a-z0-9_]+", .ere, false, true);
    defer re.deinit(allocator);

    try std.testing.expect(re.matches("hello_123"));
    try std.testing.expect(!re.matches("Hello_123"));
    try std.testing.expect(!re.matches("hello-123"));

    // Inverted bracket
    var re_inv = try Regex.compile(allocator, "[^0-9]+", .ere, false, true);
    defer re_inv.deinit(allocator);
    try std.testing.expect(re_inv.matches("abc"));
    try std.testing.expect(!re_inv.matches("abc1"));

    // POSIX character classes
    var re_posix = try Regex.compile(allocator, "^[[:alpha:]]+$", .ere, false, false);
    defer re_posix.deinit(allocator);
    try std.testing.expect(re_posix.matches("AlphaBeta"));
    try std.testing.expect(!re_posix.matches("Alpha123"));
}

test "regex: quantifiers and alternation" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "^(cat|dog|bird)$", .ere, false, false);
    defer re.deinit(allocator);

    try std.testing.expect(re.matches("cat"));
    try std.testing.expect(re.matches("dog"));
    try std.testing.expect(re.matches("bird"));
    try std.testing.expect(!re.matches("fish"));

    // Intervals {m,n}
    var re_int = try Regex.compile(allocator, "^a{2,4}$", .ere, false, false);
    defer re_int.deinit(allocator);
    try std.testing.expect(!re_int.matches("a"));
    try std.testing.expect(re_int.matches("aa"));
    try std.testing.expect(re_int.matches("aaa"));
    try std.testing.expect(re_int.matches("aaaa"));
    try std.testing.expect(!re_int.matches("aaaaa"));
}

test "regex: BRE syntax and backreferences" {
    const allocator = std.testing.allocator;

    // BRE grouping and intervals
    var re_bre = try Regex.compile(allocator, "^\\(ab\\)\\{2\\}$", .bre, false, false);
    defer re_bre.deinit(allocator);
    try std.testing.expect(re_bre.matches("abab"));
    try std.testing.expect(!re_bre.matches("ab"));

    // BRE backreference \1
    var re_backref = try Regex.compile(allocator, "^\\([a-z]*\\)-\\1$", .bre, false, false);
    defer re_backref.deinit(allocator);
    try std.testing.expect(re_backref.matches("foo-foo"));
    try std.testing.expect(re_backref.matches("bar-bar"));
    try std.testing.expect(!re_backref.matches("foo-bar"));
}
