const std = @import("std"); pub fn main() !void { const dir = std.Io.Dir.cwd(); _ = dir.io.vtable.dirSetFileOwner(dir.io.userdata, dir.handle, "", null, null, .{}); }
