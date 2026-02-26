const std = @import("std");
const testing = std.testing;

pub const DiffOp = struct {
	pub const Tag = enum { copy, insert };
	tag: Tag,
	offset: usize, // copy: offset in A. insert: unused (0).
	length: usize, // copy: bytes to copy from A. insert: length of data.
	data: ?[]const u8, // insert: the bytes to insert (slice into B). copy: null.
};

/// Edit types in the edit script produced by the Myers algorithm.
const EditType = enum { equal, delete, insert };

const Edit = struct {
	edit_type: EditType,
	pos_a: usize, // position in A
	pos_b: usize, // position in B
};

/// Core diff function. Takes two byte slices and returns a list of DiffOp instructions
/// that, when applied to A, produce B.
///
/// Uses the Myers O(ND) greedy algorithm with traceback.
/// Memory: O(D * (N+M)) where D is the edit distance — fine for gap regions.
pub fn diff(allocator: std.mem.Allocator, a: []const u8, b: []const u8) ![]DiffOp {
	const n = a.len;
	const m = b.len;

	// Edge case: identical slices
	if (n == m and std.mem.eql(u8, a, b)) {
		if (n == 0) {
			return allocator.alloc(DiffOp, 0);
		}
		const ops = try allocator.alloc(DiffOp, 1);
		ops[0] = .{
			.tag = .copy,
			.offset = 0,
			.length = n,
			.data = null,
		};
		return ops;
	}

	// Edge case: A is empty — everything in B is an insert
	if (n == 0) {
		const ops = try allocator.alloc(DiffOp, 1);
		ops[0] = .{
			.tag = .insert,
			.offset = 0,
			.length = m,
			.data = b,
		};
		return ops;
	}

	// Edge case: B is empty — delete everything in A, producing empty ops
	if (m == 0) {
		return allocator.alloc(DiffOp, 0);
	}

	// Myers O(ND) algorithm with edit distance cap.
	// When the edit distance exceeds d_cap, bail out and emit a single Insert
	// of B's data. This prevents O(N*D) blowup on large dissimilar regions
	// where fine-grained byte-level diffing is both slow and produces bloated output.
	const max_d = n + m;
	const d_cap: usize = @min(std.math.sqrt(n + m) * 2 + 16, 8192);
	const effective_max_d = @min(max_d, d_cap);
	const v_size = 2 * effective_max_d + 1;

	// Store V arrays for each d to enable traceback.
	// v_history[d] = copy of V after processing edit distance d.
	// Using raw slices in a dynamic list.
	var v_history_len: usize = 0;
	var v_history_cap: usize = 0;
	var v_history_buf: ?[*][]isize = null;
	defer {
		if (v_history_buf) |buf| {
			for (0..v_history_len) |i| {
				allocator.free(buf[i]);
			}
			allocator.free(buf[0..v_history_cap]);
		}
	}

	// Current V array: V[k + max_d] = furthest x on diagonal k
	const v = try allocator.alloc(isize, v_size);
	defer allocator.free(v);

	// Initialize V to -1 (unreached)
	@memset(v, -1);

	// V[1] = 0 means: on diagonal k=1, the furthest x is 0
	// which represents the starting point.
	v[intToIndex(1, effective_max_d)] = 0;

	var final_d: usize = 0;
	var found_path = false;

	outer: for (0..effective_max_d + 1) |d| {
		const d_signed: isize = @intCast(d);
		var k: isize = -d_signed;
		while (k <= d_signed) : (k += 2) {
			// Choose whether to move down (insert) or right (delete)
			var x: isize = undefined;
			if (k == -d_signed or (k != d_signed and v[intToIndex(k - 1, effective_max_d)] < v[intToIndex(k + 1, effective_max_d)])) {
				// Move down: take x from diagonal k+1 (insert from B)
				x = v[intToIndex(k + 1, effective_max_d)];
			} else {
				// Move right: take x from diagonal k-1 and add 1 (delete from A)
				x = v[intToIndex(k - 1, effective_max_d)] + 1;
			}

			var y: isize = x - k;

			// Follow the snake (diagonal — equal bytes)
			while (x < @as(isize, @intCast(n)) and y < @as(isize, @intCast(m)) and a[@intCast(x)] == b[@intCast(y)]) {
				x += 1;
				y += 1;
			}

			v[intToIndex(k, effective_max_d)] = x;

			// Check if we've reached the end
			if (x == @as(isize, @intCast(n)) and y == @as(isize, @intCast(m))) {
				// Save this final V state
				const v_copy = try allocator.alloc(isize, v_size);
				@memcpy(v_copy, v);
				try appendVHistory(allocator, &v_history_buf, &v_history_len, &v_history_cap, v_copy);
				final_d = d;
				found_path = true;
				break :outer;
			}
		}

		// Save V state for this d
		const v_copy = try allocator.alloc(isize, v_size);
		@memcpy(v_copy, v);
		try appendVHistory(allocator, &v_history_buf, &v_history_len, &v_history_cap, v_copy);
	}

	// Edit distance cap exceeded — bail out with a raw Insert of B.
	// This is correct: "delete all of A, insert all of B."
	if (!found_path) {
		if (m == 0) {
			return allocator.alloc(DiffOp, 0);
		}
		const ops = try allocator.alloc(DiffOp, 1);
		ops[0] = .{
			.tag = .insert,
			.offset = 0,
			.length = m,
			.data = b,
		};
		return ops;
	}

	// Traceback: walk from d=final_d back to d=0 to recover the edit script
	var edits: std.ArrayList(Edit) = .{};
	defer edits.deinit(allocator);

	var x: isize = @intCast(n);
	var y: isize = @intCast(m);

	var d_idx: isize = @intCast(final_d);
	while (d_idx > 0) : (d_idx -= 1) {
		const d_usize: usize = @intCast(d_idx);
		const k = x - y;
		const v_prev = v_history_buf.?[d_usize - 1];

		// Determine which move got us to this k
		const d_signed: isize = @intCast(d_usize);
		var prev_k: isize = undefined;
		if (k == -d_signed or (k != d_signed and v_prev[intToIndex(k - 1, effective_max_d)] < v_prev[intToIndex(k + 1, effective_max_d)])) {
			// We got here by moving down (insert)
			prev_k = k + 1;
		} else {
			// We got here by moving right (delete)
			prev_k = k - 1;
		}

		const prev_x = v_prev[intToIndex(prev_k, effective_max_d)];
		const prev_y = prev_x - prev_k;

		// Add diagonal (equal) edits from the snake
		while (x > prev_x + (if (prev_k < k) @as(isize, 1) else @as(isize, 0)) and y > prev_y + (if (prev_k > k) @as(isize, 1) else @as(isize, 0))) {
			x -= 1;
			y -= 1;
			try edits.append(allocator, .{
				.edit_type = .equal,
				.pos_a = @intCast(x),
				.pos_b = @intCast(y),
			});
		}

		// Add the non-diagonal edit
		if (prev_k < k) {
			// Delete (move right): x increases, y stays
			x -= 1;
			try edits.append(allocator, .{
				.edit_type = .delete,
				.pos_a = @intCast(x),
				.pos_b = @intCast(y),
			});
		} else {
			// Insert (move down): y increases, x stays
			y -= 1;
			try edits.append(allocator, .{
				.edit_type = .insert,
				.pos_a = @intCast(x),
				.pos_b = @intCast(y),
			});
		}
	}

	// Handle remaining snake at d=0
	while (x > 0 and y > 0) {
		x -= 1;
		y -= 1;
		try edits.append(allocator, .{
			.edit_type = .equal,
			.pos_a = @intCast(x),
			.pos_b = @intCast(y),
		});
	}

	// Reverse edits to get them in forward order
	std.mem.reverse(Edit, edits.items);

	// Convert edit script to DiffOps
	return editsToDiffOps(allocator, b, edits.items);
}

