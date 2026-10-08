const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const directory = @import("directory.zig");
const directory_patch = @import("directory_patch.zig");
const metadata = @import("metadata.zig");
const symlink_transport = @import("symlink_transport.zig");
const native_stat = @import("native_stat.zig");
const native_acl = @import("native_acl.zig");
const native_finder = @import("native_finder.zig");
const native_sparse = @import("native_sparse.zig");
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

pub const SnapshotOptions = struct {
    rules: []const path_filter.Rule = &.{},
    omit: metadata.Omit = .{},
};

pub fn snapshotDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    options: SnapshotOptions,
) !OwnedSnapshot {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

    var raw: std.ArrayListUnmanaged(directory.Entry) = .empty;
    var root_buf: [std.posix.PATH_MAX]u8 = undefined;
    const root_len = try root.realPath(io, &root_buf);
    try walk(arena_allocator, io, root, "", root_buf[0..root_len], options.omit, &raw);
    std.mem.sort(directory.Entry, raw.items, {}, entryLessThan);
    try directory.validateSnapshot(raw.items);

    const entries = if (options.rules.len == 0)
        try raw.toOwnedSlice(arena_allocator)
    else
        try selectEntries(arena_allocator, raw.items, options.rules);
    try directory.validateSnapshot(entries);
    if (!options.omit.hardlink) try assignHardlinks(arena_allocator, io, root, entries);
    try directory.validateMetadataRelations(entries);
    const root_stat = try root.statFile(io, ".", .{ .follow_symlinks = false });
    const root_birth = if (options.omit.timestamps) null else (try native_stat.read(io, root, ".")).birth;
    const root_meta = try metadataFor(arena_allocator, root_stat.mtime, root_buf[0..root_len], options.omit, root_birth);
    return .{ .arena = arena, .entries = entries, .root_meta = root_meta };
}

