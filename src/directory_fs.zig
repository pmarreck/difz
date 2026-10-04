const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const directory = @import("directory.zig");
const directory_patch = @import("directory_patch.zig");
const metadata = @import("metadata.zig");
const path_filter = @import("path_filter.zig");
const xattr_stream = @import("xattr_stream");

const logical_xattr_opts = xattr_stream.Options{ .follow_symlinks = false };
const raw_xattr_opts = xattr_stream.Options{ .follow_symlinks = false, .raw_names = true };

pub const OwnedSnapshot = struct {
    arena: std.heap.ArenaAllocator,
    entries: []directory.Entry,
    // Attributes of the snapshot directory itself. Entries cannot name it:
    // an empty path is rejected. Gatekeeper reads this directory.
    root_meta: metadata.Metadata = .{},

    pub fn deinit(self: *OwnedSnapshot) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn snapshotDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    rules: []const path_filter.Rule,
) !OwnedSnapshot {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

    var raw: std.ArrayListUnmanaged(directory.Entry) = .empty;
    var root_buf: [std.posix.PATH_MAX]u8 = undefined;
    const root_len = try root.realPath(io, &root_buf);
    try walk(arena_allocator, io, root, "", root_buf[0..root_len], &raw);
    std.mem.sort(directory.Entry, raw.items, {}, entryLessThan);
    try directory.validateSnapshot(raw.items);

    const entries = if (rules.len == 0)
        try raw.toOwnedSlice(arena_allocator)
    else
        try selectEntries(arena_allocator, raw.items, rules);
    try directory.validateSnapshot(entries);
    const root_xattrs = try readXattrs(arena_allocator, root_buf[0..root_len]);
    const root_meta: metadata.Metadata = if (root_xattrs.len == 0)
        .{}
    else
        try metadata.canonicalize(arena_allocator, .{ .xattrs = root_xattrs }, .{});
    return .{ .arena = arena, .entries = entries, .root_meta = root_meta };
}

pub fn createPatchFromDirs(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: std.Io.Dir,
    target: std.Io.Dir,
    options: directory_patch.CreateOptions,
) ![]u8 {
    var source_snapshot = try snapshotDir(allocator, io, source, options.rules);
    defer source_snapshot.deinit();
    var target_snapshot = try snapshotDir(allocator, io, target, options.rules);
    defer target_snapshot.deinit();
    var patch_options = options;
    patch_options.source_root = source_snapshot.root_meta;
    patch_options.target_root = target_snapshot.root_meta;
    return directory_patch.createPatch(
        allocator,
        source_snapshot.entries,
        target_snapshot.entries,
        patch_options,
    );
}

