//! POSIX.1-2024 (IEEE Std 1003.1-2024) compliant implementation of `awk`.
//!
//! Specification References:
//! - IEEE Std 1003.1-2024, Shell & Utilities (XCU), Section: `awk`
//!   - SYNOPSIS:
//!       awk [-F sepstring] [-v assignment]... program [argument...]
//!       awk [-F sepstring] -f progfile... [-v assignment]... [argument...]
//!   - OPTIONS:
//!       -F sepstring: Define input field separator (FS).
//!       -v assignment: Assign variable before program execution.
//!       -f progfile: Path to awk program file. Multiple -f concatenate files.
//!   - OPERANDS:
//!       program: Awk program text if -f not specified.
//!       argument: Either file operand or var=val assignment.
//!   - EXIT STATUS:
//!       0: Successful completion.
//!       >0: An error occurred (or explicit exit code).

const std = @import("std");
const common_args = @import("../common/args.zig");
const common_error = @import("../common/error.zig");
const common_regex = @import("../common/regex.zig");

pub const BUFFER_SIZE: usize = 16 * 1024;

pub const Value = struct {
    tag: enum { num, str, uninit },
    num_val: f64 = 0,
    str_val: []const u8 = "",

    pub fn fromNum(n: f64) Value {
        return .{ .tag = .num, .num_val = n };
    }

    pub fn fromStr(s: []const u8) Value {
        return .{ .tag = .str, .str_val = s };
    }

    pub fn uninitVal() Value {
        return .{ .tag = .uninit };
    }

    pub fn asNumber(self: Value) f64 {
        switch (self.tag) {
            .num => return self.num_val,
            .str => {
                const trimmed = std.mem.trim(u8, self.str_val, " \t\r\n");
                return std.fmt.parseFloat(f64, trimmed) catch 0.0;
            },
            .uninit => return 0.0,
        }
    }

    pub fn asString(self: Value, allocator: std.mem.Allocator) []const u8 {
        switch (self.tag) {
            .str => return self.str_val,
            .num => {
                // If it's an integer, print as integer
                if (@floor(self.num_val) == self.num_val and !std.math.isNan(self.num_val) and !std.math.isInf(self.num_val)) {
                    const i = @as(i64, @intFromFloat(self.num_val));
                    return std.fmt.allocPrint(allocator, "{d}", .{i}) catch "0";
                }
                return std.fmt.allocPrint(allocator, "{d}", .{self.num_val}) catch "0";
            },
            .uninit => return "",
        }
    }

    pub fn isTrue(self: Value) bool {
        switch (self.tag) {
            .num => return self.num_val != 0.0 and !std.math.isNan(self.num_val),
            .str => return self.str_val.len > 0,
            .uninit => return false,
        }
    }

    pub fn isNumericString(s: []const u8) bool {
        const trimmed = std.mem.trim(u8, s, " \t\r\n");
        if (trimmed.len == 0) return false;
        _ = std.fmt.parseFloat(f64, trimmed) catch return false;
        return true;
    }
};

pub const TokenType = enum {
    eof,
    newline,
    semicolon,
    comma,
    lparen,
    rparen,
    lbrace,
    rbrace,
    lbracket,
    rbracket,
    dollar,

    // Literals & Identifiers
    number,
    string,
    regex_lit,
    ident,

    // Operators
    plus,
    minus,
    star,
    slash,
    percent,
    caret,
    assign,
    plus_assign,
    minus_assign,
    star_assign,
    slash_assign,
    percent_assign,
    inc,
    dec,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    match,
    not_match,
    and_op,
    or_op,
    not_op,

    // Keywords
    kw_begin,
    kw_end,
    kw_print,
    kw_printf,
    kw_if,
    kw_else,
    kw_while,
    kw_for,
    kw_do,
    kw_in,
    kw_break,
    kw_continue,
    kw_next,
    kw_exit,
    kw_delete,
    kw_function,
};

pub const Token = struct {
    tok_type: TokenType,
    text: []const u8 = "",
    num_val: f64 = 0.0,
};

