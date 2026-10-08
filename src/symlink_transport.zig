const std = @import("std");
const metadata = @import("metadata.zig");
const directory = @import("directory.zig");
const testing = std.testing;

pub const attribute = "difz.symlinks";
pub const max_bytes = 65_536;
const magic = "DIFZLINK\x01";

pub const Record = struct { name: []const u8, meta: metadata.Metadata, absent_times: u8 = 0, observed_mtime: ?metadata.Time = null, acl_override: bool = false, finder_override: bool = false };
pub const Decoded = struct {
    arena: std.heap.ArenaAllocator,
    records: []Record,

    pub fn deinit(self: *Decoded) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn encode(allocator: std.mem.Allocator, records: []const Record) ![]u8 {
    if (records.len > (max_bytes - magic.len - 4) / 31) return error.TransportTooLarge;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var bytes: std.ArrayListUnmanaged(u8) = .empty;
    errdefer bytes.deinit(allocator);
    try bytes.appendSlice(allocator, magic);
    try appendInt(allocator, &bytes, @intCast(records.len));
    for (records, 0..) |record, index| {
        try validateRecord(record);
        if (index > 0 and std.mem.order(u8, records[index - 1].name, record.name) != .lt) return error.InvalidTransport;
        const canonical = try metadata.canonicalize(arena.allocator(), record.meta, .{});
        const blob = try metadata.encodeCanonical(allocator, canonical);
        defer allocator.free(blob);
        var time_buffer: [13]u8 = undefined;
        const observed = try metadata.encodeTimeOverride(record.observed_mtime, &time_buffer);
        const needed = std.math.add(usize, 9 + observed.len + record.name.len, blob.len) catch return error.TransportTooLarge;
        if (needed > max_bytes - bytes.items.len) return error.TransportTooLarge;
        try appendInt(allocator, &bytes, @intCast(record.name.len));
        try appendInt(allocator, &bytes, @intCast(blob.len));
        try bytes.append(allocator, record.absent_times | (@as(u8, @intFromBool(record.acl_override)) << 3) | (@as(u8, @intFromBool(record.finder_override)) << 4));
        try bytes.appendSlice(allocator, observed);
        try bytes.appendSlice(allocator, record.name);
        try bytes.appendSlice(allocator, blob);
    }
    return bytes.toOwnedSlice(allocator);
}

/// Descriptor arrays are owned; names and values borrow the input bytes.
pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !Decoded {
    if (bytes.len > max_bytes) return error.TransportTooLarge;
    var reader = Reader{ .bytes = bytes };
    if (!std.mem.eql(u8, try reader.take(magic.len), magic)) return error.InvalidTransport;
    const count = try reader.readInt();
    if (count > (bytes.len - reader.position) / 31) return error.InvalidTransport;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const records = try arena.allocator().alloc(Record, count);
    for (records, 0..) |*record, index| {
        const name_len = try reader.readInt();
        const meta_len = try reader.readInt();
        const flags = (try reader.take(1))[0];
        if (flags & 0xe0 != 0) return error.InvalidTransport;
        const time_start = reader.position;
        const presence = (try reader.take(1))[0];
        if (presence > 1) return error.InvalidTransport;
        if (presence == 1) _ = try reader.take(12);
        const observed = metadata.decodeTimeOverride(bytes[time_start..reader.position]) catch return error.InvalidTransport;
        const name = try reader.take(name_len);
        const blob = try reader.take(meta_len);
        const meta = metadata.decodeCanonical(arena.allocator(), blob) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.InvalidTransport,
        };
        record.* = .{ .name = name, .meta = meta, .absent_times = flags & 7, .observed_mtime = observed, .acl_override = flags & 8 != 0, .finder_override = flags & 16 != 0 };
        try validateRecord(record.*);
        if (index > 0 and std.mem.order(u8, records[index - 1].name, name) != .lt) return error.InvalidTransport;
    }
    if (reader.position != bytes.len) return error.InvalidTransport;
    return .{ .arena = arena, .records = records };
}

