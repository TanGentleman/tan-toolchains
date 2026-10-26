//! File-level write helpers shared by adapters. Every byte that lands on disk
//! goes through `writeAtomic`; every install/remove is serialized by a lock and
//! verified after the change.

const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const max_file_bytes = 1024 * 1024;

pub const Action = enum { install, uninstall };

pub const Outcome = enum { changed, unchanged };

pub const Error = error{
    SettingsIsSymlink,
    SettingsNotRegularFile,
    SettingsTooLarge,
    VerifyFailed,
};

fn statExisting(io: Io, dir: Io.Dir, name: []const u8) !?Io.File.Stat {
    return dir.statFile(io, name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

fn readExisting(io: Io, gpa: Allocator, dir: Io.Dir, name: []const u8) !?[]u8 {
    const stat = try statExisting(io, dir, name) orelse return null;
    switch (stat.kind) {
        .sym_link => return error.SettingsIsSymlink,
        .file => {},
        else => return error.SettingsNotRegularFile,
    }
    if (stat.size > max_file_bytes) return error.SettingsTooLarge;
    return try dir.readFileAlloc(io, name, gpa, .limited(max_file_bytes));
}

fn lockFile(io: Io, dir: Io.Dir) !Io.File {
    return dir.createFile(io, ".enforcer.lock", .{
        .read = true,
        .truncate = false,
        .lock = .exclusive,
    });
}

/// Replace `name` with `bytes` if the content differs. The existing mode is
/// preserved, the replacement is a rename, and the result is re-read.
pub fn updateFile(io: Io, gpa: Allocator, dir: Io.Dir, name: []const u8, bytes: []const u8) !Outcome {
    const lock = try lockFile(io, dir);
    defer lock.close(io);

    const old = try readExisting(io, gpa, dir, name);
    defer if (old) |b| gpa.free(b);
    if (old) |b| {
        if (std.mem.eql(u8, b, bytes)) return .unchanged;
    }

    try writeAtomic(io, dir, name, bytes);
    const verified = try readExisting(io, gpa, dir, name) orelse return error.VerifyFailed;
    defer gpa.free(verified);
    if (!std.mem.eql(u8, verified, bytes)) return error.VerifyFailed;
    return .changed;
}

/// Remove `name` only when its first line matches `header`.
pub fn removeFile(io: Io, gpa: Allocator, dir: Io.Dir, name: []const u8, header: []const u8) !Outcome {
    const lock = try lockFile(io, dir);
    defer lock.close(io);

    const old = try readExisting(io, gpa, dir, name) orelse return .unchanged;
    defer gpa.free(old);

    const first_line = if (std.mem.indexOfScalar(u8, old, '\n')) |i| old[0..i] else old;
    if (!std.mem.eql(u8, first_line, header)) return error.NotOurFile;

    try dir.deleteFile(io, name);
    if (try statExisting(io, dir, name) != null) return error.VerifyFailed;
    return .changed;
}

/// The only writer. `createFileAtomic` plus `replace` keeps a crash from
/// truncating the destination, and the caller's mode survives the rename.
fn writeAtomic(io: Io, dir: Io.Dir, name: []const u8, bytes: []const u8) !void {
    var permissions: Io.File.Permissions = .default_file;
    if (try statExisting(io, dir, name)) |stat| {
        switch (stat.kind) {
            .sym_link => return error.SettingsIsSymlink,
            .file => permissions = stat.permissions,
            else => return error.SettingsNotRegularFile,
        }
    }

    var atomic = try dir.createFileAtomic(io, name, .{
        .permissions = permissions,
        .make_path = false,
        .replace = true,
    });
    defer atomic.deinit(io);

    var buf: [4096]u8 = undefined;
    var writer = atomic.file.writer(io, &buf);
    try writer.interface.writeAll(bytes);
    try writer.flush();
    try atomic.file.sync(io);
    try atomic.replace(io);
}

test "updateFile writes once and then reports unchanged" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std.testing.expectEqual(Outcome.changed, try updateFile(io, gpa, tmp.dir, "file", "hello\n"));
    try std.testing.expectEqual(Outcome.unchanged, try updateFile(io, gpa, tmp.dir, "file", "hello\n"));

    const got = try tmp.dir.readFileAlloc(io, "file", gpa, .limited(max_file_bytes));
    defer gpa.free(got);
    try std.testing.expectEqualStrings("hello\n", got);
}

test "removeFile refuses a file it did not write" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try updateFile(io, gpa, tmp.dir, "file", "hand written\n");
    try std.testing.expectError(error.NotOurFile, removeFile(io, gpa, tmp.dir, "file", "generated"));
    const got = try tmp.dir.readFileAlloc(io, "file", gpa, .limited(max_file_bytes));
    defer gpa.free(got);
    try std.testing.expectEqualStrings("hand written\n", got);
}

test "updateFile refuses a symlink target" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "real");
    try updateFile(io, gpa, tmp.dir, "real/target", "original\n");
    try tmp.dir.symLink(io, "real/target", "file", .{});
    try std.testing.expectError(error.SettingsIsSymlink, updateFile(io, gpa, tmp.dir, "file", "changed\n"));

    const got = try tmp.dir.readFileAlloc(io, "real/target", gpa, .limited(max_file_bytes));
    defer gpa.free(got);
    try std.testing.expectEqualStrings("original\n", got);
}
