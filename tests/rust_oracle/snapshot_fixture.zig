const std = @import("std");
const metadata = @import("reference").metadata;
const directory = @import("reference").directory;
pub const Snapshot = struct { entries: []directory.Entry, root: metadata.Metadata = .{} };

fn fileMeta(allocator: std.mem.Allocator, link: ?[]const u8) !metadata.Metadata {
    return .{
        .xattrs = try allocator.dupe(metadata.Xattr, &.{.{ .class = .logical, .name = "x", .value = "v\x00\xff" }}),
        .times = .{ .mtime = .{ .sec = -1, .nsec = 7 } },
        .holes = try allocator.dupe(metadata.Hole, &.{.{ .offset = 0, .length = 2 }}),
        .hardlink_to = link,
    };
}
fn rootMeta(allocator: std.mem.Allocator) !metadata.Metadata {
    return .{ .xattrs = try allocator.dupe(metadata.Xattr, &.{.{ .class = .logical, .name = "root", .value = "\x00\xff" }}) };
}
pub fn make(allocator: std.mem.Allocator, selector: u8) !Snapshot {
    if (selector > 41) return error.BadMetadata;
    if (selector == 0) return .{ .entries = &.{} };
    if (selector == 26 or selector == 27) {
        const count: usize = if (selector == 26) 1_000_001 else 1_000_000;
        const entries = try allocator.alloc(directory.Entry, count);
        @memset(entries, .{ .path = "x", .kind = .file, .mode = 0o644 });
        return .{ .entries = entries };
    }
    if (selector >= 29 and selector <= 32) {
        const pair = try allocator.alloc(directory.Entry, 2);
        const mode: u16 = if (selector <= 30) 0o750 else 0o777;
        const data: []const u8 = if (selector <= 30) "" else "file";
        pair[0] = .{ .path = "a", .kind = if (selector == 29) .directory else if (selector == 32) .symlink else .file, .mode = mode, .data = data };
        pair[1] = .{ .path = "b", .kind = if (selector == 30) .directory else if (selector == 31) .symlink else .file, .mode = mode, .data = data, .meta = .{ .hardlink_to = "a" } };
        return .{ .entries = pair };
    }
    const entries = try allocator.alloc(directory.Entry, 5);
    entries[0] = .{ .path = "a", .kind = .directory, .mode = 0o750 };
    entries[1] = .{ .path = "a/base", .kind = .file, .mode = 0o644, .data = "\x00\x00X\x00", .meta = try fileMeta(allocator, null) };
    entries[2] = .{ .path = "a/link", .kind = .symlink, .mode = 0o777, .data = "base" };
    entries[3] = .{ .path = "a/z", .kind = .file, .mode = 0o644, .data = "\x00\x00X\x00", .meta = try fileMeta(allocator, "a/base") };
    var value: Snapshot = .{ .entries = entries[0..4] };
    switch (selector) {
        1 => {},
        2 => value.root = try rootMeta(allocator),
        3 => {
            value.entries = &.{};
            value.root = try rootMeta(allocator);
        },
        4 => entries[0].path = "../escape",
        5 => std.mem.swap(directory.Entry, &entries[1], &entries[2]),
        6, 22, 40, 41 => entries[2].path = "a/base",
        7 => entries[0].path = "0",
        8 => entries[0].kind = .file,
        9 => entries[2].data = "",
        10 => entries[2].data = "../../escape",
        11, 12 => entries[1].meta.holes = try allocator.dupe(metadata.Hole, &.{.{ .offset = if (selector == 11) 2 else 4, .length = 1 }}),
        13 => entries[0].meta.holes = try allocator.dupe(metadata.Hole, &.{.{ .offset = 0, .length = 1 }}),
        14, 23 => entries[3].meta.hardlink_to = "a/missing",
        15 => entries[3].meta.hardlink_to = "a/z",
        16 => entries[1].meta.hardlink_to = "a/z",
        17 => entries[3].mode = 0o600,
        18 => entries[3].data = "\x00\x00Y\x00",
        19 => entries[3].meta.times.mtime.?.sec = 1,
        20 => {},
        21, 28 => value.root.hardlink_to = "a/base",
        24 => entries[3].meta.hardlink_to = null,
        25 => {
            entries[4] = .{ .path = "a/zz", .kind = .file, .mode = 0o644, .data = "\x00\x00X\x00", .meta = try fileMeta(allocator, "a/z") };
            value.entries = entries;
        },
        33 => {
            const attrs = try allocator.dupe(metadata.Xattr, entries[3].meta.xattrs);
            attrs[0].value = "different";
            entries[3].meta.xattrs = attrs;
        },
        34 => entries[3].meta.aces = try allocator.dupe(metadata.Ace, &.{.{ .tag = .owner, .read = true }}),
        35 => entries[3].meta.native_acl = .{ .origin = .linux, .bytes = "\x00\xff" },
        36 => entries[3].meta.times.atime = .{},
        37 => entries[3].meta.finder_flags = 1,
        38 => entries[3].meta.finder_info = [_]u8{0} ** 32,
        39 => entries[3].meta.holes = try allocator.dupe(metadata.Hole, &.{.{ .offset = 0, .length = 1 }}),
        else => unreachable,
    }
    if (selector == 20 or selector == 23 or selector == 28) value.root.holes = try allocator.dupe(metadata.Hole, &.{.{ .offset = 0, .length = 1 }});
    if (selector == 22) entries[0].meta.holes = try allocator.dupe(metadata.Hole, &.{.{ .offset = 0, .length = 1 }});
    if (selector == 40) entries[3].path = "../escape";
    if (selector == 41) entries[2].data = "/outside";
    return value;
}
