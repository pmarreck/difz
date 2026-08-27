const std = @import("std");
const testing = std.testing;
const directory = @import("directory.zig");
const diff_mod = @import("diff.zig");
const encoding = @import("encoding.zig");
const file_patch = @import("patch.zig");
const path_filter = @import("path_filter.zig");

const magic = "DIFZTREE";
const format_version: u16 = 1;
const reader_version: u16 = 1;
const checksum_offset: usize = 88;
const header_length: usize = 120;

const Operation = enum(u8) {
    directory = 1,
    symlink = 2,
    file_copy = 3,
    file_raw = 4,
    file_delta = 5,
};

pub const CreateOptions = struct {
    rules: []const path_filter.Rule = &.{},
    seed: [32]u8 = [_]u8{0} ** 32,
    target_chunk_size: usize = 64,
    compression: encoding.CompressionMode = .none,
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

    pub fn deinit(self: *OwnedSnapshot) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const OwnedRules = struct {
    arena: std.heap.ArenaAllocator,
    rules: []path_filter.Rule,

    pub fn deinit(self: *OwnedRules) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn readRules(
    allocator: std.mem.Allocator,
    patch_bytes: []const u8,
    limits: Limits,
) !OwnedRules {
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
    return .{ .arena = arena, .rules = rules };
}

pub fn createPatch(
    allocator: std.mem.Allocator,
    source: []const directory.Entry,
    target: []const directory.Entry,
    options: CreateOptions,
) ![]u8 {
    const limits = Limits{};
    try directory.validateSnapshot(source);
    try directory.validateSnapshot(target);
    if (options.rules.len > limits.max_rules) return error.LimitExceeded;
    if (target.len > limits.max_entries) return error.LimitExceeded;
    if (options.rules.len > 0) {
        var filter = try path_filter.Filter.compile(allocator, options.rules);
        filter.deinit();
    }

    const source_hash = try directory.treeHash(source);
    const target_hash = try directory.treeHash(target);
    var output: std.ArrayListUnmanaged(u8) = .empty;
    errdefer output.deinit(allocator);

    try appendBytes(allocator, &output, magic, limits.max_patch_bytes);
    try appendInt(allocator, &output, u16, format_version, limits.max_patch_bytes);
    try appendInt(allocator, &output, u16, reader_version, limits.max_patch_bytes);
    try appendInt(allocator, &output, u32, 0, limits.max_patch_bytes);
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
                            const result = try diff_mod.computeDiff(allocator, old.data, entry.data, .{
                                .seed = options.seed,
                                .target_chunk_size = options.target_chunk_size,
                            });
                            defer diff_mod.freeDiffResult(allocator, result);
                            owned_payload = try encoding.encode(allocator, result, options.compression);
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
    }

    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update("DIFZTREE-PATCH\x01");
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
    var decoded = try decodePatch(allocator, patch_bytes, limits);
    defer decoded.deinit();
    const actual_source_hash = try directory.treeHash(source);
    if (!std.mem.eql(u8, &actual_source_hash, &decoded.source_hash)) return error.SourceHashMismatch;

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();
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
        entries[index] = .{ .path = path, .kind = kind, .mode = encoded.mode, .data = data };
    }

    try directory.validateSnapshot(entries);
    const actual_target_hash = try directory.treeHash(entries);
    if (!std.mem.eql(u8, &actual_target_hash, &decoded.target_hash)) return error.TargetHashMismatch;
    return .{ .arena = arena, .entries = entries };
}

const EncodedEntry = struct {
    operation: Operation,
    mode: u16,
    path: []const u8,
    payload: []const u8,
};

const DecodedPatch = struct {
    allocator: std.mem.Allocator,
    rules: []path_filter.Rule,
    entries: []EncodedEntry,
    source_hash: [32]u8,
    target_hash: [32]u8,

    fn deinit(self: *DecodedPatch) void {
        self.allocator.free(self.rules);
        self.allocator.free(self.entries);
        self.* = undefined;
    }
};

fn decodePatch(allocator: std.mem.Allocator, bytes: []const u8, limits: Limits) !DecodedPatch {
    if (bytes.len > limits.max_patch_bytes) return error.LimitExceeded;
    if (bytes.len < header_length) return error.UnexpectedEndOfInput;
    if (!std.mem.eql(u8, bytes[0..8], magic)) return error.InvalidMagic;

    var expected_checksum: [32]u8 = undefined;
    @memcpy(&expected_checksum, bytes[checksum_offset..header_length]);
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update("DIFZTREE-PATCH\x01");
    hasher.update(bytes[0..checksum_offset]);
    hasher.update(bytes[header_length..]);
    var actual_checksum: [32]u8 = undefined;
    hasher.final(&actual_checksum);
    if (!std.mem.eql(u8, &actual_checksum, &expected_checksum)) return error.PatchHashMismatch;

    var reader = Reader{ .bytes = bytes, .position = 8 };
    if (try reader.readInt(u16) != format_version) return error.UnsupportedVersion;
    if (try reader.readInt(u16) > reader_version) return error.ReaderTooOld;
    if (try reader.readInt(u32) != 0) return error.UnsupportedFlags;
    const rule_count = try countToUsize(try reader.readInt(u32), limits.max_rules);
    const entry_count = try countToUsize(try reader.readInt(u32), limits.max_entries);
    var source_hash: [32]u8 = undefined;
    @memcpy(&source_hash, try reader.take(32));
    var target_hash: [32]u8 = undefined;
    @memcpy(&target_hash, try reader.take(32));
    _ = try reader.take(32);

    const rules = try allocator.alloc(path_filter.Rule, rule_count);
    errdefer allocator.free(rules);
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
        var filter = try path_filter.Filter.compile(allocator, rules);
        filter.deinit();
    }

    const entries = try allocator.alloc(EncodedEntry, entry_count);
    errdefer allocator.free(entries);
    const snapshot_view = try allocator.alloc(directory.Entry, entry_count);
    defer allocator.free(snapshot_view);
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
        entry.* = .{ .operation = operation, .mode = mode, .path = path, .payload = payload };
        view.* = .{ .path = path, .kind = kind, .mode = mode, .data = if (kind == .directory) "" else payload };
    }
    if (reader.position != bytes.len) return error.TrailingData;
    try directory.validateSnapshot(snapshot_view);

    return .{
        .allocator = allocator,
        .rules = rules,
        .entries = entries,
        .source_hash = source_hash,
        .target_hash = target_hash,
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
    hasher.update("DIFZTREE-PATCH\x01");
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
    future_format[8] = 2;
    recomputeChecksum(future_format);
    try testing.expectError(error.UnsupportedVersion, applyPatch(testing.allocator, &empty, future_format, .{}));

    const future_reader = try testing.allocator.dupe(u8, original);
    defer testing.allocator.free(future_reader);
    future_reader[10] = 2;
    recomputeChecksum(future_reader);
    try testing.expectError(error.ReaderTooOld, applyPatch(testing.allocator, &empty, future_reader, .{}));

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
