const std = @import("std");
const testing = std.testing;
const blip = @import("blip");
const diff_mod = @import("diff.zig");

pub const DiffOp = diff_mod.DiffOp;

/// Magic bytes identifying a ZDIF v1 container.
const MAGIC = "ZDIF\x01";

pub const DecodeResult = struct {
	ops: []DiffOp,
	seed: [32]u8,
	target_chunk_size: usize,
	size_a: usize,
	size_b: usize,
};

pub const EncodeError = error{
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
	InvalidMagic,
};

// ---------------------------------------------------------------------------
// Helper: build a RAW container manually
// ---------------------------------------------------------------------------

/// Build a RAW container (type 0x81 0x04) from payload bytes.
/// Layout: [0x81, 0x04] + BLIP(total_length) + payload
/// where total_length = 2 + encodedSize(total_length) + payload.len
/// Caller owns returned memory.
fn serializeRaw(allocator: std.mem.Allocator, payload: []const u8) EncodeError![]u8 {
	// Solve the fixpoint: total = 2 + blip.encodedSize(total) + payload.len
	const base: u64 = 2 + payload.len;
	var total: u64 = undefined;
	for (1..10) |l_bytes| {
		const candidate = base + l_bytes;
		if (blip.encodedSize(candidate) == l_bytes) {
			total = candidate;
			break;
		}
	}

	const buf = try allocator.alloc(u8, @intCast(total));
	errdefer allocator.free(buf);

	// Type sentinel: RAW = 0x81 0x04
	buf[0] = 0x81;
	buf[1] = 0x04;

	// BLIP(total)
	const len_bytes = blip.encode(total, buf[2..]) catch return error.BufferTooSmall;

	// Payload
	@memcpy(buf[2 + len_bytes ..], payload);

	return buf;
}

/// Parse a RAW container and return the payload slice (zero-copy into buf).
/// Returns error if not a RAW container or truncated.
fn parseRaw(buf: []const u8) EncodeError![]const u8 {
	if (buf.len < 3) return error.UnexpectedEndOfInput;
	if (buf[0] != 0x81 or buf[1] != 0x04) return error.InvalidContainerType;
	const len_result = blip.decode(buf[2..]) catch |e| switch (e) {
		error.UnexpectedEndOfInput => return error.UnexpectedEndOfInput,
		error.Overflow => return error.Overflow,
		error.BufferTooSmall => return error.BufferTooSmall,
	};
	const total: usize = @intCast(len_result.value);
	const value_offset = 2 + len_result.bytes_read;
	if (total > buf.len) return error.LengthExceedsBounds;
	if (total < value_offset) return error.InvalidLength;
	return buf[value_offset..total];
}

// ---------------------------------------------------------------------------
// Helper: encode a usize value into a temporary buffer via BLIP
// ---------------------------------------------------------------------------

fn blipEncodeValue(value: u64, out: []u8) EncodeError!usize {
	return blip.encode(value, out) catch |e| switch (e) {
		error.BufferTooSmall => return error.BufferTooSmall,
		error.UnexpectedEndOfInput => return error.UnexpectedEndOfInput,
		error.Overflow => return error.Overflow,
	};
}

fn blipDecodeValue(buf: []const u8) EncodeError!blip.DecodeResult {
	return blip.decode(buf) catch |e| switch (e) {
		error.UnexpectedEndOfInput => return error.UnexpectedEndOfInput,
		error.Overflow => return error.Overflow,
		error.BufferTooSmall => return error.BufferTooSmall,
	};
}

// ---------------------------------------------------------------------------
// Encode
// ---------------------------------------------------------------------------