pub fn applyPatchToNewDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: std.Io.Dir,
    output_parent: std.Io.Dir,
    output_name: []const u8,
    staging_name: []const u8,
    patch_bytes: []const u8,
    limits: directory_patch.Limits,
) !void {
    try validateBasename(output_name);
    try validateBasename(staging_name);
    if (std.mem.eql(u8, output_name, staging_name)) return error.StagingNameConflict;
    if (output_parent.statFile(io, output_name, .{ .follow_symlinks = false })) |_| {
        return error.OutputAlreadyExists;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    var owned_rules = try directory_patch.readRules(allocator, patch_bytes, limits);
    defer owned_rules.deinit();
    var source_snapshot = try snapshotDir(allocator, io, source, owned_rules.rules);
    defer source_snapshot.deinit();
    var reconstructed = try directory_patch.applyPatchRoot(
        allocator,
        source_snapshot.entries,
        patch_bytes,
        limits,
        source_snapshot.root_meta,
    );
    defer reconstructed.deinit();

    try output_parent.createDir(io, staging_name, writableDirectoryPermissions());
    var owns_stage = true;
    errdefer if (owns_stage) deleteOwnedTree(io, output_parent, staging_name) catch {};
    var stage = try output_parent.openDir(io, staging_name, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer stage.close(io);
    try writeSnapshot(allocator, io, stage, reconstructed.entries, reconstructed.root_meta);

    var staged_snapshot = try snapshotDir(allocator, io, stage, &.{});
    defer staged_snapshot.deinit();
    const expect_metadata = directory.usesMetadata(reconstructed.entries) or !reconstructed.root_meta.isEmpty();
    const expected_hash = if (expect_metadata)
        try directory.treeHashV2WithRoot(reconstructed.entries, reconstructed.root_meta)
    else
        try directory.treeHash(reconstructed.entries);
    const staged_hash = if (expect_metadata)
        try directory.treeHashV2WithRoot(staged_snapshot.entries, staged_snapshot.root_meta)
    else
        try directory.treeHash(staged_snapshot.entries);
    if (!std.mem.eql(u8, &expected_hash, &staged_hash)) return error.StagedHashMismatch;

    try publishStagingDir(io, output_parent, staging_name, output_name);
    owns_stage = false;
}

/// Move a finished staging directory to its final name, and fail if that name
/// is already taken. Linux uses renameat2(RENAME_NOREPLACE). Darwin's
/// renamePreserve hardlinks first, and a directory cannot be hardlinked, so
/// the publish uses renameatx_np(RENAME_EXCL) instead.
fn publishStagingDir(
    io: std.Io,
    parent: std.Io.Dir,
    staging_name: []const u8,
    output_name: []const u8,
) !void {
    if (comptime builtin.os.tag != .macos) {
        try parent.renamePreserve(staging_name, parent, output_name, io);
        return;
    }
    // Analyzed only on macOS: renameatx_np is a Darwin libc symbol.
    const rename_excl: u32 = 0x00000004;
    const libc = struct {
        extern "c" fn renameatx_np(
            from_fd: std.posix.fd_t,
            from_path: [*:0]const u8,
            to_fd: std.posix.fd_t,
            to_path: [*:0]const u8,
            flags: u32,
        ) c_int;
    };
    var from_buf: [std.posix.PATH_MAX]u8 = undefined;
    var to_buf: [std.posix.PATH_MAX]u8 = undefined;
    const from_z = try terminatedBasename(&from_buf, staging_name);
    const to_z = try terminatedBasename(&to_buf, output_name);
    switch (std.c.errno(libc.renameatx_np(parent.handle, from_z, parent.handle, to_z, rename_excl))) {
        .SUCCESS => {},
        .EXIST => return error.OutputAlreadyExists,
        .NOENT => return error.FileNotFound,
        .ACCES => return error.AccessDenied,
        .PERM => return error.PermissionDenied,
        .NOTDIR => return error.NotDir,
        .NOTEMPTY => return error.DirNotEmpty,
        .NAMETOOLONG => return error.NameTooLong,
        .ROFS => return error.ReadOnlyFileSystem,
        .NOSPC => return error.NoSpaceLeft,
        .IO => return error.FileSystem,
        .LOOP => return error.SymLinkLoop,
        .ILSEQ => return error.BadPathName,
        else => return error.Unexpected,
    }
}

fn terminatedBasename(buffer: []u8, name: []const u8) ![:0]const u8 {
    if (name.len >= buffer.len) return error.NameTooLong;
    @memcpy(buffer[0..name.len], name);
    buffer[name.len] = 0;
    return buffer[0..name.len :0];
}

fn deleteOwnedTree(io: std.Io, parent: std.Io.Dir, name: []const u8) !void {
    {
        var root = try parent.openDir(io, name, .{ .iterate = true, .follow_symlinks = false });
        defer root.close(io);
        try makeDirectoriesWritable(io, root);
    }
    try parent.deleteTree(io, name);
}

fn makeDirectoriesWritable(io: std.Io, root: std.Io.Dir) !void {
    var iterator = root.iterate();
    while (try iterator.next(io)) |entry| {
        const stat = try root.statFile(io, entry.name, .{ .follow_symlinks = false });
        if (stat.kind != .directory) continue;
        try root.setFilePermissions(
            io,
            entry.name,
            writableDirectoryPermissions(),
            .{ .follow_symlinks = false },
        );
        var child = try root.openDir(io, entry.name, .{ .iterate = true, .follow_symlinks = false });
        defer child.close(io);
        try makeDirectoriesWritable(io, child);
    }
}

fn treeHasXattrs(entries: []const directory.Entry) bool {
    for (entries) |entry| if (entry.meta.xattrs.len != 0) return true;
    return false;
}

fn writeSnapshot(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    entries: []const directory.Entry,
    root_meta: metadata.Metadata,
) !void {
    try directory.validateSnapshot(entries);
    for (entries) |entry| {
        switch (entry.kind) {
            .directory => try root.createDir(io, entry.path, writableDirectoryPermissions()),
            .file => {
                var file = try root.createFile(io, entry.path, .{
                    .exclusive = true,
                    .permissions = writableFilePermissions(),
                    .resolve_beneath = true,
                });
                defer file.close(io);
                try file.writeStreamingAll(io, entry.data);
                try file.setPermissions(io, try permissionsForMode(entry.mode, .file));
            },
            .symlink => try root.symLink(io, entry.data, entry.path, .{
                .is_directory = try symlinkPointsToDirectory(allocator, entries, entry),
            }),
        }
    }
    var index = entries.len;
    while (index > 0) {
        index -= 1;
        const entry = entries[index];
        if (entry.kind == .directory) {
            try root.setFilePermissions(
                io,
                entry.path,
                try permissionsForMode(entry.mode, .directory),
                .{ .follow_symlinks = false },
            );
        }
    }
    // Extended attributes before the timestamp. setxattr can bump mtime,
    // and the staged hash compares the stamp the patch recorded.
    if (treeHasXattrs(entries) or root_meta.xattrs.len != 0) {
        var root_buf: [std.posix.PATH_MAX]u8 = undefined;
        const root_len = try root.realPath(io, &root_buf);
        for (entries) |entry| {
            if (entry.meta.xattrs.len == 0) continue;
            var abs_buf: [std.posix.PATH_MAX]u8 = undefined;
            const abs_path = std.fmt.bufPrint(&abs_buf, "{s}/{s}", .{ root_buf[0..root_len], entry.path }) catch return error.NameTooLong;
            try restoreXattrs(allocator, abs_path, entry.meta);
        }
        if (root_meta.xattrs.len != 0) {
            try restoreXattrs(allocator, root_buf[0..root_len], root_meta);
        }
    }
    // After content and permission writes, which can bump mtime.
    for (entries) |entry| {
        if (entry.meta.times.mtime) |mtime| {
            try root.setTimestamps(io, entry.path, .{
                .follow_symlinks = false,
                .modify_timestamp = .{ .new = timestampFromTime(mtime) },
            });
        }
    }
}

fn trimLeadingSlashes(path: []const u8) []const u8 {
    return std.mem.trimStart(u8, path, "/");
}

test "trimLeadingSlashes strips a posix root prefix" {
    try testing.expectEqualStrings("a/b", trimLeadingSlashes("/a/b"));
    try testing.expectEqualStrings("a", trimLeadingSlashes("a"));
    try testing.expectEqualStrings("", trimLeadingSlashes("/"));
    try testing.expectEqualStrings("", trimLeadingSlashes(""));
}

fn symlinkPointsToDirectory(
    allocator: std.mem.Allocator,
    entries: []const directory.Entry,
    link: directory.Entry,
) !bool {
    if (comptime builtin.os.tag != .windows) return false;
    const parent_path = if (std.mem.lastIndexOfScalar(u8, link.path, '/')) |slash|
        try std.fmt.allocPrint(allocator, "/{s}", .{link.path[0..slash]})
    else
        try allocator.dupe(u8, "/");
    defer allocator.free(parent_path);
    const resolved = try std.fs.path.resolvePosix(allocator, &.{ parent_path, link.data });
    defer allocator.free(resolved);
    const target_path = trimLeadingSlashes(resolved);
    if (target_path.len == 0) return true;
    const target_index = findEntry(entries, target_path) orelse return false;
    return entries[target_index].kind == .directory;
}

fn validateBasename(name: []const u8) !void {
    try directory.validatePath(name);
    if (std.mem.indexOfScalar(u8, name, '/') != null) return error.NotBasename;
}

fn writableDirectoryPermissions() std.Io.File.Permissions {
    if (comptime builtin.os.tag == .windows) return .default_dir;
    return .fromMode(0o700);
}

fn writableFilePermissions() std.Io.File.Permissions {
    if (comptime builtin.os.tag == .windows) return .default_file;
    return .fromMode(0o600);
}

fn permissionsForMode(mode: u16, kind: directory.EntryKind) !std.Io.File.Permissions {
    if (comptime builtin.os.tag == .windows) {
        const expected: u16 = switch (kind) {
            .directory => 0o755,
            .file => 0o644,
            .symlink => 0o777,
        };
        if (mode != expected) return error.UnsupportedMode;
        return switch (kind) {
            .directory, .symlink => .default_dir,
            .file => .default_file,
        };
    }
    return .fromMode(@intCast(mode));
}

fn walk(
    allocator: std.mem.Allocator,
    io: std.Io,
    current: std.Io.Dir,
    prefix: []const u8,
    abs_dir: []const u8,
    entries: *std.ArrayListUnmanaged(directory.Entry),
) !void {
    var iterator = current.iterate();
    while (try iterator.next(io)) |item| {
        const path = if (prefix.len == 0)
            try allocator.dupe(u8, item.name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, item.name });
        try directory.validatePath(path);
        var abs_buf: [std.posix.PATH_MAX]u8 = undefined;
        const abs_path = std.fmt.bufPrint(&abs_buf, "{s}/{s}", .{ abs_dir, item.name }) catch return error.NameTooLong;
        const stat = try current.statFile(io, item.name, .{ .follow_symlinks = false });
        const meta = try metadataFor(allocator, stat.mtime, abs_path);

        switch (stat.kind) {
            .directory => {
                try entries.append(allocator, .{
                    .path = path,
                    .kind = .directory,
                    .mode = canonicalMode(stat, .directory),
                    .meta = meta,
                });
                var child = try current.openDir(io, item.name, .{
                    .iterate = true,
                    .follow_symlinks = false,
                });
                defer child.close(io);
                try walk(allocator, io, child, path, abs_path, entries);
            },
            .file => {
                var file = try current.openFile(io, item.name, .{
                    .allow_directory = false,
                    .follow_symlinks = false,
                    .resolve_beneath = true,
                });
                defer file.close(io);
                const opened_stat = try file.stat(io);
                if (opened_stat.kind != .file) return error.FileChangedDuringSnapshot;
                var reader = file.reader(io, &.{});
                const data = try reader.interface.allocRemaining(allocator, .unlimited);
                const file_meta = if (opened_stat.mtime.nanoseconds == stat.mtime.nanoseconds)
                    meta
                else
                    try metadataFor(allocator, opened_stat.mtime, abs_path);
                try entries.append(allocator, .{
                    .path = path,
                    .kind = .file,
                    .mode = canonicalMode(opened_stat, .file),
                    .data = data,
                    .meta = file_meta,
                });
            },
            .sym_link => {
                var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
                const length = try current.readLink(io, item.name, &buffer);
                try entries.append(allocator, .{
                    .path = path,
                    .kind = .symlink,
                    .mode = 0o777,
                    .data = try allocator.dupe(u8, buffer[0..length]),
                    .meta = meta,
                });
            },
            else => return error.UnsupportedEntryKind,
        }
    }
}

/// Extended attributes for one object, classified through xattr_stream.
/// Logical names restore without a warning. `com.apple.ResourceFork` is
/// omitted (resource-fork payload, not a portable attribute). Names this OS
/// cannot store are read back from the `difz.raw-xattrs` sidecar.
fn readXattrs(allocator: std.mem.Allocator, abs_path: []const u8) ![]const metadata.Xattr {
    var listed = xattr_stream.list(allocator, abs_path, raw_xattr_opts) catch |err| switch (err) {
        error.Unsupported, error.NotFound => return &.{},
        else => return err,
    };
    defer listed.deinit(allocator);

    var xattrs: std.ArrayListUnmanaged(metadata.Xattr) = .empty;
    var sidecar: ?[]const u8 = null;
    var it = listed.iterator();
    while (it.next()) |native| {
        if (metadata.isTransportName(native)) {
            if (std.mem.eql(u8, transportBare(native), "difz.raw-xattrs")) {
                sidecar = try xattr_stream.get(allocator, abs_path, "difz.raw-xattrs", logical_xattr_opts);
            }
            continue;
        }
        if (excludedXattr(native)) continue;
        if (xattr_stream.names.fromNative(xattr_stream.os, native, .{ .raw = false })) |logical| {
            if (metadata.isTransportName(logical)) continue;
            const value = try xattr_stream.get(allocator, abs_path, logical, logical_xattr_opts);
            try xattrs.append(allocator, .{
                .class = .logical,
                .name = try allocator.dupe(u8, logical),
                .value = value,
            });
        } else {
            const value = try xattr_stream.get(allocator, abs_path, native, raw_xattr_opts);
            try xattrs.append(allocator, .{
                .class = .raw,
                .name = try allocator.dupe(u8, native),
                .value = value,
            });
        }
    }
    if (sidecar) |blob| {
        const decoded = try metadata.decodeCanonical(allocator, blob);
        for (decoded.xattrs) |xattr| {
            if (xattr.class != .raw) continue;
            if (hasXattr(xattrs.items, xattr.class, xattr.name)) continue;
            try xattrs.append(allocator, .{
                .class = .raw,
                .name = try allocator.dupe(u8, xattr.name),
                .value = try allocator.dupe(u8, xattr.value),
            });
        }
    }
    return xattrs.toOwnedSlice(allocator);
}

fn metadataFor(allocator: std.mem.Allocator, timestamp: std.Io.Timestamp, abs_path: []const u8) !metadata.Metadata {
    var meta = modificationMetadata(timestamp);
    meta.xattrs = try readXattrs(allocator, abs_path);
    if (meta.xattrs.len == 0) return meta;
    return metadata.canonicalize(allocator, meta, .{});
}

fn restoreXattrs(allocator: std.mem.Allocator, abs_path: []const u8, meta: metadata.Metadata) !void {
    const os = switch (builtin.os.tag) {
        .macos => metadata.Os.macos,
        .windows => metadata.Os.windows,
        else => metadata.Os.linux,
    };
    var preserved: std.ArrayListUnmanaged(metadata.Xattr) = .empty;
    defer preserved.deinit(allocator);
    for (meta.xattrs) |xattr| {
        switch (xattr.class) {
            .logical => xattr_stream.set(abs_path, xattr.name, xattr.value, logical_xattr_opts) catch return error.XattrRestoreFailed,
            .raw => {
                if (!metadata.rawAccepted(os, xattr.name)) {
                    try preserved.append(allocator, xattr);
                    continue;
                }
                xattr_stream.set(abs_path, xattr.name, xattr.value, raw_xattr_opts) catch |err| switch (err) {
                    error.Permission, error.Unsupported => try preserved.append(allocator, xattr),
                    else => return error.XattrRestoreFailed,
                };
            },
        }
    }
    if (preserved.items.len == 0) return;
    const blob = try metadata.encodeCanonical(allocator, .{ .xattrs = preserved.items });
    defer allocator.free(blob);
    xattr_stream.set(abs_path, "difz.raw-xattrs", blob, logical_xattr_opts) catch return error.XattrRestoreFailed;
    std.debug.print("difz: raw attributes that this OS cannot store were preserved in difz.raw-xattrs\n", .{});
}

fn excludedXattr(native: []const u8) bool {
    const bare = transportBare(native);
    if (std.mem.eql(u8, bare, "com.apple.ResourceFork")) return true;
    if (std.mem.eql(u8, native, "system.posix_acl_access")) return true;
    if (std.mem.eql(u8, native, "system.posix_acl_default")) return true;
    return false;
}

fn transportBare(name: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, name, "user.")) name["user.".len..] else name;
}

