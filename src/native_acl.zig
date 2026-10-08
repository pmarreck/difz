const std = @import("std");
const builtin = @import("builtin");
const metadata = @import("metadata.zig");
const xattr = @import("xattr_stream");

pub const LinuxAcl = struct { access: []const u8, default: []const u8 };
pub fn encodeLinux(allocator: std.mem.Allocator, acl: LinuxAcl) ![]u8 {
    try validateLinux(acl.access);
    try validateLinux(acl.default);
    const bytes = try allocator.alloc(u8, 16 + acl.access.len + acl.default.len);
    @memcpy(bytes[0..8], "DIFZACL\x01");
    std.mem.writeInt(u32, bytes[8..12], @intCast(acl.access.len), .little);
    std.mem.writeInt(u32, bytes[12..16], @intCast(acl.default.len), .little);
    @memcpy(bytes[16..][0..acl.access.len], acl.access);
    @memcpy(bytes[16 + acl.access.len ..], acl.default);
    return bytes;
}
pub fn decodeLinux(bytes: []const u8) !LinuxAcl {
    if (bytes.len < 16 or !std.mem.eql(u8, bytes[0..8], "DIFZACL\x01")) return error.InvalidAcl;
    const access_len = std.mem.readInt(u32, bytes[8..12], .little);
    const default_len = std.mem.readInt(u32, bytes[12..16], .little);
    if (@as(u64, access_len) + default_len != bytes.len - 16) return error.InvalidAcl;
    const acl: LinuxAcl = .{ .access = bytes[16..][0..access_len], .default = bytes[16 + access_len ..] };
    try validateLinux(acl.access);
    try validateLinux(acl.default);
    return acl;
}
pub fn portableLinux(allocator: std.mem.Allocator, bytes: []const u8) ![]const metadata.Ace {
    try validateLinux(bytes);
    if (bytes.len == 0) return &.{};
    const aces = try allocator.alloc(metadata.Ace, (bytes.len - 4) / 8);
    for (aces, 0..) |*ace, i| {
        const entry = bytes[4 + 8 * i ..][0..8];
        const tag: metadata.AceTag = switch (std.mem.readInt(u16, entry[0..2], .little)) {
            1 => .owner,
            2 => .named_user,
            4 => .group,
            8 => .named_group,
            16 => .mask,
            32 => .everyone,
            else => unreachable,
        };
        const perm = std.mem.readInt(u16, entry[2..4], .little);
        ace.* = .{ .tag = tag, .read = perm & 4 != 0, .write = perm & 2 != 0, .execute = perm & 1 != 0, .name = if (tag == .named_user or tag == .named_group) try std.fmt.allocPrint(allocator, "{d}", .{std.mem.readInt(u32, entry[4..8], .little)}) else "" };
    }
    return aces;
}

fn validateLinux(bytes: []const u8) !void {
    if (bytes.len == 0) return;
    if (bytes.len < 4 or (bytes.len - 4) % 8 != 0 or std.mem.readInt(u32, bytes[0..4], .little) != 2) return error.InvalidAcl;
    var base: u8 = 0;
    var last_tag: u16 = 0;
    var last_id: ?u32 = null;
    var named = false;
    var offset: usize = 4;
    while (offset < bytes.len) : (offset += 8) {
        const entry = bytes[offset..][0..8];
        const tag = std.mem.readInt(u16, entry[0..2], .little);
        const perm = std.mem.readInt(u16, entry[2..4], .little);
        const id = std.mem.readInt(u32, entry[4..8], .little);
        if (perm > 7 or tag < last_tag) return error.InvalidAcl;
        const is_named = tag == 2 or tag == 8;
        if (is_named) {
            if (id == std.math.maxInt(u32) or (tag == last_tag and id <= last_id.?)) return error.InvalidAcl;
            named = true;
        } else {
            if (id != std.math.maxInt(u32) or tag == last_tag) return error.InvalidAcl;
            base |= switch (tag) {
                1 => @as(u8, 1),
                4 => 2,
                16 => 4,
                32 => 8,
                else => return error.InvalidAcl,
            };
        }
        last_tag = tag;
        last_id = id;
    }
    if (base & 11 != 11 or (named and base & 4 == 0)) return error.InvalidAcl;
}

