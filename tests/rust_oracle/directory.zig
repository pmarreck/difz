const std = @import("std");
const directory = @import("reference").directory;

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
        else => return error.BadMetadata,
    }
    return &.{};
}