fn validateRecord(record: Record) !void {
    const keeps_mtime = record.meta.times.mtime != null or record.absent_times & 1 != 0;
    if (keeps_mtime != (record.observed_mtime != null)) return error.InvalidTransport;
    directory.validatePath(record.name) catch return error.InvalidTransport;
    if (record.absent_times & ~@as(u8, 7) != 0 or
        (record.absent_times & 1 != 0 and record.meta.times.mtime != null) or
        (record.absent_times & 2 != 0 and record.meta.times.atime != null) or
        (record.absent_times & 4 != 0 and record.meta.times.btime != null)) return error.InvalidTransport;
    if (std.mem.indexOfScalar(u8, record.name, '/') != null or (record.meta.isEmpty() and record.absent_times == 0 and !record.acl_override and !record.finder_override) or
        record.meta.holes.len != 0 or record.meta.hardlink_to != null) return error.InvalidTransport;
}

fn appendInt(allocator: std.mem.Allocator, bytes: *std.ArrayListUnmanaged(u8), value: u32) !void {
    var raw: [4]u8 = undefined;
    std.mem.writeInt(u32, &raw, value, .little);
    try bytes.appendSlice(allocator, &raw);
}

const Reader = struct {
    bytes: []const u8,
    position: usize = 0,

    fn take(self: *Reader, count: usize) ![]const u8 {
        if (count > self.bytes.len - self.position) return error.InvalidTransport;
        const result = self.bytes[self.position..][0..count];
        self.position += count;
        return result;
    }

    fn readInt(self: *Reader) !u32 {
        return std.mem.readInt(u32, (try self.take(4))[0..4], .little);
    }
};

pub fn find(records: []const Record, name: []const u8) ?Record {
    var low: usize = 0;
    var high = records.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        switch (std.mem.order(u8, records[middle].name, name)) {
            .lt => low = middle + 1,
            .gt => high = middle,
            .eq => return records[middle],
        }
    }
    return null;
}

const fixture = [_]Record{
    .{ .name = "a", .meta = .{
        .xattrs = &.{.{ .class = .logical, .name = "comment", .value = "kept" }},
        .times = .{ .btime = .{ .sec = -1, .nsec = 999_999_999 } },
    } },
    .{ .name = "é", .meta = .{ .native_acl = .{ .origin = .windows, .bytes = "DACL" } } },
};

test "parent transport round-trips canonical records and exact bytes" {
    const bytes = try encode(testing.allocator, &fixture);
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings(magic, bytes[0..magic.len]);
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, bytes[magic.len..][0..4], .little));
    var decoded = try decode(testing.allocator, bytes);
    defer decoded.deinit();
    try testing.expectEqual(fixture.len, decoded.records.len);
    for (fixture, decoded.records) |expected, actual| {
        try testing.expectEqualStrings(expected.name, actual.name);
        try testing.expectEqualSlices(u8, &metadata.canonicalHash(expected.meta), &metadata.canonicalHash(actual.meta));
    }
    const again = try encode(testing.allocator, decoded.records);
    defer testing.allocator.free(again);
    try testing.expectEqualSlices(u8, bytes, again);
    for ([_][]const u8{ "a", "é", "", "b", "z", "éx" }) |name| {
        const present = std.mem.eql(u8, name, "a") or std.mem.eql(u8, name, "é");
        try testing.expectEqual(present, find(decoded.records, name) != null);
    }
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            const encoded = try encode(allocator, &fixture);
            defer allocator.free(encoded);
        }
    }.run, .{});
}

