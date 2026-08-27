const std = @import("std");
const testing = std.testing;
const blar = @import("blar");
const blip = blar.core;
const diff_mod = @import("diff.zig");

pub const DiffOp = diff_mod.DiffOp;

/// Magic bytes identifying the source- and target-bound ZDIF v2 container.
const MAGIC = "ZDIF\x02";

pub const DecodeResult = struct {
    ops: []DiffOp,
    insert_storage: []u8,
    seed: [32]u8,
    target_chunk_size: usize,
    size_a: usize,
    size_b: usize,
    source_blake3: [32]u8,
    target_blake3: [32]u8,
};

pub const CompressionMode = enum(u8) {
    best = 0,
    lzma2 = 1,
    bzip2 = 2,
    lz4 = 3,
    zstd = 4,
    none = 255,
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
    InvalidSigilOrder,
    MissingDecompLen,
    MissingSigil,
    CompressionFailed,
    DecompressionFailed,
    UnsupportedCompression,
};

// ---------------------------------------------------------------------------
// Helper: build a DATA container in v2 LP format
// ---------------------------------------------------------------------------

/// Build a DATA container (type_id=4) in v2 LP format from payload bytes.
///
/// Layout: [BLIP(total)] [0x81 0x01] [0x04] [0x81 0x7F] [payload]
///   - BLIP(total): self-referential total length
///   - 0x81 0x01:   TYPE sentinel
///   - 0x04:        type_id = DATA (BLIP immediate)
///   - 0x81 0x7F:   VAL sentinel
///   - payload:     raw bytes
///
/// Attribute overhead (fixed): 2 + 1 + 2 = 5 bytes
/// Caller owns returned memory.
fn serializeDataContainer(allocator: std.mem.Allocator, payload: []const u8) EncodeError![]u8 {
    const attr_overhead: u64 = 5; // TYPE sentinel(2) + BLIP(4)(1) + VAL sentinel(2)

    // Solve fixpoint: total = blip.encodedSize(total) + attr_overhead + payload.len
    var total: u64 = undefined;
    for (1..10) |l_bytes| {
        const candidate = l_bytes + attr_overhead + payload.len;
        if (blip.encodedSize(candidate) == l_bytes) {
            total = candidate;
            break;
        }
    }

    const buf = try allocator.alloc(u8, @intCast(total));
    errdefer allocator.free(buf);

    // BLIP(total)
    var pos: usize = blip.encode(total, buf) catch return error.BufferTooSmall;

    // TYPE sentinel: 0x81 0x01
    buf[pos] = 0x81;
    buf[pos + 1] = 0x01;
    pos += 2;

    // type_id = DATA = 4 (BLIP immediate)
    buf[pos] = 0x04;
    pos += 1;

    // VAL sentinel: 0x81 0x7F
    buf[pos] = 0x81;
    buf[pos + 1] = 0x7F;
    pos += 2;

    // Payload
    @memcpy(buf[pos..], payload);

    return buf;
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

/// Stateful ARRAY traversal. BLIP's random-access elementAt(i) rescans the
/// offset index from its beginning, so using it in an increasing loop is O(n²).
const SequentialArrayCursor = struct {
    reader: blip.array_mod.ArrayReader,
    index_pos: usize,
    total: usize,
    remaining: usize,
    offsets_consumed: usize = 0,

    fn init(reader: blip.array_mod.ArrayReader) EncodeError!SequentialArrayCursor {
        const total = std.math.cast(usize, reader.lp_view.total_length) orelse return error.LengthExceedsBounds;
        const index_pos = std.math.cast(usize, reader.index_offset) orelse return error.LengthExceedsBounds;
        if (index_pos >= total) return error.InvalidLength;
        const count = try blipDecodeValue(reader.lp_view.buf[index_pos..total]);
        if (count.value != reader.elementCount()) return error.InvalidLength;
        return .{
            .reader = reader,
            .index_pos = index_pos + count.bytes_read,
            .total = total,
            .remaining = std.math.cast(usize, count.value) orelse return error.LengthExceedsBounds,
        };
    }

    fn next(self: *SequentialArrayCursor) EncodeError!?blip.container_mod.LPContainerView {
        if (self.remaining == 0) return null;
        const offset_result = try blipDecodeValue(self.reader.lp_view.buf[self.index_pos..self.total]);
        self.index_pos += offset_result.bytes_read;
        self.remaining -= 1;
        self.offsets_consumed += 1;

        const offset = std.math.cast(usize, offset_result.value) orelse return error.LengthExceedsBounds;
        const index_offset = std.math.cast(usize, self.reader.index_offset) orelse return error.LengthExceedsBounds;
        if (offset < self.reader.header_size or offset >= index_offset) return error.IndexOutOfBounds;
        const view = blip.container_mod.parseLPHeader(self.reader.lp_view.buf[offset..index_offset]) catch |err| return err;
        if (view.total_length > index_offset - offset) return error.InvalidLength;
        return view;
    }
};

const DecodedInstructionView = union(enum) {
    copy: struct { offset: usize, length: usize },
    insert: []const u8,
};

fn decodeInstructionView(element: blip.container_mod.LPContainerView) EncodeError!DecodedInstructionView {
    const payload = element.payloadSlice();
    if (payload.len < 1) return error.InvalidLength;
    var pos: usize = 1;
    return switch (payload[0]) {
        0x00 => blk: {
            const offset = try blipDecodeValue(payload[pos..]);
            pos += offset.bytes_read;
            const length = try blipDecodeValue(payload[pos..]);
            pos += length.bytes_read;
            if (pos != payload.len) return error.InvalidLength;
            break :blk .{ .copy = .{
                .offset = std.math.cast(usize, offset.value) orelse return error.LengthExceedsBounds,
                .length = std.math.cast(usize, length.value) orelse return error.LengthExceedsBounds,
            } };
        },
        0x01 => blk: {
            const length = try blipDecodeValue(payload[pos..]);
            pos += length.bytes_read;
            const data_len = std.math.cast(usize, length.value) orelse return error.LengthExceedsBounds;
            if (payload.len - pos != data_len) return error.InvalidLength;
            break :blk .{ .insert = payload[pos..] };
        },
        else => error.InvalidLength,
    };
}

// ---------------------------------------------------------------------------
// Compression helpers
// ---------------------------------------------------------------------------

/// The BLIP CompressionId type, extracted from the compressContainer function signature.
const BlipCompressionId = @typeInfo(@TypeOf(blar.compression_mod.compressContainer)).@"fn".params[1].type.?;

/// Map CompressionMode to blip CompressionId for single-algorithm modes.
fn modeToCompressionId(mode: CompressionMode) ?BlipCompressionId {
    return switch (mode) {
        .lzma2 => .lzma2,
        .bzip2 => .bzip2,
        .lz4 => .lz4,
        .zstd => .zstd,
        .best, .none => null,
    };
}

const SAMPLE_CHUNK: usize = 128 * 1024; // 128KB per chunk — large enough to amortize compressor startup overhead
const SAMPLE_THRESHOLD: usize = SAMPLE_CHUNK * 3; // 384KB — below this, try all on full data

/// Build a distributed sample from data: 3x128KB chunks from beginning, middle, end.
/// Returns a newly allocated buffer that caller must free.
fn buildSample(allocator: std.mem.Allocator, data: []const u8) EncodeError![]u8 {
    const mid_start = (data.len / 2) -| (SAMPLE_CHUNK / 2);
    const end_start = data.len -| SAMPLE_CHUNK;

    const chunk1 = data[0..@min(SAMPLE_CHUNK, data.len)];
    const chunk2 = data[mid_start..@min(mid_start + SAMPLE_CHUNK, data.len)];
    const chunk3 = data[end_start..@min(end_start + SAMPLE_CHUNK, data.len)];

    const sample = try allocator.alloc(u8, chunk1.len + chunk2.len + chunk3.len);
    var pos: usize = 0;
    @memcpy(sample[pos..][0..chunk1.len], chunk1);
    pos += chunk1.len;
    @memcpy(sample[pos..][0..chunk2.len], chunk2);
    pos += chunk2.len;
    @memcpy(sample[pos..][0..chunk3.len], chunk3);
    return sample;
}

/// Try all 3 algorithms on the given sample data and return the one that compresses smallest.
fn pickBestAlgo(allocator: std.mem.Allocator, data: []const u8) EncodeError!CompressionMode {
    // Get sample data — full data if small, distributed chunks if large
    var sample_owned: ?[]u8 = null;
    defer if (sample_owned) |s| allocator.free(s);

    const sample: []const u8 = if (data.len < SAMPLE_THRESHOLD) data else blk: {
        sample_owned = try buildSample(allocator, data);
        break :blk sample_owned.?;
    };

    const algos = [_]CompressionMode{ .lzma2, .bzip2, .zstd };
    var best_size: usize = std.math.maxInt(usize);
    var best_mode: CompressionMode = .lzma2; // default tiebreaker

    for (algos) |mode| {
        const comp_id = modeToCompressionId(mode).?;
        const compressed = blar.compression_mod.compressContainer(allocator, comp_id, sample, null, null, null, 0) catch continue;
        defer allocator.free(compressed);
        if (compressed.len < best_size) {
            best_size = compressed.len;
            best_mode = mode;
        }
    }

    return best_mode;
}

/// Compress the serialized ARRAY according to the given mode.
/// Returns the final output (compressed or uncompressed). Frees top_array if compressed version is used.
fn compressOutput(allocator: std.mem.Allocator, top_array: []u8, mode: CompressionMode) EncodeError![]u8 {
    switch (mode) {
        .none => return top_array,
        .lzma2, .bzip2, .lz4, .zstd => {
            const comp_id = modeToCompressionId(mode).?;
            const compressed = blar.compression_mod.compressContainer(allocator, comp_id, top_array, null, null, null, 0) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return top_array, // compression failed, return uncompressed
            };
            if (compressed.len < top_array.len) {
                allocator.free(top_array);
                return compressed;
            } else {
                allocator.free(compressed);
                return top_array;
            }
        },
        .best => {
            const chosen = try pickBestAlgo(allocator, top_array);
            if (chosen == .none) return top_array;
            const comp_id = modeToCompressionId(chosen).?;
            const compressed = blar.compression_mod.compressContainer(allocator, comp_id, top_array, null, null, null, 0) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return top_array,
            };
            if (compressed.len < top_array.len) {
                allocator.free(top_array);
                return compressed;
            } else {
                allocator.free(compressed);
                return top_array;
            }
        },
    }
}

