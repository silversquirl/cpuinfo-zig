const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const cpuinfo = b.addModule("cpuinfo", .{
        .root_source_file = b.path("cpuinfo.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = if (target.result.os.tag == .windows) true else null,
    });

    const test_step = b.addTest(.{ .root_module = cpuinfo });

    b.step("test", "Run library tests").dependOn(&b.addRunArtifact(test_step).step);
}
