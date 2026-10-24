//! `zigpeek info`: what this tool is for, which binaries it resolved, and
//! where the docs will come from.

const std = @import("std");
const zig_env = @import("zig_env.zig");
const version = @import("version.zig").version;

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const USAGE_GUIDE =
    \\Look up Zig stdlib and @-builtins before guessing.
    \\
    \\search when you don't know the name
    \\get when you do
    \\get --source-file when you need the body
    \\builtins list / get for @-functions
    \\batch if you have more than two lookups
    \\
    \\FQNs follow the module graph, not the file layout: std.Io.Dir.openFile.
    \\
    \\zigpeek --help lists the rest.
;

pub const Options = struct {
    zig: ?[]const u8 = null,
    lib_dir: ?[]const u8 = null,
};

pub const ZigStatus = enum { ok, unusable, missing };

pub const SourceKind = enum { compiler, override, none };

pub const Report = struct {
    zigpeek_exe: ?[]const u8 = null,
    zig_exe: ?[]const u8 = null,
    zig_status: ZigStatus = .missing,
    zig_version: ?[]const u8 = null,
    zig_lib_dir: ?[]const u8 = null,
    zig_std_dir: ?[]const u8 = null,
    /// Why the configured compiler could not be used, when `status` is unusable.
    zig_problem: ?[]const u8 = null,

    docs_version: ?[]const u8 = null,
    docs_version_note: []const u8 = "no local zig",
    source_kind: SourceKind = .none,
    source_path: ?[]const u8 = null,
    source_present: bool = false,
    langref_path: ?[]const u8 = null,
    langref_present: bool = false,
};

pub fn collect(
    arena: Allocator,
    gpa: Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    options: Options,
) error{OutOfMemory}!Report {
    var report: Report = .{
        .zigpeek_exe = std.process.executablePathAlloc(io, arena) catch null,
    };

    const discovery = zig_env.discover(arena, io, environ, options.zig);
    const lib_override = zig_env.libDirOverride(options.lib_dir, environ);

    var compiler: ?zig_env.Env = null;
    if (discovery.exe()) |exe| {
        report.zig_exe = discovery.resolved orelse exe;
        switch (try zig_env.probe(arena, gpa, io, exe)) {
            .ok => |env| compiler = env,
            .failed => |failure| {
                report.zig_status = .unusable;
                report.zig_problem = failure.message;
            },
        }
    }

    if (compiler) |env| {
        report.zig_status = .ok;
        report.zig_version = env.version;
        report.zig_lib_dir = env.lib_dir;
        report.zig_std_dir = env.std_dir;
    }

    if (lib_override) |path| {
        report.source_kind = .override;
        report.source_path = path;
        report.source_present = zig_env.pathExists(arena, io, path);
        if (compiler) |env| {
            report.docs_version = env.version;
            report.docs_version_note = "local zig; stdlib overridden";
        } else {
            report.docs_version_note = "overridden; no local zig";
        }
    } else if (compiler) |env| {
        report.source_kind = .compiler;
        report.source_path = env.std_dir;
        report.source_present = zig_env.pathExists(arena, io, env.std_dir);
        report.docs_version = env.version;
        report.docs_version_note = "from local zig";
    } else {
        report.docs_version_note = switch (report.zig_status) {
            .unusable => "compiler unusable",
            .missing, .ok => "no local zig",
        };
    }

    const langref_base = if (lib_override) |path|
        path
    else if (compiler) |env|
        env.lib_dir
    else
        null;
    if (langref_base) |base| {
        if (zig_env.findLangref(arena, io, base)) |path| {
            report.langref_path = path;
            report.langref_present = true;
        } else if (report.zig_status == .ok) {
            // Only guess the expected location for a compiler we could read;
            // for a bogus --lib-dir a fabricated path is just noise.
            report.langref_path = std.fs.path.join(arena, &.{ base, "doc", "langref.html" }) catch null;
        }
    }

    return report;
}

pub fn render(w: *std.Io.Writer, report: Report) std.Io.Writer.Error!void {
    try w.writeAll(USAGE_GUIDE);
    try w.writeAll("\n\n");

    try w.print(
        \\zigpeek:
        \\  version:  {s}
        \\  binary:   {s}
        \\
        \\
    , .{ version, report.zigpeek_exe orelse "(unknown)" });

    try w.writeAll("zig:\n");
    switch (report.zig_status) {
        .ok => try w.print(
            \\  binary:   {s}
            \\  version:  {s}
            \\  lib/:     {s}
            \\  std/:     {s}
            \\
        , .{
            report.zig_exe orelse "(unknown)",
            report.zig_version orelse "(unknown)",
            report.zig_lib_dir orelse "(unknown)",
            report.zig_std_dir orelse "(unknown)",
        }),
        .unusable => try w.print(
            \\  binary:   {s}
            \\  version:  (unusable)
            \\  lib/:     (unknown)
            \\  std/:     (unknown)
            \\  problem:  {s}
            \\
        , .{
            report.zig_exe orelse "(unknown)",
            report.zig_problem orelse "`zig env` failed",
        }),
        .missing => try w.writeAll(
            \\  binary:   (not found; checked $ZIGPEEK_ZIG, $ZIG, then PATH)
            \\  version:  (none)
            \\  lib/:     (none)
            \\  std/:     (none)
            \\
        ),
    }

    try w.writeAll("\ndocs:\n");
    try w.print("  version:  {s}  ({s})\n", .{
        report.docs_version orelse "(unknown)",
        report.docs_version_note,
    });

    switch (report.source_kind) {
        .compiler => try w.print("  source:   local compiler lib/\n            {s} ({s})\n", .{
            report.source_path orelse "(unknown)",
            presentLabel(report.source_present),
        }),
        .override => try w.print("  source:   --lib-dir / $ZIGPEEK_LIB_DIR\n            {s} ({s})\n", .{
            report.source_path orelse "(unknown)",
            presentLabel(report.source_present),
        }),
        .none => if (report.zig_status == .unusable)
            try w.writeAll("  source:   (none; compiler unusable)\n")
        else
            try w.writeAll("  source:   (none; no zig installation found)\n"),
    }

    if (report.langref_path) |path| {
        try w.print("  builtins: {s} ({s})\n", .{ path, presentLabel(report.langref_present) });
    } else {
        try w.writeAll("  builtins: (none)\n");
    }

    if (report.zig_status == .missing) {
        try w.writeAll(
            \\
            \\zigpeek reads docs straight from a compiler's lib/. Install Zig, or
            \\point at one with --zig / $ZIG / $ZIGPEEK_ZIG or --lib-dir.
            \\
        );
    }
}