pub const Lexer = struct {
    input: []const u8,
    cursor: usize = 0,

    pub fn init(input: []const u8) Lexer {
        return .{ .input = input };
    }

    pub fn nextToken(self: *Lexer) Token {
        while (self.cursor < self.input.len) {
            const c = self.input[self.cursor];

            // Whitespace (excluding newline)
            if (c == ' ' or c == '\t' or c == '\r') {
                self.cursor += 1;
                continue;
            }

            // Comments
            if (c == '#') {
                while (self.cursor < self.input.len and self.input[self.cursor] != '\n') {
                    self.cursor += 1;
                }
                continue;
            }

            // Newline
            if (c == '\n') {
                self.cursor += 1;
                return .{ .tok_type = .newline, .text = "\n" };
            }

            // String literal
            if (c == '"') {
                self.cursor += 1;
                const start = self.cursor;
                while (self.cursor < self.input.len and self.input[self.cursor] != '"') {
                    if (self.input[self.cursor] == '\\' and self.cursor + 1 < self.input.len) {
                        self.cursor += 2;
                    } else {
                        self.cursor += 1;
                    }
                }
                const str = self.input[start..self.cursor];
                if (self.cursor < self.input.len and self.input[self.cursor] == '"') {
                    self.cursor += 1;
                }
                return .{ .tok_type = .string, .text = str };
            }

            // Number literal
            if (std.ascii.isDigit(c) or (c == '.' and self.cursor + 1 < self.input.len and std.ascii.isDigit(self.input[self.cursor + 1]))) {
                const start = self.cursor;
                while (self.cursor < self.input.len and (std.ascii.isDigit(self.input[self.cursor]) or self.input[self.cursor] == '.')) {
                    self.cursor += 1;
                }
                const num_slice = self.input[start..self.cursor];
                const val = std.fmt.parseFloat(f64, num_slice) catch 0.0;
                return .{ .tok_type = .number, .text = num_slice, .num_val = val };
            }

            // Identifiers / Keywords
            if (std.ascii.isAlphabetic(c) or c == '_') {
                const start = self.cursor;
                while (self.cursor < self.input.len and (std.ascii.isAlphanumeric(self.input[self.cursor]) or self.input[self.cursor] == '_')) {
                    self.cursor += 1;
                }
                const word = self.input[start..self.cursor];
                if (std.mem.eql(u8, word, "BEGIN")) return .{ .tok_type = .kw_begin, .text = word };
                if (std.mem.eql(u8, word, "END")) return .{ .tok_type = .kw_end, .text = word };
                if (std.mem.eql(u8, word, "print")) return .{ .tok_type = .kw_print, .text = word };
                if (std.mem.eql(u8, word, "printf")) return .{ .tok_type = .kw_printf, .text = word };
                if (std.mem.eql(u8, word, "if")) return .{ .tok_type = .kw_if, .text = word };
                if (std.mem.eql(u8, word, "else")) return .{ .tok_type = .kw_else, .text = word };
                if (std.mem.eql(u8, word, "while")) return .{ .tok_type = .kw_while, .text = word };
                if (std.mem.eql(u8, word, "for")) return .{ .tok_type = .kw_for, .text = word };
                if (std.mem.eql(u8, word, "do")) return .{ .tok_type = .kw_do, .text = word };
                if (std.mem.eql(u8, word, "in")) return .{ .tok_type = .kw_in, .text = word };
                if (std.mem.eql(u8, word, "break")) return .{ .tok_type = .kw_break, .text = word };
                if (std.mem.eql(u8, word, "continue")) return .{ .tok_type = .kw_continue, .text = word };
                if (std.mem.eql(u8, word, "next")) return .{ .tok_type = .kw_next, .text = word };
                if (std.mem.eql(u8, word, "exit")) return .{ .tok_type = .kw_exit, .text = word };
                if (std.mem.eql(u8, word, "delete")) return .{ .tok_type = .kw_delete, .text = word };
                if (std.mem.eql(u8, word, "function")) return .{ .tok_type = .kw_function, .text = word };
                return .{ .tok_type = .ident, .text = word };
            }

            // Multi-char operators
            if (self.cursor + 1 < self.input.len) {
                const two = self.input[self.cursor .. self.cursor + 2];
                if (std.mem.eql(u8, two, "++")) {
                    self.cursor += 2;
                    return .{ .tok_type = .inc, .text = "++" };
                }
                if (std.mem.eql(u8, two, "--")) {
                    self.cursor += 2;
                    return .{ .tok_type = .dec, .text = "--" };
                }
                if (std.mem.eql(u8, two, "+=")) {
                    self.cursor += 2;
                    return .{ .tok_type = .plus_assign, .text = "+=" };
                }
                if (std.mem.eql(u8, two, "-=")) {
                    self.cursor += 2;
                    return .{ .tok_type = .minus_assign, .text = "-=" };
                }
                if (std.mem.eql(u8, two, "*=")) {
                    self.cursor += 2;
                    return .{ .tok_type = .star_assign, .text = "*=" };
                }
                if (std.mem.eql(u8, two, "/=")) {
                    self.cursor += 2;
                    return .{ .tok_type = .slash_assign, .text = "/=" };
                }
                if (std.mem.eql(u8, two, "%=")) {
                    self.cursor += 2;
                    return .{ .tok_type = .percent_assign, .text = "%=" };
                }
                if (std.mem.eql(u8, two, "==")) {
                    self.cursor += 2;
                    return .{ .tok_type = .eq, .text = "==" };
                }
                if (std.mem.eql(u8, two, "!=")) {
                    self.cursor += 2;
                    return .{ .tok_type = .ne, .text = "!=" };
                }
                if (std.mem.eql(u8, two, "<=")) {
                    self.cursor += 2;
                    return .{ .tok_type = .le, .text = "<=" };
                }
                if (std.mem.eql(u8, two, ">=")) {
                    self.cursor += 2;
                    return .{ .tok_type = .ge, .text = ">=" };
                }
                if (std.mem.eql(u8, two, "!~")) {
                    self.cursor += 2;
                    return .{ .tok_type = .not_match, .text = "!~" };
                }
                if (std.mem.eql(u8, two, "&&")) {
                    self.cursor += 2;
                    return .{ .tok_type = .and_op, .text = "&&" };
                }
                if (std.mem.eql(u8, two, "||")) {
                    self.cursor += 2;
                    return .{ .tok_type = .or_op, .text = "||" };
                }
            }

            // Single char punctuation / operators
            self.cursor += 1;
            switch (c) {
                ';' => return .{ .tok_type = .semicolon, .text = ";" },
                ',' => return .{ .tok_type = .comma, .text = "," },
                '(' => return .{ .tok_type = .lparen, .text = "(" },
                ')' => return .{ .tok_type = .rparen, .text = ")" },
                '{' => return .{ .tok_type = .lbrace, .text = "{" },
                '}' => return .{ .tok_type = .rbrace, .text = "}" },
                '[' => return .{ .tok_type = .lbracket, .text = "[" },
                ']' => return .{ .tok_type = .rbracket, .text = "]" },
                '$' => return .{ .tok_type = .dollar, .text = "$" },
                '+' => return .{ .tok_type = .plus, .text = "+" },
                '-' => return .{ .tok_type = .minus, .text = "-" },
                '*' => return .{ .tok_type = .star, .text = "*" },
                '/' => return .{ .tok_type = .slash, .text = "/" },
                '%' => return .{ .tok_type = .percent, .text = "%" },
                '^' => return .{ .tok_type = .caret, .text = "^" },
                '=' => return .{ .tok_type = .assign, .text = "=" },
                '<' => return .{ .tok_type = .lt, .text = "<" },
                '>' => return .{ .tok_type = .gt, .text = ">" },
                '~' => return .{ .tok_type = .match, .text = "~" },
                '!' => return .{ .tok_type = .not_op, .text = "!" },
                else => {},
            }
        }
        return .{ .tok_type = .eof, .text = "" };
    }
};

pub const Expr = union(enum) {
    number: f64,
    string: []const u8,
    regex_lit: []const u8,
    variable: []const u8,
    field: *const Expr,
    array_access: struct { name: []const u8, key: *const Expr },
    unary: struct { op: TokenType, operand: *const Expr },
    binary: struct { op: TokenType, left: *const Expr, right: *const Expr },
    concat: struct { left: *const Expr, right: *const Expr },
    assign: struct { target: *const Expr, op: TokenType, val: *const Expr },
    call: struct { name: []const u8, args: []const Expr },
    in_array: struct { key: *const Expr, array_name: []const u8 },
};

