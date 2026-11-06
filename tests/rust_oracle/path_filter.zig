const std = @import("std");
const filter = @import("reference").path_filter;

fn word(input: []const u8, position: *usize) !u32 {
    if (input.len - position.* < 4) return error.BadFixture;
    const result = std.mem.readInt(u32, input[position.*..][0..4], .little);
    position.* += 4;
    return result;
}
pub fn run(allocator: std.mem.Allocator, mode: u32, input: []const u8) ![]const u8 {
    var position: usize = 0;
    const count = try word(input, &position);
    if (count > 4096 or count > (input.len - position) / 5) return error.BadFixture;
    const rules = try allocator.alloc(filter.Rule, count);
    for (rules) |*rule| {
        if (position >= input.len) return error.BadFixture;
        const action = std.enums.fromInt(filter.Action, input[position]) orelse return error.BadFixture;
        position += 1;
        const length = try word(input, &position);
        if (length > input.len - position) return error.BadFixture;
        rule.* = .{ .action = action, .pattern = input[position..][0..length] };
        position += length;
    }
    var compiled = try filter.Filter.compile(allocator, rules);
    defer compiled.deinit();
    if (mode == 50) {
        if (position != input.len) return error.BadFixture;
        return &.{};
    }
    const included = try compiled.includes(input[position..]);
    return allocator.dupe(u8, &.{@intFromBool(included)});
}
