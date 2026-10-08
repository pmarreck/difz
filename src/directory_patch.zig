const std = @import("std");
const testing = std.testing;
const directory = @import("directory.zig");
const metadata = @import("metadata.zig");
const zstd_patch = @import("zstd_patch.zig");
const file_patch = @import("patch.zig");
const path_filter = @import("path_filter.zig");

const magic = "DIFZTREE";
const format_version: u16 = 2;
const checksum_offset: usize = 88;
const header_length: usize = 120;
const min_rule_length: usize = 9; // Fixed rule fields and one pattern byte.
const min_entry_length: usize = 41; // Fixed fields, one path byte, and an empty metadata record.
// Bit 0: a canonical metadata record for the snapshot root follows the entries.
// Bits 1..6 store the metadata omission mask; bits 7..31 stay reserved.
const flag_root_metadata: u32 = 1;
const known_flags: u32 = 0x7f;

const Operation = enum(u8) {
    directory = 1,
    symlink = 2,
    file_copy = 3,
    file_raw = 4,
    file_delta = 5,
};

pub const CreateOptions = struct {
    rules: []const path_filter.Rule = &.{},
    omit: metadata.Omit = .{},
    // Canonical metadata for the two snapshot roots. Only the target root is
    // stored; an empty target root leaves the root flag unset.
    source_root: metadata.Metadata = .{},
    target_root: metadata.Metadata = .{},
};

pub const Limits = struct {
    max_patch_bytes: usize = 16 * 1024 * 1024 * 1024,
    max_entries: usize = directory.max_entries,
    max_rules: usize = 4096,
    max_path_bytes: usize = directory.max_path_bytes,
    max_pattern_bytes: usize = 4096,
    max_symlink_bytes: usize = 65_536,
    max_payload_bytes: usize = 8 * 1024 * 1024 * 1024,
    max_output_bytes: usize = 64 * 1024 * 1024 * 1024,
};