// Linux UAPI posix_acl_xattr: version 2, then tag/permissions/ID entries.
const fixture = [_]u8{ 2, 0, 0, 0, 1, 0, 7, 0, 255, 255, 255, 255, 2, 0, 4, 0, 123, 0, 0, 0, 4, 0, 5, 0, 255, 255, 255, 255, 16, 0, 5, 0, 255, 255, 255, 255, 32, 0, 0, 0, 255, 255, 255, 255 };

test "Linux native ACL bundle preserves access and default bytes with bounded decoding" {
    const t = std.testing;
    const bytes = try encodeLinux(t.allocator, .{ .access = &fixture, .default = &fixture });
    defer t.allocator.free(bytes);
    const decoded = try decodeLinux(bytes);
    try t.expectEqualSlices(u8, &fixture, decoded.access);
    try t.expectEqualSlices(u8, &fixture, decoded.default);
    const again = try encodeLinux(t.allocator, decoded);
    defer t.allocator.free(again);
    try t.expectEqualSlices(u8, bytes, again);
    for (0..bytes.len) |length| try t.expectError(error.InvalidAcl, decodeLinux(bytes[0..length]));
    var malformed = fixture;
    malformed[6] = 8;
    try t.expectError(error.InvalidAcl, encodeLinux(t.allocator, .{ .access = &malformed, .default = &.{} }));
}

test "Linux portable ACL mapping uses numeric principals and kernel permission bits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const aces = try portableLinux(arena.allocator(), &fixture);
    const canonical = try metadata.canonicalize(arena.allocator(), .{ .aces = aces }, .{});
    try std.testing.expectEqualDeep(&[_]metadata.Ace{
        .{ .tag = .owner, .read = true, .write = true, .execute = true },
        .{ .tag = .group, .read = true, .execute = true },
        .{ .tag = .everyone },
        .{ .tag = .named_user, .name = "123", .read = true },
        .{ .tag = .mask, .read = true, .execute = true },
    }, canonical.aces);
}

const raw_opts: xattr.Options = .{ .follow_symlinks = false, .raw_names = true };

pub fn capture(allocator: std.mem.Allocator, path: []const u8) !metadata.Metadata {
    if (comptime builtin.os.tag == .linux) {
        const access = try readLinuxAttribute(allocator, path, "system.posix_acl_access");
        const default = try readLinuxAttribute(allocator, path, "system.posix_acl_default");
        if (access.len == 0 and default.len == 0) return .{};
        return .{ .aces = try portableLinux(allocator, access), .native_acl = .{
            .origin = .linux,
            .bytes = try encodeLinux(allocator, .{ .access = access, .default = default }),
        } };
    } else if (comptime builtin.os.tag == .macos) {
        const path_z = try allocator.dupeZ(u8, path);
        const acl = darwin.acl_get_link_np(path_z, 0x100) orelse {
            // Libc also reports ENOENT when FILESEC_ACL is absent.
            if (std.c.errno(-1) == .OPNOTSUPP or std.c.errno(-1) == .NOENT) return .{};
            return error.AclReadFailed;
        };
        defer _ = darwin.acl_free(acl);
        var length: isize = 0;
        const text = darwin.acl_to_text(acl, &length) orelse return error.AclReadFailed;
        defer _ = darwin.acl_free(text);
        if (length < 0 or length > 65536) return error.InvalidAcl;
        return .{ .native_acl = .{ .origin = .macos, .bytes = try allocator.dupe(u8, text[0..@intCast(length)]) } };
    } else {
        const handle = try openWindows(allocator, path, 0x20000); // READ_CONTROL
        defer _ = win.CloseHandle(handle);
        var dacl: ?[*]u8 = null;
        var descriptor: ?*anyopaque = null;
        if (win.GetSecurityInfo(handle, 1, 4, null, null, &dacl, null, &descriptor) != 0) return error.AclReadFailed;
        defer _ = win.LocalFree(descriptor);
        var control: u16 = 0;
        var revision: u32 = 0;
        if (win.GetSecurityDescriptorControl(descriptor.?, &control, &revision) == .FALSE) return error.AclReadFailed;
        const length: usize = if (dacl) |value| std.mem.readInt(u16, value[2..4], .little) else 0;
        const bytes = try canonicalWindows(allocator, control & 0x1000 != 0, if (dacl) |value| value[0..length] else &.{});
        return .{ .native_acl = .{ .origin = .windows, .bytes = bytes } };
    }
}

