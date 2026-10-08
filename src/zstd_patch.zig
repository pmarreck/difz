const std = @import("std");
const testing = std.testing;

const c = @cImport({
	@cDefine("ZSTD_STATIC_LINKING_ONLY", "1");
	@cInclude("zstd.h");
});

pub const level: i32 = 9;
pub const magic = "ZDIF\x04";
pub const header_len: usize = magic.len + 32 + 32 + 8 + 8;

pub const Error = error{
	OutOfMemory,
	InvalidMagic,
	Truncated,
	SizeMismatch,
	SourceHashMismatch,
	TargetHashMismatch,
	WindowTooLarge,
	CompressionFailed,
	DecompressionFailed,
	ResourceLimitExceeded,
};

pub const Info = struct {
	size_a: usize,
	size_b: usize,
	source_blake3: [32]u8,
	target_blake3: [32]u8,
};

/// BLAKE3 of a file body. Kept outside the zstd frame so a wrong source is
/// rejected before reconstruction output is allocated.
pub fn fileIdentity(data: []const u8) [32]u8 {
	var digest: [32]u8 = undefined;
	std.crypto.hash.Blake3.hash(data, &digest, .{});
	return digest;
}

fn asUsize(n: u64) Error!usize {
	if (n > std.math.maxInt(usize)) return error.WindowTooLarge;
	return @intCast(n);
}

/// Window log zstd needs so a match at the first prefix byte is in range.
/// Matches the zstd CLI `--patch-from` clamp: floor(log2(span))+1, then
/// clamped to [10, 31]. Either length above 2 GiB is `WindowTooLarge`.
const window_log_min: u32 = c.ZSTD_WINDOWLOG_MIN;
const window_log_max: u32 = c.ZSTD_WINDOWLOG_MAX;

pub fn patchWindowLog(source_len: u64, target_len: u64) Error!u32 {
	const max_window: u64 = @as(u64, 1) << window_log_max;
	if (source_len > max_window or target_len > max_window) return error.WindowTooLarge;
	const span = @max(source_len, target_len);
	if (span == 0) return window_log_min;
	const raw: u32 = 64 - @clz(span);
	return std.math.clamp(raw, window_log_min, window_log_max);
}

fn zstdOk(rc: usize) bool {
	return c.ZSTD_isError(rc) == 0;
}

fn setParam(cctx: *c.ZSTD_CCtx, param: c.ZSTD_cParameter, value: c_int) Error!void {
	if (!zstdOk(c.ZSTD_CCtx_setParameter(cctx, param, value))) return error.CompressionFailed;
}

/// `ZSTD_cycleLog` from the zstd CLI. The first argument is chainLog, despite
/// the historical parameter name.
fn cycleLog(chain_log: c_uint, strategy: c_uint) c_uint {
	const btlazy2: c_uint = c.ZSTD_btlazy2;
	const scale: c_uint = if (strategy >= btlazy2) 1 else 0;
	return chain_log - scale;
}

