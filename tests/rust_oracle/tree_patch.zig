const std = @import("std");
const reference = @import("reference");
const patch = reference.tree_patch;
const directory = reference.directory;

pub fn run(allocator: std.mem.Allocator, mode: u32, input: []const u8) ![]const u8 {
    if (mode == 40) {
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
    var options = try patch.readOptions(allocator, bytes, limits);
    defer options.deinit();
    return &.{};
}
