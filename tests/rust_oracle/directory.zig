const std = @import("std");
const directory = @import("reference").directory;
const metadata = @import("reference").metadata;

pub fn run(allocator: std.mem.Allocator, mode: u32, input: []const u8) ![]const u8 {
    switch (mode) {
        30 => try directory.validatePath(input),
        31 => {
            if (input.len < 4) return error.BadMetadata;
            const length = std.mem.readInt(u32, input[0..4], .little);
            if (length > input.len - 4) return error.BadMetadata;
            const path = input[4..][0..length];
            try directory.validatePath(path);
            var entries: std.ArrayListUnmanaged(directory.Entry) = .empty;
            // Use the public snapshot boundary, supplying every required parent.
            for (path, 0..) |byte, index| {
                if (byte == '/') try entries.append(allocator, .{ .path = path[0..index], .kind = .directory, .mode = 0o755 });
            }
            try entries.append(allocator, .{ .path = path, .kind = .symlink, .mode = 0o777, .data = input[4 + length ..] });
            try directory.validateSnapshot(entries.items);
        },
        32 => {
            if (input.len != 2) return error.BadMetadata;
            const entry: directory.Entry = .{ .path = "x", .kind = .file, .mode = std.mem.readInt(u16, input[0..2], .little) };
            try directory.validateSnapshot(&.{entry});
            return allocator.dupe(u8, input);
        },
        33 => {
            if (input.len != 1 or input[0] > 4) return error.BadMetadata;
            if (input[0] == 0) {
                const digest = try directory.treeHash(&.{});
                return allocator.dupe(u8, &digest);
            }
            var entry: directory.Entry = switch (input[0]) {
                1 => .{ .path = "dir", .kind = .directory, .mode = 0o750 },
                2, 4 => .{ .path = "file", .kind = .file, .mode = 0o644, .data = "\x00\xff" },
                3 => .{ .path = "link", .kind = .symlink, .mode = 0o777, .data = "file" },
                else => unreachable,
            };
            const attrs = [_]metadata.Xattr{.{ .class = .logical, .name = "x", .value = "\x00\xff" }};
            const root: metadata.Metadata = if (input[0] == 4) .{ .xattrs = &attrs } else .{};
            if (input[0] == 4) entry.meta.times.mtime = .{ .sec = -1, .nsec = 7 };
            const digest = try directory.treeHashWithRoot(&.{entry}, root);
            return allocator.dupe(u8, &digest);
        },
        else => return error.BadMetadata,
    }
    return &.{};
}