pub fn createPatchFromDirs(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: std.Io.Dir,
    target: std.Io.Dir,
    options: directory_patch.CreateOptions,
) ![]u8 {
    var source_snapshot = try snapshotDir(allocator, io, source, .{ .rules = options.rules, .omit = options.omit });
    defer source_snapshot.deinit();
    var target_snapshot = try snapshotDir(allocator, io, target, .{ .rules = options.rules, .omit = options.omit });
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
) !metadata.RestoreReport {
    try validateBasename(output_name);
    try validateBasename(staging_name);
    if (std.mem.eql(u8, output_name, staging_name)) return error.StagingNameConflict;
    if (output_parent.statFile(io, output_name, .{ .follow_symlinks = false })) |_| {
        return error.OutputAlreadyExists;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    var owned_rules = try directory_patch.readOptions(allocator, patch_bytes, limits);
    defer owned_rules.deinit();
    var source_snapshot = try snapshotDir(allocator, io, source, .{ .rules = owned_rules.rules, .omit = owned_rules.omit });
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
    const report = try writeSnapshot(allocator, io, stage, reconstructed.entries, reconstructed.root_meta, owned_rules.omit);

    var staged_snapshot = try snapshotDir(allocator, io, stage, .{ .omit = owned_rules.omit });
    defer staged_snapshot.deinit();
    const expected_hash = try directory.treeHashWithRoot(reconstructed.entries, reconstructed.root_meta);
    const staged_hash = try directory.treeHashWithRoot(staged_snapshot.entries, staged_snapshot.root_meta);
    if (!std.mem.eql(u8, &expected_hash, &staged_hash)) return error.StagedHashMismatch;

    try publishStagingDir(io, output_parent, staging_name, output_name);
    owns_stage = false;
    return report;
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

fn writeSnapshot(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    entries: []const directory.Entry,
    root_meta: metadata.Metadata,
    omit: metadata.Omit,
) !metadata.RestoreReport {
    var report: metadata.RestoreReport = .{};
    try directory.validateSnapshot(entries);
    try directory.validateMetadataRelations(entries);
    for (entries) |entry| {
        switch (entry.kind) {
            .directory => try root.createDir(io, entry.path, writableDirectoryPermissions()),
            .file => {
                if (entry.meta.hardlink_to) |canonical_path| {
                    try root.hardLink(canonical_path, root, entry.path, io, .{ .follow_symlinks = false });
                    continue;
                }
                var file = try root.createFile(io, entry.path, .{
                    .exclusive = true,
                    .permissions = writableFilePermissions(),
                    .resolve_beneath = true,
                });
                defer file.close(io);
                try file.writeStreamingAll(io, entry.data);
            },
            .symlink => try root.symLink(io, entry.data, entry.path, .{
                .is_directory = try symlinkPointsToDirectory(allocator, entries, entry),
            }),
        }
    }
    // Keep objects writable through metadata restore, including parent transport.
    {
        var root_buf: [std.posix.PATH_MAX]u8 = undefined;
        const root_len = try root.realPath(io, &root_buf);
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const temp = arena.allocator();
        var parents: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(symlink_transport.Record)) = .empty;
        for (entries) |entry| {
            var abs_buf: [std.posix.PATH_MAX]u8 = undefined;
            const abs_path = std.fmt.bufPrint(&abs_buf, "{s}/{s}", .{ root_buf[0..root_len], entry.path }) catch return error.NameTooLong;
            const kept_xattrs = try restoreXattrs(temp, abs_path, entry.meta, entry.kind == .symlink, &report);
            if (!omit.sparse and entry.kind == .file) try restoreSparse(temp, io, root, entry, abs_path, &report);
            const keep_birth = !omit.timestamps and try birthNeedsTransport(temp, io, root, entry.path, abs_path, entry.meta.times.btime);
            if (!omit.finder) {
                native_finder.setInfo(abs_path, entry.meta.finder_info) catch {};
                native_finder.setFlags(temp, abs_path, entry.meta.finder_flags) catch |err| if (err == error.OutOfMemory) return err;
            }
            if (entry.kind == .symlink) {
                const keep_mtime = !omit.timestamps and try mtimeNeedsTransport(io, root, entry.path, entry.meta.times.mtime);
                const actual_acl = if (omit.acl) metadata.Metadata{} else try metadata.canonicalize(temp, try native_acl.capture(temp, abs_path), .{});
                const keep_acl = !omit.acl and !std.mem.eql(u8, &metadata.canonicalHash(aclOnly(actual_acl)), &metadata.canonicalHash(aclOnly(entry.meta)));
                const actual_finder = if (omit.finder) metadata.Metadata{} else try native_finder.capture(temp, abs_path);
                const keep_finder = !omit.finder and !std.mem.eql(u8, &metadata.canonicalHash(finderOnly(actual_finder)), &metadata.canonicalHash(finderOnly(entry.meta)));
                const kept: metadata.Metadata = .{
                    .xattrs = kept_xattrs,
                    .aces = if (keep_acl) entry.meta.aces else &.{},
                    .native_acl = if (keep_acl) entry.meta.native_acl else null,
                    .times = .{ .btime = if (keep_birth) entry.meta.times.btime else null, .mtime = if (keep_mtime) entry.meta.times.mtime else null },
                    .finder_info = if (keep_finder) entry.meta.finder_info else null,
                    .finder_flags = if (keep_finder) entry.meta.finder_flags else 0,
                };
                const absent_times: u8 = @as(u8, @intFromBool(keep_mtime and entry.meta.times.mtime == null)) |
                    (@as(u8, @intFromBool(keep_birth and entry.meta.times.btime == null)) << 2);
                if (!kept.isEmpty() or absent_times != 0 or keep_acl or keep_finder) {
                    const parent = if (std.mem.lastIndexOfScalar(u8, entry.path, '/')) |slash| entry.path[0..slash] else "";
                    const name = if (parent.len == 0) entry.path else entry.path[parent.len + 1 ..];
                    const slot = try parents.getOrPut(temp, parent);
                    if (!slot.found_existing) slot.value_ptr.* = .empty;
                    try slot.value_ptr.append(temp, .{ .name = name, .meta = kept, .absent_times = absent_times, .observed_mtime = if (keep_mtime) timeFromTimestamp((try root.statFile(io, entry.path, .{ .follow_symlinks = false })).mtime) else null, .acl_override = keep_acl, .finder_override = keep_finder });
                }
            } else if (keep_birth) {
                try writeTimeOverride(abs_path, "difz.btime", entry.meta.times.btime);
                report.add(.birth_time_preserved);
            }
            if (!omit.acl and entry.kind != .symlink) {
                try restoreAcl(temp, abs_path, entry.meta, &report);
                try root.setFilePermissions(io, entry.path, if (entry.kind == .directory) writableDirectoryPermissions() else writableFilePermissions(), .{ .follow_symlinks = false });
            }
            if (!omit.finder and entry.kind != .symlink) try restoreFinder(temp, abs_path, entry.meta, &report);
        }
        if (root_meta.xattrs.len != 0) {
            _ = try restoreXattrs(temp, root_buf[0..root_len], root_meta, false, &report);
        }
        if (!omit.acl) {
            try restoreAcl(temp, root_buf[0..root_len], root_meta, &report);
            try root.setFilePermissions(io, ".", writableDirectoryPermissions(), .{ .follow_symlinks = false });
        }
        if (!omit.finder) {
            native_finder.setInfo(root_buf[0..root_len], root_meta.finder_info) catch {};
            native_finder.setFlags(temp, root_buf[0..root_len], root_meta.finder_flags) catch |err| if (err == error.OutOfMemory) return err;
            try restoreFinder(temp, root_buf[0..root_len], root_meta, &report);
        }
        if (!omit.timestamps and try birthNeedsTransport(temp, io, root, ".", root_buf[0..root_len], root_meta.times.btime)) {
            try writeTimeOverride(root_buf[0..root_len], "difz.btime", root_meta.times.btime);
            report.add(.birth_time_preserved);
        }
        var it = parents.iterator();
        while (it.next()) |parent| {
            const path = if (parent.key_ptr.len == 0) root_buf[0..root_len] else try std.fmt.allocPrint(temp, "{s}/{s}", .{ root_buf[0..root_len], parent.key_ptr.* });
            const blob = try symlink_transport.encode(temp, parent.value_ptr.items);
            try xattr_stream.set(path, symlink_transport.attribute, blob, logical_xattr_opts);
            report.add(.symlink_metadata_preserved);
        }
    }
    // Preserve coarse timestamps while objects are still writable. chmod
    // changes ctime rather than mtime on the supported POSIX filesystems.
    var index = entries.len;
    while (index > 0) {
        index -= 1;
        const entry = entries[index];
        if (!omit.timestamps and entry.kind != .symlink and try mtimeNeedsTransport(io, root, entry.path, entry.meta.times.mtime)) {
            var abs_buf: [std.posix.PATH_MAX]u8 = undefined;
            var root_buf: [std.posix.PATH_MAX]u8 = undefined;
            const root_len = try root.realPath(io, &root_buf);
            const abs_path = try std.fmt.bufPrint(&abs_buf, "{s}/{s}", .{ root_buf[0..root_len], entry.path });
            try writeModificationOverride(io, root, entry.path, abs_path, entry.meta.times.mtime);
            report.add(.modification_time_preserved);
        }
        if (entry.kind != .symlink) try root.setFilePermissions(io, entry.path, try permissionsForMode(entry.mode, entry.kind), .{ .follow_symlinks = false });
    }
    if (!omit.acl) {
        var root_buf: [std.posix.PATH_MAX]u8 = undefined;
        const root_len = try root.realPath(io, &root_buf);
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        native_acl.restore(arena.allocator(), root_buf[0..root_len], root_meta) catch |err| if (err == error.OutOfMemory) return err;
        // Windows can propagate inheritable ACEs to existing descendants.
        // Restore parent ACLs first, then give each descendant its final ACL.
        for (entries) |entry| {
            if (entry.kind == .symlink) continue;
            const abs_path = try std.fmt.allocPrint(arena.allocator(), "{s}/{s}", .{ root_buf[0..root_len], entry.path });
            native_acl.restore(arena.allocator(), abs_path, entry.meta) catch |err| if (err == error.OutOfMemory) return err;
        }
    }
    if (!omit.timestamps and try mtimeNeedsTransport(io, root, ".", root_meta.times.mtime)) {
        var root_buf: [std.posix.PATH_MAX]u8 = undefined;
        const root_len = try root.realPath(io, &root_buf);
        try writeModificationOverride(io, root, ".", root_buf[0..root_len], root_meta.times.mtime);
        report.add(.modification_time_preserved);
    }
    return report;
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
    omit: metadata.Omit,
    entries: *std.ArrayListUnmanaged(directory.Entry),
) !void {
    const transported = if (omit.bits() == 0x3f) &.{} else try readSymlinkTransport(allocator, io, current, abs_dir);
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
        const birth = if (omit.timestamps) null else (try native_stat.read(io, current, item.name)).birth;
        const meta = try metadataFor(allocator, stat.mtime, abs_path, omit, birth);

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
                try walk(allocator, io, child, path, abs_path, omit, entries);
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
                var file_meta = if (opened_stat.mtime.nanoseconds == stat.mtime.nanoseconds)
                    meta
                else
                    try metadataFor(allocator, opened_stat.mtime, abs_path, omit, birth);
                if (!omit.sparse) file_meta.holes = try readSparse(allocator, io, current, item.name, abs_path, data.len);
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
                var link_meta = meta;
                if (symlink_transport.find(transported, item.name)) |record|
                    link_meta = try mergeSymlinkMetadata(allocator, meta, record, omit);
                try entries.append(allocator, .{
                    .path = path,
                    .kind = .symlink,
                    .mode = 0o777,
                    .data = try allocator.dupe(u8, buffer[0..length]),
                    .meta = link_meta,
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

fn readSymlinkTransport(allocator: std.mem.Allocator, io: std.Io, parent: std.Io.Dir, abs_path: []const u8) ![]const symlink_transport.Record {
    const blob = xattr_stream.get(allocator, abs_path, symlink_transport.attribute, logical_xattr_opts) catch |err| switch (err) {
        error.Missing, error.Unsupported => return &.{},
        else => return err,
    };
    var decoded = try symlink_transport.decode(allocator, blob);
    defer decoded.deinit();
    const records = try allocator.alloc(symlink_transport.Record, decoded.records.len);
    for (decoded.records, records) |record, *target| {
        const stat = parent.statFile(io, record.name, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return error.InvalidTransport,
            else => return err,
        };
        if (stat.kind != .sym_link) return error.InvalidTransport;
        target.* = .{ .name = record.name, .meta = try metadata.canonicalize(allocator, record.meta, .{}), .absent_times = record.absent_times, .observed_mtime = record.observed_mtime, .acl_override = record.acl_override, .finder_override = record.finder_override };
    }
    return records;
}

fn mergeSymlinkMetadata(allocator: std.mem.Allocator, native: metadata.Metadata, record: symlink_transport.Record, omit: metadata.Omit) !metadata.Metadata {
    const kept = record.meta;
    var result = native;
    var attrs: std.ArrayListUnmanaged(metadata.Xattr) = .empty;
    try attrs.appendSlice(allocator, native.xattrs);
    for (kept.xattrs) |attr| if (!hasXattr(attrs.items, attr.class, attr.name)) try attrs.append(allocator, attr);
    result.xattrs = try attrs.toOwnedSlice(allocator);
    if (kept.aces.len != 0) result.aces = kept.aces;
    if (kept.native_acl != null) result.native_acl = kept.native_acl;
    if (record.acl_override) {
        result.aces = kept.aces;
        result.native_acl = kept.native_acl;
    }
    if (std.meta.eql(native.times.mtime, record.observed_mtime)) {
        if (kept.times.mtime != null or record.absent_times & 1 != 0) result.times.mtime = kept.times.mtime;
    }
    if (kept.times.atime != null) result.times.atime = kept.times.atime;
    if (kept.times.btime != null) result.times.btime = kept.times.btime;
    if (record.absent_times & 2 != 0) result.times.atime = null;
    if (record.absent_times & 4 != 0) result.times.btime = null;
    if (kept.finder_flags != 0) result.finder_flags = kept.finder_flags;
    if (kept.finder_info != null) result.finder_info = kept.finder_info;
    if (record.finder_override) {
        result.finder_flags = kept.finder_flags;
        result.finder_info = kept.finder_info;
    }
    return metadata.canonicalize(allocator, result, omit);
}

fn metadataFor(allocator: std.mem.Allocator, timestamp: std.Io.Timestamp, abs_path: []const u8, omit: metadata.Omit, birth: ?metadata.Time) !metadata.Metadata {
    var meta: metadata.Metadata = if (omit.timestamps) .{} else modificationMetadata(timestamp);
    if (!omit.timestamps) {
        meta.times.btime = birth;
        if (try readTimeOverride(allocator, abs_path, "difz.btime")) |override| meta.times.btime = override.value;
        if (try readModificationOverride(allocator, abs_path)) |override| {
            if (std.meta.eql(meta.times.mtime, @as(?metadata.Time, override.observed))) meta.times.mtime = override.original;
        }
    }
    meta.xattrs = if (omit.xattr) &.{} else try readXattrs(allocator, abs_path);
    if (!omit.acl) {
        const acl = try readAcl(allocator, abs_path);
        meta.aces = acl.aces;
        meta.native_acl = acl.native_acl;
    }
    if (!omit.finder) {
        const finder = try readFinder(allocator, abs_path);
        meta.finder_flags = finder.finder_flags;
        meta.finder_info = finder.finder_info;
    }
    return metadata.canonicalize(allocator, meta, .{});
}

fn aclOnly(meta: metadata.Metadata) metadata.Metadata {
    return .{ .aces = meta.aces, .native_acl = meta.native_acl };
}

fn finderOnly(meta: metadata.Metadata) metadata.Metadata {
    return .{ .finder_flags = meta.finder_flags, .finder_info = meta.finder_info };
}

fn readSparse(allocator: std.mem.Allocator, io: std.Io, root: std.Io.Dir, path: []const u8, abs_path: []const u8, size: u64) ![]const metadata.Hole {
    const bytes = xattr_stream.get(allocator, abs_path, "difz.sparse-holes", logical_xattr_opts) catch |err| switch (err) {
        error.Missing, error.Unsupported => return native_sparse.capture(allocator, io, root, path, size),
        else => return err,
    };
    const decoded = try metadata.decodeCanonical(allocator, bytes);
    if (!std.mem.eql(u8, &metadata.canonicalHash(decoded), &metadata.canonicalHash(.{ .holes = decoded.holes }))) return error.InvalidTransport;
    return decoded.holes;
}

fn restoreSparse(allocator: std.mem.Allocator, io: std.Io, root: std.Io.Dir, entry: directory.Entry, abs_path: []const u8, report: *metadata.RestoreReport) !void {
    native_sparse.punch(io, root, entry.path, entry.meta.holes) catch {};
    const actual = try native_sparse.capture(allocator, io, root, entry.path, entry.data.len);
    if (std.mem.eql(u8, &metadata.canonicalHash(.{ .holes = actual }), &metadata.canonicalHash(.{ .holes = entry.meta.holes }))) return;
    const blob = try metadata.encodeCanonical(allocator, .{ .holes = entry.meta.holes });
    try xattr_stream.set(abs_path, "difz.sparse-holes", blob, logical_xattr_opts);
    report.add(.sparse_preserved);
}

fn readFinder(allocator: std.mem.Allocator, path: []const u8) !metadata.Metadata {
    var result = try native_finder.capture(allocator, path);
    for ([_][]const u8{ "difz.bsd-flags", "difz.finder-info" }, 0..) |name, index| {
        const bytes = xattr_stream.get(allocator, path, name, logical_xattr_opts) catch |err| switch (err) {
            error.Missing, error.Unsupported => continue,
            else => return err,
        };
        const decoded = try metadata.decodeCanonical(allocator, bytes);
        var field = metadata.Metadata{};
        if (index == 0) field.finder_flags = decoded.finder_flags else field.finder_info = decoded.finder_info;
        if (!std.mem.eql(u8, &metadata.canonicalHash(decoded), &metadata.canonicalHash(field))) return error.InvalidTransport;
        if (index == 0) result.finder_flags = decoded.finder_flags else result.finder_info = decoded.finder_info;
    }
    return result;
}

fn restoreFinder(allocator: std.mem.Allocator, path: []const u8, meta: metadata.Metadata, report: *metadata.RestoreReport) !void {
    const actual = try native_finder.capture(allocator, path);
    if (actual.finder_flags != meta.finder_flags) {
        const blob = try metadata.encodeCanonical(allocator, .{ .finder_flags = meta.finder_flags });
        try xattr_stream.set(path, "difz.bsd-flags", blob, logical_xattr_opts);
        report.add(.finder_flags_preserved);
    }
    if (!std.meta.eql(actual.finder_info, meta.finder_info)) {
        const blob = try metadata.encodeCanonical(allocator, .{ .finder_info = meta.finder_info });
        try xattr_stream.set(path, "difz.finder-info", blob, logical_xattr_opts);
        report.add(.finder_info_preserved);
    }
}

fn readAcl(allocator: std.mem.Allocator, path: []const u8) !metadata.Metadata {
    var result = try native_acl.capture(allocator, path);
    for ([_][]const u8{ "difz.native-acl", "difz.portable-acl" }, 0..) |name, index| {
        const bytes = xattr_stream.get(allocator, path, name, logical_xattr_opts) catch |err| switch (err) {
            error.Missing, error.Unsupported => continue,
            else => return err,
        };
        const decoded = try metadata.decodeCanonical(allocator, bytes);
        var family = metadata.Metadata{};
        if (index == 0) family.native_acl = decoded.native_acl else family.aces = decoded.aces;
        if (!std.mem.eql(u8, &metadata.canonicalHash(decoded), &metadata.canonicalHash(family))) return error.InvalidTransport;
        if (index == 0) result.native_acl = decoded.native_acl else result.aces = decoded.aces;
    }
    return result;
}

fn restoreAcl(allocator: std.mem.Allocator, path: []const u8, meta: metadata.Metadata, report: *metadata.RestoreReport) !void {
    native_acl.restore(allocator, path, meta) catch |err| if (err == error.OutOfMemory) return err;
    const actual = try metadata.canonicalize(allocator, try native_acl.capture(allocator, path), .{});
    const desired = aclOnly(meta);
    if (!std.mem.eql(u8, &metadata.canonicalHash(.{ .native_acl = actual.native_acl }), &metadata.canonicalHash(.{ .native_acl = desired.native_acl }))) {
        const blob = try metadata.encodeCanonical(allocator, .{ .native_acl = desired.native_acl });
        try xattr_stream.set(path, "difz.native-acl", blob, logical_xattr_opts);
        report.add(.native_acl_preserved);
    }
    if (!std.mem.eql(u8, &metadata.canonicalHash(.{ .aces = actual.aces }), &metadata.canonicalHash(.{ .aces = desired.aces }))) {
        const blob = try metadata.encodeCanonical(allocator, .{ .aces = desired.aces });
        try xattr_stream.set(path, "difz.portable-acl", blob, logical_xattr_opts);
        report.add(.portable_acl_preserved);
    }
}

const TimeOverride = struct { value: ?metadata.Time };

fn readTimeOverride(allocator: std.mem.Allocator, path: []const u8, name: []const u8) !?TimeOverride {
    const bytes = xattr_stream.get(allocator, path, name, logical_xattr_opts) catch |err| switch (err) {
        error.Missing, error.Unsupported => return null,
        else => return err,
    };
    defer allocator.free(bytes);
    return .{ .value = try metadata.decodeTimeOverride(bytes) };
}

fn writeTimeOverride(path: []const u8, name: []const u8, value: ?metadata.Time) !void {
    var buffer: [13]u8 = undefined;
    try xattr_stream.set(path, name, try metadata.encodeTimeOverride(value, &buffer), logical_xattr_opts);
}

fn readModificationOverride(allocator: std.mem.Allocator, path: []const u8) !?metadata.ModificationOverride {
    const bytes = xattr_stream.get(allocator, path, "difz.mtime", logical_xattr_opts) catch |err| switch (err) {
        error.Missing, error.Unsupported => return null,
        else => return err,
    };
    defer allocator.free(bytes);
    return try metadata.decodeModificationOverride(bytes);
}

fn writeModificationOverride(io: std.Io, root: std.Io.Dir, path: []const u8, abs_path: []const u8, original: ?metadata.Time) !void {
    const observed = timeFromTimestamp((try root.statFile(io, path, .{ .follow_symlinks = false })).mtime);
    var buffer: [25]u8 = undefined;
    const bytes = try metadata.encodeModificationOverride(.{ .original = original, .observed = observed }, &buffer);
    try xattr_stream.set(abs_path, "difz.mtime", bytes, logical_xattr_opts);
    // ADS or attribute writes may change mtime; the witness must remain valid.
    try root.setTimestamps(io, path, .{ .follow_symlinks = false, .modify_timestamp = .{ .new = timestampFromTime(observed) } });
}

fn birthNeedsTransport(allocator: std.mem.Allocator, io: std.Io, root: std.Io.Dir, path: []const u8, abs_path: []const u8, desired: ?metadata.Time) !bool {
    if (comptime builtin.os.tag == .linux) return desired != null or (try native_stat.read(io, root, path)).birth != null;
    if (desired) |value| _ = try native_stat.setBirth(allocator, abs_path, value);
    const actual = (try native_stat.read(io, root, path)).birth;
    return !std.meta.eql(desired, actual);
}

fn mtimeNeedsTransport(io: std.Io, root: std.Io.Dir, path: []const u8, desired: ?metadata.Time) !bool {
    if (desired) |value| root.setTimestamps(io, path, .{
        .follow_symlinks = false,
        .modify_timestamp = .{ .new = timestampFromTime(value) },
    }) catch {};
    const actual: ?metadata.Time = timeFromTimestamp((try root.statFile(io, path, .{ .follow_symlinks = false })).mtime);
    return !std.meta.eql(desired, actual);
}

fn restoreXattrs(allocator: std.mem.Allocator, abs_path: []const u8, meta: metadata.Metadata, is_link: bool, report: *metadata.RestoreReport) ![]const metadata.Xattr {
    const os = switch (builtin.os.tag) {
        .macos => metadata.Os.macos,
        .windows => metadata.Os.windows,
        else => metadata.Os.linux,
    };
    var preserved: std.ArrayListUnmanaged(metadata.Xattr) = .empty;
    for (meta.xattrs) |xattr| {
        switch (xattr.class) {
            .logical => xattr_stream.set(abs_path, xattr.name, xattr.value, logical_xattr_opts) catch |err| switch (err) {
                error.Permission, error.Unsupported => {
                    if (!is_link) return error.XattrRestoreFailed;
                    try preserved.append(allocator, xattr);
                },
                else => return error.XattrRestoreFailed,
            },
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
    if (is_link) return preserved.toOwnedSlice(allocator);
    if (preserved.items.len == 0) return &.{};
    const blob = try metadata.encodeCanonical(allocator, .{ .xattrs = preserved.items });
    defer allocator.free(blob);
    xattr_stream.set(abs_path, "difz.raw-xattrs", blob, logical_xattr_opts) catch return error.XattrRestoreFailed;
    report.add(.raw_xattr_preserved);
    return &.{};
}

fn excludedXattr(native: []const u8) bool {
    const bare = transportBare(native);
    if (comptime builtin.os.tag == .macos) {
        if (std.mem.eql(u8, native, "com.apple.FinderInfo")) return true;
    }
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

const FileIdentity = struct { device: u64, inode: u64 };

fn assignHardlinks(allocator: std.mem.Allocator, io: std.Io, root: std.Io.Dir, entries: []directory.Entry) !void {
    var canonical: std.AutoHashMapUnmanaged(FileIdentity, []const u8) = .empty;
    defer canonical.deinit(allocator);
    for (entries) |*entry| {
        if (entry.kind != .file) continue;
        const stat = try root.statFile(io, entry.path, .{ .follow_symlinks = false });
        if (stat.kind != .file) return error.FileChangedDuringSnapshot;
        if (stat.nlink < 2) continue;
        const identity = try fileIdentity(io, root, entry.path);
        const slot = try canonical.getOrPut(allocator, identity);
        if (slot.found_existing) {
            entry.meta.hardlink_to = slot.value_ptr.*;
        } else slot.value_ptr.* = entry.path;
    }
}

/// Inode numbers alone collide across filesystems mounted within a tree.
fn fileIdentity(io: std.Io, root: std.Io.Dir, path: []const u8) !FileIdentity {
    const info = try native_stat.read(io, root, path);
    return .{ .device = info.device, .inode = info.inode };
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

    var snapshot = try snapshotDir(testing.allocator, io, tmp.dir, .{});
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

    var repeated = try snapshotDir(testing.allocator, io, tmp.dir, .{});
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
    var snapshot = try snapshotDir(testing.allocator, io, tmp.dir, .{ .rules = &rules });
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
            var snapshot = try snapshotDir(allocator, test_io, dir, .{ .rules = test_rules });
            defer snapshot.deinit();
        }
    }.run, .{ io, tmp.dir, &rules });
}

test "filesystem directory patch round-trip is deterministic and staged" {
    var tmp = testing.tmpDir(.{ .iterate = true, .follow_symlinks = false });
    defer tmp.cleanup();
    const io = testing.io;
    try requireTransportFs(io, tmp.dir);
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

    _ = try applyPatchToNewDir(
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
    var expected = try snapshotDir(testing.allocator, io, target, .{});
    defer expected.deinit();
    var actual = try snapshotDir(testing.allocator, io, output, .{});
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
    try requireTransportFs(io, tmp.dir);
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
    _ = try applyPatchToNewDir(
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
    try requireTransportFs(io, tmp.dir);
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
            _ = try applyPatchToNewDir(
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

test "filesystem apply reuses stored omission for source and staged capture" {
    var tmp = testing.tmpDir(.{ .iterate = true, .follow_symlinks = false });
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.createDir(io, "source", .default_dir);
    try tmp.dir.createDir(io, "target", .default_dir);
    var source = try tmp.dir.openDir(io, "source", .{ .iterate = true });
    defer source.close(io);
    var target = try tmp.dir.openDir(io, "target", .{ .iterate = true });
    defer target.close(io);
    try source.writeFile(io, .{ .sub_path = "data", .data = "old" });
    try target.writeFile(io, .{ .sub_path = "data", .data = "new" });
    const patch = try createPatchFromDirs(testing.allocator, io, source, target, .{
        .omit = .{ .timestamps = true, .xattr = true },
    });
    defer testing.allocator.free(patch);
    try source.setTimestamps(io, "data", .{ .modify_timestamp = .{ .new = .{ .nanoseconds = 42 } }, .follow_symlinks = false });
    _ = try applyPatchToNewDir(testing.allocator, io, source, tmp.dir, "output", ".omit-stage", patch, .{});
    var output = try tmp.dir.openDir(io, "output", .{ .iterate = true });
    defer output.close(io);
    var buffer: [16]u8 = undefined;
    try testing.expectEqualStrings("new", try readFileIntoBuffer(io, output, "data", &buffer));
}

test "filesystem hardlinks use the first included path and restore one inode" {
    var tmp = testing.tmpDir(.{ .iterate = true, .follow_symlinks = false });
    defer tmp.cleanup();
    const io = testing.io;
    try requireTransportFs(io, tmp.dir);
    try tmp.dir.createDir(io, "source", .default_dir);
    try tmp.dir.createDir(io, "target", .default_dir);
    var source = try tmp.dir.openDir(io, "source", .{ .iterate = true });
    defer source.close(io);
    var target = try tmp.dir.openDir(io, "target", .{ .iterate = true });
    defer target.close(io);
    try target.writeFile(io, .{ .sub_path = "a", .data = "shared" });
    try target.hardLink("a", target, "b", io, .{});
    try target.hardLink("a", target, "c", io, .{});
    try target.writeFile(io, .{ .sub_path = "d", .data = "shared" });
    const rules = [_]path_filter.Rule{.{ .action = .exclude, .pattern = "a" }};
    var snapshot = try snapshotDir(testing.allocator, io, target, .{ .rules = &rules });
    defer snapshot.deinit();
    try testing.expectEqual(@as(usize, 3), snapshot.entries.len);
    try testing.expect(snapshot.entries[0].meta.hardlink_to == null);
    try testing.expectEqualStrings("b", snapshot.entries[1].meta.hardlink_to.?);
    try testing.expect(snapshot.entries[2].meta.hardlink_to == null);
    const patch = try createPatchFromDirs(testing.allocator, io, source, target, .{ .rules = &rules });
    defer testing.allocator.free(patch);
    _ = try applyPatchToNewDir(testing.allocator, io, source, tmp.dir, "output", ".hardlink-stage", patch, .{});
    var output = try tmp.dir.openDir(io, "output", .{ .iterate = true });
    defer output.close(io);
    const b = try output.statFile(io, "b", .{});
    const c = try output.statFile(io, "c", .{});
    const d = try output.statFile(io, "d", .{});
    try testing.expectEqual(b.inode, c.inode);
    try testing.expectEqual(@as(std.Io.File.NLink, 2), b.nlink);
    try testing.expect(b.inode != d.inode);

    const omitted = try createPatchFromDirs(testing.allocator, io, source, target, .{ .omit = .{ .hardlink = true } });
    defer testing.allocator.free(omitted);
    _ = try applyPatchToNewDir(testing.allocator, io, source, tmp.dir, "copies", ".copy-stage", omitted, .{});
    var copies = try tmp.dir.openDir(io, "copies", .{ .iterate = true });
    defer copies.close(io);
    try testing.expect((try copies.statFile(io, "a", .{})).inode != (try copies.statFile(io, "b", .{})).inode);
}

test "snapshot root timestamps and birth time survive verified filesystem apply" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true, .follow_symlinks = false });
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.createDir(io, "source", .default_dir);
    try tmp.dir.createDir(io, "target", .default_dir);
    var source = try tmp.dir.openDir(io, "source", .{ .iterate = true });
    defer source.close(io);
    var target = try tmp.dir.openDir(io, "target", .{ .iterate = true });
    defer target.close(io);
    try target.writeFile(io, .{ .sub_path = "data", .data = "kept" });
    var target_buf: [std.posix.PATH_MAX]u8 = undefined;
    const target_len = try target.realPath(io, &target_buf);
    var birth: [13]u8 = undefined;
    birth[0] = 1;
    std.mem.writeInt(i64, birth[1..9], 7, .little);
    std.mem.writeInt(u32, birth[9..13], 9, .little);
    try setFixtureXattr(target_buf[0..target_len], "difz.btime", &birth, logical_xattr_opts);
    const root_ns: i96 = 42 * std.time.ns_per_s + 3;
    try target.setTimestamps(io, ".", .{ .modify_timestamp = .{ .new = .{ .nanoseconds = root_ns } } });
    var snapshot = try snapshotDir(testing.allocator, io, target, .{});
    defer snapshot.deinit();
    try testing.expectEqualDeep(@as(?metadata.Time, .{ .sec = 42, .nsec = 3 }), snapshot.root_meta.times.mtime);
    try testing.expectEqualDeep(@as(?metadata.Time, .{ .sec = 7, .nsec = 9 }), snapshot.root_meta.times.btime);
    const patch = try createPatchFromDirs(testing.allocator, io, source, target, .{});
    defer testing.allocator.free(patch);
    const report = try applyPatchToNewDir(testing.allocator, io, source, tmp.dir, "output", ".times-stage", patch, .{});
    var output = try tmp.dir.openDir(io, "output", .{ .iterate = true });
    defer output.close(io);
    try testing.expectEqual(root_ns, (try output.statFile(io, ".", .{})).mtime.nanoseconds);
    var actual = try snapshotDir(testing.allocator, io, output, .{});
    defer actual.deinit();
    try testing.expectEqualSlices(u8, &metadata.canonicalHash(snapshot.root_meta), &metadata.canonicalHash(actual.root_meta));
    if (comptime builtin.os.tag == .linux) try testing.expect(report.mask & (1 << 4) != 0);
}

test "unrepresentable mtime is preserved before final readonly permissions" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.createDir(io, "source", .default_dir);
    var source = try tmp.dir.openDir(io, "source", .{ .iterate = true });
    defer source.close(io);
    var source_buf: [std.posix.PATH_MAX]u8 = undefined;
    const source_len = try source.realPath(io, &source_buf);
    try setFixtureXattr(source_buf[0..source_len], "comment", "probe", logical_xattr_opts);
    var baseline = try snapshotDir(testing.allocator, io, source, .{});
    defer baseline.deinit();
    const stamp: metadata.Time = .{ .sec = std.math.maxInt(i64), .nsec = 999_999_999 };
    const entries = [_]directory.Entry{.{ .path = "data", .kind = .file, .mode = 0o400, .data = "kept", .meta = .{ .times = .{ .mtime = stamp } } }};
    const patch = try directory_patch.createPatch(testing.allocator, baseline.entries, &entries, .{
        .source_root = baseline.root_meta,
        .target_root = baseline.root_meta,
    });
    defer testing.allocator.free(patch);
    const report = try applyPatchToNewDir(testing.allocator, io, source, tmp.dir, "output", ".rounded-stage", patch, .{});
    try testing.expect(report.mask & (1 << 9) != 0);
    var output = try tmp.dir.openDir(io, "output", .{ .iterate = true });
    defer output.close(io);
    const stat = try output.statFile(io, "data", .{});
    try testing.expectEqual(@as(u32, 0o400), stat.permissions.toMode() & 0o777);
    try testing.expect(stat.mtime.nanoseconds != timestampFromTime(stamp).nanoseconds);
    var actual = try snapshotDir(testing.allocator, io, output, .{});
    defer actual.deinit();
    try testing.expectEqualDeep(@as(?metadata.Time, stamp), actual.entries[0].meta.times.mtime);
    try testing.expect(actual.entries[0].meta.times.btime == null);
    const source_check = try createPatchFromDirs(testing.allocator, io, output, output, .{});
    defer testing.allocator.free(source_check);
    try output.setTimestamps(io, "data", .{ .modify_timestamp = .{ .new = .{ .nanoseconds = 17 } } });
    try testing.expectError(error.SourceHashMismatch, applyPatchToNewDir(testing.allocator, io, output, tmp.dir, "wrong-source", ".wrong-time-stage", source_check, .{}));
}

test "symlink metadata survives through a parent attribute without changing its target" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const transport = @import("symlink_transport.zig");
    var tmp = testing.tmpDir(.{ .iterate = true, .follow_symlinks = false });
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.createDir(io, "source", .default_dir);
    var source = try tmp.dir.openDir(io, "source", .{ .iterate = true });
    defer source.close(io);
    var source_buf: [std.posix.PATH_MAX]u8 = undefined;
    const source_len = try source.realPath(io, &source_buf);
    try setFixtureXattr(source_buf[0..source_len], "comment", "probe", logical_xattr_opts);
    var baseline = try snapshotDir(testing.allocator, io, source, .{});
    defer baseline.deinit();
    const stamp: metadata.Times = .{ .mtime = .{ .sec = 42 } };
    const link_meta: metadata.Metadata = .{
        .xattrs = &.{.{ .class = .logical, .name = "comment", .value = "on-link" }},
        .native_acl = .{ .origin = .windows, .bytes = "DACL" },
        .times = .{ .mtime = stamp.mtime, .btime = .{ .sec = 1, .nsec = 2 } },
        .finder_info = [_]u8{1} ** 32,
    };
    const entries = [_]directory.Entry{
        .{ .path = "data", .kind = .file, .mode = 0o644, .data = "kept", .meta = .{ .times = stamp } },
        .{ .path = "folder", .kind = .directory, .mode = 0o500, .meta = .{ .times = stamp } },
        .{ .path = "folder/link", .kind = .symlink, .mode = 0o777, .data = "../data", .meta = link_meta },
    };
    const patch = try directory_patch.createPatch(testing.allocator, baseline.entries, &entries, .{
        .source_root = baseline.root_meta,
        .target_root = baseline.root_meta,
    });
    defer testing.allocator.free(patch);
    const report = try applyPatchToNewDir(testing.allocator, io, source, tmp.dir, "output", ".link-stage", patch, .{});
    try testing.expect(report.mask & (1 << 8) != 0);
    try testing.expectEqual(@as(u32, 0), report.mask & ~@as(u32, (1 << 8) | (1 << 4)));
    defer deleteOwnedTree(io, tmp.dir, "output") catch {};
    var output = try tmp.dir.openDir(io, "output", .{ .iterate = true });
    defer output.close(io);
    var snapshot = try snapshotDir(testing.allocator, io, output, .{});
    defer snapshot.deinit();
    try testing.expectEqualSlices(u8, &metadata.canonicalHash(link_meta), &metadata.canonicalHash(snapshot.entries[2].meta));
    try testing.expectEqual(@as(usize, 0), snapshot.entries[0].meta.xattrs.len);
    try testing.expectEqual(@as(usize, 0), snapshot.entries[1].meta.xattrs.len);
    var abs_buf: [std.posix.PATH_MAX]u8 = undefined;
    const abs_len = try output.realPath(io, &abs_buf);
    const parent = try std.fmt.allocPrint(testing.allocator, "{s}/folder", .{abs_buf[0..abs_len]});
    defer testing.allocator.free(parent);
    const blob = try xattr_stream.get(testing.allocator, parent, transport.attribute, logical_xattr_opts);
    defer testing.allocator.free(blob);
    var decoded = try transport.decode(testing.allocator, blob);
    defer decoded.deinit();
    try testing.expectEqual(@as(usize, 1), decoded.records.len);
    try testing.expectEqualStrings("link", decoded.records[0].name);
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(allocator: std.mem.Allocator, test_io: std.Io, source_dir: std.Io.Dir, parent_dir: std.Io.Dir, bytes: []const u8) !void {
            _ = try applyPatchToNewDir(allocator, test_io, source_dir, parent_dir, "allocation", ".allocation-link-stage", bytes, .{});
            try deleteOwnedTree(test_io, parent_dir, "allocation");
        }
    }.run, .{ io, source, tmp.dir, patch });
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, ".allocation-link-stage", .{}));

    const large = try testing.allocator.alloc(u8, symlink_transport.max_bytes);
    defer testing.allocator.free(large);
    @memset(large, 0);
    var too_large = entries;
    too_large[2].meta.xattrs = &.{.{ .class = .logical, .name = "comment", .value = large }};
    const large_patch = try directory_patch.createPatch(testing.allocator, baseline.entries, &too_large, .{
        .source_root = baseline.root_meta,
        .target_root = baseline.root_meta,
    });
    defer testing.allocator.free(large_patch);
    if (comptime builtin.os.tag == .linux) {
        try testing.expectError(error.TransportTooLarge, applyPatchToNewDir(testing.allocator, io, source, tmp.dir, "too-large", ".large-link-stage", large_patch, .{}));
        try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "too-large", .{}));
        try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, ".large-link-stage", .{}));
    }

    const omitted = try directory_patch.createPatch(testing.allocator, baseline.entries, &entries, .{
        .source_root = baseline.root_meta,
        .target_root = baseline.root_meta,
        .omit = .{ .xattr = true, .acl = true, .timestamps = true, .finder = true },
    });
    defer testing.allocator.free(omitted);
    const omitted_report = try applyPatchToNewDir(testing.allocator, io, source, tmp.dir, "omitted", ".omitted-link-stage", omitted, .{});
    defer deleteOwnedTree(io, tmp.dir, "omitted") catch {};
    try testing.expectEqual(@as(u32, 0), omitted_report.mask);
}

