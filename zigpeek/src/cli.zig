//! Argument parsing and command dispatch.
//!
//! Exit codes follow the Python tool's contract:
//!   0 — success
//!   1 — bad input (unknown command, missing argument, empty query)
//!   2 — the local Zig installation could not be used (network is never involved)

const std = @import("std");
const info_cmd = @import("info.zig");
const builtins_cmd = @import("builtins.zig");
const get_cmd = @import("get.zig");
const stdlib = @import("stdlib.zig");
const zig_env = @import("zig_env.zig");
const version = @import("version.zig").version;

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const main_usage =
    \\Usage: zigpeek <command> [options]
    \\
    \\Commands:
    \\  info      Show how to use zigpeek, resolved binaries, and the active Zig
    \\  search    Search the standard library for a declaration name
    \\  get       Show docs, signature, and source for a fully-qualified name
    \\  builtins  List or look up @-builtin functions from the local langref
    \\  batch     Run many lookups in one process, one command per line
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

pub const search_usage =
    \\Usage: zigpeek search <query> [options]
    \\
    \\Search declarations in the stdlib of the active Zig compiler. Queries with
    \\no uppercase letters are case-insensitive; a query containing `.` matches
    \\whole fully-qualified names.
    \\
    \\Options:
    \\  --limit N        Maximum results to show (default 20)
    \\  --zig PATH       Zig executable to read docs from
    \\  --lib-dir PATH   Stdlib root (Zig lib/ or std/)
    \\  -h, --help       Show this help
    \\
;

pub const get_usage =
    \\Usage: zigpeek get <fqn> [options]
    \\
    \\Print docs, signature, members, and source for one declaration. The `std.`
    \\prefix may be omitted. Use --source-file to print the whole defining file.
    \\
    \\Options:
    \\  --source-file    Print the entire source file for the item
    \\  --zig PATH       Zig executable to read docs from
    \\  --lib-dir PATH   Stdlib root (Zig lib/ or std/)
    \\  -h, --help       Show this help
    \\
;

const SourceOptions = struct {
    zig: ?[]const u8 = null,
    lib_dir: ?[]const u8 = null,
};

pub fn run(init: std.process.Init) u8 {
    const arena = init.arena.allocator();
    const argv = init.minimal.args.toSlice(arena) catch {
        return fail(init.io, 1, "could not read command line arguments", .{});
    };
    var ctx: Ctx = .{};
    defer ctx.deinit();
    return dispatch(init, if (argv.len > 1) argv[1..] else argv[0..0], &ctx);
}

fn dispatch(init: std.process.Init, args: []const [:0]const u8, ctx: *Ctx) u8 {
    const io = init.io;

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
    if (is(command, "info")) return runInfo(init, args[1..]);
    if (is(command, "search")) return runSearch(init, args[1..], ctx);
    if (is(command, "get")) return runGet(init, args[1..], ctx);
    if (is(command, "builtins")) return runBuiltins(init, args[1..]);
    if (is(command, "batch")) return runBatch(init, args[1..]);

    return fail(io, 1, "unknown command '{s}'\n\nRun `zigpeek --help`.", .{command});
}

