//! Argument parsing and command dispatch.
//!
//! Exit codes follow the Python tool's contract:
//!   0 — success
//!   1 — bad input (unknown command, missing argument, empty query)
//!   2 — the local Zig installation could not be used (network is never involved)

const std = @import("std");
const info_cmd = @import("info.zig");
const version = @import("version.zig").version;

const Io = std.Io;

pub const main_usage =
    \\Usage: zigpeek <command> [options]
    \\
    \\Commands:
    \\  info      Show how to use zigpeek, resolved binaries, and the active Zig
    \\
    \\Options:
    \\  -h, --help       Show this help
    \\  -V, --version    Show the zigpeek version
    \\
    \\Run `zigpeek info` to get started.
    \\
;

pub const info_usage =
    \\Usage: zigpeek info [options]
    \\
    \\Print a short when/how blurb, the `zigpeek` and `zig` binaries, and the
    \\Zig version + stdlib directory that docs will be read from.
    \\
    \\Options:
    \\  --zig PATH       Zig executable to inspect (default: $ZIGPEEK_ZIG,
    \\                   then $ZIG, then `zig` on PATH)
    \\  --lib-dir PATH   Stdlib root (Zig lib/ or std/) to report instead of the
    \\                   compiler's own (default: $ZIGPEEK_LIB_DIR)
    \\  -h, --help       Show this help
    \\
;

pub fn run(init: std.process.Init) u8 {
    const io = init.io;
    const arena = init.arena.allocator();

    const argv = init.minimal.args.toSlice(arena) catch {
        return fail(io, 1, "could not read command line arguments", .{});
    };
    const args = if (argv.len > 1) argv[1..] else argv[0..0];

    if (args.len == 0) {
        writeErr(io, main_usage);
        return 1;
    }

    const command = args[0];
    if (is(command, "-h") or is(command, "--help") or is(command, "help")) {
        writeOut(io, main_usage);
        return 0;
    }
    if (is(command, "-V") or is(command, "--version")) {
        var buf: [128]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "zigpeek {s}\n", .{version}) catch unreachable;
        writeOut(io, line);
        return 0;
    }
    if (is(command, "info")) {
        return runInfo(init, args[1..]);
    }

    return fail(io, 1, "unknown command '{s}'\n\nRun `zigpeek --help`.", .{command});
}

fn runInfo(init: std.process.Init, args: []const [:0]const u8) u8 {
    const io = init.io;
    var options: info_cmd.Options = .{};

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (is(arg, "-h") or is(arg, "--help")) {
            writeOut(io, info_usage);
            return 0;
        }

        switch (optionValue(arg, "--zig", args, &i)) {
            .no => {},
            .missing_value => return fail(io, 1, "option '--zig' requires a value", .{}),
            .value => |value| options.zig = value,
        }
        switch (optionValue(arg, "--lib-dir", args, &i)) {
            .no => {},
            .missing_value => return fail(io, 1, "option '--lib-dir' requires a value", .{}),
            .value => |value| options.lib_dir = value,
        }

        if (!is(arg, "--zig") and !is(arg, "--lib-dir") and
            !std.mem.startsWith(u8, arg, "--zig=") and
            !std.mem.startsWith(u8, arg, "--lib-dir="))
        {
            return fail(io, 1, "unknown option '{s}' for `zigpeek info`\n\n{s}", .{ arg, info_usage });
        }
    }

    const report = info_cmd.collect(
        init.arena.allocator(),
        init.gpa,
        io,
        init.environ_map,
        options,
    ) catch return fail(io, 1, "out of memory", .{});

    var aw: std.Io.Writer.Allocating = .init(init.gpa);
    defer aw.deinit();
    info_cmd.render(&aw.writer, report) catch return fail(io, 1, "out of memory", .{});
    writeOut(io, aw.written());
    return 0;
}

const OptionMatch = union(enum) {
    no,
    missing_value,
    value: []const u8,
};

/// Accepts both `--name value` and `--name=value`.
fn optionValue(
    arg: []const u8,
    name: []const u8,
    args: []const [:0]const u8,
    index: *usize,
) OptionMatch {
    if (std.mem.eql(u8, arg, name)) {
        if (index.* + 1 >= args.len) return .missing_value;
        index.* += 1;
        return .{ .value = args[index.*] };
    }
    if (arg.len > name.len and
        std.mem.startsWith(u8, arg, name) and
        arg[name.len] == '=')
    {
        return .{ .value = arg[name.len + 1 ..] };
    }
    return .no;
}

fn is(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn writeOut(io: Io, text: []const u8) void {
    Io.File.stdout().writeStreamingAll(io, text) catch {};
}

fn writeErr(io: Io, text: []const u8) void {
    Io.File.stderr().writeStreamingAll(io, text) catch {};
}

fn fail(io: Io, code: u8, comptime fmt: []const u8, args: anytype) u8 {
    var buf: [8192]u8 = undefined;
    const message = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch fmt;
    writeErr(io, message);
    return code;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "optionValue: space form" {
    const args = [_][:0]const u8{ "--zig", "/opt/zig" };
    var i: usize = 0;
    const got = optionValue("--zig", "--zig", &args, &i);
    try testing.expectEqualStrings("/opt/zig", got.value);
    try testing.expectEqual(@as(usize, 1), i);
}

test "optionValue: equals form" {
    const args = [_][:0]const u8{"--lib-dir=/z/lib"};
    var i: usize = 0;
    const got = optionValue("--lib-dir=/z/lib", "--lib-dir", &args, &i);
    try testing.expectEqualStrings("/z/lib", got.value);
    try testing.expectEqual(@as(usize, 0), i);
}

test "optionValue: missing value" {
    const args = [_][:0]const u8{"--zig"};
    var i: usize = 0;
    try testing.expect(optionValue("--zig", "--zig", &args, &i) == .missing_value);
}

test "optionValue: not this option" {
    const args = [_][:0]const u8{"--other"};
    var i: usize = 0;
    try testing.expect(optionValue("--other", "--zig", &args, &i) == .no);
    try testing.expect(optionValue("--ziggy", "--zig", &args, &i) == .no);
}

test "main usage lists the implemented command" {
    try testing.expect(std.mem.indexOf(u8, main_usage, "info") != null);
    try testing.expect(std.mem.indexOf(u8, info_usage, "--lib-dir") != null);
    try testing.expect(std.mem.indexOf(u8, info_usage, "--zig") != null);
}
