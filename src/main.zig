const std = @import("std");

const cli = @import("cli.zig");
const delete = @import("delete.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(allocator);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    const options = cli.parse(allocator, args) catch |err| {
        try stderr.print("error: {s}\n\n", .{@errorName(err)});
        try cli.writeUsage(stderr);
        try stderr.flush();
        std.process.exit(1);
    };

    if (options.help) {
        try cli.writeUsage(stdout);
        try stdout.flush();
        return;
    }

    const stats = delete.run(allocator, io, .{
        .root_path = options.root_path,
        .patterns = options.patterns.items,
    }) catch |err| {
        try stderr.print("delete failed: {s}\n", .{@errorName(err)});
        try stderr.flush();
        std.process.exit(1);
    };

    try stdout.print("scanned {d}, deleted {d}\n", .{ stats.scanned, stats.deleted });
    try stdout.flush();
}

test {
    _ = cli;
    _ = delete;
}
