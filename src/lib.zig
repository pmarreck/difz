const std = @import("std");
const zstd_patch = @import("zstd_patch.zig");
const patch_mod = @import("patch.zig");
const inspect_mod = @import("inspect.zig");
const directory_fs = @import("directory_fs.zig");
const path_filter = @import("path_filter.zig");
const metadata = @import("metadata.zig");

pub const version = "0.1.0";

const ProgressFn = *const fn (stage: [*:0]const u8, done: u64, total: u64, user: ?*anyopaque) callconv(.c) void;
var progress_fn: ?ProgressFn = null;
var progress_user: ?*anyopaque = null;

fn emitProgress(stage: [:0]const u8, done: u64, total: u64) void {
    if (progress_fn) |cb| cb(stage.ptr, done, total, progress_user);
}

export fn difz_set_progress_callback(
    cb: ?ProgressFn,
    user: ?*anyopaque,
) callconv(.c) void {
    progress_fn = cb;
    progress_user = user;
}

// ============================================================================
// C FFI exports
// ============================================================================

/// Compute a zstd level-9 prefix patch from buffer A to buffer B.
/// On success: sets out_ptr/out_len and returns 0.
/// On error: returns -1, or -4 when max_output_bytes is exceeded.
export fn difz_diff(
    a_ptr: [*]const u8,
    a_len: usize,
    b_ptr: [*]const u8,
    b_len: usize,
    out_ptr: *[*]u8,
    out_len: *usize,
) callconv(.c) i32 {
    return difz_diff_limited(a_ptr, a_len, b_ptr, b_len, 0, out_ptr, out_len);
}

export fn difz_diff_limited(
    a_ptr: [*]const u8,
    a_len: usize,
    b_ptr: [*]const u8,
    b_len: usize,
    max_output_bytes: usize,
    out_ptr: *[*]u8,
    out_len: *usize,
) callconv(.c) i32 {
    const allocator = std.heap.page_allocator;
    const a = a_ptr[0..a_len];
    const b = b_ptr[0..b_len];

    emitProgress("diff", 0, 2);
    emitProgress("encode", 1, 2);
    const encoded = zstd_patch.encode(allocator, a, b) catch return -1;
    if (max_output_bytes != 0 and encoded.len > max_output_bytes) {
        allocator.free(encoded);
        return -4;
    }

    emitProgress("done", 2, 2);
    out_ptr.* = encoded.ptr;
    out_len.* = encoded.len;
    return 0;
}

/// Apply a diff to buffer A to reconstruct buffer B.
/// On success: sets out_ptr/out_len and returns 0.
/// On error: returns -1, or -4 when max_output_bytes is exceeded.
export fn difz_patch(
    a_ptr: [*]const u8,
    a_len: usize,
    diff_ptr: [*]const u8,
    diff_len: usize,
    out_ptr: *[*]u8,
    out_len: *usize,
) callconv(.c) i32 {
    return difz_patch_limited(a_ptr, a_len, diff_ptr, diff_len, 0, out_ptr, out_len);
}

export fn difz_patch_limited(
    a_ptr: [*]const u8,
    a_len: usize,
    diff_ptr: [*]const u8,
    diff_len: usize,
    max_output_bytes: usize,
    out_ptr: *[*]u8,
    out_len: *usize,
) callconv(.c) i32 {
    const allocator = std.heap.page_allocator;

    const a = a_ptr[0..a_len];
    const diff_blob = diff_ptr[0..diff_len];

    emitProgress("patch", 0, 1);
    const reconstructed = patch_mod.patchLimited(allocator, a, diff_blob, max_output_bytes) catch |err| {
        return if (err == error.ResourceLimitExceeded) @as(i32, -4) else -1;
    };

    emitProgress("done", 1, 1);
    out_ptr.* = reconstructed.ptr;
    out_len.* = reconstructed.len;
    return 0;
}

const DifzPathRule = extern struct {
    action: u8,
    pattern: [*:0]const u8,
};

export fn difz_parse_metadata_omit(text: [*:0]const u8, out_mask: *u32) callconv(.c) i32 {
    const omit = metadata.parseOmit(std.mem.span(text)) catch return -1;
    out_mask.* = omit.bits();
    return 0;
}