// ---------------------------------------------------------------------------
// Encode
// ---------------------------------------------------------------------------

/// Serialize a DiffResult into BLIP bytes. Returns owned slice.
///
/// Format:
///   ARRAY (top-level)
///   +-- [0] DATA: magic "ZDIF\x02"
///   +-- [1] DATA: metadata (seed[32] + source_blake3[32] + target_blake3[32]
///                         + BLIP(chunk_size) + BLIP(size_a) + BLIP(size_b))
///   +-- [2] ARRAY: instructions
///       +-- [i] DATA: opcode + BLIP fields [+ data]
pub fn encode(allocator: std.mem.Allocator, result: diff_mod.DiffResult, compression: CompressionMode) EncodeError![]u8 {
    // 1. Build magic element
    const magic_data = try serializeDataContainer(allocator, MAGIC);
    defer allocator.free(magic_data);

    // 2. Build metadata element: seed and identities, then the three BLIP values.
    var meta_buf: [96 + 9 + 9 + 9]u8 = undefined;
    @memcpy(meta_buf[0..32], &result.options.seed);
    @memcpy(meta_buf[32..64], &result.source_blake3);
    @memcpy(meta_buf[64..96], &result.target_blake3);
    var meta_pos: usize = 96;
    meta_pos += try blipEncodeValue(@intCast(result.options.target_chunk_size), meta_buf[meta_pos..]);
    meta_pos += try blipEncodeValue(@intCast(result.size_a), meta_buf[meta_pos..]);
    meta_pos += try blipEncodeValue(@intCast(result.size_b), meta_buf[meta_pos..]);
    const metadata_data = try serializeDataContainer(allocator, meta_buf[0..meta_pos]);
    defer allocator.free(metadata_data);

    // 3. Build instruction DATA elements
    var instr_elements_list: std.ArrayList([]u8) = .empty;
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
                const data_elem = try serializeDataContainer(allocator, instr_buf[0..ipos]);
                instr_elements_list.append(allocator, data_elem) catch |err| {
                    allocator.free(data_elem);
                    return err;
                };
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
                const data_elem = try serializeDataContainer(allocator, payload_buf[0..ipos]);
                instr_elements_list.append(allocator, data_elem) catch |err| {
                    allocator.free(data_elem);
                    return err;
                };
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
    const top_elements = [_][]const u8{ magic_data, metadata_data, instr_array };
    const top_array = try blip.array_mod.serializeArray(allocator, &top_elements);

    // 6. Compress according to the requested mode.
    return compressOutput(allocator, top_array, compression);
}

