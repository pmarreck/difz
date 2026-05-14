const std = @import("std");
const gear_hash = @import("gear_hash.zig");
const testing = std.testing;

pub const Chunk = struct {
	offset: usize,
	length: usize,
};

/// Split a byte slice into variable-size chunks using Content-Defined Chunking
/// with the Gear rolling hash for boundary detection. Cuts when
/// `(state & mask == 0) and (chunk_len >= min_size)` or `chunk_len >= max_size`.
/// Returns an owned slice of Chunk structs; caller must free with allocator.free().
pub fn chunkSlice(allocator: std.mem.Allocator, data: []const u8, seed: [32]u8, target_size: usize) ![]Chunk {
	// Generate Gear hash table from seed
	const table = gear_hash.generateTable(seed);

	// Compute mask: round target_size up to next power of 2, subtract 1
	const mask: u64 = nextPowerOf2(target_size) - 1;

	// Min and max chunk sizes
	const min_size = target_size / 4;
	const max_size = target_size * 4;

	// Collect chunks using an ArrayList
	var chunks: std.ArrayList(Chunk) = .empty;
	defer chunks.deinit(allocator);

	var state: u64 = 0;
	var chunk_start: usize = 0;

	for (data, 0..) |byte, i| {
		state = gear_hash.roll(&table, state, byte);
		const chunk_len = i - chunk_start + 1;

		const hit_boundary = (state & mask == 0) and (chunk_len >= min_size);
		const hit_max = chunk_len >= max_size;

		if (hit_boundary or hit_max) {
			try chunks.append(allocator, .{
				.offset = chunk_start,
				.length = chunk_len,
			});
			chunk_start = i + 1;
			state = 0;
		}
	}

	// Final remainder becomes the last chunk
	if (chunk_start < data.len) {
		try chunks.append(allocator, .{
			.offset = chunk_start,
			.length = data.len - chunk_start,
		});
	}

	return chunks.toOwnedSlice(allocator);
}

/// Round up to the next power of 2. If already a power of 2, return it.
/// Special case: 0 returns 1.
fn nextPowerOf2(n: usize) u64 {
	if (n == 0) return 1;
	// If n is already a power of 2, return it
	if (n & (n -% 1) == 0) return @intCast(n);
	// Find the position of the highest set bit and return the next power of 2
	const bits = @bitSizeOf(usize);
	const leading = @clz(@as(usize, n));
	return @as(u64, 1) << @intCast(bits - leading);
}

test "chunk empty input produces no chunks" {
	const seed = [_]u8{0} ** 32;
	const chunks = try chunkSlice(testing.allocator, &[_]u8{}, seed, 1024);
	defer testing.allocator.free(chunks);
	try testing.expectEqual(@as(usize, 0), chunks.len);
}

test "chunk single byte produces one chunk" {
	const seed = [_]u8{0} ** 32;
	const data = [_]u8{0x42};
	const chunks = try chunkSlice(testing.allocator, &data, seed, 1024);
	defer testing.allocator.free(chunks);
	try testing.expectEqual(@as(usize, 1), chunks.len);
	try testing.expectEqual(@as(usize, 0), chunks[0].offset);
	try testing.expectEqual(@as(usize, 1), chunks[0].length);
}

test "chunks cover entire input without gaps or overlaps" {
	const seed = [_]u8{42} ** 32;
	var prng = std.Random.DefaultPrng.init(12345);
	var data: [8192]u8 = undefined;
	prng.random().bytes(&data);
	const chunks = try chunkSlice(testing.allocator, &data, seed, 256);
	defer testing.allocator.free(chunks);
	// First chunk starts at 0
	try testing.expectEqual(@as(usize, 0), chunks[0].offset);
	// Each chunk starts where previous ended
	for (1..chunks.len) |i| {
		try testing.expectEqual(
			chunks[i - 1].offset + chunks[i - 1].length,
			chunks[i].offset,
		);
	}
	// Last chunk ends at data.len
	const last = chunks[chunks.len - 1];
	try testing.expectEqual(data.len, last.offset + last.length);
}

test "same input and seed produce same chunks" {
	const seed = [_]u8{7} ** 32;
	const data = "the quick brown fox jumps over the lazy dog" ** 20;
	const c1 = try chunkSlice(testing.allocator, data, seed, 64);
	defer testing.allocator.free(c1);
	const c2 = try chunkSlice(testing.allocator, data, seed, 64);
	defer testing.allocator.free(c2);
	try testing.expectEqual(c1.len, c2.len);
	for (c1, c2) |a, b| {
		try testing.expectEqual(a.offset, b.offset);
		try testing.expectEqual(a.length, b.length);
	}
}

test "different seeds produce different chunk boundaries" {
	const data = "the quick brown fox jumps over the lazy dog" ** 20;
	const c1 = try chunkSlice(testing.allocator, data, [_]u8{1} ** 32, 64);
	defer testing.allocator.free(c1);
	const c2 = try chunkSlice(testing.allocator, data, [_]u8{2} ** 32, 64);
	defer testing.allocator.free(c2);
	try testing.expect(c1.len != c2.len or c1[1].offset != c2[1].offset);
}

test "average chunk size is roughly target" {
	const seed = [_]u8{99} ** 32;
	var prng = std.Random.DefaultPrng.init(54321);
	var data: [65536]u8 = undefined;
	prng.random().bytes(&data);
	const target: usize = 1024;
	const chunks = try chunkSlice(testing.allocator, &data, seed, target);
	defer testing.allocator.free(chunks);
	const avg = data.len / chunks.len;
	// Average should be within 3x of target (loose but sensible)
	try testing.expect(avg > target / 3);
	try testing.expect(avg < target * 3);
}