test "parent transport rejects missing names and names that are not symlinks" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true, .follow_symlinks = false });
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "file", .data = "kept" });
    var abs_buf: [std.posix.PATH_MAX]u8 = undefined;
    const abs_len = try tmp.dir.realPath(io, &abs_buf);
    const abs_path = abs_buf[0..abs_len];
    for ([_][]const u8{ "file", "missing" }) |name| {
        const blob = try symlink_transport.encode(testing.allocator, &.{.{ .name = name, .meta = .{ .times = .{ .btime = .{ .sec = 1 } } } }});
        defer testing.allocator.free(blob);
        try setFixtureXattr(abs_path, symlink_transport.attribute, blob, logical_xattr_opts);
        try testing.expectError(error.InvalidTransport, snapshotDir(testing.allocator, io, tmp.dir, .{}));
        var ignored = try snapshotDir(testing.allocator, io, tmp.dir, .{ .omit = try metadata.Omit.fromBits(63) });
        ignored.deinit();
    }
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
    try setFixtureXattr(file_path, "comment", "kept", logical);
    // macOS stores the Gatekeeper attribute under its real name. Linux raw
    // names need a namespace, and this one is not a logical name.
    const raw_name = if (comptime builtin.os.tag == .macos) "com.apple.quarantine" else "user.com.apple.quarantine";
    const raw_value = "03c1;difz";
    try xattr_stream.set(file_path, raw_name, raw_value, raw);

    var snapshot = try snapshotDir(testing.allocator, io, target, .{});
    defer snapshot.deinit();
    const note = entryByPath(snapshot.entries, "note.txt") orelse return error.FileNotFound;
    try expectXattr(note.meta, .logical, "comment", "kept");
    try expectXattr(note.meta, .raw, raw_name, raw_value);

    const patch = try createPatchFromDirs(testing.allocator, io, source, target, .{});
    defer testing.allocator.free(patch);
    _ = try applyPatchToNewDir(testing.allocator, io, source, tmp.dir, "output", ".output.difz-stage-xattr", patch, .{});
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
    try setFixtureXattr(source_buf[0..source_len], "comment", "src", logical);
    try xattr_stream.set(target_buf[0..target_len], "comment", "bundle", logical);
    try xattr_stream.set(target_buf[0..target_len], quarantine_name, quarantine_value, raw);
    if (comptime builtin.os.tag == .macos) {
        try xattr_stream.set(target_buf[0..target_len], "com.apple.provenance", "probe", raw);
        try xattr_stream.set(target_buf[0..target_len], "com.apple.macl", "probe", raw);
    }

    var snapshot = try snapshotDir(testing.allocator, io, target, .{});
    defer snapshot.deinit();
    try expectXattr(snapshot.root_meta, .logical, "comment", "bundle");
    try expectXattr(snapshot.root_meta, .raw, quarantine_name, quarantine_value);
    if (comptime builtin.os.tag == .macos) {
        try expectXattr(snapshot.root_meta, .raw, "com.apple.provenance", "probe");
        try expectXattr(snapshot.root_meta, .raw, "com.apple.macl", "probe");
    }

    const patch = try createPatchFromDirs(testing.allocator, io, source, target, .{});
    defer testing.allocator.free(patch);
    _ = try applyPatchToNewDir(testing.allocator, io, source, tmp.dir, "output", ".output.difz-stage-root-xattr", patch, .{});
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

