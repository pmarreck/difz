const std = @import("std");
const testing = std.testing;
const elder_diff = @import("elder_diff.zig");
const chunk_match = @import("chunk_match.zig");

pub const DiffOp = elder_diff.DiffOp;

pub const DiffOptions = struct {
	seed: [32]u8,
	target_chunk_size: usize,
};

pub const DiffResult = struct {
	ops: []DiffOp,
	options: DiffOptions,
	size_a: usize,
	size_b: usize,
};

/// Two-stage diff: CDC chunk matching (Stage 1) + Elder byte diff on gaps (Stage 2).
/// Returns a DiffResult whose ops, when applied to A, produce B.
///
/// Matches are walked in B-order (sorted by offset_b) so that moved/rearranged
/// blocks are handled correctly. For gaps between matched regions in B:
/// - If the surrounding matches are also monotonic in A, the corresponding
///   A-gap is paired for Elder byte-level diffing (compact output).
/// - Otherwise, the B-gap is emitted as a raw Insert (correct for moved blocks).
pub fn computeDiff(allocator: std.mem.Allocator, a: []const u8, b: []const u8, options: DiffOptions) !DiffResult {
	// Stage 1: Find matching chunks between A and B via CDC + BLAKE3
	const matches = try chunk_match.findMatches(allocator, a, b, options.seed, options.target_chunk_size);
	defer allocator.free(matches);

	// Re-sort matches by offset_b for B-ordered reconstruction.
	// findMatches returns them sorted by offset_a, but we need B-order
	// to correctly handle moved/rearranged blocks.
	std.mem.sortUnstable(chunk_match.Match, matches, {}, struct {
		fn lessThan(_: void, lhs: chunk_match.Match, rhs: chunk_match.Match) bool {
			if (lhs.offset_b != rhs.offset_b) return lhs.offset_b < rhs.offset_b;
			return lhs.offset_a < rhs.offset_a;
		}
	}.lessThan);

	// Filter overlapping matches in B-space (greedy: keep non-overlapping).
	// This handles cases where multiple A-chunks match the same B-chunk.
	var filtered_len: usize = 0;
	{
		var b_cursor: usize = 0;
		for (matches) |m| {
			if (m.offset_b >= b_cursor) {
				matches[filtered_len] = m;
				filtered_len += 1;
				b_cursor = m.offset_b + m.length;
			}
		}
	}
	const filtered = matches[0..filtered_len];

	// Build ops by walking filtered matches in B-order.
	var ops_list: std.ArrayList(DiffOp) = .{};
	defer ops_list.deinit(allocator);

	var pos_b: usize = 0;
	var prev_a_end: usize = 0; // tracks A-cursor for Elder-diff gap pairing

	for (filtered) |m| {
		if (m.offset_b > pos_b) {
			// B-gap: need to produce b[pos_b..m.offset_b]
			const gap_b_slice = b[pos_b..m.offset_b];

			// If matches are locally monotonic in A (this match's A-region
			// starts at or after where the previous one ended), we can pair
			// the corresponding A-gap for fine-grained Elder diffing.
			if (m.offset_a >= prev_a_end) {
				const gap_a_slice = a[prev_a_end..m.offset_a];

				// Stage 2: Elder diff on the paired gap
				const gap_ops = try elder_diff.diff(allocator, gap_a_slice, gap_b_slice);
				defer elder_diff.freeOps(allocator, gap_ops);

				for (gap_ops) |op| {
					var adjusted = op;
					if (op.tag == .copy) {
						adjusted.offset = op.offset + prev_a_end;
					}
					try ops_list.append(allocator, adjusted);
				}
			} else {
				// Non-monotonic (moved block): no natural A-gap to pair.
				// Emit raw Insert of the B-gap bytes.
				if (gap_b_slice.len > 0) {
					try ops_list.append(allocator, .{
						.tag = .insert,
						.offset = 0,
						.length = gap_b_slice.len,
						.data = gap_b_slice,
					});
				}
			}
		}

		// Emit Copy for the matched region (referencing position in A)
		try ops_list.append(allocator, .{
			.tag = .copy,
			.offset = m.offset_a,
			.length = m.length,
			.data = null,
		});

		pos_b = m.offset_b + m.length;
		prev_a_end = m.offset_a + m.length;
	}

	// Remaining gap after the last match
	if (pos_b < b.len) {
		const gap_b_slice = b[pos_b..];

		if (prev_a_end <= a.len) {
			const gap_a_slice = a[prev_a_end..];

			const gap_ops = try elder_diff.diff(allocator, gap_a_slice, gap_b_slice);
			defer elder_diff.freeOps(allocator, gap_ops);

			for (gap_ops) |op| {
				var adjusted = op;
				if (op.tag == .copy) {
					adjusted.offset = op.offset + prev_a_end;
				}
				try ops_list.append(allocator, adjusted);
			}
		} else {
			try ops_list.append(allocator, .{
				.tag = .insert,
				.offset = 0,
				.length = gap_b_slice.len,
				.data = gap_b_slice,
			});
		}
	}

	return DiffResult{
		.ops = try ops_list.toOwnedSlice(allocator),
		.options = options,
		.size_a = a.len,
		.size_b = b.len,
	};
}

/// Free a DiffResult. Insert data points into the original B slice (not owned),
/// so only the ops array itself needs freeing.
pub fn freeDiffResult(allocator: std.mem.Allocator, result: DiffResult) void {
	allocator.free(result.ops);
}

