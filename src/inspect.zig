const std = @import("std");
const testing = std.testing;
const zstd_patch = @import("zstd_patch.zig");

fn formatSize(buf: []u8, bytes: usize) []const u8 {
	if (bytes < 1024) {
		return std.fmt.bufPrint(buf, "{d}B", .{bytes}) catch "?";
	} else if (bytes < 1024 * 1024) {
		return std.fmt.bufPrint(buf, "{d:.1}KB", .{@as(f64, @floatFromInt(bytes)) / 1024.0}) catch "?";
	} else if (bytes < 1024 * 1024 * 1024) {
		return std.fmt.bufPrint(buf, "{d:.1}MB", .{@as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0)}) catch "?";
	} else {
		return std.fmt.bufPrint(buf, "{d:.1}GB", .{@as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0 * 1024.0)}) catch "?";
	}
}

fn hex32(bytes: [32]u8) [64]u8 {
	const alphabet = "0123456789abcdef";
	var out: [64]u8 = undefined;
	for (bytes, 0..) |byte, i| {
		out[i * 2] = alphabet[byte >> 4];
		out[i * 2 + 1] = alphabet[byte & 0xf];
	}
	return out;
}

/// Describe a ZDIF v4 patch: sizes, BLAKE3 identities, and the zstd frame.
/// The caller owns the returned text.
pub fn inspect(allocator: std.mem.Allocator, diff_blob: []const u8) ![]u8 {
	const parsed = try zstd_patch.info(diff_blob);
	if (diff_blob.len < zstd_patch.header_len) return error.Truncated;
	var source_size: [64]u8 = undefined;
	var target_size: [64]u8 = undefined;
	var frame_size: [64]u8 = undefined;
	const source_hex = hex32(parsed.source_blake3);
	const target_hex = hex32(parsed.target_blake3);
	return std.fmt.allocPrint(allocator,
		\\difz inspect: zstd level {d} patch-from, source={s}, target={s}, frame={s}
		\\source blake3: {s}
		\\target blake3: {s}
		\\
	, .{
		zstd_patch.level,
		formatSize(&source_size, parsed.size_a),
		formatSize(&target_size, parsed.size_b),
		formatSize(&frame_size, diff_blob.len - zstd_patch.header_len),
		source_hex,
		target_hex,
	});
}

test "inspect describes a zstd level 9 patch-from frame" {
	const patch = try zstd_patch.encode(testing.allocator, "hello", "hello!");
	defer testing.allocator.free(patch);
	const text = try inspect(testing.allocator, patch);
	defer testing.allocator.free(text);
	try testing.expect(std.mem.indexOf(u8, text, "zstd level 9 patch-from") != null);
	try testing.expect(std.mem.indexOf(u8, text, "source=5B") != null);
	try testing.expect(std.mem.indexOf(u8, text, "target=6B") != null);
	try testing.expect(std.mem.indexOf(u8, text, "source blake3:") != null);
	try testing.expect(std.mem.indexOf(u8, text, "target blake3:") != null);
}
