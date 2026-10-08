const std = @import("std");
const testing = std.testing;
const metadata = @import("metadata.zig");

pub const EntryKind = enum(u8) {
    directory = 1,
    file = 2,
    symlink = 3,
};

pub const Entry = struct {
    path: []const u8,
    kind: EntryKind,
    mode: u16,
    data: []const u8 = "",
    meta: metadata.Metadata = .{},
};

pub const SnapshotError = error{
    EmptyPath,
    InvalidUtf8,
    AbsolutePath,
    BackslashSeparator,
    NulByte,
    InvalidComponent,
    DrivePrefix,
    PathsNotSorted,
    DuplicatePath,
    MissingParent,
    ParentNotDirectory,
    InvalidMode,
    InvalidEntryData,
    SymlinkEscapesRoot,
    TooManyEntries,
    PathTooLong,
    InvalidHardlinkRelation,
    InvalidSparseExtent,
};

pub const max_entries: usize = 1_000_000;
pub const max_path_bytes: usize = 4096;

pub fn validatePath(path: []const u8) SnapshotError!void {
    if (path.len == 0) return error.EmptyPath;
    if (path.len > max_path_bytes) return error.PathTooLong;
    if (!std.unicode.utf8ValidateSlice(path)) return error.InvalidUtf8;
    if (path[0] == '/') return error.AbsolutePath;
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return error.BackslashSeparator;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.NulByte;
    if (path.len >= 2 and std.ascii.isAlphabetic(path[0]) and path[1] == ':') return error.DrivePrefix;

    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        if (component.len == 0 or
            std.mem.eql(u8, component, ".") or
            std.mem.eql(u8, component, ".."))
        {
            return error.InvalidComponent;
        }
    }
}

pub fn validateSnapshot(entries: []const Entry) SnapshotError!void {
    if (entries.len > max_entries) return error.TooManyEntries;

    for (entries, 0..) |entry, index| {
        try validatePath(entry.path);
        if (entry.mode & ~@as(u16, 0o777) != 0) return error.InvalidMode;
        if (entry.kind == .directory and entry.data.len != 0) return error.InvalidEntryData;
        if (entry.kind == .symlink and entry.mode != 0o777) return error.InvalidMode;
        if (entry.kind == .symlink) try validateSymlinkTarget(entry.path, entry.data);

        if (index > 0) {
            switch (std.mem.order(u8, entries[index - 1].path, entry.path)) {
                .eq => return error.DuplicatePath,
                .gt => return error.PathsNotSorted,
                .lt => {},
            }
        }

        if (std.mem.lastIndexOfScalar(u8, entry.path, '/')) |slash| {
            const parent_path = entry.path[0..slash];
            const parent_index = findPath(entries[0..index], parent_path) orelse return error.MissingParent;
            if (entries[parent_index].kind != .directory) return error.ParentNotDirectory;
        }
    }
}

fn validateSymlinkTarget(link_path: []const u8, target: []const u8) SnapshotError!void {
    if (target.len == 0) return error.InvalidEntryData;
    if (!std.unicode.utf8ValidateSlice(target)) return error.InvalidUtf8;
    if (target[0] == '/') return error.AbsolutePath;
    if (std.mem.indexOfScalar(u8, target, '\\') != null) return error.BackslashSeparator;
    if (std.mem.indexOfScalar(u8, target, 0) != null) return error.NulByte;
    if (target.len >= 2 and std.ascii.isAlphabetic(target[0]) and target[1] == ':') return error.DrivePrefix;

    var depth: usize = std.mem.count(u8, link_path, "/");
    var components = std.mem.splitScalar(u8, target, '/');
    while (components.next()) |component| {
        if (component.len == 0) return error.InvalidComponent;
        if (std.mem.eql(u8, component, ".")) continue;
        if (std.mem.eql(u8, component, "..")) {
            if (depth == 0) return error.SymlinkEscapesRoot;
            depth -= 1;
        } else {
            depth += 1;
        }
    }
}

/// DIFZTREE identity includes every entry's canonical metadata, even when
/// empty. Metadata must already be canonical; this function does not sort it.
pub fn treeHash(entries: []const Entry) SnapshotError![32]u8 {
    return treeHashWithRoot(entries, .{});
}