/// Serialize a DiffResult into BLIP bytes. Returns owned slice.
///
/// Format:
///   ARRAY (top-level)
///   +-- [0] RAW: magic "ZDIF\x01"
///   +-- [1] RAW: metadata (seed[32] + BLIP(chunk_size) + BLIP(size_a) + BLIP(size_b))
///   +-- [2] ARRAY: instructions
///       +-- [i] RAW: opcode + BLIP fields [+ data]
pub fn encode(allocator: std.mem.Allocator, result: diff_mod.DiffResult) EncodeError![]u8 {
	// 1. Build magic element
	const magic_raw = try serializeRaw(allocator, MAGIC);
	defer allocator.free(magic_raw);

	// 2. Build metadata element: seed[32] + BLIP(chunk_size) + BLIP(size_a) + BLIP(size_b)
	var meta_buf: [32 + 9 + 9 + 9]u8 = undefined; // 32 bytes seed + max 9 bytes each for 3 BLIP values
	@memcpy(meta_buf[0..32], &result.options.seed);
	var meta_pos: usize = 32;
	meta_pos += try blipEncodeValue(@intCast(result.options.target_chunk_size), meta_buf[meta_pos..]);
	meta_pos += try blipEncodeValue(@intCast(result.size_a), meta_buf[meta_pos..]);
	meta_pos += try blipEncodeValue(@intCast(result.size_b), meta_buf[meta_pos..]);
	const metadata_raw = try serializeRaw(allocator, meta_buf[0..meta_pos]);
	defer allocator.free(metadata_raw);

	// 3. Build instruction RAW elements
	var instr_elements_list: std.ArrayList([]u8) = .{};
	defer {
		for (instr_elements_list.items) |item| allocator.free(item);
		instr_elements_list.deinit(allocator);
	}

	for (result.ops) |op| {
		switch (op.tag) {
			.copy => {
				// Copy: 0x00 + BLIP(offset) + BLIP(length)
				var instr_buf: [1 + 9 + 9]u8 = undefined;
				instr_buf[0] = 0x00;
				var ipos: usize = 1;
				ipos += try blipEncodeValue(@intCast(op.offset), instr_buf[ipos..]);
				ipos += try blipEncodeValue(@intCast(op.length), instr_buf[ipos..]);
				const raw_elem = try serializeRaw(allocator, instr_buf[0..ipos]);
				try instr_elements_list.append(allocator, raw_elem);
			},
			.insert => {
				// Insert: 0x01 + BLIP(length) + raw data bytes
				const data_bytes = op.data orelse return error.InvalidLength;
				// Max overhead: 1 byte opcode + 9 bytes BLIP length
				const payload_size = 1 + blip.encodedSize(@intCast(op.length)) + data_bytes.len;
				const payload_buf = try allocator.alloc(u8, payload_size);
				defer allocator.free(payload_buf);
				payload_buf[0] = 0x01;
				var ipos: usize = 1;
				ipos += try blipEncodeValue(@intCast(op.length), payload_buf[ipos..]);
				@memcpy(payload_buf[ipos..][0..data_bytes.len], data_bytes);
				ipos += data_bytes.len;
				const raw_elem = try serializeRaw(allocator, payload_buf[0..ipos]);
				try instr_elements_list.append(allocator, raw_elem);
			},
		}
	}

	// Build const slice for serializeArray
	const instr_const = try allocator.alloc([]const u8, instr_elements_list.items.len);
	defer allocator.free(instr_const);
	for (instr_elements_list.items, 0..) |item, i| {
		instr_const[i] = item;
	}

	// 4. Build instructions ARRAY
	const instr_array = try blip.array_mod.serializeArray(allocator, instr_const);
	defer allocator.free(instr_array);

	// 5. Build top-level ARRAY from [magic, metadata, instructions]
	const top_elements = [_][]const u8{ magic_raw, metadata_raw, instr_array };
	const top_array = try blip.array_mod.serializeArray(allocator, &top_elements);

	return top_array;
}

// ---------------------------------------------------------------------------
// Decode
// ---------------------------------------------------------------------------

