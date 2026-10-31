const builtin = @import("builtin");
const std = @import("std");
const metadata = @import("metadata.zig");
const xattr_stream = @import("xattr_stream");

const linux = std.os.linux;

const nofollow_logical = xattr_stream.Options{ .follow_symlinks = false };
const nofollow_raw = xattr_stream.Options{ .follow_symlinks = false, .raw_names = true };

pub const Captured = struct {
    meta: metadata.Metadata,
    inode: u64,
    nlink: u32,
};

/// Read portable metadata for one filesystem object. `abs_path` is the
/// object itself, not its parent. Birth time prefers the `difz.btime`
/// sidecar over statx so a Linux restore still hashes back to the source.
pub fn capture(
    allocator: std.mem.Allocator,
    abs_path: []const u8,
    file: ?std.Io.File,
    stat: std.Io.File.Stat,
    omit: metadata.Omit,
) !Captured {
    var meta = metadata.Metadata{};
    if (!omit.timestamps) {
        meta.times.mtime = timeFromNs(stat.mtime.nanoseconds);
        if (try readSidecarTime(allocator, abs_path, "difz.btime")) |stored| {
            meta.times.btime = stored;
        } else if (statxBirth(abs_path)) |birth| meta.times.btime = birth;
    }
    if (!omit.xattr or !omit.acl or !omit.finder or !omit.sparse or !omit.hardlink) {
        try readAttributes(allocator, abs_path, &meta, omit);
    }
    if (!omit.sparse and meta.holes.len == 0) {
        if (file) |open| meta.holes = try scanHoles(allocator, open.handle, stat.size);
    }
    if (!omit.finder and meta.finder_info == null) {
        if (try readExactSidecar(allocator, abs_path, "difz.finder-info", 32)) |bytes| {
            var info: [32]u8 = undefined;
            @memcpy(&info, bytes);
            allocator.free(bytes);
            meta.finder_info = info;
        }
        if (try readExactSidecar(allocator, abs_path, "difz.bsd-flags", 4)) |bytes| {
            meta.finder_flags = std.mem.readInt(u32, bytes[0..4], .little);
            allocator.free(bytes);
        }
    }
    if (!omit.hardlink) {
        if (try readSidecar(allocator, abs_path, "difz.hardlink-to")) |path| meta.hardlink_to = path;
    }
    meta = try metadata.canonicalize(allocator, meta, omit);
    return .{
        .meta = meta,
        .inode = stat.inode,
        .nlink = stat.nlink,
    };
}

