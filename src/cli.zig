const std = @import("std");

pub const patterns_max = 1024;

pub const ParseError = error{
    MissingOptionValue,
    MissingPattern,
    OutOfMemory,
    TooManyPatterns,
    UnknownOption,
};

pub const PatternKind = enum {
    file,
    directory,
    any,
};

pub const Pattern = struct {
    text: []const u8,
    kind: PatternKind,
    match_path: bool,
    has_wildcard: bool,
};

pub const Options = struct {
    root_path: []const u8 = ".",
    patterns: std.ArrayList(Pattern) = .empty,
    help: bool = false,
};

pub fn parse(allocator: std.mem.Allocator, args: []const [:0]const u8) ParseError!Options {
    var options: Options = .{};
    errdefer options.patterns.deinit(allocator);

    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            options.help = true;
        } else if (longAssignment(arg)) |assignment| {
            try applyLongAssignment(allocator, &options, assignment);
        } else if (isPathFlag(arg)) {
            try setRootPath(&options, try consumeOptionValue(args, &index));
        } else if (patternKindForFlag(arg)) |kind| {
            try appendPatterns(allocator, &options.patterns, try consumeOptionValue(args, &index), kind);
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownOption;
        } else {
            try appendPattern(allocator, &options.patterns, arg, .any);
        }
    }

    if (!options.help and options.patterns.items.len == 0) return error.MissingPattern;

    return options;
}

pub fn writeUsage(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll(
        \\usage: zig-delete [options] <pattern>...
        \\
        \\Options:
        \\  -p, --path <path>      root directory to scan (default: .)
        \\  -d, --dir <pattern>    delete directories matching a comma-separated pattern list
        \\  -f, --file <pattern>   delete files matching a comma-separated pattern list
        \\  -n, --name <pattern>   delete files or directories matching a comma-separated pattern list
        \\  -h, --help            show this help
        \\
        \\Patterns use '*' as a wildcard. Patterns with a path separator match relative paths;
        \\other patterns match basenames.
        \\
    );
}

const LongAssignment = struct {
    flag: []const u8,
    value: []const u8,
};

fn longAssignment(arg: []const u8) ?LongAssignment {
    if (!std.mem.startsWith(u8, arg, "--")) return null;
    const separator_index = std.mem.indexOfScalar(u8, arg, '=') orelse return null;

    return .{
        .flag = arg[0..separator_index],
        .value = arg[separator_index + 1 ..],
    };
}

fn applyLongAssignment(
    allocator: std.mem.Allocator,
    options: *Options,
    assignment: LongAssignment,
) ParseError!void {
    if (isPathFlag(assignment.flag)) {
        try setRootPath(options, assignment.value);

        return;
    }

    if (patternKindForFlag(assignment.flag)) |kind| {
        try appendPatterns(allocator, &options.patterns, assignment.value, kind);

        return;
    }

    return error.UnknownOption;
}

fn consumeOptionValue(args: []const [:0]const u8, index: *usize) ParseError![]const u8 {
    index.* += 1;
    if (index.* == args.len) return error.MissingOptionValue;

    return args[index.*];
}

fn setRootPath(options: *Options, root_path: []const u8) ParseError!void {
    if (root_path.len == 0) return error.MissingOptionValue;

    options.root_path = root_path;
}

fn isPathFlag(flag: []const u8) bool {
    return std.mem.eql(u8, flag, "-p") or std.mem.eql(u8, flag, "--path");
}

fn patternKindForFlag(flag: []const u8) ?PatternKind {
    if (std.mem.eql(u8, flag, "-d") or std.mem.eql(u8, flag, "--dir")) return .directory;
    if (std.mem.eql(u8, flag, "-f") or std.mem.eql(u8, flag, "--file")) return .file;
    if (std.mem.eql(u8, flag, "-n") or std.mem.eql(u8, flag, "--name")) return .any;

    return null;
}

fn appendPatterns(
    allocator: std.mem.Allocator,
    patterns: *std.ArrayList(Pattern),
    list: []const u8,
    kind: PatternKind,
) ParseError!void {
    const before_len = patterns.items.len;
    var iterator = std.mem.splitScalar(u8, list, ',');
    while (iterator.next()) |raw| {
        const text = std.mem.trim(u8, raw, " \t\r\n");
        if (text.len == 0) continue;
        try appendPattern(allocator, patterns, text, kind);
    }

    if (patterns.items.len == before_len) return error.MissingPattern;
}

fn appendPattern(
    allocator: std.mem.Allocator,
    patterns: *std.ArrayList(Pattern),
    text: []const u8,
    kind: PatternKind,
) ParseError!void {
    if (text.len == 0) return error.MissingPattern;
    if (patterns.items.len == patterns_max) return error.TooManyPatterns;
    try patterns.append(allocator, .{
        .text = text,
        .kind = kind,
        .match_path = hasPathSeparator(text),
        .has_wildcard = std.mem.indexOfScalar(u8, text, '*') != null,
    });
}

fn hasPathSeparator(pattern: []const u8) bool {
    return std.mem.indexOfScalar(u8, pattern, '/') != null or
        std.mem.indexOfScalar(u8, pattern, '\\') != null;
}

test "parse supports explicit and positional patterns" {
    const args = [_][:0]const u8{ "zig-delete", "--path=tmp", "--dir", "zig-cache,.zig-cache", "node_modules" };
    var options = try parse(std.testing.allocator, &args);
    defer options.patterns.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("tmp", options.root_path);
    try std.testing.expectEqual(@as(usize, 3), options.patterns.items.len);
    try std.testing.expectEqual(PatternKind.directory, options.patterns.items[0].kind);
    try std.testing.expectEqual(PatternKind.any, options.patterns.items[2].kind);
}

test "parse rejects empty pattern lists" {
    const args = [_][:0]const u8{ "zig-delete", "--dir", ",, " };

    try std.testing.expectError(error.MissingPattern, parse(std.testing.allocator, &args));
}

test "parse rejects empty path values" {
    const args = [_][:0]const u8{ "zig-delete", "--path=", "node_modules" };

    try std.testing.expectError(error.MissingOptionValue, parse(std.testing.allocator, &args));
}

test "parse cleans up allocated patterns after later errors" {
    const args = [_][:0]const u8{ "zig-delete", "--name", "node_modules", "--bad" };

    try std.testing.expectError(error.UnknownOption, parse(std.testing.allocator, &args));
}