/// Helper to append a V array to the history (manual dynamic array to avoid
/// std.ArrayList initialization issues with slice-of-slices in Zig 0.15).
fn appendVHistory(
	allocator: std.mem.Allocator,
	buf: *?[*][]isize,
	len: *usize,
	cap: *usize,
	item: []isize,
) !void {
	if (len.* == cap.*) {
		const new_cap = if (cap.* == 0) 8 else cap.* * 2;
		if (buf.*) |old_buf| {
			const old_slice = old_buf[0..cap.*];
			const new_slice = try allocator.realloc(old_slice, new_cap);
			buf.* = new_slice.ptr;
		} else {
			const new_slice = try allocator.alloc([]isize, new_cap);
			buf.* = new_slice.ptr;
		}
		cap.* = new_cap;
	}
	buf.*.?[len.*] = item;
	len.* += 1;
}

/// Convert the offset k to an index into the V array.
fn intToIndex(k: isize, max_d: usize) usize {
	const offset: isize = @intCast(max_d);
	return @intCast(k + offset);
}

/// Convert a list of Edit operations into merged DiffOps.
fn editsToDiffOps(allocator: std.mem.Allocator, b: []const u8, edits: []const Edit) ![]DiffOp {
	var ops: std.ArrayList(DiffOp) = .{};
	defer ops.deinit(allocator);

	var i: usize = 0;
	while (i < edits.len) {
		const edit = edits[i];
		switch (edit.edit_type) {
			.equal => {
				// Merge consecutive equal edits into a single Copy
				const copy_start = edit.pos_a;
				var copy_len: usize = 1;
				i += 1;
				while (i < edits.len and edits[i].edit_type == .equal) {
					copy_len += 1;
					i += 1;
				}
				try ops.append(allocator, .{
					.tag = .copy,
					.offset = copy_start,
					.length = copy_len,
					.data = null,
				});
			},
			.delete => {
				// Deletes from A: skip these bytes (no DiffOp emitted)
				i += 1;
				while (i < edits.len and edits[i].edit_type == .delete) {
					i += 1;
				}
			},
			.insert => {
				// Merge consecutive inserts into a single Insert
				const insert_start_b = edit.pos_b;
				var insert_len: usize = 1;
				i += 1;
				while (i < edits.len and edits[i].edit_type == .insert) {
					insert_len += 1;
					i += 1;
				}
				try ops.append(allocator, .{
					.tag = .insert,
					.offset = 0,
					.length = insert_len,
					.data = b[insert_start_b .. insert_start_b + insert_len],
				});
			},
		}
	}

	return ops.toOwnedSlice(allocator);
}

