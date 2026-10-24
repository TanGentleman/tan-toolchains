//! `zigpeek get FQN`: render one declaration as markdown.
//!
//! The index (stdlib.zig) points at a file + AST node. This module re-parses
//! just that file, follows alias chains (`pub const X = other.X`), and renders
//! docs, signature, members, fields, errors, and source.

const std = @import("std");
const stdlib = @import("stdlib.zig");

const Ast = std.zig.Ast;
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Options = struct {
    source_file: bool = false,
};

pub const Error = error{
    NotFound,
    Unreadable,
    Unparseable,
    OutOfMemory,
    WriteFailed,
};

/// Maximum alias hops before giving up; guards against `A = B; B = A;`.
const max_alias_hops = 8;

pub fn render(
    w: *std.Io.Writer,
    arena: Allocator,
    gpa: Allocator,
    io: Io,
    index: *const stdlib.Index,
    request: []const u8,
    options: Options,
) Error!void {
    const requested = normalize(arena, index, request) orelse return error.NotFound;
    const entry = index.find(requested) orelse return error.NotFound;

    const target = try resolveTarget(arena, gpa, io, index, entry, requested) orelse
        return error.NotFound;

    if (options.source_file) {
        var loaded = try load(arena, gpa, io, target.path);
        defer loaded.deinit();
        try w.print("# {s}\n\n```zig\n{s}\n```\n", .{ target.path, loaded.source });
        return;
    }
    var loaded = try load(arena, gpa, io, target.path);
    defer loaded.deinit();

    const node: Ast.Node.Index = @fromBackingInt(@intCast(target.node));
    const kind = classify(loaded.tree, node) orelse return error.NotFound;

    // A namespace entry is declared in its parent module; the namespace body
    // (fields, `//!` docs) lives in the imported file.
    if (kind == .namespace) {
        const module_path = try namespacePath(arena, &loaded, node);
        if (!std.mem.eql(u8, module_path, loaded.path)) {
            loaded.deinit();
            loaded = try load(arena, gpa, io, module_path);
        }
    }

    try w.print("# {s}\n\n", .{requested});
    if (target.alias_expr) |expr| {
        try w.print("Alias of `{s}`.\n\n", .{expr});
    }

    const docs = blk: {
        if (try declDocs(arena, &loaded, node)) |text| break :blk text;
        // Modules document themselves with `//!` at the top of the file.
        if (kind == .namespace) break :blk try moduleDocs(arena, &loaded);
        break :blk null;
    };
    if (docs) |text| {
        try w.writeAll(text);
        try w.writeAll("\n\n");
    }

    switch (kind) {
        .namespace => {
            // `pub const X = @import("x.zig")` where the file root is a struct
            // (e.g. std.mem.Allocator) exposes fields at the root node.
            try renderFields(w, arena, &loaded, .root);
            try renderMembers(w, arena, index, target.fqn);
        },
        .container => {
            try renderFields(w, arena, &loaded, node);
            try renderMembers(w, arena, index, target.fqn);
        },
        .error_set => try renderErrors(w, arena, &loaded, node),
        .function, .type_function => {
            try renderSignature(w, arena, &loaded, node);
            try renderSource(w, &loaded, node);
        },
        .global_var, .global_const, .alias => try renderSource(w, &loaded, node),
    }
}

/// Accept `Io.Dir.openFile` as well as `std.Io.Dir.openFile`.
fn normalize(arena: Allocator, index: *const stdlib.Index, request: []const u8) ?[]const u8 {
    if (index.find(request) != null) return request;
    if (std.mem.startsWith(u8, request, "std.")) return null;
    const prefixed = std.fmt.allocPrint(arena, "std.{s}", .{request}) catch return null;
    return if (index.find(prefixed) != null) prefixed else null;
}

// ---------------------------------------------------------------------------
// Loading and alias resolution
// ---------------------------------------------------------------------------

const Loaded = struct {
    gpa: Allocator,
    path: []const u8,
    source: [:0]u8,
    tree: Ast,

    fn deinit(self: *Loaded) void {
        self.tree.deinit(self.gpa);
        self.gpa.free(self.source);
    }
};