pub const OwnedSnapshot = struct {
    arena: std.heap.ArenaAllocator,
    entries: []directory.Entry,
    root_meta: metadata.Metadata = .{},

    pub fn deinit(self: *OwnedSnapshot) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const OwnedOptions = struct {
    arena: std.heap.ArenaAllocator,
    rules: []path_filter.Rule,
    omit: metadata.Omit = .{},

    pub fn deinit(self: *OwnedOptions) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn readOptions(
    allocator: std.mem.Allocator,
    patch_bytes: []const u8,
    limits: Limits,
) !OwnedOptions {
    var decoded = try decodePatch(allocator, patch_bytes, limits);
    defer decoded.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();
    const rules = try arena_allocator.alloc(path_filter.Rule, decoded.rules.len);
    for (decoded.rules, rules) |source, *target| {
        target.* = .{
            .action = source.action,
            .pattern = try arena_allocator.dupe(u8, source.pattern),
        };
    }
    return .{ .arena = arena, .rules = rules, .omit = decoded.omit };
}

pub fn createPatch(
    allocator: std.mem.Allocator,
    source_entries: []const directory.Entry,
    target_entries: []const directory.Entry,
    options: CreateOptions,
) ![]u8 {
    const limits = Limits{};
    try directory.validateSnapshot(source_entries);
    try directory.validateSnapshot(target_entries);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const source = try maskedSnapshot(arena.allocator(), source_entries, options.omit);
    const target = try maskedSnapshot(arena.allocator(), target_entries, options.omit);
    const source_root = try metadata.canonicalize(arena.allocator(), options.source_root, options.omit);
    const target_root = try metadata.canonicalize(arena.allocator(), options.target_root, options.omit);
    if (options.rules.len > limits.max_rules) return error.LimitExceeded;
    if (target.len > limits.max_entries) return error.LimitExceeded;
    if (options.rules.len > 0) {
        var filter = try path_filter.Filter.compile(allocator, options.rules);
        filter.deinit();
    }

    const has_target_root = !target_root.isEmpty();
    const header_flags: u32 = (options.omit.bits() << 1) | @as(u32, @intFromBool(has_target_root));
    const source_hash = try directory.treeHashWithRoot(source, source_root);
    const target_hash = try directory.treeHashWithRoot(target, target_root);
    var output: std.ArrayListUnmanaged(u8) = .empty;
    errdefer output.deinit(allocator);

    try appendBytes(allocator, &output, magic, limits.max_patch_bytes);
    try appendInt(allocator, &output, u16, format_version, limits.max_patch_bytes);
    try appendInt(allocator, &output, u16, format_version, limits.max_patch_bytes);
    try appendInt(allocator, &output, u32, header_flags, limits.max_patch_bytes);
    try appendInt(allocator, &output, u32, @intCast(options.rules.len), limits.max_patch_bytes);
    try appendInt(allocator, &output, u32, @intCast(target.len), limits.max_patch_bytes);
    try appendBytes(allocator, &output, &source_hash, limits.max_patch_bytes);
    try appendBytes(allocator, &output, &target_hash, limits.max_patch_bytes);
    try appendBytes(allocator, &output, &([_]u8{0} ** 32), limits.max_patch_bytes);

    for (options.rules) |rule| {
        if (rule.pattern.len == 0 or rule.pattern.len > limits.max_pattern_bytes) return error.LimitExceeded;
        if (!std.unicode.utf8ValidateSlice(rule.pattern)) return error.InvalidUtf8;
        try appendInt(allocator, &output, u8, @intFromEnum(rule.action), limits.max_patch_bytes);
        try appendInt(allocator, &output, u8, 0, limits.max_patch_bytes);
        try appendInt(allocator, &output, u16, 0, limits.max_patch_bytes);
        try appendInt(allocator, &output, u32, @intCast(rule.pattern.len), limits.max_patch_bytes);
        try appendBytes(allocator, &output, rule.pattern, limits.max_patch_bytes);
    }

    for (target) |entry| {
        var operation: Operation = undefined;
        var payload: []const u8 = "";
        var owned_payload: ?[]u8 = null;
        defer if (owned_payload) |bytes| allocator.free(bytes);

        switch (entry.kind) {
            .directory => operation = .directory,
            .symlink => {
                operation = .symlink;
                payload = entry.data;
                if (payload.len > limits.max_symlink_bytes) return error.LimitExceeded;
            },
            .file => {
                if (findEntry(source, entry.path)) |old| {
                    if (old.kind == .file) {
                        if (std.mem.eql(u8, old.data, entry.data)) {
                            operation = .file_copy;
                        } else {
                            operation = .file_delta;
                            owned_payload = try zstd_patch.encode(allocator, old.data, entry.data);
                            payload = owned_payload.?;
                        }
                    } else {
                        operation = .file_raw;
                        payload = entry.data;
                    }
                } else {
                    operation = .file_raw;
                    payload = entry.data;
                }
                if (payload.len > limits.max_payload_bytes) return error.LimitExceeded;
            },
        }

        try appendInt(allocator, &output, u8, @intFromEnum(operation), limits.max_patch_bytes);
        try appendInt(allocator, &output, u8, 0, limits.max_patch_bytes);
        try appendInt(allocator, &output, u16, entry.mode, limits.max_patch_bytes);
        try appendInt(allocator, &output, u32, @intCast(entry.path.len), limits.max_patch_bytes);
        try appendInt(allocator, &output, u64, @intCast(payload.len), limits.max_patch_bytes);
        try appendBytes(allocator, &output, entry.path, limits.max_patch_bytes);
        try appendBytes(allocator, &output, payload, limits.max_patch_bytes);
        const encoded_meta = try metadata.encodeCanonical(allocator, entry.meta);
        defer allocator.free(encoded_meta);
        if (encoded_meta.len > limits.max_payload_bytes) return error.LimitExceeded;
        try appendInt(allocator, &output, u32, @intCast(encoded_meta.len), limits.max_patch_bytes);
        try appendBytes(allocator, &output, encoded_meta, limits.max_patch_bytes);
    }
    if (has_target_root) {
        const encoded_root = try metadata.encodeCanonical(allocator, target_root);
        defer allocator.free(encoded_root);
        if (encoded_root.len > limits.max_payload_bytes) return error.LimitExceeded;
        try appendInt(allocator, &output, u32, @intCast(encoded_root.len), limits.max_patch_bytes);
        try appendBytes(allocator, &output, encoded_root, limits.max_patch_bytes);
    }

    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update("DIFZTREE-PATCH\x02");
    hasher.update(output.items[0..checksum_offset]);
    hasher.update(output.items[header_length..]);
    var checksum: [32]u8 = undefined;
    hasher.final(&checksum);
    @memcpy(output.items[checksum_offset..header_length], &checksum);
    return output.toOwnedSlice(allocator);
}

pub fn applyPatch(
    allocator: std.mem.Allocator,
    source: []const directory.Entry,
    patch_bytes: []const u8,
    limits: Limits,
) !OwnedSnapshot {
    return applyPatchRoot(allocator, source, patch_bytes, limits, .{});
}

/// Apply a patch whose source hash covers `source_root`. Pass an empty root
/// for a patch that did not record one. The returned snapshot carries the
/// target root from the trailer, when header flag bit 0 is set.
pub fn applyPatchRoot(
    allocator: std.mem.Allocator,
    source: []const directory.Entry,
    patch_bytes: []const u8,
    limits: Limits,
    source_root: metadata.Metadata,
) !OwnedSnapshot {
    var decoded = try decodePatch(allocator, patch_bytes, limits);
    defer decoded.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();
    const masked_source = try maskedSnapshot(arena_allocator, source, decoded.omit);
    const masked_root = try metadata.canonicalize(arena_allocator, source_root, decoded.omit);
    const actual_source_hash = try directory.treeHashWithRoot(masked_source, masked_root);
    if (!std.mem.eql(u8, &actual_source_hash, &decoded.source_hash)) return error.SourceHashMismatch;
    const entries = try arena_allocator.alloc(directory.Entry, decoded.entries.len);
    var output_bytes: usize = 0;
    for (decoded.entries, 0..) |encoded, index| {
        const path = try arena_allocator.dupe(u8, encoded.path);
        var kind: directory.EntryKind = undefined;
        var data: []const u8 = "";
        switch (encoded.operation) {
            .directory => kind = .directory,
            .symlink => {
                kind = .symlink;
                data = try arena_allocator.dupe(u8, encoded.payload);
            },
            .file_raw => {
                kind = .file;
                data = try arena_allocator.dupe(u8, encoded.payload);
            },
            .file_copy => {
                kind = .file;
                const old = findEntry(source, encoded.path) orelse return error.MissingSourceEntry;
                if (old.kind != .file) return error.SourceKindMismatch;
                data = try arena_allocator.dupe(u8, old.data);
            },
            .file_delta => {
                kind = .file;
                const old = findEntry(source, encoded.path) orelse return error.MissingSourceEntry;
                if (old.kind != .file) return error.SourceKindMismatch;
                data = try file_patch.patch(arena_allocator, old.data, encoded.payload);
            },
        }
        if (data.len > limits.max_output_bytes -| output_bytes) return error.LimitExceeded;
        output_bytes += data.len;
        entries[index] = .{
            .path = path,
            .kind = kind,
            .mode = encoded.mode,
            .data = data,
            .meta = try dupeMetadata(arena_allocator, encoded.meta),
        };
    }

    try directory.validateSnapshot(entries);
    const actual_target_hash = try directory.treeHashWithRoot(entries, decoded.target_root);
    if (!std.mem.eql(u8, &actual_target_hash, &decoded.target_hash)) return error.TargetHashMismatch;
    // Finish every arena allocation before copying `arena`. A later alloc can
    // take a chunk that the copied state does not own, and that chunk leaks.
    const root_meta = try dupeMetadata(arena_allocator, decoded.target_root);
    return .{
        .arena = arena,
        .entries = entries,
        .root_meta = root_meta,
    };
}

const EncodedEntry = struct {
    operation: Operation,
    mode: u16,
    path: []const u8,
    payload: []const u8,
    meta: metadata.Metadata = .{},
};

const DecodedPatch = struct {
    arena: std.heap.ArenaAllocator,
    rules: []path_filter.Rule,
    entries: []EncodedEntry,
    source_hash: [32]u8,
    target_hash: [32]u8,
    target_root: metadata.Metadata = .{},
    omit: metadata.Omit,

    fn deinit(self: *DecodedPatch) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

fn decodePatch(allocator: std.mem.Allocator, bytes: []const u8, limits: Limits) !DecodedPatch {
    if (bytes.len > limits.max_patch_bytes) return error.LimitExceeded;
    if (bytes.len < header_length) return error.UnexpectedEndOfInput;
    if (!std.mem.eql(u8, bytes[0..8], magic)) return error.InvalidMagic;

    const patch_version = std.mem.readInt(u16, bytes[8..10], .little);
    if (patch_version != format_version) return error.UnsupportedVersion;
    var expected_checksum: [32]u8 = undefined;
    @memcpy(&expected_checksum, bytes[checksum_offset..header_length]);
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update("DIFZTREE-PATCH\x02");
    hasher.update(bytes[0..checksum_offset]);
    hasher.update(bytes[header_length..]);
    var actual_checksum: [32]u8 = undefined;
    hasher.final(&actual_checksum);
    if (!std.mem.eql(u8, &actual_checksum, &expected_checksum)) return error.PatchHashMismatch;

    var reader = Reader{ .bytes = bytes, .position = 8 };
    if (try reader.readInt(u16) != patch_version) return error.UnsupportedVersion;
    const needed_reader = try reader.readInt(u16);
    if (needed_reader > format_version) return error.ReaderTooOld;
    const header_flags = try reader.readInt(u32);
    if (header_flags & ~known_flags != 0) return error.UnsupportedFlags;
    const omit = try metadata.Omit.fromBits(header_flags >> 1);
    const rule_count = try countToUsize(try reader.readInt(u32), limits.max_rules);
    const entry_count = try countToUsize(try reader.readInt(u32), limits.max_entries);
    var source_hash: [32]u8 = undefined;
    @memcpy(&source_hash, try reader.take(32));
    var target_hash: [32]u8 = undefined;
    @memcpy(&target_hash, try reader.take(32));
    _ = try reader.take(32);

    const body_bytes = bytes.len - reader.position;
    if (rule_count > body_bytes / min_rule_length) return error.UnexpectedEndOfInput;
    const after_rules = body_bytes - rule_count * min_rule_length;
    if (entry_count > after_rules / min_entry_length) return error.UnexpectedEndOfInput;

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();
    const rules = try arena_allocator.alloc(path_filter.Rule, rule_count);
    for (rules) |*rule| {
        const action = std.enums.fromInt(path_filter.Action, try reader.readInt(u8)) orelse return error.InvalidRule;
        if (try reader.readInt(u8) != 0 or try reader.readInt(u16) != 0) return error.InvalidRule;
        const pattern_length = try countToUsize(try reader.readInt(u32), limits.max_pattern_bytes);
        if (pattern_length == 0) return error.InvalidRule;
        const pattern = try reader.take(pattern_length);
        if (!std.unicode.utf8ValidateSlice(pattern)) return error.InvalidUtf8;
        rule.* = .{ .action = action, .pattern = pattern };
    }
    if (rules.len > 0) {
        var filter = try path_filter.Filter.compile(arena_allocator, rules);
        filter.deinit();
    }

    const entries = try arena_allocator.alloc(EncodedEntry, entry_count);
    const snapshot_view = try arena_allocator.alloc(directory.Entry, entry_count);
    for (entries, snapshot_view) |*entry, *view| {
        const operation = std.enums.fromInt(Operation, try reader.readInt(u8)) orelse return error.InvalidOperation;
        if (try reader.readInt(u8) != 0) return error.UnsupportedFlags;
        const mode = try reader.readInt(u16);
        const path_length = try countToUsize(try reader.readInt(u32), limits.max_path_bytes);
        if (path_length == 0) return error.InvalidPath;
        const payload_length_u64 = try reader.readInt(u64);
        if (payload_length_u64 > limits.max_payload_bytes) return error.LimitExceeded;
        const payload_length = std.math.cast(usize, payload_length_u64) orelse return error.LimitExceeded;
        const path = try reader.take(path_length);
        const payload = try reader.take(payload_length);
        const meta_length = try countToUsize(try reader.readInt(u32), limits.max_payload_bytes);
        const meta_bytes = try reader.take(meta_length);
        const meta = try metadata.decodeCanonical(arena_allocator, meta_bytes);
        if (hasOmittedMetadata(meta, omit)) return error.OmittedMetadataPresent;

        const kind: directory.EntryKind = switch (operation) {
            .directory => blk: {
                if (payload.len != 0) return error.InvalidPayload;
                break :blk .directory;
            },
            .symlink => blk: {
                if (payload.len > limits.max_symlink_bytes) return error.LimitExceeded;
                break :blk .symlink;
            },
            .file_copy => blk: {
                if (payload.len != 0) return error.InvalidPayload;
                break :blk .file;
            },
            .file_raw, .file_delta => .file,
        };
        entry.* = .{ .operation = operation, .mode = mode, .path = path, .payload = payload, .meta = meta };
        view.* = .{ .path = path, .kind = kind, .mode = mode, .data = if (kind == .directory) "" else payload, .meta = meta };
    }
    var target_root: metadata.Metadata = .{};
    if (header_flags & flag_root_metadata != 0) {
        const meta_length = try countToUsize(try reader.readInt(u32), limits.max_payload_bytes);
        const meta_bytes = try reader.take(meta_length);
        target_root = try metadata.decodeCanonical(arena_allocator, meta_bytes);
        if (hasOmittedMetadata(target_root, omit)) return error.OmittedMetadataPresent;
        if (target_root.isEmpty()) return error.BadMetadata;
    }
    if (reader.position != bytes.len) return error.TrailingData;
    try directory.validateSnapshot(snapshot_view);

    return .{
        .arena = arena,
        .rules = rules,
        .entries = entries,
        .source_hash = source_hash,
        .target_hash = target_hash,
        .target_root = target_root,
        .omit = omit,
    };
}

fn dupeMetadata(allocator: std.mem.Allocator, meta: metadata.Metadata) !metadata.Metadata {
    const xattrs = try allocator.alloc(metadata.Xattr, meta.xattrs.len);
    for (meta.xattrs, xattrs) |source, *target| {
        target.* = .{
            .class = source.class,
            .name = try allocator.dupe(u8, source.name),
            .value = try allocator.dupe(u8, source.value),
        };
    }
    const aces = try allocator.alloc(metadata.Ace, meta.aces.len);
    for (meta.aces, aces) |source, *target| {
        target.* = .{
            .tag = source.tag,
            .read = source.read,
            .write = source.write,
            .execute = source.execute,
            .name = try allocator.dupe(u8, source.name),
        };
    }
    const native_acl: ?metadata.NativeAcl = if (meta.native_acl) |acl| .{
        .origin = acl.origin,
        .bytes = try allocator.dupe(u8, acl.bytes),
    } else null;
    const holes = try allocator.dupe(metadata.Hole, meta.holes);
    const hardlink_to = if (meta.hardlink_to) |path| try allocator.dupe(u8, path) else null;
    return .{
        .xattrs = xattrs,
        .aces = aces,
        .native_acl = native_acl,
        .times = meta.times,
        .finder_flags = meta.finder_flags,
        .finder_info = meta.finder_info,
        .holes = holes,
        .hardlink_to = hardlink_to,
    };
}

const Reader = struct {
    bytes: []const u8,
    position: usize,

    fn take(self: *Reader, length: usize) ![]const u8 {
        if (length > self.bytes.len -| self.position) return error.UnexpectedEndOfInput;
        const result = self.bytes[self.position..][0..length];
        self.position += length;
        return result;
    }

    fn readInt(self: *Reader, comptime T: type) !T {
        var raw: [@sizeOf(T)]u8 = undefined;
        @memcpy(&raw, try self.take(raw.len));
        return std.mem.readInt(T, &raw, .little);
    }
};

fn maskedSnapshot(allocator: std.mem.Allocator, entries: []const directory.Entry, omit: metadata.Omit) ![]directory.Entry {
    const masked = try allocator.dupe(directory.Entry, entries);
    for (masked) |*entry| entry.meta = try metadata.canonicalize(allocator, entry.meta, omit);
    return masked;
}

fn hasOmittedMetadata(meta: metadata.Metadata, omit: metadata.Omit) bool {
    return (omit.xattr and meta.xattrs.len != 0) or
        (omit.acl and (meta.aces.len != 0 or meta.native_acl != null)) or
        (omit.timestamps and (meta.times.mtime != null or meta.times.atime != null or meta.times.btime != null)) or
        (omit.finder and (meta.finder_flags != 0 or meta.finder_info != null)) or
        (omit.sparse and meta.holes.len != 0) or
        (omit.hardlink and meta.hardlink_to != null);
}

fn appendInt(
    allocator: std.mem.Allocator,
    output: *std.ArrayListUnmanaged(u8),
    comptime T: type,
    value: T,
    limit: usize,
) !void {
    var raw: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &raw, value, .little);
    try appendBytes(allocator, output, &raw, limit);
}

fn appendBytes(
    allocator: std.mem.Allocator,
    output: *std.ArrayListUnmanaged(u8),
    bytes: []const u8,
    limit: usize,
) !void {
    if (bytes.len > limit -| output.items.len) return error.PatchTooLarge;
    try output.appendSlice(allocator, bytes);
}

fn countToUsize(value: anytype, limit: usize) !usize {
    const converted = std.math.cast(usize, value) orelse return error.LimitExceeded;
    if (converted > limit) return error.LimitExceeded;
    return converted;
}

fn findEntry(entries: []const directory.Entry, path: []const u8) ?directory.Entry {
    var low: usize = 0;
    var high = entries.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        switch (std.mem.order(u8, entries[middle].path, path)) {
            .lt => low = middle + 1,
            .gt => high = middle,
            .eq => return entries[middle],
        }
    }
    return null;
}

fn recomputeChecksum(bytes: []u8) void {
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update("DIFZTREE-PATCH\x02");
    hasher.update(bytes[0..checksum_offset]);
    hasher.update(bytes[header_length..]);
    var checksum: [32]u8 = undefined;
    hasher.final(&checksum);
    @memcpy(bytes[checksum_offset..header_length], &checksum);
}

fn replaceUnique(bytes: []u8, old: []const u8, new: []const u8) !void {
    if (old.len != new.len) return error.TestReplacementSizeMismatch;
    const position = std.mem.indexOf(u8, bytes, old) orelse return error.TestPatternMissing;
    if (std.mem.indexOfPos(u8, bytes, position + old.len, old) != null) return error.TestPatternNotUnique;
    @memcpy(bytes[position..][0..new.len], new);
}

fn expectSnapshotsEqual(expected: []const directory.Entry, actual: []const directory.Entry) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |want, got| {
        try testing.expectEqualStrings(want.path, got.path);
        try testing.expectEqual(want.kind, got.kind);
        try testing.expectEqual(want.mode, got.mode);
        try testing.expectEqualSlices(u8, want.data, got.data);
    }
}