fn hasXattr(xattrs: []const metadata.Xattr, class: metadata.XattrClass, name: []const u8) bool {
    for (xattrs) |xattr| {
        if (xattr.class == class and std.mem.eql(u8, xattr.name, name)) return true;
    }
    return false;
}

fn selectEntries(
    allocator: std.mem.Allocator,
    raw: []const directory.Entry,
    rules: []const path_filter.Rule,
) ![]directory.Entry {
    var filter = try path_filter.Filter.compile(allocator, rules);
    defer filter.deinit();
    const selected = try allocator.alloc(bool, raw.len);
    @memset(selected, false);

    for (raw, 0..) |entry, index| {
        if (!try filter.includes(entry.path)) continue;
        selected[index] = true;
        var parent = entry.path;
        while (std.mem.lastIndexOfScalar(u8, parent, '/')) |slash| {
            parent = parent[0..slash];
            const parent_index = findEntry(raw, parent) orelse return error.MissingParent;
            selected[parent_index] = true;
        }
    }

    var output: std.ArrayListUnmanaged(directory.Entry) = .empty;
    for (raw, selected) |entry, include| {
        if (include) try output.append(allocator, entry);
    }
    return output.toOwnedSlice(allocator);
}

fn findEntry(entries: []const directory.Entry, path: []const u8) ?usize {
    var low: usize = 0;
    var high = entries.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        switch (std.mem.order(u8, entries[middle].path, path)) {
            .lt => low = middle + 1,
            .gt => high = middle,
            .eq => return middle,
        }
    }
    return null;
}