// ---------------------------------------------------------------------------
// Decode
// ---------------------------------------------------------------------------

/// Deserialize BLIP bytes back into a DecodeResult.
/// Accepts both compressed and uncompressed ARRAY containers.
pub fn decode(allocator: std.mem.Allocator, data: []const u8) EncodeError!DecodeResult {
    // Check for compressed LP container and decompress if present
    var decompressed: ?[]u8 = null;
    defer if (decompressed) |d| allocator.free(d);

    const inner_data: []const u8 = if (blar.compression_mod.isCompressed(data)) blk: {
        decompressed = blar.compression_mod.decompressContainer(allocator, data) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidMagic,
        };
        break :blk decompressed.?;
    } else data;

    // Parse outer ARRAY
    const outer = blip.array_mod.ArrayReader.init(inner_data) catch return error.InvalidMagic;

    if (outer.elementCount() != 3) return error.InvalidMagic;

    // Element 0: magic (DATA container)
    const magic_view = outer.elementAt(0) catch return error.InvalidMagic;
    const magic_payload = magic_view.payloadSlice();
    if (!std.mem.eql(u8, magic_payload, MAGIC)) return error.InvalidMagic;

    // Element 1: metadata (DATA container)
    const meta_view = outer.elementAt(1) catch return error.InvalidLength;
    const meta_payload = meta_view.payloadSlice();
    if (meta_payload.len < 96) return error.InvalidLength;

    var seed: [32]u8 = undefined;
    @memcpy(&seed, meta_payload[0..32]);
    var source_blake3: [32]u8 = undefined;
    @memcpy(&source_blake3, meta_payload[32..64]);
    var target_blake3: [32]u8 = undefined;
    @memcpy(&target_blake3, meta_payload[64..96]);
    var mpos: usize = 96;

    const chunk_result = try blipDecodeValue(meta_payload[mpos..]);
    mpos += chunk_result.bytes_read;
    const target_chunk_size = std.math.cast(usize, chunk_result.value) orelse return error.LengthExceedsBounds;

    const size_a_result = try blipDecodeValue(meta_payload[mpos..]);
    mpos += size_a_result.bytes_read;
    const size_a = std.math.cast(usize, size_a_result.value) orelse return error.LengthExceedsBounds;

    const size_b_result = try blipDecodeValue(meta_payload[mpos..]);
    mpos += size_b_result.bytes_read;
    const size_b = std.math.cast(usize, size_b_result.value) orelse return error.LengthExceedsBounds;
    if (mpos != meta_payload.len) return error.InvalidLength;

    // Element 2: instructions array (ARRAY container)
    const instr_view = outer.elementAt(2) catch return error.InvalidLength;
    const instr_buf = instr_view.buf[0..@intCast(instr_view.total_length)];
    const instr_reader = blip.array_mod.ArrayReader.init(instr_buf) catch return error.InvalidLength;

    const op_count = std.math.cast(usize, instr_reader.elementCount()) orelse return error.LengthExceedsBounds;
    var instruction_cursor = try SequentialArrayCursor.init(instr_reader);
    var total_insert_bytes: usize = 0;
    for (0..op_count) |_| {
        const element = (try instruction_cursor.next()) orelse return error.InvalidLength;
        switch (try decodeInstructionView(element)) {
            .copy => {},
            .insert => |inserted_bytes| total_insert_bytes = std.math.add(usize, total_insert_bytes, inserted_bytes.len) catch return error.LengthExceedsBounds,
        }
    }

    const ops = try allocator.alloc(DiffOp, op_count);
    errdefer allocator.free(ops);
    const insert_storage = try allocator.alloc(u8, total_insert_bytes);
    errdefer allocator.free(insert_storage);

    instruction_cursor = try SequentialArrayCursor.init(instr_reader);
    var insert_pos: usize = 0;
    for (0..op_count) |i| {
        const element = (try instruction_cursor.next()) orelse return error.InvalidLength;
        switch (try decodeInstructionView(element)) {
            .copy => |copy| {
                ops[i] = .{
                    .tag = .copy,
                    .offset = copy.offset,
                    .length = copy.length,
                    .data = null,
                };
            },
            .insert => |inserted_bytes| {
                const owned_data = insert_storage[insert_pos..][0..inserted_bytes.len];
                @memcpy(owned_data, inserted_bytes);
                ops[i] = .{
                    .tag = .insert,
                    .offset = 0,
                    .length = inserted_bytes.len,
                    .data = owned_data,
                };
                insert_pos += inserted_bytes.len;
            },
        }
    }

    return DecodeResult{
        .ops = ops,
        .insert_storage = insert_storage,
        .seed = seed,
        .target_chunk_size = target_chunk_size,
        .size_a = size_a,
        .size_b = size_b,
        .source_blake3 = source_blake3,
        .target_blake3 = target_blake3,
    };
}

