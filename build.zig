const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "sys-ink",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = true, // Remove debug symbols
            .link_libc = true, // Link libc for system calls and C interop
        }),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Tests. The root is src/tests.zig rather than src/main.zig so the suite
    // runs on any host: main pulls in Linux-only syscalls that will not compile
    // on macOS or Windows.
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Type-check the hardware-facing modules without running anything. These
    // only build for Linux, so give them an explicit target.
    const check_target = b.resolveTargetQuery(.{ .os_tag = .linux, .abi = .musl });
    const check_exe = b.addExecutable(.{
        .name = "sys-ink-check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = check_target,
            .optimize = .Debug,
            .link_libc = true,
        }),
    });

    const check_step = b.step("check", "Type-check the Linux-only modules");
    check_step.dependOn(&check_exe.step);
}
