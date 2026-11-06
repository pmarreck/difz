const std = @import("std");
const reference = @import("reference");
const transport = reference.symlink_transport;
const metadata = reference.metadata;
pub fn run(allocator: std.mem.Allocator, mode: u32, input: []const u8) ![]const u8 {
    if (mode == 47) {
        var decoded = try transport.decode(allocator, input);
        defer decoded.deinit();
        return transport.encode(allocator, decoded.records);
    }
    if (std.mem.eql(u8, input, &.{0})) return transport.encode(allocator, &.{});
    if (input.len == 1 and input[0] == 2) {
        return transport.encode(allocator, &.{
            .{ .name = "a", .meta = .{ .times = .{ .btime = .{ .sec = -1, .nsec = 999_999_999 } } } },
            .{ .name = "é", .meta = .{ .native_acl = .{ .origin = .windows, .bytes = "DACL" }, .finder_flags = 1, .finder_info = [_]u8{0} ** 32 } },
        });
    }
    const attrs = [_]metadata.Xattr{.{ .class = .logical, .name = "x", .value = "\x00\xff" }};
    if (input.len == 2 and input[0] == 6) {
        var meta: metadata.Metadata = .{};
        switch (input[1]) {
            0 => meta.holes = &.{.{ .offset = 0, .length = 1 }},
            1 => meta.hardlink_to = "base",
            2 => {},
            else => return error.BadFixture,
        }
        return transport.encode(allocator, &.{.{ .name = "a", .meta = meta }});
    }
    if (input.len > 0 and input[0] == 3) return transport.encode(allocator, &.{.{ .name = input[1..], .meta = .{ .xattrs = &attrs } }});
    if (input.len == 5 and input[0] == 4) {
        const count = std.mem.readInt(u32, input[1..5], .little);
        if (count > transport.max_bytes) return error.BadFixture;
        const value = try allocator.alloc(u8, count);
        @memset(value, 0);
        return transport.encode(allocator, &.{.{ .name = "a", .meta = .{ .xattrs = &.{.{ .class = .logical, .name = "x", .value = value }} } }});
    }
    if (input.len == 5 and input[0] == 5) {
        const count = std.mem.readInt(u32, input[1..5], .little);
        if (count > 2114) return error.BadFixture;
        const records = try allocator.alloc(transport.Record, count);
        for (records) |*record| record.* = .{ .name = "a", .meta = .{ .xattrs = &attrs } };
        return transport.encode(allocator, records);
    }
    if (input.len != 3 or input[0] != 1 or input[2] >= 128) return error.BadFixture;
    const flags = input[2];
    const time: metadata.Time = .{ .sec = -1, .nsec = 7 };
    return transport.encode(allocator, &.{.{
        .name = "a", .absent_times = input[1],
        .observed_mtime = if (flags & 8 != 0) .{ .sec = 42 } else null,
        .acl_override = flags & 16 != 0, .finder_override = flags & 32 != 0,
        .meta = .{ .xattrs = if (flags & 64 != 0) &attrs else &.{}, .times = .{
            .mtime = if (flags & 1 != 0) time else null, .atime = if (flags & 2 != 0) time else null,
            .btime = if (flags & 4 != 0) time else null,
        } },
    }});
}
