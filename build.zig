const std = @import("std");

pub fn build(b: *std.Build) void {
    _ = b.addModule("cpuinfo", .{
        .source_file = .{ .path = "cpuinfo.zig" },
    });

    const test_step = b.addTest(.{
        .root_source_file = .{ .path = "cpuinfo.zig" },
    });
    if (@import("builtin").os.tag == .windows) {
        test_step.linkLibC();
    }
    b.step("test", "Run library tests").dependOn(&test_step.step);
}