/// A sandbox without xattrs reports a skip. The complete entry point sets
/// DIFZ_REQUIRE_XATTR_TESTS so missing host support fails instead of skipping.
fn requireTransportFs(io: std.Io, dir: std.Io.Dir) !void {
    var buffer: [std.posix.PATH_MAX]u8 = undefined;
    const length = try dir.realPath(io, &buffer);
    try setFixtureXattr(buffer[0..length], "difz.test-probe", "", logical_xattr_opts);
}

fn setFixtureXattr(path: []const u8, name: []const u8, value: []const u8, opts: xattr_stream.Options) !void {
    xattr_stream.set(path, name, value, opts) catch |err| switch (err) {
        error.Unsupported => {
            if (std.c.getenv("DIFZ_REQUIRE_XATTR_TESTS") == null) return error.SkipZigTest;
            return err;
        },
        else => return err,
    };
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

test "Linux access and default ACLs survive create apply and native readback" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = testing.io;
    try requireTransportFs(io, tmp.dir);
    try tmp.dir.createDir(io, "source", .default_dir);
    try tmp.dir.createDir(io, "target", .default_dir);
    var source = try tmp.dir.openDir(io, "source", .{ .iterate = true });
    defer source.close(io);
    var target = try tmp.dir.openDir(io, "target", .{ .iterate = true });
    defer target.close(io);
    try target.writeFile(io, .{ .sub_path = "data", .data = "ACL payload" });
    var buffer: [std.posix.PATH_MAX]u8 = undefined;
    const length = try target.realPath(io, &buffer);
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/data", .{buffer[0..length]});
    defer testing.allocator.free(path);
    const acl = [_]u8{ 2, 0, 0, 0, 1, 0, 7, 0, 255, 255, 255, 255, 2, 0, 4, 0, 123, 0, 0, 0, 4, 0, 5, 0, 255, 255, 255, 255, 16, 0, 5, 0, 255, 255, 255, 255, 32, 0, 0, 0, 255, 255, 255, 255 };
    try setFixtureXattr(path, "system.posix_acl_access", &acl, raw_xattr_opts);
    try setFixtureXattr(buffer[0..length], "system.posix_acl_default", &acl, raw_xattr_opts);
    var snapshot = try snapshotDir(testing.allocator, io, target, .{});
    defer snapshot.deinit();
    const file_meta = snapshot.entries[0].meta;
    try testing.expectEqual(@as(usize, 5), file_meta.aces.len);
    try testing.expectEqualSlices(u8, &acl, (try native_acl.decodeLinux(file_meta.native_acl.?.bytes)).access);
    try testing.expectEqualSlices(u8, &acl, (try native_acl.decodeLinux(snapshot.root_meta.native_acl.?.bytes)).default);
    const patch = try createPatchFromDirs(testing.allocator, io, source, target, .{});
    defer testing.allocator.free(patch);
    const report = try applyPatchToNewDir(testing.allocator, io, source, tmp.dir, "output", ".acl-stage", patch, .{});
    try testing.expectEqual(@as(u32, 0), report.mask & 3);
    var output = try tmp.dir.openDir(io, "output", .{ .iterate = true });
    defer output.close(io);
    const out_len = try output.realPath(io, &buffer);
    try expectStoredXattr(buffer[0..out_len], "system.posix_acl_default", &acl, raw_xattr_opts);
    const out_file = try std.fmt.allocPrint(testing.allocator, "{s}/data", .{buffer[0..out_len]});
    defer testing.allocator.free(out_file);
    try expectStoredXattr(out_file, "system.posix_acl_access", &acl, raw_xattr_opts);
    const omitted = try createPatchFromDirs(testing.allocator, io, source, target, .{ .omit = .{ .acl = true } });
    defer testing.allocator.free(omitted);
    try setFixtureXattr(path, "system.posix_acl_access", &acl, raw_xattr_opts);
    _ = try applyPatchToNewDir(testing.allocator, io, source, tmp.dir, "omitted-acl", ".omit-acl-stage", omitted, .{});
}