fn entryLessThan(_: void, left: directory.Entry, right: directory.Entry) bool {
    return std.mem.order(u8, left.path, right.path) == .lt;
}

/// Access time is omitted on purpose: relatime changes it between reads.
fn modificationMetadata(timestamp: std.Io.Timestamp) metadata.Metadata {
    return .{ .times = .{ .mtime = timeFromTimestamp(timestamp) } };
}

fn timeFromTimestamp(timestamp: std.Io.Timestamp) metadata.Time {
    const scale: i96 = std.time.ns_per_s;
    const seconds = @divFloor(timestamp.nanoseconds, scale);
    const nanoseconds = timestamp.nanoseconds - seconds * scale;
    return .{ .sec = @intCast(seconds), .nsec = @intCast(nanoseconds) };
}

fn timestampFromTime(time: metadata.Time) std.Io.Timestamp {
    return .{ .nanoseconds = @as(i96, time.sec) * std.time.ns_per_s + time.nsec };
}

fn canonicalMode(stat: std.Io.File.Stat, kind: directory.EntryKind) u16 {
    if (comptime builtin.os.tag == .windows) {
        return switch (kind) {
            .directory => 0o755,
            .file => 0o644,
            .symlink => 0o777,
        };
    }
    return @intCast(stat.permissions.toMode() & 0o777);
}

