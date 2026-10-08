const std = @import("std");
const builtin = @import("builtin");
const metadata = @import("metadata.zig");

pub const Info = struct {
    device: u64,
    inode: u64,
    birth: ?metadata.Time = null,
    finder_flags: u32 = 0,
};

pub fn read(io: std.Io, root: std.Io.Dir, path: []const u8) !Info {
    if (comptime builtin.os.tag == .windows) {
        var file = try root.openFile(io, path, .{ .follow_symlinks = false, .allow_directory = true });
        defer file.close(io);
        var info: WinInfo = undefined;
        if (kernel.GetFileInformationByHandle(file.handle, &info) == .FALSE) return error.NativeStatFailed;
        const ticks = (@as(u64, info.creation.dwHighDateTime) << 32) | info.creation.dwLowDateTime;
        return .{
            .device = info.volume,
            .inode = (@as(u64, info.index_high) << 32) | info.index_low,
            .birth = timeFromWindows(ticks),
        };
    } else {
        var buffer: [std.posix.PATH_MAX]u8 = undefined;
        const path_z = try terminated(&buffer, path);
        if (comptime builtin.os.tag == .linux) {
            const linux = std.os.linux;
            var stat = std.mem.zeroes(linux.Statx);
            if (linux.errno(linux.statx(root.handle, path_z, linux.AT.SYMLINK_NOFOLLOW, .{ .INO = true, .BTIME = true }, &stat)) != .SUCCESS or !stat.mask.INO) return error.NativeStatFailed;
            return .{
                .device = (@as(u64, stat.dev_major) << 32) | stat.dev_minor,
                .inode = stat.ino,
                .birth = if (stat.mask.BTIME) .{ .sec = stat.btime.sec, .nsec = stat.btime.nsec } else null,
            };
        } else {
            var stat: std.c.Stat = undefined;
            if (std.c.fstatat(root.handle, path_z, &stat, std.posix.AT.SYMLINK_NOFOLLOW) != 0) return error.NativeStatFailed;
            return .{
                .device = @as(u32, @bitCast(stat.dev)),
                .inode = stat.ino,
                .birth = .{ .sec = stat.birthtimespec.sec, .nsec = @intCast(stat.birthtimespec.nsec) },
                .finder_flags = stat.flags,
            };
        }
    }
}

pub fn setBirth(allocator: std.mem.Allocator, abs_path: []const u8, time: metadata.Time) !bool {
    if (comptime builtin.os.tag == .macos) {
        const AttrList = extern struct {
            count: u16 = 5,
            reserved: u16 = 0,
            common: u32 = 0x200,
            volume: u32 = 0,
            dir: u32 = 0,
            file: u32 = 0,
            fork: u32 = 0,
        };
        const libc = struct {
            extern "c" fn setattrlist([*:0]const u8, *AttrList, *const std.c.timespec, usize, c_uint) c_int;
        };
        var buffer: [std.posix.PATH_MAX]u8 = undefined;
        const path_z = try terminated(&buffer, abs_path);
        var attrs: AttrList = .{};
        const stamp: std.c.timespec = .{ .sec = time.sec, .nsec = time.nsec };
        return libc.setattrlist(path_z, &attrs, &stamp, @sizeOf(std.c.timespec), 1) == 0;
    } else if (comptime builtin.os.tag == .windows) {
        const ticks = timeToWindows(time) orelse return false;
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(allocator, abs_path);
        defer allocator.free(wide);
        const handle = kernel.CreateFileW(wide, 0x100, 7, null, 3, 0x02200000, null);
        if (handle == windows.INVALID_HANDLE_VALUE) return false;
        defer _ = kernel.CloseHandle(handle);
        const stamp: windows.FILETIME = .{ .dwLowDateTime = @truncate(ticks), .dwHighDateTime = @truncate(ticks >> 32) };
        return kernel.SetFileTime(handle, &stamp, null, null) != .FALSE;
    } else return false;
}

fn terminated(buffer: []u8, path: []const u8) ![:0]const u8 {
    if (path.len >= buffer.len) return error.NameTooLong;
    @memcpy(buffer[0..path.len], path);
    buffer[path.len] = 0;
    return buffer[0..path.len :0];
}

const windows = std.os.windows;
const WinInfo = extern struct {
    attributes: u32,
    creation: windows.FILETIME,
    access: windows.FILETIME,
    write: windows.FILETIME,
    volume: u32,
    size_high: u32,
    size_low: u32,
    links: u32,
    index_high: u32,
    index_low: u32,
};
const kernel = struct {
    extern "kernel32" fn GetFileInformationByHandle(windows.HANDLE, *WinInfo) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn CreateFileW([*:0]const u16, u32, u32, ?*anyopaque, u32, u32, ?windows.HANDLE) callconv(.winapi) windows.HANDLE;
    extern "kernel32" fn SetFileTime(windows.HANDLE, ?*const windows.FILETIME, ?*const windows.FILETIME, ?*const windows.FILETIME) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn CloseHandle(windows.HANDLE) callconv(.winapi) windows.BOOL;
};

const windows_epoch_ticks: i128 = 116_444_736_000_000_000;

fn timeFromWindows(ticks: u64) metadata.Time {
    const ns = (@as(i128, ticks) - windows_epoch_ticks) * 100;
    return .{ .sec = @intCast(@divFloor(ns, std.time.ns_per_s)), .nsec = @intCast(@mod(ns, std.time.ns_per_s)) };
}

fn timeToWindows(time: metadata.Time) ?u64 {
    const ticks = @divFloor(@as(i128, time.sec) * std.time.ns_per_s + time.nsec, 100) + windows_epoch_ticks;
    return std.math.cast(u64, ticks);
}

test "Windows timestamp mapping exposes its 100 ns precision" {
    const cases = [_]struct { ticks: u64, time: metadata.Time }{
        .{ .ticks = 0, .time = .{ .sec = -11_644_473_600 } },
        .{ .ticks = 116_444_735_999_999_999, .time = .{ .sec = -1, .nsec = 999_999_900 } },
        .{ .ticks = 116_444_736_000_000_000, .time = .{} },
        .{ .ticks = 116_444_736_000_000_001, .time = .{ .nsec = 100 } },
    };
    for (cases) |case| {
        try std.testing.expectEqualDeep(case.time, timeFromWindows(case.ticks));
        try std.testing.expectEqual(@as(?u64, case.ticks), timeToWindows(case.time));
    }
    try std.testing.expectEqual(@as(?u64, 116_444_736_000_000_000), timeToWindows(.{ .nsec = 99 }));
    try std.testing.expectEqual(@as(?u64, null), timeToWindows(.{ .sec = -11_644_473_601 }));
}

test "native stat reports the inode and device shared by real hardlinks" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "a", .data = "same" });
    try tmp.dir.hardLink("a", tmp.dir, "b", io, .{});
    const a = try read(io, tmp.dir, "a");
    const b = try read(io, tmp.dir, "b");
    try std.testing.expectEqual(a.device, b.device);
    try std.testing.expectEqual(a.inode, b.inode);
    try std.testing.expectEqual((try tmp.dir.statFile(io, "a", .{})).inode, a.inode);
    if (a.birth) |birth| try std.testing.expect(birth.nsec < std.time.ns_per_s);
}
