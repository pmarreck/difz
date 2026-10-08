const std = @import("std");
const zstd_patch = @import("zstd_patch.zig");

pub const PatchError = zstd_patch.Error;

/// Reconstruct the target from a ZDIF v4 patch. The source BLAKE3 is checked
/// before the output buffer is allocated.
pub fn patch(allocator: std.mem.Allocator, a: []const u8, diff_blob: []const u8) PatchError![]u8 {
	return zstd_patch.applyLimited(allocator, a, diff_blob, 0);
}

pub fn patchLimited(
	allocator: std.mem.Allocator,
	a: []const u8,
	diff_blob: []const u8,
	max_output_bytes: usize,
) PatchError![]u8 {
	return zstd_patch.applyLimited(allocator, a, diff_blob, max_output_bytes);
}
