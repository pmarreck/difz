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

/// Threshold above which a gap uses the rolling hash matcher instead of Elder diff.
/// Myers O(ND) is O(D*N) — for a 100KB gap with D=2000, that's 200M ops.
/// The rolling hash matcher is O(N) regardless of edit distance.
const ROLLING_MATCH_THRESHOLD: usize = 8192;

/// Window size for rolling hash match finder (bytes).
/// Smaller = more matches found but more hash table overhead.
/// 16 bytes gives good balance: low collision rate, finds small matches.
const MATCH_WINDOW: usize = 16;

/// Process a paired gap and append ops to ops_list.
/// Small gaps use Elder/Myers byte diff.
/// Large gaps use a rolling hash match finder for O(N) performance.
fn processGap(
	allocator: std.mem.Allocator,
	a: []const u8,
	b: []const u8,
	gap_a_start: usize,
	gap_a_end: usize,
	gap_b_start: usize,
	gap_b_end: usize,
	ops_list: *std.ArrayList(DiffOp),
) !void {
	const gap_a = a[gap_a_start..gap_a_end];
	const gap_b = b[gap_b_start..gap_b_end];

	// Small gaps: Elder diff directly (fast for small inputs)
	if (gap_a.len + gap_b.len < ROLLING_MATCH_THRESHOLD) {
		const gap_ops = try elder_diff.diff(allocator, gap_a, gap_b);
		defer elder_diff.freeOps(allocator, gap_ops);

		for (gap_ops) |op| {
			var adjusted = op;
			if (op.tag == .copy) {
				adjusted.offset = op.offset + gap_a_start;
			}
			try ops_list.append(allocator, adjusted);
		}
		return;
	}

	// Large gaps: rolling hash match finder.
	if (gap_a.len < MATCH_WINDOW or gap_b.len < MATCH_WINDOW) {
		// Too small for windowed matching, use raw Insert
		if (gap_b.len > 0) {
			try ops_list.append(allocator, .{
				.tag = .insert,
				.offset = 0,
				.length = gap_b.len,
				.data = gap_b,
			});
		}
		return;
	}

	// FNV-1a hash for speed
	const hashWindow = struct {
		fn hash(data: []const u8) u32 {
			var h: u32 = 2166136261;
			for (data) |byte| {
				h ^= byte;
				h *%= 16777619;
			}
			return h;
		}
	}.hash;

	// Probe phase: before building the expensive hash table, check if
	// the gap content has any similarity worth finding. Sample a few
	// windows from gap_b and search for them in gap_a near the same
	// relative position. If no matches found, skip rolling hash entirely.
	const NUM_PROBES = 8;
	const PROBE_SCAN_RADIUS = 512; // scan +/- this many bytes in gap_a
	var probe_found_match = false;
	for (0..NUM_PROBES) |probe_i| {
		// Evenly-spaced positions in gap_b
		const pos_b_probe = (gap_b.len - MATCH_WINDOW) * probe_i / NUM_PROBES;
		const window_b = gap_b[pos_b_probe .. pos_b_probe + MATCH_WINDOW];
		const h_b = hashWindow(window_b);

		// Search gap_a near the same relative position
		const center_a = (gap_a.len * probe_i) / NUM_PROBES;
		const scan_start = if (center_a > PROBE_SCAN_RADIUS) center_a - PROBE_SCAN_RADIUS else 0;
		const scan_end = @min(center_a + PROBE_SCAN_RADIUS, gap_a.len -| MATCH_WINDOW + 1);

		var scan_pos = scan_start;
		while (scan_pos < scan_end) : (scan_pos += 1) {
			if (hashWindow(gap_a[scan_pos .. scan_pos + MATCH_WINDOW]) == h_b) {
				// Verify (hash collision guard)
				if (std.mem.eql(u8, gap_a[scan_pos .. scan_pos + MATCH_WINDOW], window_b)) {
					probe_found_match = true;
					break;
				}
			}
		}
		if (probe_found_match) break;
	}

	if (!probe_found_match) {
		// No similarity detected — emit raw Insert (avoids hash table allocation)
		if (gap_b.len > 0) {
			try ops_list.append(allocator, .{
				.tag = .insert,
				.offset = 0,
				.length = gap_b.len,
				.data = gap_b,
			});
		}
		return;
	}

	// Build hash table: hash(window) -> position in gap_a
	const HashEntry = struct { pos: u32 };
	const table_bits = blk: {
		// Size table to ~2x the number of windows for low collision rate
		var bits: u5 = 10;
		const n_windows = gap_a.len - MATCH_WINDOW + 1;
		while ((@as(usize, 1) << bits) < n_windows * 2 and bits < 24) : (bits += 1) {}
		break :blk bits;
	};
	const table_size = @as(usize, 1) << table_bits;
	const table_mask = table_size - 1;

	const table = try allocator.alloc(?HashEntry, table_size);
	defer allocator.free(table);
	@memset(table, null);

	// Populate table with gap_a windows (last write wins for collisions)
	for (0..gap_a.len - MATCH_WINDOW + 1) |i| {
		const h = hashWindow(gap_a[i .. i + MATCH_WINDOW]);
		table[h & table_mask] = .{ .pos = @intCast(i) };
	}

	// Scan gap_b, find matches, emit ops.
	var pos_b_local: usize = 0;
	var insert_start: usize = 0; // start of pending unmatched region in gap_b

	while (pos_b_local + MATCH_WINDOW <= gap_b.len) {
		const h = hashWindow(gap_b[pos_b_local .. pos_b_local + MATCH_WINDOW]);
		const entry = table[h & table_mask];

		if (entry) |e| {
			const pos_a_local: usize = e.pos;

			// Verify the window actually matches (hash collision guard)
			if (std.mem.eql(u8, gap_a[pos_a_local .. pos_a_local + MATCH_WINDOW], gap_b[pos_b_local .. pos_b_local + MATCH_WINDOW])) {
				// Extend match backwards
				var back: usize = 0;
				while (pos_b_local > insert_start + back and
					back < pos_a_local and
					gap_a[pos_a_local - back - 1] == gap_b[pos_b_local - back - 1]) : (back += 1)
				{}

				// Extend match forwards
				var fwd: usize = MATCH_WINDOW;
				while (pos_a_local + fwd < gap_a.len and pos_b_local + fwd < gap_b.len and
					gap_a[pos_a_local + fwd] == gap_b[pos_b_local + fwd]) : (fwd += 1)
				{}

				const match_start_a = pos_a_local - back;
				const match_start_b = pos_b_local - back;
				const match_len = back + fwd;

				// Emit pending Insert for unmatched bytes before this match
				if (match_start_b > insert_start) {
					const insert_data = gap_b[insert_start..match_start_b];
					try ops_list.append(allocator, .{
						.tag = .insert,
						.offset = 0,
						.length = insert_data.len,
						.data = insert_data,
					});
				}

				// Emit Copy (absolute position in A)
				try ops_list.append(allocator, .{
					.tag = .copy,
					.offset = gap_a_start + match_start_a,
					.length = match_len,
					.data = null,
				});

				pos_b_local = match_start_b + match_len;
				insert_start = pos_b_local;
				continue;
			}
		}

		pos_b_local += 1;
	}

	// Emit any remaining unmatched bytes as Insert
	if (insert_start < gap_b.len) {
		const insert_data = gap_b[insert_start..];
		try ops_list.append(allocator, .{
			.tag = .insert,
			.offset = 0,
			.length = insert_data.len,
			.data = insert_data,
		});
	}
}