/// Attempt native restoration. Canonical readback decides whether transport is needed.
pub fn restore(allocator: std.mem.Allocator, path: []const u8, desired: metadata.Metadata) !void {
    if (comptime builtin.os.tag == .linux) {
        const acl: LinuxAcl = if (desired.native_acl) |native| blk: {
            if (native.origin == .linux) break :blk try decodeLinux(native.bytes);
            break :blk .{ .access = try encodePortableLinux(allocator, desired.aces), .default = &.{} };
        } else .{ .access = try encodePortableLinux(allocator, desired.aces), .default = &.{} };
        try setLinuxAttribute(path, "system.posix_acl_access", acl.access);
        try setLinuxAttribute(path, "system.posix_acl_default", acl.default);
    } else if (comptime builtin.os.tag == .macos) {
        const native = desired.native_acl orelse {
            const empty = darwin.acl_init(0) orelse return error.AclRestoreFailed;
            defer _ = darwin.acl_free(empty);
            const path_z = try allocator.dupeZ(u8, path);
            if (darwin.acl_set_link_np(path_z, 0x100, empty) != 0) return error.AclRestoreFailed;
            return;
        };
        if (native.origin != .macos) return error.UnrepresentableAcl;
        try validateDarwinText(native.bytes);
        const text = try allocator.dupeZ(u8, native.bytes);
        const acl = darwin.acl_from_text(text) orelse return error.InvalidAcl;
        defer _ = darwin.acl_free(acl);
        const path_z = try allocator.dupeZ(u8, path);
        if (darwin.acl_set_link_np(path_z, 0x100, acl) != 0) return error.AclRestoreFailed;
    } else {
        const native = desired.native_acl orelse return error.UnrepresentableAcl;
        if (native.origin != .windows) return error.UnrepresentableAcl;
        try validateWindows(native.bytes);
        // Win32 consumes a DWORD-aligned ACL, unlike its packed transport.
        const aligned = try allocator.alignedAlloc(u8, .@"4", native.bytes.len - 1);
        @memcpy(aligned, native.bytes[1..]);
        const acl: ?*anyopaque = if (aligned.len == 0) null else aligned.ptr;
        if (acl != null and win.IsValidAcl(acl.?) == .FALSE) return error.InvalidAcl;
        const handle = try openWindows(allocator, path, 0x40000); // WRITE_DAC
        defer _ = win.CloseHandle(handle);
        const protection: u32 = if (native.bytes[0] == 1) 0x80000000 else 0x20000000;
        if (win.SetSecurityInfo(handle, 1, 4 | protection, null, null, acl, null) != 0) return error.AclRestoreFailed;
    }
}

fn validateDarwinText(bytes: []const u8) !void {
    if (bytes.len == 0 or bytes.len > 65536 or std.mem.indexOfScalar(u8, bytes, 0) != null) return error.InvalidAcl;
}

