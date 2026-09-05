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

    // blar transitively needs zlib (deflate_emit.zig: PNG/ZIP) even with image
    // support off. For a static (musl) build the flake supplies a static zlib;
    // these point Zig at its headers/archive. Optional so a plain `zig build`
    // (dynamic, with system zlib on the default search path) still works.
    const zlib_include_path = b.option([]const u8, "zlib-include-path", "Path to zlib headers (zlib.h)");
    const zlib_lib_path = b.option([]const u8, "zlib-lib-path", "Path to zlib libraries");

    // Get blar dependency (provides compression_mod + re-exports BLIP varint via blar.core).
    // Disable blar's heavy/optional features — we only need its Zig-side compression API.
    // enable_image=false drops the libjxl link (we never call blar's JXL transcode);
    // zlib remains required by blar's deflate_emit, supplied via the paths below.
    const blar_dep = b.dependency("blar", .{
        .target = target,
        .optimize = optimize,
        .enable_flac = false,
        .enable_image = false,
    });

    // Get printable-binary dependency
    const pb_dep = b.dependency("printable_binary", .{
        .target = target,
        .optimize = optimize,
    });
    const pb_module = pb_dep.module("printable_binary");

    // PCRE2 powers dirtree-compatible allowlist and denylist path globs.
    const pcre2_dep = b.dependency("pcre2", .{
        .target = target,
        .optimize = optimize,
        .linkage = .static,
        .@"code-unit-width" = .@"8",
    });
    const pcre2_lib = pcre2_dep.artifact("pcre2-8");

    const blip_dep = b.dependency("blip", .{
        .target = target,
        .optimize = optimize,
    });
    const blip_mod = blip_dep.module("blip");
    const blip_lib = blip_dep.artifact("blip");
    const lz4_lib = b.dependency("lz4", .{
        .target = target,
        .optimize = optimize,
    }).artifact("lz4");
    const zstd_lib = b.dependency("zstdz", .{
        .target = target,
        .optimize = optimize,
    }).artifact("zstd");
    const bzip2z_mod = b.dependency("bzip2z", .{
        .target = target,
        .optimize = optimize,
    }).module("bzip2z");

    const lzma2_mod = b.createModule(.{
        .root_source_file = b.dependency("z7z", .{
            .target = target,
            .optimize = optimize,
        }).path("src/lzma2_encoder.zig"),
        .target = target,
        .optimize = optimize,
    });
    const z7z_compute = b.createModule(.{
        .root_source_file = b.path("src/z7z_compute.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "lzma2_encoder", .module = lzma2_mod },
        },
    });
    const blar_compression = b.createModule(.{
        .root_source_file = blar_dep.path("src/compression.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "blip", .module = blip_mod },
            .{ .name = "z7z", .module = z7z_compute },
            .{ .name = "bzip2z", .module = bzip2z_mod },
        },
    });
    blar_compression.linkLibrary(lz4_lib);
    blar_compression.linkLibrary(zstd_lib);
    blar_compression.addIncludePath(lz4_lib.getEmittedIncludeTree());
    blar_compression.addIncludePath(zstd_lib.getEmittedIncludeTree());
    if (zlib_include_path) |p| blar_compression.addSystemIncludePath(.{ .cwd_relative = p });
    if (zlib_lib_path) |p| blar_compression.addLibraryPath(.{ .cwd_relative = p });

    const blar_compute = b.createModule(.{
        .root_source_file = b.path("src/blar_compute.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "blip", .module = blip_mod },
            .{ .name = "compression", .module = blar_compression },
        },
    });

    // Get progrez dependency (C FFI progress library)
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
            .{ .name = "blar", .module = blar_compute },
            .{ .name = "printable_binary", .module = pb_module },
        },
    });
    difz_module.addIncludePath(pcre2_lib.getEmittedIncludeTree());
    difz_module.linkLibrary(pcre2_lib);
    difz_module.link_libc = true;

    // Static library (needs its own module instance)
    const lib_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "blar", .module = blar_compute },
            .{ .name = "printable_binary", .module = pb_module },
        },
    });
    lib_module.addIncludePath(pcre2_lib.getEmittedIncludeTree());
    lib_module.linkLibrary(pcre2_lib);
    lib_module.link_libc = true;

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "difz",
        .root_module = lib_module,
    });
    b.installArtifact(lib);

    // Install C header
    lib.installHeader(b.path("src/difz.h"), "difz.h");

    const flatten = b.addSystemCommand(&.{"bash"});
    flatten.addFileArg(b.path("scripts/flatten-static-lib"));
    const flattened = flatten.addOutputFileArg("libdifz.a");
    flatten.addFileArg(lib.getEmittedBin());
    flatten.addFileArg(pcre2_lib.getEmittedBin());
    flatten.addFileArg(blip_lib.getEmittedBin());
    flatten.addFileArg(lz4_lib.getEmittedBin());
    flatten.addFileArg(zstd_lib.getEmittedBin());
    const install_flat = b.addInstallFileWithDir(flattened, .lib, "libdifz.a");
    b.getInstallStep().dependOn(&install_flat.step);

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
    // blar's zlib is linked (-lz) via the imported module, but the library
    // *search path* must be on the final-linking artifact, not just the module
    // (it does not propagate through linkLibrary/import). Add it here too.
    if (zlib_lib_path) |p| exe.root_module.addLibraryPath(.{ .cwd_relative = p });
    b.installArtifact(exe);

    // Tests
    const unit_tests = b.addTest(.{
        .root_module = difz_module,
    });
    unit_tests.linkage = link_mode; // static test binary execs in the Nix sandbox
    if (zlib_lib_path) |p| unit_tests.root_module.addLibraryPath(.{ .cwd_relative = p });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
