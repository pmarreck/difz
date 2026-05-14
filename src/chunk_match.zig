const std = @import("std");
const cdc = @import("cdc.zig");
const Blake3 = std.crypto.hash.Blake3;
const testing = std.testing;

pub const Match = struct {
	offset_a: usize,
	offset_b: usize,
	length: usize,
};

pub const GapRegion = struct {
	offset: usize,
	length: usize,
};

pub const GapResult = struct {
	gaps_a: []GapRegion,
	gaps_b: []GapRegion,
};

/// Hash a chunk's data using BLAKE3, returning the first 16 bytes as a u128.
fn blake3Hash128(data: []const u8) u128 {
	var out: [32]u8 = undefined;
	Blake3.hash(data, &out, .{});
	return std.mem.readInt(u128, out[0..16], .little);
}

/// Entry stored in the B-chunk map: offset and length of a chunk in B.
const BChunkEntry = struct {
	offset: usize,
	length: usize,
};

/// Find matching chunks between two byte slices using CDC and BLAKE3 hashing.
/// Returns an owned slice of Match structs sorted by offset_a with adjacent matches merged.
/// Caller must free the returned slice with allocator.free().
pub fn findMatches(allocator: std.mem.Allocator, a: []const u8, b: []const u8, seed: [32]u8, target_chunk_size: usize) ![]Match {
	// 1. Chunk both A and B using CDC
	const chunks_a = try cdc.chunkSlice(allocator, a, seed, target_chunk_size);
	defer allocator.free(chunks_a);
	const chunks_b = try cdc.chunkSlice(allocator, b, seed, target_chunk_size);
	defer allocator.free(chunks_b);

	// 2. BLAKE3-hash each chunk of B, build a HashMap: hash -> list of (offset, length)
	// Using AutoHashMap with u128 keys and ArrayList values for multiple chunks with same hash
	const BChunkList = std.ArrayList(BChunkEntry);
	var b_map = std.AutoHashMap(u128, BChunkList).init(allocator);
	defer {
		var it = b_map.valueIterator();
		while (it.next()) |list_ptr| {
			list_ptr.deinit(allocator);
		}
		b_map.deinit();
	}

	for (chunks_b) |chunk| {
		const chunk_data = b[chunk.offset .. chunk.offset + chunk.length];
		const h = blake3Hash128(chunk_data);
		const gop = try b_map.getOrPut(h);
		if (!gop.found_existing) {
			gop.value_ptr.* = BChunkList.empty;
		}
		try gop.value_ptr.append(allocator, .{
			.offset = chunk.offset,
			.length = chunk.length,
		});
	}

	// 3. Walk A's chunks, BLAKE3-hash each, look up in B's map
	var matches: std.ArrayList(Match) = .empty;
	defer matches.deinit(allocator);

	for (chunks_a) |chunk| {
		const chunk_data = a[chunk.offset .. chunk.offset + chunk.length];
		const h = blake3Hash128(chunk_data);
		if (b_map.get(h)) |b_entries| {
			// For each matching B chunk, record a Match
			for (b_entries.items) |b_entry| {
				// Only record if the chunks have the same length (hash collision guard)
				if (b_entry.length == chunk.length) {
					try matches.append(allocator, .{
						.offset_a = chunk.offset,
						.offset_b = b_entry.offset,
						.length = chunk.length,
					});
				}
			}
		}
	}

	// 5. Sort matches by offset_a (then by offset_b for stability)
	std.mem.sortUnstable(Match, matches.items, {}, struct {
		fn lessThan(_: void, lhs: Match, rhs: Match) bool {
			if (lhs.offset_a != rhs.offset_a) return lhs.offset_a < rhs.offset_a;
			return lhs.offset_b < rhs.offset_b;
		}
	}.lessThan);

	// 6. Merge adjacent matches
	if (matches.items.len > 0) {
		var write: usize = 0;
		for (1..matches.items.len) |read| {
			const prev = &matches.items[write];
			const curr = matches.items[read];
			if (prev.offset_a + prev.length == curr.offset_a and
				prev.offset_b + prev.length == curr.offset_b)
			{
				// Merge: extend the previous match
				prev.length += curr.length;
			} else {
				write += 1;
				matches.items[write] = curr;
			}
		}
		// Truncate to merged length before converting to owned slice
		matches.items.len = write + 1;
	}

	return matches.toOwnedSlice(allocator);
}

