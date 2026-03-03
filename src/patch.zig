const std = @import("std");
const testing = std.testing;
const diff_mod = @import("diff.zig");
const encoding = @import("encoding.zig");

pub const PatchError = error{
	InvalidMagic,
	SizeMismatch,
	OutOfBounds,
	OutOfMemory,
	BufferTooSmall,
	UnexpectedEndOfInput,
	Overflow,
	InvalidContainerType,
	InvalidLength,
	LengthExceedsBounds,
	MissingRequiredKey,
	DuplicateKey,
	KeysNotSorted,
	HashMismatch,
	IndexOutOfBounds,
	InvalidSigilOrder,
	MissingDecompLen,
	MissingSigil,
	CompressionFailed,
	DecompressionFailed,
	UnsupportedCompression,
};

pub const PatchInfo = struct {
	size_a: usize,
	size_b: usize,
	seed: [32]u8,
	target_chunk_size: usize,
	num_ops: usize,
};

/// Decode a BLIP-encoded diff blob and apply it to source file A to reconstruct file B.
///
/// Steps:
/// 1. Decode the BLIP diff blob using encoding.decode()
/// 2. Verify size_a matches a.len (return error.SizeMismatch if not)
/// 3. Walk the decoded ops: Copy -> append a[offset..offset+length], Insert -> append data
/// 4. Verify result length matches size_b from metadata
/// 5. Return the reconstructed B as an owned slice
pub fn patch(allocator: std.mem.Allocator, a: []const u8, diff_blob: []const u8) PatchError![]u8 {
	// 1. Decode the diff blob
	const decoded = try encoding.decode(allocator, diff_blob);
	defer encoding.freeDecoded(allocator, decoded);

	// 2. Verify source size matches
	if (decoded.size_a != a.len) {
		return error.SizeMismatch;
	}

	// 3. Walk ops and build output
	const output = allocator.alloc(u8, decoded.size_b) catch return error.OutOfMemory;
	errdefer allocator.free(output);

	var pos: usize = 0;
	for (decoded.ops) |op| {
		switch (op.tag) {
			.copy => {
				// Bounds check against source A
				if (op.offset + op.length > a.len) {
					return error.OutOfBounds;
				}
				// Bounds check against output
				if (pos + op.length > output.len) {
					return error.OutOfBounds;
				}
				@memcpy(output[pos..][0..op.length], a[op.offset..][0..op.length]);
				pos += op.length;
			},
			.insert => {
				const data = op.data orelse return error.InvalidLength;
				// Bounds check against output
				if (pos + op.length > output.len) {
					return error.OutOfBounds;
				}
				@memcpy(output[pos..][0..op.length], data[0..op.length]);
				pos += op.length;
			},
		}
	}

	// 4. Verify result length matches size_b
	if (pos != decoded.size_b) {
		return error.SizeMismatch;
	}

	return output;
}

/// Read metadata from a BLIP-encoded diff blob without applying it.
/// Returns size_a, size_b, seed, target_chunk_size, and num_ops.
pub fn patchInfo(allocator: std.mem.Allocator, diff_blob: []const u8) PatchError!PatchInfo {
	const decoded = try encoding.decode(allocator, diff_blob);
	defer encoding.freeDecoded(allocator, decoded);

	return PatchInfo{
		.size_a = decoded.size_a,
		.size_b = decoded.size_b,
		.seed = decoded.seed,
		.target_chunk_size = decoded.target_chunk_size,
		.num_ops = decoded.ops.len,
	};
}

// ============================================================================
// Tests
// ============================================================================

test "full round-trip: diff then patch" {
	const a = "the quick brown fox " ** 50;
	const b = "the quick red fox " ** 50;
	const options = diff_mod.DiffOptions{ .seed = [_]u8{0} ** 32, .target_chunk_size = 64 };
	const result = try diff_mod.computeDiff(testing.allocator, a, b, options);
	defer diff_mod.freeDiffResult(testing.allocator, result);
	const encoded = try encoding.encode(testing.allocator, result, .lzma2);
	defer testing.allocator.free(encoded);
	const reconstructed = try patch(testing.allocator, a, encoded);
	defer testing.allocator.free(reconstructed);
	try testing.expectEqualStrings(b, reconstructed);
}

test "patch with malformed diff returns error" {
	const result = patch(testing.allocator, "hello", "not a valid diff");
	try testing.expectError(error.InvalidMagic, result);
}

test "patch with wrong source file size returns error" {
	const a = "hello world";
	const b = "hello earth";
	const options = diff_mod.DiffOptions{ .seed = [_]u8{0} ** 32, .target_chunk_size = 64 };
	const result = try diff_mod.computeDiff(testing.allocator, a, b, options);
	defer diff_mod.freeDiffResult(testing.allocator, result);
	const encoded = try encoding.encode(testing.allocator, result, .lzma2);
	defer testing.allocator.free(encoded);
	// Pass wrong file (different length) as A
	const wrong_a = "hi";
	const patch_result = patch(testing.allocator, wrong_a, encoded);
	try testing.expectError(error.SizeMismatch, patch_result);
}

test "patch empty files" {
	const options = diff_mod.DiffOptions{ .seed = [_]u8{0} ** 32, .target_chunk_size = 64 };
	const result = try diff_mod.computeDiff(testing.allocator, "", "", options);
	defer diff_mod.freeDiffResult(testing.allocator, result);
	const encoded = try encoding.encode(testing.allocator, result, .lzma2);
	defer testing.allocator.free(encoded);
	const reconstructed = try patch(testing.allocator, "", encoded);
	defer testing.allocator.free(reconstructed);
	try testing.expectEqualStrings("", reconstructed);
}

test "patchInfo returns correct metadata" {
	const a = "hello world";
	const b = "hello earth";
	const options = diff_mod.DiffOptions{ .seed = [_]u8{42} ** 32, .target_chunk_size = 256 };
	const result = try diff_mod.computeDiff(testing.allocator, a, b, options);
	defer diff_mod.freeDiffResult(testing.allocator, result);
	const encoded = try encoding.encode(testing.allocator, result, .lzma2);
	defer testing.allocator.free(encoded);
	const info = try patchInfo(testing.allocator, encoded);
	try testing.expectEqual(@as(usize, 11), info.size_a);
	try testing.expectEqual(@as(usize, 11), info.size_b);
	try testing.expectEqualSlices(u8, &([_]u8{42} ** 32), &info.seed);
	try testing.expectEqual(@as(usize, 256), info.target_chunk_size);
}

test "round-trip with large random data" {
	var prng = std.Random.DefaultPrng.init(99);
	var a: [8192]u8 = undefined;
	prng.random().bytes(&a);
	var b: [8192]u8 = undefined;
	@memcpy(&b, &a);
	// Mutate ~5% of bytes
	for (0..400) |_| {
		const idx = prng.random().intRangeLessThan(usize, 0, 8192);
		b[idx] = prng.random().int(u8);
	}
	const options = diff_mod.DiffOptions{ .seed = [_]u8{7} ** 32, .target_chunk_size = 512 };
	const result = try diff_mod.computeDiff(testing.allocator, &a, &b, options);
	defer diff_mod.freeDiffResult(testing.allocator, result);
	const encoded = try encoding.encode(testing.allocator, result, .lzma2);
	defer testing.allocator.free(encoded);
	const reconstructed = try patch(testing.allocator, &a, encoded);
	defer testing.allocator.free(reconstructed);
	try testing.expectEqualSlices(u8, &b, reconstructed);
}
