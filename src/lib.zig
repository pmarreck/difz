const blar = @import("blar");
const blip = blar.core;
const std = @import("std");
const diff_mod = @import("diff.zig");
const encoding = @import("encoding.zig");
const patch_mod = @import("patch.zig");
const inspect_mod = @import("inspect.zig");
const directory_fs = @import("directory_fs.zig");
const directory_patch = @import("directory_patch.zig");
const path_filter = @import("path_filter.zig");

pub const version = "0.1.0";

// ============================================================================
// C FFI exports
// ============================================================================

/// Compute a binary diff between buffers A and B.
/// If seed is null, a random seed is generated.
/// On success: sets out_ptr/out_len and returns 0.
/// On error: returns -1.
export fn difz_diff(
    a_ptr: [*]const u8,
    a_len: usize,
    b_ptr: [*]const u8,
    b_len: usize,
    seed: ?*const [32]u8,
    target_chunk_size: usize,
    compression: u8,
    out_ptr: *[*]u8,
    out_len: *usize,
) callconv(.c) i32 {
    const allocator = std.heap.page_allocator;

    // Resolve seed: use provided or generate random
    var seed_buf: [32]u8 = undefined;
    if (seed) |s| {
        seed_buf = s.*;
    } else {
        const io = std.Io.Threaded.global_single_threaded.io();
        io.randomSecure(&seed_buf) catch io.random(&seed_buf);
    }

    const a = a_ptr[0..a_len];
    const b = b_ptr[0..b_len];

    const options = diff_mod.DiffOptions{
        .seed = seed_buf,
        .target_chunk_size = target_chunk_size,
    };

    // Convert u8 to CompressionMode, default to .best on invalid value
    const comp_mode = std.enums.fromInt(encoding.CompressionMode, compression) orelse encoding.CompressionMode.best;

    // Compute diff
    const result = diff_mod.computeDiff(allocator, a, b, options) catch return -1;
    defer diff_mod.freeDiffResult(allocator, result);

    // Encode to BLIP bytes
    const encoded = encoding.encode(allocator, result, comp_mode) catch return -1;

    out_ptr.* = encoded.ptr;
    out_len.* = encoded.len;
    return 0;
}

/// Apply a diff to buffer A to reconstruct buffer B.
/// On success: sets out_ptr/out_len and returns 0.
/// On error: returns -1.
export fn difz_patch(
    a_ptr: [*]const u8,
    a_len: usize,
    diff_ptr: [*]const u8,
    diff_len: usize,
    out_ptr: *[*]u8,
    out_len: *usize,
) callconv(.c) i32 {
    const allocator = std.heap.page_allocator;

    const a = a_ptr[0..a_len];
    const diff_blob = diff_ptr[0..diff_len];

    const reconstructed = patch_mod.patch(allocator, a, diff_blob) catch return -1;

    out_ptr.* = reconstructed.ptr;
    out_len.* = reconstructed.len;
    return 0;
}

const DifzPathRule = extern struct {
    action: u8,
    pattern: [*:0]const u8,
};