pub const Stmt = union(enum) {
    block: []const Stmt,
    expr: Expr,
    print: struct { args: []const Expr, redirect_file: ?[]const u8, append: bool },
    printf: struct { fmt: Expr, args: []const Expr, redirect_file: ?[]const u8, append: bool },
    if_stmt: struct { cond: Expr, then_branch: *const Stmt, else_branch: ?*const Stmt },
    while_stmt: struct { cond: Expr, body: *const Stmt },
    for_stmt: struct { init: ?Expr, cond: ?Expr, post: ?Expr, body: *const Stmt },
    for_in_stmt: struct { var_name: []const u8, array_name: []const u8, body: *const Stmt },
    break_stmt,
    continue_stmt,
    next_stmt,
    exit_stmt: ?Expr,
    delete_stmt: struct { array_name: []const u8, key: ?Expr },
};

pub const RuleKind = enum {
    begin,
    end,
    pattern,
    always,
};

pub const Rule = struct {
    kind: RuleKind,
    pattern: ?Expr = null,
    action: ?Stmt = null,
};

pub const Program = struct {
    rules: []const Rule,
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    vars: std.StringHashMap(Value),
    arrays: std.StringHashMap(std.StringHashMap(Value)),

    // Fields $0, $1 ...
    fields: std.ArrayList([]const u8),
    current_record: []const u8 = "",

    // Built-in variable state
    fs: []const u8 = " ",
    ofs: []const u8 = " ",
    rs: []const u8 = "\n",
    ors: []const u8 = "\n",
    nr: usize = 0,
    fnr: usize = 0,
    filename: []const u8 = "",

    exit_requested: bool = false,
    exit_code: u8 = 0,
    next_record_requested: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Context {
        return .{
            .allocator = allocator,
            .io = io,
            .vars = std.StringHashMap(Value).init(allocator),
            .arrays = std.StringHashMap(std.StringHashMap(Value)).init(allocator),
            .fields = std.ArrayList([]const u8).empty,
        };
    }

    pub fn deinit(self: *Context) void {
        self.vars.deinit();
        var it = self.arrays.valueIterator();
        while (it.next()) |map| {
            map.deinit();
        }
        self.arrays.deinit();
        self.fields.deinit(self.allocator);
    }

    pub fn setVar(self: *Context, name: []const u8, val: Value) !void {
        if (std.mem.eql(u8, name, "FS")) self.fs = val.asString(self.allocator);
        if (std.mem.eql(u8, name, "OFS")) self.ofs = val.asString(self.allocator);
        if (std.mem.eql(u8, name, "RS")) self.rs = val.asString(self.allocator);
        if (std.mem.eql(u8, name, "ORS")) self.ors = val.asString(self.allocator);
        try self.vars.put(name, val);
    }

    pub fn getVar(self: *Context, name: []const u8) Value {
        if (std.mem.eql(u8, name, "FS")) return Value.fromStr(self.fs);
        if (std.mem.eql(u8, name, "OFS")) return Value.fromStr(self.ofs);
        if (std.mem.eql(u8, name, "RS")) return Value.fromStr(self.rs);
        if (std.mem.eql(u8, name, "ORS")) return Value.fromStr(self.ors);
        if (std.mem.eql(u8, name, "NR")) return Value.fromNum(@as(f64, @floatFromInt(self.nr)));
        if (std.mem.eql(u8, name, "FNR")) return Value.fromNum(@as(f64, @floatFromInt(self.fnr)));
        if (std.mem.eql(u8, name, "NF")) return Value.fromNum(@as(f64, @floatFromInt(if (self.fields.items.len > 0) self.fields.items.len - 1 else 0)));
        if (std.mem.eql(u8, name, "FILENAME")) return Value.fromStr(self.filename);
        return self.vars.get(name) orelse Value.uninitVal();
    }

    pub fn splitRecord(self: *Context, record: []const u8) !void {
        self.current_record = record;
        self.fields.clearRetainingCapacity();
        try self.fields.append(self.allocator, record); // $0

        if (std.mem.eql(u8, self.fs, " ")) {
            // Default whitespace splitting (space/tab sequences)
            var idx: usize = 0;
            while (idx < record.len) {
                while (idx < record.len and (record[idx] == ' ' or record[idx] == '\t')) idx += 1;
                if (idx >= record.len) break;
                const start = idx;
                while (idx < record.len and record[idx] != ' ' and record[idx] != '\t') idx += 1;
                try self.fields.append(self.allocator, record[start..idx]);
            }
        } else if (self.fs.len == 1) {
            const sep = self.fs[0];
            var it = std.mem.splitScalar(u8, record, sep);
            while (it.next()) |chunk| {
                try self.fields.append(self.allocator, chunk);
            }
        } else {
            // Multicharacter regex FS
            var re = try common_regex.Regex.compileWithAst(self.allocator, self.fs, .ere, false, false);
            defer re.deinit(self.allocator);

            var pos: usize = 0;
            while (pos <= record.len) {
                if (re.search(record[pos..])) |match_res| {
                    const sep_start = pos + match_res.start;
                    const sep_end = pos + match_res.end;
                    try self.fields.append(self.allocator, record[pos..sep_start]);
                    pos = if (sep_end == sep_start) sep_start + 1 else sep_end;
                } else {
                    try self.fields.append(self.allocator, record[pos..]);
                    break;
                }
            }
        }
    }
};