/// Best-effort restore. Native operations run first. A failure that can be
/// preserved in a `difz.*` sidecar is reported through `report` and does not
/// fail the call. A logical xattr that cannot be stored fails the call,
/// because the tree identity would otherwise change quietly.
pub fn restore(
    allocator: std.mem.Allocator,
    abs_path: []const u8,
    file: ?std.Io.File,
    meta: metadata.Metadata,
    report: *std.ArrayListUnmanaged(metadata.Compromise),
) !void {
    const os = switch (builtin.os.tag) {
        .linux => metadata.Os.linux,
        .macos => metadata.Os.macos,
        .windows => metadata.Os.windows,
        else => return error.UnsupportedOs,
    };
    var caps = metadata.defaultCaps(os);
    if (meta.holes.len != 0) {
        if (file) |open| {
            caps.punch_holes = punchHoles(open.handle, meta.holes);
        } else caps.punch_holes = false;
    }
    const plan = try metadata.planRestore(meta, caps);
    try appendCompromises(allocator, report, plan);

    if (plan.actions.logical_xattr or plan.actions.raw_xattr) {
        for (meta.xattrs) |xattr| {
            if (xattr.class == .logical) {
                xattr_stream.set(abs_path, xattr.name, xattr.value, nofollow_logical) catch return error.XattrRestoreFailed;
            } else if (xattr.class == .raw and metadataRawOk(os, xattr.name)) {
                xattr_stream.set(abs_path, xattr.name, xattr.value, nofollow_raw) catch return error.XattrRestoreFailed;
            }
        }
    }
    if (plan.actions.raw_xattr_sidecar) {
        var kept: std.ArrayListUnmanaged(metadata.Xattr) = .empty;
        defer kept.deinit(allocator);
        for (meta.xattrs) |xattr| {
            if (xattr.class == .raw and !metadataRawOk(os, xattr.name)) try kept.append(allocator, xattr);
        }
        const blob = try metadata.encodeCanonical(allocator, .{ .xattrs = kept.items });
        defer allocator.free(blob);
        xattr_stream.set(abs_path, "difz.raw-xattrs", blob, nofollow_logical) catch return error.XattrRestoreFailed;
    }
    if (plan.actions.native_acl) {
        if (meta.native_acl) |acl| {
            if (acl.origin == .linux) {
                xattr_stream.set(abs_path, "system.posix_acl_access", acl.bytes, nofollow_raw) catch return error.AclRestoreFailed;
            }
        }
    }
    if (plan.actions.portable_acl) {
        if (try encodePosixAcl(allocator, meta.aces)) |bytes| {
            defer allocator.free(bytes);
            xattr_stream.set(abs_path, "system.posix_acl_access", bytes, nofollow_raw) catch return error.AclRestoreFailed;
        }
    }
    if (plan.actions.native_acl_sidecar) {
        if (meta.native_acl) |acl| {
            const blob = try allocator.alloc(u8, 1 + acl.bytes.len);
            defer allocator.free(blob);
            blob[0] = @intFromEnum(acl.origin);
            @memcpy(blob[1..], acl.bytes);
            xattr_stream.set(abs_path, "difz.native-acl", blob, nofollow_logical) catch return error.AclRestoreFailed;
        }
    }
    if (plan.actions.portable_acl_sidecar) {
        const blob = try metadata.encodeCanonical(allocator, .{ .aces = meta.aces });
        defer allocator.free(blob);
        xattr_stream.set(abs_path, "difz.portable-acl", blob, nofollow_logical) catch return error.AclRestoreFailed;
    }
    if (plan.actions.btime_sidecar) {
        if (meta.times.btime) |time| try writeTimeSidecar(abs_path, "difz.btime", time);
    }
    if (plan.actions.finder_info_sidecar) {
        if (meta.finder_info) |info| {
            xattr_stream.set(abs_path, "difz.finder-info", &info, nofollow_logical) catch return error.XattrRestoreFailed;
        }
    }
    if (plan.actions.bsd_flags_sidecar and meta.finder_flags != 0) {
        var raw: [4]u8 = undefined;
        std.mem.writeInt(u32, &raw, meta.finder_flags, .little);
        xattr_stream.set(abs_path, "difz.bsd-flags", &raw, nofollow_logical) catch return error.XattrRestoreFailed;
    }
    if (plan.actions.sparse_sidecar) {
        const blob = try metadata.encodeCanonical(allocator, .{ .holes = meta.holes });
        defer allocator.free(blob);
        xattr_stream.set(abs_path, "difz.sparse-holes", blob, nofollow_logical) catch return error.XattrRestoreFailed;
    }
    if (plan.actions.hardlink_copy) {
        if (meta.hardlink_to) |path| {
            xattr_stream.set(abs_path, "difz.hardlink-to", path, nofollow_logical) catch return error.XattrRestoreFailed;
        }
    }
}

fn metadataRawOk(os: metadata.Os, name: []const u8) bool {
    return switch (os) {
        .linux => std.mem.startsWith(u8, name, "user.") or std.mem.startsWith(u8, name, "system.") or
            std.mem.startsWith(u8, name, "security.") or std.mem.startsWith(u8, name, "trusted."),
        .macos => name.len > 0 and name.len <= 127 and std.mem.indexOfScalar(u8, name, '/') == null,
        .windows => name.len > 0 and name.len <= 255,
    };
}

fn appendCompromises(
    allocator: std.mem.Allocator,
    report: *std.ArrayListUnmanaged(metadata.Compromise),
    plan: metadata.Plan,
) !void {
    for (plan.compromises[0..plan.compromise_len]) |item| {
        for (report.items) |existing| if (existing.code == item.code) continue;
        try report.append(allocator, item);
    }
}