fn runInfo(init: std.process.Init, args: []const [:0]const u8) u8 {
    const io = init.io;
    var source: SourceOptions = .{};

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (is(arg, "-h") or is(arg, "--help")) {
            writeOut(io, info_usage);
            return 0;
        }

        var matched = false;
        switch (optionValue(arg, "--zig", args, &i)) {
            .no => {},
            .missing_value => return fail(io, 1, "option '--zig' requires a value", .{}),
            .value => |value| {
                source.zig = value;
                matched = true;
            },
        }
        switch (optionValue(arg, "--lib-dir", args, &i)) {
            .no => {},
            .missing_value => return fail(io, 1, "option '--lib-dir' requires a value", .{}),
            .value => |value| {
                source.lib_dir = value;
                matched = true;
            },
        }
        if (matched) continue;

        if (isOption(arg)) {
            return fail(io, 1, "unknown option '{s}' for `zigpeek info`\n\n{s}", .{ arg, info_usage });
        }
        return fail(io, 1, "`zigpeek info` takes no arguments, got '{s}'", .{arg});
    }

    const report = info_cmd.collect(
        init.arena.allocator(),
        init.gpa,
        io,
        init.environ_map,
        .{ .zig = source.zig, .lib_dir = source.lib_dir },
    ) catch return fail(io, 1, "out of memory", .{});

    var aw: std.Io.Writer.Allocating = .init(init.gpa);
    defer aw.deinit();
    info_cmd.render(&aw.writer, report) catch return fail(io, 1, "out of memory", .{});
    writeOut(io, aw.written());
    return 0;
}

fn runSearch(init: std.process.Init, args: []const [:0]const u8, ctx: *Ctx) u8 {
    const io = init.io;
    const arena = init.arena.allocator();

    var source: SourceOptions = .{};
    var limit: usize = 20;
    var query: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (is(arg, "-h") or is(arg, "--help")) {
            writeOut(io, search_usage);
            return 0;
        }

        var matched = false;
        switch (optionValue(arg, "--zig", args, &i)) {
            .no => {},
            .missing_value => return fail(io, 1, "option '--zig' requires a value", .{}),
            .value => |value| {
                source.zig = value;
                matched = true;
            },
        }
        switch (optionValue(arg, "--lib-dir", args, &i)) {
            .no => {},
            .missing_value => return fail(io, 1, "option '--lib-dir' requires a value", .{}),
            .value => |value| {
                source.lib_dir = value;
                matched = true;
            },
        }
        switch (optionValue(arg, "--limit", args, &i)) {
            .no => {},
            .missing_value => return fail(io, 1, "option '--limit' requires a value", .{}),
            .value => |value| {
                limit = std.fmt.parseInt(usize, value, 10) catch
                    return fail(io, 1, "invalid --limit '{s}': expected a positive integer", .{value});
                matched = true;
            },
        }
        if (matched) continue;

        if (isOption(arg)) {
            return fail(io, 1, "unknown option '{s}' for `zigpeek search`\n\n{s}", .{ arg, search_usage });
        }
        if (query != null) {
            return fail(io, 1, "unexpected argument '{s}'; quote multi-word queries", .{arg});
        }
        query = arg;
    }

    if (query == null or query.?.len == 0) {
        return fail(io, 1, "query cannot be empty\n\n{s}", .{search_usage});
    }
    if (limit == 0) return fail(io, 1, "--limit must be at least 1", .{});

    const std_dir = switch (openStd(init, arena, source)) {
        .ok => |ok| ok.std_dir,
        .out_of_memory => return fail(io, 1, "out of memory", .{}),
        .no_zig => return fail(io, 2, no_zig_message, .{}),
        .bad_lib_dir => |raw| return fail(io, 2, bad_lib_dir_message, .{raw}),
        .probe_failed => |failure| {
            if (failure.stderr.len != 0) {
                return fail(io, 2, "{s}\n{s}", .{ failure.message, failure.stderr });
            }
            return fail(io, 2, "{s}", .{failure.message});
        },
    };

    const index = ctx.indexFor(init, arena, std_dir) catch |err| switch (err) {
        error.StdLibNotFound => return fail(io, 2, bad_std_dir_message, .{std_dir}),
        error.OutOfMemory => return fail(io, 1, "out of memory", .{}),
    };

    if (index.skipped_files != 0) {
        var buf: [160]u8 = undefined;
        const warning = std.fmt.bufPrint(
            &buf,
            "warning: skipped {d} unparseable stdlib file(s)\n",
            .{index.skipped_files},
        ) catch "";
        writeErr(io, warning);
    }

    const results = stdlib.search(arena, index, query.?, limit) catch
        return fail(io, 1, "out of memory", .{});

    var aw: std.Io.Writer.Allocating = .init(init.gpa);
    defer aw.deinit();
    stdlib.renderSearch(&aw.writer, results, query.?) catch
        return fail(io, 1, "out of memory", .{});
    writeOut(io, aw.written());
    writeOut(io, "\n");
    return 0;
}

