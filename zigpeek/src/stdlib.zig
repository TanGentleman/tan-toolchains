//! Stdlib indexing and search.
//!
//! zigpeek never ships docs: it walks the `std/` tree of an installed Zig
//! compiler, parses every file reachable through `pub const X = @import(...)`,
//! and builds a flat index of fully-qualified declarations. `search` ranks
//! that index; `get` re-parses the one file a decl lives in.
//!
//! FQNs follow the module graph, not the filesystem: `std.Io` is a module
//! because `std.zig` says `pub const Io = @import("Io.zig")`, and
//! `std.Io.Dir.openFile` is a declaration inside it.

const std = @import("std");
const Ast = std.zig.Ast;

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const StdLibError = error{ StdLibNotFound, OutOfMemory };

pub const Kind = enum {
    /// `pub const x = @import("x.zig")` — a module namespace.
    namespace,
    /// `pub const x = struct/enum/union/opaque { ... }`.
    container,
    function,
    /// `pub fn x(comptime T: type) type` — a generic type constructor.
    type_function,
    /// `pub var x = ...`.
    global_var,
    /// `pub const x = <value>`.
    global_const,
    /// `pub const x = other.name` — resolve the alias to read it.
    alias,
    /// `pub const x = error{...}`.
    error_set,
};

pub const File = struct {
    path: []const u8,
    module_fqn: []const u8,
};

pub const Entry = struct {
    fqn: []const u8,
    name: []const u8,
    kind: Kind,
    /// Index into `Index.files`.
    file: u32,
    /// AST node index inside that file; stable for a given file content.
    node: u32,
};

pub const Index = struct {
    arena_state: std.heap.ArenaAllocator,
    files: []const File,
    entries: []const Entry,
    /// Files that could not be read or parsed. Search still works without them.
    skipped_files: usize,

    pub fn deinit(self: *Index) void {
        self.arena_state.deinit();
    }

    pub fn find(self: *const Index, fqn: []const u8) ?*const Entry {
        for (self.entries) |*entry| {
            if (std.mem.eql(u8, entry.fqn, fqn)) return entry;
        }
        return null;
    }

    pub fn fileOf(self: *const Index, entry: *const Entry) *const File {
        return &self.files[entry.file];
    }
};

/// Build the index for the stdlib rooted at `std_dir_raw` (either `lib/` or
/// `std/`; both are accepted).
pub fn build(gpa: Allocator, io: Io, std_dir_raw: []const u8) StdLibError!Index {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();

    const std_dir = try resolveStdDir(arena, io, std_dir_raw);

    var builder: Builder = .{
        .arena = arena,
        .gpa = gpa,
        .io = io,
        .std_dir = std_dir,
        .files = .empty,
        .entries = .empty,
        .seen_paths = std.StringHashMap(void).init(arena),
        .pending = .empty,
    };

    const root_path = std.fs.path.join(arena, &.{ std_dir, "std.zig" }) catch
        return error.OutOfMemory;
    try builder.enqueue(root_path, "std");
    try builder.run();

    return .{
        .arena_state = arena_state,
        .files = builder.files.items,
        .entries = builder.entries.items,
        .skipped_files = builder.skipped,
    };
}

/// Accept `<lib>/`, `<lib>/std/`, or a path to `std.zig` itself.
pub fn resolveStdDir(
    arena: Allocator,
    io: Io,
    raw: []const u8,
) StdLibError![]const u8 {
    const abs = absolute(arena, io, raw) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.StdLibNotFound,
    };

    if (isStdRoot(arena, io, abs)) return abs;

    const nested = std.fs.path.join(arena, &.{ abs, "std" }) catch return error.OutOfMemory;
    if (isStdRoot(arena, io, nested)) return nested;

    // A path straight to the root file, e.g. .../lib/std/std.zig.
    if (std.fs.path.dirname(abs)) |dir| {
        if (isStdRoot(arena, io, dir)) return dir;
    }
    return error.StdLibNotFound;
}