fn load(arena: Allocator, gpa: Allocator, io: Io, path: []const u8) Error!Loaded {
    const source = stdlib.readSource(io, gpa, path) catch return error.Unreadable;
    errdefer gpa.free(source);
    var tree = Ast.parse(gpa, source, .{}) catch return error.OutOfMemory;
    if (tree.errors.len != 0) {
        tree.deinit(gpa);
        return error.Unparseable;
    }
    return .{
        .gpa = gpa,
        .path = arena.dupe(u8, path) catch {
            tree.deinit(gpa);
            return error.OutOfMemory;
        },
        .source = source,
        .tree = tree,
    };
}

const Target = struct {
    path: []const u8,
    node: u32,
    /// Canonical FQN of the resolved declaration (differs from the requested
    /// name when an alias was followed).
    fqn: []const u8,
    /// Source text of the last alias hop, when the request was an alias.
    alias_expr: ?[]const u8 = null,
};

fn resolveTarget(
    arena: Allocator,
    gpa: Allocator,
    io: Io,
    index: *const stdlib.Index,
    start: *const stdlib.Entry,
    requested: []const u8,
) Error!?Target {
    var path = index.fileOf(start).path;
    var node: Ast.Node.Index = @fromBackingInt(@intCast(start.node));
    var fqn: []const u8 = requested;
    var alias_expr: ?[]const u8 = null;

    var hop: usize = 0;
    while (hop < max_alias_hops) : (hop += 1) {
        var loaded = try load(arena, gpa, io, path);
        defer loaded.deinit();

        const var_decl = loaded.tree.fullVarDecl(node);
        const kind = classify(loaded.tree, node) orelse return null;
        if (kind != .alias) {
            return .{ .path = path, .node = @backingInt(node), .fqn = fqn, .alias_expr = alias_expr };
        }

        const init = (var_decl orelse return null).ast.init_node.unwrap() orelse
            return .{ .path = path, .node = @backingInt(node), .fqn = fqn, .alias_expr = alias_expr };
        alias_expr = try exprText(arena, &loaded, init);

        const next = try aliasNext(arena, index, &loaded, init) orelse
            return .{ .path = path, .node = @backingInt(node), .fqn = fqn, .alias_expr = alias_expr };

        switch (next) {
            .entry => |resolved| {
                if (std.mem.eql(u8, resolved.fqn, requested)) return null;
                path = index.fileOf(resolved).path;
                node = @fromBackingInt(@intCast(resolved.node));
                fqn = resolved.fqn;
            },
            .file_member => |member| {
                const target_node = findInFile(arena, gpa, io, member.path, member.name) catch
                    return .{ .path = path, .node = @backingInt(node), .fqn = fqn, .alias_expr = alias_expr };
                const target = target_node orelse
                    return .{ .path = path, .node = @backingInt(node), .fqn = fqn, .alias_expr = alias_expr };
                return .{ .path = member.path, .node = target, .fqn = fqn, .alias_expr = alias_expr };
            },
        }
    }
    return null;
}

const Next = union(enum) {
    entry: *const stdlib.Entry,
    file_member: struct { path: []const u8, name: []const u8 },
};

fn aliasNext(
    arena: Allocator,
    index: *const stdlib.Index,
    loaded: *const Loaded,
    expr: Ast.Node.Index,
) Error!?Next {
    const tree = loaded.tree;
    const module_fqn = moduleFqnFor(index, loaded.path);

    switch (tree.nodeTag(expr)) {
        .identifier => {
            const name = tree.tokenSlice(tree.nodeMainToken(expr));
            const candidates = [_][]const u8{
                try join(arena, module_fqn, name),
                try join(arena, "std", name),
            };
            for (candidates) |candidate| {
                if (index.find(candidate)) |found| return .{ .entry = found };
            }
            return null;
        },
        .field_access => {
            const data = tree.nodeData(expr);
            const lhs = data.node_and_token[0];
            const member = tree.tokenSlice(data.node_and_token[1]);

            // `@import("foo.zig").Thing` — read the file directly. The target
            // file is often not a named module (e.g. multi_array_list.zig), so
            // there may be no index entry to follow.
            var buf: [2]Ast.Node.Index = undefined;
            if (stdlib.importPath(&tree, lhs, &buf)) |import_path| {
                const dir = std.fs.path.dirname(loaded.path) orelse ".";
                const path = std.fs.path.resolveAlloc(arena, &.{ dir, import_path }) catch
                    return error.OutOfMemory;
                return .{ .file_member = .{ .path = path, .name = member } };
            }

            const lhs_text = try exprText(arena, loaded, lhs);
            const candidates = [_][]const u8{
                try std.fmt.allocPrint(arena, "{s}.{s}.{s}", .{ module_fqn, lhs_text, member }),
                try std.fmt.allocPrint(arena, "std.{s}.{s}", .{ lhs_text, member }),
            };
            for (candidates) |candidate| {
                if (index.find(candidate)) |found| return .{ .entry = found };
            }
            return null;
        },
        else => return null,
    }
}

