const std = @import("std");

const awslc = @import("build/awslc/awslc.zig");

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

    const awslc_dep = b.dependency("aws-lc", .{});

    addVendorStep(b, awslc_dep);

    const libs = awslc.build(b, target, awslc_dep) catch |err| {
        std.debug.panic("aws-lc: {s}", .{@errorName(err)});
    };

    if (libs) |l| {
        exe.root_module.addIncludePath(awslc_dep.path("include"));
        exe.root_module.linkLibrary(l.crypto);
        exe.root_module.linkLibrary(l.ssl);
    } else {
        const fail = b.addFail(b.fmt("No vendored sources for {s}-{s}", .{
            @tagName(target.result.cpu.arch),
            @tagName(target.result.os.tag),
        }));
        exe.step.dependOn(&fail.step);
    }

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

fn addVendorStep(b: *std.Build, awslc_dep: *std.Build.Dependency) void {
    const run = b.addSystemCommand(&.{"python3"});
    run.addFileArg(b.path("scripts/vendor.py"));
    run.addArgs(&.{ "awslc", "--zig", b.graph.zig_exe, "--src" });
    run.addDirectoryArg2(awslc_dep.path("."), .{});
    run.addArg("--out");
    run.addDirectoryArg2(b.path("build/awslc"), .{});
    run.has_side_effects = true;
    run.stdio = .inherit;

    const step = b.step("vendor", "Regenerate vendored source lists");
    step.dependOn(&run.step);
}