fn runGet(init: std.process.Init, args: []const [:0]const u8, ctx: *Ctx) u8 {
    const io = init.io;
    const arena = init.arena.allocator();

    var source: SourceOptions = .{};
    var source_file = false;
    var fqn: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (is(arg, "-h") or is(arg, "--help")) {
            writeOut(io, get_usage);
            return 0;
        }
        if (is(arg, "--source-file")) {
            source_file = true;
            continue;
        }

        var matched = false;
        switch (optionValue(arg, "--zig", args, &i)) {
            .no => {},
            .missing_value => return fail(io, 1, "option '--zig' requires a value", .{}),
            .value => |value| {
                source.zig = value;
                matched = true;
            },
        }
        switch (optionValue(arg, "--lib-dir", args, &i)) {
            .no => {},
            .missing_value => return fail(io, 1, "option '--lib-dir' requires a value", .{}),
            .value => |value| {
                source.lib_dir = value;
                matched = true;
            },
        }
        if (matched) continue;

        if (isOption(arg)) {
            return fail(io, 1, "unknown option '{s}' for `zigpeek get`\n\n{s}", .{ arg, get_usage });
        }
        if (fqn != null) {
            return fail(io, 1, "unexpected argument '{s}'; pass one fully-qualified name", .{arg});
        }
        fqn = arg;
    }

    if (fqn == null or fqn.?.len == 0) {
        return fail(io, 1, "name cannot be empty\n\n{s}", .{get_usage});
    }

    const std_dir = switch (openStd(init, arena, source)) {
        .ok => |ok| ok.std_dir,
        .out_of_memory => return fail(io, 1, "out of memory", .{}),
        .no_zig => return fail(io, 2, no_zig_message, .{}),
        .bad_lib_dir => |raw| return fail(io, 2, bad_lib_dir_message, .{raw}),
        .probe_failed => |failure| {
            if (failure.stderr.len != 0) {
                return fail(io, 2, "{s}\n{s}", .{ failure.message, failure.stderr });
            }
            return fail(io, 2, "{s}", .{failure.message});
        },
    };

    const index = ctx.indexFor(init, arena, std_dir) catch |err| switch (err) {
        error.StdLibNotFound => return fail(io, 2, bad_std_dir_message, .{std_dir}),
        error.OutOfMemory => return fail(io, 1, "out of memory", .{}),
    };

    var aw: std.Io.Writer.Allocating = .init(init.gpa);
    defer aw.deinit();
    get_cmd.render(&aw.writer, arena, init.gpa, io, index, fqn.?, .{
        .source_file = source_file,
    }) catch |err| switch (err) {
        error.NotFound => return reportNotFound(init, arena, index, fqn.?),
        error.Unreadable => return fail(io, 2, "could not read the stdlib file for '{s}'", .{fqn.?}),
        error.Unparseable => return fail(io, 2, "could not parse the stdlib file for '{s}'", .{fqn.?}),
        error.OutOfMemory => return fail(io, 1, "out of memory", .{}),
        error.WriteFailed => return fail(io, 1, "could not format output", .{}),
    };

    writeOut(io, aw.written());
    writeOut(io, "\n");
    return 0;
}