/// The module FQN a file was indexed under, if any.
fn moduleFqnFor(index: *const stdlib.Index, path: []const u8) []const u8 {
    for (index.files) |*file| {
        if (std.mem.eql(u8, file.path, path)) return file.module_fqn;
    }
    return "std";
}

fn findInFile(
    arena: Allocator,
    gpa: Allocator,
    io: Io,
    path: []const u8,
    name: []const u8,
) !?u32 {
    var loaded = try load(arena, gpa, io, path);
    defer loaded.deinit();

    var fbuf: [1]Ast.Node.Index = undefined;
    for (loaded.tree.rootDecls()) |node| {
        const decl_name = switch (loaded.tree.nodeTag(node)) {
            .fn_decl => blk: {
                const fn_proto = loaded.tree.fullFnProto(&fbuf, node) orelse break :blk null;
                break :blk fn_proto.name_token;
            },
            .simple_var_decl, .global_var_decl => blk: {
                const var_decl = loaded.tree.fullVarDecl(node) orelse break :blk null;
                break :blk var_decl.ast.mut_token + 1;
            },
            else => null,
        };
        const token = decl_name orelse continue;
        if (std.mem.eql(u8, loaded.tree.tokenSlice(token), name)) {
            return @backingInt(node);
        }
    }
    return null;
}

fn join(arena: Allocator, a: []const u8, b: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}.{s}", .{ a, b });
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

fn classify(tree: Ast, node: Ast.Node.Index) ?stdlib.Kind {
    switch (tree.nodeTag(node)) {
        .fn_decl => {
            var buf: [1]Ast.Node.Index = undefined;
            const fn_proto = tree.fullFnProto(&buf, node) orelse return null;
            return stdlib.fnKind(&tree, fn_proto);
        },
        .simple_var_decl, .global_var_decl => {
            const var_decl = tree.fullVarDecl(node) orelse return null;
            var buf: [2]Ast.Node.Index = undefined;
            return stdlib.varKind(&tree, var_decl, &buf);
        },
        else => return null,
    }
}

fn declDocs(arena: Allocator, loaded: *const Loaded, node: Ast.Node.Index) Error!?[]const u8 {
    const tree = loaded.tree;
    const first_token = switch (tree.nodeTag(node)) {
        .fn_decl => blk: {
            var buf: [1]Ast.Node.Index = undefined;
            const fn_proto = tree.fullFnProto(&buf, node) orelse return null;
            break :blk fn_proto.firstToken();
        },
        .simple_var_decl, .global_var_decl => blk: {
            const var_decl = tree.fullVarDecl(node) orelse return null;
            break :blk var_decl.visib_token orelse var_decl.ast.mut_token;
        },
        else => return null,
    };

    var start: ?Ast.TokenIndex = null;
    var token = first_token;
    while (token > 0) {
        const prev = token - 1;
        if (tree.tokenTag(prev) != .doc_comment) break;
        start = prev;
        token = prev;
    }
    const first_doc = start orelse return null;

    var out: std.ArrayList(u8) = .empty;
    var i = first_doc;
    while (i < first_token) : (i += 1) {
        if (tree.tokenTag(i) != .doc_comment) continue;
        const raw = tree.tokenSlice(i);
        const body = if (std.mem.startsWith(u8, raw, "///")) raw[3..] else raw;
        const text = if (body.len != 0 and body[0] == ' ') body[1..] else body;
        out.appendSlice(arena, text) catch return error.OutOfMemory;
        out.append(arena, '\n') catch return error.OutOfMemory;
    }
    if (out.items.len == 0) return null;
    return std.mem.trimEnd(u8, out.items, "\n");
}

