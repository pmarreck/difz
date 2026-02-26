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

	// Create the zdiff module
	const zdiff_module = b.createModule(.{
		.root_source_file = b.path("src/lib.zig"),
		.target = target,
		.optimize = optimize,
		.imports = &.{
			.{ .name = "blip", .module = blip_module },
		},
	});

	// Static library (needs its own module instance)
	const lib_module = b.createModule(.{
		.root_source_file = b.path("src/lib.zig"),
		.target = target,
		.optimize = optimize,
		.imports = &.{
			.{ .name = "blip", .module = blip_module },
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

	// Tests
	const unit_tests = b.addTest(.{
		.root_module = zdiff_module,
	});

	const run_unit_tests = b.addRunArtifact(unit_tests);
	const test_step = b.step("test", "Run unit tests");
	test_step.dependOn(&run_unit_tests.step);
}