test "foreign ACLs retain canonical native and portable records on readonly files and root" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = testing.io;
    try requireTransportFs(io, tmp.dir);
    try tmp.dir.createDir(io, "source", .default_dir);
    var source = try tmp.dir.openDir(io, "source", .{ .iterate = true });
    defer source.close(io);
    const omit: metadata.Omit = .{ .timestamps = true };
    var original = try snapshotDir(testing.allocator, io, source, .{ .omit = omit });
    defer original.deinit();
    const foreign: metadata.Metadata = .{ .native_acl = .{ .origin = .windows, .bytes = "foreign DACL" }, .aces = &.{.{ .tag = .named_user, .name = "foreign-principal", .read = true }} };
    const entries = [_]directory.Entry{.{ .path = "data", .kind = .file, .mode = 0o400, .data = "same", .meta = foreign }};
    const patch = try directory_patch.createPatch(testing.allocator, original.entries, &entries, .{ .omit = omit, .source_root = original.root_meta, .target_root = foreign });
    defer testing.allocator.free(patch);
    const report = try applyPatchToNewDir(testing.allocator, io, source, tmp.dir, "out", ".foreign-stage", patch, .{});
    try testing.expectEqual(@as(u32, 3), report.mask);
    var output = try tmp.dir.openDir(io, "out", .{ .iterate = true });
    defer output.close(io);
    var snapshot = try snapshotDir(testing.allocator, io, output, .{ .omit = omit });
    defer snapshot.deinit();
    try testing.expectEqualSlices(u8, &metadata.canonicalHash(foreign), &metadata.canonicalHash(snapshot.entries[0].meta));
    try testing.expectEqualSlices(u8, &metadata.canonicalHash(foreign), &metadata.canonicalHash(snapshot.root_meta));
    var path: [std.posix.PATH_MAX]u8 = undefined;
    const length = try output.realPath(io, &path);
    const invalid = try metadata.encodeCanonical(testing.allocator, .{ .finder_flags = 1 });
    defer testing.allocator.free(invalid);
    try xattr_stream.set(path[0..length], "difz.native-acl", invalid, logical_xattr_opts);
    try testing.expectError(error.InvalidTransport, snapshotDir(testing.allocator, io, output, .{ .omit = omit }));
    var ignored = try snapshotDir(testing.allocator, io, output, .{ .omit = .{ .timestamps = true, .acl = true } });
    defer ignored.deinit();
    try testing.expect(ignored.root_meta.isEmpty());
}