/// Deserialize BLIP bytes back into a DecodeResult.
pub fn decode(allocator: std.mem.Allocator, data: []const u8) EncodeError!DecodeResult {
	// Parse outer ARRAY
	const outer = blip.array_mod.ArrayReader.init(data) catch |e| switch (e) {
		error.InvalidContainerType => return error.InvalidMagic,
		error.UnexpectedEndOfInput => return error.InvalidMagic,
		error.InvalidLength => return error.InvalidMagic,
		error.LengthExceedsBounds => return error.InvalidMagic,
		error.Overflow => return error.InvalidMagic,
		error.BufferTooSmall => return error.InvalidMagic,
		error.MissingRequiredKey => return error.InvalidMagic,
		error.DuplicateKey => return error.InvalidMagic,
		error.KeysNotSorted => return error.InvalidMagic,
		error.HashMismatch => return error.InvalidMagic,
		error.IndexOutOfBounds => return error.InvalidMagic,
		error.InvalidMagic => return error.InvalidMagic,
	};

	if (outer.elementCount() < 3) return error.InvalidMagic;

	// Element 0: magic
	const magic_view = outer.elementAt(0) catch return error.InvalidMagic;
	// magic_view is a ContainerView. Extract RAW payload.
	const magic_payload = parseRaw(magic_view.buf[0..@intCast(magic_view.total_length)]) catch return error.InvalidMagic;
	if (!std.mem.eql(u8, magic_payload, MAGIC)) return error.InvalidMagic;

	// Element 1: metadata
	const meta_view = outer.elementAt(1) catch return error.InvalidLength;
	const meta_payload = try parseRaw(meta_view.buf[0..@intCast(meta_view.total_length)]);
	if (meta_payload.len < 32) return error.InvalidLength;

	var seed: [32]u8 = undefined;
	@memcpy(&seed, meta_payload[0..32]);
	var mpos: usize = 32;

	const chunk_result = try blipDecodeValue(meta_payload[mpos..]);
	mpos += chunk_result.bytes_read;
	const target_chunk_size: usize = @intCast(chunk_result.value);

	const size_a_result = try blipDecodeValue(meta_payload[mpos..]);
	mpos += size_a_result.bytes_read;
	const size_a: usize = @intCast(size_a_result.value);

	const size_b_result = try blipDecodeValue(meta_payload[mpos..]);
	const size_b: usize = @intCast(size_b_result.value);

	// Element 2: instructions array
	const instr_view = outer.elementAt(2) catch return error.InvalidLength;
	const instr_buf = instr_view.buf[0..@intCast(instr_view.total_length)];
	const instr_reader = blip.array_mod.ArrayReader.init(instr_buf) catch return error.InvalidLength;

	const op_count: usize = @intCast(instr_reader.elementCount());
	const ops = try allocator.alloc(DiffOp, op_count);
	var parsed_count: usize = 0;
	errdefer {
		// Free already-parsed insert data on error, then the ops array
		for (ops[0..parsed_count]) |op| {
			if (op.tag == .insert) {
				if (op.data) |d| {
					allocator.free(d);
				}
			}
		}
		allocator.free(ops);
	}

	for (0..op_count) |i| {
		const elem_view = instr_reader.elementAt(@intCast(i)) catch return error.InvalidLength;
		const elem_payload = try parseRaw(elem_view.buf[0..@intCast(elem_view.total_length)]);

		if (elem_payload.len < 1) return error.InvalidLength;
		const opcode = elem_payload[0];

		switch (opcode) {
			0x00 => {
				// Copy: BLIP(offset) + BLIP(length)
				var epos: usize = 1;
				const off_result = try blipDecodeValue(elem_payload[epos..]);
				epos += off_result.bytes_read;
				const len_result = try blipDecodeValue(elem_payload[epos..]);

				ops[i] = .{
					.tag = .copy,
					.offset = @intCast(off_result.value),
					.length = @intCast(len_result.value),
					.data = null,
				};
				parsed_count = i + 1;
			},
			0x01 => {
				// Insert: BLIP(length) + raw data
				var epos: usize = 1;
				const len_result = try blipDecodeValue(elem_payload[epos..]);
				epos += len_result.bytes_read;
				const data_len: usize = @intCast(len_result.value);
				const remaining = elem_payload[epos..];
				if (remaining.len < data_len) return error.InvalidLength;

				// Allocate and copy the data (since source buffer may be freed)
				const data_copy = try allocator.alloc(u8, data_len);
				@memcpy(data_copy, remaining[0..data_len]);

				ops[i] = .{
					.tag = .insert,
					.offset = 0,
					.length = data_len,
					.data = data_copy,
				};
				parsed_count = i + 1;
			},
			else => return error.InvalidLength,
		}
	}

	return DecodeResult{
		.ops = ops,
		.seed = seed,
		.target_chunk_size = target_chunk_size,
		.size_a = size_a,
		.size_b = size_b,
	};
}