/// Free the contiguous INSERT storage and operation array.
pub fn freeDecoded(allocator: std.mem.Allocator, result: DecodeResult) void {
    allocator.free(result.insert_storage);
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
    const encoded = try encode(testing.allocator, result, .lzma2);
    defer testing.allocator.free(encoded);

    const decoded = try decode(testing.allocator, encoded);
    defer freeDecoded(testing.allocator, decoded);

    try testing.expectEqual(result.ops.len, decoded.ops.len);
    try testing.expectEqual(result.size_a, decoded.size_a);
    try testing.expectEqual(result.size_b, decoded.size_b);
    try testing.expectEqualSlices(u8, &result.source_blake3, &decoded.source_blake3);
    try testing.expectEqualSlices(u8, &result.target_blake3, &decoded.target_blake3);
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

test "instruction array cursor consumes each offset exactly once" {
    const op_count = 257;
    const ops = try testing.allocator.alloc(DiffOp, op_count);
    defer testing.allocator.free(ops);
    for (ops) |*op| {
        op.* = .{ .tag = .copy, .offset = 0, .length = 0, .data = null };
    }
    const result = diff_mod.DiffResult{
        .ops = ops,
        .options = .{ .seed = [_]u8{0} ** 32, .target_chunk_size = 64 },
        .size_a = 0,
        .size_b = 0,
    };
    const encoded = try encode(testing.allocator, result, .none);
    defer testing.allocator.free(encoded);

    const outer = try blip.array_mod.ArrayReader.init(encoded);
    const instruction_view = try outer.elementAt(2);
    const instruction_buf = instruction_view.buf[0..@intCast(instruction_view.total_length)];
    const instruction_reader = try blip.array_mod.ArrayReader.init(instruction_buf);
    var cursor = try SequentialArrayCursor.init(instruction_reader);

    for (0..op_count) |_| {
        const element = (try cursor.next()).?;
        try testing.expectEqual(@as(u8, 0x00), element.payloadSlice()[0]);
    }
    try testing.expect((try cursor.next()) == null);
    try testing.expectEqual(op_count, cursor.offsets_consumed);
}

test "decoding many inserts uses one contiguous data allocation" {
    const op_count = 16;
    const ops = try testing.allocator.alloc(DiffOp, op_count);
    defer testing.allocator.free(ops);
    for (ops) |*op| {
        op.* = .{ .tag = .insert, .offset = 0, .length = 1, .data = "x" };
    }
    const result = diff_mod.DiffResult{
        .ops = ops,
        .options = .{ .seed = [_]u8{0} ** 32, .target_chunk_size = 64 },
        .size_a = 0,
        .size_b = op_count,
    };
    const encoded = try encode(testing.allocator, result, .none);
    defer testing.allocator.free(encoded);

    var allocation_gate = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 2 });
    const decoded = try decode(allocation_gate.allocator(), encoded);
    defer freeDecoded(allocation_gate.allocator(), decoded);
    try testing.expectEqual(@as(usize, 2), allocation_gate.allocations);
    try testing.expectEqual(op_count, decoded.ops.len);
}

