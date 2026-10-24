//! `zigpeek builtins`: the `@`-builtin reference, read from the langref HTML
//! that ships inside the Zig installation (`<prefix>/doc/langref.html`).
//!
//! The HTML is only mined for the `#Builtin-Functions` section, so this is a
//! deliberately small scanner rather than a general HTML parser.

const std = @import("std");
const zig_env = @import("zig_env.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Error = error{ MissingSection, OutOfMemory };

pub const Entry = struct {
    /// `@addWithOverflow`
    name: []const u8,
    /// Raw Zig signature, e.g. `@addWithOverflow(a: anytype, b: anytype) ...`
    signature: []const u8,
    docs: []const u8,
};

/// Find the langref that belongs to a compiler installation.
pub fn findLangref(arena: Allocator, io: Io, std_dir: []const u8) ?[]const u8 {
    return zig_env.findLangref(arena, io, std_dir);
}

pub fn parse(arena: Allocator, html: []const u8) Error![]Entry {
    const marker = std.mem.indexOf(u8, html, "id=\"Builtin-Functions\"") orelse
        return error.MissingSection;
    var pos = endOfTag(html, marker) orelse return error.MissingSection;

    var entries: std.ArrayList(Entry) = .empty;
    while (true) {
        const h3_at = std.mem.indexOfPos(u8, html, pos, "<h3") orelse break;
        if (std.mem.indexOfPos(u8, html, pos, "<h2")) |h2_at| {
            if (h2_at < h3_at) break;
        }

        const h3_close = std.mem.indexOfPos(u8, html, h3_at, "</h3>") orelse break;
        const name = (try headingName(arena, html[h3_at..h3_close])) orelse {
            pos = h3_close + "</h3>".len;
            continue;
        };
        pos = h3_close + "</h3>".len;

        var signature: []const u8 = "";
        if (std.mem.indexOfPos(u8, html, pos, "<pre")) |pre_at| {
            if (std.mem.indexOfPos(u8, html, pre_at, "</pre>")) |pre_close| {
                signature = try text(arena, html[pre_at..pre_close], .{
                    .code_ticks = false,
                    .collapse_whitespace = false,
                });
                pos = pre_close + "</pre>".len;
            }
        }

        const region_end = blockEnd(html, pos);
        const docs = try docsText(arena, html[pos..region_end]);
        entries.append(arena, .{
            .name = name,
            .signature = signature,
            .docs = docs,
        }) catch return error.OutOfMemory;

        pos = region_end;
    }

    return entries.items;
}

/// The next `<h2`/`<h3` boundary, or the end of the document.
fn blockEnd(html: []const u8, from: usize) usize {
    var end = html.len;
    if (std.mem.indexOfPos(u8, html, from, "<h3")) |at| end = @min(end, at);
    if (std.mem.indexOfPos(u8, html, from, "<h2")) |at| end = @min(end, at);
    return end;
}

fn endOfTag(html: []const u8, from: usize) ?usize {
    const close = std.mem.indexOfPos(u8, html, from, ">") orelse return null;
    return close + 1;
}

fn headingName(arena: Allocator, fragment: []const u8) Error!?[]const u8 {
    const a_open = std.mem.indexOfScalar(u8, fragment, '<') orelse return null;
    const a_gt = std.mem.indexOfPos(u8, fragment, a_open, ">") orelse return null;
    const a_close = std.mem.indexOfPos(u8, fragment, a_gt, "</a>") orelse return null;
    const raw = try text(arena, fragment[a_gt + 1 .. a_close], .{
        .code_ticks = false,
        .collapse_whitespace = true,
    });
    if (raw.len == 0 or raw[0] != '@') return null;
    return raw;
}

/// Turn the region after a signature into plain-text docs.
fn docsText(arena: Allocator, fragment: []const u8) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;

    var i: usize = 0;
    while (i < fragment.len) {
        if (startsWithAt(fragment, i, "<p")) {
            const close = std.mem.indexOfPos(u8, fragment, i, "</p>") orelse break;
            const body_start = endOfTag(fragment, i) orelse break;
            const body = try text(arena, fragment[body_start..close], .{
                .code_ticks = true,
                .collapse_whitespace = true,
            });
            try appendBlock(arena, &out, body);
            i = close + "</p>".len;
            continue;
        }
        if (startsWithAt(fragment, i, "<li")) {
            const close = std.mem.indexOfPos(u8, fragment, i, "</li>") orelse break;
            const body_start = endOfTag(fragment, i) orelse break;
            const body = try text(arena, fragment[body_start..close], .{
                .code_ticks = true,
                .collapse_whitespace = true,
            });
            const bullet = try std.fmt.allocPrint(arena, "* {s}", .{body});
            try appendBlock(arena, &out, bullet);
            i = close + "</li>".len;
            continue;
        }
        if (startsWithAt(fragment, i, "<figure")) {
            const close = std.mem.indexOfPos(u8, fragment, i, "</figure>") orelse break;
            // Shell figures replay compiler output, e.g. a panic dump full of
            // /home/ci/... paths. The Zig example above them says the same thing.
            if (indexOf(fragment[i..close], "shell-cap", true) == null) {
                const body = try figureMarkdown(arena, fragment[i..close]);
                try appendBlock(arena, &out, body);
            }
            i = close + "</figure>".len;
            continue;
        }
        i += 1;
    }

    return std.mem.trimEnd(u8, out.items, "\n");
}

