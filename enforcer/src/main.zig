//! enforcer: a small prompt gate. `on`/`off` manage the Pi input hook; `hook`
//! reads a prompt from stdin and exits 0 (allow), 2 (block), or 1 (fail open).

const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const adapters = @import("adapters.zig");
const hook = @import("hook.zig");
const settings = @import("settings.zig");

const usage_text =
    \\Usage: enforcer <command>
    \\
    \\  on       register the Pi prompt hook
    \\  off      unregister the Pi prompt hook
    \\  hook     run as a hook: read stdin, exit 2 to block
    \\  --help   show this help
    \\
    \\Pi is supported. Claude is not implemented in this rewrite; use
    \\https://github.com/TanGentleman/enforcer for Claude.
    \\
;

fn write(io: Io, file: Io.File, bytes: []const u8) void {
    file.writeStreamingAll(io, bytes) catch {};
}

fn printStderr(io: Io, gpa: Allocator, comptime fmt: []const u8, args: anytype) void {
    const msg = std.fmt.allocPrint(gpa, fmt, args) catch return;
    defer gpa.free(msg);
    write(io, Io.File.stderr(), msg);
}

fn printStdout(io: Io, gpa: Allocator, comptime fmt: []const u8, args: anytype) void {
    const msg = std.fmt.allocPrint(gpa, fmt, args) catch return;
    defer gpa.free(msg);
    write(io, Io.File.stdout(), msg);
}

fn usage(io: Io, file: Io.File) void {
    write(io, file, usage_text);
}

fn outcomeMessage(action: settings.Action, outcome: settings.Outcome) []const u8 {
    return switch (action) {
        .install => switch (outcome) {
            .changed => "installed",
            .unchanged => "already installed",
        },
        .uninstall => switch (outcome) {
            .changed => "removed",
            .unchanged => "nothing to remove",
        },
    };
}

fn toggle(init: std.process.Init, action: settings.Action) u8 {
    const io = init.io;
    const gpa = init.gpa;
    const env = init.environ_map;

    const home = env.get("ENFORCER_HOME") orelse env.get("HOME") orelse {
        printStderr(io, gpa, "enforcer: HOME is not set\n", .{});
        return 1;
    };

    const pi_agent_dir: ?[]const u8 = blk: {
        const path = env.get("PI_CODING_AGENT_DIR") orelse break :blk null;
        break :blk if (path.len == 0) null else path;
    };
    const ctx = adapters.context(gpa, home, pi_agent_dir) catch |err| {
        printStderr(io, gpa, "enforcer: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer gpa.free(ctx.agent_dir);
    defer gpa.free(ctx.claude_settings);

    var owned_self: ?[:0]u8 = null;
    defer if (owned_self) |path| gpa.free(path);

    const self_path: []const u8 = switch (action) {
        .install => env.get("ENFORCER_SELF") orelse blk: {
            owned_self = std.process.executablePathAlloc(io, gpa) catch |err| {
                printStderr(io, gpa, "enforcer: cannot find own executable: {s}\n", .{@errorName(err)});
                return 1;
            };
            break :blk owned_self.?;
        },
        .uninstall => "",
    };

    var found = false;
    var applied = false;

    for ([_]adapters.Adapter{ .pi, .claude }) |adapter| {
        const detected = adapters.detect(io, ctx, adapter) catch |err| {
            printStderr(io, gpa, "enforcer: {s}: {s}\n", .{ @tagName(adapter), @errorName(err) });
            return 1;
        };

        switch (detected) {
            .absent => continue,
            .problem => |problem| {
                found = true;
                printStderr(io, gpa, "enforcer: {s}: {s}\n", .{ @tagName(adapter), problem });
                return 1;
            },
            .present => {
                found = true;
                const outcome = adapters.apply(io, gpa, ctx, adapter, action, self_path) catch |err| {
                    switch (err) {
                        error.ClaudeUnsupported => {
                            printStderr(io, gpa, "enforcer: claude: not implemented; use https://github.com/TanGentleman/enforcer\n", .{});
                            continue;
                        },
                        else => {
                            printStderr(io, gpa, "enforcer: {s}: {s}\n", .{ @tagName(adapter), @errorName(err) });
                            return 1;
                        },
                    }
                };
                applied = true;
                printStdout(io, gpa, "{s}: {s}\n", .{ @tagName(adapter), outcomeMessage(action, outcome) });
            },
        }
    }

    if (!found) {
        printStderr(io, gpa, "enforcer: no configured agent found (looked for {s} and {s})\n", .{ ctx.agent_dir, ctx.claude_settings });
        return 1;
    }
    return if (applied) 0 else 1;
}

pub fn main(init: std.process.Init) u8 {
    const io = init.io;
    const gpa = init.gpa;

    const args = init.minimal.args.toSlice(gpa) catch |err| {
        printStderr(io, gpa, "enforcer: cannot read arguments: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer gpa.free(args);

    if (args.len < 2) {
        usage(io, Io.File.stderr());
        return 1;
    }

    const verb = args[1];
    if (std.mem.eql(u8, verb, "--help") or std.mem.eql(u8, verb, "-h")) {
        usage(io, Io.File.stdout());
        return 0;
    }
    if (std.mem.eql(u8, verb, "hook")) return hook.run(io, gpa);
    if (std.mem.eql(u8, verb, "on")) return toggle(init, .install);
    if (std.mem.eql(u8, verb, "off")) return toggle(init, .uninstall);

    usage(io, Io.File.stderr());
    return 1;
}