test "filesystem snapshot is sorted binary-safe and does not follow symlinks" {
    var tmp = testing.tmpDir(.{ .iterate = true, .follow_symlinks = false });
    defer tmp.cleanup();
    const io = testing.io;

    try tmp.dir.createDir(io, "empty", .default_dir);
    try tmp.dir.createDir(io, "nested", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "nested/data.bin", .data = "A\x00B\xff" });
    try tmp.dir.writeFile(io, .{ .sub_path = "zeta.txt", .data = "z" });
    try tmp.dir.writeFile(io, .{ .sub_path = "caf\xc3\xa9.txt", .data = "coffee" });
    if (comptime builtin.os.tag != .windows) {
        try tmp.dir.setFilePermissions(
            io,
            "nested/data.bin",
            std.Io.File.Permissions.fromMode(0o640),
            .{ .follow_symlinks = false },
        );
    }
    tmp.dir.symLink(io, "nested", "linked-directory", .{}) catch |err| switch (err) {
        error.AccessDenied => return error.SkipZigTest,
        else => return err,
    };

    var snapshot = try snapshotDir(testing.allocator, io, tmp.dir, &.{});
    defer snapshot.deinit();
    try directory.validateSnapshot(snapshot.entries);

    const expected = [_]struct { path: []const u8, kind: directory.EntryKind, data: []const u8 }{
        .{ .path = "caf\xc3\xa9.txt", .kind = .file, .data = "coffee" },
        .{ .path = "empty", .kind = .directory, .data = "" },
        .{ .path = "linked-directory", .kind = .symlink, .data = "nested" },
        .{ .path = "nested", .kind = .directory, .data = "" },
        .{ .path = "nested/data.bin", .kind = .file, .data = "A\x00B\xff" },
        .{ .path = "zeta.txt", .kind = .file, .data = "z" },
    };
    try testing.expectEqual(expected.len, snapshot.entries.len);
    for (expected, snapshot.entries) |want, got| {
        try testing.expectEqualStrings(want.path, got.path);
        try testing.expectEqual(want.kind, got.kind);
        try testing.expectEqualSlices(u8, want.data, got.data);
    }
    if (comptime builtin.os.tag != .windows) {
        try testing.expectEqual(@as(u16, 0o640), snapshot.entries[4].mode);
    }

    var repeated = try snapshotDir(testing.allocator, io, tmp.dir, &.{});
    defer repeated.deinit();
    try testing.expectEqualSlices(
        u8,
        &(try directory.treeHash(snapshot.entries)),
        &(try directory.treeHash(repeated.entries)),
    );
}

test "filters classify the full set while retaining structural ancestors" {
    var tmp = testing.tmpDir(.{ .iterate = true, .follow_symlinks = false });
    defer tmp.cleanup();
    const io = testing.io;

    try tmp.dir.createDir(io, "excluded", .default_dir);
    try tmp.dir.createDir(io, "excluded/deep", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "excluded/deep/keep.txt", .data = "kept" });
    try tmp.dir.writeFile(io, .{ .sub_path = "excluded/deep/drop.tmp", .data = "dropped" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".hidden", .data = "hidden" });

    const rules = [_]path_filter.Rule{
        .{ .action = .include, .pattern = "excluded/deep/keep.txt" },
        .{ .action = .exclude, .pattern = "**/*.tmp" },
    };
    var snapshot = try snapshotDir(testing.allocator, io, tmp.dir, &rules);
    defer snapshot.deinit();

    try testing.expectEqual(@as(usize, 3), snapshot.entries.len);
    try testing.expectEqualStrings("excluded", snapshot.entries[0].path);
    try testing.expectEqual(directory.EntryKind.directory, snapshot.entries[0].kind);
    try testing.expectEqualStrings("excluded/deep", snapshot.entries[1].path);
    try testing.expectEqual(directory.EntryKind.directory, snapshot.entries[1].kind);
    try testing.expectEqualStrings("excluded/deep/keep.txt", snapshot.entries[2].path);
    try testing.expectEqualStrings("kept", snapshot.entries[2].data);
}

test "snapshot releases every injected allocation failure" {
    var tmp = testing.tmpDir(.{ .iterate = true, .follow_symlinks = false });
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.createDir(io, "parent", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "parent/keep.txt", .data = "content" });
    const rules = [_]path_filter.Rule{
        .{ .action = .include, .pattern = "parent/*.txt" },
    };

    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(
            allocator: std.mem.Allocator,
            test_io: std.Io,
            dir: std.Io.Dir,
            test_rules: []const path_filter.Rule,
        ) !void {
            var snapshot = try snapshotDir(allocator, test_io, dir, test_rules);
            defer snapshot.deinit();
        }
    }.run, .{ io, tmp.dir, &rules });
}

test "filesystem directory patch round-trip is deterministic and staged" {
    var tmp = testing.tmpDir(.{ .iterate = true, .follow_symlinks = false });
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.createDir(io, "source", .default_dir);
    try tmp.dir.createDir(io, "target", .default_dir);
    var source = try tmp.dir.openDir(io, "source", .{ .iterate = true, .follow_symlinks = false });
    defer source.close(io);
    var target = try tmp.dir.openDir(io, "target", .{ .iterate = true, .follow_symlinks = false });
    defer target.close(io);

    try source.createDir(io, "bin", .default_dir);
    try source.writeFile(io, .{ .sub_path = "bin/app", .data = "old application with shared suffix" });
    try source.writeFile(io, .{ .sub_path = "deleted.txt", .data = "gone" });
    try source.writeFile(io, .{ .sub_path = "same.txt", .data = "same" });
    try target.createDir(io, "bin", .default_dir);
    try target.writeFile(io, .{ .sub_path = "bin/app", .data = "new application with shared suffix" });
    try target.createDir(io, "empty", .default_dir);
    try target.writeFile(io, .{ .sub_path = "new.txt", .data = "new" });
    try target.writeFile(io, .{ .sub_path = "same.txt", .data = "same" });
    if (comptime builtin.os.tag != .windows) {
        try target.setFilePermissions(
            io,
            "empty",
            .fromMode(0o711),
            .{ .follow_symlinks = false },
        );
    }
    target.symLink(io, "bin", "current", .{ .is_directory = true }) catch |err| switch (err) {
        error.AccessDenied => {},
        else => return err,
    };

    const first = try createPatchFromDirs(testing.allocator, io, source, target, .{});
    defer testing.allocator.free(first);
    const second = try createPatchFromDirs(testing.allocator, io, source, target, .{});
    defer testing.allocator.free(second);
    try testing.expectEqualSlices(u8, first, second);

    try applyPatchToNewDir(
        testing.allocator,
        io,
        source,
        tmp.dir,
        "output",
        ".output.difz-stage-test",
        first,
        .{},
    );
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, ".output.difz-stage-test", .{}));
    var source_buffer: [16]u8 = undefined;
    try testing.expectEqualStrings(
        "gone",
        try readFileIntoBuffer(io, source, "deleted.txt", &source_buffer),
    );
    var output = try tmp.dir.openDir(io, "output", .{ .iterate = true, .follow_symlinks = false });
    defer output.close(io);
    var expected = try snapshotDir(testing.allocator, io, target, &.{});
    defer expected.deinit();
    var actual = try snapshotDir(testing.allocator, io, output, &.{});
    defer actual.deinit();
    try testing.expectEqualSlices(
        u8,
        &(try directory.treeHash(expected.entries)),
        &(try directory.treeHash(actual.entries)),
    );
}

