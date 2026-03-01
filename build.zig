const std = @import("std");

pub fn build(b: *std.Build) void {
	const target = b.standardTargetOptions(.{});
	const optimize = b.option(
		std.builtin.OptimizeMode,
		"optimize",
		"Optimization mode (default: ReleaseFast)",
	) orelse .ReleaseFast;

	// Get BLIP dependency
	const blip_dep = b.dependency("blip", .{
		.target = target,
		.optimize = optimize,
	});
	const blip_module = blip_dep.module("blip");

	// Get printable-binary dependency
	const pb_dep = b.dependency("printable_binary", .{
		.target = target,
		.optimize = optimize,
	});
	const pb_module = pb_dep.module("printable_binary");

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

	// Create the zdiff module
	const zdiff_module = b.createModule(.{
		.root_source_file = b.path("src/lib.zig"),
		.target = target,
		.optimize = optimize,
		.imports = &.{
			.{ .name = "blip", .module = blip_module },
			.{ .name = "printable_binary", .module = pb_module },
		},
	});

	// Static library (needs its own module instance)
	const lib_module = b.createModule(.{
		.root_source_file = b.path("src/lib.zig"),
		.target = target,
		.optimize = optimize,
		.imports = &.{
			.{ .name = "blip", .module = blip_module },
			.{ .name = "printable_binary", .module = pb_module },
		},
	});

	const lib = b.addLibrary(.{
		.linkage = .static,
		.name = "zdiff",
		.root_module = lib_module,
	});
	b.installArtifact(lib);

	// Install C header
	lib.installHeader(b.path("src/zdiff.h"), "zdiff.h");

	// C CLI executable — dogfoods the FFI
	const c_flags: []const []const u8 = if (optimize == .Debug)
		&.{ "-std=c11", "-Wall", "-Wextra", "-Wpedantic", "-DZDIFF_DEBUG" }
	else
		&.{ "-std=c11", "-Wall", "-Wextra", "-Wpedantic", "-DNDEBUG" };

	const exe = b.addExecutable(.{
		.name = "zdiff",
		.root_module = b.createModule(.{
			.root_source_file = null,
			.target = target,
			.optimize = optimize,
			.link_libc = true,
		}),
	});
	exe.addCSourceFile(.{
		.file = b.path("src/zdiff.c"),
		.flags = c_flags,
	});
	exe.linkLibrary(lib);
	exe.linkLibrary(progrez_lib);
	exe.root_module.addIncludePath(b.path("src"));
	exe.root_module.addIncludePath(progrez_dep.path("include"));
	b.installArtifact(exe);

	// Tests
	const unit_tests = b.addTest(.{
		.root_module = zdiff_module,
	});

	const run_unit_tests = b.addRunArtifact(unit_tests);
	const test_step = b.step("test", "Run unit tests");
	test_step.dependOn(&run_unit_tests.step);
}