fn readAttributes(
    allocator: std.mem.Allocator,
    abs_path: []const u8,
    meta: *metadata.Metadata,
    omit: metadata.Omit,
) !void {
    var listed = xattr_stream.list(allocator, abs_path, nofollow_raw) catch |err| switch (err) {
        error.Unsupported, error.NotFound => return,
        else => return err,
    };
    defer listed.deinit(allocator);
    var xattrs: std.ArrayListUnmanaged(metadata.Xattr) = .empty;
    var it = listed.iterator();
    while (it.next()) |native| {
        if (metadata.isTransportName(native)) continue;
        if (std.mem.eql(u8, native, "system.posix_acl_access") or std.mem.eql(u8, native, "system.posix_acl_default")) {
            if (omit.acl or meta.native_acl != null) continue;
            const bytes = try xattr_stream.get(allocator, abs_path, native, nofollow_raw);
            meta.aces = parsePosixAcl(allocator, bytes) catch &.{};
            meta.native_acl = .{ .origin = .linux, .bytes = bytes };
            continue;
        }
        if (omit.xattr) continue;
        if (xattr_stream.names.fromNative(.linux, native, .{ .raw = false })) |logical| {
            if (metadata.isTransportName(logical)) continue;
            const value = try xattr_stream.get(allocator, abs_path, logical, nofollow_logical);
            try xattrs.append(allocator, .{ .class = .logical, .name = logical, .value = value });
        } else {
            const value = try xattr_stream.get(allocator, abs_path, native, nofollow_raw);
            try xattrs.append(allocator, .{ .class = .raw, .name = native, .value = value });
        }
    }
    if (meta.native_acl == null and !omit.acl) {
        if (try readSidecar(allocator, abs_path, "difz.native-acl")) |blob| {
            if (blob.len >= 1) {
                const origin = std.enums.fromInt(metadata.AclOrigin, blob[0]) orelse return error.BadMetadata;
                meta.native_acl = .{ .origin = origin, .bytes = blob[1..] };
            }
        }
    }
    meta.xattrs = try xattrs.toOwnedSlice(allocator);
    if (!omit.sparse and meta.holes.len == 0) {
        if (try readSidecar(allocator, abs_path, "difz.sparse-holes")) |blob| {
            const decoded = try metadata.decodeCanonical(allocator, blob);
            meta.holes = decoded.holes;
        }
    }
}

fn timeFromNs(nanoseconds: i96) metadata.Time {
    const scale: i96 = 1_000_000_000;
    const sec = @divFloor(nanoseconds, scale);
    const nsec = nanoseconds - sec * scale;
    return .{ .sec = @intCast(sec), .nsec = @intCast(nsec) };
}

fn statxBirth(abs_path: []const u8) ?metadata.Time {
    if (comptime builtin.os.tag != .linux) return null;
    var path_buf: [4097]u8 = undefined;
    if (abs_path.len >= path_buf.len) return null;
    @memcpy(path_buf[0..abs_path.len], abs_path);
    path_buf[abs_path.len] = 0;
    var stx = std.mem.zeroes(linux.Statx);
    const rc = linux.statx(
        linux.AT.FDCWD,
        path_buf[0..abs_path.len :0],
        linux.AT.SYMLINK_NOFOLLOW,
        .{ .BTIME = true },
        &stx,
    );
    if (linux.errno(rc) != .SUCCESS or !stx.mask.BTIME) return null;
    if (stx.btime.nsec >= 1_000_000_000) return null;
    return .{ .sec = stx.btime.sec, .nsec = stx.btime.nsec };
}

fn readSidecar(allocator: std.mem.Allocator, abs_path: []const u8, name: []const u8) !?[]u8 {
    return xattr_stream.get(allocator, abs_path, name, nofollow_logical) catch |err| switch (err) {
        error.Missing, error.Unsupported, error.NotFound => null,
        else => return err,
    };
}

fn readSidecarTime(allocator: std.mem.Allocator, abs_path: []const u8, name: []const u8) !?metadata.Time {
    const bytes = try readSidecar(allocator, abs_path, name) orelse return null;
    defer allocator.free(bytes);
    if (bytes.len != 12) return null;
    const nsec = std.mem.readInt(u32, bytes[8..12], .little);
    if (nsec >= 1_000_000_000) return null;
    return .{
        .sec = std.mem.readInt(i64, bytes[0..8], .little),
        .nsec = nsec,
    };
}

fn readExactSidecar(allocator: std.mem.Allocator, abs_path: []const u8, name: []const u8, len: usize) !?[]u8 {
    const bytes = try readSidecar(allocator, abs_path, name) orelse return null;
    if (bytes.len != len) {
        allocator.free(bytes);
        return null;
    }
    return bytes;
}

fn writeTimeSidecar(abs_path: []const u8, name: []const u8, time: metadata.Time) !void {
    var raw: [12]u8 = undefined;
    std.mem.writeInt(i64, raw[0..8], time.sec, .little);
    std.mem.writeInt(u32, raw[8..12], time.nsec, .little);
    xattr_stream.set(abs_path, name, &raw, nofollow_logical) catch return error.XattrRestoreFailed;
}

fn scanHoles(allocator: std.mem.Allocator, fd: std.posix.fd_t, size: u64) ![]metadata.Hole {
    if (comptime builtin.os.tag != .linux or size == 0) return &.{};
    var holes: std.ArrayListUnmanaged(metadata.Hole) = .empty;
    var offset: u64 = 0;
    while (offset < size) {
        const data = lseekAt(fd, offset, 3) orelse return holes.toOwnedSlice(allocator);
        if (data > size) return holes.toOwnedSlice(allocator);
        if (data > offset) try holes.append(allocator, .{ .offset = offset, .length = data - offset });
        const hole_end = lseekAt(fd, data, 4) orelse return holes.toOwnedSlice(allocator);
        if (hole_end <= data) return holes.toOwnedSlice(allocator);
        offset = @min(hole_end, size);
    }
    return holes.toOwnedSlice(allocator);
}

