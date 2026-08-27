const std = @import("std");
const testing = std.testing;
const directory = @import("directory.zig");
const glob = @import("glob.zig");
const pcre2 = @import("pcre2.zig");

pub const Action = enum(u8) {
    include = 1,
    exclude = 2,
};

pub const Rule = struct {
    action: Action,
    pattern: []const u8,
};

pub const Filter = struct {
    allocator: std.mem.Allocator,
    rules: []CompiledRule,
    default_included: bool,

    const CompiledRule = struct {
        action: Action,
        regex: pcre2.Regex,
    };

    pub fn compile(allocator: std.mem.Allocator, rules: []const Rule) !Filter {
        var compiled: std.ArrayListUnmanaged(CompiledRule) = .empty;
        errdefer {
            for (compiled.items) |*rule| rule.regex.deinit();
            compiled.deinit(allocator);
        }

        var default_included = true;
        for (rules) |rule| {
            if (rule.action == .include) default_included = false;
            var action = rule.action;
            var pattern = rule.pattern;
            if (pattern.len > 0 and pattern[0] == '!') {
                action = opposite(action);
                pattern = pattern[1..];
            }
            if (pattern.len == 0) return error.EmptyPattern;
            if (!std.unicode.utf8ValidateSlice(pattern)) return error.InvalidUtf8;

            const regex_text = try glob.toRegex(allocator, pattern);
            defer allocator.free(regex_text);
            var regex = try pcre2.Regex.compile(allocator, regex_text);
            compiled.append(allocator, .{ .action = action, .regex = regex }) catch |err| {
                regex.deinit();
                return err;
            };
        }

        return .{
            .allocator = allocator,
            .rules = try compiled.toOwnedSlice(allocator),
            .default_included = default_included,
        };
    }

    pub fn deinit(self: *Filter) void {
        for (self.rules) |*rule| rule.regex.deinit();
        self.allocator.free(self.rules);
        self.* = undefined;
    }

    pub fn includes(self: *Filter, path: []const u8) !bool {
        try directory.validatePath(path);
        var included = self.default_included;
        for (self.rules) |*rule| {
            if (try rule.regex.matches(path)) included = rule.action == .include;
        }
        return included;
    }
};

fn opposite(action: Action) Action {
    return switch (action) {
        .include => .exclude,
        .exclude => .include,
    };
}

test "ordered glob rules classify a representative path set" {
    const rules = [_]Rule{
        .{ .action = .include, .pattern = "**" },
        .{ .action = .exclude, .pattern = "**/*.tmp" },
        .{ .action = .exclude, .pattern = "src/**" },
        .{ .action = .include, .pattern = "src/main.zig" },
        .{ .action = .exclude, .pattern = ".*" },
        .{ .action = .exclude, .pattern = "literal\\*name" },
    };
    var filter = try Filter.compile(testing.allocator, &rules);
    defer filter.deinit();

    const Case = struct { path: []const u8, included: bool };
    const cases = [_]Case{
        .{ .path = "README.md", .included = true },
        .{ .path = ".env", .included = false },
        .{ .path = "src/main.zig", .included = true },
        .{ .path = "src/generated/cache.zig", .included = false },
        .{ .path = "docs/δ.md", .included = true },
        .{ .path = "nested/cache.tmp", .included = false },
        .{ .path = "literal*name", .included = false },
        .{ .path = "literalXname", .included = true },
    };

    for (cases) |case| {
        try testing.expectEqual(case.included, try filter.includes(case.path));
    }
}

test "leading negation flips an ordered rule action over a set" {
    const rules = [_]Rule{
        .{ .action = .exclude, .pattern = "*.log" },
        .{ .action = .exclude, .pattern = "!keep.log" },
        .{ .action = .include, .pattern = "!secret.log" },
    };
    var filter = try Filter.compile(testing.allocator, &rules);
    defer filter.deinit();

    const Case = struct { path: []const u8, included: bool };
    const cases = [_]Case{
        .{ .path = "drop.log", .included = false },
        .{ .path = "keep.log", .included = true },
        .{ .path = "secret.log", .included = false },
        .{ .path = "notes.txt", .included = false },
    };
    for (cases) |case| {
        try testing.expectEqual(case.included, try filter.includes(case.path));
    }
}

test "an allowlist excludes unmatched paths and allows a re-included descendant" {
    const rules = [_]Rule{
        .{ .action = .include, .pattern = "kept/**" },
    };
    var filter = try Filter.compile(testing.allocator, &rules);
    defer filter.deinit();

    const Case = struct { path: []const u8, included: bool };
    const cases = [_]Case{
        .{ .path = "kept", .included = false },
        .{ .path = "kept/child.txt", .included = true },
        .{ .path = "other.txt", .included = false },
    };
    for (cases) |case| {
        try testing.expectEqual(case.included, try filter.includes(case.path));
    }
}
