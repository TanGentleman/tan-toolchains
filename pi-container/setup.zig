//! pi-container-setup: runs the setup steps from README.md (branch tanuj/bootstrap),
//! then drops you into a Pi chat.
//!
//! usage: pi-container-setup [OWNER/REPO]
//!
//! Run it from the pi-container folder (the one with the Dockerfile and run.sh):
//!
//!   zig build
//!   ./zig-out/bin/pi-container-setup you/your-repo
//!
//! Steps, in README order:
//!   1. find the container CLI (/usr/local/bin/container, or PATH)
//!   2. container system start        (answer Y to install the default kernel)
//!   3. create ~/.config/pi-container/env with empty OPENROUTER_API_KEY/GITHUB_TOKEN
//!      (only if missing; existing keys are never overwritten) and chmod 600
//!   4. open -e ~/.config/pi-container/env, wait for you to paste the keys
//!      (skipped when both keys already have values)
//!   5. container build -t pi-agent:local .
//!   6. ./run.sh check [OWNER/REPO]   (validates both keys, costs nothing)
//!   7. ./run.sh                      (README, Use: Pi chat on this folder; /quit to exit)

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const usage =
    \\pi-container-setup: run the setup steps from pi-container/README.md, then chat
    \\
    \\usage: pi-container-setup [OWNER/REPO]
    \\
    \\
    \\Run from the pi-container folder (the one with the Dockerfile and run.sh).
    \\OWNER/REPO is the repo used by the `./run.sh check` validation step.
    \\
    \\Expects Apple's `container` CLI (default install: /usr/local/bin/container).
    \\
;