const source_fixture = [_]directory.Entry{
    .{ .path = "bin", .kind = .directory, .mode = 0o755 },
    .{ .path = "bin/app", .kind = .file, .mode = 0o755, .data = "old application payload with shared suffix" },
    .{ .path = "delete.txt", .kind = .file, .mode = 0o644, .data = "delete me" },
    .{ .path = "empty-old", .kind = .directory, .mode = 0o755 },
    .{ .path = "link", .kind = .symlink, .mode = 0o777, .data = "delete.txt" },
    .{ .path = "same.txt", .kind = .file, .mode = 0o644, .data = "same bytes" },
};

const target_fixture = [_]directory.Entry{
    .{ .path = "bin", .kind = .directory, .mode = 0o755 },
    .{ .path = "bin/app", .kind = .file, .mode = 0o755, .data = "new application payload with shared suffix" },
    .{ .path = "empty-new", .kind = .directory, .mode = 0o700 },
    .{ .path = "link", .kind = .symlink, .mode = 0o777, .data = "bin/app" },
    .{ .path = "new.txt", .kind = .file, .mode = 0o600, .data = "new file" },
    .{ .path = "same.txt", .kind = .file, .mode = 0o755, .data = "same bytes" },
};

test "every directory patch uses v2 including empty and metadata-free trees" {
    const empty = [_]directory.Entry{};
    const plain = [_]directory.Entry{
        .{ .path = "a", .kind = .file, .mode = 0o644, .data = "data" },
    };
    for ([_][]const directory.Entry{ &empty, &plain }) |target| {
        const bytes = try createPatch(testing.allocator, &empty, target, .{});
        defer testing.allocator.free(bytes);
        try testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, bytes[8..10], .little));
        try testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, bytes[10..12], .little));
        var actual = try applyPatch(testing.allocator, &empty, bytes, .{});
        defer actual.deinit();
        try expectSnapshotsEqual(target, actual.entries);
    }
}