fn appendBlock(arena: Allocator, out: *std.ArrayList(u8), block: []const u8) Error!void {
    if (block.len == 0) return;
    out.appendSlice(arena, block) catch return error.OutOfMemory;
    out.append(arena, '\n') catch return error.OutOfMemory;
}

/// Render one `<figure>`; only called for figures that carry a Zig example.
fn figureMarkdown(arena: Allocator, fragment: []const u8) Error![]const u8 {
    var label: []const u8 = "";
    var language: []const u8 = "";

    if (std.mem.indexOf(u8, fragment, "<figcaption")) |cap_at| {
        if (endOfTag(fragment, cap_at)) |cap_body| {
            if (std.mem.indexOfPos(u8, fragment, cap_body, "</figcaption>")) |cap_close| {
                label = try text(arena, fragment[cap_body..cap_close], .{
                    .code_ticks = false,
                    .collapse_whitespace = true,
                });
                if (std.mem.endsWith(u8, label, ".zig")) {
                    language = "zig";
                } else if (indexOf(label, "shell", true) != null) {
                    language = "sh";
                }
            }
        }
    }

    var code: []const u8 = "";
    if (std.mem.indexOf(u8, fragment, "<pre")) |pre_at| {
        if (std.mem.indexOfPos(u8, fragment, pre_at, "</pre>")) |pre_close| {
            code = try text(arena, fragment[pre_at..pre_close], .{
                .code_ticks = false,
                .collapse_whitespace = false,
            });
        }
    }
    if (code.len == 0) return "";

    if (label.len != 0) {
        return std.fmt.allocPrint(
            arena,
            "**{s}**\n\n```{s}\n{s}\n```",
            .{ label, language, std.mem.trim(u8, code, " \t\r\n") },
        ) catch error.OutOfMemory;
    }
    return std.fmt.allocPrint(
        arena,
        "```{s}\n{s}\n```",
        .{ language, std.mem.trim(u8, code, " \t\r\n") },
    ) catch error.OutOfMemory;
}

const TextOptions = struct {
    code_ticks: bool,
    collapse_whitespace: bool,
};

/// Strip tags, decode the handful of entities the langref uses, and
/// optionally collapse whitespace (docs) or preserve it (code).
fn text(arena: Allocator, fragment: []const u8, options: TextOptions) Error![]const u8 {
    var raw: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < fragment.len) {
        if (fragment[i] == '<') {
            const close = std.mem.indexOfScalarPos(u8, fragment, i, '>') orelse break;
            if (options.code_ticks) {
                const tag = fragment[i .. close + 1];
                if (std.mem.eql(u8, tag, "<code>") or std.mem.startsWith(u8, tag, "<code ")) {
                    raw.append(arena, '`') catch return error.OutOfMemory;
                } else if (std.mem.eql(u8, tag, "</code>")) {
                    raw.append(arena, '`') catch return error.OutOfMemory;
                }
            }
            i = close + 1;
            continue;
        }
        if (fragment[i] == '&') {
            if (decodeEntity(fragment, i)) |decoded| {
                raw.appendSlice(arena, decoded.bytes) catch return error.OutOfMemory;
                i = decoded.next;
                continue;
            }
        }
        raw.append(arena, fragment[i]) catch return error.OutOfMemory;
        i += 1;
    }

    if (!options.collapse_whitespace) {
        return std.mem.trim(u8, raw.items, " \t\r\n");
    }

    var out: std.ArrayList(u8) = .empty;
    var pending_space = false;
    for (raw.items) |c| {
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            pending_space = out.items.len != 0;
            continue;
        }
        if (pending_space) {
            out.append(arena, ' ') catch return error.OutOfMemory;
            pending_space = false;
        }
        out.append(arena, c) catch return error.OutOfMemory;
    }
    return out.items;
}