fn canonicalWindows(allocator: std.mem.Allocator, protected: bool, acl: []const u8) ![]u8 {
    const bytes = try allocator.alloc(u8, 1 + acl.len);
    errdefer allocator.free(bytes);
    bytes[0] = @intFromBool(protected);
    @memcpy(bytes[1..], acl);
    try validateWindows(bytes);
    if (acl.len == 0) return bytes;
    var used: usize = 8;
    for (0..std.mem.readInt(u16, acl[4..6], .little)) |_| used += std.mem.readInt(u16, acl[used + 2 ..][0..2], .little);
    std.mem.writeInt(u16, bytes[3..5], @intCast(used), .little);
    const result = try allocator.dupe(u8, bytes[0 .. 1 + used]);
    allocator.free(bytes);
    return result;
}

fn validateWindows(bytes: []const u8) !void {
    if (bytes.len == 0 or bytes[0] > 1) return error.InvalidAcl;
    if (bytes.len == 1) return;
    const acl = bytes[1..];
    if (acl.len < 8 or (acl[0] != 2 and acl[0] != 4) or acl[1] != 0 or std.mem.readInt(u16, acl[2..4], .little) != acl.len or std.mem.readInt(u16, acl[6..8], .little) != 0) return error.InvalidAcl;
    const count = std.mem.readInt(u16, acl[4..6], .little);
    var offset: usize = 8;
    for (0..count) |_| {
        if (acl.len - offset < 4) return error.InvalidAcl;
        const length = std.mem.readInt(u16, acl[offset + 2 ..][0..2], .little);
        if (length < 4 or length % 4 != 0 or length > acl.len - offset) return error.InvalidAcl;
        offset += length;
    }
    // Unused trailing ACL capacity is legal and remains part of the native record.
}

const darwin = struct {
    extern "c" fn acl_get_link_np([*:0]const u8, c_int) ?*anyopaque;
    extern "c" fn acl_set_link_np([*:0]const u8, c_int, *anyopaque) c_int;
    extern "c" fn acl_to_text(*anyopaque, *isize) ?[*]u8;
    extern "c" fn acl_from_text([*:0]const u8) ?*anyopaque;
    extern "c" fn acl_init(c_int) ?*anyopaque;
    extern "c" fn acl_free(*anyopaque) c_int;
};
const windows = std.os.windows;
const win = struct {
    extern "kernel32" fn CreateFileW([*:0]const u16, u32, u32, ?*anyopaque, u32, u32, ?windows.HANDLE) callconv(.winapi) windows.HANDLE;
    extern "kernel32" fn CloseHandle(windows.HANDLE) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn LocalFree(?*anyopaque) callconv(.winapi) ?*anyopaque;
    extern "advapi32" fn GetSecurityInfo(windows.HANDLE, c_int, u32, ?*anyopaque, ?*anyopaque, *?[*]u8, ?*anyopaque, *?*anyopaque) callconv(.winapi) u32;
    extern "advapi32" fn SetSecurityInfo(windows.HANDLE, c_int, u32, ?*anyopaque, ?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.winapi) u32;
    extern "advapi32" fn GetSecurityDescriptorControl(*anyopaque, *u16, *u32) callconv(.winapi) windows.BOOL;
    extern "advapi32" fn IsValidAcl(*anyopaque) callconv(.winapi) windows.BOOL;
};
fn openWindows(allocator: std.mem.Allocator, path: []const u8, access: u32) !windows.HANDLE {
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(allocator, path);
    const handle = win.CreateFileW(wide, access, 7, null, 3, 0x02200000, null);
    if (handle == windows.INVALID_HANDLE_VALUE) return error.AclOpenFailed;
    return handle;
}

fn readLinuxAttribute(allocator: std.mem.Allocator, path: []const u8, name: []const u8) ![]const u8 {
    return xattr.get(allocator, path, name, raw_opts) catch |err| switch (err) {
        error.Missing, error.Unsupported => &.{},
        else => return err,
    };
}