test "directory patch rejects every format version except v2 before allocation" {
    const empty = [_]directory.Entry{};
    const bytes = try createPatch(testing.allocator, &empty, &empty, .{});
    defer testing.allocator.free(bytes);
    for (0..65_536) |version| {
        if (version == 2) continue;
        std.mem.writeInt(u16, bytes[8..10], @intCast(version), .little);
        try testing.expectError(error.UnsupportedVersion, applyPatch(testing.failing_allocator, &empty, bytes, .{}));
    }
}

test "v2 patch round-trips every metadata family" {
    const meta = @import("metadata.zig");
    const info = [_]u8{0x11} ** 32;
    const source = [_]directory.Entry{
        .{ .path = "a.txt", .kind = .file, .mode = 0o644, .data = "same" },
    };
    const target = [_]directory.Entry{
        .{
            .path = "a.txt",
            .kind = .file,
            .mode = 0o644,
            .data = "same",
            .meta = .{
                .xattrs = &[_]meta.Xattr{
                    .{ .class = .logical, .name = "comment", .value = "hi" },
                    .{ .class = .raw, .name = "user.raw", .value = "r" },
                },
                .aces = &[_]meta.Ace{.{ .tag = .owner, .read = true, .write = true }},
                .native_acl = .{ .origin = .windows, .bytes = "DACL" },
                .times = .{ .mtime = .{ .sec = 42, .nsec = 7 }, .btime = .{ .sec = 1, .nsec = 0 } },
                .finder_flags = 0x8000,
                .finder_info = info,
                .holes = &[_]meta.Hole{.{ .offset = 0, .length = 2 }},
            },
        },
        .{
            .path = "b.txt",
            .kind = .file,
            .mode = 0o644,
            .data = "",
            .meta = .{ .hardlink_to = "a.txt" },
        },
    };
    const patch_bytes = try createPatch(testing.allocator, &source, &target, .{});
    defer testing.allocator.free(patch_bytes);
    try testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, patch_bytes[8..10], .little));
    var reconstructed = try applyPatch(testing.allocator, &source, patch_bytes, .{});
    defer reconstructed.deinit();
    const got = reconstructed.entries[0].meta;
    try testing.expectEqual(@as(usize, 2), got.xattrs.len);
    try testing.expectEqualStrings("comment", got.xattrs[0].name);
    try testing.expectEqualStrings("hi", got.xattrs[0].value);
    try testing.expectEqualStrings("user.raw", got.xattrs[1].name);
    try testing.expectEqual(@as(i64, 42), got.times.mtime.?.sec);
    try testing.expectEqual(@as(u32, 7), got.times.mtime.?.nsec);
    try testing.expectEqual(@as(i64, 1), got.times.btime.?.sec);
    try testing.expectEqual(@as(u32, 0x8000), got.finder_flags);
    try testing.expectEqualSlices(u8, &info, &got.finder_info.?);
    try testing.expectEqual(@as(u64, 2), got.holes[0].length);
    try testing.expectEqual(meta.AclOrigin.windows, got.native_acl.?.origin);
    try testing.expectEqualStrings("DACL", got.native_acl.?.bytes);
    try testing.expect(got.aces[0].read and got.aces[0].write);
    try testing.expectEqualStrings("a.txt", reconstructed.entries[1].meta.hardlink_to.?);
    const again = try directory.treeHash(reconstructed.entries);
    try testing.expectEqualSlices(u8, &(try directory.treeHash(&target)), &again);
}

