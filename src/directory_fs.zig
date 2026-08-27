const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const directory = @import("directory.zig");
const directory_patch = @import("directory_patch.zig");
const path_filter = @import("path_filter.zig");

pub const OwnedSnapshot = struct {
    arena: std.heap.ArenaAllocator,
    entries: []directory.Entry,

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
    try walk(arena_allocator, io, root, "", &raw);
    std.mem.sort(directory.Entry, raw.items, {}, entryLessThan);
    try directory.validateSnapshot(raw.items);

    const entries = if (rules.len == 0)
        try raw.toOwnedSlice(arena_allocator)
    else
        try selectEntries(arena_allocator, raw.items, rules);
    try directory.validateSnapshot(entries);
    return .{ .arena = arena, .entries = entries };
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
    return directory_patch.createPatch(
        allocator,
        source_snapshot.entries,
        target_snapshot.entries,
        options,
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
    var reconstructed = try directory_patch.applyPatch(
        allocator,
        source_snapshot.entries,
        patch_bytes,
        limits,
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
    try writeSnapshot(allocator, io, stage, reconstructed.entries);

    var staged_snapshot = try snapshotDir(allocator, io, stage, &.{});
    defer staged_snapshot.deinit();
    const expected_hash = try directory.treeHash(reconstructed.entries);
    const staged_hash = try directory.treeHash(staged_snapshot.entries);
    if (!std.mem.eql(u8, &expected_hash, &staged_hash)) return error.StagedHashMismatch;

    try output_parent.renamePreserve(staging_name, output_parent, output_name, io);
    owns_stage = false;
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
    const target_path = std.mem.trimLeft(u8, resolved, "/");
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
    entries: *std.ArrayListUnmanaged(directory.Entry),
) !void {
    var iterator = current.iterate();
    while (try iterator.next(io)) |item| {
        const path = if (prefix.len == 0)
            try allocator.dupe(u8, item.name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, item.name });
        try directory.validatePath(path);
        const stat = try current.statFile(io, item.name, .{ .follow_symlinks = false });

        switch (stat.kind) {
            .directory => {
                try entries.append(allocator, .{
                    .path = path,
                    .kind = .directory,
                    .mode = canonicalMode(stat, .directory),
                });
                var child = try current.openDir(io, item.name, .{
                    .iterate = true,
                    .follow_symlinks = false,
                });
                defer child.close(io);
                try walk(allocator, io, child, path, entries);
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
                try entries.append(allocator, .{
                    .path = path,
                    .kind = .file,
                    .mode = canonicalMode(opened_stat, .file),
                    .data = data,
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
                });
            },
            else => return error.UnsupportedEntryKind,
        }
    }
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