fn renderSignature(w: *std.Io.Writer, arena: Allocator, loaded: *const Loaded, node: Ast.Node.Index) Error!void {
    const tree = loaded.tree;
    var buf: [1]Ast.Node.Index = undefined;
    const fn_proto = tree.fullFnProto(&buf, node) orelse return;

    var end_token = matchingParen(tree, fn_proto.lparen);
    if (fn_proto.ast.return_type.unwrap()) |return_node| {
        end_token = tree.lastToken(return_node);
    }

    const text = sourceSlice(arena, loaded, fn_proto.firstToken(), end_token) catch
        return error.OutOfMemory;
    try w.print("## Signature\n\n```zig\n{s}\n```\n\n", .{text});
}

fn matchingParen(tree: Ast, lparen: Ast.TokenIndex) Ast.TokenIndex {
    var depth: usize = 0;
    var token = lparen;
    while (token < tree.tokens.len) : (token += 1) {
        switch (tree.tokenTag(token)) {
            .l_paren => depth += 1,
            .r_paren => {
                depth -= 1;
                if (depth == 0) return token;
            },
            else => {},
        }
    }
    return lparen;
}

/// A `pub const X = struct {...}` stores the container/error-set in the
/// initializer; fields and errors live there, not on the var decl node.
fn declExpr(tree: Ast, node: Ast.Node.Index) Ast.Node.Index {
    if (tree.fullVarDecl(node)) |var_decl| {
        return var_decl.ast.init_node.unwrap() orelse node;
    }
    return node;
}

/// For a namespace entry, the declaring file is the parent module; the actual
/// namespace lives in the imported file (e.g. `std.mem.Allocator` is declared
/// in mem.zig but defined by mem/Allocator.zig).
fn namespacePath(
    arena: Allocator,
    loaded: *const Loaded,
    node: Ast.Node.Index,
) Error![]const u8 {
    const tree = loaded.tree;
    const var_decl = tree.fullVarDecl(node) orelse return loaded.path;
    const init = var_decl.ast.init_node.unwrap() orelse return loaded.path;
    var buf: [2]Ast.Node.Index = undefined;
    const import_path = stdlib.importPath(&tree, init, &buf) orelse return loaded.path;
    const dir = std.fs.path.dirname(loaded.path) orelse ".";
    return std.fs.path.resolveAlloc(arena, &.{ dir, import_path }) catch error.OutOfMemory;
}

fn moduleDocs(arena: Allocator, loaded: *const Loaded) Error!?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var token: Ast.TokenIndex = 0;
    while (token < loaded.tree.tokens.len) : (token += 1) {
        if (loaded.tree.tokenTag(token) != .container_doc_comment) break;
        const raw = loaded.tree.tokenSlice(token);
        const body = if (std.mem.startsWith(u8, raw, "//!")) raw[3..] else raw;
        const text = if (body.len != 0 and body[0] == ' ') body[1..] else body;
        out.appendSlice(arena, text) catch return error.OutOfMemory;
        out.append(arena, '\n') catch return error.OutOfMemory;
    }
    if (out.items.len == 0) return null;
    return std.mem.trimEnd(u8, out.items, "\n");
}

fn renderSource(w: *std.Io.Writer, loaded: *const Loaded, node: Ast.Node.Index) Error!void {
    const tree = loaded.tree;
    const first = tree.firstToken(node);
    const last = tree.lastToken(node);
    const text = sourceSlice(loaded.gpa, loaded, first, last) catch return error.OutOfMemory;
    defer loaded.gpa.free(text);

    // An extern/prototype declaration has no body: the signature already
    // showed everything, so don't print the same text twice.
    try w.print("## Source Code\n\n```zig\n{s}\n```\n", .{text});
}