fn mtimeNanoseconds(seconds: i64, nanoseconds: u32) i96 {
    return @as(i96, seconds) * std.time.ns_per_s + nanoseconds;
}

test "filesystem apply restores last-modification time" {
    var tmp = testing.tmpDir(.{ .iterate = true, .follow_symlinks = false });
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.createDir(io, "source", .default_dir);
    try tmp.dir.createDir(io, "target", .default_dir);
    var source = try tmp.dir.openDir(io, "source", .{ .iterate = true, .follow_symlinks = false });
    defer source.close(io);
    var target = try tmp.dir.openDir(io, "target", .{ .iterate = true, .follow_symlinks = false });
    defer target.close(io);

    try target.createDir(io, "folder", .default_dir);
    try target.writeFile(io, .{ .sub_path = "folder/note.txt", .data = "same" });
    // Directory stamp is older than the child, so a parent updated by create still fails.
    const file_ns = mtimeNanoseconds(1_700_000_000, 123_456_789);
    const directory_ns = mtimeNanoseconds(1_600_000_000, 1);
    try target.setTimestamps(io, "folder/note.txt", .{
        .follow_symlinks = false,
        .modify_timestamp = .{ .new = .{ .nanoseconds = file_ns } },
    });
    try target.setTimestamps(io, "folder", .{
        .follow_symlinks = false,
        .modify_timestamp = .{ .new = .{ .nanoseconds = directory_ns } },
    });
    var link_ns: ?i96 = null;
    if (comptime builtin.os.tag != .windows) {
        try target.symLink(io, "folder/note.txt", "alias", .{});
        link_ns = mtimeNanoseconds(1_500_000_000, 2);
        try target.setTimestamps(io, "alias", .{
            .follow_symlinks = false,
            .modify_timestamp = .{ .new = .{ .nanoseconds = link_ns.? } },
        });
    }

    const patch = try createPatchFromDirs(testing.allocator, io, source, target, .{});
    defer testing.allocator.free(patch);
    try applyPatchToNewDir(
        testing.allocator,
        io,
        source,
        tmp.dir,
        "output",
        ".output.difz-mtime",
        patch,
        .{},
    );

    var output = try tmp.dir.openDir(io, "output", .{ .iterate = true, .follow_symlinks = false });
    defer output.close(io);
    // Stat is the oracle. A metadata hash of two empty records would match
    // even when the applied tree kept "now" as its modification time.
    const file_stat = try output.statFile(io, "folder/note.txt", .{ .follow_symlinks = false });
    try testing.expectEqual(file_ns, file_stat.mtime.nanoseconds);
    const directory_stat = try output.statFile(io, "folder", .{ .follow_symlinks = false });
    try testing.expectEqual(directory_ns, directory_stat.mtime.nanoseconds);
    if (link_ns) |expected_link| {
        const link_stat = try output.statFile(io, "alias", .{ .follow_symlinks = false });
        try testing.expectEqual(expected_link, link_stat.mtime.nanoseconds);
        const note_stat = try output.statFile(io, "folder/note.txt", .{ .follow_symlinks = false });
        try testing.expectEqual(file_ns, note_stat.mtime.nanoseconds);
    }
}