const Decoded = struct {
    bytes: []const u8,
    next: usize,
};

fn decodeEntity(source: []const u8, at: usize) ?Decoded {
    const semicolon = std.mem.indexOfScalarPos(u8, source, at, ';') orelse return null;
    if (semicolon - at > 10) return null;
    const entity = source[at + 1 .. semicolon];
    const next = semicolon + 1;

    const named = .{
        .{ "quot", "\"" },
        .{ "apos", "'" },
        .{ "amp", "&" },
        .{ "lt", "<" },
        .{ "gt", ">" },
        .{ "nbsp", " " },
    };
    inline for (named) |pair| {
        if (std.mem.eql(u8, entity, pair[0])) return .{ .bytes = pair[1], .next = next };
    }
    return null;
}

fn startsWithAt(haystack: []const u8, at: usize, needle: []const u8) bool {
    return at + needle.len <= haystack.len and std.mem.eql(u8, haystack[at .. at + needle.len], needle);
}

// ---------------------------------------------------------------------------
// Ranking
// ---------------------------------------------------------------------------

pub const Hit = struct {
    entry: *const Entry,
    score: i32,
};

pub const Results = struct {
    hits: []const Hit,
    total: usize,
};

pub fn rank(arena: Allocator, entries: []const Entry, query: []const u8, limit: usize) !Results {
    const trimmed = std.mem.trim(u8, query, " \t\r\n");
    if (trimmed.len == 0) return .{ .hits = &.{}, .total = 0 };

    const ignore_case = blk: {
        for (trimmed) |c| if (std.ascii.isUpper(c)) break :blk false;
        break :blk true;
    };

    var hits: std.ArrayList(Hit) = .empty;
    for (entries) |*entry| {
        const score = scoreName(trimmed, entry, ignore_case);
        if (score > 0) try hits.append(arena, .{ .entry = entry, .score = score });
    }
    // Name matches always win; only search doc text when the name has no hit
    // at all (`atomicLoad` should return one result, not every builtin whose
    // docs mention it).
    if (hits.items.len == 0) {
        for (entries) |*entry| {
            const score = scoreDocs(trimmed, entry, ignore_case);
            if (score > 0) try hits.append(arena, .{ .entry = entry, .score = score });
        }
    }

    const total = hits.items.len;
    std.sort.heap(Hit, hits.items, {}, hitLessThan);
    return .{ .hits = hits.items[0..@min(total, limit)], .total = total };
}

fn scoreName(query: []const u8, entry: *const Entry, ignore_case: bool) i32 {
    // `@atomic` and `atomic` are the same query.
    const bare = if (std.mem.startsWith(u8, query, "@")) query[1..] else query;
    const name = if (std.mem.startsWith(u8, entry.name, "@")) entry.name[1..] else entry.name;

    const base: i32 = if (eql(bare, name, ignore_case))
        1000
    else if (startsWith(name, bare, ignore_case))
        500
    else if (indexOf(name, bare, ignore_case) != null)
        300
    else
        return 0;

    const case_bonus: i32 = if (std.mem.eql(u8, query, entry.name)) 10 else 0;
    return base + case_bonus + brevity(entry.name);
}

fn scoreDocs(query: []const u8, entry: *const Entry, ignore_case: bool) i32 {
    const bare = if (std.mem.startsWith(u8, query, "@")) query[1..] else query;
    if (indexOf(entry.docs, bare, ignore_case) == null) return 0;
    return 100 + brevity(entry.name);
}

fn brevity(name: []const u8) i32 {
    return @intCast(@max(0, 40 -| @min(name.len, 40)));
}

fn hitLessThan(_: void, a: Hit, b: Hit) bool {
    if (a.score != b.score) return a.score > b.score;
    return std.mem.order(u8, a.entry.name, b.entry.name) == .lt;
}

fn eql(a: []const u8, b: []const u8, ignore_case: bool) bool {
    return if (ignore_case) std.ascii.eqlIgnoreCase(a, b) else std.mem.eql(u8, a, b);
}

fn startsWith(haystack: []const u8, needle: []const u8, ignore_case: bool) bool {
    if (needle.len > haystack.len) return false;
    return eql(haystack[0..needle.len], needle, ignore_case);
}