fn renderFields(w: *std.Io.Writer, arena: Allocator, loaded: *const Loaded, node: Ast.Node.Index) Error!void {
    const tree = loaded.tree;
    var cbuf: [2]Ast.Node.Index = undefined;
    const container = tree.fullContainerDecl(&cbuf, declExpr(tree, node)) orelse return;

    var fields: std.ArrayList([]const u8) = .empty;
    for (container.ast.members) |member| {
        const field = tree.fullContainerField(member) orelse continue;
        const first = field.firstToken();
        const last = if (field.ast.value_expr.unwrap()) |value|
            tree.lastToken(value)
        else if (field.ast.type_expr.unwrap()) |type_node|
            tree.lastToken(type_node)
        else
            field.ast.main_token;
        const text = sourceSlice(arena, loaded, first, last) catch return error.OutOfMemory;
        fields.append(arena, text) catch return error.OutOfMemory;
    }

    if (fields.items.len == 0) return;
    try w.writeAll("## Fields\n\n");
    for (fields.items) |field| {
        try w.print("- `{s}`\n", .{field});
    }
    try w.writeAll("\n");
}

fn renderErrors(w: *std.Io.Writer, arena: Allocator, loaded: *const Loaded, node: Ast.Node.Index) Error!void {
    const tree = loaded.tree;
    const expr = declExpr(tree, node);
    if (tree.nodeTag(expr) != .error_set_decl) return;

    const braces = tree.nodeData(expr).token_and_token;
    var errors: std.ArrayList([]const u8) = .empty;
    var token = braces[0] + 1;
    while (token < braces[1]) : (token += 1) {
        if (tree.tokenTag(token) != .identifier) continue;
        errors.append(arena, tree.tokenSlice(token)) catch return error.OutOfMemory;
    }

    if (errors.items.len == 0) return;
    try w.writeAll("## Errors\n\n");
    for (errors.items) |name| {
        try w.print("- `{s}`\n", .{name});
    }
    try w.writeAll("\n");
}

fn renderMembers(w: *std.Io.Writer, arena: Allocator, index: *const stdlib.Index, prefix: []const u8) Error!void {
    const buckets = [_]struct { title: []const u8, kinds: []const stdlib.Kind }{
        .{ .title = "Types", .kinds = &.{ .container, .type_function } },
        .{ .title = "Namespaces", .kinds = &.{.namespace} },
        .{ .title = "Error Sets", .kinds = &.{.error_set} },
        .{ .title = "Functions", .kinds = &.{.function} },
        .{ .title = "Global Variables", .kinds = &.{.global_var} },
        .{ .title = "Values", .kinds = &.{ .global_const, .alias } },
    };

    for (buckets) |bucket| {
        var names: std.ArrayList([]const u8) = .empty;
        for (index.entries) |*entry| {
            if (!std.mem.startsWith(u8, entry.fqn, prefix)) continue;
            if (entry.fqn.len <= prefix.len + 1) continue;
            if (entry.fqn[prefix.len] != '.') continue;
            const rest = entry.fqn[prefix.len + 1 ..];
            if (std.mem.indexOfScalar(u8, rest, '.') != null) continue;

            for (bucket.kinds) |kind| {
                if (entry.kind != kind) continue;
                names.append(arena, entry.name) catch return error.OutOfMemory;
                break;
            }
        }
        if (names.items.len == 0) continue;

        std.sort.heap([]const u8, names.items, {}, nameLessThan);
        try w.print("## {s}\n\n", .{bucket.title});
        for (names.items) |name| {
            try w.print("- `{s}`\n", .{name});
        }
        try w.writeAll("\n");
    }
}

fn nameLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

// ---------------------------------------------------------------------------
// Source slicing helpers
// ---------------------------------------------------------------------------

fn exprText(arena: Allocator, loaded: *const Loaded, node: Ast.Node.Index) Error![]const u8 {
    return sourceSlice(arena, loaded, loaded.tree.firstToken(node), loaded.tree.lastToken(node)) catch
        return error.OutOfMemory;
}