test "parent transport can override inherited symlink ACL and Finder fields with canonical absence" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const inherited: metadata.Metadata = .{ .native_acl = .{ .origin = .windows, .bytes = "inherited" }, .aces = &.{.{ .tag = .everyone, .read = true }}, .finder_flags = 1, .finder_info = [_]u8{9} ** 32 };
    const record: symlink_transport.Record = .{ .name = "link", .meta = .{}, .acl_override = true, .finder_override = true };
    const bytes = try symlink_transport.encode(testing.allocator, &.{record});
    defer testing.allocator.free(bytes);
    var decoded = try symlink_transport.decode(testing.allocator, bytes);
    defer decoded.deinit();
    const result = try mergeSymlinkMetadata(arena.allocator(), inherited, decoded.records[0], .{});
    try testing.expect(result.isEmpty());
}

test "Finder fields survive foreign restore on readonly files directories symlinks and root" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = testing.io;
    try requireTransportFs(io, tmp.dir);
    try tmp.dir.createDir(io, "source", .default_dir);
    var source = try tmp.dir.openDir(io, "source", .{ .iterate = true });
    defer source.close(io);
    const omit: metadata.Omit = .{ .timestamps = true };
    var original = try snapshotDir(testing.allocator, io, source, .{ .omit = omit });
    defer original.deinit();
    const finder: metadata.Metadata = .{ .finder_flags = 0x8003, .finder_info = [_]u8{42} ** 32 };
    const entries = [_]directory.Entry{
        .{ .path = "dir", .kind = .directory, .mode = 0o500, .meta = finder },
        .{ .path = "dir/data", .kind = .file, .mode = 0o400, .data = "same", .meta = finder },
        .{ .path = "link", .kind = .symlink, .mode = 0o777, .data = "dir/data", .meta = finder },
    };
    const patch = try directory_patch.createPatch(testing.allocator, original.entries, &entries, .{ .omit = omit, .source_root = original.root_meta, .target_root = finder });
    defer testing.allocator.free(patch);
    const report = try applyPatchToNewDir(testing.allocator, io, source, tmp.dir, "out", ".finder-stage", patch, .{});
    try testing.expectEqual(@as(u32, 4 | 8 | 256), report.mask);
    var output = try tmp.dir.openDir(io, "out", .{ .iterate = true });
    defer output.close(io);
    var snapshot = try snapshotDir(testing.allocator, io, output, .{ .omit = omit });
    defer snapshot.deinit();
    for (snapshot.entries) |entry| try testing.expectEqualSlices(u8, &metadata.canonicalHash(finder), &metadata.canonicalHash(entry.meta));
    try testing.expectEqualSlices(u8, &metadata.canonicalHash(finder), &metadata.canonicalHash(snapshot.root_meta));
    const omitted_patch = try directory_patch.createPatch(testing.allocator, original.entries, &entries, .{ .omit = .{ .timestamps = true, .finder = true }, .source_root = original.root_meta, .target_root = finder });
    defer testing.allocator.free(omitted_patch);
    const omitted_report = try applyPatchToNewDir(testing.allocator, io, source, tmp.dir, "omit", ".finder-omit-stage", omitted_patch, .{});
    try testing.expectEqual(@as(u32, 0), omitted_report.mask);
}