/// Serialize `target` as a zstd level-9 frame that uses `source` as its prefix.
/// The caller owns the returned ZDIF v4 bytes.
pub fn encode(allocator: std.mem.Allocator, source: []const u8, target: []const u8) Error![]u8 {
	const window_log = try patchWindowLog(source.len, target.len);
	const cparams = c.ZSTD_getCParams(level, target.len, source.len);
	const raw_log: u32 = if (@max(source.len, target.len) == 0) 0 else 64 - @clz(@max(source.len, target.len));
	const long_distance: c_int = if (raw_log > cycleLog(cparams.chainLog, cparams.strategy)) 1 else 0;

	const cctx = c.ZSTD_createCCtx() orelse return error.OutOfMemory;
	defer _ = c.ZSTD_freeCCtx(cctx);
	try setParam(cctx, c.ZSTD_c_compressionLevel, level);
	try setParam(cctx, c.ZSTD_c_nbWorkers, 0);
	try setParam(cctx, c.ZSTD_c_enableLongDistanceMatching, long_distance);
	try setParam(cctx, c.ZSTD_c_windowLog, @intCast(window_log));
	try setParam(cctx, c.ZSTD_c_chainLog, @intCast(cparams.chainLog));
	try setParam(cctx, c.ZSTD_c_hashLog, @intCast(cparams.hashLog));
	try setParam(cctx, c.ZSTD_c_searchLog, @intCast(cparams.searchLog));
	try setParam(cctx, c.ZSTD_c_minMatch, @intCast(cparams.minMatch));
	try setParam(cctx, c.ZSTD_c_targetLength, @intCast(cparams.targetLength));
	try setParam(cctx, c.ZSTD_c_strategy, @intCast(cparams.strategy));
	if (source.len > 0) {
		if (!zstdOk(c.ZSTD_CCtx_refPrefix(cctx, source.ptr, source.len))) return error.CompressionFailed;
	}

	const bound = c.ZSTD_compressBound(target.len);
	if (!zstdOk(bound)) return error.CompressionFailed;
	const total = std.math.add(usize, header_len, bound) catch return error.CompressionFailed;
	const buf = try allocator.alloc(u8, total);
	errdefer allocator.free(buf);

	const source_hash = fileIdentity(source);
	const target_hash = fileIdentity(target);
	@memcpy(buf[0..magic.len], magic);
	@memcpy(buf[magic.len..][0..32], &source_hash);
	@memcpy(buf[magic.len + 32 ..][0..32], &target_hash);
	std.mem.writeInt(u64, buf[magic.len + 64 ..][0..8], source.len, .little);
	std.mem.writeInt(u64, buf[magic.len + 72 ..][0..8], target.len, .little);

	const written = c.ZSTD_compress2(cctx, buf[header_len..].ptr, bound, if (target.len == 0) null else target.ptr, target.len);
	if (!zstdOk(written)) return error.CompressionFailed;
	return allocator.realloc(buf, header_len + written) catch return error.OutOfMemory;
}

/// Read the ZDIF v4 header. Does not allocate and does not touch the frame.
pub fn info(patch: []const u8) Error!Info {
	if (patch.len < magic.len or !std.mem.eql(u8, patch[0..magic.len], magic)) return error.InvalidMagic;
	if (patch.len < header_len) return error.Truncated;
	const size_a = try asUsize(std.mem.readInt(u64, patch[magic.len + 64 ..][0..8], .little));
	const size_b = try asUsize(std.mem.readInt(u64, patch[magic.len + 72 ..][0..8], .little));
	var source_blake3: [32]u8 = undefined;
	var target_blake3: [32]u8 = undefined;
	@memcpy(&source_blake3, patch[magic.len..][0..32]);
	@memcpy(&target_blake3, patch[magic.len + 32 ..][0..32]);
	return .{
		.size_a = size_a,
		.size_b = size_b,
		.source_blake3 = source_blake3,
		.target_blake3 = target_blake3,
	};
}

fn exceedsOutputLimit(len: usize, max_output_bytes: usize) bool {
	return max_output_bytes != 0 and len > max_output_bytes;
}

/// Reconstruct `target` from `source` and a ZDIF v4 patch.
/// `max_output_bytes == 0` means unlimited. The source BLAKE3 is checked
/// before the reconstruction buffer is allocated.
pub fn applyLimited(
	allocator: std.mem.Allocator,
	source: []const u8,
	patch: []const u8,
	max_output_bytes: usize,
) Error![]u8 {
	const parsed = try info(patch);
	if (parsed.size_a != source.len) return error.SizeMismatch;
	if (!std.mem.eql(u8, &parsed.source_blake3, &fileIdentity(source))) return error.SourceHashMismatch;
	if (exceedsOutputLimit(parsed.size_b, max_output_bytes)) return error.ResourceLimitExceeded;
	_ = try patchWindowLog(source.len, parsed.size_b);

	const output = try allocator.alloc(u8, parsed.size_b);
	errdefer allocator.free(output);

	const dctx = c.ZSTD_createDCtx() orelse return error.OutOfMemory;
	defer _ = c.ZSTD_freeDCtx(dctx);
	const max_window: usize = @as(usize, 1) << c.ZSTD_WINDOWLOG_MAX;
	if (!zstdOk(c.ZSTD_DCtx_setMaxWindowSize(dctx, max_window))) return error.DecompressionFailed;
	if (source.len > 0) {
		if (!zstdOk(c.ZSTD_DCtx_refPrefix(dctx, source.ptr, source.len))) return error.DecompressionFailed;
	}
	const frame = patch[header_len..];
	const written = c.ZSTD_decompressDCtx(
		dctx,
		if (output.len == 0) null else output.ptr,
		output.len,
		if (frame.len == 0) null else frame.ptr,
		frame.len,
	);
	if (!zstdOk(written) or written != parsed.size_b) return error.DecompressionFailed;
	if (!std.mem.eql(u8, &parsed.target_blake3, &fileIdentity(output))) return error.TargetHashMismatch;
	return output;
}

