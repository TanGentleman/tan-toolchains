const std = @import("std");
const cli = @import("cli.zig");

pub fn main(init: std.process.Init) u8 {
    return cli.run(init);
}

test {
    _ = @import("builtins.zig");
    _ = @import("cli.zig");
    _ = @import("get.zig");
    _ = @import("info.zig");
    _ = @import("stdlib.zig");
    _ = @import("version.zig");
    _ = @import("zig_env.zig");
}
