const std = @import("std");

/// Convert a dirtree-compatible path glob into an anchored PCRE2 pattern.
pub fn toRegex(allocator: std.mem.Allocator, glob: []const u8) ![]u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    defer result.deinit(allocator);
    try result.append(allocator, '^');

    var i: usize = 0;
    while (i < glob.len) {
        const c = glob[i];
        switch (c) {
            '\\' => {
                if (i + 1 < glob.len) {
                    try appendLiteral(allocator, &result, glob[i + 1]);
                    i += 2;
                    continue;
                }
                try appendLiteral(allocator, &result, '\\');
            },
            '*' => {
                if (i + 1 < glob.len and glob[i + 1] == '*') {
                    if (i + 2 < glob.len and glob[i + 2] == '/') {
                        try result.appendSlice(allocator, "(.*/)?");
                        i += 3;
                    } else {
                        try result.appendSlice(allocator, ".*");
                        i += 2;
                    }
                    continue;
                }
                try result.appendSlice(allocator, "[^/]*");
            },
            '?' => try result.appendSlice(allocator, "[^/]"),
            '[' => {
                var class: std.ArrayListUnmanaged(u8) = .empty;
                defer class.deinit(allocator);
                try class.append(allocator, '[');

                var j = i + 1;
                if (j < glob.len and (glob[j] == '!' or glob[j] == '^')) {
                    try class.append(allocator, '^');
                    j += 1;
                }
                if (j < glob.len and glob[j] == ']') {
                    try class.append(allocator, ']');
                    j += 1;
                }

                var valid = false;
                while (j < glob.len) : (j += 1) {
                    const item = glob[j];
                    if (item == ']') {
                        valid = true;
                        j += 1;
                        break;
                    }
                    if (item == '\\' and j + 1 < glob.len) {
                        j += 1;
                        try appendClassLiteral(allocator, &class, glob[j]);
                    } else {
                        try appendClassLiteral(allocator, &class, item);
                    }
                }

                if (!valid) {
                    try result.appendSlice(allocator, "\\[");
                    i += 1;
                    continue;
                }
                try class.append(allocator, ']');
                try result.appendSlice(allocator, class.items);
                i = j;
                continue;
            },
            else => try appendLiteral(allocator, &result, c),
        }
        i += 1;
    }

    try result.append(allocator, '$');
    return result.toOwnedSlice(allocator);
}

fn appendLiteral(allocator: std.mem.Allocator, result: *std.ArrayListUnmanaged(u8), byte: u8) !void {
    switch (byte) {
        '.', '+', '^', '$', '(', ')', '{', '}', '|', '\\', '*', '?', '[', ']' => try result.append(allocator, '\\'),
        else => {},
    }
    try result.append(allocator, byte);
}

fn appendClassLiteral(allocator: std.mem.Allocator, result: *std.ArrayListUnmanaged(u8), byte: u8) !void {
    switch (byte) {
        '\\', '-', '[', ']', '^' => try result.append(allocator, '\\'),
        else => {},
    }
    try result.append(allocator, byte);
}

test "escaped wildcard conversion follows the documented dirtree contract" {
    const cases = [_]struct { glob: []const u8, regex: []const u8 }{
        .{ .glob = "\\*", .regex = "^\\*$" },
        .{ .glob = "a\\*b", .regex = "^a\\*b$" },
        .{ .glob = "file\\?.txt", .regex = "^file\\?\\.txt$" },
        .{ .glob = "literal\\[x", .regex = "^literal\\[x$" },
    };
    for (cases) |case| {
        const regex = try toRegex(std.testing.allocator, case.glob);
        defer std.testing.allocator.free(regex);
        try std.testing.expectEqualStrings(case.regex, regex);
    }
}