test "encoded diff is a valid LP container" {
    var ops_buf = [_]DiffOp{
        .{ .tag = .copy, .offset = 0, .length = 10, .data = null },
    };
    const result = diff_mod.DiffResult{
        .ops = &ops_buf,
        .options = .{ .seed = [_]u8{0} ** 32, .target_chunk_size = 256 },
        .size_a = 10,
        .size_b = 10,
    };
    const encoded = try encode(testing.allocator, result, .lzma2);
    defer testing.allocator.free(encoded);

    // Must round-trip successfully (validates container integrity)
    const decoded = try decode(testing.allocator, encoded);
    defer freeDecoded(testing.allocator, decoded);
    try testing.expectEqual(@as(usize, 1), decoded.ops.len);
}

test "decode rejects invalid magic" {
    // Just some random bytes, not a valid ZDIF container
    const bad = "not a valid difz blob";
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
    const encoded = try encode(testing.allocator, result, .lzma2);
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
    const encoded = try encode(testing.allocator, result, .lzma2);
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
    const encoded = try encode(testing.allocator, result, .lzma2);
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
    const encoded = try encode(testing.allocator, result, .lzma2);
    defer testing.allocator.free(encoded);
    const decoded = try decode(testing.allocator, encoded);
    defer freeDecoded(testing.allocator, decoded);
    try testing.expectEqualSlices(u8, &seed, &decoded.seed);
    try testing.expectEqual(@as(usize, 8192), decoded.target_chunk_size);
    try testing.expectEqual(@as(usize, 1_000_000), decoded.size_a);
    try testing.expectEqual(@as(usize, 1_000_001), decoded.size_b);
}