const env_template = "OPENROUTER_API_KEY=\nGITHUB_TOKEN=\n";

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;

    var stdout_buffer: [512]u8 = undefined;
    var out: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const w = &out.interface;

    if (builtin.os.tag != .macos) {
        try say(w, "pi-container-setup: needs macOS on Apple silicon (README, Setup)\n", .{});
        return 1;
    }

    const args = try init.minimal.args.toSlice(arena);
    if (args.len == 2 and (std.mem.eql(u8, args[1], "-h") or std.mem.eql(u8, args[1], "--help"))) {
        try w.writeAll(usage);
        try w.flush();
        return 0;
    }
    if (args.len > 2) {
        try w.writeAll(usage);
        try w.flush();
        return 2;
    }
    const repo: ?[]const u8 = if (args.len == 2) args[1] else null;

    // README: "Then, from this folder" — the build and check steps need Dockerfile/run.sh.
    for ([_][]const u8{ "Dockerfile", "Dockerfile.proxy", "proxy.py", "run.sh" }) |file| {
        Io.Dir.cwd().access(io, file, .{ .read = true }) catch {
            try say(w, "pi-container-setup: no {s} in the current folder; run me from the pi-container folder\n", .{file});
            return 2;
        };
    }

    // 1. find the container CLI: /usr/local/bin/container if installed there, else PATH
    try say(w, "== 1/7: find the container CLI\n", .{});
    const container = if (Io.Dir.accessAbsolute(io, "/usr/local/bin/container", .{ .execute = true })) |_| "/usr/local/bin/container" else |err| switch (err) {
        error.FileNotFound => blk: {
            try say(w, "   not in /usr/local/bin or /opt/homebrew/bin; trying PATH\n", .{});
            Io.Dir.accessAbsolute(io, "/opt/homebrew/bin/container", .{ .execute = true }) catch break :blk "container";
            break :blk "/opt/homebrew/bin/container";
        },
        else => return err,
    };
    const rc1 = try run(w, io, &.{ container, "--version" }, null);
    if (rc1 != 0) return rc1;

    // Make sure the child run.sh uses the CLI we found, even if it is not on PATH.
    var child_env = try init.environ_map.clone(arena);
    try child_env.put("CONTAINER_CLI", container);

    // 2. container system start
    try say(w, "== 2/7: container system start (answer Y to install the default kernel)\n", .{});
    const rc2 = try run(w, io, &.{ container, "system", "start" }, null);
    if (rc2 != 0) return rc2;

    // 3. mkdir -p ~/.config/pi-container; write the env skeleton if missing; chmod 600
    try say(w, "== 3/7: prepare ~/.config/pi-container/env (chmod 600)\n", .{});
    const home = init.environ_map.get("HOME") orelse {
        try say(w, "pi-container-setup: $HOME is not set\n", .{});
        return 1;
    };
    var home_dir = try Io.Dir.openDirAbsolute(io, home, .{});
    defer home_dir.close(io);
    try home_dir.createDirPath(io, ".config/pi-container");
    var cfg_dir = try home_dir.openDir(io, ".config/pi-container", .{});
    defer cfg_dir.close(io);

    const env_missing = if (cfg_dir.access(io, "env", .{ .read = true })) |_| false else |err| switch (err) {
        error.FileNotFound => true,
        else => return err,
    };
    if (env_missing) {
        try cfg_dir.writeFile(io, .{
            .sub_path = "env",
            .data = env_template,
        });
    }
    try cfg_dir.setFilePermissions(io, "env", Io.Dir.Permissions.fromMode(0o600), .{});

    // 4. open -e the env file only if either key is missing or still empty
    const env_data = cfg_dir.readFileAlloc(io, "env", arena, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => env_template, // just created; nothing pasted yet
        else => {
            try say(w, "pi-container-setup: cannot read the env file: {t}\n", .{err});
            return 1;
        },
    };
    const keys_ready = hasKey(env_data, "OPENROUTER_API_KEY=") and hasKey(env_data, "GITHUB_TOKEN=");
    const env_path = try std.fmt.allocPrint(arena, "{s}/.config/pi-container/env", .{home});
    if (keys_ready) {
        try say(w, "== 4/7: both keys already set in {s}; skipping the editor\n", .{env_path});
    } else {
        try say(w, "== 4/7: open {s} for editing\n", .{env_path});
        const rc4 = try run(w, io, &.{ "open", "-e", env_path }, null);
        if (rc4 != 0) return rc4;
        try say(w,
            \\   Paste OPENROUTER_API_KEY and GITHUB_TOKEN after the = signs (no quotes) and save.
            \\   (An existing env file was kept as-is; only empty values need filling in.)
            \\   Press Enter to continue...
        , .{});
        try w.flush();
        var stdin_buffer: [1]u8 = undefined;
        var stdin_reader: Io.File.Reader = .init(.stdin(), io, &stdin_buffer);
        while (true) {
            const byte = try stdin_reader.interface.takeByte();
            if (byte == 0 or byte == '\n') break; // 0 = end of stream
        }
        const updated = cfg_dir.readFileAlloc(io, "env", arena, .limited(1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => env_template,
            else => {
                try say(w, "pi-container-setup: cannot read the env file: {t}\n", .{err});
                return 1;
            },
        };
        if (!(hasKey(updated, "OPENROUTER_API_KEY=") and hasKey(updated, "GITHUB_TOKEN="))) {
            try say(w, "pi-container-setup: both keys are still empty; edit {s} and rerun\n", .{env_path});
            return 1;
        }
    }

    // 5. container build -t pi-agent:local .
    try say(w, "== 5/7: container build -t pi-agent:local .\n", .{});
    const rc5 = try run(w, io, &.{ container, "build", "-t", "pi-agent:local", "." }, null);
    if (rc5 != 0) return rc5;

    // 6. ./run.sh check [OWNER/REPO] — validates both keys, costs nothing
    if (repo) |r| {
        try say(w, "== 6/7: ./run.sh check {s}\n", .{r});
        const rc6 = try run(w, io, &.{ "./run.sh", "check", r }, &child_env);
        if (rc6 != 0) return rc6;
    } else {
        try say(w, "== 6/7: ./run.sh check (pass OWNER/REPO to also fetch the repo's HEAD)\n", .{});
        const rc6 = try run(w, io, &.{ "./run.sh", "check" }, &child_env);
        if (rc6 != 0) return rc6;
    }

    // 7. README, Use: Pi on this folder. An interactive chat — /quit exits, /model picks.
    try say(w, "== 7/7: ./run.sh — starting Pi on this folder (/quit to exit, /model to pick a model)\n", .{});
    const rc7 = try run(w, io, &.{"./run.sh"}, &child_env);
    if (rc7 != 0) return rc7;

    return 0;
}

fn say(w: *Io.Writer, comptime fmt: []const u8, args: anytype) !void {
    try w.print(fmt, args);
    try w.flush();
}

/// Runs a command with inherited stdio; returns its exit code (127 if not found).
fn run(w: *Io.Writer, io: Io, argv: []const []const u8, env: ?*const std.process.Environ.Map) !u8 {
    var child = std.process.spawn(io, .{ .argv = argv, .environ_map = env }) catch |err| switch (err) {
        error.FileNotFound => {
            try say(w, "pi-container-setup: '{s}' not found in PATH\n", .{argv[0]});
            return 127;
        },
        error.AccessDenied, error.InvalidExe => {
            try say(w, "pi-container-setup: cannot execute '{s}' ({t})\n", .{ argv[0], err });
            return 126;
        },
        else => return err,
    };
    const term = try child.wait(io);
    return switch (term) {
        .exited => |code| code,
        else => 1,
    };
}

/// True if `data` contains a line starting with `key` ("NAME=") whose value is non-empty.
fn hasKey(data: []const u8, comptime key: []const u8) bool {
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, key)) {
            const value = std.mem.trim(u8, trimmed[key.len..], " \t\r");
            if (value.len > 0) return true;
        }
    }
    return false;
}
