const std = @import("std");

const Io = std.Io;
const gpa = std.testing.allocator;
const io = std.testing.io;
const exe_path = @import("build_options").exe_path;

const Result = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: *Result) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
    }
};

fn writeFile(dir: Io.Dir, name: []const u8, bytes: []const u8) !void {
    var file = try dir.createFile(io, name, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var writer = file.writer(io, &buf);
    try writer.interface.writeAll(bytes);
    try writer.flush();
}

fn readFile(dir: Io.Dir, name: []const u8) ![]u8 {
    return dir.readFileAlloc(io, name, gpa, .limited(1024 * 1024));
}

fn envWithHome(home: ?[]const u8) !std.process.Environ.Map {
    var env = std.process.Environ.Map.init(gpa);
    errdefer env.deinit();
    if (home) |h| try env.put("HOME", h);
    return env;
}

fn runCase(
    dir: Io.Dir,
    case_name: []const u8,
    argv: []const []const u8,
    stdin_bytes: []const u8,
    env: ?*const std.process.Environ.Map,
) !Result {
    const in_name = try std.fmt.allocPrint(gpa, "{s}.in", .{case_name});
    defer gpa.free(in_name);
    const out_name = try std.fmt.allocPrint(gpa, "{s}.out", .{case_name});
    defer gpa.free(out_name);
    const err_name = try std.fmt.allocPrint(gpa, "{s}.err", .{case_name});
    defer gpa.free(err_name);

    try writeFile(dir, in_name, stdin_bytes);
    const stdin_file = try dir.openFile(io, in_name, .{});
    const stdout_file = try dir.createFile(io, out_name, .{});
    const stderr_file = try dir.createFile(io, err_name, .{});

    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .{ .file = stdin_file },
        .stdout = .{ .file = stdout_file },
        .stderr = .{ .file = stderr_file },
        .environ_map = env,
    });
    const term = try child.wait(io);

    return .{
        .term = term,
        .stdout = try readFile(dir, out_name),
        .stderr = try readFile(dir, err_name),
    };
}

fn expectCode(result: Result, code: u8) !void {
    switch (result.term) {
        .exited => |got| try std.testing.expectEqual(code, got),
        else => return error.TestUnexpectedResult,
    }
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

test "hook blocks a token" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var result = try runCase(tmp.dir, "block", &.{ exe_path, "hook" }, "{\"prompt\":\"use ghp_abc\"}", null);
    defer result.deinit();
    try expectCode(result, 2);
    try std.testing.expectEqualStrings("", result.stdout);
    try expectContains(result.stderr, "GitHub");
}

test "hook allows a clean prompt silently" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var result = try runCase(tmp.dir, "allow", &.{ exe_path, "hook" }, "{\"prompt\":\"hello\"}", null);
    defer result.deinit();
    try expectCode(result, 0);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "no args prints usage and exits 1" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var result = try runCase(tmp.dir, "noargs", &.{exe_path}, "", null);
    defer result.deinit();
    try expectCode(result, 1);
    try expectContains(result.stderr, "Usage: enforcer");
    try std.testing.expectEqualStrings("", result.stdout);
}

test "--help exits 0" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var result = try runCase(tmp.dir, "help", &.{ exe_path, "--help" }, "", null);
    defer result.deinit();
    try expectCode(result, 0);
    try expectContains(result.stdout, "Usage: enforcer");
}

test "on with an empty home exits 1 without creating state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try std.fs.path.join(gpa, &.{ ".zig-cache/tmp", &tmp.sub_path });
    defer gpa.free(home);
    var env = try envWithHome(home);
    defer env.deinit();

    var result = try runCase(tmp.dir, "emptyhome", &.{ exe_path, "on" }, "", &env);
    defer result.deinit();
    try expectCode(result, 1);
    try expectContains(result.stderr, "no configured agent found");
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, ".pi", .{}));
}

test "on with HOME unset exits 1 without panicking" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = try envWithHome(null);
    defer env.deinit();

    var result = try runCase(tmp.dir, "nohome", &.{ exe_path, "on" }, "", &env);
    defer result.deinit();
    try expectCode(result, 1);
    try expectContains(result.stderr, "HOME is not set");
}