/// Given sorted matches and total file lengths, produce gap regions representing
/// unmatched areas in both A and B.
/// Caller must free both gaps_a and gaps_b with allocator.free().
pub fn invertMatches(allocator: std.mem.Allocator, matches: []const Match, len_a: usize, len_b: usize) !GapResult {
	// Compute gaps in A: walk matches by offset_a
	var gaps_a_list: std.ArrayList(GapRegion) = .empty;
	defer gaps_a_list.deinit(allocator);

	var pos_a: usize = 0;
	for (matches) |m| {
		if (m.offset_a > pos_a) {
			try gaps_a_list.append(allocator, .{
				.offset = pos_a,
				.length = m.offset_a - pos_a,
			});
		}
		pos_a = m.offset_a + m.length;
	}
	if (pos_a < len_a) {
		try gaps_a_list.append(allocator, .{
			.offset = pos_a,
			.length = len_a - pos_a,
		});
	}

	// For gaps in B, we need matches sorted by offset_b
	// Copy and sort
	const matches_by_b = try allocator.alloc(Match, matches.len);
	defer allocator.free(matches_by_b);
	@memcpy(matches_by_b, matches);
	std.mem.sortUnstable(Match, matches_by_b, {}, struct {
		fn lessThan(_: void, lhs: Match, rhs: Match) bool {
			return lhs.offset_b < rhs.offset_b;
		}
	}.lessThan);

	var gaps_b_list: std.ArrayList(GapRegion) = .empty;
	defer gaps_b_list.deinit(allocator);

	var pos_b: usize = 0;
	for (matches_by_b) |m| {
		if (m.offset_b > pos_b) {
			try gaps_b_list.append(allocator, .{
				.offset = pos_b,
				.length = m.offset_b - pos_b,
			});
		}
		pos_b = m.offset_b + m.length;
	}
	if (pos_b < len_b) {
		try gaps_b_list.append(allocator, .{
			.offset = pos_b,
			.length = len_b - pos_b,
		});
	}

	return GapResult{
		.gaps_a = try gaps_a_list.toOwnedSlice(allocator),
		.gaps_b = try gaps_b_list.toOwnedSlice(allocator),
	};
}

test "identical data produces matches covering everything" {
	const data = "hello world this is test data!!" ** 10;
	const seed = [_]u8{0} ** 32;
	const matches = try findMatches(testing.allocator, data, data, seed, 64);
	defer testing.allocator.free(matches);
	var total_matched: usize = 0;
	for (matches) |m| total_matched += m.length;
	try testing.expectEqual(data.len, total_matched);
}

test "completely different data produces no matches" {
	var prng1 = std.Random.DefaultPrng.init(111);
	var prng2 = std.Random.DefaultPrng.init(222);
	var a: [4096]u8 = undefined;
	var b: [4096]u8 = undefined;
	prng1.random().bytes(&a);
	prng2.random().bytes(&b);
	const seed = [_]u8{0} ** 32;
	const matches = try findMatches(testing.allocator, &a, &b, seed, 256);
	defer testing.allocator.free(matches);
	try testing.expectEqual(@as(usize, 0), matches.len);
}

test "invertMatches with one match in middle" {
	const matches = &[_]Match{.{ .offset_a = 100, .offset_b = 200, .length = 50 }};
	const gaps = try invertMatches(testing.allocator, matches, 300, 400);
	defer {
		testing.allocator.free(gaps.gaps_a);
		testing.allocator.free(gaps.gaps_b);
	}
	// gaps_a: [0..100), [150..300)
	try testing.expectEqual(@as(usize, 2), gaps.gaps_a.len);
	try testing.expectEqual(@as(usize, 0), gaps.gaps_a[0].offset);
	try testing.expectEqual(@as(usize, 100), gaps.gaps_a[0].length);
	try testing.expectEqual(@as(usize, 150), gaps.gaps_a[1].offset);
	try testing.expectEqual(@as(usize, 150), gaps.gaps_a[1].length);
	// gaps_b: [0..200), [250..400)
	try testing.expectEqual(@as(usize, 2), gaps.gaps_b.len);
	try testing.expectEqual(@as(usize, 0), gaps.gaps_b[0].offset);
	try testing.expectEqual(@as(usize, 200), gaps.gaps_b[0].length);
	try testing.expectEqual(@as(usize, 250), gaps.gaps_b[1].offset);
	try testing.expectEqual(@as(usize, 150), gaps.gaps_b[1].length);
}

test "invertMatches with no matches produces full-file gaps" {
	const matches = &[_]Match{};
	const gaps = try invertMatches(testing.allocator, matches, 100, 200);
	defer {
		testing.allocator.free(gaps.gaps_a);
		testing.allocator.free(gaps.gaps_b);
	}
	try testing.expectEqual(@as(usize, 1), gaps.gaps_a.len);
	try testing.expectEqual(@as(usize, 0), gaps.gaps_a[0].offset);
	try testing.expectEqual(@as(usize, 100), gaps.gaps_a[0].length);
	try testing.expectEqual(@as(usize, 1), gaps.gaps_b.len);
	try testing.expectEqual(@as(usize, 0), gaps.gaps_b[0].offset);
	try testing.expectEqual(@as(usize, 200), gaps.gaps_b[0].length);
}

test "shared prefix detected" {
	const shared = "shared prefix data " ** 20;
	const a = shared ++ "AAAA unique to A end";
	const b = shared ++ "BBBB unique to B end";
	const seed = [_]u8{0} ** 32;
	const matches = try findMatches(testing.allocator, a, b, seed, 32);
	defer testing.allocator.free(matches);
	var total_matched: usize = 0;
	for (matches) |m| total_matched += m.length;
	// Should match most of the shared prefix
	try testing.expect(total_matched > 0);
	try testing.expect(total_matched <= shared.len);
}
