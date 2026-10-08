const std = @import("std");
const builtin = @import("builtin");
const metadata = @import("metadata.zig");

pub const Range = extern struct { offset: i64, length: i64 };
pub fn holesFromAllocated(allocator: std.mem.Allocator, size: u64, ranges: []const Range) ![]const metadata.Hole {
    var holes: std.ArrayListUnmanaged(metadata.Hole) = .empty;
    errdefer holes.deinit(allocator);
    var cursor: u64 = 0;
    for (ranges) |range| {
        if (range.offset < 0 or range.length <= 0) return error.InvalidExtents;
        const offset: u64 = @intCast(range.offset);
        const end = std.math.add(u64, offset, @intCast(range.length)) catch return error.InvalidExtents;
        if (offset < cursor or offset >= size) return error.InvalidExtents;
        if (offset > cursor) try holes.append(allocator, .{ .offset = cursor, .length = offset - cursor });
        cursor = @min(size, end);
    }
    if (cursor < size) try holes.append(allocator, .{ .offset = cursor, .length = size - cursor });
    return holes.toOwnedSlice(allocator);
}

pub fn capture(allocator: std.mem.Allocator, io: std.Io, root: std.Io.Dir, path: []const u8, size: u64) ![]const metadata.Hole {
    if (size == 0) return &.{};
    if (size > std.math.maxInt(i64)) return error.InvalidExtents;
    var file = try root.openFile(io, path, .{ .allow_directory = false, .follow_symlinks = false, .resolve_beneath = true });
    defer file.close(io);
    if (comptime builtin.os.tag == .windows) return captureWindows(allocator, file.handle, size);
    var holes: std.ArrayListUnmanaged(metadata.Hole) = .empty;
    defer holes.deinit(allocator);
    const seek_hole: c_int = if (builtin.os.tag == .macos) 3 else 4;
    const seek_data: c_int = if (builtin.os.tag == .macos) 4 else 3;
    var cursor: u64 = 0;
    while (cursor < size) {
        const hole = std.c.lseek(file.handle, @intCast(cursor), seek_hole);
        if (hole < 0) switch (std.c.errno(hole)) {
            .NXIO => break,
            .INVAL, .OPNOTSUPP => return &.{},
            else => return error.ExtentReadFailed,
        };
        if (hole < cursor) return error.InvalidExtents;
        if (hole >= size) break;
        const next = std.c.lseek(file.handle, hole, seek_data);
        const data: u64 = if (next >= 0) @min(size, @as(u64, @intCast(next))) else switch (std.c.errno(next)) {
            .NXIO => size,
            else => return error.ExtentReadFailed,
        };
        if (data <= hole) return error.InvalidExtents;
        try holes.append(allocator, .{ .offset = @intCast(hole), .length = data - @as(u64, @intCast(hole)) });
        cursor = data;
    }
    return holes.toOwnedSlice(allocator);
}

/// Called only after the logical bytes and hole bounds have been validated.
pub fn punch(io: std.Io, root: std.Io.Dir, path: []const u8, holes: []const metadata.Hole) !void {
    if (holes.len == 0) return;
    var file = try root.openFile(io, path, .{ .mode = .read_write, .allow_directory = false, .follow_symlinks = false, .resolve_beneath = true });
    defer file.close(io);
    if (comptime builtin.os.tag == .windows) {
        var returned: u32 = 0;
        if (kernel.DeviceIoControl(file.handle, 0x900c4, null, 0, null, 0, &returned, null) == .FALSE) return error.HolePunchFailed;
        for (holes) |hole| {
            var range = [2]i64{ @intCast(hole.offset), @intCast(hole.offset + hole.length) };
            if (kernel.DeviceIoControl(file.handle, 0x980c8, &range, @sizeOf(@TypeOf(range)), null, 0, &returned, null) == .FALSE) return error.HolePunchFailed;
        }
    } else if (comptime builtin.os.tag == .linux) {
        for (holes) |hole| if (std.c.fallocate(file.handle, 3, @intCast(hole.offset), @intCast(hole.length)) != 0) return error.HolePunchFailed;
    } else {
        const Punch = extern struct { flags: u32 = 0, reserved: u32 = 0, offset: i64, length: i64 };
        for (holes) |hole| {
            var range: Punch = .{ .offset = @intCast(hole.offset), .length = @intCast(hole.length) };
            if (std.c.fcntl(file.handle, 99, &range) != 0) return error.HolePunchFailed;
        }
    }
}

const windows = std.os.windows;
const kernel = struct {
    extern "kernel32" fn DeviceIoControl(windows.HANDLE, u32, ?*const anyopaque, u32, ?*anyopaque, u32, *u32, ?*anyopaque) callconv(.winapi) windows.BOOL;
};

fn captureWindows(allocator: std.mem.Allocator, handle: windows.HANDLE, size: u64) ![]const metadata.Hole {
    var query: WindowsQuery = .{ .handle = handle };
    return captureRanges(allocator, size, &query);
}

