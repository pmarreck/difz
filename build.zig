const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    // Default to a musl target on Linux so binaries are fully static (no dynamic
    // interpreter) and thus runnable on NixOS, whose ld-linux/ld-musl loaders do
    // not exist — a glibc-dynamic build compiles green but cannot exec. macOS
    // stays default (libSystem is dynamic; Apple forbids fully-static binaries).
    const target = b.standardTargetOptions(.{
        .default_target = if (builtin.os.tag == .linux) .{ .abi = .musl } else .{},
    });
    // static iff musl (no loader needed); glibc/macOS stay dynamic.
    const link_mode: std.builtin.LinkMode =
        if (target.result.abi == .musl) .static else .dynamic;
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Optimization mode (default: ReleaseFast)",
    ) orelse .ReleaseFast;

    // PCRE2 powers dirtree-compatible allowlist and denylist path globs.
    const pcre2_dep = b.dependency("pcre2", .{
        .target = target,
        .optimize = optimize,
        .linkage = .static,
        .@"code-unit-width" = .@"8",
    });
    const pcre2_lib = pcre2_dep.artifact("pcre2-8");

    // zstdz is the only compressor. File patches are level-9 prefix frames.
    const zstd_lib = b.dependency("zstdz", .{
        .target = target,
        .optimize = optimize,
    }).artifact("zstd");

    const xattr_dep = b.dependency("xattr_stream", .{
        .target = target,
        .optimize = optimize,
    });
    const xattr_mod = xattr_dep.module("xattr_stream");

    // Build a static lib from source — progrez's build.zig registers both
    // static and dynamic libs with the same name, making artifact() ambiguous.
    const progrez_dep = b.dependency("progrez", .{
        .target = target,
        .optimize = optimize,
    });
    const progrez_lib = b.addLibrary(.{
        .name = "progrez",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = progrez_dep.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    // Create the difz module
    const difz_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "xattr_stream", .module = xattr_mod },
        },
    });
    difz_module.addIncludePath(pcre2_lib.getEmittedIncludeTree());
    difz_module.addIncludePath(zstd_lib.getEmittedIncludeTree());
    difz_module.linkLibrary(pcre2_lib);
    difz_module.linkLibrary(zstd_lib);
    difz_module.link_libc = true;
    if (target.result.os.tag == .windows) difz_module.linkSystemLibrary("advapi32", .{});

    // Static library (needs its own module instance)
    const lib_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "xattr_stream", .module = xattr_mod },
        },
    });
    lib_module.addIncludePath(pcre2_lib.getEmittedIncludeTree());
    lib_module.addIncludePath(zstd_lib.getEmittedIncludeTree());
    lib_module.linkLibrary(pcre2_lib);
    lib_module.linkLibrary(zstd_lib);
    lib_module.link_libc = true;
    if (target.result.os.tag == .windows) lib_module.linkSystemLibrary("advapi32", .{});

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "difz",
        .root_module = lib_module,
    });

    // The raw archive only contains difz objects. External callers get one
    // archive that also holds pcre2 and zstd, plus the public header.
    const flatten = b.addSystemCommand(&.{"bash"});
    flatten.addFileArg(b.path("scripts/flatten-static-lib"));
    const flattened = flatten.addOutputFileArg("libdifz.a");
    flatten.addFileArg(lib.getEmittedBin());
    flatten.addFileArg(pcre2_lib.getEmittedBin());
    flatten.addFileArg(zstd_lib.getEmittedBin());
    const install_flat = b.addInstallFileWithDir(flattened, .lib, "libdifz.a");
    const install_header = b.addInstallFileWithDir(b.path("src/difz.h"), .header, "difz.h");
    b.getInstallStep().dependOn(&install_flat.step);
    b.getInstallStep().dependOn(&install_header.step);

    // C CLI executable — dogfoods the FFI
    const c_flags: []const []const u8 = if (optimize == .Debug)
        &.{ "-std=c11", "-Wall", "-Wextra", "-Wpedantic", "-DDIFZ_DEBUG" }
    else
        &.{ "-std=c11", "-Wall", "-Wextra", "-Wpedantic", "-DNDEBUG" };

    const exe = b.addExecutable(.{
        .name = "difz",
        .root_module = b.createModule(.{
            .root_source_file = null,
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    exe.linkage = link_mode; // static on musl → runnable on NixOS without a loader
    exe.root_module.addCSourceFile(.{
        .file = b.path("src/difz.c"),
        .flags = c_flags,
    });
    exe.root_module.linkLibrary(lib);
    exe.root_module.linkLibrary(progrez_lib);
    exe.root_module.linkLibrary(pcre2_lib);
    exe.root_module.addIncludePath(b.path("src"));
    exe.root_module.addIncludePath(progrez_dep.path("include"));
    b.installArtifact(exe);

    // Tests
    const unit_tests = b.addTest(.{
        .root_module = difz_module,
    });
    unit_tests.linkage = link_mode; // static test binary execs in the Nix sandbox

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
