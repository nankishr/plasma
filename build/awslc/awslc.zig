const std = @import("std");

pub const Set = struct {
    crypto_c: []const []const u8,
    crypto_asm: []const []const u8,
    jitter_c: []const []const u8,
    ssl_cc: []const []const u8,
};

pub const Libs = struct {
    crypto: *std.Build.Step.Compile,
    ssl: *std.Build.Step.Compile,
};

const base_flags: []const []const u8 = &.{
    "-fvisibility=hidden",
    "-fno-common",
    "-ffunction-sections",
    "-fdata-sections",
    "-fno-sanitize=undefined",
    "-DBORINGSSL_IMPLEMENTATION",
    "-DAWS_LC_STDALIGN_AVAILABLE",
    "-DAWS_LC_BUILTIN_SWAP_SUPPORTED",
    "-DBORINGSSL_RELEASE_BUILD",
    "-DNDEBUG",
    "-DS2N_BN_HIDE_SYMBOLS",
};

const linux_flags: []const []const u8 = &.{ "-DHAVE_LINUX_RANDOM_H", "-D_XOPEN_SOURCE=700" };
const jitter_flags: []const []const u8 = &.{ "-DAWSLC", "-fwrapv", "-O0", "-U_FORTIFY_SOURCE", "-fno-stack-protector" };
const gnu_flag: []const []const u8 = &.{"-std=gnu11"};
const cxx_flags: []const []const u8 = &.{ "-std=c++11", "-fno-exceptions", "-fno-rtti" };

fn load(b: *std.Build, target: std.Build.ResolvedTarget) !?Set {
    const path = b.fmt("build/awslc/generated/{s}_{s}.zon", .{
        @tagName(target.result.os.tag),
        @tagName(target.result.cpu.arch),
    });

    const bytes = std.Io.Dir.cwd().readFileAlloc(b.graph.io, path, b.allocator, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => {
            std.log.err("awslc: not found: {s}", .{path});
            return null;
        },
        else => return err,
    };
    const source = try b.allocator.allocSentinel(u8, bytes.len, 0);
    @memcpy(source, bytes);

    var diag: std.zon.parse.Diagnostics = undefined;
    return std.zon.parse.fromSlice(Set, .{
        .gpa = b.allocator,
        .arena = b.allocator,
        .source = source,
        .diagnostics = &diag,
    }) catch |err| switch (err) {
        error.ParseZon => diag.fatal(path),
        error.OutOfMemory => |e| return e,
    };
}

pub fn build(b: *std.Build, target: std.Build.ResolvedTarget, dep: *std.Build.Dependency) !?Libs {
    const set = (try load(b, target)) orelse return null;

    const crypto_mod = b.createModule(.{
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
        .pic = true,
    });

    const ssl_mod = b.createModule(.{
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
        .link_libcpp = true,
        .pic = true,
    });

    var common: std.ArrayList([]const u8) = .empty;
    try common.appendSlice(b.allocator, base_flags);
    if (target.result.os.tag == .linux) try common.appendSlice(b.allocator, linux_flags);

    crypto_mod.addIncludePath(dep.path("include"));
    crypto_mod.addIncludePath(dep.path("third_party/jitterentropy/jitterentropy-library"));
    crypto_mod.addIncludePath(dep.path("third_party/s2n-bignum/s2n-bignum-imported/include"));

    crypto_mod.addCSourceFiles(.{
        .root = dep.path("."),
        .files = try std.mem.concat(b.allocator, []const u8, &.{ set.crypto_c, set.crypto_asm }),
        .flags = try std.mem.concat(b.allocator, []const u8, &.{ common.items, gnu_flag }),
    });

    crypto_mod.addCSourceFiles(.{
        .root = dep.path("."),
        .files = set.jitter_c,
        .flags = try std.mem.concat(b.allocator, []const u8, &.{ common.items, jitter_flags, gnu_flag }),
    });

    ssl_mod.addIncludePath(dep.path("include"));
    ssl_mod.addCSourceFiles(.{
        .root = dep.path("."),
        .files = try byExt(b, set.ssl_cc, true),
        .flags = try std.mem.concat(b.allocator, []const u8, &.{ common.items, cxx_flags }),
    });
    ssl_mod.addCSourceFiles(.{
        .root = dep.path("."),
        .files = try byExt(b, set.ssl_cc, false),
        .flags = try std.mem.concat(b.allocator, []const u8, &.{ common.items, gnu_flag }),
    });

    return .{
        .crypto = b.addLibrary(.{ .name = "crypto", .linkage = .static, .root_module = crypto_mod }),
        .ssl = b.addLibrary(.{ .name = "ssl", .linkage = .static, .root_module = ssl_mod }),
    };
}

fn byExt(b: *std.Build, files: []const []const u8, comptime cpp: bool) ![]const []const u8 {
    var l: std.ArrayList([]const u8) = .empty;
    for (files) |f| {
        const is_cpp = std.mem.endsWith(u8, f, ".cpp") or std.mem.endsWith(u8, f, ".cc");
        if (is_cpp == cpp) try l.append(b.allocator, f);
    }
    return l.items;
}
