const std = @import("std");
const reference = @import("reference");
const acl = reference.linux_acl;
pub fn run(allocator: std.mem.Allocator, mode: u32, input: []const u8) ![]const u8 {
    if (mode == 53) {
        const meta = try reference.metadata.decodeCanonical(allocator, input);
        return acl.encodePortableLinux(allocator, meta.aces);
    }
    if (mode == 48) {
        const aces = try acl.portableLinux(allocator, input);
        const meta = try reference.metadata.canonicalize(allocator, .{ .aces = aces }, .{});
        return reference.metadata.encodeCanonical(allocator, meta);
    }
    if (mode == 49) return acl.encodeLinux(allocator, try acl.decodeLinux(input));
    if (input.len < 4) return error.BadFixture;
    const count = std.mem.readInt(u32, input[0..4], .little);
    if (count > input.len - 4) return error.BadFixture;
    return acl.encodeLinux(allocator, .{ .access = input[4..][0..count], .default = input[4 + count ..] });
}
