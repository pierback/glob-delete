const std = @import("std");
const deps = @import("./deps.zig");

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("zig-delete", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);

    deps.addAllTo(exe);
    exe.install();
}