export fn difz_directory_diff(
    source_path_z: [*:0]const u8,
    target_path_z: [*:0]const u8,
    rules_ptr: ?[*]const DifzPathRule,
    rule_count: usize,
    seed: ?*const [32]u8,
    target_chunk_size: usize,
    compression: u8,
    out_ptr: *[*]u8,
    out_len: *usize,
) callconv(.c) i32 {
    const allocator = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const source_path = std.mem.span(source_path_z);
    const target_path = std.mem.span(target_path_z);
    var source = std.Io.Dir.cwd().openDir(io, source_path, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch return -1;
    defer source.close(io);
    var target = std.Io.Dir.cwd().openDir(io, target_path, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch return -1;
    defer target.close(io);

    const rules = allocator.alloc(path_filter.Rule, rule_count) catch return -1;
    defer allocator.free(rules);
    if (rule_count > 0) {
        const ffi_rules = rules_ptr orelse return -1;
        for (ffi_rules[0..rule_count], rules) |source_rule, *rule| {
            const action = std.enums.fromInt(path_filter.Action, source_rule.action) orelse return -1;
            rule.* = .{ .action = action, .pattern = std.mem.span(source_rule.pattern) };
        }
    }
    const comp_mode = std.enums.fromInt(encoding.CompressionMode, compression) orelse return -1;
    const patch_bytes = directory_fs.createPatchFromDirs(allocator, io, source, target, .{
        .rules = rules,
        .seed = if (seed) |value| value.* else [_]u8{0} ** 32,
        .target_chunk_size = target_chunk_size,
        .compression = comp_mode,
    }) catch return -1;
    out_ptr.* = patch_bytes.ptr;
    out_len.* = patch_bytes.len;
    return 0;
}

export fn difz_directory_patch(
    source_path_z: [*:0]const u8,
    patch_ptr: [*]const u8,
    patch_len: usize,
    output_path_z: [*:0]const u8,
) callconv(.c) i32 {
    const allocator = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const source_path = std.mem.span(source_path_z);
    const output_path = std.mem.span(output_path_z);
    var source = std.Io.Dir.cwd().openDir(io, source_path, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch return -1;
    defer source.close(io);
    const parent_path = std.fs.path.dirname(output_path) orelse ".";
    const output_name = std.fs.path.basename(output_path);
    var parent = std.Io.Dir.cwd().openDir(io, parent_path, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch return -1;
    defer parent.close(io);
    var random: u64 = undefined;
    io.randomSecure(std.mem.asBytes(&random)) catch io.random(std.mem.asBytes(&random));
    var staging_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const staging_name = std.fmt.bufPrint(
        &staging_buffer,
        ".{s}.difz-stage-{x:0>16}",
        .{ output_name, random },
    ) catch return -1;
    directory_fs.applyPatchToNewDir(
        allocator,
        io,
        source,
        parent,
        output_name,
        staging_name,
        patch_ptr[0..patch_len],
        .{},
    ) catch |err| return switch (err) {
        error.SourceHashMismatch => -2,
        error.OutputAlreadyExists => -3,
        else => -1,
    };
    return 0;
}

export fn difz_write_new_file_atomic(
    output_path_z: [*:0]const u8,
    data_ptr: [*]const u8,
    data_len: usize,
) callconv(.c) i32 {
    writeNewFileAtomic(
        std.Io.Threaded.global_single_threaded.io(),
        std.mem.span(output_path_z),
        data_ptr[0..data_len],
    ) catch |err| return switch (err) {
        error.PathAlreadyExists => -3,
        else => -1,
    };
    return 0;
}

fn writeNewFileAtomic(io: std.Io, output_path: []const u8, data: []const u8) !void {
    const parent_path = std.fs.path.dirname(output_path) orelse ".";
    const output_name = std.fs.path.basename(output_path);
    var parent = try std.Io.Dir.cwd().openDir(io, parent_path, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer parent.close(io);
    var random: u64 = undefined;
    io.randomSecure(std.mem.asBytes(&random)) catch io.random(std.mem.asBytes(&random));
    var staging_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const staging_name = try std.fmt.bufPrint(
        &staging_buffer,
        ".{s}.difz-stage-{x:0>16}",
        .{ output_name, random },
    );
    var file = try parent.createFile(io, staging_name, .{
        .exclusive = true,
        .permissions = .default_file,
        .resolve_beneath = true,
    });
    var file_open = true;
    defer if (file_open) file.close(io);
    var owns_stage = true;
    errdefer if (owns_stage) parent.deleteFile(io, staging_name) catch {};
    try file.writeStreamingAll(io, data);
    try file.sync(io);
    file.close(io);
    file_open = false;
    try parent.renamePreserve(staging_name, parent, output_name, io);
    owns_stage = false;
}

/// Inspect a diff blob and produce a human-readable text description.
/// max_data_bytes: truncate INSERT data display to this many bytes (0 = no limit).
/// hexlike: if non-zero, use hexlike encoding instead of standard printable-binary.
/// On success: sets out_ptr/out_len and returns 0.
/// On error: returns -1.
export fn difz_inspect(
    diff_ptr: [*]const u8,
    diff_len: usize,
    max_data_bytes: usize,
    hexlike: c_int,
    out_ptr: *[*]u8,
    out_len: *usize,
) callconv(.c) i32 {
    const allocator = std.heap.page_allocator;

    const diff_blob = diff_ptr[0..diff_len];
    const effective_max = if (max_data_bytes == 0) std.math.maxInt(usize) else max_data_bytes;

    const result = inspect_mod.inspect(allocator, diff_blob, effective_max, hexlike != 0) catch return -1;

    out_ptr.* = result.ptr;
    out_len.* = result.len;
    return 0;
}

/// Free memory returned by difz_diff, difz_patch, or difz_inspect.
export fn difz_free(ptr: [*]u8, len: usize) callconv(.c) void {
    const allocator = std.heap.page_allocator;
    allocator.free(ptr[0..len]);
}

test "blip dependency works" {
    var buf: [16]u8 = undefined;
    const n = try blip.encode(42, &buf);
    const result = try blip.decode(buf[0..n]);
    try std.testing.expectEqual(@as(u64, 42), result.value);
}

test {
    _ = @import("gear_hash.zig");
    _ = @import("cdc.zig");
    _ = @import("chunk_match.zig");
    _ = @import("elder_diff.zig");
    _ = @import("diff.zig");
    _ = @import("encoding.zig");
    _ = @import("patch.zig");
    _ = @import("inspect.zig");
    _ = @import("directory.zig");
    _ = @import("path_filter.zig");
    _ = @import("directory_patch.zig");
    _ = @import("directory_fs.zig");
}

test "C FFI: difz_diff and difz_patch round-trip" {
    const a = "the quick brown fox " ** 50;
    const b = "the quick red fox " ** 50;
    var diff_out: [*]u8 = undefined;
    var diff_len: usize = undefined;
    const rc = difz_diff(a.ptr, a.len, b.ptr, b.len, null, 64, 0, &diff_out, &diff_len);
    try std.testing.expectEqual(@as(i32, 0), rc);
    defer difz_free(diff_out, diff_len);

    var patch_out: [*]u8 = undefined;
    var patch_len: usize = undefined;
    const rc2 = difz_patch(a.ptr, a.len, diff_out, diff_len, &patch_out, &patch_len);
    try std.testing.expectEqual(@as(i32, 0), rc2);
    defer difz_free(patch_out, patch_len);

    try std.testing.expectEqualStrings(b, patch_out[0..patch_len]);
}

test "C FFI: difz_diff with explicit seed" {
    const a = "hello world test data " ** 30;
    const b = "hello earth test data " ** 30;
    const seed = [_]u8{42} ** 32;
    var diff_out: [*]u8 = undefined;
    var diff_len: usize = undefined;
    const rc = difz_diff(a.ptr, a.len, b.ptr, b.len, &seed, 128, 0, &diff_out, &diff_len);
    try std.testing.expectEqual(@as(i32, 0), rc);
    defer difz_free(diff_out, diff_len);

    var patch_out: [*]u8 = undefined;
    var patch_len: usize = undefined;
    const rc2 = difz_patch(a.ptr, a.len, diff_out, diff_len, &patch_out, &patch_len);
    try std.testing.expectEqual(@as(i32, 0), rc2);
    defer difz_free(patch_out, patch_len);

    try std.testing.expectEqualStrings(b, patch_out[0..patch_len]);
}

test "C FFI: difz_patch with invalid diff returns error" {
    const a = "hello";
    const bad_diff = "not a valid diff";
    var patch_out: [*]u8 = undefined;
    var patch_len: usize = undefined;
    const rc = difz_patch(a.ptr, a.len, bad_diff.ptr, bad_diff.len, &patch_out, &patch_len);
    try std.testing.expectEqual(@as(i32, -1), rc);
}

test "C FFI: difz_inspect produces readable output" {
    // First create a diff
    const a = "the quick brown fox " ** 50;
    const b = "the quick red fox " ** 50;
    var diff_out: [*]u8 = undefined;
    var diff_len: usize = undefined;
    const rc = difz_diff(a.ptr, a.len, b.ptr, b.len, null, 64, 0, &diff_out, &diff_len);
    try std.testing.expectEqual(@as(i32, 0), rc);
    defer difz_free(diff_out, diff_len);

    // Now inspect it
    var inspect_out: [*]u8 = undefined;
    var inspect_len: usize = undefined;
    const rc2 = difz_inspect(diff_out, diff_len, 64, 0, &inspect_out, &inspect_len);
    try std.testing.expectEqual(@as(i32, 0), rc2);
    defer difz_free(inspect_out, inspect_len);

    const output = inspect_out[0..inspect_len];
    try std.testing.expect(std.mem.indexOf(u8, output, "difz inspect:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "COPY") != null or
        std.mem.indexOf(u8, output, "INSERT") != null);
}

test "C FFI: difz_inspect with invalid diff returns error" {
    const bad_diff = "not a valid diff";
    var inspect_out: [*]u8 = undefined;
    var inspect_len: usize = undefined;
    const rc = difz_inspect(bad_diff.ptr, bad_diff.len, 64, 0, &inspect_out, &inspect_len);
    try std.testing.expectEqual(@as(i32, -1), rc);
}