fn reportNotFound(
    init: std.process.Init,
    arena: Allocator,
    index: *const stdlib.Index,
    fqn: []const u8,
) u8 {
    var aw: std.Io.Writer.Allocating = .init(init.gpa);
    defer aw.deinit();

    aw.writer.print("# Error\n\nDeclaration \"{s}\" not found.\n", .{fqn}) catch {};

    const leaf = if (std.mem.lastIndexOfScalar(u8, fqn, '.')) |dot| fqn[dot + 1 ..] else fqn;
    if (stdlib.search(arena, index, leaf, 5)) |results| {
        if (results.total != 0) {
            aw.writer.writeAll("\nDid you mean:\n") catch {};
            for (results.hits) |hit| {
                aw.writer.print("- {s}\n", .{hit.entry.fqn}) catch {};
            }
        }
    } else |_| {}

    writeErr(init.io, aw.written());
    return 1;
}

pub const builtins_usage =
    \\Usage: zigpeek builtins <list|get> [query] [options]
    \\
    \\Browse the `@`-builtin functions from the langref that ships inside the
    \\Zig installation (no network).
    \\
    \\Commands:
    \\  list             List every builtin with its signature
    \\  get <query>      Look up builtins by name or by words in their docs
    \\
    \\Options:
    \\  --zig PATH       Zig executable to read the langref from
    \\  --lib-dir PATH   Stdlib root (Zig lib/ or std/)
    \\  -h, --help       Show this help
    \\
;

fn runBuiltins(init: std.process.Init, args: []const [:0]const u8) u8 {
    const io = init.io;
    const arena = init.arena.allocator();

    if (args.len == 0) {
        writeErr(io, builtins_usage);
        return 1;
    }

    var source: SourceOptions = .{};
    var subcommand: ?[]const u8 = null;
    var query: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (is(arg, "-h") or is(arg, "--help")) {
            writeOut(io, builtins_usage);
            return 0;
        }

        var matched = false;
        switch (optionValue(arg, "--zig", args, &i)) {
            .no => {},
            .missing_value => return fail(io, 1, "option '--zig' requires a value", .{}),
            .value => |value| {
                source.zig = value;
                matched = true;
            },
        }
        switch (optionValue(arg, "--lib-dir", args, &i)) {
            .no => {},
            .missing_value => return fail(io, 1, "option '--lib-dir' requires a value", .{}),
            .value => |value| {
                source.lib_dir = value;
                matched = true;
            },
        }
        if (matched) continue;

        if (isOption(arg)) {
            return fail(io, 1, "unknown option '{s}' for `zigpeek builtins`\n\n{s}", .{ arg, builtins_usage });
        }
        if (subcommand == null) {
            subcommand = arg;
        } else if (query == null) {
            query = arg;
        } else {
            return fail(io, 1, "unexpected argument '{s}'; quote multi-word queries", .{arg});
        }
    }

    const sub = subcommand orelse return fail(io, 1, "missing builtins subcommand\n\n{s}", .{builtins_usage});
    var want_get = false;
    if (is(sub, "list")) {
        if (query != null) return fail(io, 1, "`builtins list` takes no query", .{});
    } else if (is(sub, "get")) {
        want_get = true;
        if (query == null or query.?.len == 0) {
            return fail(io, 1, "query cannot be empty\n\n{s}", .{builtins_usage});
        }
    } else {
        return fail(io, 1, "unknown builtins subcommand '{s}'\n\n{s}", .{ sub, builtins_usage });
    }

    const std_dir = switch (openStd(init, arena, source)) {
        .ok => |ok| ok.std_dir,
        .out_of_memory => return fail(io, 1, "out of memory", .{}),
        .no_zig => return fail(io, 2, no_zig_message, .{}),
        .bad_lib_dir => |raw| return fail(io, 2, bad_lib_dir_message, .{raw}),
        .probe_failed => |failure| {
            if (failure.stderr.len != 0) {
                return fail(io, 2, "{s}\n{s}", .{ failure.message, failure.stderr });
            }
            return fail(io, 2, "{s}", .{failure.message});
        },
    };

    const langref = builtins_cmd.findLangref(arena, io, std_dir) orelse
        return fail(io, 2, no_langref_message, .{std_dir});

    const html = readLangref(init.gpa, io, langref) catch |err| switch (err) {
        error.OutOfMemory => return fail(io, 1, "out of memory", .{}),
        else => return fail(io, 2, "could not read '{s}'", .{langref}),
    };
    defer init.gpa.free(html);

    const entries = builtins_cmd.parse(arena, html) catch |err| switch (err) {
        error.MissingSection => return fail(io, 2, "no Builtin Functions section in '{s}'", .{langref}),
        error.OutOfMemory => return fail(io, 1, "out of memory", .{}),
    };

    var aw: std.Io.Writer.Allocating = .init(init.gpa);
    defer aw.deinit();

    if (!want_get) {
        builtins_cmd.renderList(&aw.writer, entries, langref) catch
            return fail(io, 1, "out of memory", .{});
        writeOut(io, aw.written());
        writeOut(io, "\n");
        return 0;
    }

    const results = builtins_cmd.rank(arena, entries, query.?, 20) catch
        return fail(io, 1, "out of memory", .{});
    if (results.total == 0) {
        return fail(io, 1, "No builtin functions found matching \"{s}\".\nTry `zigpeek builtins list` to see all functions.", .{query.?});
    }
    builtins_cmd.renderGet(&aw.writer, results, query.?) catch
        return fail(io, 1, "out of memory", .{});
    writeOut(io, aw.written());
    writeOut(io, "\n");
    return 0;
}