test "v2 patch carries snapshot-root metadata behind a header flag" {
    const meta = @import("metadata.zig");
    const entries = [_]directory.Entry{
        .{ .path = "a.txt", .kind = .file, .mode = 0o644, .data = "same" },
    };
    const root = meta.Metadata{
        .xattrs = &[_]meta.Xattr{
            .{ .class = .logical, .name = "comment", .value = "bundle" },
        },
    };
    const bare = try createPatch(testing.allocator, &entries, &entries, .{});
    defer testing.allocator.free(bare);
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, bare[12..16], .little));

    const patch_bytes = try createPatch(testing.allocator, &entries, &entries, .{
        .target_root = root,
    });
    defer testing.allocator.free(patch_bytes);
    try testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, patch_bytes[8..10], .little));
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, patch_bytes[12..16], .little));

    var reconstructed = try applyPatch(testing.allocator, &entries, patch_bytes, .{});
    defer reconstructed.deinit();
    try testing.expectEqual(@as(usize, 1), reconstructed.root_meta.xattrs.len);
    try testing.expectEqual(meta.XattrClass.logical, reconstructed.root_meta.xattrs[0].class);
    try testing.expectEqualStrings("comment", reconstructed.root_meta.xattrs[0].name);
    try testing.expectEqualStrings("bundle", reconstructed.root_meta.xattrs[0].value);
    const again = try directory.treeHashWithRoot(reconstructed.entries, reconstructed.root_meta);
    try testing.expectEqualSlices(u8, &(try directory.treeHashWithRoot(&entries, root)), &again);
    try testing.expectEqualSlices(u8, &(try directory.treeHash(&entries)), &(try directory.treeHashWithRoot(&entries, .{})));
}