/// Identity plus the snapshot root. The root is not an entry: an empty
/// path is illegal, and a bundle's quarantine attribute lives on the directory
/// the user opens. An empty root adds no bytes, so existing v2 digests stay put.
pub fn treeHashWithRoot(entries: []const Entry, root: metadata.Metadata) SnapshotError![32]u8 {
    try validateSnapshot(entries);
    try validateMetadataRelations(entries);
    try validateRootMetadata(root);
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update("DIFZTREE-ID\x02");
    hashInt(&hasher, u32, @intCast(entries.len));
    for (entries) |entry| {
        const kind = [_]u8{@intFromEnum(entry.kind)};
        hasher.update(&kind);
        hashInt(&hasher, u16, entry.mode);
        hashInt(&hasher, u32, @intCast(entry.path.len));
        hasher.update(entry.path);
        hashInt(&hasher, u64, @intCast(entry.data.len));
        hasher.update(entry.data);
        const meta_hash = metadata.canonicalHash(entry.meta);
        hasher.update(&meta_hash);
    }
    if (!root.isEmpty()) {
        hasher.update("DIFZTREE-ROOT\x01");
        const root_hash = metadata.canonicalHash(root);
        hasher.update(&root_hash);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

fn findPath(entries: []const Entry, path: []const u8) ?usize {
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

pub fn validateRootMetadata(root: metadata.Metadata) SnapshotError!void {
    if (root.holes.len != 0) return error.InvalidSparseExtent;
    if (root.hardlink_to != null) return error.InvalidHardlinkRelation;
}

/// Requires expanded file bytes. Encoded deltas cannot satisfy this boundary.
pub fn validateMetadataRelations(entries: []const Entry) SnapshotError!void {
    for (entries, 0..) |entry, index| {
        for (entry.meta.holes) |hole| {
            if (entry.kind != .file or hole.length == 0 or hole.offset > entry.data.len or
                hole.length > entry.data.len - hole.offset) return error.InvalidSparseExtent;
            const begin: usize = @intCast(hole.offset);
            const end: usize = begin + @as(usize, @intCast(hole.length));
            for (entry.data[begin..end]) |byte| if (byte != 0) return error.InvalidSparseExtent;
        }
        if (entry.meta.hardlink_to) |path| {
            if (entry.kind != .file) return error.InvalidHardlinkRelation;
            const target_index = findPath(entries[0..index], path) orelse return error.InvalidHardlinkRelation;
            const target = entries[target_index];
            if (target.kind != .file or target.meta.hardlink_to != null or target.mode != entry.mode or
                !std.mem.eql(u8, target.data, entry.data)) return error.InvalidHardlinkRelation;
            var shared_meta = entry.meta;
            shared_meta.hardlink_to = null;
            if (!std.mem.eql(u8, &metadata.canonicalHash(shared_meta), &metadata.canonicalHash(target.meta)))
                return error.InvalidHardlinkRelation;
        }
    }
}

fn hashInt(hasher: *std.crypto.hash.Blake3, comptime T: type, value: T) void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    hasher.update(&bytes);
}

test "directory roots reject metadata reserved for regular files" {
    try testing.expectError(error.InvalidSparseExtent, treeHashWithRoot(&.{}, .{
        .holes = &.{.{ .offset = 0, .length = 1 }},
    }));
    try testing.expectError(error.InvalidHardlinkRelation, treeHashWithRoot(&.{}, .{
        .hardlink_to = "canonical123",
    }));
}

test "hardlink references classify complete snapshot relations" {
    const base = [_]Entry{
        .{ .path = "a", .kind = .file, .mode = 0o644, .data = "same" },
        .{ .path = "b", .kind = .file, .mode = 0o644, .data = "same", .meta = .{ .hardlink_to = "a" } },
    };
    _ = try treeHash(&base);
    for (0..8) |case| {
        var changed = base;
        switch (case) {
            0 => changed[1].meta.hardlink_to = "missing",
            1 => changed[0].meta.hardlink_to = "b",
            2 => changed[1].meta.hardlink_to = "b",
            3 => changed[0].kind = .directory,
            4 => changed[1].data = "diff",
            5 => changed[1].mode = 0o600,
            6 => changed[1].meta.times.mtime = .{ .sec = 1 },
            7 => changed[1].kind = .symlink,
            else => unreachable,
        }
        // Keep the general entry contract valid so this tests the relation.
        if (case == 3) changed[0].data = "";
        if (case == 7) changed[1].mode = 0o777;
        try testing.expectError(error.InvalidHardlinkRelation, treeHash(&changed));
    }
    const chain = base ++ [_]Entry{.{ .path = "c", .kind = .file, .mode = 0o644, .data = "same", .meta = .{ .hardlink_to = "b" } }};
    try testing.expectError(error.InvalidHardlinkRelation, treeHash(&chain));
}

test "sparse extents classify object kind bounds and logical zero bytes" {
    const base = Entry{ .path = "a", .kind = .file, .mode = 0o644, .data = "\x00X", .meta = .{ .holes = &.{.{ .offset = 0, .length = 1 }} } };
    _ = try treeHash(&.{base});
    const bad = [_]metadata.Hole{
        .{ .offset = 1, .length = 1 },
        .{ .offset = 2, .length = 1 },
        .{ .offset = 0, .length = 3 },
        .{ .offset = std.math.maxInt(u64), .length = 2 },
        .{ .offset = 0, .length = 0 },
    };
    for (bad) |hole| {
        var changed = base;
        changed.meta.holes = &.{hole};
        try testing.expectError(error.InvalidSparseExtent, treeHash(&.{changed}));
    }
    var directory_entry = base;
    directory_entry.kind = .directory;
    directory_entry.data = "";
    try testing.expectError(error.InvalidSparseExtent, treeHash(&.{directory_entry}));
}

test "canonical paths classify a representative set" {
    const Case = struct { path: []const u8, valid: bool };
    const cases = [_]Case{
        .{ .path = "a", .valid = true },
        .{ .path = "a/b.txt", .valid = true },
        .{ .path = "café/δ", .valid = true },
        .{ .path = "", .valid = false },
        .{ .path = "/absolute", .valid = false },
        .{ .path = "trailing/", .valid = false },
        .{ .path = "two//components", .valid = false },
        .{ .path = ".", .valid = false },
        .{ .path = "a/./b", .valid = false },
        .{ .path = "..", .valid = false },
        .{ .path = "a/../b", .valid = false },
        .{ .path = "a\\b", .valid = false },
        .{ .path = "C:/drive", .valid = false },
        .{ .path = "c:drive-relative", .valid = false },
        .{ .path = "nul\x00byte", .valid = false },
        .{ .path = "bad\xffutf8", .valid = false },
    };

    for (cases) |case| {
        if (validatePath(case.path)) |_| {
            try testing.expect(case.valid);
        } else |_| {
            try testing.expect(!case.valid);
        }
    }
}

test "snapshots classify sorted hierarchy and entry invariants over sets" {
    const valid = [_]Entry{
        .{ .path = "bin", .kind = .directory, .mode = 0o755 },
        .{ .path = "bin/app", .kind = .file, .mode = 0o755, .data = "app" },
        .{ .path = "current", .kind = .symlink, .mode = 0o777, .data = "bin" },
        .{ .path = "empty", .kind = .directory, .mode = 0o700 },
    };
    const duplicate = [_]Entry{
        .{ .path = "a", .kind = .file, .mode = 0o644, .data = "one" },
        .{ .path = "a", .kind = .file, .mode = 0o644, .data = "two" },
    };
    const unsorted = [_]Entry{
        .{ .path = "b", .kind = .file, .mode = 0o644 },
        .{ .path = "a", .kind = .file, .mode = 0o644 },
    };
    const missing_parent = [_]Entry{
        .{ .path = "a/b", .kind = .file, .mode = 0o644 },
    };
    const non_directory_parent = [_]Entry{
        .{ .path = "a", .kind = .file, .mode = 0o644 },
        .{ .path = "a/b", .kind = .file, .mode = 0o644 },
    };
    const invalid_mode = [_]Entry{
        .{ .path = "a", .kind = .file, .mode = 0o1000 },
    };
    const directory_data = [_]Entry{
        .{ .path = "a", .kind = .directory, .mode = 0o755, .data = "forbidden" },
    };
    const symlink_with_nul = [_]Entry{
        .{ .path = "link", .kind = .symlink, .mode = 0o777, .data = "bad\x00target" },
    };
    const symlink_escape = [_]Entry{
        .{ .path = "link", .kind = .symlink, .mode = 0o777, .data = "../../outside" },
    };
    const absolute_symlink = [_]Entry{
        .{ .path = "link", .kind = .symlink, .mode = 0o777, .data = "/outside" },
    };
    const contained_parent_symlink = [_]Entry{
        .{ .path = "dir", .kind = .directory, .mode = 0o755 },
        .{ .path = "dir/link", .kind = .symlink, .mode = 0o777, .data = "../inside" },
    };
    const Case = struct { entries: []const Entry, valid: bool };
    const cases = [_]Case{
        .{ .entries = &valid, .valid = true },
        .{ .entries = &duplicate, .valid = false },
        .{ .entries = &unsorted, .valid = false },
        .{ .entries = &missing_parent, .valid = false },
        .{ .entries = &non_directory_parent, .valid = false },
        .{ .entries = &invalid_mode, .valid = false },
        .{ .entries = &directory_data, .valid = false },
        .{ .entries = &symlink_with_nul, .valid = false },
        .{ .entries = &symlink_escape, .valid = false },
        .{ .entries = &absolute_symlink, .valid = false },
        .{ .entries = &contained_parent_symlink, .valid = true },
    };

    for (cases) |case| {
        if (validateSnapshot(case.entries)) |_| {
            try testing.expect(case.valid);
        } else |_| {
            try testing.expect(!case.valid);
        }
    }
}

test "tree identity changes with path kind mode and content" {
    const base = [_]Entry{
        .{ .path = "a", .kind = .file, .mode = 0o644, .data = "same-size" },
    };
    const changed_content = [_]Entry{
        .{ .path = "a", .kind = .file, .mode = 0o644, .data = "wrong-one" },
    };
    const changed_mode = [_]Entry{
        .{ .path = "a", .kind = .file, .mode = 0o755, .data = "same-size" },
    };
    const changed_path = [_]Entry{
        .{ .path = "b", .kind = .file, .mode = 0o644, .data = "same-size" },
    };
    const changed_kind = [_]Entry{
        .{ .path = "a", .kind = .symlink, .mode = 0o777, .data = "same-size" },
    };
    const external_b3sum = [_]u8{
        0x93, 0x98, 0x56, 0xf8, 0x23, 0xc6, 0xe8, 0x00,
        0x34, 0x5b, 0x98, 0x97, 0xd2, 0x05, 0xef, 0x2c,
        0x99, 0x37, 0x82, 0x33, 0x3d, 0xb6, 0xb9, 0x0d,
        0xc1, 0xc4, 0x9f, 0x96, 0x67, 0x8f, 0x9c, 0xa8,
    };

    const base_hash = try treeHash(&base);
    try testing.expectEqualSlices(u8, &external_b3sum, &base_hash);
    try testing.expectEqualSlices(u8, &base_hash, &(try treeHash(&base)));
    try testing.expect(!std.mem.eql(u8, &base_hash, &(try treeHash(&changed_content))));
    try testing.expect(!std.mem.eql(u8, &base_hash, &(try treeHash(&changed_mode))));
    try testing.expect(!std.mem.eql(u8, &base_hash, &(try treeHash(&changed_path))));
    try testing.expect(!std.mem.eql(u8, &base_hash, &(try treeHash(&changed_kind))));
}

test "tree identity always includes canonical metadata" {
    const plain = [_]Entry{
        .{ .path = "a", .kind = .file, .mode = 0o644, .data = "same-size" },
    };
    const commented = [_]Entry{
        .{
            .path = "a",
            .kind = .file,
            .mode = 0o644,
            .data = "same-size",
            .meta = .{ .xattrs = &[_]metadata.Xattr{.{ .class = .logical, .name = "comment", .value = "hi" }} },
        },
    };
    try testing.expect(!std.mem.eql(u8, &(try treeHash(&plain)), &(try treeHash(&commented))));
}
