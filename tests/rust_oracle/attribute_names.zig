const std = @import("std");
const names = @import("reference").attribute_names;
pub fn run(allocator: std.mem.Allocator, mode: u32, input: []const u8) ![]const u8 {
    if (input.len < 2 or input[1] < 1 or input[1] > 2) return error.BadMetadata;
    const os: names.Os = switch (input[0]) { 1 => .linux, 2 => .macos, 3 => .windows, else => return error.BadMetadata };
    const options: names.NameOptions = .{ .raw = input[1] == 2 };
    if (mode == 54) {
        if (input.len < 4) return error.BadMetadata;
        const capacity = std.mem.readInt(u16, input[2..4], .little);
        var buffer: [512]u8 = undefined;
        if (capacity > buffer.len) return error.BadMetadata;
        return allocator.dupe(u8, try names.toNative(os, input[4..], options, buffer[0..capacity]));
    }
    if (names.fromNative(os, input[2..], options)) |name| {
        const output = try allocator.alloc(u8, name.len + 1);
        output[0] = 1;
        @memcpy(output[1..], name);
        return output;
    }
    return &.{0};
}