test "LZMA2 compressed encoding is smaller than uncompressed for repetitive data" {
    // Build a diff with a large repetitive Insert payload — highly compressible.
    const insert_data = "ABCDEFGHIJ" ** 200; // 2000 bytes of repetitive data
    var ops_buf = [_]DiffOp{
        .{ .tag = .copy, .offset = 0, .length = 100, .data = null },
        .{ .tag = .insert, .offset = 0, .length = 2000, .data = insert_data },
    };
    const result = diff_mod.DiffResult{
        .ops = &ops_buf,
        .options = .{ .seed = [_]u8{0} ** 32, .target_chunk_size = 1024 },
        .size_a = 100,
        .size_b = 2100,
    };
    const encoded = try encode(testing.allocator, result, .lzma2);
    defer testing.allocator.free(encoded);

    // Compressed container should be detected as compressed
    try testing.expect(blar.compression_mod.isCompressed(encoded));

    // Compressed should be smaller than the uncompressed insert data
    try testing.expect(encoded.len < 2000);

    // Must still decode correctly
    const decoded = try decode(testing.allocator, encoded);
    defer freeDecoded(testing.allocator, decoded);
    try testing.expectEqual(@as(usize, 2), decoded.ops.len);
    try testing.expectEqual(DiffOp.Tag.copy, decoded.ops[0].tag);
    try testing.expectEqual(DiffOp.Tag.insert, decoded.ops[1].tag);
    try testing.expectEqualStrings(insert_data, decoded.ops[1].data.?);
}