/// Two-stage diff: CDC chunk matching (Stage 1) + rolling hash / Elder byte diff (Stage 2).
/// Returns a DiffResult whose ops, when applied to A, produce B.
///
/// Matches are walked in B-order (sorted by offset_b) so that moved/rearranged
/// blocks are handled correctly. For gaps between matched regions in B:
/// - If the surrounding matches are also monotonic in A, the corresponding
///   A-gap is paired. Large gaps use a rolling hash match finder (O(N));
///   small gaps use Elder/Myers byte diff for fine-grained output.
/// - Otherwise, the B-gap is emitted as a raw Insert (correct for moved blocks).
pub fn computeDiff(allocator: std.mem.Allocator, a: []const u8, b: []const u8, options: DiffOptions) !DiffResult {
	// Stage 1: Find matching chunks between A and B via CDC + BLAKE3
	const matches = try chunk_match.findMatches(allocator, a, b, options.seed, options.target_chunk_size);
	defer allocator.free(matches);

	// Re-sort matches by offset_b for B-ordered reconstruction.
	std.mem.sortUnstable(chunk_match.Match, matches, {}, struct {
		fn lessThan(_: void, lhs: chunk_match.Match, rhs: chunk_match.Match) bool {
			if (lhs.offset_b != rhs.offset_b) return lhs.offset_b < rhs.offset_b;
			return lhs.offset_a < rhs.offset_a;
		}
	}.lessThan);

	// Filter overlapping matches in B-space (greedy: keep non-overlapping).
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
	var prev_a_end: usize = 0;

	for (filtered) |m| {
		if (m.offset_b > pos_b) {
			const gap_b_slice = b[pos_b..m.offset_b];

			if (m.offset_a >= prev_a_end) {
				try processGap(allocator, a, b, prev_a_end, m.offset_a, pos_b, m.offset_b, &ops_list);
			} else {
				// Non-monotonic (moved block): raw Insert
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

		// Emit Copy for the matched region
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
		if (prev_a_end <= a.len) {
			try processGap(allocator, a, b, prev_a_end, a.len, pos_b, b.len, &ops_list);
		} else {
			const gap_b_slice = b[pos_b..];
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
