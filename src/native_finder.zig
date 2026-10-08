const std = @import("std");
const builtin = @import("builtin");
const metadata = @import("metadata.zig");
const xattr = @import("xattr_stream");

// UF_NODUMP and UF_HIDDEN do not impede staging, traversal, or publication.
const staging_flags: u32 = 0x8001;
fn flagsForStaging(current: u32, requested: u32) u32 {
    return (current & ~staging_flags) | (requested & staging_flags);
}

pub fn capture(allocator: std.mem.Allocator, path: []const u8) !metadata.Metadata {
    if (comptime builtin.os.tag != .macos) return .{};
    const path_z = try allocator.dupeZ(u8, path);
    var stat: std.c.Stat = undefined;
    if (std.c.fstatat(std.posix.AT.FDCWD, path_z, &stat, std.posix.AT.SYMLINK_NOFOLLOW) != 0) return error.FinderReadFailed;
    const bytes = xattr.get(allocator, path, "com.apple.FinderInfo", .{ .follow_symlinks = false, .raw_names = true }) catch |err| switch (err) {
        error.Missing, error.Unsupported => return .{ .finder_flags = stat.flags },
        else => return err,
    };
    if (bytes.len != 32) return error.InvalidFinderInfo;
    return .{ .finder_flags = stat.flags, .finder_info = bytes[0..32].* };
}

pub fn setInfo(path: []const u8, info: ?[32]u8) !void {
    if (comptime builtin.os.tag != .macos) {
        if (info != null) return error.Unsupported;
        return;
    }
    const opts: xattr.Options = .{ .follow_symlinks = false, .raw_names = true };
    if (info) |bytes| return xattr.set(path, "com.apple.FinderInfo", &bytes, opts);
    xattr.remove(path, "com.apple.FinderInfo", opts) catch |err| switch (err) {
        error.Missing, error.Unsupported => {},
        else => return err,
    };
}

pub fn setFlags(allocator: std.mem.Allocator, path: []const u8, requested: u32) !void {
    if (comptime builtin.os.tag != .macos) {
        if (requested != 0) return error.Unsupported;
        return;
    }
    const libc = struct {
        extern "c" fn lchflags([*:0]const u8, u32) c_int;
    };
    const path_z = try allocator.dupeZ(u8, path);
    var stat: std.c.Stat = undefined;
    if (std.c.fstatat(std.posix.AT.FDCWD, path_z, &stat, std.posix.AT.SYMLINK_NOFOLLOW) != 0) return error.FinderReadFailed;
    if (libc.lchflags(path_z, flagsForStaging(stat.flags, requested)) != 0) return error.FinderRestoreFailed;
}

test "BSD staging flags classify every bit and preserve OS-managed flags" {
    var accepted: u32 = 0;
    for (0..32) |bit| {
        const flag = @as(u32, 1) << @intCast(bit);
        if (flagsForStaging(0, flag) != 0) accepted |= flag;
    }
    try std.testing.expectEqual(@as(u32, 0x8001), accepted);
    try std.testing.expectEqual(@as(u32, 0xffff7ffe), flagsForStaging(0xffffffff, 0));
    try std.testing.expectEqual(@as(u32, 0xffff7fff), flagsForStaging(0xffffffff, 1));
    try std.testing.expectEqual(@as(u32, 0x8001), flagsForStaging(0, 0xffffffff));
}
