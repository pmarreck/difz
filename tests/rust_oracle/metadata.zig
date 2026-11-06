const std = @import("std");
const metadata = @import("reference").metadata;
const fixtures = @import("metadata_fixture.zig");

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
        10 => {
            if (input.len != 1) return error.BadMetadata;
            var wire = [_]u8{0} ** 26;
            wire[4] = 1; // One owner ACE with no name.
            wire[8] = 1;
            wire[9] = input[0];
            const parsed = try metadata.decodeCanonical(allocator, &wire);
            const encoded = try metadata.encodeCanonical(allocator, parsed);
            return encoded[9..10];
        },
        11 => {
            if (input.len != 1) return error.BadMetadata;
            var record: metadata.Metadata = .{};
            switch (input[0]) {
                0 => {},
                1 => record.xattrs = &.{.{ .class = .logical, .name = "x", .value = "" }},
                2 => record.aces = &.{.{ .tag = .owner }},
                3 => record.native_acl = .{ .origin = .linux, .bytes = "" },
                4 => record.times.mtime = .{},
                5 => record.times.atime = .{},
                6 => record.times.btime = .{},
                7 => record.finder_flags = 1,
                8 => record.finder_info = [_]u8{0} ** 32,
                9 => record.holes = &.{.{ .offset = 0, .length = 1 }},
                10 => record.hardlink_to = "",
                else => return error.BadMetadata,
            }
            return allocator.dupe(u8, &.{@intFromBool(record.isEmpty())});
        },
        12, 13 => {
            if (input.len != 1) return error.BadMetadata;
            const raw = try fixtures.make(allocator, input[0]);
            const encoded = try metadata.encodeCanonical(allocator, raw);
            const parsed = try metadata.decodeCanonical(allocator, encoded);
            if (mode == 12) return encoded;
            const digest = metadata.canonicalHash(parsed);
            return allocator.dupe(u8, &digest);
        },
        14, 15 => {
            const parsed = try metadata.decodeCanonical(allocator, input);
            if (mode == 14) return metadata.encodeCanonical(allocator, parsed);
            const digest = metadata.canonicalHash(parsed);
            return allocator.dupe(u8, &digest);
        },
        16, 17 => {
            if (input.len != 2) return error.BadMetadata;
            const raw = try fixtures.forNormalization(allocator, input[0]);
            const omit = try metadata.Omit.fromBits(input[1]);
            const normalized = try metadata.canonicalize(allocator, raw, omit);
            if (mode == 16) return metadata.encodeCanonical(allocator, normalized);
            return allocator.dupe(u8, &metadata.canonicalHash(normalized));
        },
        18 => {
            if (input.len % 16 != 0) return error.BadMetadata;
            const holes = try allocator.alloc(metadata.Hole, input.len / 16);
            for (holes, 0..) |*hole, index| {
                const offset = index * 16;
                hole.* = .{
                    .offset = std.mem.readInt(u64, input[offset..][0..8], .little),
                    .length = std.mem.readInt(u64, input[offset + 8 ..][0..8], .little),
                };
            }
            const normalized = try metadata.canonicalize(allocator, .{ .holes = holes }, .{});
            return metadata.encodeCanonical(allocator, normalized);
        },
        20, 21, 22 => return @import("restore.zig").run(allocator, mode, input),
        30, 31 => return @import("directory.zig").run(allocator, mode, input),
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