/// Free decoded result -- free each insert's data, then free ops array.
pub fn freeDecoded(allocator: std.mem.Allocator, result: DecodeResult) void {
	for (result.ops) |op| {
		if (op.tag == .insert) {
			if (op.data) |d| {
				allocator.free(d);
			}
		}
	}
	allocator.free(result.ops);
}

// ============================================================================
// Tests
// ============================================================================

test "encode then decode produces identical ops" {
	var ops_buf = [_]DiffOp{
		.{ .tag = .copy, .offset = 0, .length = 100, .data = null },
		.{ .tag = .insert, .offset = 0, .length = 5, .data = "hello" },
		.{ .tag = .copy, .offset = 105, .length = 200, .data = null },
	};
	const result = diff_mod.DiffResult{
		.ops = &ops_buf,
		.options = .{ .seed = [_]u8{42} ** 32, .target_chunk_size = 1024 },
		.size_a = 305,
		.size_b = 305,
	};
	const encoded = try encode(testing.allocator, result);
	defer testing.allocator.free(encoded);

	const decoded = try decode(testing.allocator, encoded);
	defer freeDecoded(testing.allocator, decoded);

	try testing.expectEqual(result.ops.len, decoded.ops.len);
	try testing.expectEqual(result.size_a, decoded.size_a);
	try testing.expectEqual(result.size_b, decoded.size_b);
	try testing.expectEqualSlices(u8, &result.options.seed, &decoded.seed);
	try testing.expectEqual(result.options.target_chunk_size, decoded.target_chunk_size);

	for (result.ops, decoded.ops) |orig, dec| {
		try testing.expectEqual(orig.tag, dec.tag);
		try testing.expectEqual(orig.length, dec.length);
		if (orig.tag == .copy) {
			try testing.expectEqual(orig.offset, dec.offset);
		}
		if (orig.tag == .insert) {
			try testing.expectEqualStrings(orig.data.?, dec.data.?);
		}
	}
}

test "encoded diff starts with valid BLIP array" {
	var ops_buf = [_]DiffOp{
		.{ .tag = .copy, .offset = 0, .length = 10, .data = null },
	};
	const result = diff_mod.DiffResult{
		.ops = &ops_buf,
		.options = .{ .seed = [_]u8{0} ** 32, .target_chunk_size = 256 },
		.size_a = 10,
		.size_b = 10,
	};
	const encoded = try encode(testing.allocator, result);
	defer testing.allocator.free(encoded);

	// First 2 bytes should be ARRAY sentinel
	try testing.expectEqual(@as(u8, 0x81), encoded[0]);
	try testing.expectEqual(@as(u8, 0x01), encoded[1]);
}

test "decode rejects invalid magic" {
	// Just some random bytes, not a valid ZDIF container
	const bad = "not a valid zdiff blob";
	const result = decode(testing.allocator, bad);
	try testing.expectError(error.InvalidMagic, result);
}

test "empty ops round-trip" {
	const result = diff_mod.DiffResult{
		.ops = &[_]DiffOp{},
		.options = .{ .seed = [_]u8{0} ** 32, .target_chunk_size = 64 },
		.size_a = 0,
		.size_b = 0,
	};
	const encoded = try encode(testing.allocator, result);
	defer testing.allocator.free(encoded);
	const decoded = try decode(testing.allocator, encoded);
	defer freeDecoded(testing.allocator, decoded);
	try testing.expectEqual(@as(usize, 0), decoded.ops.len);
}