pub fn evalExpr(ctx: *Context, expr: Expr) anyerror!Value {
    switch (expr) {
        .number => |n| return Value.fromNum(n),
        .string => |s| return Value.fromStr(s),
        .regex_lit => |re_str| {
            // Regex literal matches against $0
            var re = try common_regex.Regex.compile(ctx.allocator, re_str, .ere, false, false);
            defer re.deinit(ctx.allocator);
            return Value.fromNum(if (re.matches(ctx.current_record)) 1.0 else 0.0);
        },
        .variable => |name| return ctx.getVar(name),
        .field => |f_expr| {
            const f_val = try evalExpr(ctx, f_expr.*);
            const idx = @as(usize, @intFromFloat(@max(0.0, f_val.asNumber())));
            if (idx < ctx.fields.items.len) {
                return Value.fromStr(ctx.fields.items[idx]);
            }
            return Value.fromStr("");
        },
        .array_access => |acc| {
            const k_val = try evalExpr(ctx, acc.key.*);
            const key_str = k_val.asString(ctx.allocator);
            if (ctx.arrays.get(acc.name)) |map| {
                return map.get(key_str) orelse Value.uninitVal();
            }
            return Value.uninitVal();
        },
        .in_array => |in_a| {
            const k_val = try evalExpr(ctx, in_a.key.*);
            const key_str = k_val.asString(ctx.allocator);
            if (ctx.arrays.get(in_a.array_name)) |map| {
                return Value.fromNum(if (map.contains(key_str)) 1.0 else 0.0);
            }
            return Value.fromNum(0.0);
        },
        .unary => |u| {
            const val = try evalExpr(ctx, u.operand.*);
            switch (u.op) {
                .plus => return Value.fromNum(val.asNumber()),
                .minus => return Value.fromNum(-val.asNumber()),
                .not_op => return Value.fromNum(if (!val.isTrue()) 1.0 else 0.0),
                else => return val,
            }
        },
        .concat => |c| {
            const l_val = try evalExpr(ctx, c.left.*);
            const r_val = try evalExpr(ctx, c.right.*);
            const l_s = l_val.asString(ctx.allocator);
            const r_s = r_val.asString(ctx.allocator);
            const combined = try std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ l_s, r_s });
            return Value.fromStr(combined);
        },
        .binary => |b| {
            const l_val = try evalExpr(ctx, b.left.*);
            const r_val = try evalExpr(ctx, b.right.*);

            switch (b.op) {
                .plus => return Value.fromNum(l_val.asNumber() + r_val.asNumber()),
                .minus => return Value.fromNum(l_val.asNumber() - r_val.asNumber()),
                .star => return Value.fromNum(l_val.asNumber() * r_val.asNumber()),
                .slash => {
                    const denom = r_val.asNumber();
                    return Value.fromNum(if (denom != 0.0) l_val.asNumber() / denom else 0.0);
                },
                .percent => {
                    const denom = r_val.asNumber();
                    return Value.fromNum(if (denom != 0.0) @mod(l_val.asNumber(), denom) else 0.0);
                },
                .caret => return Value.fromNum(std.math.pow(f64, l_val.asNumber(), r_val.asNumber())),
                .eq, .ne, .lt, .le, .gt, .ge => {
                    // Numeric comparison if both are numbers or numeric strings
                    const l_s = l_val.asString(ctx.allocator);
                    const r_s = r_val.asString(ctx.allocator);
                    const l_is_num = (l_val.tag == .num or Value.isNumericString(l_s));
                    const r_is_num = (r_val.tag == .num or Value.isNumericString(r_s));

                    var cmp: i32 = 0;
                    if (l_is_num and r_is_num) {
                        const n1 = l_val.asNumber();
                        const n2 = r_val.asNumber();
                        cmp = if (n1 < n2) -1 else if (n1 > n2) 1 else 0;
                    } else {
                        cmp = if (std.mem.lessThan(u8, l_s, r_s)) -1 else if (std.mem.lessThan(u8, r_s, l_s)) 1 else 0;
                    }

                    const res = switch (b.op) {
                        .eq => cmp == 0,
                        .ne => cmp != 0,
                        .lt => cmp < 0,
                        .le => cmp <= 0,
                        .gt => cmp > 0,
                        .ge => cmp >= 0,
                        else => false,
                    };
                    return Value.fromNum(if (res) 1.0 else 0.0);
                },
                .match, .not_match => {
                    const target = l_val.asString(ctx.allocator);
                    const pat = r_val.asString(ctx.allocator);
                    var re = try common_regex.Regex.compile(ctx.allocator, pat, .ere, false, false);
                    defer re.deinit(ctx.allocator);
                    const is_m = re.matches(target);
                    return Value.fromNum(if (if (b.op == .match) is_m else !is_m) 1.0 else 0.0);
                },
                .and_op => return Value.fromNum(if (l_val.isTrue() and r_val.isTrue()) 1.0 else 0.0),
                .or_op => return Value.fromNum(if (l_val.isTrue() or r_val.isTrue()) 1.0 else 0.0),
                else => return l_val,
            }
        },
        .assign => |a| {
            const v = try evalExpr(ctx, a.val.*);
            switch (a.target.*) {
                .variable => |name| {
                    const cur = ctx.getVar(name);
                    const final_v = switch (a.op) {
                        .assign => v,
                        .plus_assign => Value.fromNum(cur.asNumber() + v.asNumber()),
                        .minus_assign => Value.fromNum(cur.asNumber() - v.asNumber()),
                        .star_assign => Value.fromNum(cur.asNumber() * v.asNumber()),
                        .slash_assign => Value.fromNum(if (v.asNumber() != 0.0) cur.asNumber() / v.asNumber() else 0.0),
                        .percent_assign => Value.fromNum(if (v.asNumber() != 0.0) @mod(cur.asNumber(), v.asNumber()) else 0.0),
                        else => v,
                    };
                    try ctx.setVar(name, final_v);
                    return final_v;
                },
                .field => |f_expr| {
                    const idx_val = try evalExpr(ctx, f_expr.*);
                    const idx = @as(usize, @intFromFloat(@max(0.0, idx_val.asNumber())));
                    const s = v.asString(ctx.allocator);
                    if (idx < ctx.fields.items.len) {
                        ctx.fields.items[idx] = s;
                    }
                    return v;
                },
                .array_access => |acc| {
                    const k_val = try evalExpr(ctx, acc.key.*);
                    const key_str = k_val.asString(ctx.allocator);
                    var entry = try ctx.arrays.getOrPut(acc.name);
                    if (!entry.found_existing) {
                        entry.value_ptr.* = std.StringHashMap(Value).init(ctx.allocator);
                    }
                    try entry.value_ptr.put(key_str, v);
                    return v;
                },
                else => return v,
            }
        },
        .call => |call| {
            return evalCall(ctx, call.name, call.args);
        },
    }
}

