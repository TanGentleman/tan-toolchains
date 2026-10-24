//! Locate a Zig installation and read its `zig env` report.
//!
//! There is no network access and no bundled docs anywhere in zigpeek: every
//! command reads the `lib/` of a compiler that is already installed. This
//! module is the only place that knows how to find that compiler.

const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Checked in order before falling back to `zig` on PATH.
pub const bin_env_vars = [_][]const u8{ "ZIGPEEK_ZIG", "ZIG" };

/// Env var that pins a stdlib root instead of discovering one.
pub const lib_dir_env = "ZIGPEEK_LIB_DIR";

/// `--lib-dir zig` / `--lib-dir auto` mean "discover the compiler".
pub const auto_sentinels = [_][]const u8{ "zig", "auto" };

const exe_suffix = if (builtin.os.tag == .windows) ".exe" else "";

/// Parsed `zig env` output, reduced to the fields zigpeek uses.
pub const Env = struct {
    zig_exe: []const u8,
    lib_dir: []const u8,
    std_dir: []const u8,
    version: []const u8,
};

/// What we found before running anything.
pub const Discovery = struct {
    /// Value from `--zig` / `$ZIGPEEK_ZIG` / `$ZIG`, if any.
    configured: ?[]const u8 = null,
    /// Absolute path, when the configured value (or `zig` on PATH) exists.
    resolved: ?[]const u8 = null,

    pub fn exe(self: Discovery) ?[]const u8 {
        return self.resolved orelse self.configured;
    }
};

pub const FailureKind = enum { spawn_failed, bad_exit, bad_output };

pub const Failure = struct {
    kind: FailureKind,
    message: []const u8,
    stderr: []const u8 = "",
};

pub const Probe = union(enum) {
    ok: Env,
    failed: Failure,
};

pub fn isAutoSentinel(value: []const u8) bool {
    for (auto_sentinels) |sentinel| {
        if (std.mem.eql(u8, value, sentinel)) return true;
    }
    return false;
}

/// `--zig` beats `$ZIGPEEK_ZIG`, which beats `$ZIG`, which beats PATH.
pub fn discover(
    arena: Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    cli_value: ?[]const u8,
) Discovery {
    if (cli_value) |value| {
        if (value.len != 0) return discoverOne(arena, io, environ, value);
    }
    for (bin_env_vars) |key| {
        if (environ.get(key)) |value| {
            if (value.len != 0) return discoverOne(arena, io, environ, value);
        }
    }
    return .{ .resolved = findOnPath(arena, io, environ, "zig") };
}

fn discoverOne(
    arena: Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    value: []const u8,
) Discovery {
    return .{
        .configured = value,
        .resolved = resolveExecutable(arena, io, environ, value),
    };
}

/// Resolve a user-supplied executable: a path is used as-is, a bare name is
/// searched on PATH.
pub fn resolveExecutable(
    arena: Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    value: []const u8,
) ?[]const u8 {
    if (hasPathSeparator(value)) {
        const abs = absolute(arena, io, value) catch return null;
        return if (isExecutable(io, abs)) abs else null;
    }
    return findOnPath(arena, io, environ, value);
}

pub fn findOnPath(
    arena: Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    name: []const u8,
) ?[]const u8 {
    const path_env = environ.get("PATH") orelse environ.get("Path") orelse return null;
    const with_suffix = std.fmt.allocPrint(arena, "{s}{s}", .{ name, exe_suffix }) catch return null;

    var dirs = std.mem.splitScalar(u8, path_env, std.fs.path.delimiter);
    while (dirs.next()) |dir| {
        if (dir.len == 0) continue;
        const candidate = std.fs.path.join(arena, &.{ dir, with_suffix }) catch return null;
        const abs = absolute(arena, io, candidate) catch continue;
        if (isExecutable(io, abs)) return abs;
    }
    return null;
}

