const std = @import("std");
const metadata = @import("metadata");

fn run(allocator: std.mem.Allocator, mode: u32, input: []const u8) ![]const u8 {
    switch (mode) {
        0, 1 => {
            const omit = if (mode == 0) blk: {
                if (input.len != 4) return error.BadMetadata;
                break :blk try metadata.Omit.fromBits(std.mem.readInt(u32, input[0..4], .little));
            } else try metadata.parseOmit(input);
            const bytes = try allocator.alloc(u8, 4);
            std.mem.writeInt(u32, bytes[0..4], omit.bits(), .little);
            return bytes;
        },
        2 => {
            const parsed = try metadata.decodeTimeOverride(input);
            var buffer: [13]u8 = undefined;
            return allocator.dupe(u8, try metadata.encodeTimeOverride(parsed, &buffer));
        },
        3 => {
            const parsed = try metadata.decodeModificationOverride(input);
            var buffer: [25]u8 = undefined;
            return allocator.dupe(u8, try metadata.encodeModificationOverride(parsed, &buffer));
        },
        4, 5 => {
            const xattrs = [_]metadata.Xattr{.{ .class = if (mode == 4) .logical else .raw, .name = input, .value = "" }};
            _ = try metadata.canonicalize(allocator, .{ .xattrs = &xattrs }, .{});
            return &.{};
        },
        6 => {
            _ = try metadata.canonicalize(allocator, .{ .hardlink_to = input }, .{});
            return &.{};
        },
        7 => {
            if (input.len == 0) return error.BadMetadata;
            const tag = std.enums.fromInt(metadata.AceTag, input[0]) orelse return error.BadMetadata;
            const aces = [_]metadata.Ace{.{ .tag = tag, .name = input[1..] }};
            _ = try metadata.canonicalize(allocator, .{ .aces = &aces }, .{});
            return &.{};
        },
        8 => return allocator.dupe(u8, &.{@intFromBool(metadata.isTransportName(input))}),
        9 => {
            if (input.len == 0) return error.BadMetadata;
            const os = std.enums.fromInt(metadata.Os, input[0]) orelse return error.BadMetadata;
            return allocator.dupe(u8, &.{@intFromBool(metadata.rawAccepted(os, input[1..]))});
        },
        else => return error.BadMetadata,
    }
}

export fn difz_metadata_oracle(mode: u32, input: [*]const u8, input_len: usize, output: [*]u8, output_capacity: usize, error_out: [*]u8, error_capacity: usize, error_len: *usize) usize {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    error_len.* = 0;
    const result = run(arena.allocator(), mode, input[0..input_len]) catch |err| {
        const name = @errorName(err);
        const count = @min(name.len, error_capacity);
        @memcpy(error_out[0..count], name[0..count]);
        error_len.* = count;
        return std.math.maxInt(usize);
    };
    if (result.len > output_capacity) return std.math.maxInt(usize);
    @memcpy(output[0..result.len], result);
    return result.len;
}