fn evalCall(ctx: *Context, name: []const u8, args: []const Expr) anyerror!Value {
    if (std.mem.eql(u8, name, "length")) {
        const str = if (args.len > 0)
            (try evalExpr(ctx, args[0])).asString(ctx.allocator)
        else
            ctx.current_record;
        return Value.fromNum(@as(f64, @floatFromInt(str.len)));
    }
    if (std.mem.eql(u8, name, "substr")) {
        if (args.len < 2) return Value.fromStr("");
        const s = (try evalExpr(ctx, args[0])).asString(ctx.allocator);
        const start_1 = @as(isize, @intFromFloat((try evalExpr(ctx, args[1])).asNumber()));
        if (start_1 < 1 or start_1 > s.len) return Value.fromStr("");
        const s_0 = @as(usize, @intCast(start_1 - 1));

        if (args.len >= 3) {
            const count = @as(usize, @intFromFloat(@max(0.0, (try evalExpr(ctx, args[2])).asNumber())));
            const end_0 = @min(s_0 + count, s.len);
            return Value.fromStr(s[s_0..end_0]);
        }
        return Value.fromStr(s[s_0..]);
    }
    if (std.mem.eql(u8, name, "index")) {
        if (args.len < 2) return Value.fromNum(0.0);
        const s = (try evalExpr(ctx, args[0])).asString(ctx.allocator);
        const t = (try evalExpr(ctx, args[1])).asString(ctx.allocator);
        if (std.mem.indexOf(u8, s, t)) |idx| {
            return Value.fromNum(@as(f64, @floatFromInt(idx + 1)));
        }
        return Value.fromNum(0.0);
    }
    if (std.mem.eql(u8, name, "tolower")) {
        if (args.len == 0) return Value.fromStr("");
        const s = (try evalExpr(ctx, args[0])).asString(ctx.allocator);
        var lower_buf = try ctx.allocator.alloc(u8, s.len);
        for (s, 0..) |c, i| lower_buf[i] = std.ascii.toLower(c);
        return Value.fromStr(lower_buf);
    }
    if (std.mem.eql(u8, name, "toupper")) {
        if (args.len == 0) return Value.fromStr("");
        const s = (try evalExpr(ctx, args[0])).asString(ctx.allocator);
        var upper_buf = try ctx.allocator.alloc(u8, s.len);
        for (s, 0..) |c, i| upper_buf[i] = std.ascii.toUpper(c);
        return Value.fromStr(upper_buf);
    }
    if (std.mem.eql(u8, name, "int")) {
        if (args.len == 0) return Value.fromNum(0.0);
        const n = (try evalExpr(ctx, args[0])).asNumber();
        return Value.fromNum(@floor(n));
    }
    if (std.mem.eql(u8, name, "sqrt")) {
        if (args.len == 0) return Value.fromNum(0.0);
        const n = (try evalExpr(ctx, args[0])).asNumber();
        return Value.fromNum(@sqrt(n));
    }
    return Value.uninitVal();
}

pub fn execStmt(ctx: *Context, stmt: Stmt, writer: anytype) !void {
    if (ctx.exit_requested or ctx.next_record_requested) return;

    switch (stmt) {
        .block => |stmts| {
            for (stmts) |s| {
                try execStmt(ctx, s, writer);
                if (ctx.exit_requested or ctx.next_record_requested) return;
            }
        },
        .expr => |e| {
            _ = try evalExpr(ctx, e);
        },
        .print => |p| {
            if (p.args.len == 0) {
                _ = writer.writeAll(ctx.current_record) catch {};
            } else {
                for (p.args, 0..) |arg, idx| {
                    if (idx > 0) _ = writer.writeAll(ctx.ofs) catch {};
                    const val = try evalExpr(ctx, arg);
                    _ = writer.writeAll(val.asString(ctx.allocator)) catch {};
                }
            }
            _ = writer.writeAll(ctx.ors) catch {};
        },
        .printf => |p| {
            const fmt_val = try evalExpr(ctx, p.fmt);
            const fmt_str = fmt_val.asString(ctx.allocator);
            var arg_idx: usize = 0;
            var i: usize = 0;
            while (i < fmt_str.len) {
                if (fmt_str[i] == '%' and i + 1 < fmt_str.len) {
                    const spec = fmt_str[i + 1];
                    if (spec == 's' and arg_idx < p.args.len) {
                        const val = try evalExpr(ctx, p.args[arg_idx]);
                        arg_idx += 1;
                        _ = writer.writeAll(val.asString(ctx.allocator)) catch {};
                        i += 2;
                        continue;
                    } else if ((spec == 'd' or spec == 'i') and arg_idx < p.args.len) {
                        const val = try evalExpr(ctx, p.args[arg_idx]);
                        arg_idx += 1;
                        _ = writer.print("{d}", .{@as(i64, @intFromFloat(val.asNumber()))}) catch {};
                        i += 2;
                        continue;
                    } else if (spec == 'f' and arg_idx < p.args.len) {
                        const val = try evalExpr(ctx, p.args[arg_idx]);
                        arg_idx += 1;
                        _ = writer.print("{d:.6}", .{val.asNumber()}) catch {};
                        i += 2;
                        continue;
                    } else if (spec == '%') {
                        _ = writer.writeByte('%') catch {};
                        i += 2;
                        continue;
                    }
                }
                _ = writer.writeByte(fmt_str[i]) catch {};
                i += 1;
            }
        },
        .if_stmt => |ifs| {
            const cond_val = try evalExpr(ctx, ifs.cond);
            if (cond_val.isTrue()) {
                try execStmt(ctx, ifs.then_branch.*, writer);
            } else if (ifs.else_branch) |eb| {
                try execStmt(ctx, eb.*, writer);
            }
        },
        .while_stmt => |ws| {
            while ((try evalExpr(ctx, ws.cond)).isTrue()) {
                try execStmt(ctx, ws.body.*, writer);
                if (ctx.exit_requested or ctx.next_record_requested) break;
            }
        },
        .for_stmt => |fs| {
            if (fs.init) |in_e| _ = try evalExpr(ctx, in_e);
            while (fs.cond == null or (try evalExpr(ctx, fs.cond.?)).isTrue()) {
                try execStmt(ctx, fs.body.*, writer);
                if (ctx.exit_requested or ctx.next_record_requested) break;
                if (fs.post) |p_e| _ = try evalExpr(ctx, p_e);
            }
        },
        .for_in_stmt => |fis| {
            if (ctx.arrays.get(fis.array_name)) |map| {
                var it = map.keyIterator();
                while (it.next()) |k| {
                    try ctx.setVar(fis.var_name, Value.fromStr(k.*));
                    try execStmt(ctx, fis.body.*, writer);
                    if (ctx.exit_requested or ctx.next_record_requested) break;
                }
            }
        },
        .break_stmt => {},
        .continue_stmt => {},
        .next_stmt => ctx.next_record_requested = true,
        .exit_stmt => |e| {
            ctx.exit_requested = true;
            if (e) |ex| {
                const code_val = try evalExpr(ctx, ex);
                ctx.exit_code = @as(u8, @truncate(@as(u32, @intFromFloat(@max(0.0, code_val.asNumber())))));
            } else {
                ctx.exit_code = 0;
            }
        },
        .delete_stmt => |d| {
            if (d.key) |k_e| {
                const k_val = try evalExpr(ctx, k_e);
                const k_s = k_val.asString(ctx.allocator);
                if (ctx.arrays.getPtr(d.array_name)) |map| {
                    _ = map.remove(k_s);
                }
            } else {
                if (ctx.arrays.getPtr(d.array_name)) |map| {
                    map.clearRetainingCapacity();
                }
            }
        },
    }
}