test "large insert data round-trips correctly" {
	// Test with a larger payload to exercise BLIP encoding edge cases
	const insert_data = "A" ** 500;
	var ops_buf = [_]DiffOp{
		.{ .tag = .insert, .offset = 0, .length = 500, .data = insert_data },
	};
	const result = diff_mod.DiffResult{
		.ops = &ops_buf,
		.options = .{ .seed = [_]u8{0xFF} ** 32, .target_chunk_size = 4096 },
		.size_a = 0,
		.size_b = 500,
	};
	const encoded = try encode(testing.allocator, result);
	defer testing.allocator.free(encoded);
	const decoded = try decode(testing.allocator, encoded);
	defer freeDecoded(testing.allocator, decoded);
	try testing.expectEqual(@as(usize, 1), decoded.ops.len);
	try testing.expectEqual(DiffOp.Tag.insert, decoded.ops[0].tag);
	try testing.expectEqual(@as(usize, 500), decoded.ops[0].length);
	try testing.expectEqualStrings(insert_data, decoded.ops[0].data.?);
}

test "multiple interleaved copy and insert ops round-trip" {
	var ops_buf = [_]DiffOp{
		.{ .tag = .copy, .offset = 0, .length = 50, .data = null },
		.{ .tag = .insert, .offset = 0, .length = 3, .data = "abc" },
		.{ .tag = .copy, .offset = 50, .length = 100, .data = null },
		.{ .tag = .insert, .offset = 0, .length = 2, .data = "XY" },
		.{ .tag = .copy, .offset = 150, .length = 25, .data = null },
	};
	const result = diff_mod.DiffResult{
		.ops = &ops_buf,
		.options = .{ .seed = [_]u8{7} ** 32, .target_chunk_size = 512 },
		.size_a = 175,
		.size_b = 180,
	};
	const encoded = try encode(testing.allocator, result);
	defer testing.allocator.free(encoded);
	const decoded = try decode(testing.allocator, encoded);
	defer freeDecoded(testing.allocator, decoded);
	try testing.expectEqual(@as(usize, 5), decoded.ops.len);

	// Verify each op
	try testing.expectEqual(DiffOp.Tag.copy, decoded.ops[0].tag);
	try testing.expectEqual(@as(usize, 0), decoded.ops[0].offset);
	try testing.expectEqual(@as(usize, 50), decoded.ops[0].length);

	try testing.expectEqual(DiffOp.Tag.insert, decoded.ops[1].tag);
	try testing.expectEqualStrings("abc", decoded.ops[1].data.?);

	try testing.expectEqual(DiffOp.Tag.copy, decoded.ops[2].tag);
	try testing.expectEqual(@as(usize, 50), decoded.ops[2].offset);
	try testing.expectEqual(@as(usize, 100), decoded.ops[2].length);

	try testing.expectEqual(DiffOp.Tag.insert, decoded.ops[3].tag);
	try testing.expectEqualStrings("XY", decoded.ops[3].data.?);

	try testing.expectEqual(DiffOp.Tag.copy, decoded.ops[4].tag);
	try testing.expectEqual(@as(usize, 150), decoded.ops[4].offset);
	try testing.expectEqual(@as(usize, 25), decoded.ops[4].length);
}

test "seed and metadata preserved across encode/decode" {
	var seed: [32]u8 = undefined;
	for (&seed, 0..) |*b, i| {
		b.* = @intCast(i);
	}
	const result = diff_mod.DiffResult{
		.ops = &[_]DiffOp{},
		.options = .{ .seed = seed, .target_chunk_size = 8192 },
		.size_a = 1_000_000,
		.size_b = 1_000_001,
	};
	const encoded = try encode(testing.allocator, result);
	defer testing.allocator.free(encoded);
	const decoded = try decode(testing.allocator, encoded);
	defer freeDecoded(testing.allocator, decoded);
	try testing.expectEqualSlices(u8, &seed, &decoded.seed);
	try testing.expectEqual(@as(usize, 8192), decoded.target_chunk_size);
	try testing.expectEqual(@as(usize, 1_000_000), decoded.size_a);
	try testing.expectEqual(@as(usize, 1_000_001), decoded.size_b);
}