fn readLangref(gpa: Allocator, io: Io, path: []const u8) ![]u8 {
    const dir_path = std.fs.path.dirname(path) orelse ".";
    var dir = try Io.Dir.openDirAbsolute(io, dir_path, .{});
    defer dir.close(io);
    return dir.readFileAlloc(io, std.fs.path.basename(path), gpa, .limited(16 << 20));
}

const no_langref_message =
    "this Zig installation does not ship doc/langref.html (looked next to '{s}').\n" ++
    "`zigpeek builtins` needs the compiler tarball's doc/ directory.";

// ---------------------------------------------------------------------------
// Batch mode
// ---------------------------------------------------------------------------

pub const batch_usage =
    \\Usage: zigpeek batch [-f FILE]
    \\
    \\Run one command per line, in one process, so the stdlib index is parsed
    \\only once. Blank lines and lines starting with `#` are skipped. Each
    \\result is framed with `===> <line>`. The exit code is the worst one seen.
    \\
    \\Options:
    \\  -f, --file PATH  Read commands from PATH instead of stdin
    \\  -h, --help       Show this help
    \\
;

/// Caches the parsed stdlib across batch lines. A plain `zigpeek` invocation
/// creates one and drops it; `batch` keeps it for the whole run.
const Ctx = struct {
    cached_std_dir: ?[]const u8 = null,
    cached_index: ?stdlib.Index = null,

    fn indexFor(
        self: *Ctx,
        init: std.process.Init,
        arena: Allocator,
        std_dir: []const u8,
    ) !*const stdlib.Index {
        if (self.cached_index) |*index| {
            if (self.cached_std_dir) |cached| {
                if (std.mem.eql(u8, cached, std_dir)) return index;
            }
            index.deinit();
            self.cached_index = null;
        }
        self.cached_index = try stdlib.build(init.gpa, init.io, std_dir);
        self.cached_std_dir = try arena.dupe(u8, std_dir);
        return &self.cached_index.?;
    }

    fn deinit(self: *Ctx) void {
        if (self.cached_index) |*index| index.deinit();
        self.cached_index = null;
    }
};