fn isStdRoot(arena: Allocator, io: Io, dir: []const u8) bool {
    for ([_][]const u8{ "std.zig", "root.zig" }) |name| {
        const candidate = std.fs.path.join(arena, &.{ dir, name }) catch return false;
        if (pathExists(arena, io, candidate)) return true;
    }
    return false;
}

/// Lexical absolutization against the process cwd. 0.17's
/// `std.fs.path.resolveAlloc` no longer prepends the cwd on its own.
fn absolute(arena: Allocator, io: Io, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) return path;
    const cwd = try std.process.currentPathAlloc(io, arena);
    return std.fs.path.resolveAlloc(arena, &.{ cwd, path });
}

fn pathExists(arena: Allocator, io: Io, path: []const u8) bool {
    const abs = absolute(arena, io, path) catch return false;
    Io.Dir.accessAbsolute(io, abs, .{ .read = true }) catch return false;
    return true;
}

// ---------------------------------------------------------------------------
// Index construction
// ---------------------------------------------------------------------------

const Pending = struct {
    abs_path: []const u8,
    module_fqn: []const u8,
};

const Builder = struct {
    arena: Allocator,
    gpa: Allocator,
    io: Io,
    std_dir: []const u8,
    files: std.ArrayList(File),
    entries: std.ArrayList(Entry),
    seen_paths: std.StringHashMap(void),
    pending: std.ArrayList(Pending),
    skipped: usize = 0,

    fn enqueue(self: *Builder, abs_path: []const u8, module_fqn: []const u8) !void {
        if (self.seen_paths.contains(abs_path)) return;
        const owned_path = try self.arena.dupe(u8, abs_path);
        try self.seen_paths.put(owned_path, {});
        try self.pending.append(self.arena, .{ .abs_path = owned_path, .module_fqn = module_fqn });
    }

    fn run(self: *Builder) !void {
        var queue_index: usize = 0;
        while (queue_index < self.pending.items.len) : (queue_index += 1) {
            const pending = self.pending.items[queue_index];
            self.process(pending) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => self.skipped += 1,
            };
        }
    }

    fn process(self: *Builder, pending: Pending) !void {
        const source = try readSource(self.io, self.gpa, pending.abs_path);
        defer self.gpa.free(source);

        var tree = try Ast.parse(self.gpa, source, .{});
        defer tree.deinit(self.gpa);

        // Rather than guess at half-parsed containers, skip the file.
        if (tree.errors.len != 0) return error.ParseErrors;

        const file_id: u32 = @intCast(self.files.items.len);
        try self.files.append(self.arena, .{
            .path = pending.abs_path,
            .module_fqn = pending.module_fqn,
        });
        try self.walk(file_id, &tree, pending.module_fqn, tree.rootDecls(), pending.abs_path);
    }

    fn walk(
        self: *Builder,
        file_id: u32,
        tree: *const Ast,
        prefix: []const u8,
        members: []const Ast.Node.Index,
        file_path: []const u8,
    ) !void {
        var cbuf: [2]Ast.Node.Index = undefined;
        var fbuf: [1]Ast.Node.Index = undefined;

        for (members) |node| {
            switch (tree.nodeTag(node)) {
                .fn_decl => {
                    const fn_proto = tree.fullFnProto(&fbuf, node) orelse continue;
                    if (fn_proto.visib_token == null) continue;
                    const name_token = fn_proto.name_token orelse continue;
                    try self.add(
                        file_id,
                        prefix,
                        tree.tokenSlice(name_token),
                        fnKind(tree, fn_proto),
                        node,
                    );
                },
                .simple_var_decl, .global_var_decl => {
                    const var_decl = tree.fullVarDecl(node) orelse continue;
                    if (var_decl.visib_token == null) continue;

                    const name = tree.tokenSlice(var_decl.ast.mut_token + 1);
                    const init = var_decl.ast.init_node.unwrap();
                    const kind = varKind(tree, var_decl, &cbuf);
                    try self.add(file_id, prefix, name, kind, node);

                    const expr = init orelse continue;
                    switch (kind) {
                        .namespace => {
                            const import_path = importPath(tree, expr, &cbuf) orelse continue;
                            const target = try self.resolveImport(file_path, import_path);
                            const module_fqn = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ prefix, name });
                            try self.enqueue(target, module_fqn);
                        },
                        .container => {
                            const container = tree.fullContainerDecl(&cbuf, expr) orelse continue;
                            const container_fqn = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ prefix, name });
                            try self.walk(file_id, tree, container_fqn, container.ast.members, file_path);
                        },
                        else => {},
                    }
                },
                else => {},
            }
        }
    }

    fn add(
        self: *Builder,
        file_id: u32,
        prefix: []const u8,
        name: []const u8,
        kind: Kind,
        node: Ast.Node.Index,
    ) !void {
        if (name.len == 0) return;
        const fqn = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ prefix, name });
        try self.entries.append(self.arena, .{
            .fqn = fqn,
            .name = try self.arena.dupe(u8, name),
            .kind = kind,
            .file = file_id,
            .node = @backingInt(node),
        });
    }

    fn resolveImport(self: *Builder, importing_file: []const u8, import_path: []const u8) ![]const u8 {
        const dir = std.fs.path.dirname(importing_file) orelse self.std_dir;
        return std.fs.path.resolveAlloc(self.arena, &.{ dir, import_path });
    }
};