test "LZMA2 decode handles both compressed and uncompressed input" {
    // A small diff that may not benefit from compression — but encode always
    // compresses now. Either way, decode must handle it.
    var ops_buf = [_]DiffOp{
        .{ .tag = .copy, .offset = 0, .length = 10, .data = null },
    };
    const result = diff_mod.DiffResult{
        .ops = &ops_buf,
        .options = .{ .seed = [_]u8{0} ** 32, .target_chunk_size = 256 },
        .size_a = 10,
        .size_b = 10,
    };
    const encoded = try encode(testing.allocator, result, .lzma2);
    defer testing.allocator.free(encoded);

    const decoded = try decode(testing.allocator, encoded);
    defer freeDecoded(testing.allocator, decoded);
    try testing.expectEqual(@as(usize, 1), decoded.ops.len);
    try testing.expectEqual(DiffOp.Tag.copy, decoded.ops[0].tag);
    try testing.expectEqual(@as(usize, 10), decoded.ops[0].length);
}

test "bzip2 compression round-trips correctly" {
    const insert_data = "ABCDEFGHIJ" ** 200;
    var ops_buf = [_]DiffOp{
        .{ .tag = .copy, .offset = 0, .length = 100, .data = null },
        .{ .tag = .insert, .offset = 0, .length = 2000, .data = insert_data },
    };
    const result = diff_mod.DiffResult{
        .ops = &ops_buf,
        .options = .{ .seed = [_]u8{0} ** 32, .target_chunk_size = 1024 },
        .size_a = 100,
        .size_b = 2100,
    };
    const encoded = try encode(testing.allocator, result, .bzip2);
    defer testing.allocator.free(encoded);

    try testing.expect(blar.compression_mod.isCompressed(encoded));
    try testing.expect(encoded.len < 2000);

    const decoded = try decode(testing.allocator, encoded);
    defer freeDecoded(testing.allocator, decoded);
    try testing.expectEqual(@as(usize, 2), decoded.ops.len);
    try testing.expectEqualStrings(insert_data, decoded.ops[1].data.?);
}

test "lz4 compression round-trips correctly" {
    const insert_data = "ABCDEFGHIJ" ** 200;
    var ops_buf = [_]DiffOp{
        .{ .tag = .copy, .offset = 0, .length = 100, .data = null },
        .{ .tag = .insert, .offset = 0, .length = 2000, .data = insert_data },
    };
    const result = diff_mod.DiffResult{
        .ops = &ops_buf,
        .options = .{ .seed = [_]u8{0} ** 32, .target_chunk_size = 1024 },
        .size_a = 100,
        .size_b = 2100,
    };
    const encoded = try encode(testing.allocator, result, .lz4);
    defer testing.allocator.free(encoded);

    try testing.expect(blar.compression_mod.isCompressed(encoded));
    try testing.expect(encoded.len < 2000);

    const decoded = try decode(testing.allocator, encoded);
    defer freeDecoded(testing.allocator, decoded);
    try testing.expectEqual(@as(usize, 2), decoded.ops.len);
    try testing.expectEqualStrings(insert_data, decoded.ops[1].data.?);
}

