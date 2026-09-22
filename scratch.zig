const std = @import("std"); pub fn main() !void { const st1 = try std.fs.cwd().statFile("."); const st2 = try std.fs.cwd().statFile("."); std.debug.print("{} {}\n", .{st1.inode, st2.inode}); }
