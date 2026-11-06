const std = @import("std");
const metadata = @import("metadata");

// Independent reference fixtures for the forthcoming Rust canonical codec.
pub fn make(allocator: std.mem.Allocator, selector: u8) !metadata.Metadata {
    if (selector > 31) return error.BadMetadata;
    if (selector == 0) return .{};
    const xattrs = try allocator.dupe(metadata.Xattr, &.{
        .{ .class = .logical, .name = "app", .value = "v\x00\xff" },
        .{ .class = .raw, .name = "system.meta", .value = "\x01raw" },
    });
    const aces = try allocator.dupe(metadata.Ace, &.{
        .{ .tag = .owner, .read = true, .write = true },
        .{ .tag = .named_user, .read = true, .execute = true, .name = "alice" },
    });
    const holes = try allocator.dupe(metadata.Hole, &.{ .{ .offset = 0, .length = 16 }, .{ .offset = 32, .length = 32 } });
    var info: [32]u8 = undefined;
    for (&info, 0..) |*byte, index| byte.* = @intCast(index);
    var value: metadata.Metadata = .{
        .xattrs = xattrs,
        .aces = aces,
        .native_acl = .{ .origin = if (selector == 2) .macos else if (selector == 3) .windows else .linux, .bytes = "\x00\xffacl" },
        .times = .{ .mtime = .{ .sec = -1, .nsec = 7 }, .atime = .{}, .btime = .{ .sec = std.math.maxInt(i64), .nsec = 999_999_999 } },
        .finder_flags = 0x1234,
        .finder_info = info,
        .holes = holes,
        .hardlink_to = "dir/base",
    };
    switch (selector) {
        1, 2, 3 => {},
        4 => xattrs[1] = xattrs[0],
        5 => {
            xattrs[0].class = .raw;
            xattrs[1].class = .logical;
        },
        6 => xattrs[0].name = "",
        7 => xattrs[0].name = "user.difz.btime",
        8 => xattrs[1].name = "binary\xff",
        9 => xattrs[1].name = "bad/name",
        10 => aces[1] = aces[0],
        11 => {
            aces[0].tag = .named_user;
            aces[0].name = "alice";
            aces[1].tag = .owner;
            aces[1].name = "";
        },
        12 => aces[1].name = "",
        13 => value.native_acl.?.bytes = "",
        14 => value.times.mtime.?.nsec = 1_000_000_000,
        15 => holes[0].length = 0,
        16 => {
            holes[1].offset = std.math.maxInt(u64);
            holes[1].length = 1;
        },
        17 => {
            holes[1].offset = 16;
            holes[1].length = 16;
        },
        18 => holes[1].offset = 8,
        19 => {
            holes[0].offset = 32;
            holes[1].offset = 0;
        },
        20 => value.hardlink_to = "../escape",
        21 => value.times = .{},
        22 => value.finder_info = [_]u8{0} ** 32,
        23 => value.hardlink_to = null,
        24 => value.holes = &.{},
        25 => value.native_acl.?.origin = .windows,
        26 => value.times.mtime = .{ .sec = std.math.minInt(i64), .nsec = 999_999_999 },
        27 => value.xattrs = &.{},
        28 => value.aces = &.{},
        29 => value.native_acl = null,
        30 => {
            value.finder_info = null;
            value.finder_flags = 0;
        },
        31 => {
            holes[1].offset = std.math.maxInt(u64) - 7;
            holes[1].length = 7;
        },
        else => unreachable,
    }
    return value;
}

// Raw normalization inputs are separate from strict wire-decoder fixtures:
// normalization validates families in order; decoding parses times first.
pub fn forNormalization(allocator: std.mem.Allocator, selector: u8) !metadata.Metadata {
    if (selector <= 31) return make(allocator, selector);
    if (selector > 34) return error.BadMetadata;
    var value = try make(allocator, 1);
    const xattrs = try allocator.dupe(metadata.Xattr, value.xattrs);
    const aces = try allocator.dupe(metadata.Ace, value.aces);
    const holes = try allocator.dupe(metadata.Hole, value.holes);
    value.xattrs = xattrs;
    value.aces = aces;
    value.holes = holes;
    switch (selector) {
        32 => {
            xattrs[1] = xattrs[0];
            aces[1].name = "";
            value.native_acl.?.bytes = "";
            value.times.mtime.?.nsec = 1_000_000_000;
            holes[0].length = 0;
            value.hardlink_to = "../escape";
        },
        33 => {
            xattrs[1] = xattrs[0];
            xattrs[0].name = "";
            aces[1] = aces[0];
        },
        34 => {
            value.native_acl.?.bytes = "";
            value.times.mtime.?.nsec = 1_000_000_000;
            holes[0].length = 0;
        },
        else => unreachable,
    }
    return value;
}
