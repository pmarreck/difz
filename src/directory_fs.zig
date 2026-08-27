const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const directory = @import("directory.zig");
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
            .directory, .symlink => 0o777,
            .file => if (stat.permissions.readOnly()) 0o444 else 0o666,
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
