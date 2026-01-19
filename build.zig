const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "bbnotes",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{},
        }),
    });

    const vaxis = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addImport("vaxis", vaxis.module("vaxis"));

    //const zig_time_dep = b.dependency("zig-time", .{});
    //exe.root_module.addImport("zig-time", zig_time_dep.module("zig-time"));

    const dmp = b.dependency("diffmatchpatch", .{});
    exe.root_module.addImport("diffmatchpatch", dmp.module("diffmatchpatch"));

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}