fn expectRoundTrip(source: []const u8, target: []const u8) !void {
	const patch = try encode(testing.allocator, source, target);
	defer testing.allocator.free(patch);
	const again = try encode(testing.allocator, source, target);
	defer testing.allocator.free(again);
	try testing.expectEqualSlices(u8, patch, again);
	try testing.expect(patch.len >= header_len);
	try testing.expectEqualSlices(u8, magic, patch[0..magic.len]);
	try testing.expectEqualSlices(u8, &.{ 0x28, 0xB5, 0x2F, 0xFD }, patch[header_len..][0..4]);
	const decoded = try info(patch);
	try testing.expectEqual(source.len, decoded.size_a);
	try testing.expectEqual(target.len, decoded.size_b);
	const reconstructed = try applyLimited(testing.allocator, source, patch, 0);
	defer testing.allocator.free(reconstructed);
	try testing.expectEqualSlices(u8, target, reconstructed);
}

test "zstd patch-from round-trips bytes that contain an embedded NUL" {
	const source = "alpha\x00beta";
	const target = "alpha\x00BETA\x00";
	try expectRoundTrip(source, target);
}

test "zstd patch-from round-trips empty, identical, and source-only inputs" {
	try expectRoundTrip("", "");
	try expectRoundTrip("same bytes", "same bytes");
	try expectRoundTrip("source only", "");
	try expectRoundTrip("", "target only");
}

test "zstd patch-from rejects a v3 container and a truncated header" {
	const patch = try encode(testing.allocator, "abc", "abd");
	defer testing.allocator.free(patch);
	var v3 = try testing.allocator.dupe(u8, patch);
	defer testing.allocator.free(v3);
	v3[magic.len - 1] = 3;
	try testing.expectError(error.InvalidMagic, applyLimited(testing.allocator, "abc", v3, 0));
	try testing.expectError(error.InvalidMagic, applyLimited(testing.allocator, "abc", "ZDIF\x03", 0));
	try testing.expectError(error.Truncated, applyLimited(testing.allocator, "abc", patch[0..header_len - 1], 0));
	try testing.expectError(error.InvalidMagic, applyLimited(testing.allocator, "abc", "not a patch", 0));
}

test "zstd patch-from checks the source identity before allocating output" {
	const source = "0123456789";
	const target = "0123456789XYZ";
	const patch = try encode(testing.allocator, source, target);
	defer testing.allocator.free(patch);
	try testing.expectError(
		error.SourceHashMismatch,
		applyLimited(testing.failing_allocator, "9999999999", patch, 0),
	);
	try testing.expectError(
		error.SizeMismatch,
		applyLimited(testing.failing_allocator, "012345678", patch, 0),
	);
	try testing.expectError(
		error.ResourceLimitExceeded,
		applyLimited(testing.failing_allocator, source, patch, 1),
	);
}

fn expectedWindowLog(source_len: u64, target_len: u64) ?u32 {
	const max_window: u64 = 1 << 31;
	if (source_len > max_window or target_len > max_window) return null;
	const span = @max(source_len, target_len);
	if (span == 0) return 10;
	const raw: u32 = 64 - @clz(span);
	return std.math.clamp(raw, 10, 31);
}

test "zstd patch-from window log matches the zstd --patch-from clamp" {
	const sizes = [_]u64{ 0, 1, 1024, (1 << 30) + 1, (1 << 31) - 1, 1 << 31, (1 << 31) + 1 };
	for (sizes) |source_len| {
		for (sizes) |target_len| {
			const result = patchWindowLog(source_len, target_len);
			if (expectedWindowLog(source_len, target_len)) |log| {
				try testing.expectEqual(log, result);
			} else {
				try testing.expectError(error.WindowTooLarge, result);
			}
		}
	}
}