pub fn parseSimpleProgram(allocator: std.mem.Allocator, src: []const u8) !Program {
    var rules: std.ArrayList(Rule) = .empty;
    var lexer = Lexer.init(src);

    var tok = lexer.nextToken();
    while (tok.tok_type != .eof) {
        if (tok.tok_type == .newline or tok.tok_type == .semicolon) {
            tok = lexer.nextToken();
            continue;
        }

        if (tok.tok_type == .kw_begin) {
            tok = lexer.nextToken();
            const action = try parseBlock(allocator, &lexer, &tok);
            try rules.append(allocator, .{ .kind = .begin, .action = action });
        } else if (tok.tok_type == .kw_end) {
            tok = lexer.nextToken();
            const action = try parseBlock(allocator, &lexer, &tok);
            try rules.append(allocator, .{ .kind = .end, .action = action });
        } else if (tok.tok_type == .lbrace) {
            const action = try parseBlock(allocator, &lexer, &tok);
            try rules.append(allocator, .{ .kind = .always, .action = action });
        } else {
            // Pattern or pattern { action }
            const pat = try parseExpr(allocator, &lexer, &tok);
            var action: ?Stmt = null;
            if (tok.tok_type == .lbrace) {
                action = try parseBlock(allocator, &lexer, &tok);
            } else {
                // Default action: { print }
                action = Stmt{ .print = .{ .args = &.{}, .redirect_file = null, .append = false } };
            }
            try rules.append(allocator, .{ .kind = .pattern, .pattern = pat, .action = action });
        }
    }

    return Program{ .rules = try rules.toOwnedSlice(allocator) };
}

fn parseBlock(allocator: std.mem.Allocator, lexer: *Lexer, tok: *Token) anyerror!Stmt {
    if (tok.tok_type != .lbrace) return error.ExpectedLBrace;
    tok.* = lexer.nextToken();

    var stmts: std.ArrayList(Stmt) = .empty;

    while (tok.tok_type != .rbrace and tok.tok_type != .eof) {
        if (tok.tok_type == .newline or tok.tok_type == .semicolon) {
            tok.* = lexer.nextToken();
            continue;
        }

        if (tok.tok_type == .kw_print) {
            tok.* = lexer.nextToken();
            var print_args: std.ArrayList(Expr) = .empty;
            while (tok.tok_type != .newline and tok.tok_type != .semicolon and tok.tok_type != .rbrace and tok.tok_type != .eof) {
                const arg = try parseExpr(allocator, lexer, tok);
                try print_args.append(allocator, arg);
                if (tok.tok_type == .comma) {
                    tok.* = lexer.nextToken();
                } else break;
            }
            try stmts.append(allocator, .{ .print = .{
                .args = try print_args.toOwnedSlice(allocator),
                .redirect_file = null,
                .append = false,
            } });
        } else if (tok.tok_type == .kw_printf) {
            tok.* = lexer.nextToken();
            const fmt = try parseExpr(allocator, lexer, tok);
            var p_args: std.ArrayList(Expr) = .empty;
            if (tok.tok_type == .comma) {
                tok.* = lexer.nextToken();
                while (tok.tok_type != .newline and tok.tok_type != .semicolon and tok.tok_type != .rbrace and tok.tok_type != .eof) {
                    const a = try parseExpr(allocator, lexer, tok);
                    try p_args.append(allocator, a);
                    if (tok.tok_type == .comma) {
                        tok.* = lexer.nextToken();
                    } else break;
                }
            }
            try stmts.append(allocator, .{ .printf = .{
                .fmt = fmt,
                .args = try p_args.toOwnedSlice(allocator),
                .redirect_file = null,
                .append = false,
            } });
        } else if (tok.tok_type == .kw_exit) {
            tok.* = lexer.nextToken();
            var code_expr: ?Expr = null;
            if (tok.tok_type != .newline and tok.tok_type != .semicolon and tok.tok_type != .rbrace and tok.tok_type != .eof) {
                code_expr = try parseExpr(allocator, lexer, tok);
            }
            try stmts.append(allocator, .{ .exit_stmt = code_expr });
        } else if (tok.tok_type == .kw_next) {
            tok.* = lexer.nextToken();
            try stmts.append(allocator, .next_stmt);
        } else {
            const e = try parseExpr(allocator, lexer, tok);
            try stmts.append(allocator, .{ .expr = e });
        }

        if (tok.tok_type == .newline or tok.tok_type == .semicolon) {
            tok.* = lexer.nextToken();
        }
    }

    if (tok.tok_type == .rbrace) {
        tok.* = lexer.nextToken();
    }

    return Stmt{ .block = try stmts.toOwnedSlice(allocator) };
}

