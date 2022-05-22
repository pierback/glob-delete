const std = @import("std");
const builtin = @import("builtin");
const clap = @import("clap");

const debug = std.debug;
const fs = std.fs;
const mem = std.mem;
const io = std.io;
const os = std.os;
const allocPrint = std.fmt.allocPrint;

const stdout = std.io.getStdOut().writer();

const BufferedOutStream = std.io.BufferedOutStream;

const open_flags = .{
    .access_sub_paths = true,
    .iterate = true,
};

pub fn main() !void {
    var _gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = _gpa.allocator();

    var arg_it = try std.process.argsWithAllocator(allocator);
    // First we specify what parameters our program can take.
    // We can use `parseParamsComptime` to parse a string into an array of `Param(Help)`
    const params = comptime clap.parseParamsComptime(
        \\-h, --help             Display this help and exit.
        \\-p, --path <str>...  An option parameter which can be specified multiple times.
        \\-d, --dir <str>...  An option parameter which can be specified multiple times.
        \\-f, --file <str>...  An option parameter which can be specified multiple times.
        \\-n, --name <str>...  An option parameter which can be specified multiple times.
        \\<str>...
        \\
    );

    // Initalize our diagnostics, which can be used for reporting useful errors.
    // This is optional. You can also pass `.{}` to `clap.parse` if you don't
    // care about the extra information `Diagnostics` provides.
    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag,
    }) catch |err| {
        // Report useful error and exit
        diag.report(io.getStdErr().writer(), err) catch {};
        return err;
    };
    defer res.deinit();

    var name: ?[]const u8 = null;
    var path: ?[]const u8 = null;
    var dir: ?[]const u8 = null;
    var file: ?[]const u8 = null;

    if (res.args.help)
        debug.print("--help\n", .{});

    for (res.args.path) |s| {
        debug.print("--path = {s}\n", .{s});
        path = s;
    }
    for (res.args.dir) |s| {
        debug.print("--dir = {s}\n", .{s});
        dir = s;
    }
    for (res.args.file) |s| {
        debug.print("--file = {s}\n", .{s});
        file = s;
    }
    for (res.args.name) |s| {
        debug.print("--name = {s}\n", .{s});
        name = s;
    }

    const needle = name orelse file orelse dir;

    if (needle) |v| {
        const _path = try getPath(&allocator, path.?);

        // var file_content = std.ArrayList([]const u8).init(allocator);
        // defer file_content.deinit();

        var iter = std.mem.split(u8, v, ",");
        debug.print("v = {s}\n", .{v});

        while (iter.next()) |entry| {
            Finder.findAndDelete(&allocator, _path, entry) catch |err| {
                std.debug.print("Failed to find and delete {s}", .{err});
            };
            // try file_content.append(entry);
        }
        _ = _path;
    }

    _ = arg_it;
    _ = name;
    _ = dir;
    _ = file;
    _ = path;
    _ = needle;
}

fn returnCwd(gpa: *const std.mem.Allocator) anyerror![]const u8 {
    const allocator = gpa.*;

    var buf: [100]u8 = undefined;
    const _cwd = try std.os.getcwd(&buf);

    var path_buffer: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const real_path = try std.fs.realpath(_cwd, &path_buffer);

    const real_path_heap = try allocator.dupe(u8, real_path[0..]);
    return real_path_heap;
}
fn returnRealPath(gpa: *const std.mem.Allocator, path: []const u8) anyerror![]const u8 {
    const allocator = gpa.*;

    var path_buffer: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const real_path = try std.fs.realpath(path, &path_buffer);

    const real_path_heap = try allocator.dupe(u8, real_path[0..]);
    return real_path_heap;
}

pub fn getPath(gpa: *const std.mem.Allocator, path: []const u8) anyerror![]const u8 {
    if (Finder.contains(path, ".")) {
        return try returnCwd(gpa);
    } else {
        return try returnRealPath(gpa, path);
    }
}

pub const Finder = struct {
    pub fn findAndDelete(gpa: *const std.mem.Allocator, path: []const u8, folder_name: []const u8) anyerror!void {
        const allocator = gpa.*;

        var dir = try std.fs.openDirAbsolute(path, open_flags);
        errdefer dir.close();

        var walker = try dir.walk(allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            switch (entry.kind) {
                .Directory => {
                    if (matchTokenized(entry.path, folder_name)) {
                        const absolute_path = try fs.path.join(allocator, &[_][]const u8{ path, entry.path });

                        std.debug.print("Delete: {s}", .{absolute_path});
                        try fs.deleteTreeAbsolute(absolute_path);
                        std.debug.print(" ✅\n", .{});
                    }
                },
                else => {},
            }
        }
    }

    pub fn contains(string: []const u8, sub_string: []const u8) bool {
        return mem.indexOf(u8, string, sub_string) != null;
    }

    pub fn lastItem(gpa: *const std.mem.Allocator, it: *std.mem.SplitIterator(u8)) []const u8 {
        const last = stop: {
            var list = std.ArrayList([]const u8).init(gpa.*);
            while (it.next()) |s| {
                list.append(s) catch {
                    @panic("lastItem: conversion failed");
                };
            }
            const slice = list.toOwnedSlice();
            break :stop slice[slice.len - 1];
        };

        return last;
    }

    pub fn match(gpa: *const std.mem.Allocator, path: []const u8, name: []const u8) bool {
        var it = std.mem.split(u8, path, "/");

        return mem.eql(u8, lastItem(gpa, &it), name);
    }

    pub fn matchTokenized(path: []const u8, pattern: []const u8) bool {
        if (mem.eql(u8, pattern, "*")) return true;

        var pattern_length: usize = 0;
        var it = mem.tokenize(u8, pattern, "*");

        // pattern doesn't start with '*'
        var no_glob_start = pattern.len > 0 and pattern[0] != '*';

        while (it.next()) |substr| {
            if (mem.indexOf(u8, path[pattern_length..], substr)) |index_of_substr| {
                if (no_glob_start) {
                    // pattern doesn't start with '*'
                    // and the substring is found but is '0'
                    // thus, the pattern doesn't match
                    if (index_of_substr != 0) {
                        return false;
                    } else {
                        // set no_glob_start to false to not check again
                        no_glob_start = false;
                        std.debug.print("no_glob_start = {}\n", .{no_glob_start});
                    }
                }

                std.debug.print("current index = {}\n", .{pattern_length});
                std.debug.print("index_of_substr = {}\n", .{index_of_substr});
                std.debug.print("substr.len = {}\n", .{substr.len});

                // build the new path by replacing the substring with the pattern (bar)
                // but in terms of length /users/lib/foo/bars -> /users/lib/foo/bar
                // var path_length = "/users/lib/foo/bars".len;
                // var new_path = "/users/lib/foo/bar".len;
                // if pattern is bar --> there will be no match because the path is too short
                // if pattern is bar* --> there will be a match because there was match and due to the wildcard the lenght isn't the same relevant

                pattern_length = pattern_length + index_of_substr + substr.len;
                std.debug.print("new index = {}\n", .{pattern_length});
            } else return false;
        }

        _ = no_glob_start;

        const path_lengths_matches = pattern_length == path.len;
        const ends_with_wildcard = pattern[pattern.len - 1] == '*';

        return ends_with_wildcard or path_lengths_matches;
    }
};