fn lseekAt(fd: std.posix.fd_t, offset: u64, whence: usize) ?u64 {
    const rc = linux.lseek(fd, @intCast(offset), whence);
    if (linux.errno(rc) != .SUCCESS) return null;
    return @intCast(rc);
}

fn punchHoles(fd: std.posix.fd_t, holes: []const metadata.Hole) bool {
    if (comptime builtin.os.tag != .linux) return false;
    const mode: i32 = 0x01 | 0x02;
    for (holes) |hole| {
        const rc = linux.fallocate(fd, mode, @intCast(hole.offset), @intCast(hole.length));
        if (linux.errno(rc) != .SUCCESS) return false;
    }
    return true;
}

fn parsePosixAcl(allocator: std.mem.Allocator, bytes: []const u8) ![]metadata.Ace {
    if (bytes.len < 4 or (bytes.len - 4) % 8 != 0) return error.BadMetadata;
    if (std.mem.readInt(u32, bytes[0..4], .little) != 2) return error.BadMetadata;
    const count = (bytes.len - 4) / 8;
    const aces = try allocator.alloc(metadata.Ace, count);
    var index: usize = 0;
    var cursor: usize = 4;
    while (cursor < bytes.len) : (cursor += 8) {
        const tag = std.mem.readInt(u16, bytes[cursor..][0..2], .little);
        const perm = std.mem.readInt(u16, bytes[cursor + 2 ..][0..2], .little);
        const id = std.mem.readInt(u32, bytes[cursor + 4 ..][0..4], .little);
        const ace_tag: metadata.AceTag = switch (tag) {
            0x0001 => .owner,
            0x0002 => .named_user,
            0x0004 => .group,
            0x0008 => .named_group,
            0x0010 => .mask,
            0x0020 => .everyone,
            else => return error.BadMetadata,
        };
        const named = ace_tag == .named_user or ace_tag == .named_group;
        aces[index] = .{
            .tag = ace_tag,
            .read = perm & 4 != 0,
            .write = perm & 2 != 0,
            .execute = perm & 1 != 0,
            .name = if (named) try std.fmt.allocPrint(allocator, "{d}", .{id}) else "",
        };
        index += 1;
    }
    return aces;
}

fn encodePosixAcl(allocator: std.mem.Allocator, aces: []const metadata.Ace) !?[]u8 {
    if (aces.len == 0) return null;
    const bytes = try allocator.alloc(u8, 4 + aces.len * 8);
    std.mem.writeInt(u32, bytes[0..4], 2, .little);
    for (aces, 0..) |ace, index| {
        const tag: u16 = switch (ace.tag) {
            .owner => 0x0001,
            .named_user => 0x0002,
            .group => 0x0004,
            .named_group => 0x0008,
            .mask => 0x0010,
            .everyone => 0x0020,
        };
        var id: u32 = 0;
        if (ace.tag == .named_user or ace.tag == .named_group) {
            id = std.fmt.parseInt(u32, ace.name, 10) catch {
                allocator.free(bytes);
                return null;
            };
        }
        var perm: u16 = 0;
        if (ace.read) perm |= 4;
        if (ace.write) perm |= 2;
        if (ace.execute) perm |= 1;
        const at = 4 + index * 8;
        std.mem.writeInt(u16, bytes[at..][0..2], tag, .little);
        std.mem.writeInt(u16, bytes[at + 2 ..][0..2], perm, .little);
        std.mem.writeInt(u32, bytes[at + 4 ..][0..4], id, .little);
    }
    return bytes;
}

pub fn directoryPath(dir: std.Io.Dir, buf: []u8) ![]const u8 {
    if (comptime builtin.os.tag != .linux) return error.UnsupportedOs;
    var link_buf: [64]u8 = undefined;
    const link = try std.fmt.bufPrint(link_buf[0 .. link_buf.len - 1], "/proc/self/fd/{d}", .{dir.handle});
    var zlink: [64]u8 = undefined;
    @memcpy(zlink[0..link.len], link);
    zlink[link.len] = 0;
    const rc = linux.readlink(zlink[0..link.len :0], buf.ptr, buf.len);
    if (linux.errno(rc) != .SUCCESS) return error.UnsupportedOs;
    const len: usize = @intCast(rc);
    if (len == 0 or len >= buf.len) return error.UnsupportedOs;
    return buf[0..len];
}

pub fn joinUnder(allocator: std.mem.Allocator, root: []const u8, rel: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, rel });
}