fn parseExpr(allocator: std.mem.Allocator, lexer: *Lexer, tok: *Token) anyerror!Expr {
    var left = try parsePrimary(allocator, lexer, tok);

    // Check for assignment or binary operator
    while (true) {
        const op = tok.tok_type;
        if (op == .assign or op == .plus_assign or op == .minus_assign or op == .star_assign or op == .slash_assign) {
            tok.* = lexer.nextToken();
            const val = try parseExpr(allocator, lexer, tok);
            const l_ptr = try allocator.create(Expr);
            l_ptr.* = left;
            const v_ptr = try allocator.create(Expr);
            v_ptr.* = val;
            return Expr{ .assign = .{ .target = l_ptr, .op = op, .val = v_ptr } };
        }

        if (op == .plus or op == .minus or op == .star or op == .slash or op == .percent or op == .caret or
            op == .eq or op == .ne or op == .lt or op == .le or op == .gt or op == .ge or
            op == .match or op == .not_match or op == .and_op or op == .or_op)
        {
            tok.* = lexer.nextToken();
            const right = try parsePrimary(allocator, lexer, tok);
            const l_ptr = try allocator.create(Expr);
            l_ptr.* = left;
            const r_ptr = try allocator.create(Expr);
            r_ptr.* = right;
            left = Expr{ .binary = .{ .op = op, .left = l_ptr, .right = r_ptr } };
            continue;
        }

        // Implicit string concatenation: if next token is number, string, variable, field, etc.
        if (tok.tok_type == .number or tok.tok_type == .string or tok.tok_type == .ident or tok.tok_type == .dollar) {
            const next_p = try parsePrimary(allocator, lexer, tok);
            const l_ptr = try allocator.create(Expr);
            l_ptr.* = left;
            const r_ptr = try allocator.create(Expr);
            r_ptr.* = next_p;
            left = Expr{ .concat = .{ .left = l_ptr, .right = r_ptr } };
            continue;
        }

        break;
    }

    return left;
}

fn parsePrimary(allocator: std.mem.Allocator, lexer: *Lexer, tok: *Token) anyerror!Expr {
    switch (tok.tok_type) {
        .number => {
            const val = tok.num_val;
            tok.* = lexer.nextToken();
            return Expr{ .number = val };
        },
        .string => {
            const s = tok.text;
            tok.* = lexer.nextToken();
            return Expr{ .string = s };
        },
        .dollar => {
            tok.* = lexer.nextToken();
            const f_inner = try parsePrimary(allocator, lexer, tok);
            const f_ptr = try allocator.create(Expr);
            f_ptr.* = f_inner;
            return Expr{ .field = f_ptr };
        },
        .ident => {
            const name = tok.text;
            tok.* = lexer.nextToken();
            if (tok.tok_type == .lparen) {
                // Function call
                tok.* = lexer.nextToken();
                var call_args: std.ArrayList(Expr) = .empty;
                while (tok.tok_type != .rparen and tok.tok_type != .eof) {
                    const arg = try parseExpr(allocator, lexer, tok);
                    try call_args.append(allocator, arg);
                    if (tok.tok_type == .comma) {
                        tok.* = lexer.nextToken();
                    } else break;
                }
                if (tok.tok_type == .rparen) tok.* = lexer.nextToken();
                return Expr{ .call = .{ .name = name, .args = try call_args.toOwnedSlice(allocator) } };
            } else if (tok.tok_type == .lbracket) {
                // Array access
                tok.* = lexer.nextToken();
                const key_e = try parseExpr(allocator, lexer, tok);
                if (tok.tok_type == .rbracket) tok.* = lexer.nextToken();
                const k_ptr = try allocator.create(Expr);
                k_ptr.* = key_e;
                return Expr{ .array_access = .{ .name = name, .key = k_ptr } };
            }
            return Expr{ .variable = name };
        },
        .lparen => {
            tok.* = lexer.nextToken();
            const inner = try parseExpr(allocator, lexer, tok);
            if (tok.tok_type == .rparen) tok.* = lexer.nextToken();
            return inner;
        },
        .slash => {
            // Regex literal /.../
            const start = lexer.cursor;
            while (lexer.cursor < lexer.input.len and lexer.input[lexer.cursor] != '/') {
                if (lexer.input[lexer.cursor] == '\\' and lexer.cursor + 1 < lexer.input.len) {
                    lexer.cursor += 2;
                } else {
                    lexer.cursor += 1;
                }
            }
            const re_content = lexer.input[start..lexer.cursor];
            if (lexer.cursor < lexer.input.len and lexer.input[lexer.cursor] == '/') {
                lexer.cursor += 1;
            }
            tok.* = lexer.nextToken();
            return Expr{ .regex_lit = re_content };
        },
        else => return error.UnexpectedToken,
    }
}