test "zstd compression round-trips correctly" {
    const insert_data = "ABCDEFGHIJ" ** 200;
    var ops_buf = [_]DiffOp{
        .{ .tag = .copy, .offset = 0, .length = 100, .data = null },
        .{ .tag = .insert, .offset = 0, .length = 2000, .data = insert_data },
    };
    const result = diff_mod.DiffResult{
        .ops = &ops_buf,
        .options = .{ .seed = [_]u8{0} ** 32, .target_chunk_size = 1024 },
        .size_a = 100,
        .size_b = 2100,
    };
    const encoded = try encode(testing.allocator, result, .zstd);
    defer testing.allocator.free(encoded);

    try testing.expect(blar.compression_mod.isCompressed(encoded));
    try testing.expect(encoded.len < 2000);

    const decoded = try decode(testing.allocator, encoded);
    defer freeDecoded(testing.allocator, decoded);
    try testing.expectEqual(@as(usize, 2), decoded.ops.len);
    try testing.expectEqualStrings(insert_data, decoded.ops[1].data.?);
}

test "none compression produces uncompressed output" {
    const insert_data = "ABCDEFGHIJ" ** 200;
    var ops_buf = [_]DiffOp{
        .{ .tag = .copy, .offset = 0, .length = 100, .data = null },
        .{ .tag = .insert, .offset = 0, .length = 2000, .data = insert_data },
    };
    const result = diff_mod.DiffResult{
        .ops = &ops_buf,
        .options = .{ .seed = [_]u8{0} ** 32, .target_chunk_size = 1024 },
        .size_a = 100,
        .size_b = 2100,
    };
    const encoded = try encode(testing.allocator, result, .none);
    defer testing.allocator.free(encoded);

    // Should NOT be compressed
    try testing.expect(!blar.compression_mod.isCompressed(encoded));

    // Must still decode correctly
    const decoded = try decode(testing.allocator, encoded);
    defer freeDecoded(testing.allocator, decoded);
    try testing.expectEqual(@as(usize, 2), decoded.ops.len);
    try testing.expectEqualStrings(insert_data, decoded.ops[1].data.?);
}

test "best compression round-trips correctly" {
    const insert_data = "ABCDEFGHIJ" ** 200;
    var ops_buf = [_]DiffOp{
        .{ .tag = .copy, .offset = 0, .length = 100, .data = null },
        .{ .tag = .insert, .offset = 0, .length = 2000, .data = insert_data },
    };
    const result = diff_mod.DiffResult{
        .ops = &ops_buf,
        .options = .{ .seed = [_]u8{0} ** 32, .target_chunk_size = 1024 },
        .size_a = 100,
        .size_b = 2100,
    };
    const encoded = try encode(testing.allocator, result, .best);
    defer testing.allocator.free(encoded);

    // best should pick a compression algorithm for compressible data
    try testing.expect(blar.compression_mod.isCompressed(encoded));
    try testing.expect(encoded.len < 2000);

    const decoded = try decode(testing.allocator, encoded);
    defer freeDecoded(testing.allocator, decoded);
    try testing.expectEqual(@as(usize, 2), decoded.ops.len);
    try testing.expectEqualStrings(insert_data, decoded.ops[1].data.?);
}

test "pickBestAlgo returns a valid algorithm for small input" {
    // Small compressible data — should try all algorithms exhaustively
    const data = "ABCDEFGHIJ" ** 200; // 2000 bytes, well below 192KB threshold
    const result = try pickBestAlgo(testing.allocator, data);
    // Must be one of the candidate algorithms
    try testing.expect(result == .lzma2 or result == .bzip2 or result == .zstd);
}

test "pickBestAlgo returns a valid algorithm for large input" {
    // Large repetitive data — should use distributed sampling
    const alloc = testing.allocator;
    const size = SAMPLE_THRESHOLD + 1024; // just above 384KB
    const data = try alloc.alloc(u8, size);
    defer alloc.free(data);
    // Fill with repetitive pattern
    for (data, 0..) |*b, i| {
        b.* = @intCast(i % 256);
    }
    const result = try pickBestAlgo(alloc, data);
    try testing.expect(result == .lzma2 or result == .bzip2 or result == .zstd);
}