/// `--lib-dir` beats `$ZIGPEEK_LIB_DIR`. Sentinels are reported as absent so
/// callers fall back to compiler discovery.
pub fn libDirOverride(cli_value: ?[]const u8, environ: *const std.process.Environ.Map) ?[]const u8 {
    const raw = cli_value orelse environ.get(lib_dir_env) orelse return null;
    if (raw.len == 0) return null;
    if (isAutoSentinel(raw)) return null;
    return raw;
}

/// Run `<exe> env` and parse it. Never returns an error for a broken compiler:
/// callers want to render the failure, not crash.
pub fn probe(
    arena: Allocator,
    gpa: Allocator,
    io: Io,
    exe: []const u8,
) error{OutOfMemory}!Probe {
    const result = std.process.run(gpa, io, .{
        .argv = &.{ exe, "env" },
        .stdout_limit = .limited(8 << 20),
        .stderr_limit = .limited(1 << 20),
        .timeout = .{ .duration = .{
            .raw = .{ .nanoseconds = 15 * std.time.ns_per_s },
            .clock = .awake,
        } },
    }) catch |err| return failed(arena, .spawn_failed, "could not run `{s} env`: {t}", .{ exe, err });

    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    if (!result.term.success()) {
        return failed(arena, .bad_exit, "`{s} env` did not exit cleanly: {t}", .{ exe, result.term });
    }

    const env = parseEnvZon(arena, gpa, result.stdout) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidZigEnvZon => return .{ .failed = .{
            .kind = .bad_output,
            .message = try std.fmt.allocPrint(arena, "`{s} env` printed unparseable output", .{exe}),
            .stderr = try arena.dupe(u8, std.mem.trim(u8, result.stderr, " \t\r\n")),
        } },
    };
    return .{ .ok = env };
}

fn failed(
    arena: Allocator,
    kind: FailureKind,
    comptime fmt: []const u8,
    args: anytype,
) error{OutOfMemory}!Probe {
    return .{ .failed = .{
        .kind = kind,
        .message = try std.fmt.allocPrint(arena, fmt, args),
    } };
}

/// Parse the ZON document printed by `zig env`.
///
/// Unknown fields are ignored on purpose: `zig env` grows fields over time
/// (`.target`, `.env`, ...) and none of them matter here.
pub fn parseEnvZon(
    arena: Allocator,
    gpa: Allocator,
    source: []const u8,
) error{ OutOfMemory, InvalidZigEnvZon }!Env {
    const trimmed = std.mem.trim(u8, source, " \t\r\n");
    const sentinel = try arena.dupeSentinel(u8, trimmed, 0);

    const Raw = struct {
        zig_exe: []const u8 = "",
        lib_dir: []const u8 = "",
        std_dir: []const u8 = "",
        version: []const u8 = "",
    };

    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const raw = std.zon.parse.fromSlice(Raw, .{
        .gpa = gpa,
        .arena = arena,
        .source = sentinel,
        .diagnostics = &diagnostics,
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseZon => return error.InvalidZigEnvZon,
    };

    if (raw.lib_dir.len == 0) return error.InvalidZigEnvZon;

    const std_dir = if (raw.std_dir.len != 0)
        raw.std_dir
    else
        try std.fs.path.join(arena, &.{ raw.lib_dir, "std" });

    return .{
        .zig_exe = raw.zig_exe,
        .lib_dir = raw.lib_dir,
        .std_dir = std_dir,
        .version = raw.version,
    };
}

pub fn pathExists(arena: Allocator, io: Io, path: []const u8) bool {
    const abs = absolute(arena, io, path) catch return false;
    std.Io.Dir.accessAbsolute(io, abs, .{ .read = true }) catch return false;
    return true;
}

/// Look for the langref HTML that ships next to a compiler.
///
/// Accepts `<prefix>/lib`, `<prefix>/lib/std`, or `<prefix>` and checks the
/// obvious `doc/langref.html` locations.
pub fn findLangref(arena: Allocator, io: Io, lib_or_std: []const u8) ?[]const u8 {
    var base: []const u8 = lib_or_std;
    var depth: usize = 0;
    while (depth <= 2) : (depth += 1) {
        const candidate = std.fs.path.join(arena, &.{ base, "doc", "langref.html" }) catch return null;
        if (pathExists(arena, io, candidate)) return candidate;
        base = std.fs.path.dirname(base) orelse return null;
    }
    return null;
}

/// Lexical absolutization against the process cwd. 0.17's
/// `std.fs.path.resolveAlloc` no longer prepends the cwd on its own.
fn absolute(arena: Allocator, io: Io, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) return path;
    const cwd = try std.process.currentPathAlloc(io, arena);
    return std.fs.path.resolveAlloc(arena, &.{ cwd, path });
}