test "filesystem patch rejects wrong sources and staging collisions without partial output" {
    var tmp = testing.tmpDir(.{ .iterate = true, .follow_symlinks = false });
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.createDir(io, "source", .default_dir);
    try tmp.dir.createDir(io, "wrong", .default_dir);
    try tmp.dir.createDir(io, "target", .default_dir);
    var source = try tmp.dir.openDir(io, "source", .{ .iterate = true, .follow_symlinks = false });
    defer source.close(io);
    var wrong = try tmp.dir.openDir(io, "wrong", .{ .iterate = true, .follow_symlinks = false });
    defer wrong.close(io);
    var target = try tmp.dir.openDir(io, "target", .{ .iterate = true, .follow_symlinks = false });
    defer target.close(io);
    try source.writeFile(io, .{ .sub_path = "data", .data = "right" });
    try wrong.writeFile(io, .{ .sub_path = "data", .data = "WRONG" });
    try target.writeFile(io, .{ .sub_path = "data", .data = "new!!" });
    const patch_bytes = try createPatchFromDirs(testing.allocator, io, source, target, .{});
    defer testing.allocator.free(patch_bytes);

    try testing.expectError(error.SourceHashMismatch, applyPatchToNewDir(
        testing.allocator,
        io,
        wrong,
        tmp.dir,
        "output",
        ".output.difz-stage-test",
        patch_bytes,
        .{},
    ));
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "output", .{}));
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, ".output.difz-stage-test", .{}));

    const corrupted = try testing.allocator.dupe(u8, patch_bytes);
    defer testing.allocator.free(corrupted);
    corrupted[88] ^= 1;
    try testing.expectError(error.PatchHashMismatch, applyPatchToNewDir(
        testing.allocator,
        io,
        source,
        tmp.dir,
        "output",
        ".output.difz-stage-test",
        corrupted,
        .{},
    ));
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "output", .{}));
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, ".output.difz-stage-test", .{}));

    try tmp.dir.createDir(io, "existing-output", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "existing-output/sentinel", .data = "preserve" });
    try testing.expectError(error.OutputAlreadyExists, applyPatchToNewDir(
        testing.allocator,
        io,
        source,
        tmp.dir,
        "existing-output",
        ".existing-output.difz-stage-test",
        patch_bytes,
        .{},
    ));
    var output_buffer: [16]u8 = undefined;
    try testing.expectEqualStrings(
        "preserve",
        try readFileIntoBuffer(io, tmp.dir, "existing-output/sentinel", &output_buffer),
    );
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, ".existing-output.difz-stage-test", .{}));

    try tmp.dir.createDir(io, ".output.difz-stage-test", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = ".output.difz-stage-test/owned-by-someone-else", .data = "keep" });
    try testing.expectError(error.PathAlreadyExists, applyPatchToNewDir(
        testing.allocator,
        io,
        source,
        tmp.dir,
        "output",
        ".output.difz-stage-test",
        patch_bytes,
        .{},
    ));
    const preserved = try tmp.dir.readFileAlloc(
        io,
        ".output.difz-stage-test/owned-by-someone-else",
        testing.allocator,
        .limited(16),
    );
    defer testing.allocator.free(preserved);
    try testing.expectEqualStrings("keep", preserved);
}

fn readFileIntoBuffer(io: std.Io, dir: std.Io.Dir, path: []const u8, buffer: []u8) ![]const u8 {
    var file = try dir.openFile(io, path, .{
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    });
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.size > buffer.len) return error.BufferTooSmall;
    var reader = file.reader(io, buffer);
    return try reader.interface.take(@intCast(stat.size));
}

test "staged filesystem apply cleans up every injected allocation failure" {
    var tmp = testing.tmpDir(.{ .iterate = true, .follow_symlinks = false });
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.createDir(io, "source", .default_dir);
    try tmp.dir.createDir(io, "target", .default_dir);
    var source = try tmp.dir.openDir(io, "source", .{ .iterate = true, .follow_symlinks = false });
    defer source.close(io);
    var target = try tmp.dir.openDir(io, "target", .{ .iterate = true, .follow_symlinks = false });
    defer target.close(io);
    try source.writeFile(io, .{ .sub_path = "data", .data = "old payload" });
    try target.createDir(io, "locked", .default_dir);
    try target.writeFile(io, .{ .sub_path = "locked/data", .data = "new payload" });
    if (comptime builtin.os.tag != .windows) {
        try target.setFilePermissions(
            io,
            "locked",
            .fromMode(0o500),
            .{ .follow_symlinks = false },
        );
    }
    const patch_bytes = try createPatchFromDirs(testing.allocator, io, source, target, .{});
    defer testing.allocator.free(patch_bytes);

    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(
            allocator: std.mem.Allocator,
            test_io: std.Io,
            source_dir: std.Io.Dir,
            parent_dir: std.Io.Dir,
            bytes: []const u8,
        ) !void {
            try applyPatchToNewDir(
                allocator,
                test_io,
                source_dir,
                parent_dir,
                "output",
                ".output.difz-stage-allocation-test",
                bytes,
                .{},
            );
            try deleteOwnedTree(test_io, parent_dir, "output");
        }
    }.run, .{ io, source, tmp.dir, patch_bytes });
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "output", .{}));
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, ".output.difz-stage-allocation-test", .{}));
}

test "filesystem snapshot and apply round-trip logical and raw extended attributes" {
    if (comptime builtin.os.tag == .windows) return;
    var tmp = testing.tmpDir(.{ .iterate = true, .follow_symlinks = false });
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.createDir(io, "source", .default_dir);
    try tmp.dir.createDir(io, "target", .default_dir);
    var source = try tmp.dir.openDir(io, "source", .{ .iterate = true, .follow_symlinks = false });
    defer source.close(io);
    var target = try tmp.dir.openDir(io, "target", .{ .iterate = true, .follow_symlinks = false });
    defer target.close(io);
    try source.writeFile(io, .{ .sub_path = "note.txt", .data = "old" });
    try target.writeFile(io, .{ .sub_path = "note.txt", .data = "kept-bytes" });

    var root_buf: [std.posix.PATH_MAX]u8 = undefined;
    const root_len = try target.realPath(io, &root_buf);
    var file_buf: [std.posix.PATH_MAX]u8 = undefined;
    const file_path = std.fmt.bufPrint(&file_buf, "{s}/note.txt", .{root_buf[0..root_len]}) catch return error.NameTooLong;
    const logical = xattr_stream.Options{ .follow_symlinks = false };
    const raw = xattr_stream.Options{ .follow_symlinks = false, .raw_names = true };
    // Nix builds on this machine's ZFS store return EOPNOTSUPP for every
    // setxattr, including on the sandbox tmpfs. Skip there. A host tmpfs and
    // APFS still run the assertions.
    if (!try setXattrOrSkip(file_path, "comment", "kept", logical)) return;
    // macOS stores the Gatekeeper attribute under its real name. Linux raw
    // names need a namespace, and this one is not a logical name.
    const raw_name = if (comptime builtin.os.tag == .macos) "com.apple.quarantine" else "user.com.apple.quarantine";
    const raw_value = "03c1;difz";
    try xattr_stream.set(file_path, raw_name, raw_value, raw);

    var snapshot = try snapshotDir(testing.allocator, io, target, &.{});
    defer snapshot.deinit();
    const note = entryByPath(snapshot.entries, "note.txt") orelse return error.FileNotFound;
    try expectXattr(note.meta, .logical, "comment", "kept");
    try expectXattr(note.meta, .raw, raw_name, raw_value);

    const patch = try createPatchFromDirs(testing.allocator, io, source, target, .{});
    defer testing.allocator.free(patch);
    try applyPatchToNewDir(testing.allocator, io, source, tmp.dir, "output", ".output.difz-stage-xattr", patch, .{});
    var output = try tmp.dir.openDir(io, "output", .{ .iterate = true, .follow_symlinks = false });
    defer output.close(io);
    var out_root_buf: [std.posix.PATH_MAX]u8 = undefined;
    const out_root_len = try output.realPath(io, &out_root_buf);
    var out_file_buf: [std.posix.PATH_MAX]u8 = undefined;
    const out_file = std.fmt.bufPrint(&out_file_buf, "{s}/note.txt", .{out_root_buf[0..out_root_len]}) catch return error.NameTooLong;
    try expectStoredXattr(out_file, "comment", "kept", logical);
    try expectStoredXattr(out_file, raw_name, raw_value, raw);
}