fn runBatch(init: std.process.Init, args: []const [:0]const u8) u8 {
    const io = init.io;
    const arena = init.arena.allocator();

    var file: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (is(arg, "-h") or is(arg, "--help")) {
            writeOut(io, batch_usage);
            return 0;
        }

        var matched = false;
        switch (optionValue(arg, "-f", args, &i)) {
            .no => {},
            .missing_value => return fail(io, 1, "option '-f' requires a value", .{}),
            .value => |value| {
                file = value;
                matched = true;
            },
        }
        switch (optionValue(arg, "--file", args, &i)) {
            .no => {},
            .missing_value => return fail(io, 1, "option '--file' requires a value", .{}),
            .value => |value| {
                file = value;
                matched = true;
            },
        }
        if (matched) continue;

        return fail(io, 1, "unknown argument '{s}' for `zigpeek batch`\n\n{s}", .{ arg, batch_usage });
    }

    const text = if (file) |path|
        readTextFile(init.gpa, io, path) catch
            return fail(io, 2, "could not read '{s}'", .{path})
    else
        readStdin(init.gpa, io) catch
            return fail(io, 2, "could not read stdin", .{});
    defer init.gpa.free(text);

    var ctx: Ctx = .{};
    defer ctx.deinit();

    var worst: u8 = 0;
    var first = true;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        const tokens = splitLine(arena, line) catch {
            frameLine(io, line, "# Error\nunparseable line (unmatched quote)\n", first);
            worst = @max(worst, 1);
            first = false;
            continue;
        };
        if (tokens.len == 0) continue;
        if (is(tokens[0], "batch")) {
            frameLine(io, line, "# Error\n`batch` is not allowed inside batch.\n", first);
            worst = @max(worst, 1);
            first = false;
            continue;
        }

        var out_aw: std.Io.Writer.Allocating = .init(init.gpa);
        var err_aw: std.Io.Writer.Allocating = .init(init.gpa);

        out_sink = &out_aw.writer;
        err_sink = &err_aw.writer;
        const code = dispatch(init, tokens, &ctx);
        out_sink = null;
        err_sink = null;

        if (!first) writeOut(io, "\n");
        writeOut(io, "===> ");
        writeOut(io, line);
        writeOut(io, "\n");
        writeOut(io, out_aw.written());
        writeOut(io, err_aw.written());

        out_aw.deinit();
        err_aw.deinit();

        worst = @max(worst, code);
        first = false;
    }

    return worst;
}

fn frameLine(io: Io, line: []const u8, payload: []const u8, first: bool) void {
    if (!first) writeOut(io, "\n");
    writeOut(io, "===> ");
    writeOut(io, line);
    writeOut(io, "\n");
    writeOut(io, payload);
}

/// Split a batch line into argv, honoring single and double quotes.
fn splitLine(arena: Allocator, line: []const u8) error{ UnmatchedQuote, OutOfMemory }![]const [:0]const u8 {
    var tokens: std.ArrayList([:0]const u8) = .empty;
    var i: usize = 0;

    while (i < line.len) {
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
        if (i >= line.len) break;

        var token: std.ArrayList(u8) = .empty;
        var quote: ?u8 = null;
        while (i < line.len) {
            const c = line[i];
            if (quote) |q| {
                if (c == q) {
                    quote = null;
                } else {
                    token.append(arena, c) catch return error.OutOfMemory;
                }
            } else if (c == '"' or c == '\'') {
                quote = c;
            } else if (c == ' ' or c == '\t') {
                break;
            } else {
                token.append(arena, c) catch return error.OutOfMemory;
            }
            i += 1;
        }
        if (quote != null) return error.UnmatchedQuote;
        if (token.items.len != 0) {
            const sentinel = arena.dupeSentinel(u8, token.items, 0) catch return error.OutOfMemory;
            tokens.append(arena, sentinel) catch return error.OutOfMemory;
        }
    }
    return tokens.items;
}

fn readStdin(gpa: Allocator, io: Io) ![]u8 {
    var buffer: [4096]u8 = undefined;
    var reader = Io.File.stdin().reader(io, &buffer);
    return reader.interface.allocRemaining(gpa, .limited(16 << 20));
}

