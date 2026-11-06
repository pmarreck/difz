const std = @import("std");
const reference = @import("reference");
const patch = reference.tree_patch;
const directory = reference.directory;

fn rich(allocator: std.mem.Allocator, mask: u8) ![]const u8 {
    const metadata = reference.metadata;
    const attrs = [_]metadata.Xattr{.{ .class = .logical, .name = "x", .value = "v\x00\xff" }};
    const aces = [_]metadata.Ace{.{ .tag = .owner, .read = true, .execute = true }};
    const holes = [_]metadata.Hole{.{ .offset = 0, .length = 2 }};
    const meta: metadata.Metadata = .{
        .xattrs = &attrs, .aces = &aces, .native_acl = .{ .origin = .linux, .bytes = "acl\x00\xff" },
        .times = .{ .mtime = .{ .sec = -1, .nsec = 7 } }, .finder_flags = 1,
        .finder_info = [_]u8{0} ** 32, .holes = &holes,
    };
    var link_meta = meta;
    link_meta.hardlink_to = "app/base";
    const source = [_]directory.Entry{
        .{ .path = "app", .kind = .directory, .mode = 0o750 },
        .{ .path = "app/base", .kind = .file, .mode = 0o644, .data = "\x00\x00OLD\x00", .meta = meta },
        .{ .path = "app/link", .kind = .symlink, .mode = 0o777, .data = "base" },
        .{ .path = "app/same", .kind = .file, .mode = 0o644, .data = "same" },
    };
    const target = [_]directory.Entry{
        .{ .path = "app", .kind = .directory, .mode = 0o750 },
        .{ .path = "app/base", .kind = .file, .mode = 0o644, .data = "\x00\x00NEW\x00", .meta = meta },
        .{ .path = "app/link", .kind = .symlink, .mode = 0o777, .data = "base" },
        .{ .path = "app/new", .kind = .file, .mode = 0o644, .data = "\x00\xffraw" },
        .{ .path = "app/same", .kind = .file, .mode = 0o644, .data = "same" },
        .{ .path = "app/z", .kind = .file, .mode = 0o644, .data = "\x00\x00NEW\x00", .meta = link_meta },
    };
    const root_attrs = [_]metadata.Xattr{.{ .class = .logical, .name = "root", .value = "\x00\xff" }};
    return patch.createPatch(allocator, &source, &target, .{
        .omit = try metadata.Omit.fromBits(mask), .target_root = .{ .xattrs = &root_attrs },
        .rules = &.{.{ .action = .include, .pattern = "**" }, .{ .action = .exclude, .pattern = "*.tmp" }},
    });
}

pub fn run(allocator: std.mem.Allocator, mode: u32, input: []const u8) ![]const u8 {
    if (mode == 40) {
        if (input.len == 0 or input.len > 2) return error.BadFixture;
        if (input[0] == 4) return rich(allocator, if (input.len == 2) input[1] else 0);
        if (input[0] == 5 and input.len == 1) {
            const source = [_]directory.Entry{
                .{ .path = "x", .kind = .directory, .mode = 0o700 },
                .{ .path = "y", .kind = .file, .mode = 0o640, .data = "old" },
            };
            const target = [_]directory.Entry{
                .{ .path = "x", .kind = .file, .mode = 0o644, .data = "new\x00\xff" },
                .{ .path = "y", .kind = .symlink, .mode = 0o777, .data = "x" },
            };
            return patch.createPatch(allocator, &source, &target, .{ .source_root = .{ .times = .{ .mtime = .{ .sec = -1, .nsec = 7 } } } });
        }
        if (input.len != 1 or input[0] > 3) return error.BadFixture;
        const entries = [_]directory.Entry{.{ .path = "x", .kind = .file, .mode = 0o640, .data = "\x00\xffbody" }};
        const root_attrs = [_]reference.metadata.Xattr{.{ .class = .logical, .name = "root", .value = "\x00\xff" }};
        return patch.createPatch(allocator, &.{}, if (input[0] == 2) &entries else &.{}, .{
            .omit = try reference.metadata.Omit.fromBits(if (input[0] == 0) 63 else 0),
            .target_root = if (input[0] == 1) .{ .xattrs = &root_attrs } else .{},
            .rules = if (input[0] == 3) &.{.{ .action = .include, .pattern = "**" }} else &.{},
        });
    }
    var limits: patch.Limits = .{};
    var bytes = input;
    if (mode == 42) {
        if (input.len < 24) return error.BadFixture;
        limits.max_patch_bytes = @intCast(std.mem.readInt(u64, input[0..8], .little));
        limits.max_entries = @intCast(std.mem.readInt(u64, input[8..16], .little));
        limits.max_rules = @intCast(std.mem.readInt(u64, input[16..24], .little));
        bytes = input[24..];
    }
    if (mode == 44) {
        if (input.len < 56) return error.BadFixture;
        limits.max_patch_bytes = @intCast(std.mem.readInt(u64, input[0..8], .little));
        limits.max_entries = @intCast(std.mem.readInt(u64, input[8..16], .little));
        limits.max_rules = @intCast(std.mem.readInt(u64, input[16..24], .little));
        limits.max_path_bytes = @intCast(std.mem.readInt(u64, input[24..32], .little));
        limits.max_pattern_bytes = @intCast(std.mem.readInt(u64, input[32..40], .little));
        limits.max_symlink_bytes = @intCast(std.mem.readInt(u64, input[40..48], .little));
        limits.max_payload_bytes = @intCast(std.mem.readInt(u64, input[48..56], .little));
        bytes = input[56..];
    }
    var options = try patch.readOptions(allocator, bytes, limits);
    defer options.deinit();
    return &.{};
}