pub fn readSource(io: Io, gpa: Allocator, abs_path: []const u8) ![:0]u8 {
    const dir_path = std.fs.path.dirname(abs_path) orelse ".";
    var dir = try Io.Dir.openDirAbsolute(io, dir_path, .{});
    defer dir.close(io);
    return dir.readFileAllocOptions(
        io,
        std.fs.path.basename(abs_path),
        gpa,
        .limited(16 << 20),
        .of(u8),
        0,
    );
}

pub fn fnKind(tree: *const Ast, fn_proto: Ast.full.FnProto) Kind {
    if (fn_proto.ast.return_type.unwrap()) |return_node| {
        if (tree.nodeTag(return_node) == .identifier) {
            const token = tree.nodeMainToken(return_node);
            if (std.mem.eql(u8, tree.tokenSlice(token), "type")) return .type_function;
        }
    }
    return .function;
}

pub fn varKind(tree: *const Ast, var_decl: Ast.full.VarDecl, buf: *[2]Ast.Node.Index) Kind {
    if (std.mem.eql(u8, tree.tokenSlice(var_decl.ast.mut_token), "var")) return .global_var;
    const expr = var_decl.ast.init_node.unwrap() orelse return .global_const;
    if (importPath(tree, expr, buf) != null) return .namespace;
    if (tree.fullContainerDecl(buf, expr) != null) return .container;
    if (tree.nodeTag(expr) == .error_set_decl) return .error_set;
    if (isAliasExpr(tree, expr)) return .alias;
    return .global_const;
}

/// `other`, `other.member`, `@import("x.zig").member`.
pub fn isAliasExpr(tree: *const Ast, node: Ast.Node.Index) bool {
    return switch (tree.nodeTag(node)) {
        .identifier, .field_access, .deref => true,
        else => false,
    };
}

/// The path inside `@import("...")`.
pub fn importPath(tree: *const Ast, node: Ast.Node.Index, buf: *[2]Ast.Node.Index) ?[]const u8 {
    switch (tree.nodeTag(node)) {
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {},
        else => return null,
    }
    const main_token = tree.nodeMainToken(node);
    if (!std.mem.eql(u8, tree.tokenSlice(main_token), "@import")) return null;
    const params = tree.builtinCallParams(buf, node) orelse return null;
    if (params.len != 1) return null;
    const param = params[0];
    if (tree.nodeTag(param) != .string_literal) return null;
    const literal = tree.tokenSlice(tree.nodeMainToken(param));
    if (literal.len < 2 or literal[0] != '"') return null;
    return literal[1 .. literal.len - 1];
}

// ---------------------------------------------------------------------------
// Search
// ---------------------------------------------------------------------------

pub const Hit = struct {
    entry: *const Entry,
    score: i32,
};

pub const Results = struct {
    /// Already sorted and truncated to the requested limit.
    hits: []const Hit,
    /// Number of matches before the limit was applied.
    total: usize,
};

