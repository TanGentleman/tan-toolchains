const std = @import("std");
const cli = @import("cli.zig");

pub fn main(init: std.process.Init) u8 {
    return cli.run(init);
}

test {
    _ = @import("cli.zig");
    _ = @import("info.zig");
    _ = @import("version.zig");
    _ = @import("zig_env.zig");
}