test "filesystem snapshot keeps an extended attribute on the snapshot root" {
    if (comptime builtin.os.tag == .windows) return;
    var tmp = testing.tmpDir(.{ .iterate = true, .follow_symlinks = false });
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.createDir(io, "source", .default_dir);
    try tmp.dir.createDir(io, "target", .default_dir);
    var source = try tmp.dir.openDir(io, "source", .{ .iterate = true, .follow_symlinks = false });
    defer source.close(io);
    var target = try tmp.dir.openDir(io, "target", .{ .iterate = true, .follow_symlinks = false });
    defer target.close(io);
    try source.writeFile(io, .{ .sub_path = "note.txt", .data = "old" });
    try target.writeFile(io, .{ .sub_path = "note.txt", .data = "kept-bytes" });

    var source_buf: [std.posix.PATH_MAX]u8 = undefined;
    const source_len = try source.realPath(io, &source_buf);
    var target_buf: [std.posix.PATH_MAX]u8 = undefined;
    const target_len = try target.realPath(io, &target_buf);
    const logical = xattr_stream.Options{ .follow_symlinks = false };
    const raw = xattr_stream.Options{ .follow_symlinks = false, .raw_names = true };
    const quarantine_name = if (comptime builtin.os.tag == .macos) "com.apple.quarantine" else "user.com.apple.quarantine";
    const quarantine_value = "03c1;difz";
    if (!try setXattrOrSkip(source_buf[0..source_len], "comment", "src", logical)) return;
    try xattr_stream.set(target_buf[0..target_len], "comment", "bundle", logical);
    try xattr_stream.set(target_buf[0..target_len], quarantine_name, quarantine_value, raw);
    if (comptime builtin.os.tag == .macos) {
        try xattr_stream.set(target_buf[0..target_len], "com.apple.provenance", "probe", raw);
        try xattr_stream.set(target_buf[0..target_len], "com.apple.macl", "probe", raw);
    }

    var snapshot = try snapshotDir(testing.allocator, io, target, &.{});
    defer snapshot.deinit();
    try expectXattr(snapshot.root_meta, .logical, "comment", "bundle");
    try expectXattr(snapshot.root_meta, .raw, quarantine_name, quarantine_value);
    if (comptime builtin.os.tag == .macos) {
        try expectXattr(snapshot.root_meta, .raw, "com.apple.provenance", "probe");
        try expectXattr(snapshot.root_meta, .raw, "com.apple.macl", "probe");
    }

    const patch = try createPatchFromDirs(testing.allocator, io, source, target, .{});
    defer testing.allocator.free(patch);
    try applyPatchToNewDir(testing.allocator, io, source, tmp.dir, "output", ".output.difz-stage-root-xattr", patch, .{});
    var output = try tmp.dir.openDir(io, "output", .{ .iterate = true, .follow_symlinks = false });
    defer output.close(io);
    var out_buf: [std.posix.PATH_MAX]u8 = undefined;
    const out_len = try output.realPath(io, &out_buf);
    try expectStoredXattr(out_buf[0..out_len], "comment", "bundle", logical);
    try expectStoredXattr(out_buf[0..out_len], quarantine_name, quarantine_value, raw);
    if (comptime builtin.os.tag == .macos) {
        try expectStoredXattr(out_buf[0..out_len], "com.apple.provenance", "probe", raw);
        try expectStoredXattr(out_buf[0..out_len], "com.apple.macl", "probe", raw);
    }
}

/// False when this filesystem refuses extended attributes. The Nix ZFS
/// sandbox returns EOPNOTSUPP for setxattr. Any other error still fails.
fn setXattrOrSkip(path: []const u8, name: []const u8, value: []const u8, opts: xattr_stream.Options) !bool {
    xattr_stream.set(path, name, value, opts) catch |err| switch (err) {
        error.Unsupported => return false,
        else => return err,
    };
    return true;
}

fn entryByPath(entries: []const directory.Entry, path: []const u8) ?directory.Entry {
    for (entries) |entry| if (std.mem.eql(u8, entry.path, path)) return entry;
    return null;
}

fn expectXattr(meta: metadata.Metadata, class: metadata.XattrClass, name: []const u8, value: []const u8) !void {
    for (meta.xattrs) |xattr| {
        if (xattr.class == class and std.mem.eql(u8, xattr.name, name)) {
            try testing.expectEqualSlices(u8, value, xattr.value);
            return;
        }
    }
    return error.FileNotFound;
}

fn expectStoredXattr(path: []const u8, name: []const u8, value: []const u8, opts: xattr_stream.Options) !void {
    const got = try xattr_stream.get(testing.allocator, path, name, opts);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, value, got);
}