/// Apply diff ops to A, producing B. Convenience wrapper around elder_diff.applyOps.
pub fn applyDiff(allocator: std.mem.Allocator, a: []const u8, ops: []const DiffOp) ![]u8 {
	return elder_diff.applyOps(allocator, a, ops);
}

// ============================================================================
// Tests
// ============================================================================

test "diff identical files produces minimal output" {
	const data = "hello world this is some test data" ** 10;
	const result = try computeDiff(testing.allocator, data, data, .{
		.seed = [_]u8{0} ** 32,
		.target_chunk_size = 64,
	});
	defer freeDiffResult(testing.allocator, result);
	// Should produce copies covering the full file
	var total_copied: usize = 0;
	for (result.ops) |op| {
		if (op.tag == .copy) total_copied += op.length;
	}
	try testing.expectEqual(data.len, total_copied);
}

test "diff completely different files round-trips" {
	var prng1 = std.Random.DefaultPrng.init(111);
	var prng2 = std.Random.DefaultPrng.init(222);
	var a: [4096]u8 = undefined;
	var b: [4096]u8 = undefined;
	prng1.random().bytes(&a);
	prng2.random().bytes(&b);
	const result = try computeDiff(testing.allocator, &a, &b, .{
		.seed = [_]u8{0} ** 32,
		.target_chunk_size = 256,
	});
	defer freeDiffResult(testing.allocator, result);
	const reconstructed = try applyDiff(testing.allocator, &a, result.ops);
	defer testing.allocator.free(reconstructed);
	try testing.expectEqualSlices(u8, &b, reconstructed);
}

test "round-trip: files with shared regions" {
	const shared_prefix = "SHARED PREFIX DATA " ** 50;
	const shared_suffix = " SHARED SUFFIX DATA" ** 50;
	const a = shared_prefix ++ "AAA middle of A" ++ shared_suffix;
	const b = shared_prefix ++ "BBB different middle" ++ shared_suffix;
	const result = try computeDiff(testing.allocator, a, b, .{
		.seed = [_]u8{0} ** 32,
		.target_chunk_size = 64,
	});
	defer freeDiffResult(testing.allocator, result);
	const reconstructed = try applyDiff(testing.allocator, a, result.ops);
	defer testing.allocator.free(reconstructed);
	try testing.expectEqualStrings(b, reconstructed);
}

test "diff B empty" {
	const result = try computeDiff(testing.allocator, "hello", "", .{
		.seed = [_]u8{0} ** 32,
		.target_chunk_size = 64,
	});
	defer freeDiffResult(testing.allocator, result);
	const reconstructed = try applyDiff(testing.allocator, "hello", result.ops);
	defer testing.allocator.free(reconstructed);
	try testing.expectEqualStrings("", reconstructed);
}

test "diff A empty" {
	const result = try computeDiff(testing.allocator, "", "hello", .{
		.seed = [_]u8{0} ** 32,
		.target_chunk_size = 64,
	});
	defer freeDiffResult(testing.allocator, result);
	const reconstructed = try applyDiff(testing.allocator, "", result.ops);
	defer testing.allocator.free(reconstructed);
	try testing.expectEqualStrings("hello", reconstructed);
}

test "round-trip: multiple edits scattered across file" {
	// File with several distinct edit regions separated by shared content.
	const shared = "SHARED_BLOCK_" ** 20;
	const a = shared ++ "old-part-1" ++ shared ++ "old-part-2" ++ shared ++ "old-part-3" ++ shared;
	const b = shared ++ "NEW-PART-1" ++ shared ++ "NEW-PART-TWO" ++ shared ++ "NP3" ++ shared;
	const result = try computeDiff(testing.allocator, a, b, .{
		.seed = [_]u8{0} ** 32,
		.target_chunk_size = 64,
	});
	defer freeDiffResult(testing.allocator, result);
	const reconstructed = try applyDiff(testing.allocator, a, result.ops);
	defer testing.allocator.free(reconstructed);
	try testing.expectEqualStrings(b, reconstructed);
}

test "round-trip: moved/rearranged sections" {
	// Sections of A appear in a different order in B.
	// CDC should detect the moved chunks; computeDiff must handle non-monotonic
	// B-offsets in the match list by sorting matches in B-order.
	const section1 = "AAAAAAAAAA section-one data AAAAAAAAAA" ** 5;
	const section2 = "BBBBBBBBBB section-two data BBBBBBBBBB" ** 5;
	const section3 = "CCCCCCCCCC section-three data CCCCCCCCCC" ** 5;
	const a = section1 ++ section2 ++ section3;
	const b = section3 ++ section1 ++ section2; // rotated
	const result = try computeDiff(testing.allocator, a, b, .{
		.seed = [_]u8{0} ** 32,
		.target_chunk_size = 64,
	});
	defer freeDiffResult(testing.allocator, result);
	const reconstructed = try applyDiff(testing.allocator, a, result.ops);
	defer testing.allocator.free(reconstructed);
	try testing.expectEqualStrings(b, reconstructed);
}

test "diff stores correct metadata" {
	const result = try computeDiff(testing.allocator, "abc", "xyz", .{
		.seed = [_]u8{42} ** 32,
		.target_chunk_size = 128,
	});
	defer freeDiffResult(testing.allocator, result);
	try testing.expectEqual(@as(usize, 3), result.size_a);
	try testing.expectEqual(@as(usize, 3), result.size_b);
	try testing.expectEqualSlices(u8, &([_]u8{42} ** 32), &result.options.seed);
	try testing.expectEqual(@as(usize, 128), result.options.target_chunk_size);
}