pub fn run(allocator: std.mem.Allocator, args: []const [:0]const u8) u8 {
    const io = std.Io.Threaded.global_single_threaded.io();

    var fs_opt: ?[]const u8 = null;
    var vars_assign: std.ArrayList([]const u8) = .empty;
    defer vars_assign.deinit(allocator);

    var prog_files: std.ArrayList([]const u8) = .empty;
    defer prog_files.deinit(allocator);

    var parser = common_args.ArgParser.init(args);
    while (parser.next("F:v:f:")) |opt| {
        switch (opt) {
            'F' => {
                fs_opt = parser.optarg;
            },
            'v' => {
                const v = parser.optarg orelse {
                    common_error.report("awk", "option requires an argument: -v", error.InvalidArgument);
                    return common_error.EXIT_SYNTAX;
                };
                vars_assign.append(allocator, v) catch {
                    common_error.report("awk", null, error.OutOfMemory);
                    return common_error.EXIT_FAILURE;
                };
            },
            'f' => {
                const f = parser.optarg orelse {
                    common_error.report("awk", "option requires an argument: -f", error.InvalidArgument);
                    return common_error.EXIT_SYNTAX;
                };
                prog_files.append(allocator, f) catch {
                    common_error.report("awk", null, error.OutOfMemory);
                    return common_error.EXIT_FAILURE;
                };
            },
            else => {
                common_error.report("awk", "invalid option", error.InvalidArgument);
                return common_error.EXIT_SYNTAX;
            },
        }
    }

    const operands = parser.remaining();
    var program_src: []const u8 = "";
    var file_operands: []const [:0]const u8 = &.{};

    if (prog_files.items.len > 0) {
        var p_buf: std.ArrayList(u8) = .empty;
        defer p_buf.deinit(allocator);
        for (prog_files.items) |pf| {
            const content = std.Io.Dir.cwd().readFileAlloc(io, pf, allocator, .unlimited) catch |err| {
                common_error.report("awk", pf, err);
                return common_error.EXIT_SYNTAX;
            };
            defer allocator.free(content);
            p_buf.appendSlice(allocator, content) catch {};
            p_buf.append(allocator, '\n') catch {};
        }
        program_src = allocator.dupe(u8, p_buf.items) catch "";
        file_operands = operands;
    } else {
        if (operands.len == 0) {
            common_error.report("awk", "missing program operand", error.InvalidArgument);
            return common_error.EXIT_SYNTAX;
        }
        program_src = operands[0];
        file_operands = operands[1..];
    }

    var ctx = Context.init(allocator, io);
    defer ctx.deinit();

    if (fs_opt) |fs| {
        ctx.fs = fs;
    }

    // Process -v assignments before BEGIN
    for (vars_assign.items) |assign_str| {
        if (std.mem.indexOfScalar(u8, assign_str, '=')) |eq_pos| {
            const name = assign_str[0..eq_pos];
            const val_str = assign_str[eq_pos + 1 ..];
            const val = if (Value.isNumericString(val_str))
                Value.fromNum(std.fmt.parseFloat(f64, val_str) catch 0.0)
            else
                Value.fromStr(val_str);
            ctx.setVar(name, val) catch {};
        }
    }

    // Parse program
    var prog_arena = std.heap.ArenaAllocator.init(allocator);
    defer prog_arena.deinit();
    const p_alloc = prog_arena.allocator();

    const prog = parseSimpleProgram(p_alloc, program_src) catch |err| {
        common_error.report("awk", "program syntax error", err);
        return common_error.EXIT_SYNTAX;
    };

    const stdout_file = std.Io.File.stdout();
    var stdout_buf: [BUFFER_SIZE]u8 = undefined;
    var stdout_fw = stdout_file.writerStreaming(io, &stdout_buf);
    const writer = &stdout_fw.interface;
    defer stdout_fw.flush() catch {};

    // 1. Execute BEGIN rules
    for (prog.rules) |rule| {
        if (rule.kind == .begin and rule.action != null) {
            execStmt(&ctx, rule.action.?, writer) catch {};
            if (ctx.exit_requested) break;
        }
    }

    // Check if there are body or END rules
    var has_body_or_end = false;
    for (prog.rules) |rule| {
        if (rule.kind != .begin) {
            has_body_or_end = true;
            break;
        }
    }

    if (!ctx.exit_requested and has_body_or_end) {
        const default_operands = [_][:0]const u8{"-"};
        const input_files: []const [:0]const u8 = if (file_operands.len == 0) &default_operands else file_operands;

        for (input_files) |path| {
            if (ctx.exit_requested) break;

            // Check if operand is an assignment: var=val
            if (std.mem.indexOfScalar(u8, path, '=')) |eq_pos| {
                const name = path[0..eq_pos];
                const val_str = path[eq_pos + 1 ..];
                const val = if (Value.isNumericString(val_str))
                    Value.fromNum(std.fmt.parseFloat(f64, val_str) catch 0.0)
                else
                    Value.fromStr(val_str);
                ctx.setVar(name, val) catch {};
                continue;
            }

            ctx.filename = path;
            ctx.fnr = 0;

            const is_stdin = std.mem.eql(u8, path, "-");
            const f = if (is_stdin)
                std.Io.File.stdin()
            else
                std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch |err| {
                    common_error.report("awk", path, err);
                    return common_error.EXIT_FAILURE;
                };
            defer if (!is_stdin) f.close(io);

            var r_buf: [BUFFER_SIZE]u8 = undefined;
            var r = f.readerStreaming(io, &r_buf);

            while (true) {
                const maybe_line = r.interface.takeDelimiter('\n') catch break;
                const raw_l = maybe_line orelse break;
                const line = if (raw_l.len > 0 and raw_l[raw_l.len - 1] == '\r')
                    raw_l[0 .. raw_l.len - 1]
                else
                    raw_l;

                ctx.nr += 1;
                ctx.fnr += 1;
                ctx.next_record_requested = false;
                ctx.splitRecord(line) catch break;

                // Execute body rules
                for (prog.rules) |rule| {
                    if (ctx.exit_requested or ctx.next_record_requested) break;
                    if (rule.kind == .begin or rule.kind == .end) continue;

                    var matched = false;
                    if (rule.kind == .always) {
                        matched = true;
                    } else if (rule.pattern) |pat| {
                        const pat_val = evalExpr(&ctx, pat) catch continue;
                        matched = pat_val.isTrue();
                    }

                    if (matched and rule.action != null) {
                        execStmt(&ctx, rule.action.?, writer) catch {};
                    }
                }
            }
        }
    }

    // 2. Execute END rules
    for (prog.rules) |rule| {
        if (rule.kind == .end and rule.action != null) {
            execStmt(&ctx, rule.action.?, writer) catch {};
        }
    }

    return ctx.exit_code;
}

// ============================================================================
// Unit Tests
// ============================================================================

test "awk: parse simple print program" {
    const allocator = std.testing.allocator;

    const prog_src = "BEGIN { print \"hello\", \"world\" }";
    var prog_arena = std.heap.ArenaAllocator.init(allocator);
    defer prog_arena.deinit();

    const prog = try parseSimpleProgram(prog_arena.allocator(), prog_src);
    try std.testing.expectEqual(@as(usize, 1), prog.rules.len);
    try std.testing.expectEqual(RuleKind.begin, prog.rules[0].kind);
}

test "awk: value conversions" {
    const allocator = std.testing.allocator;

    const v1 = Value.fromNum(42.0);
    try std.testing.expectEqual(@as(f64, 42.0), v1.asNumber());
    const s1 = v1.asString(allocator);
    defer allocator.free(s1);
    try std.testing.expectEqualStrings("42", s1);

    const v2 = Value.fromStr("123.5");
    try std.testing.expectEqual(@as(f64, 123.5), v2.asNumber());
}

test "awk: file processing and fields" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const tmp_path = "zig-cache/tmp_awk_test.txt";
    const file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{});
    defer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
    try file.writeStreamingAll(io, "apple 10 red\nbanana 20 yellow\n");
    file.close(io);

    // Run awk program '{ print $1, $3 }'
    const res = run(allocator, &.{ "{ print $1, $3 }", tmp_path });
    try std.testing.expectEqual(common_error.EXIT_SUCCESS, res);
}
