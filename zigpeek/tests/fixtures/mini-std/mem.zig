//! Minimal allocator-ish interface.

const Mem = @This();

/// Type-erased context pointer.
ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {};

pub fn alloc(self: Mem) void {
    _ = self;
}

/// Private helper; must not be listed.
fn secretHelper() void {}