test "parent transport decoder rejects forged order names and version" {
    const records = [_]Record{ fixture[0], .{ .name = "b", .meta = fixture[1].meta } };
    const bytes = try encode(testing.allocator, &records);
    defer testing.allocator.free(bytes);
    var decoded = try decode(testing.allocator, bytes);
    defer decoded.deinit();
    const first = @intFromPtr(decoded.records[0].name.ptr) - @intFromPtr(bytes.ptr);
    const second = @intFromPtr(decoded.records[1].name.ptr) - @intFromPtr(bytes.ptr);
    for ([_]u8{ 'a', '.', '/', '\\', 0, 0xff }) |bad| {
        bytes[second] = bad;
        try testing.expectError(error.InvalidTransport, decode(testing.allocator, bytes));
    }
    bytes[first] = 'b';
    bytes[second] = 'a';
    try testing.expectError(error.InvalidTransport, decode(testing.allocator, bytes));
    bytes[magic.len - 1] = 2;
    try testing.expectError(error.InvalidTransport, decode(testing.allocator, bytes));
}

test "parent transport can preserve absent timestamps independently of native values" {
    const records = [_]Record{.{ .name = "a", .meta = .{}, .absent_times = 5, .observed_mtime = .{ .sec = 42 } }};
    const bytes = try encode(testing.allocator, &records);
    defer testing.allocator.free(bytes);
    var decoded = try decode(testing.allocator, bytes);
    defer decoded.deinit();
    try testing.expectEqual(@as(u8, 5), decoded.records[0].absent_times);
    try testing.expect(decoded.records[0].meta.isEmpty());
    for ([_]u8{ 8, 128, 255 }) |flags| {
        try testing.expectError(error.InvalidTransport, encode(testing.allocator, &.{.{ .name = "a", .meta = .{}, .absent_times = flags }}));
    }
    try testing.expectError(error.InvalidTransport, encode(testing.allocator, &.{.{ .name = "a", .meta = fixture[0].meta, .absent_times = 4 }}));
}

test "parent transport rejects truncation trailing bytes and impossible counts without leaks" {
    const bytes = try encode(testing.allocator, &fixture);
    defer testing.allocator.free(bytes);
    for (0..bytes.len) |length| {
        if (decode(testing.allocator, bytes[0..length])) |value| {
            var unexpected = value;
            unexpected.deinit();
            return error.TruncationAccepted;
        } else |_| {}
    }
    const trailing = try std.mem.concat(testing.allocator, u8, &.{ bytes, "!" });
    defer testing.allocator.free(trailing);
    try testing.expectError(error.InvalidTransport, decode(testing.allocator, trailing));
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(allocator: std.mem.Allocator, input: []const u8) !void {
            var decoded = try decode(allocator, input);
            defer decoded.deinit();
        }
    }.run, .{bytes});
    var huge = magic.* ++ [_]u8{0xff} ** 4;
    try testing.expectError(error.InvalidTransport, decode(testing.failing_allocator, &huge));
}

test "parent transport classifies names ordering and symlink metadata" {
    const invalid = [_][]const u8{ "", ".", "..", "a/b", "a\\b", "a\x00b", "bad\xff", "C:drive" };
    for (invalid) |name| {
        try testing.expectError(error.InvalidTransport, encode(testing.allocator, &.{.{ .name = name, .meta = fixture[0].meta }}));
    }
    try testing.expectError(error.InvalidTransport, encode(testing.allocator, &.{ fixture[0], fixture[0] }));
    try testing.expectError(error.InvalidTransport, encode(testing.allocator, &.{ fixture[1], fixture[0] }));
    const bad_meta = [_]metadata.Metadata{
        .{}, .{ .holes = &.{.{ .offset = 0, .length = 1 }} }, .{ .hardlink_to = "a" },
    };
    for (bad_meta) |meta| try testing.expectError(error.InvalidTransport, encode(testing.allocator, &.{.{ .name = "a", .meta = meta }}));
    const value = try testing.allocator.alloc(u8, max_bytes);
    defer testing.allocator.free(value);
    @memset(value, 0);
    try testing.expectError(error.TransportTooLarge, encode(testing.allocator, &.{.{ .name = "a", .meta = .{
        .xattrs = &.{.{ .class = .logical, .name = "comment", .value = value }},
    } }}));
}