test "macOS Finder information is a typed field with native file and root readback" {
    if (comptime builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = testing.io;
    try requireTransportFs(io, tmp.dir);
    try tmp.dir.createDir(io, "source", .default_dir);
    try tmp.dir.createDir(io, "target", .default_dir);
    var source = try tmp.dir.openDir(io, "source", .{ .iterate = true });
    defer source.close(io);
    var target = try tmp.dir.openDir(io, "target", .{ .iterate = true });
    defer target.close(io);
    try target.writeFile(io, .{ .sub_path = "data", .data = "Finder payload" });
    var buffer: [std.posix.PATH_MAX]u8 = undefined;
    const length = try target.realPath(io, &buffer);
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/data", .{buffer[0..length]});
    defer testing.allocator.free(path);
    const info = [_]u8{0} ** 8 ++ [_]u8{ 0x40, 0 } ++ [_]u8{0} ** 22;
    try setFixtureXattr(path, "com.apple.FinderInfo", &info, raw_xattr_opts);
    try setFixtureXattr(buffer[0..length], "com.apple.FinderInfo", &info, raw_xattr_opts);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try native_finder.setFlags(arena.allocator(), path, 0x8001);
    var snapshot = try snapshotDir(testing.allocator, io, target, .{});
    defer snapshot.deinit();
    try testing.expectEqualDeep(@as(?[32]u8, info), snapshot.root_meta.finder_info);
    try testing.expectEqualDeep(@as(?[32]u8, info), snapshot.entries[0].meta.finder_info);
    try testing.expectEqual(@as(u32, 0x8001), snapshot.entries[0].meta.finder_flags & 0x8001);
    try testing.expect(!hasXattr(snapshot.entries[0].meta.xattrs, .raw, "com.apple.FinderInfo"));
    const patch = try createPatchFromDirs(testing.allocator, io, source, target, .{});
    defer testing.allocator.free(patch);
    const report = try applyPatchToNewDir(testing.allocator, io, source, tmp.dir, "out", ".finder-native-stage", patch, .{});
    try testing.expectEqual(@as(u32, 0), report.mask & 12);
    var output = try tmp.dir.openDir(io, "out", .{ .iterate = true });
    defer output.close(io);
    const out_len = try output.realPath(io, &buffer);
    try expectStoredXattr(buffer[0..out_len], "com.apple.FinderInfo", &info, raw_xattr_opts);
}

test "Linux sparse capture and apply preserve physical holes and logical bytes" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = testing.io;
    try requireTransportFs(io, tmp.dir);
    try tmp.dir.createDir(io, "source", .default_dir);
    try tmp.dir.createDir(io, "target", .default_dir);
    var source = try tmp.dir.openDir(io, "source", .{ .iterate = true });
    defer source.close(io);
    var target = try tmp.dir.openDir(io, "target", .{ .iterate = true });
    defer target.close(io);
    var size: u64 = 1024 * 1024;
    var file = try target.createFile(io, "sparse", .{ .read = true });
    defer file.close(io);
    const block = [_]u8{42} ** 4096;
    var first_hole: usize = 0;
    // Grow beyond the volume's allocation unit, without a timing dependency.
    for (0..4) |_| {
        try file.setLength(io, size);
        try file.writePositionalAll(io, &block, 0);
        try file.writePositionalAll(io, &block, size - block.len);
        try file.sync(io);
        first_hole = std.os.linux.lseek(file.handle, 0, 4);
        try testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(first_hole));
        if (first_hole < size) break;
        size *= 4;
    }
    size = (try file.stat(io)).size;
    try testing.expect(first_hole < size);
    const omit: metadata.Omit = .{ .timestamps = true };
    var expected = try snapshotDir(testing.allocator, io, target, .{ .omit = omit });
    defer expected.deinit();
    try testing.expect(expected.entries[0].meta.holes.len > 0);
    try testing.expectEqual(first_hole, expected.entries[0].meta.holes[0].offset);
    const patch = try createPatchFromDirs(testing.allocator, io, source, target, .{ .omit = omit });
    defer testing.allocator.free(patch);
    const report = try applyPatchToNewDir(testing.allocator, io, source, tmp.dir, "out", ".sparse-stage", patch, .{});
    try testing.expectEqual(@as(u32, 0), report.mask & 32);
    var output = try tmp.dir.openDir(io, "out", .{ .iterate = true });
    defer output.close(io);
    var actual = try snapshotDir(testing.allocator, io, output, .{ .omit = omit });
    defer actual.deinit();
    try testing.expectEqualSlices(u8, expected.entries[0].data, actual.entries[0].data);
    try testing.expectEqualDeep(expected.entries[0].meta.holes, actual.entries[0].meta.holes);
    // The kernel's allocated-block count is independent of our extent codec.
    var stat: std.os.linux.Statx = std.mem.zeroes(std.os.linux.Statx);
    try testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(std.os.linux.statx(output.handle, "sparse", 0, .{ .BLOCKS = true, .SIZE = true }, &stat)));
    try testing.expect(stat.mask.BLOCKS and stat.blocks * 512 < size / 2);
}