test "on and off are idempotent for Pi" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try std.fs.path.join(gpa, &.{ ".zig-cache/tmp", &tmp.sub_path });
    defer gpa.free(home);
    try tmp.dir.createDirPath(io, ".pi/agent");
    var env = try envWithHome(home);
    defer env.deinit();

    {
        var result = try runCase(tmp.dir, "on1", &.{ exe_path, "on" }, "", &env);
        defer result.deinit();
        try expectCode(result, 0);
        try expectContains(result.stdout, "pi: installed");
    }
    {
        var result = try runCase(tmp.dir, "on2", &.{ exe_path, "on" }, "", &env);
        defer result.deinit();
        try expectCode(result, 0);
        try expectContains(result.stdout, "pi: already installed");
    }
    const shim = try readFile(tmp.dir, ".pi/agent/extensions/enforcer.ts");
    defer gpa.free(shim);
    try expectContains(shim, "generated by `enforcer on`");
    try expectContains(shim, "spawnSync");

    {
        var result = try runCase(tmp.dir, "off1", &.{ exe_path, "off" }, "", &env);
        defer result.deinit();
        try expectCode(result, 0);
        try expectContains(result.stdout, "pi: removed");
    }
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, ".pi/agent/extensions/enforcer.ts", .{}));

    {
        var result = try runCase(tmp.dir, "off2", &.{ exe_path, "off" }, "", &env);
        defer result.deinit();
        try expectCode(result, 0);
        try expectContains(result.stdout, "pi: nothing to remove");
    }
}

test "on honors PI_CODING_AGENT_DIR" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try std.fs.path.join(gpa, &.{ ".zig-cache/tmp", &tmp.sub_path });
    defer gpa.free(home);
    const agent_dir = try std.fs.path.join(gpa, &.{ ".zig-cache/tmp", &tmp.sub_path, "custom-agent" });
    defer gpa.free(agent_dir);
    try tmp.dir.createDirPath(io, "custom-agent");
    var env = try envWithHome(home);
    defer env.deinit();
    try env.put("PI_CODING_AGENT_DIR", agent_dir);

    var result = try runCase(tmp.dir, "customagent", &.{ exe_path, "on" }, "", &env);
    defer result.deinit();
    try expectCode(result, 0);
    try expectContains(result.stdout, "pi: installed");

    const shim = try readFile(tmp.dir, "custom-agent/extensions/enforcer.ts");
    defer gpa.free(shim);
    try expectContains(shim, "generated by `enforcer on`");
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, ".pi", .{}));

    var removed = try runCase(tmp.dir, "customagentoff", &.{ exe_path, "off" }, "", &env);
    defer removed.deinit();
    try expectCode(removed, 0);
    try expectContains(removed.stdout, "pi: removed");
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "custom-agent/extensions/enforcer.ts", .{}));
}

test "off refuses a hand-written extension" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try std.fs.path.join(gpa, &.{ ".zig-cache/tmp", &tmp.sub_path });
    defer gpa.free(home);
    try tmp.dir.createDirPath(io, ".pi/agent/extensions");
    try writeFile(tmp.dir, ".pi/agent/extensions/enforcer.ts", "// mine\nexport default function () {}\n");
    var env = try envWithHome(home);
    defer env.deinit();

    var result = try runCase(tmp.dir, "handwritten", &.{ exe_path, "off" }, "", &env);
    defer result.deinit();
    try expectCode(result, 1);
    try expectContains(result.stderr, "NotOurFile");
    const shim = try readFile(tmp.dir, ".pi/agent/extensions/enforcer.ts");
    defer gpa.free(shim);
    try std.testing.expectEqualStrings("// mine\nexport default function () {}\n", shim);
}

test "on refuses a symlinked extension" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try std.fs.path.join(gpa, &.{ ".zig-cache/tmp", &tmp.sub_path });
    defer gpa.free(home);
    try tmp.dir.createDirPath(io, ".pi/agent/extensions");
    try writeFile(tmp.dir, ".pi/agent/target.ts", "target\n");
    try tmp.dir.symLink(io, "../target.ts", ".pi/agent/extensions/enforcer.ts", .{});
    var env = try envWithHome(home);
    defer env.deinit();

    var result = try runCase(tmp.dir, "symlink", &.{ exe_path, "on" }, "", &env);
    defer result.deinit();
    try expectCode(result, 1);
    try expectContains(result.stderr, "SettingsIsSymlink");
    const target = try readFile(tmp.dir, ".pi/agent/target.ts");
    defer gpa.free(target);
    try std.testing.expectEqualStrings("target\n", target);
}

test "concurrent on leaves one shim" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try std.fs.path.join(gpa, &.{ ".zig-cache/tmp", &tmp.sub_path });
    defer gpa.free(home);
    try tmp.dir.createDirPath(io, ".pi/agent");
    var env = try envWithHome(home);
    defer env.deinit();

    var children: [8]std.process.Child = undefined;
    var spawned: usize = 0;
    defer for (children[0..spawned]) |*child| child.kill(io);
    for (&children) |*child| {
        child.* = try std.process.spawn(io, .{
            .argv = &.{ exe_path, "on" },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
            .environ_map = &env,
        });
        spawned += 1;
    }
    for (children[0..spawned]) |*child| {
        const term = try child.wait(io);
        try std.testing.expect(term.success());
    }
    spawned = 0;

    const shim = try readFile(tmp.dir, ".pi/agent/extensions/enforcer.ts");
    defer gpa.free(shim);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, shim, "generated by `enforcer on`"));
}