fn sourceSlice(
    allocator: Allocator,
    loaded: *const Loaded,
    first: Ast.TokenIndex,
    last: Ast.TokenIndex,
) ![]const u8 {
    const start = loaded.tree.tokenStart(first);
    const end_token = loaded.tree.tokenStart(last);
    const end = end_token + loaded.tree.tokenSlice(last).len;
    return allocator.dupe(u8, loaded.source[start..end]);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const fixture_dir = "tests/fixtures/mini-std";

fn testIndex(gpa: Allocator) !stdlib.Index {
    return stdlib.build(gpa, testing.io, fixture_dir);
}

fn renderToString(
    allocator: Allocator,
    index: *const stdlib.Index,
    fqn: []const u8,
    options: Options,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    try render(&aw.writer, arena_state.allocator(), allocator, testing.io, index, fqn, options);
    return allocator.dupe(u8, aw.written());
}

test "get: function renders docs, signature, and source" {
    var index = try testIndex(testing.allocator);
    defer index.deinit();

    const out = try renderToString(testing.allocator, &index, "std.Foo.Thing.hello", .{});
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "# std.Foo.Thing.hello") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Say hello from foo.") != null);
    try testing.expect(std.mem.indexOf(u8, out, "## Signature\n\n```zig\npub fn hello() void\n```") != null);
    try testing.expect(std.mem.indexOf(u8, out, "## Source Code") != null);
}

test "get: the std. prefix may be omitted" {
    var index = try testIndex(testing.allocator);
    defer index.deinit();

    const out = try renderToString(testing.allocator, &index, "Foo.Thing.hello", .{});
    defer testing.allocator.free(out);

    try testing.expect(std.mem.startsWith(u8, out, "# std.Foo.Thing.hello\n"));
}

test "get: error sets list their errors" {
    var index = try testIndex(testing.allocator);
    defer index.deinit();

    const out = try renderToString(testing.allocator, &index, "std.Oops", .{});
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "## Errors") != null);
    try testing.expect(std.mem.indexOf(u8, out, "- `Bad`") != null);
    try testing.expect(std.mem.indexOf(u8, out, "- `Worse`") != null);
}

test "get: alias resolves to its target and says so" {
    var index = try testIndex(testing.allocator);
    defer index.deinit();

    const out = try renderToString(testing.allocator, &index, "std.Alias", .{});
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "# std.Alias") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Alias of `Foo.Thing`.") != null);
    try testing.expect(std.mem.indexOf(u8, out, "## Functions") != null);
    try testing.expect(std.mem.indexOf(u8, out, "- `hello`") != null);
}

test "get: namespace shows module docs, fields, and members" {
    var index = try testIndex(testing.allocator);
    defer index.deinit();

    const out = try renderToString(testing.allocator, &index, "std.Mem", .{});
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "Minimal allocator-ish interface.") != null);
    try testing.expect(std.mem.indexOf(u8, out, "## Fields") != null);
    try testing.expect(std.mem.indexOf(u8, out, "- `ptr: *anyopaque`") != null);
    try testing.expect(std.mem.indexOf(u8, out, "- `vtable: *const VTable`") != null);
    try testing.expect(std.mem.indexOf(u8, out, "- `VTable`") != null);
    try testing.expect(std.mem.indexOf(u8, out, "- `alloc`") != null);
    // private decls are never rendered
    try testing.expect(std.mem.indexOf(u8, out, "secretHelper") == null);
}

test "get: --source-file prints the whole file" {
    var index = try testIndex(testing.allocator);
    defer index.deinit();

    const out = try renderToString(testing.allocator, &index, "std.Foo.Thing", .{ .source_file = true });
    defer testing.allocator.free(out);

    try testing.expect(std.mem.startsWith(u8, out, "# "));
    try testing.expect(std.mem.indexOf(u8, out, "foo.zig") != null);
    try testing.expect(std.mem.indexOf(u8, out, "pub fn hello() void") != null);
    try testing.expect(std.mem.indexOf(u8, out, "pub var counter") != null);
}

test "get: unknown declaration is NotFound" {
    var index = try testIndex(testing.allocator);
    defer index.deinit();

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    try testing.expectError(
        error.NotFound,
        render(&aw.writer, arena_state.allocator(), testing.allocator, testing.io, &index, "std.Nope", .{}),
    );
}
