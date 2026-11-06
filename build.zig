const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const is_dev = optimize == .debug;

    const exe = b.addExecutable(.{
        .name = "plasma",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .strip = !is_dev,
        }),
    });

    exe.lto = if (is_dev) .none else .full;

    const awslc_dep = b.dependency("aws_lc_zig", .{
        .target = target,
        .optimize = optimize,
        .ssl = false
    });

    const crypto = awslc_dep.artifact("crypto");

    exe.root_module.linkLibrary(crypto);


    const mimalloc_dep = b.dependency("mimalloc", .{});
    exe.root_module.addIncludePath(mimalloc_dep.path("include"));

    exe.root_module.addCSourceFile(.{
        .file = mimalloc_dep.path("src/static.c"),
        .flags = &.{
            "-O3",
            "-DNDEBUG",
            "-DMI_STATIC_LIB",
            "-DMI_OPT_ARCH=1",
            "-DMI_OPT_SIMD=1",
            "-DMI_SECURE=0",
            "-DMI_DEBUG=0",
            "-DMI_TRACK=0",
            "-DMI_STATS=0",
            "-DMI_PROFILE=0",
            "-DMI_FREE_IS_CHECKED=0",
            "-DMI_GUARDED=0",
            "-DMI_PADDING=0",
            "-DMI_FREE_USE_PAGEMAP=0",
            "-DMI_DEFAULT_ALLOW_THP=2",
            "-DMI_OPT_FREE_SMALL=1",
            "-fno-builtin-malloc",
            "-fno-builtin-free",
        },
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());
}