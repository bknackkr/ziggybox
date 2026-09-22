const std = @import("std");

pub const OptSpec = struct {
    char: u8,
    takes_arg: bool = false,
};

pub const ArgParser = struct {
    args: []const [:0]const u8,
    arg_idx: usize = 0,
    sub_idx: usize = 0,
    optarg: ?[:0]const u8 = null,
    optopt: u8 = 0,

    pub fn init(args: []const [:0]const u8) ArgParser {
        return ArgParser{
            .args = args,
        };
    }

    /// Returns the next parsed option flag character, '?' on unknown flag, 
    /// ':' on missing argument, or null when options are exhausted.
    pub fn next(self: *ArgParser, optstring: []const u8) ?u8 {
        self.optarg = null;
        self.optopt = 0;

        if (self.arg_idx >= self.args.len) return null;

        const arg = self.args[self.arg_idx];

        if (self.sub_idx == 0) {
            // Check if it's an option
            if (arg.len < 2 or arg[0] != '-') {
                // Non-option argument found, strict POSIX stops parsing here.
                return null;
            }

            if (std.mem.eql(u8, arg, "--")) {
                self.arg_idx += 1; // Skip "--"
                return null; // End of options
            }

            // Note: "-" by itself is usually a non-option (e.g. stdin).
            if (std.mem.eql(u8, arg, "-")) {
                return null;
            }

            self.sub_idx = 1;
        }

        const opt_char = arg[self.sub_idx];
        self.optopt = opt_char;
        self.sub_idx += 1;

        var is_known = false;
        var takes_arg = false;

        for (optstring, 0..) |c, i| {
            if (c == opt_char and c != ':') {
                is_known = true;
                if (i + 1 < optstring.len and optstring[i + 1] == ':') {
                    takes_arg = true;
                }
                break;
            }
        }

        if (is_known) {
            if (takes_arg) {
                if (self.sub_idx < arg.len) {
                    // Option argument is attached: -n10
                    self.optarg = arg[self.sub_idx..];
                    self.arg_idx += 1;
                    self.sub_idx = 0;
                } else {
                    // Option argument is space-separated: -n 10
                    self.arg_idx += 1;
                    if (self.arg_idx < self.args.len) {
                        self.optarg = self.args[self.arg_idx];
                        self.arg_idx += 1;
                        self.sub_idx = 0;
                    } else {
                        self.sub_idx = 0;
                        return ':'; // Missing argument
                    }
                }
            } else {
                if (self.sub_idx >= arg.len) {
                    self.arg_idx += 1;
                    self.sub_idx = 0;
                }
            }
            return opt_char;
        } else {
            // Unknown flag
            if (self.sub_idx >= arg.len) {
                self.arg_idx += 1;
                self.sub_idx = 0;
            }
            return '?';
        }
    }

    /// Returns remaining positional arguments once option parsing finishes.
    pub fn remaining(self: *const ArgParser) []const [:0]const u8 {
        return self.args[self.arg_idx..];
    }
};