export fn difz_directory_diff(
    source_path_z: [*:0]const u8,
    target_path_z: [*:0]const u8,
    rules_ptr: ?[*]const DifzPathRule,
    rule_count: usize,
    omit_metadata: u32,
    out_ptr: *[*]u8,
    out_len: *usize,
) callconv(.c) i32 {
    const omit = metadata.Omit.fromBits(omit_metadata) catch return -1;
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
    const patch_bytes = directory_fs.createPatchFromDirs(allocator, io, source, target, .{
        .rules = rules,
        .omit = omit,
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

/// Describe a ZDIF v4 patch. On success: sets out_ptr/out_len and returns 0.
/// On error: returns -1.
export fn difz_inspect(
    diff_ptr: [*]const u8,
    diff_len: usize,
    out_ptr: *[*]u8,
    out_len: *usize,
) callconv(.c) i32 {
    const allocator = std.heap.page_allocator;
    const diff_blob = diff_ptr[0..diff_len];
    const result = inspect_mod.inspect(allocator, diff_blob) catch return -1;

    out_ptr.* = result.ptr;
    out_len.* = result.len;
    return 0;
}

/// Free a buffer returned by the public C API. Null pointers are ignored.
export fn difz_free(ptr: ?[*]u8, len: usize) callconv(.c) void {
    const p = ptr orelse return;
    if (len == 0) return;
    const allocator = std.heap.page_allocator;
    allocator.free(p[0..len]);
}

test "difz_free ignores null pointers" {
    difz_free(null, 0);
    difz_free(null, 32);
}

test {
    _ = @import("patch.zig");
    _ = @import("inspect.zig");
    _ = @import("directory.zig");
    _ = @import("path_filter.zig");
    _ = @import("directory_patch.zig");
    _ = @import("directory_fs.zig");
    _ = @import("zstd_patch.zig");
}

test "C FFI: difz_diff and difz_patch round-trip" {
    const a = "the quick brown fox " ** 50;
    const b = "the quick red fox " ** 50;
    var diff_out: [*]u8 = undefined;
    var diff_len: usize = undefined;
    const rc = difz_diff(a.ptr, a.len, b.ptr, b.len, &diff_out, &diff_len);
    try std.testing.expectEqual(@as(i32, 0), rc);
    defer difz_free(diff_out, diff_len);

    var patch_out: [*]u8 = undefined;
    var patch_len: usize = undefined;
    const rc2 = difz_patch(a.ptr, a.len, diff_out, diff_len, &patch_out, &patch_len);
    try std.testing.expectEqual(@as(i32, 0), rc2);
    defer difz_free(patch_out, patch_len);

    try std.testing.expectEqualStrings(b, patch_out[0..patch_len]);
}

test "C FFI: repeated diffs are byte-identical" {
    const a = "hello world test data " ** 30;
    const b = "hello earth test data " ** 30;
    var first: [*]u8 = undefined;
    var first_len: usize = undefined;
    var second: [*]u8 = undefined;
    var second_len: usize = undefined;
    try std.testing.expectEqual(@as(i32, 0), difz_diff(a.ptr, a.len, b.ptr, b.len, &first, &first_len));
    defer difz_free(first, first_len);
    try std.testing.expectEqual(@as(i32, 0), difz_diff(a.ptr, a.len, b.ptr, b.len, &second, &second_len));
    defer difz_free(second, second_len);
    try std.testing.expectEqualSlices(u8, first[0..first_len], second[0..second_len]);
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
    const rc = difz_diff(a.ptr, a.len, b.ptr, b.len, &diff_out, &diff_len);
    try std.testing.expectEqual(@as(i32, 0), rc);
    defer difz_free(diff_out, diff_len);

    // Now inspect it
    var inspect_out: [*]u8 = undefined;
    var inspect_len: usize = undefined;
    const rc2 = difz_inspect(diff_out, diff_len, &inspect_out, &inspect_len);
    try std.testing.expectEqual(@as(i32, 0), rc2);
    defer difz_free(inspect_out, inspect_len);

    const output = inspect_out[0..inspect_len];
    try std.testing.expect(std.mem.indexOf(u8, output, "difz inspect:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "zstd level 9 patch-from") != null);
}

test "C FFI: difz_inspect with invalid diff returns error" {
    const bad_diff = "not a valid diff";
    var inspect_out: [*]u8 = undefined;
    var inspect_len: usize = undefined;
    const rc = difz_inspect(bad_diff.ptr, bad_diff.len, &inspect_out, &inspect_len);
    try std.testing.expectEqual(@as(i32, -1), rc);
}

test "C FFI: difz_diff_limited returns -4 when the encoded patch exceeds the ceiling" {
    const a = "AAAAAAAA";
    const b = "BBBBBBBB";
    var out_ptr: [*]u8 = undefined;
    var out_len: usize = undefined;
    const rc = difz_diff_limited(a.ptr, a.len, b.ptr, b.len, 8, &out_ptr, &out_len);
    try std.testing.expectEqual(@as(i32, -4), rc);
    const ok = difz_diff_limited(a.ptr, a.len, b.ptr, b.len, 0, &out_ptr, &out_len);
    try std.testing.expectEqual(@as(i32, 0), ok);
    defer difz_free(out_ptr, out_len);
    try std.testing.expect(out_len > 8);
}

test "C FFI: progress callback fires for diff stages" {
    const Counter = struct {
        n: usize = 0,
        fn on_progress(stage: [*:0]const u8, done: u64, total: u64, user: ?*anyopaque) callconv(.c) void {
            _ = stage;
            _ = done;
            _ = total;
            const n: *usize = @ptrCast(@alignCast(user.?));
            n.* += 1;
        }
    };
    var n: usize = 0;
    difz_set_progress_callback(&Counter.on_progress, @ptrCast(&n));
    defer difz_set_progress_callback(null, null);
    const a = "hello hello";
    const b = "hello world";
    var out_ptr: [*]u8 = undefined;
    var out_len: usize = undefined;
    const rc = difz_diff(a.ptr, a.len, b.ptr, b.len, &out_ptr, &out_len);
    try std.testing.expectEqual(@as(i32, 0), rc);
    defer difz_free(out_ptr, out_len);
    try std.testing.expect(n >= 2);
}