/// Rank declarations against `query`.
///
/// A query containing `.` is matched against the whole FQN (so
/// `Io.Dir.open` finds `std.Io.Dir.openFile`), otherwise it is matched
/// against the short declaration name. Queries with no uppercase are matched
/// case-insensitively, which keeps `zigpeek search arraylist` useful while
/// letting `zigpeek search ArrayList` stay exact.
pub fn search(arena: Allocator, index: *const Index, query: []const u8, limit: usize) !Results {
    const trimmed = std.mem.trim(u8, query, " \t\r\n");
    if (trimmed.len == 0) return .{ .hits = &.{}, .total = 0 };

    const ignore_case = blk: {
        for (trimmed) |c| if (std.ascii.isUpper(c)) break :blk false;
        break :blk true;
    };
    const match_fqn = std.mem.indexOfScalar(u8, trimmed, '.') != null;

    var hits: std.ArrayList(Hit) = .empty;
    for (index.entries) |*entry| {
        const haystack = if (match_fqn) entry.fqn else entry.name;
        const score = rank(trimmed, haystack, ignore_case, entry.name.len);
        if (score > 0) try hits.append(arena, .{ .entry = entry, .score = score });
    }

    const total = hits.items.len;
    std.sort.heap(Hit, hits.items, {}, hitLessThan);

    const shown = @min(total, limit);
    return .{ .hits = hits.items[0..shown], .total = total };
}

fn rank(query: []const u8, haystack: []const u8, ignore_case: bool, name_len: usize) i32 {
    const base: i32 = if (eql(query, haystack, ignore_case))
        1000
    else if (startsWith(haystack, query, ignore_case))
        500
    else if (indexOf(haystack, query, ignore_case) != null)
        300
    else
        return 0;

    // Among case-insensitive matches, the one that matches the query's casing
    // byte-for-byte wins: `answer` before `Answer` for `search answer`.
    const case_bonus: i32 = if (std.mem.eql(u8, query, haystack)) 10 else 0;

    // Prefer shorter names among equal-quality matches: `ArrayList` before
    // `ArrayListUnmanaged`.
    const brevity: i32 = @intCast(@max(0, 50 -| @min(name_len, 50)));
    return base + case_bonus + brevity;
}

fn eql(a: []const u8, b: []const u8, ignore_case: bool) bool {
    return if (ignore_case) std.ascii.eqlIgnoreCase(a, b) else std.mem.eql(u8, a, b);
}

fn startsWith(haystack: []const u8, needle: []const u8, ignore_case: bool) bool {
    if (needle.len > haystack.len) return false;
    return eql(haystack[0..needle.len], needle, ignore_case);
}