fn setLinuxAttribute(path: []const u8, name: []const u8, bytes: []const u8) !void {
    if (bytes.len != 0) return xattr.set(path, name, bytes, raw_opts);
    xattr.remove(path, name, raw_opts) catch |err| switch (err) {
        error.Missing, error.Unsupported => {},
        else => return err,
    };
}

fn encodePortableLinux(allocator: std.mem.Allocator, aces: []const metadata.Ace) ![]const u8 {
    if (aces.len == 0) return &.{};
    const Entry = struct { tag: u16, perm: u16, id: u32 };
    const entries = try allocator.alloc(Entry, aces.len);
    for (aces, entries) |ace, *entry| {
        entry.* = .{
            .tag = switch (ace.tag) {
                .owner => 1,
                .named_user => 2,
                .group => 4,
                .named_group => 8,
                .mask => 16,
                .everyone => 32,
            },
            .perm = (@as(u16, @intFromBool(ace.read)) << 2) | (@as(u16, @intFromBool(ace.write)) << 1) | @intFromBool(ace.execute),
            .id = if (ace.tag == .named_user or ace.tag == .named_group) std.fmt.parseInt(u32, ace.name, 10) catch return error.UnrepresentableAcl else std.math.maxInt(u32),
        };
    }
    std.mem.sort(Entry, entries, {}, struct {
        fn less(_: void, a: Entry, b: Entry) bool {
            return a.tag < b.tag or (a.tag == b.tag and a.id < b.id);
        }
    }.less);
    const bytes = try allocator.alloc(u8, 4 + aces.len * 8);
    std.mem.writeInt(u32, bytes[0..4], 2, .little);
    for (entries, 0..) |entry, i| {
        const dest = bytes[4 + i * 8 ..][0..8];
        std.mem.writeInt(u16, dest[0..2], entry.tag, .little);
        std.mem.writeInt(u16, dest[2..4], entry.perm, .little);
        std.mem.writeInt(u32, dest[4..8], entry.id, .little);
    }
    try validateLinux(bytes);
    return bytes;
}

test "Windows DACL transport validates every ACE boundary before native calls" {
    const t = std.testing;
    const valid = [_]u8{ 1, 2, 0, 12, 0, 1, 0, 0, 0, 0, 0, 4, 0 };
    try validateWindows(&valid);
    try validateWindows(&.{0}); // Native NULL DACL.
    for (0..valid.len) |length| {
        if (length == 1) continue; // A prefix can also be the complete NULL DACL.
        try t.expectError(error.InvalidAcl, validateWindows(valid[0..length]));
    }
    var invalid = valid;
    invalid[11] = 20;
    try t.expectError(error.InvalidAcl, validateWindows(&invalid));
    invalid = valid;
    invalid[5] = 2;
    try t.expectError(error.InvalidAcl, validateWindows(&invalid));
    invalid = valid;
    invalid[0] = 4;
    try t.expectError(error.InvalidAcl, validateWindows(&invalid));
}

test "Darwin native ACL text rejects embedded terminators and oversized input" {
    try validateDarwinText("!#acl 1\n");
    try std.testing.expectError(error.InvalidAcl, validateDarwinText("!#acl\x00ignored"));
    try std.testing.expectError(error.InvalidAcl, validateDarwinText(""));
}

test "Windows native ACL capture removes unused allocation capacity" {
    const t = std.testing;
    // The two ACLs have identical entries and different unused capacity bytes.
    const padded = [_]u8{ 2, 0, 16, 0, 1, 0, 0, 0, 0, 0, 4, 0, 81, 82, 83, 84 };
    const minimal = [_]u8{ 2, 0, 12, 0, 1, 0, 0, 0, 0, 0, 4, 0 };
    const a = try canonicalWindows(t.allocator, true, &padded);
    defer t.allocator.free(a);
    const b = try canonicalWindows(t.allocator, true, &minimal);
    defer t.allocator.free(b);
    try t.expectEqualSlices(u8, b, a);
    try t.expectEqualSlices(u8, &([_]u8{1} ++ minimal), a);
}
