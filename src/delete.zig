const std = @import("std");

const cli = @import("cli.zig");
const glob = @import("glob.zig");

pub const Request = struct {
    root_path: []const u8,
    patterns: []const cli.Pattern,
};

pub const Stats = struct {
    scanned: usize = 0,
    deleted: usize = 0,
};

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: Request,
) !Stats {
    std.debug.assert(request.root_path.len > 0);
    std.debug.assert(request.patterns.len > 0);

    var root = try std.Io.Dir.cwd().openDir(io, request.root_path, .{
        .access_sub_paths = true,
        .iterate = true,
        .follow_symlinks = false,
    });
    defer root.close(io);

    var walker = try root.walkSelectively(allocator);
    defer walker.deinit();

    var stats: Stats = .{};
    while (try walker.next(io)) |entry| {
        stats.scanned += 1;

        if (matchesAnyPattern(entry, request.patterns)) {
            try deleteEntry(io, entry);
            stats.deleted += 1;
            continue;
        }

        if (entry.kind == .directory) {
            try walker.enter(io, entry);
        }
    }

    return stats;
}

fn matchesAnyPattern(entry: std.Io.Dir.Walker.Entry, patterns: []const cli.Pattern) bool {
    for (patterns) |pattern| {
        if (!kindMatches(pattern.kind, entry.kind)) continue;
        const candidate = candidatePath(entry, pattern);
        if (glob.matches(pattern.text, candidate, pattern.has_wildcard)) return true;
    }

    return false;
}

fn deleteEntry(io: std.Io, entry: std.Io.Dir.Walker.Entry) !void {
    switch (entry.kind) {
        .directory => try entry.dir.deleteTree(io, entry.basename),
        .file, .sym_link => try entry.dir.deleteFile(io, entry.basename),
        else => unreachable,
    }
}

fn kindMatches(pattern_kind: cli.PatternKind, entry_kind: std.Io.File.Kind) bool {
    return switch (pattern_kind) {
        .directory => entry_kind == .directory,
        .file => entry_kind == .file,
        .any => entry_kind == .directory or entry_kind == .file or entry_kind == .sym_link,
    };
}

fn candidatePath(entry: std.Io.Dir.Walker.Entry, pattern: cli.Pattern) []const u8 {
    return if (pattern.match_path) entry.path else entry.basename;
}

test "run deletes matching directories without deleting siblings" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "keep/nested");
    try tmp.dir.createDirPath(io, "remove_me/nested");
    try tmp.dir.writeFile(io, .{ .sub_path = "keep/file.txt", .data = "keep" });
    try tmp.dir.writeFile(io, .{ .sub_path = "remove_me/nested/file.txt", .data = "delete" });

    const root_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(root_path);

    const patterns = [_]cli.Pattern{.{
        .text = "remove_*",
        .kind = .directory,
        .match_path = false,
        .has_wildcard = true,
    }};
    const stats = try run(std.testing.allocator, io, .{
        .root_path = root_path,
        .patterns = &patterns,
    });

    try std.testing.expect(stats.scanned >= 2);
    try std.testing.expectEqual(@as(usize, 1), stats.deleted);
    try tmp.dir.access(io, "keep/file.txt", .{});
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "remove_me", .{}));
}

test "run deletes matching files" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "keep.txt", .data = "keep" });
    try tmp.dir.writeFile(io, .{ .sub_path = "remove.log", .data = "delete" });

    const root_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(root_path);

    const patterns = [_]cli.Pattern{.{
        .text = "*.log",
        .kind = .file,
        .match_path = false,
        .has_wildcard = true,
    }};
    const stats = try run(std.testing.allocator, io, .{
        .root_path = root_path,
        .patterns = &patterns,
    });

    try std.testing.expect(stats.scanned >= 2);
    try std.testing.expectEqual(@as(usize, 1), stats.deleted);
    try tmp.dir.access(io, "keep.txt", .{});
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "remove.log", .{}));
}