fn indexOf(haystack: []const u8, needle: []const u8, ignore_case: bool) ?usize {
    if (!ignore_case) return std.mem.indexOf(u8, haystack, needle);
    if (needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

fn hitLessThan(_: void, a: Hit, b: Hit) bool {
    if (a.score != b.score) return a.score > b.score;
    return std.mem.order(u8, a.entry.fqn, b.entry.fqn) == .lt;
}

pub fn renderSearch(w: *std.Io.Writer, results: Results, query: []const u8) std.Io.Writer.Error!void {
    try w.print("# Search Results\n\nQuery: \"{s}\"\n\n", .{query});
    if (results.total == 0) {
        try w.writeAll("No results found.");
        return;
    }
    try w.print("Found {d} results (showing {d}):\n\n", .{ results.total, results.hits.len });
    for (results.hits) |hit| {
        try w.print("- {s}\n", .{hit.entry.fqn});
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const fixture_dir = "tests/fixtures/mini-std";

fn fixtureIndex(gpa: Allocator) !Index {
    return build(gpa, testing.io, fixture_dir);
}

test "index: module graph, containers, and kinds" {
    var index = try fixtureIndex(testing.allocator);
    defer index.deinit();

    const expected = [_]struct { fqn: []const u8, kind: Kind }{
        .{ .fqn = "std.Answer", .kind = .container },
        .{ .fqn = "std.Answer.value", .kind = .global_const },
        .{ .fqn = "std.Answer.greet", .kind = .function },
        .{ .fqn = "std.Foo", .kind = .namespace },
        .{ .fqn = "std.Foo.Thing", .kind = .container },
        .{ .fqn = "std.Foo.Thing.hello", .kind = .function },
        .{ .fqn = "std.Foo.Thing.Slice", .kind = .global_const },
        .{ .fqn = "std.Foo.counter", .kind = .global_var },
        .{ .fqn = "std.Bar", .kind = .namespace },
        .{ .fqn = "std.Bar.deep", .kind = .function },
        .{ .fqn = "std.Bar.Deep", .kind = .container },
        .{ .fqn = "std.Alias", .kind = .alias },
        .{ .fqn = "std.make", .kind = .type_function },
        .{ .fqn = "std.answer", .kind = .global_const },
        .{ .fqn = "std.Thing", .kind = .container },
        .{ .fqn = "std.Oops", .kind = .error_set },
    };

    for (expected) |want| {
        const entry = index.find(want.fqn) orelse {
            std.debug.print("missing FQN: {s}\n", .{want.fqn});
            return error.TestExpectedEntry;
        };
        try testing.expectEqual(want.kind, entry.kind);
    }
}

test "index: private decls and private members stay out" {
    var index = try fixtureIndex(testing.allocator);
    defer index.deinit();

    for ([_][]const u8{
        "std.Private",
        "std.Private.Hidden",
        "std.Answer.secret",
        "std.std",
    }) |hidden| {
        try testing.expect(index.find(hidden) == null);
    }
}

test "index: reports which file a decl lives in" {
    var index = try fixtureIndex(testing.allocator);
    defer index.deinit();

    const entry = index.find("std.Foo.Thing.hello").?;
    try testing.expect(std.mem.endsWith(u8, index.fileOf(entry).path, "foo.zig"));
    try testing.expectEqualStrings("std.Foo", index.fileOf(entry).module_fqn);

    const deep = index.find("std.Bar.Deep").?;
    try testing.expect(std.mem.endsWith(u8, index.fileOf(deep).path, "bar.zig"));
}

test "index: accepts lib/, std/, and the root file path" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const as_std = try resolveStdDir(arena, testing.io, fixture_dir);
    // `as_std` is absolute, so only compare the last component: separators
    // differ on Windows.
    try testing.expect(std.mem.endsWith(u8, as_std, "mini-std"));

    const as_file = try std.fmt.allocPrint(arena, "{s}/std.zig", .{fixture_dir});
    _ = try resolveStdDir(arena, testing.io, as_file);
}

test "index: missing stdlib is a clean error" {
    try testing.expectError(
        error.StdLibNotFound,
        build(testing.allocator, testing.io, "tests/fixtures/does-not-exist"),
    );
}

test "search: exact, prefix, and substring ranking" {
    var index = try fixtureIndex(testing.allocator);
    defer index.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const results = try search(arena, &index, "answer", 10);
    try testing.expect(results.total >= 2);
    // Exact (case-insensitive) `std.answer` beats prefix `std.Answer`, which
    // itself beats nothing else here.
    try testing.expectEqualStrings("std.answer", results.hits[0].entry.fqn);
    try testing.expectEqualStrings("std.Answer", results.hits[1].entry.fqn);
}

test "search: dotted query matches FQNs" {
    var index = try fixtureIndex(testing.allocator);
    defer index.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const results = try search(arena, &index, "Foo.Thing.h", 10);
    try testing.expectEqual(@as(usize, 1), results.total);
    try testing.expectEqualStrings("std.Foo.Thing.hello", results.hits[0].entry.fqn);
}

test "search: limit truncates but total is preserved" {
    var index = try fixtureIndex(testing.allocator);
    defer index.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const results = try search(arena, &index, "e", 2);
    try testing.expectEqual(@as(usize, 2), results.hits.len);
    try testing.expect(results.total > 2);
}

test "search: no matches" {
    var index = try fixtureIndex(testing.allocator);
    defer index.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const results = try search(arena, &index, "zzzznotathing", 10);
    try testing.expectEqual(@as(usize, 0), results.total);
}
