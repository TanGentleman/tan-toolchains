//! Miniature stdlib used by the index/search tests.
//!
//! Mirrors the shapes that matter: a module import, a nested module import,
//! a container with public members, a type-returning function, an alias, an
//! error set, plus things that must stay out of the index (private decls,
//! private members, and a private self-import).

pub const Answer = struct {
    /// The meaning of life.
    pub const value: u32 = 42;

    /// Say hello.
    pub fn greet() void {}

    const secret = 1;
};

pub const Foo = @import("foo.zig");
pub const Bar = @import("nested/bar.zig");
pub const Mem = @import("mem.zig");

pub const Alias = Foo.Thing;

pub fn make(comptime T: type) type {
    return struct {
        pub const Inner = T;
    };
}

const Private = struct {
    pub const Hidden = u8;
};

pub const answer = 42;
pub const Thing = enum { a, b };
pub const Oops = error{ Bad, Worse };
