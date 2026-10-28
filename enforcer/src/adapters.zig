//! Agent knowledge lives here. Pi is implemented; Claude is detected but points
//! at the upstream project until this rewrite grows a settings mutator.

const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const settings = @import("settings.zig");
const pi = @import("pi.zig");

pub const Adapter = enum { pi, claude };

pub const Detect = union(enum) {
    absent,
    present,
    problem: []const u8,
};

pub const Context = struct {
    home: []const u8,
    agent_dir: []const u8,
    claude_settings: []const u8,
};

/// `pi_agent_dir` is Pi's `PI_CODING_AGENT_DIR` override; when absent, the
/// default lives under `home`. The returned paths are owned by the caller.
pub fn context(gpa: Allocator, home: []const u8, pi_agent_dir: ?[]const u8) !Context {
    return .{
        .home = home,
        .agent_dir = if (pi_agent_dir) |path|
            try gpa.dupe(u8, path)
        else
            try std.fs.path.join(gpa, &.{ home, ".pi", "agent" }),
        .claude_settings = try std.fs.path.join(gpa, &.{ home, ".claude", "settings.json" }),
    };
}

pub fn detect(io: Io, ctx: Context, adapter: Adapter) !Detect {
    switch (adapter) {
        .pi => {
            const stat = Io.Dir.cwd().statFile(io, ctx.agent_dir, .{}) catch |err| switch (err) {
                error.FileNotFound => return .absent,
                else => return err,
            };
            if (stat.kind != .directory) return .{ .problem = "agent directory is not a directory" };
            return .present;
        },
        .claude => {
            const stat = Io.Dir.cwd().statFile(io, ctx.claude_settings, .{ .follow_symlinks = false }) catch |err| switch (err) {
                error.FileNotFound => return .absent,
                else => return err,
            };
            return switch (stat.kind) {
                .sym_link => .{ .problem = "settings.json is a symlink (unsupported)" },
                .file => .present,
                else => .{ .problem = "settings.json is not a regular file" },
            };
        },
    }
}

pub fn apply(
    io: Io,
    gpa: Allocator,
    ctx: Context,
    adapter: Adapter,
    action: settings.Action,
    self_path: []const u8,
) !settings.Outcome {
    switch (adapter) {
        .pi => {
            var agent_dir = try Io.Dir.cwd().openDir(io, ctx.agent_dir, .{});
            defer agent_dir.close(io);
            return switch (action) {
                .install => pi.install(io, gpa, agent_dir, self_path),
                .uninstall => pi.uninstall(io, gpa, agent_dir),
            };
        },
        .claude => return error.ClaudeUnsupported,
    }
}

test "pi is absent when the agent directory does not exist" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache/tmp", &tmp.sub_path });
    defer std.testing.allocator.free(home);

    const ctx = try context(std.testing.allocator, home, null);
    defer std.testing.allocator.free(ctx.agent_dir);
    defer std.testing.allocator.free(ctx.claude_settings);

    try std.testing.expect(detect(std.testing.io, ctx, .pi) == .absent);
    try std.testing.expect(detect(std.testing.io, ctx, .claude) == .absent);
}

test "PI_CODING_AGENT_DIR overrides the default agent directory" {
    const ctx = try context(std.testing.allocator, "/home/user", "/custom/pi-agent");
    defer std.testing.allocator.free(ctx.agent_dir);
    defer std.testing.allocator.free(ctx.claude_settings);

    try std.testing.expectEqualStrings("/custom/pi-agent", ctx.agent_dir);
    try std.testing.expectEqualStrings("/home/user/.claude/settings.json", ctx.claude_settings);
}
