const std = @import("std");
const testing = std.testing;

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

pub fn treeHash(entries: []const Entry) SnapshotError![32]u8 {
    try validateSnapshot(entries);

    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update("DIFZTREE-ID\x01");
    hashInt(&hasher, u32, @intCast(entries.len));
    for (entries) |entry| {
        const kind = [_]u8{@intFromEnum(entry.kind)};
        hasher.update(&kind);
        hashInt(&hasher, u16, entry.mode);
        hashInt(&hasher, u32, @intCast(entry.path.len));
        hasher.update(entry.path);
        hashInt(&hasher, u64, @intCast(entry.data.len));
        hasher.update(entry.data);
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

fn hashInt(hasher: *std.crypto.hash.Blake3, comptime T: type, value: T) void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    hasher.update(&bytes);
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
        0x32, 0x42, 0x80, 0x3f, 0x7d, 0x5d, 0x8a, 0xf6,
        0x41, 0xed, 0xb4, 0x69, 0x0e, 0x65, 0x57, 0xd7,
        0x30, 0xb5, 0x24, 0x6f, 0xb2, 0x70, 0x6a, 0xbd,
        0x68, 0xc8, 0xe8, 0x55, 0x79, 0x5d, 0xa6, 0x19,
    };

    const base_hash = try treeHash(&base);
    try testing.expectEqualSlices(u8, &external_b3sum, &base_hash);
    try testing.expectEqualSlices(u8, &base_hash, &(try treeHash(&base)));
    try testing.expect(!std.mem.eql(u8, &base_hash, &(try treeHash(&changed_content))));
    try testing.expect(!std.mem.eql(u8, &base_hash, &(try treeHash(&changed_mode))));
    try testing.expect(!std.mem.eql(u8, &base_hash, &(try treeHash(&changed_path))));
    try testing.expect(!std.mem.eql(u8, &base_hash, &(try treeHash(&changed_kind))));
}
