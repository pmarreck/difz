const blip = @import("blip");
const std = @import("std");

pub const version = "0.1.0";

test "blip dependency works" {
	var buf: [16]u8 = undefined;
	const n = try blip.encode(42, &buf);
	const result = try blip.decode(buf[0..n]);
	try std.testing.expectEqual(@as(u64, 42), result.value);
}

test {
	_ = @import("gear_hash.zig");
	_ = @import("cdc.zig");
	_ = @import("chunk_match.zig");
	_ = @import("elder_diff.zig");
	_ = @import("diff.zig");
}