fn indexOf(haystack: []const u8, needle: []const u8, ignore_case: bool) ?usize {
    if (needle.len == 0) return 0;
    if (!ignore_case) return std.mem.indexOf(u8, haystack, needle);
    if (needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

pub fn renderList(w: *std.Io.Writer, entries: []const Entry, langref_path: []const u8) std.Io.Writer.Error!void {
    try w.print(
        "Available {d} builtin functions (full docs: {s}):\n\n",
        .{ entries.len, langref_path },
    );
    for (entries) |entry| {
        try w.print("- {s}\n", .{entry.signature});
    }
}

pub fn renderGet(w: *std.Io.Writer, results: Results, query: []const u8) std.Io.Writer.Error!void {
    if (results.total == 0) return;
    if (results.total == 1) {
        try renderEntry(w, results.hits[0].entry);
        return;
    }
    try w.print("Found {d} matching functions:\n\n", .{results.total});
    for (results.hits, 0..) |hit, index| {
        if (index != 0) try w.writeAll("\n---\n\n");
        try renderEntry(w, hit.entry);
    }
    _ = query;
}

fn renderEntry(w: *std.Io.Writer, entry: *const Entry) std.Io.Writer.Error!void {
    try w.print("**{s}**\n\n```zig\n{s}\n```\n", .{ entry.name, entry.signature });
    if (entry.docs.len != 0) {
        try w.print("\n{s}\n", .{entry.docs});
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const fixture = "tests/fixtures/tiny-langref.html";

fn parseFixture(arena: Allocator) ![]Entry {
    const html = try std.Io.Dir.cwd().readFileAlloc(testing.io, fixture, arena, .limited(1 << 20));
    return parse(arena, html);
}

test "builtins: only the Builtin-Functions section is parsed" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    const entries = try parseFixture(arena_state.allocator());
    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqualStrings("@addWithOverflow", entries[0].name);
    try testing.expectEqualStrings("@atomicLoad", entries[1].name);
}

test "builtins: signatures are de-tagged and unescaped" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    const entries = try parseFixture(arena_state.allocator());
    try testing.expectEqualStrings(
        "@addWithOverflow(a: anytype, b: anytype) struct { @TypeOf(a, b), u1 }",
        entries[0].signature,
    );
    try testing.expectEqualStrings(
        "@atomicLoad(comptime T: type, ptr: *const T, comptime ordering: AtomicOrder) T",
        entries[1].signature,
    );
}

test "builtins: docs include paragraphs, bullets, and figure code" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    const entries = try parseFixture(arena_state.allocator());
    try testing.expectEqualStrings(
        "Performs `a + b` and returns a tuple with the result and a possible overflow bit.",
        entries[0].docs,
    );

    const atomic = entries[1].docs;
    try testing.expect(std.mem.indexOf(u8, atomic, "Loads a value from memory with `ptr` atomically.") != null);
    try testing.expect(std.mem.indexOf(u8, atomic, "* ordering must be `.acquire`, `.acq_rel`, or `.seq_cst`.") != null);
    try testing.expect(std.mem.indexOf(u8, atomic, "**test_atomic.zig**") != null);
    try testing.expect(std.mem.indexOf(u8, atomic, "```zig\nconst value = @atomicLoad(u32, &ptr, .acquire);\n```") != null);
    try testing.expect(std.mem.indexOf(u8, atomic, "&amp;") == null);
    // The shell figure's replay of a panic must not reach the docs.
    try testing.expect(std.mem.indexOf(u8, atomic, "zig test test_atomic.zig") == null);
    try testing.expect(std.mem.indexOf(u8, atomic, "Shell") == null);
}

test "builtins: missing section is an error" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectError(
        error.MissingSection,
        parse(arena_state.allocator(), "<html><body><h2 id=\"Nope\">x</h2></body></html>"),
    );
}

test "builtins: ranking prefers name matches over doc matches" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const entries = try parseFixture(arena);
    const by_name = try rank(arena, entries, "atomicload", 10);
    try testing.expectEqual(@as(usize, 1), by_name.total);
    try testing.expectEqualStrings("@atomicLoad", by_name.hits[0].entry.name);

    const by_doc = try rank(arena, entries, "overflow bit", 10);
    try testing.expectEqual(@as(usize, 1), by_doc.total);
    try testing.expectEqualStrings("@addWithOverflow", by_doc.hits[0].entry.name);

    const at_prefix = try rank(arena, entries, "@atomic", 10);
    try testing.expectEqualStrings("@atomicLoad", at_prefix.hits[0].entry.name);
}