test "v2 source-root metadata is part of the source hash and is not a trailer" {
    const meta = @import("metadata.zig");
    const entries = [_]directory.Entry{
        .{ .path = "a.txt", .kind = .file, .mode = 0o644, .data = "same" },
    };
    const source_root = meta.Metadata{
        .xattrs = &[_]meta.Xattr{
            .{ .class = .logical, .name = "comment", .value = "src" },
        },
    };
    const patch_bytes = try createPatch(testing.allocator, &entries, &entries, .{
        .source_root = source_root,
    });
    defer testing.allocator.free(patch_bytes);
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, patch_bytes[12..16], .little));
    try testing.expectError(error.SourceHashMismatch, applyPatch(testing.allocator, &entries, patch_bytes, .{}));
    var got = try applyPatchRoot(testing.allocator, &entries, patch_bytes, .{}, source_root);
    defer got.deinit();
    try testing.expect(got.root_meta.isEmpty());
}

test "directory patch deterministically reconstructs all baseline operations" {
    const first = try createPatch(testing.allocator, &source_fixture, &target_fixture, .{});
    defer testing.allocator.free(first);
    const second = try createPatch(testing.allocator, &source_fixture, &target_fixture, .{});
    defer testing.allocator.free(second);
    try testing.expectEqualSlices(u8, first, second);
    try testing.expect(first.len > header_length);
    try testing.expectEqualStrings("DIFZTREE", first[0..8]);

    var reconstructed = try applyPatch(testing.allocator, &source_fixture, first, .{});
    defer reconstructed.deinit();
    try expectSnapshotsEqual(&target_fixture, reconstructed.entries);
}

test "wrong same-sized source tree fails before reconstruction" {
    const patch_bytes = try createPatch(testing.allocator, &source_fixture, &target_fixture, .{});
    defer testing.allocator.free(patch_bytes);
    var wrong = source_fixture;
    wrong[1].data = "BAD application payload with shared suffix";
    try testing.expectEqual(source_fixture[1].data.len, wrong[1].data.len);
    try testing.expectError(error.SourceHashMismatch, applyPatch(testing.allocator, &wrong, patch_bytes, .{}));
}

test "every truncation and single-byte mutation is rejected, paired with valid specificity" {
    const patch_bytes = try createPatch(testing.allocator, &source_fixture, &target_fixture, .{});
    defer testing.allocator.free(patch_bytes);

    var valid = try applyPatch(testing.allocator, &source_fixture, patch_bytes, .{});
    valid.deinit();

    for (0..patch_bytes.len) |length| {
        if (applyPatch(testing.allocator, &source_fixture, patch_bytes[0..length], .{})) |result| {
            var unexpected = result;
            unexpected.deinit();
            return error.TruncationAccepted;
        } else |_| {}
    }

    for (patch_bytes, 0..) |_, index| {
        const mutated = try testing.allocator.dupe(u8, patch_bytes);
        defer testing.allocator.free(mutated);
        mutated[index] ^= 1;
        if (applyPatch(testing.allocator, &source_fixture, mutated, .{})) |result| {
            var unexpected = result;
            unexpected.deinit();
            return error.MutationAccepted;
        } else |_| {}
    }
}