fn presentLabel(present: bool) []const u8 {
    return if (present) "found" else "missing";
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn renderToOwned(allocator: Allocator, report: Report) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try render(&aw.writer, report);
    return allocator.dupe(u8, aw.written());
}

test "usage guide keeps the agent-facing contract" {
    const guide = USAGE_GUIDE;
    try testing.expect(std.mem.startsWith(u8, guide, "Look up Zig stdlib"));
    for ([_][]const u8{
        "search",                       "get --source-file", "builtins list / get", "batch", "zigpeek --help",
        "FQNs follow the module graph",
    }) |needle| {
        try testing.expect(std.mem.indexOf(u8, guide, needle) != null);
    }
    // The guide is plain text, not markdown: `info` output is pasted into
    // terminals, and headings/table pipes just add noise.
    try testing.expect(std.mem.indexOf(u8, guide, "##") == null);
    try testing.expect(std.mem.indexOf(u8, guide, "|") == null);
}

test "render: working local compiler" {
    const report: Report = .{
        .zigpeek_exe = "/usr/local/bin/zigpeek",
        .zig_exe = "/opt/zig/zig",
        .zig_status = .ok,
        .zig_version = "0.17.0",
        .zig_lib_dir = "/opt/zig/lib",
        .zig_std_dir = "/opt/zig/lib/std",
        .docs_version = "0.17.0",
        .docs_version_note = "from local zig",
        .source_kind = .compiler,
        .source_path = "/opt/zig/lib/std",
        .source_present = true,
        .langref_path = "/opt/zig/doc/langref.html",
        .langref_present = true,
    };

    const out = try renderToOwned(testing.allocator, report);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "zigpeek:\n  version:  0.6.0\n  binary:   /usr/local/bin/zigpeek") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\nzig:\n  binary:   /opt/zig/zig\n  version:  0.17.0\n  lib/:     /opt/zig/lib\n  std/:     /opt/zig/lib/std\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\ndocs:\n  version:  0.17.0  (from local zig)\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "  source:   local compiler lib/\n            /opt/zig/lib/std (found)\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "  builtins: /opt/zig/doc/langref.html (found)\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "unusable") == null);
    try testing.expect(std.mem.indexOf(u8, out, "Install Zig") == null);
}

test "render: missing compiler is reported, not fatal" {
    const report: Report = .{ .zigpeek_exe = null };

    const out = try renderToOwned(testing.allocator, report);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "  binary:   (unknown)") != null);
    try testing.expect(std.mem.indexOf(u8, out, "  binary:   (not found; checked $ZIGPEEK_ZIG, $ZIG, then PATH)") != null);
    try testing.expect(std.mem.indexOf(u8, out, "  source:   (none; no zig installation found)") != null);
    try testing.expect(std.mem.indexOf(u8, out, "  builtins: (none)") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Install Zig") != null);
}

test "render: unusable compiler shows the probe problem" {
    const report: Report = .{
        .zig_exe = "/broken/zig",
        .zig_status = .unusable,
        .zig_problem = "`/broken/zig env` did not exit cleanly: exited=1",
    };

    const out = try renderToOwned(testing.allocator, report);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "  binary:   /broken/zig\n  version:  (unusable)") != null);
    try testing.expect(std.mem.indexOf(u8, out, "did not exit cleanly") != null);
    try testing.expect(std.mem.indexOf(u8, out, "  source:   (none; compiler unusable)") != null);
    try testing.expect(std.mem.indexOf(u8, out, "no zig installation found") == null);
}

test "render: lib override with a working compiler" {
    const report: Report = .{
        .zig_exe = "/opt/zig/zig",
        .zig_status = .ok,
        .zig_version = "0.17.0",
        .zig_lib_dir = "/opt/zig/lib",
        .zig_std_dir = "/opt/zig/lib/std",
        .docs_version = "0.17.0",
        .docs_version_note = "local zig; stdlib overridden",
        .source_kind = .override,
        .source_path = "/checkout/zig/lib",
        .source_present = false,
    };

    const out = try renderToOwned(testing.allocator, report);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "  source:   --lib-dir / $ZIGPEEK_LIB_DIR\n            /checkout/zig/lib (missing)\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "stdlib overridden") != null);
}