test "unaligned sparse holes use verified transport before readonly permissions" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = testing.io;
    try requireTransportFs(io, tmp.dir);
    try tmp.dir.createDir(io, "source", .default_dir);
    var source = try tmp.dir.openDir(io, "source", .{ .iterate = true });
    defer source.close(io);
    const omit: metadata.Omit = .{ .timestamps = true };
    var original = try snapshotDir(testing.allocator, io, source, .{ .omit = omit });
    defer original.deinit();
    const holes = [_]metadata.Hole{.{ .offset = 1, .length = 1 }};
    const entries = [_]directory.Entry{.{ .path = "data", .kind = .file, .mode = 0o400, .data = "\x00\x00\x00", .meta = .{ .holes = &holes } }};
    const patch = try directory_patch.createPatch(testing.allocator, original.entries, &entries, .{ .omit = omit, .source_root = original.root_meta });
    defer testing.allocator.free(patch);
    const report = try applyPatchToNewDir(testing.allocator, io, source, tmp.dir, "out", ".sparse-fallback-stage", patch, .{});
    try testing.expectEqual(@as(u32, 32), report.mask);
    var output = try tmp.dir.openDir(io, "out", .{ .iterate = true });
    defer output.close(io);
    var actual = try snapshotDir(testing.allocator, io, output, .{ .omit = omit });
    defer actual.deinit();
    try testing.expectEqualDeep(&holes, actual.entries[0].meta.holes);
    try testing.expectEqualSlices(u8, "\x00\x00\x00", actual.entries[0].data);
    var ignored = try snapshotDir(testing.allocator, io, output, .{ .omit = .{ .timestamps = true, .sparse = true } });
    defer ignored.deinit();
    try testing.expectEqual(@as(usize, 0), ignored.entries[0].meta.holes.len);
}