/// Free the ops slice. DiffOp.data for inserts points into the original B slice
/// (no owned data), so just free the ops array itself.
pub fn freeOps(allocator: std.mem.Allocator, ops: []DiffOp) void {
	allocator.free(ops);
}

/// Test helper: reconstruct B from A + ops.
/// Walk ops: Copy -> append a[offset..offset+length], Insert -> append data.
/// Returns owned slice.
pub fn applyOps(allocator: std.mem.Allocator, a: []const u8, ops: []const DiffOp) ![]u8 {
	// Calculate total output size
	var total_len: usize = 0;
	for (ops) |op| {
		total_len += op.length;
	}

	const result = try allocator.alloc(u8, total_len);
	var pos: usize = 0;
	for (ops) |op| {
		switch (op.tag) {
			.copy => {
				@memcpy(result[pos .. pos + op.length], a[op.offset .. op.offset + op.length]);
				pos += op.length;
			},
			.insert => {
				@memcpy(result[pos .. pos + op.length], op.data.?);
				pos += op.length;
			},
		}
	}

	return result;
}

// ============================================================================
// Tests
// ============================================================================

test "diff of identical slices is single Copy" {
	const data = "hello";
	const ops = try diff(testing.allocator, data, data);
	defer testing.allocator.free(ops);
	try testing.expectEqual(@as(usize, 1), ops.len);
	try testing.expectEqual(DiffOp.Tag.copy, ops[0].tag);
	try testing.expectEqual(@as(usize, 0), ops[0].offset);
	try testing.expectEqual(@as(usize, 5), ops[0].length);
}

test "diff of empty A into non-empty B is single Insert" {
	const ops = try diff(testing.allocator, "", "hello");
	defer testing.allocator.free(ops);
	try testing.expectEqual(@as(usize, 1), ops.len);
	try testing.expectEqual(DiffOp.Tag.insert, ops[0].tag);
	try testing.expectEqualStrings("hello", ops[0].data.?);
}

test "diff of non-empty A into empty B produces empty ops" {
	const ops = try diff(testing.allocator, "hello", "");
	defer testing.allocator.free(ops);
	try testing.expectEqual(@as(usize, 0), ops.len);
}