const Page = struct { count: usize, more: bool };
const WindowsQuery = struct {
    handle: windows.HANDLE,
    fn next(self: *@This(), query: Range, output: []Range) !Page {
        var returned: u32 = 0;
        const ok = kernel.DeviceIoControl(self.handle, 0x940cf, &query, @sizeOf(Range), output.ptr, @intCast(output.len * @sizeOf(Range)), &returned, null) != .FALSE;
        if (!ok) switch (windows.GetLastError()) {
            .MORE_DATA => {},
            .INVALID_FUNCTION, .NOT_SUPPORTED => return error.Unsupported,
            else => return error.ExtentReadFailed,
        };
        if (returned > output.len * @sizeOf(Range) or returned % @sizeOf(Range) != 0) return error.InvalidExtents;
        return .{ .count = returned / @sizeOf(Range), .more = !ok };
    }
};

fn captureRanges(allocator: std.mem.Allocator, size: u64, query_port: anytype) ![]const metadata.Hole {
    var ranges: std.ArrayListUnmanaged(Range) = .empty;
    defer ranges.deinit(allocator);
    const output = try allocator.alloc(Range, 128);
    defer allocator.free(output);
    var cursor: u64 = 0;
    while (cursor < size) {
        const query: Range = .{ .offset = @intCast(cursor), .length = @intCast(size - cursor) };
        const page = query_port.next(query, output) catch |err| {
            if (err != error.Unsupported) return err;
            if (cursor != 0) return error.ExtentReadFailed;
            return &.{};
        };
        if (page.count > output.len) return error.InvalidExtents;
        try ranges.appendSlice(allocator, output[0..page.count]);
        if (!page.more) break;
        if (page.count == 0) return error.InvalidExtents;
        const last = output[page.count - 1];
        if (last.offset < 0 or last.length <= 0) return error.InvalidExtents;
        const next = std.math.add(u64, @intCast(last.offset), @intCast(last.length)) catch return error.InvalidExtents;
        if (next <= cursor or next > size) return error.InvalidExtents;
        cursor = next;
    }
    return holesFromAllocated(allocator, size, ranges.items);
}

test "allocated data ranges complement holes over every eight-byte layout" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    for (0..256) |mask| {
        var ranges: std.ArrayListUnmanaged(Range) = .empty;
        for (0..8) |byte| {
            if (mask & (@as(usize, 1) << @intCast(byte)) != 0) try ranges.append(alloc, .{ .offset = @intCast(byte), .length = 1 });
        }
        const holes = try holesFromAllocated(alloc, 8, ranges.items);
        var classified: [8]bool = @splat(false);
        for (holes, 0..) |hole, i| {
            if (i > 0) try std.testing.expect(holes[i - 1].offset + holes[i - 1].length < hole.offset);
            for (hole.offset..hole.offset + hole.length) |byte| classified[byte] = true;
        }
        for (classified, 0..) |hole, byte| try std.testing.expectEqual(mask & (@as(usize, 1) << @intCast(byte)) == 0, hole);
    }
    const clipped = try holesFromAllocated(alloc, 10, &.{.{ .offset = 2, .length = 20 }});
    try std.testing.expectEqualDeep(&[_]metadata.Hole{.{ .offset = 0, .length = 2 }}, clipped);
    for ([_][]const Range{
        &.{.{ .offset = -1, .length = 1 }},                                 &.{.{ .offset = 0, .length = 0 }},
        &.{.{ .offset = 0, .length = -1 }},                                 &.{ .{ .offset = 2, .length = 1 }, .{ .offset = 1, .length = 1 } },
        &.{ .{ .offset = 0, .length = 3 }, .{ .offset = 2, .length = 1 } },
    }) |invalid| try std.testing.expectError(error.InvalidExtents, holesFromAllocated(alloc, 8, invalid));
}

test "allocated range pagination records exact requests and rejects nonprogress" {
    const Fake = struct {
        calls: usize = 0,
        requests: [2]Range = undefined,
        bad: bool = false,
        fn next(self: *@This(), query: Range, output: []Range) !Page {
            if (self.calls >= self.requests.len) return error.TooManyQueries;
            self.requests[self.calls] = query;
            self.calls += 1;
            if (self.bad) return .{ .count = 0, .more = true };
            if (self.calls == 1) {
                output[0] = .{ .offset = 2, .length = 2 };
                output[1] = .{ .offset = 6, .length = 1 };
                return .{ .count = 2, .more = true };
            }
            output[0] = .{ .offset = 10, .length = 2 };
            return .{ .count = 1, .more = false };
        }
    };
    var fake: Fake = .{};
    const holes = try captureRanges(std.testing.allocator, 16, &fake);
    defer std.testing.allocator.free(holes);
    try std.testing.expectEqualDeep(&[_]metadata.Hole{
        .{ .offset = 0, .length = 2 }, .{ .offset = 4, .length = 2 },
        .{ .offset = 7, .length = 3 }, .{ .offset = 12, .length = 4 },
    }, holes);
    try std.testing.expectEqual(@as(usize, 2), fake.calls);
    try std.testing.expectEqualDeep([_]Range{ .{ .offset = 0, .length = 16 }, .{ .offset = 7, .length = 9 } }, fake.requests);
    var bad: Fake = .{ .bad = true };
    try std.testing.expectError(error.InvalidExtents, captureRanges(std.testing.allocator, 16, &bad));
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            var query: Fake = .{};
            const result = try captureRanges(allocator, 16, &query);
            defer allocator.free(result);
        }
    }.run, .{});
}
