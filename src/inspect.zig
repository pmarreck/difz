const std = @import("std");
const testing = std.testing;
const encoding = @import("encoding.zig");
const diff_mod = @import("diff.zig");
const pb = @import("printable_binary");

pub const DiffOp = diff_mod.DiffOp;

/// Format a byte count as a human-readable string (e.g. "5.2MB").
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

/// Inspect a diff blob and produce a human-readable text description.
/// Returns an owned text buffer that the caller must free.
pub fn inspect(
    allocator: std.mem.Allocator,
    diff_blob: []const u8,
    max_data_bytes: usize,
    hexlike: bool,
) ![]u8 {
    // Decode the diff
    const decoded = try encoding.decode(allocator, diff_blob);
    defer encoding.freeDecoded(allocator, decoded);

    // Build output using an ArrayList
    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(allocator);
    const writer = out.writer(allocator);

    // Header line
    var size_a_buf: [64]u8 = undefined;
    var size_b_buf: [64]u8 = undefined;
    const size_a_str = formatSize(&size_a_buf, decoded.size_a);
    const size_b_str = formatSize(&size_b_buf, decoded.size_b);

    try writer.print("zdiff inspect: {d} ops, source={s}, target={s}, chunk_size={d}\n\n", .{
        decoded.ops.len,
        size_a_str,
        size_b_str,
        decoded.target_chunk_size,
    });

    // Op lines
    for (decoded.ops, 0..) |op, i| {
        switch (op.tag) {
            .copy => {
                try writer.print("  #{d:<4}COPY    offset={d:<10}length={d}\n", .{
                    i, op.offset, op.length,
                });
            },
            .insert => {
                const data = op.data orelse &[_]u8{};
                const display_len = @min(data.len, max_data_bytes);
                const display_data = data[0..display_len];

                // Encode the display portion via printable-binary
                const encoded_display = if (hexlike)
                    try pb.hexlikeEncode(allocator, display_data, .{})
                else
                    try pb.encode(allocator, display_data, .{});
                defer allocator.free(encoded_display);

                if (data.len > max_data_bytes) {
                    try writer.print("  #{d:<4}INSERT  length={d:<10}data=\u{300c}{s}...\u{300d} (truncated, {d} bytes total)\n", .{
                        i, op.length, encoded_display, data.len,
                    });
                } else {
                    try writer.print("  #{d:<4}INSERT  length={d:<10}data=\u{300c}{s}\u{300d}\n", .{
                        i, op.length, encoded_display,
                    });
                }
            },
        }
    }

    return try out.toOwnedSlice(allocator);
}

// ============================================================================
// Tests
// ============================================================================

test "inspect: basic round-trip formatting" {
    const alloc = testing.allocator;

    // Build a small diff with known ops
    var ops_buf = [_]DiffOp{
        .{ .tag = .copy, .offset = 0, .length = 100, .data = null },
        .{ .tag = .insert, .offset = 0, .length = 5, .data = "hello" },
        .{ .tag = .copy, .offset = 105, .length = 200, .data = null },
    };
    const diff_result = diff_mod.DiffResult{
        .ops = &ops_buf,
        .options = .{ .seed = [_]u8{42} ** 32, .target_chunk_size = 1024 },
        .size_a = 305,
        .size_b = 305,
    };
    const encoded_diff = try encoding.encode(alloc, diff_result, .lzma2);
    defer alloc.free(encoded_diff);

    const output = try inspect(alloc, encoded_diff, 64, false);
    defer alloc.free(output);

    // Verify header
    try testing.expect(std.mem.indexOf(u8, output, "3 ops") != null);
    try testing.expect(std.mem.indexOf(u8, output, "chunk_size=1024") != null);

    // Verify COPY ops present
    try testing.expect(std.mem.indexOf(u8, output, "COPY") != null);
    try testing.expect(std.mem.indexOf(u8, output, "offset=0") != null);

    // Verify INSERT op with data in corner brackets
    try testing.expect(std.mem.indexOf(u8, output, "INSERT") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\u{300c}") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\u{300d}") != null);
}

test "inspect: truncation" {
    const alloc = testing.allocator;

    const long_data = "A" ** 200;
    var ops_buf = [_]DiffOp{
        .{ .tag = .insert, .offset = 0, .length = 200, .data = long_data },
    };
    const diff_result = diff_mod.DiffResult{
        .ops = &ops_buf,
        .options = .{ .seed = [_]u8{0} ** 32, .target_chunk_size = 256 },
        .size_a = 0,
        .size_b = 200,
    };
    const encoded_diff = try encoding.encode(alloc, diff_result, .lzma2);
    defer alloc.free(encoded_diff);

    // Truncate to 16 bytes
    const output = try inspect(alloc, encoded_diff, 16, false);
    defer alloc.free(output);

    // Should show truncation message
    try testing.expect(std.mem.indexOf(u8, output, "truncated") != null);
    try testing.expect(std.mem.indexOf(u8, output, "200 bytes total") != null);
}

test "inspect: no truncation when data fits" {
    const alloc = testing.allocator;

    var ops_buf = [_]DiffOp{
        .{ .tag = .insert, .offset = 0, .length = 3, .data = "abc" },
    };
    const diff_result = diff_mod.DiffResult{
        .ops = &ops_buf,
        .options = .{ .seed = [_]u8{0} ** 32, .target_chunk_size = 256 },
        .size_a = 0,
        .size_b = 3,
    };
    const encoded_diff = try encoding.encode(alloc, diff_result, .lzma2);
    defer alloc.free(encoded_diff);

    const output = try inspect(alloc, encoded_diff, 64, false);
    defer alloc.free(output);

    // Should NOT show truncation
    try testing.expect(std.mem.indexOf(u8, output, "truncated") == null);
}

test "inspect: hexlike mode" {
    const alloc = testing.allocator;

    var ops_buf = [_]DiffOp{
        .{ .tag = .insert, .offset = 0, .length = 3, .data = "\x00\x01\x02" },
    };
    const diff_result = diff_mod.DiffResult{
        .ops = &ops_buf,
        .options = .{ .seed = [_]u8{0} ** 32, .target_chunk_size = 256 },
        .size_a = 0,
        .size_b = 3,
    };
    const encoded_diff = try encoding.encode(alloc, diff_result, .lzma2);
    defer alloc.free(encoded_diff);

    const output = try inspect(alloc, encoded_diff, 64, true);
    defer alloc.free(output);

    // Hexlike mode should produce hex output (contains uppercase hex digits)
    try testing.expect(std.mem.indexOf(u8, output, "000102") != null);
}

test "inspect: empty ops" {
    const alloc = testing.allocator;

    const diff_result = diff_mod.DiffResult{
        .ops = &[_]DiffOp{},
        .options = .{ .seed = [_]u8{0} ** 32, .target_chunk_size = 64 },
        .size_a = 0,
        .size_b = 0,
    };
    const encoded_diff = try encoding.encode(alloc, diff_result, .lzma2);
    defer alloc.free(encoded_diff);

    const output = try inspect(alloc, encoded_diff, 64, false);
    defer alloc.free(output);

    try testing.expect(std.mem.indexOf(u8, output, "0 ops") != null);
}