test "parser structural guards survive a valid recomputed checksum" {
    const source = [_]directory.Entry{};
    const target = [_]directory.Entry{
        .{ .path = "alpha.txt", .kind = .file, .mode = 0o644, .data = "A" },
        .{ .path = "bravo.txt", .kind = .file, .mode = 0o644, .data = "B" },
    };
    const original = try createPatch(testing.allocator, &source, &target, .{});
    defer testing.allocator.free(original);

    const duplicate = try testing.allocator.dupe(u8, original);
    defer testing.allocator.free(duplicate);
    try replaceUnique(duplicate, "bravo.txt", "alpha.txt");
    recomputeChecksum(duplicate);
    try testing.expectError(error.DuplicatePath, applyPatch(testing.allocator, &source, duplicate, .{}));

    const unsorted = try testing.allocator.dupe(u8, original);
    defer testing.allocator.free(unsorted);
    try replaceUnique(unsorted, "alpha.txt", "zulu0.txt");
    recomputeChecksum(unsorted);
    try testing.expectError(error.PathsNotSorted, applyPatch(testing.allocator, &source, unsorted, .{}));

    const traversal_target = [_]directory.Entry{
        .{ .path = "safe.txt", .kind = .file, .mode = 0o644, .data = "safe" },
    };
    const traversal = try createPatch(testing.allocator, &source, &traversal_target, .{});
    defer testing.allocator.free(traversal);
    try replaceUnique(traversal, "safe.txt", "../x.txt");
    recomputeChecksum(traversal);
    try testing.expectError(error.InvalidComponent, applyPatch(testing.allocator, &source, traversal, .{}));
}

test "version and parser limits reject before output allocation" {
    const empty = [_]directory.Entry{};
    const original = try createPatch(testing.allocator, &empty, &empty, .{});
    defer testing.allocator.free(original);

    const future_format = try testing.allocator.dupe(u8, original);
    defer testing.allocator.free(future_format);
    future_format[8] = 3;
    recomputeChecksum(future_format);
    try testing.expectError(error.UnsupportedVersion, applyPatch(testing.allocator, &empty, future_format, .{}));

    const future_reader = try testing.allocator.dupe(u8, original);
    defer testing.allocator.free(future_reader);
    future_reader[10] = 3;
    recomputeChecksum(future_reader);
    try testing.expectError(error.ReaderTooOld, applyPatch(testing.allocator, &empty, future_reader, .{}));

    const unknown_flags = try testing.allocator.dupe(u8, original);
    defer testing.allocator.free(unknown_flags);
    unknown_flags[12] = 128;
    recomputeChecksum(unknown_flags);
    try testing.expectError(error.UnsupportedFlags, applyPatch(testing.allocator, &empty, unknown_flags, .{}));

    const missing_root = try testing.allocator.dupe(u8, original);
    defer testing.allocator.free(missing_root);
    missing_root[12] = 1;
    recomputeChecksum(missing_root);
    try testing.expectError(error.UnexpectedEndOfInput, applyPatch(testing.allocator, &empty, missing_root, .{}));

    try testing.expectError(
        error.LimitExceeded,
        applyPatch(testing.allocator, &empty, original, .{ .max_patch_bytes = original.len - 1 }),
    );
}

test "empty target and ordered filter rules round-trip" {
    const rules = [_]path_filter.Rule{
        .{ .action = .include, .pattern = "kept/**" },
        .{ .action = .exclude, .pattern = "**/*.tmp" },
    };
    const empty = [_]directory.Entry{};
    const patch_bytes = try createPatch(testing.allocator, &empty, &empty, .{ .rules = &rules });
    defer testing.allocator.free(patch_bytes);
    var decoded = try decodePatch(testing.allocator, patch_bytes, .{});
    defer decoded.deinit();
    try testing.expectEqual(rules.len, decoded.rules.len);
    for (rules, decoded.rules) |expected, actual| {
        try testing.expectEqual(expected.action, actual.action);
        try testing.expectEqualStrings(expected.pattern, actual.pattern);
    }
    var reconstructed = try applyPatch(testing.allocator, &empty, patch_bytes, .{});
    defer reconstructed.deinit();
    try testing.expectEqual(@as(usize, 0), reconstructed.entries.len);
}

test "directory patch create and apply release all allocations on failure" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            const patch_bytes = try createPatch(allocator, &source_fixture, &target_fixture, .{});
            defer allocator.free(patch_bytes);
        }
    }.run, .{});

    const patch_bytes = try createPatch(testing.allocator, &source_fixture, &target_fixture, .{});
    defer testing.allocator.free(patch_bytes);
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(allocator: std.mem.Allocator, bytes: []const u8) !void {
            var reconstructed = try applyPatch(allocator, &source_fixture, bytes, .{});
            defer reconstructed.deinit();
        }
    }.run, .{patch_bytes});
}

test "metadata-bearing patches release all allocations on parser and apply failure" {
    const empty = [_]directory.Entry{};
    const rich: metadata.Metadata = .{
        .xattrs = &.{.{ .class = .logical, .name = "comment", .value = "hi" }},
        .aces = &.{.{ .tag = .owner, .read = true }},
        .native_acl = .{ .origin = .windows, .bytes = "DACL" },
        .times = .{ .mtime = .{ .sec = 42 }, .btime = .{ .sec = 1 } },
        .finder_info = [_]u8{0x11} ** 32,
    };
    const target = [_]directory.Entry{
        .{ .path = "a", .kind = .file, .mode = 0o644, .data = "A", .meta = rich },
        .{ .path = "b", .kind = .file, .mode = 0o644, .data = "B", .meta = rich },
    };
    const bytes = try createPatch(testing.allocator, &empty, &target, .{ .target_root = rich });
    defer testing.allocator.free(bytes);
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(allocator: std.mem.Allocator, patch_bytes: []const u8) !void {
            var restored = try applyPatch(allocator, &empty, patch_bytes, .{});
            defer restored.deinit();
        }
    }.run, .{bytes});

    const truncated = try testing.allocator.dupe(u8, bytes);
    defer testing.allocator.free(truncated);
    for (header_length..bytes.len) |length| {
        recomputeChecksum(truncated[0..length]);
        if (applyPatch(testing.allocator, &empty, truncated[0..length], .{})) |result| {
            var unexpected = result;
            unexpected.deinit();
            return error.TruncationAccepted;
        } else |_| {}
    }
}