fn hasPathSeparator(value: []const u8) bool {
    return std.mem.indexOfAny(u8, value, "/\\") != null;
}

fn isExecutable(io: Io, abs_path: []const u8) bool {
    // Windows has no execute bit; existence is the best available signal.
    const options: std.Io.Dir.AccessOptions = if (builtin.os.tag == .windows)
        .{ .read = true }
    else
        .{ .execute = true };
    std.Io.Dir.accessAbsolute(io, abs_path, options) catch return false;
    return true;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "parseEnvZon: real zig 0.17 output, unknown fields ignored" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const source =
        \\.{
        \\    .zig_exe = "/opt/zig-aarch64-linux-0.17.0/zig",
        \\    .lib_dir = "/opt/zig-aarch64-linux-0.17.0/lib",
        \\    .std_dir = "/opt/zig-aarch64-linux-0.17.0/lib/std",
        \\    .global_cache_dir = "/root/.cache/zig",
        \\    .version = "0.17.0",
        \\    .target = "aarch64-linux.6.18.15...6.18.15-gnu.2.36",
        \\    .env = .{
        \\        .ZIG_GLOBAL_CACHE_DIR = null,
        \\        .HOME = "/root",
        \\    },
        \\}
    ;

    const env = try parseEnvZon(arena, testing.allocator, source);
    try testing.expectEqualStrings("/opt/zig-aarch64-linux-0.17.0/zig", env.zig_exe);
    try testing.expectEqualStrings("/opt/zig-aarch64-linux-0.17.0/lib", env.lib_dir);
    try testing.expectEqualStrings("/opt/zig-aarch64-linux-0.17.0/lib/std", env.std_dir);
    try testing.expectEqualStrings("0.17.0", env.version);
}

test "parseEnvZon: derives std_dir when the field is absent" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const env = try parseEnvZon(
        arena,
        testing.allocator,
        \\.{ .lib_dir = "/z/lib", .version = "0.16.0" }
        ,
    );
    const expected_std_dir = try std.fs.path.join(arena, &.{ "/z/lib", "std" });
    try testing.expectEqualStrings(expected_std_dir, env.std_dir);
    try testing.expectEqualStrings("", env.zig_exe);
}

test "parseEnvZon: rejects output without a lib_dir" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectError(
        error.InvalidZigEnvZon,
        parseEnvZon(arena_state.allocator(), testing.allocator, ".{ .version = \"0.17.0\" }"),
    );
}

test "isAutoSentinel" {
    try testing.expect(isAutoSentinel("zig"));
    try testing.expect(isAutoSentinel("auto"));
    try testing.expect(!isAutoSentinel("/opt/zig/lib"));
}

test "libDirOverride: sentinels and empties mean discover" {
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();

    try testing.expectEqual(@as(?[]const u8, null), libDirOverride(null, &environ));
    try testing.expectEqual(@as(?[]const u8, null), libDirOverride("", &environ));
    try testing.expectEqual(@as(?[]const u8, null), libDirOverride("zig", &environ));
    try testing.expectEqualStrings("/z/std", libDirOverride("/z/std", &environ).?);

    try environ.put("ZIGPEEK_LIB_DIR", "/from/env");
    try testing.expectEqualStrings("/from/env", libDirOverride(null, &environ).?);
    try testing.expectEqualStrings("/from/cli", libDirOverride("/from/cli", &environ).?);
}
