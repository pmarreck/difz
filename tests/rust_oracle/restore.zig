const std = @import("std");
const metadata = @import("metadata");

comptime {
    if (std.meta.fields(metadata.Caps).len != 9) @compileError("review capability wire layout");
    if (std.meta.fields(metadata.Action).len > 32) @compileError("action bitset is too small");
}

fn capBits(caps: metadata.Caps) u8 {
    var bits: u8 = 0;
    inline for (std.meta.fields(metadata.Caps)[1..], 0..) |field, index| {
        if (field.type != bool) @compileError("review capability field type");
        if (@field(caps, field.name)) bits |= @as(u8, 1) << @intCast(index);
    }
    return bits;
}

pub fn run(allocator: std.mem.Allocator, mode: u32, input: []const u8) ![]const u8 {
    switch (mode) {
        20 => {
            if (input.len < 2) return error.BadMetadata;
            const os = std.enums.fromInt(metadata.Os, input[0]) orelse return error.BadMetadata;
            var caps: metadata.Caps = .{ .os = os };
            inline for (std.meta.fields(metadata.Caps)[1..], 0..) |field, index| {
                @field(caps, field.name) = input[1] & (@as(u8, 1) << @intCast(index)) != 0;
            }
            const parsed = try metadata.decodeCanonical(allocator, input[2..]);
            const plan = try metadata.planRestore(parsed, caps);
            var flags: u32 = 0;
            inline for (std.meta.fields(metadata.Action), 0..) |field, index| {
                if (@field(plan.actions, field.name)) flags |= @as(u32, 1) << @intCast(index);
            }
            const output = try allocator.alloc(u8, 5 + plan.compromise_len * 4);
            std.mem.writeInt(u32, output[0..4], flags, .little);
            output[4] = @intCast(plan.compromise_len);
            for (plan.compromises[0..plan.compromise_len], 0..) |item, index| {
                const offset = 5 + index * 4;
                output[offset..][0..4].* = .{
                    @intFromEnum(item.code),                 @intFromEnum(item.family),
                    @intFromBool(item.portable_acl_applied), if (item.origin) |origin| @intFromEnum(origin) else 0,
                };
            }
            return output;
        },
        21 => {
            if (input.len != 1) return error.BadMetadata;
            const os = std.enums.fromInt(metadata.Os, input[0]) orelse return error.BadMetadata;
            return allocator.dupe(u8, &.{capBits(metadata.defaultCaps(os))});
        },
        22 => {
            var report: metadata.RestoreReport = .{};
            for (input) |byte| report.add(std.enums.fromInt(metadata.CompromiseCode, byte) orelse return error.BadMetadata);
            const output = try allocator.alloc(u8, 4);
            std.mem.writeInt(u32, output[0..4], report.mask, .little);
            return output;
        },
        else => return error.BadMetadata,
    }
}