test "diff with insertion in middle" {
	const a = "helloworld";
	const b = "hello_world";
	const ops = try diff(testing.allocator, a, b);
	defer testing.allocator.free(ops);
	const result = try applyOps(testing.allocator, a, ops);
	defer testing.allocator.free(result);
	try testing.expectEqualStrings(b, result);
}

test "diff with deletion" {
	const a = "hello world";
	const b = "helloworld";
	const ops = try diff(testing.allocator, a, b);
	defer testing.allocator.free(ops);
	const result = try applyOps(testing.allocator, a, ops);
	defer testing.allocator.free(result);
	try testing.expectEqualStrings(b, result);
}

test "diff with replacement" {
	const a = "hello";
	const b = "hXllo";
	const ops = try diff(testing.allocator, a, b);
	defer testing.allocator.free(ops);
	const result = try applyOps(testing.allocator, a, ops);
	defer testing.allocator.free(result);
	try testing.expectEqualStrings(b, result);
}

test "round-trip property on random data" {
	var prng = std.Random.DefaultPrng.init(42);
	var a_buf: [256]u8 = undefined;
	var b_buf: [256]u8 = undefined;
	prng.random().bytes(&a_buf);
	@memcpy(&b_buf, &a_buf);
	for (0..30) |_| {
		const idx = prng.random().intRangeLessThan(usize, 0, 256);
		b_buf[idx] = prng.random().int(u8);
	}
	const ops = try diff(testing.allocator, &a_buf, &b_buf);
	defer testing.allocator.free(ops);
	const result = try applyOps(testing.allocator, &a_buf, ops);
	defer testing.allocator.free(result);
	try testing.expectEqualSlices(u8, &b_buf, result);
}

test "diff single byte change at start" {
	const ops = try diff(testing.allocator, "Ahello", "Bhello");
	defer testing.allocator.free(ops);
	const result = try applyOps(testing.allocator, "Ahello", ops);
	defer testing.allocator.free(result);
	try testing.expectEqualStrings("Bhello", result);
}

test "diff single byte change at end" {
	const ops = try diff(testing.allocator, "helloA", "helloB");
	defer testing.allocator.free(ops);
	const result = try applyOps(testing.allocator, "helloA", ops);
	defer testing.allocator.free(result);
	try testing.expectEqualStrings("helloB", result);
}

test "large dissimilar diff completes quickly via edit distance cap" {
	// 16KB of completely random data — worst case for Myers O(ND).
	// Without a cap this would take many seconds. With a cap it should bail
	// to a raw Insert and complete in well under 1 second.
	var prng_a = std.Random.DefaultPrng.init(1000);
	var prng_b = std.Random.DefaultPrng.init(2000);
	var a: [16384]u8 = undefined;
	var b: [16384]u8 = undefined;
	prng_a.random().bytes(&a);
	prng_b.random().bytes(&b);

	var timer = try std.time.Timer.start();
	const ops = try diff(testing.allocator, &a, &b);
	const elapsed_ms = timer.read() / 1_000_000;
	defer testing.allocator.free(ops);

	// Must complete in under 500ms (Debug build). Without cap this takes 30+ seconds.
	try testing.expect(elapsed_ms < 500);

	// Must still round-trip correctly
	const result = try applyOps(testing.allocator, &a, ops);
	defer testing.allocator.free(result);
	try testing.expectEqualSlices(u8, &b, result);
}

test "edit distance cap still produces fine-grained ops for similar data" {
	// Small, mostly-similar data should still get fine-grained Copy/Insert ops,
	// NOT a single big Insert (cap shouldn't trigger on easy cases).
	const a = "the quick brown fox jumps over the lazy dog";
	const b = "the quick red fox jumps over the lazy cat";
	const ops = try diff(testing.allocator, a, b);
	defer testing.allocator.free(ops);

	// Should have multiple ops (Copy+Insert interleaved), not just 1 Insert
	try testing.expect(ops.len > 1);

	// Should have at least one Copy op (preserving shared content)
	var has_copy = false;
	for (ops) |op| {
		if (op.tag == .copy) has_copy = true;
	}
	try testing.expect(has_copy);

	// Must round-trip
	const result = try applyOps(testing.allocator, a, ops);
	defer testing.allocator.free(result);
	try testing.expectEqualStrings(b, result);
}