test "directory collection counts are bounded by body bytes before allocation" {
    const empty = [_]directory.Entry{};
    const bytes = try createPatch(testing.allocator, &empty, &empty, .{});
    defer testing.allocator.free(bytes);
    for ([_]usize{ 16, 20 }) |offset| {
        std.mem.writeInt(u32, bytes[offset..][0..4], 1, .little);
        recomputeChecksum(bytes);
        try testing.expectError(error.UnexpectedEndOfInput, applyPatch(testing.failing_allocator, &empty, bytes, .{}));
        std.mem.writeInt(u32, bytes[offset..][0..4], 0, .little);
    }
}

test "all metadata omission subsets persist and classify source differences" {
    const families = [_]metadata.Omit{
        .{ .xattr = true },  .{ .acl = true },    .{ .timestamps = true },
        .{ .finder = true }, .{ .sparse = true }, .{ .hardlink = true },
    };
    const rich: metadata.Metadata = .{
        .xattrs = &.{.{ .class = .logical, .name = "comment", .value = "hi" }},
        .aces = &.{.{ .tag = .owner, .read = true }},
        .native_acl = .{ .origin = .windows, .bytes = "DACL" },
        .times = .{ .mtime = .{ .sec = 42 }, .btime = .{ .sec = 1 } },
        .finder_flags = 0x8000,
        .finder_info = [_]u8{0x11} ** 32,
        .holes = &.{.{ .offset = 0, .length = 1 }},
    };
    var base = [_]directory.Entry{
        .{ .path = "a", .kind = .file, .mode = 0o644, .data = "\x00X", .meta = rich },
        .{ .path = "b", .kind = .file, .mode = 0o644, .data = "\x00X", .meta = rich },
    };
    base[1].meta.hardlink_to = "a";
    const root: metadata.Metadata = .{ .xattrs = rich.xattrs };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    for (0..64) |mask| {
        const omit = try metadata.Omit.fromBits(@intCast(mask));
        const bytes = try createPatch(testing.allocator, &base, &base, .{
            .source_root = root,
            .target_root = root,
            .omit = omit,
        });
        defer testing.allocator.free(bytes);
        const flags: u32 = (@as(u32, @intCast(mask)) << 1) | @as(u32, @intFromBool(!omit.xattr));
        try testing.expectEqual(flags, std.mem.readInt(u32, bytes[12..16], .little));
        var scope = try readOptions(testing.allocator, bytes, .{});
        defer scope.deinit();
        try testing.expectEqualDeep(omit, scope.omit);
        var restored = try applyPatchRoot(testing.allocator, &base, bytes, .{}, root);
        defer restored.deinit();
        for (base, restored.entries) |expected, actual| {
            const masked = try metadata.canonicalize(allocator, expected.meta, omit);
            try testing.expectEqualSlices(u8, &metadata.canonicalHash(masked), &metadata.canonicalHash(actual.meta));
        }
        const masked_root = try metadata.canonicalize(allocator, root, omit);
        try testing.expectEqualSlices(u8, &metadata.canonicalHash(masked_root), &metadata.canonicalHash(restored.root_meta));
        for (families, 0..) |family, index| {
            var changed = base;
            for (&changed) |*entry| entry.meta = try metadata.canonicalize(allocator, entry.meta, family);
            const changed_root = try metadata.canonicalize(allocator, root, family);
            if (mask & (@as(usize, 1) << @intCast(index)) != 0) {
                var accepted = try applyPatchRoot(testing.allocator, &changed, bytes, .{}, changed_root);
                accepted.deinit();
            } else {
                try testing.expectError(error.SourceHashMismatch, applyPatchRoot(testing.allocator, &changed, bytes, .{}, changed_root));
            }
        }
    }
}

test "omission flags reject contradictory entry and root payloads" {
    const empty = [_]directory.Entry{};
    const rich: metadata.Metadata = .{
        .xattrs = &.{.{ .class = .logical, .name = "comment", .value = "hi" }},
        .aces = &.{.{ .tag = .owner, .read = true }},
        .times = .{ .mtime = .{ .sec = 1 } },
        .finder_flags = 1,
        .holes = &.{.{ .offset = 0, .length = 1 }},
        .hardlink_to = "a",
    };
    const target = [_]directory.Entry{
        .{ .path = "a", .kind = .file, .mode = 0o644, .data = "\x00" },
        .{ .path = "b", .kind = .file, .mode = 0o644, .data = "\x00", .meta = rich },
    };
    for ([_]bool{ false, true }) |on_root| {
        const bytes = try createPatch(testing.allocator, &empty, if (on_root) &empty else &target, .{
            .target_root = if (on_root) rich else .{},
        });
        defer testing.allocator.free(bytes);
        for (0..6) |index| {
            std.mem.writeInt(u32, bytes[12..16], @as(u32, @intFromBool(on_root)) | (@as(u32, 2) << @intCast(index)), .little);
            recomputeChecksum(bytes);
            try testing.expectError(error.OmittedMetadataPresent, applyPatch(testing.allocator, &empty, bytes, .{}));
        }
    }
}