fn readTextFile(gpa: Allocator, io: Io, path: []const u8) ![]u8 {
    if (!std.fs.path.isAbsolute(path)) {
        return Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 << 20));
    }
    const dir_path = std.fs.path.dirname(path) orelse ".";
    var dir = try Io.Dir.openDirAbsolute(io, dir_path, .{});
    defer dir.close(io);
    return dir.readFileAlloc(io, std.fs.path.basename(path), gpa, .limited(16 << 20));
}

const StdSource = struct {
    std_dir: []const u8,
};

const OpenStd = union(enum) {
    ok: StdSource,
    no_zig: void,
    probe_failed: zig_env.Failure,
    bad_lib_dir: []const u8,
    out_of_memory: void,
};

fn openStd(init: std.process.Init, arena: Allocator, options: SourceOptions) OpenStd {
    if (zig_env.libDirOverride(options.lib_dir, init.environ_map)) |raw| {
        const std_dir = stdlib.resolveStdDir(arena, init.io, raw) catch |err| switch (err) {
            error.OutOfMemory => return .out_of_memory,
            error.StdLibNotFound => return .{ .bad_lib_dir = raw },
        };
        return .{ .ok = .{ .std_dir = std_dir } };
    }

    const discovery = zig_env.discover(arena, init.io, init.environ_map, options.zig);
    const exe = discovery.exe() orelse return .no_zig;
    const probe = zig_env.probe(arena, init.gpa, init.io, exe) catch return .out_of_memory;
    return switch (probe) {
        .ok => |env| .{ .ok = .{ .std_dir = env.std_dir } },
        .failed => |failure| .{ .probe_failed = failure },
    };
}

const no_zig_message =
    "no Zig installation found: checked --zig, $ZIGPEEK_ZIG, $ZIG, then PATH.\n" ++
    "Install Zig, or pass --zig PATH / --lib-dir PATH.";

const bad_lib_dir_message =
    "--lib-dir '{s}' is not a Zig lib/ or std/ directory " ++
    "(expected std.zig or root.zig inside it)";

const bad_std_dir_message =
    "no std.zig or root.zig under '{s}'";

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

fn isOption(arg: []const u8) bool {
    return arg.len > 1 and arg[0] == '-';
}

fn is(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

var out_sink: ?*std.Io.Writer = null;
var err_sink: ?*std.Io.Writer = null;

fn writeOut(io: Io, text: []const u8) void {
    if (out_sink) |w| {
        w.writeAll(text) catch {};
        return;
    }
    Io.File.stdout().writeStreamingAll(io, text) catch {};
}

fn writeErr(io: Io, text: []const u8) void {
    if (err_sink) |w| {
        w.writeAll(text) catch {};
        return;
    }
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

test "usage texts list flags" {
    try testing.expect(std.mem.indexOf(u8, main_usage, "search") != null);
    try testing.expect(std.mem.indexOf(u8, search_usage, "--limit") != null);
    try testing.expect(std.mem.indexOf(u8, search_usage, "--lib-dir") != null);
    try testing.expect(std.mem.indexOf(u8, info_usage, "--zig") != null);
}

test "batch: splitLine honors quotes and whitespace" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    const tokens = try splitLine(arena_state.allocator(), "search \"two words\" --limit=3");
    try testing.expectEqual(@as(usize, 3), tokens.len);
    try testing.expectEqualStrings("search", tokens[0]);
    try testing.expectEqualStrings("two words", tokens[1]);
    try testing.expectEqualStrings("--limit=3", tokens[2]);
}

test "batch: splitLine rejects unmatched quotes" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectError(
        error.UnmatchedQuote,
        splitLine(arena_state.allocator(), "search \"unterminated"),
    );
}

test "batch: usage mentions stdin and file" {
    try testing.expect(std.mem.indexOf(u8, batch_usage, "stdin") != null);
    try testing.expect(std.mem.indexOf(u8, batch_usage, "--file") != null);
}
