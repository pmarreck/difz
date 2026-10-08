const std = @import("std");
const testing = std.testing;

pub const Os = enum(u8) { linux = 1, macos = 2, windows = 3 };

pub const Family = enum(u8) {
    xattr = 1,
    acl = 2,
    timestamps = 3,
    finder = 4,
    sparse = 5,
    hardlink = 6,
};

pub const Omit = struct {
    xattr: bool = false,
    acl: bool = false,
    timestamps: bool = false,
    finder: bool = false,
    sparse: bool = false,
    hardlink: bool = false,

    pub fn bits(self: Omit) u32 {
        return @as(u32, @intFromBool(self.xattr)) |
            (@as(u32, @intFromBool(self.acl)) << 1) |
            (@as(u32, @intFromBool(self.timestamps)) << 2) |
            (@as(u32, @intFromBool(self.finder)) << 3) |
            (@as(u32, @intFromBool(self.sparse)) << 4) |
            (@as(u32, @intFromBool(self.hardlink)) << 5);
    }

    pub fn fromBits(value: u32) MetaError!Omit {
        if (value & ~@as(u32, 0x3f) != 0) return error.InvalidOmitMask;
        return .{
            .xattr = value & 1 != 0,
            .acl = value & 2 != 0,
            .timestamps = value & 4 != 0,
            .finder = value & 8 != 0,
            .sparse = value & 16 != 0,
            .hardlink = value & 32 != 0,
        };
    }
};

pub const XattrClass = enum(u8) { logical = 1, raw = 2 };

pub const Xattr = struct {
    class: XattrClass,
    name: []const u8,
    value: []const u8,
};

pub const AceTag = enum(u8) {
    owner = 1,
    group = 2,
    everyone = 3,
    named_user = 4,
    named_group = 5,
    mask = 6,
};

pub const Ace = struct {
    tag: AceTag,
    read: bool = false,
    write: bool = false,
    execute: bool = false,
    name: []const u8 = "",
};

pub const AclOrigin = enum(u8) { linux = 1, macos = 2, windows = 3 };

pub const NativeAcl = struct {
    origin: AclOrigin,
    bytes: []const u8,
};

pub const Time = struct {
    sec: i64 = 0,
    nsec: u32 = 0,
};

pub const Times = struct {
    mtime: ?Time = null,
    atime: ?Time = null,
    btime: ?Time = null,
};

pub const Hole = struct { offset: u64, length: u64 };

pub const Metadata = struct {
    xattrs: []const Xattr = &.{},
    aces: []const Ace = &.{},
    native_acl: ?NativeAcl = null,
    times: Times = .{},
    finder_flags: u32 = 0,
    finder_info: ?[32]u8 = null,
    holes: []const Hole = &.{},
    hardlink_to: ?[]const u8 = null,

    /// True when every family is absent. Omitted families canonicalize to this.
    pub fn isEmpty(self: Metadata) bool {
        return self.xattrs.len == 0 and self.aces.len == 0 and self.native_acl == null and
            self.times.mtime == null and self.times.atime == null and self.times.btime == null and
            self.finder_flags == 0 and self.finder_info == null and self.holes.len == 0 and
            self.hardlink_to == null;
    }
};

pub const Caps = struct {
    os: Os,
    set_btime: bool = false,
    punch_holes: bool = false,
    hardlink: bool = false,
    portable_acl: bool = false,
    native_acl: bool = false,
    bsd_flags: bool = false,
    finder_info: bool = false,
    logical_xattr: bool = true,
};

pub const Action = struct {
    logical_xattr: bool = false,
    raw_xattr: bool = false,
    raw_xattr_sidecar: bool = false,
    portable_acl: bool = false,
    portable_acl_sidecar: bool = false,
    native_acl: bool = false,
    native_acl_sidecar: bool = false,
    mtime_atime: bool = false,
    btime: bool = false,
    btime_sidecar: bool = false,
    bsd_flags: bool = false,
    bsd_flags_sidecar: bool = false,
    finder_info: bool = false,
    finder_info_sidecar: bool = false,
    punch_holes: bool = false,
    sparse_sidecar: bool = false,
    hardlink: bool = false,
    hardlink_copy: bool = false,
};

pub const CompromiseCode = enum(u8) {
    native_acl_preserved = 1,
    portable_acl_preserved = 2,
    finder_flags_preserved = 3,
    finder_info_preserved = 4,
    birth_time_preserved = 5,
    sparse_preserved = 6,
    hardlink_copied = 7,
    raw_xattr_preserved = 8,
    symlink_metadata_preserved = 9,
    modification_time_preserved = 10,
};

/// Per-apply effects, reported only after the verified tree is published.
pub const RestoreReport = struct {
    mask: u32 = 0,

    pub fn add(self: *RestoreReport, code: CompromiseCode) void {
        self.mask |= @as(u32, 1) << @intCast(@intFromEnum(code) - 1);
    }
};

pub const Compromise = struct {
    code: CompromiseCode,
    family: Family,
    portable_acl_applied: bool = false,
    origin: ?AclOrigin = null,
};

pub const Plan = struct {
    actions: Action = .{},
    compromises: [8]Compromise = undefined,
    compromise_len: usize = 0,
};

pub const MetaError = error{
    DuplicateXattr,
    DuplicateAce,
    EmptyName,
    InvalidLogicalName,
    ReservedTransportName,
    InvalidRawName,
    ZeroLengthHole,
    HoleOverflow,
    InvalidNsec,
    InvalidHardlink,
    InvalidAceName,
    EmptyNativeAcl,
    TruncatedMetadata,
    TrailingMetadata,
    BadMetadata,
    UnknownFamily,
    DuplicateFamily,
    EmptyFamily,
    PlanImpossible,
    InvalidOmitMask,
};

/// Sidecar attribute names. Snapshot must not treat these as user xattrs.
pub const transport_names = [_][]const u8{
    "difz.btime",
    "difz.mtime",
    "difz.finder-info",
    "difz.bsd-flags",
    "difz.native-acl",
    "difz.portable-acl",
    "difz.sparse-holes",
    "difz.hardlink-to",
    "difz.raw-xattrs",
    "difz.symlinks",
};

pub fn parseOmit(text: []const u8) MetaError!Omit {
    var omit = Omit{};
    if (text.len == 0) return omit;
    var parts = std.mem.splitScalar(u8, text, ',');
    while (parts.next()) |raw| {
        const name = std.mem.trim(u8, raw, " ");
        if (name.len == 0) return error.EmptyFamily;
        const family = familyByName(name) orelse return error.UnknownFamily;
        switch (family) {
            .xattr => {
                if (omit.xattr) return error.DuplicateFamily;
                omit.xattr = true;
            },
            .acl => {
                if (omit.acl) return error.DuplicateFamily;
                omit.acl = true;
            },
            .timestamps => {
                if (omit.timestamps) return error.DuplicateFamily;
                omit.timestamps = true;
            },
            .finder => {
                if (omit.finder) return error.DuplicateFamily;
                omit.finder = true;
            },
            .sparse => {
                if (omit.sparse) return error.DuplicateFamily;
                omit.sparse = true;
            },
            .hardlink => {
                if (omit.hardlink) return error.DuplicateFamily;
                omit.hardlink = true;
            },
        }
    }
    return omit;
}

pub fn encodeTimeOverride(value: ?Time, buffer: *[13]u8) MetaError![]const u8 {
    try validateTime(value);
    buffer[0] = @intFromBool(value != null);
    if (value) |time| {
        std.mem.writeInt(i64, buffer[1..9], time.sec, .little);
        std.mem.writeInt(u32, buffer[9..13], time.nsec, .little);
        return buffer;
    }
    return buffer[0..1];
}

pub fn decodeTimeOverride(bytes: []const u8) MetaError!?Time {
    if (bytes.len == 1 and bytes[0] == 0) return null;
    if (bytes.len != 13 or bytes[0] != 1) return error.BadMetadata;
    const value: Time = .{ .sec = std.mem.readInt(i64, bytes[1..9], .little), .nsec = std.mem.readInt(u32, bytes[9..13], .little) };
    try validateTime(value);
    return value;
}

pub const ModificationOverride = struct { original: ?Time, observed: Time };

pub fn encodeModificationOverride(value: ModificationOverride, buffer: *[25]u8) MetaError![]const u8 {
    var original: [13]u8 = undefined;
    const bytes = try encodeTimeOverride(value.original, &original);
    try validateTime(value.observed);
    @memcpy(buffer[0..bytes.len], bytes);
    std.mem.writeInt(i64, buffer[bytes.len..][0..8], value.observed.sec, .little);
    std.mem.writeInt(u32, buffer[bytes.len + 8 ..][0..4], value.observed.nsec, .little);
    return buffer[0 .. bytes.len + 12];
}

pub fn decodeModificationOverride(bytes: []const u8) MetaError!ModificationOverride {
    if (bytes.len != 13 and bytes.len != 25) return error.BadMetadata;
    const prefix = bytes.len - 12;
    const original = try decodeTimeOverride(bytes[0..prefix]);
    const observed: Time = .{ .sec = std.mem.readInt(i64, bytes[prefix..][0..8], .little), .nsec = std.mem.readInt(u32, bytes[prefix + 8 ..][0..4], .little) };
    try validateTime(observed);
    return .{ .original = original, .observed = observed };
}

test "mtime transport binds the original value to the observed native stamp" {
    for ([_]?Time{ null, .{ .sec = std.math.maxInt(i64), .nsec = 999_999_999 } }) |original| {
        const value: ModificationOverride = .{ .original = original, .observed = .{ .sec = -1, .nsec = 4 } };
        var buffer: [25]u8 = undefined;
        const bytes = try encodeModificationOverride(value, &buffer);
        try testing.expectEqualDeep(value, try decodeModificationOverride(bytes));
        for (0..bytes.len) |length| {
            if (decodeModificationOverride(bytes[0..length])) |_| return error.TruncationAccepted else |_| {}
        }
    }
}

test "timestamp transport preserves presence signed seconds and nanosecond boundaries" {
    const values = [_]?Time{ null, .{}, .{ .sec = -1, .nsec = 999_999_999 }, .{ .sec = std.math.minInt(i64) }, .{ .sec = std.math.maxInt(i64), .nsec = 999_999_999 } };
    for (values) |value| {
        var buffer: [13]u8 = undefined;
        const bytes = try encodeTimeOverride(value, &buffer);
        try testing.expectEqual(if (value == null) @as(usize, 1) else 13, bytes.len);
        const decoded = try decodeTimeOverride(bytes);
        try testing.expectEqualDeep(value, decoded);
        var again: [13]u8 = undefined;
        try testing.expectEqualSlices(u8, bytes, try encodeTimeOverride(decoded, &again));
    }
    var wire = [_]u8{1} ++ [_]u8{0xff} ** 8 ++ [_]u8{ 0xff, 0xc9, 0x9a, 0x3b };
    try testing.expectEqualDeep(@as(?Time, .{ .sec = -1, .nsec = 999_999_999 }), try decodeTimeOverride(&wire));
    for (0..13) |length| try testing.expectError(error.BadMetadata, decodeTimeOverride(wire[0..length]));
    wire[0] = 2;
    try testing.expectError(error.BadMetadata, decodeTimeOverride(&wire));
    wire[0] = 1;
    std.mem.writeInt(u32, wire[9..13], 1_000_000_000, .little);
    try testing.expectError(error.InvalidNsec, decodeTimeOverride(&wire));
}

/// Sort and validate a metadata record. `allocator` should be an arena: an
/// error return can leave earlier copies allocated. Omitted families become
/// absent so they do not affect the canonical hash.
pub fn canonicalize(allocator: std.mem.Allocator, meta: Metadata, omit: Omit) !Metadata {
    const xattrs = if (omit.xattr) &[_]Xattr{} else try canonicalXattrs(allocator, meta.xattrs);
    const aces = if (omit.acl) &[_]Ace{} else try canonicalAces(allocator, meta.aces);
    const native_acl = if (omit.acl) null else blk: {
        if (meta.native_acl) |acl| {
            if (acl.bytes.len == 0) return error.EmptyNativeAcl;
        }
        break :blk meta.native_acl;
    };
    const times = if (omit.timestamps) Times{} else meta.times;
    if (!omit.timestamps) {
        try validateTime(times.mtime);
        try validateTime(times.atime);
        try validateTime(times.btime);
    }
    const finder_flags: u32 = if (omit.finder) 0 else meta.finder_flags;
    const finder_info: ?[32]u8 = if (omit.finder) null else meta.finder_info;
    const holes = if (omit.sparse) &[_]Hole{} else try canonicalHoles(allocator, meta.holes);
    const hardlink_to: ?[]const u8 = if (omit.hardlink) null else blk: {
        if (meta.hardlink_to) |path| try validateHardlink(path);
        break :blk meta.hardlink_to;
    };
    return .{
        .xattrs = xattrs,
        .aces = aces,
        .native_acl = native_acl,
        .times = times,
        .finder_flags = finder_flags,
        .finder_info = finder_info,
        .holes = holes,
        .hardlink_to = hardlink_to,
    };
}

/// BLAKE3 over domain `DIFZMETA\x01` and the canonical field layout.
/// Callers hash the output of `canonicalize`.
pub fn canonicalHash(meta: Metadata) [32]u8 {
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update("DIFZMETA\x01");
    writeCanonical(hashPut, &hasher, meta) catch unreachable;
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

/// Byte layout hashed by `canonicalHash` after the domain prefix.
/// Returned slices from `decodeCanonical` alias `bytes`.
pub fn encodeCanonical(allocator: std.mem.Allocator, meta: Metadata) ![]u8 {
    var list: std.ArrayListUnmanaged(u8) = .empty;
    errdefer list.deinit(allocator);
    var ctx = ListCtx{ .allocator = allocator, .list = &list };
    try writeCanonical(listPut, &ctx, meta);
    return list.toOwnedSlice(allocator);
}

/// Strings and blobs borrow `bytes`; the caller owns the xattr, ACE, and hole
/// descriptor arrays allocated through `allocator`.
pub fn decodeCanonical(allocator: std.mem.Allocator, bytes: []const u8) !Metadata {
    var cursor = Cursor{ .bytes = bytes, .pos = 0 };
    const meta = try readCanonical(allocator, &cursor);
    errdefer {
        allocator.free(meta.xattrs);
        allocator.free(meta.aces);
        allocator.free(meta.holes);
    }
    if (cursor.pos != bytes.len) return error.TrailingMetadata;
    try validateCanonical(meta);
    return meta;
}

fn validateCanonical(meta: Metadata) MetaError!void {
    for (meta.xattrs, 0..) |xattr, index| {
        if (isTransportName(xattr.name)) return error.ReservedTransportName;
        switch (xattr.class) {
            .logical => try validateLogical(xattr.name),
            .raw => try validateRaw(xattr.name),
        }
        if (index > 0) {
            const previous = meta.xattrs[index - 1];
            if (previous.class == xattr.class and std.mem.eql(u8, previous.name, xattr.name)) return error.DuplicateXattr;
            if (!xattrLess({}, previous, xattr)) return error.BadMetadata;
        }
    }
    for (meta.aces, 0..) |ace, index| {
        try validateAce(ace);
        if (index > 0) {
            const previous = meta.aces[index - 1];
            if (previous.tag == ace.tag and std.mem.eql(u8, previous.name, ace.name)) return error.DuplicateAce;
            if (!aceLess({}, previous, ace)) return error.BadMetadata;
        }
    }
    if (meta.native_acl) |acl| if (acl.bytes.len == 0) return error.EmptyNativeAcl;
    var previous_end: ?u64 = null;
    for (meta.holes) |hole| {
        if (hole.length == 0) return error.ZeroLengthHole;
        const end = std.math.add(u64, hole.offset, hole.length) catch return error.HoleOverflow;
        if (previous_end) |value| if (hole.offset <= value) return error.BadMetadata;
        previous_end = end;
    }
    if (meta.hardlink_to) |path| try validateHardlink(path);
}

/// Decide native apply versus sidecar preservation for one target OS.
/// A sidecar keeps the canonical record recoverable. If the target cannot
/// store even the sidecar, this returns `PlanImpossible`.
pub fn planRestore(meta: Metadata, caps: Caps) MetaError!Plan {
    var plan = Plan{};
    if (meta.xattrs.len != 0) {
        var logical = false;
        var raw_ok = false;
        var raw_bad = false;
        for (meta.xattrs) |xattr| {
            switch (xattr.class) {
                .logical => logical = true,
                .raw => {
                    if (rawAccepted(caps.os, xattr.name)) raw_ok = true else raw_bad = true;
                },
            }
        }
        if ((logical or raw_bad) and !caps.logical_xattr) return error.PlanImpossible;
        plan.actions.logical_xattr = logical;
        plan.actions.raw_xattr = raw_ok;
        plan.actions.raw_xattr_sidecar = raw_bad;
        if (raw_bad) try push(&plan, .{ .code = .raw_xattr_preserved, .family = .xattr });
    }

    if (meta.native_acl) |native| {
        if (caps.native_acl and native.origin == aclOrigin(caps.os)) {
            plan.actions.native_acl = true;
        } else {
            try requireTransport(caps);
            plan.actions.native_acl_sidecar = true;
            const apply_portable = meta.aces.len != 0 and caps.portable_acl;
            plan.actions.portable_acl = apply_portable;
            if (meta.aces.len != 0 and !caps.portable_acl) plan.actions.portable_acl_sidecar = true;
            try push(&plan, .{
                .code = .native_acl_preserved,
                .family = .acl,
                .portable_acl_applied = apply_portable,
                .origin = native.origin,
            });
            if (meta.aces.len != 0 and !caps.portable_acl) {
                try push(&plan, .{ .code = .portable_acl_preserved, .family = .acl });
            }
        }
    } else if (meta.aces.len != 0) {
        if (caps.portable_acl) {
            plan.actions.portable_acl = true;
        } else {
            try requireTransport(caps);
            plan.actions.portable_acl_sidecar = true;
            try push(&plan, .{ .code = .portable_acl_preserved, .family = .acl });
        }
    }

    if (meta.times.mtime != null or meta.times.atime != null) plan.actions.mtime_atime = true;
    if (meta.times.btime != null) {
        if (caps.set_btime) {
            plan.actions.btime = true;
        } else {
            try requireTransport(caps);
            plan.actions.btime_sidecar = true;
            try push(&plan, .{ .code = .birth_time_preserved, .family = .timestamps });
        }
    }

    if (meta.finder_flags != 0) {
        if (caps.bsd_flags) {
            plan.actions.bsd_flags = true;
        } else {
            try requireTransport(caps);
            plan.actions.bsd_flags_sidecar = true;
            try push(&plan, .{ .code = .finder_flags_preserved, .family = .finder });
        }
    }
    if (meta.finder_info != null) {
        if (caps.finder_info) {
            plan.actions.finder_info = true;
        } else {
            try requireTransport(caps);
            plan.actions.finder_info_sidecar = true;
            try push(&plan, .{ .code = .finder_info_preserved, .family = .finder });
        }
    }

    if (meta.holes.len != 0) {
        if (caps.punch_holes) {
            plan.actions.punch_holes = true;
        } else {
            try requireTransport(caps);
            plan.actions.sparse_sidecar = true;
            try push(&plan, .{ .code = .sparse_preserved, .family = .sparse });
        }
    }

    if (meta.hardlink_to != null) {
        if (caps.hardlink) {
            plan.actions.hardlink = true;
        } else {
            try requireTransport(caps);
            plan.actions.hardlink_copy = true;
            try push(&plan, .{ .code = .hardlink_copied, .family = .hardlink });
        }
    }
    return plan;
}

pub fn compromiseText(compromise: Compromise, buf: []u8) []const u8 {
    switch (compromise.code) {
        .modification_time_preserved => return "modification-time metadata was preserved in difz.mtime",
        .symlink_metadata_preserved => return "symlink metadata was preserved in difz.symlinks on the parent directory",
        .native_acl_preserved => {
            const which = switch (compromise.origin orelse .windows) {
                .linux => "linux",
                .macos => "macos",
                .windows => "windows",
            };
            if (compromise.portable_acl_applied) {
                return std.fmt.bufPrint(buf, "native {s} ACL was not applied; portable permissions were applied and the native ACL was preserved in difz.native-acl", .{which}) catch "";
            }
            return std.fmt.bufPrint(buf, "native {s} ACL was not applied; preserved in difz.native-acl", .{which}) catch "";
        },
        .portable_acl_preserved => return "portable ACL was not applied; preserved in difz.portable-acl",
        .finder_flags_preserved => return "Finder flags were not applied; preserved in difz.bsd-flags",
        .finder_info_preserved => return "Finder info was not applied; preserved in difz.finder-info",
        .birth_time_preserved => return "birth time cannot be set on this OS; preserved in difz.btime",
        .sparse_preserved => return "sparse extents were not punched; preserved in difz.sparse-holes",
        .hardlink_copied => return "hard link was stored as a separate file; the link target was preserved in difz.hardlink-to",
        .raw_xattr_preserved => return "raw attributes that this OS cannot store were preserved in difz.raw-xattrs",
    }
}

/// Conservative per-OS defaults. A filesystem probe may still raise
/// `punch_holes` when the mounted volume supports it.
pub fn defaultCaps(os: Os) Caps {
    return switch (os) {
        .linux => .{
            .os = .linux,
            .set_btime = false,
            .punch_holes = true,
            .hardlink = true,
            .portable_acl = true,
            .native_acl = true,
            .bsd_flags = false,
            .finder_info = false,
            .logical_xattr = true,
        },
        .macos => .{
            .os = .macos,
            .set_btime = true,
            .punch_holes = true,
            .hardlink = true,
            .portable_acl = true,
            .native_acl = true,
            .bsd_flags = true,
            .finder_info = true,
            .logical_xattr = true,
        },
        .windows => .{
            .os = .windows,
            .set_btime = true,
            .punch_holes = false,
            .hardlink = true,
            .portable_acl = false,
            .native_acl = true,
            .bsd_flags = false,
            .finder_info = false,
            .logical_xattr = true,
        },
    };
}

fn familyByName(name: []const u8) ?Family {
    if (std.mem.eql(u8, name, "xattr")) return .xattr;
    if (std.mem.eql(u8, name, "acl")) return .acl;
    if (std.mem.eql(u8, name, "timestamps")) return .timestamps;
    if (std.mem.eql(u8, name, "finder")) return .finder;
    if (std.mem.eql(u8, name, "sparse")) return .sparse;
    if (std.mem.eql(u8, name, "hardlink")) return .hardlink;
    return null;
}

pub fn isTransportName(name: []const u8) bool {
    const bare = if (std.mem.startsWith(u8, name, "user.")) name["user.".len..] else name;
    for (transport_names) |reserved| {
        if (std.mem.eql(u8, bare, reserved)) return true;
    }
    return false;
}

fn validateLogical(name: []const u8) MetaError!void {
    if (name.len == 0) return error.EmptyName;
    if (name.len > 127) return error.InvalidLogicalName;
    const forbidden = "/\\:*?\"<>|";
    for (name) |byte| {
        if (byte < 0x20 or byte == 0x7f) return error.InvalidLogicalName;
        if (std.mem.indexOfScalar(u8, forbidden, byte) != null) return error.InvalidLogicalName;
    }
    if (!std.unicode.utf8ValidateSlice(name)) return error.InvalidLogicalName;
    const last = name[name.len - 1];
    if (name[0] == ' ' or last == ' ' or last == '.') return error.InvalidLogicalName;
    if (std.ascii.startsWithIgnoreCase(name, "user.")) return error.InvalidLogicalName;
    if (std.ascii.startsWithIgnoreCase(name, "com.apple.")) return error.InvalidLogicalName;
    if (std.ascii.startsWithIgnoreCase(name, "$")) return error.InvalidLogicalName;
    if (std.ascii.eqlIgnoreCase(name, "zone.identifier")) return error.InvalidLogicalName;
}

fn validateRaw(name: []const u8) MetaError!void {
    if (name.len == 0) return error.EmptyName;
    if (name.len > 255) return error.InvalidRawName;
    if (std.mem.indexOfScalar(u8, name, 0) != null) return error.InvalidRawName;
    if (std.mem.indexOfScalar(u8, name, '/') != null or std.mem.indexOfScalar(u8, name, '\\') != null) {
        return error.InvalidRawName;
    }
}

pub fn rawAccepted(os: Os, name: []const u8) bool {
    switch (os) {
        .linux => {
            const prefixes = [_][]const u8{ "user.", "system.", "security.", "trusted." };
            for (prefixes) |prefix| {
                if (std.mem.startsWith(u8, name, prefix) and name.len > prefix.len) return true;
            }
            return false;
        },
        .macos => return name.len > 0 and name.len <= 127 and std.mem.indexOfScalar(u8, name, '/') == null,
        .windows => {
            if (name.len == 0 or name.len > 255) return false;
            const forbidden = "/\\:*?\"<>|";
            for (name) |byte| {
                if (std.mem.indexOfScalar(u8, forbidden, byte) != null) return false;
            }
            return true;
        },
    }
}

fn validateHardlink(path: []const u8) MetaError!void {
    if (path.len == 0 or path.len > 4096) return error.InvalidHardlink;
    if (!std.unicode.utf8ValidateSlice(path)) return error.InvalidHardlink;
    if (path[0] == '/' or std.mem.indexOfScalar(u8, path, '\\') != null) return error.InvalidHardlink;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidHardlink;
    if (path.len >= 2 and std.ascii.isAlphabetic(path[0]) and path[1] == ':') return error.InvalidHardlink;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidHardlink;
    }
}

fn validateAce(ace: Ace) MetaError!void {
    const named = ace.tag == .named_user or ace.tag == .named_group;
    if (named) {
        if (ace.name.len == 0 or !std.unicode.utf8ValidateSlice(ace.name)) return error.InvalidAceName;
        if (std.mem.indexOfScalar(u8, ace.name, '/') != null or std.mem.indexOfScalar(u8, ace.name, 0) != null) {
            return error.InvalidAceName;
        }
    } else if (ace.name.len != 0) return error.InvalidAceName;
}

fn validateTime(time: ?Time) MetaError!void {
    if (time) |value| if (value.nsec >= 1_000_000_000) return error.InvalidNsec;
}

fn xattrLess(_: void, left: Xattr, right: Xattr) bool {
    if (left.class != right.class) return @intFromEnum(left.class) < @intFromEnum(right.class);
    return std.mem.order(u8, left.name, right.name) == .lt;
}

fn aceLess(_: void, left: Ace, right: Ace) bool {
    if (left.tag != right.tag) return @intFromEnum(left.tag) < @intFromEnum(right.tag);
    return std.mem.order(u8, left.name, right.name) == .lt;
}

fn holeLess(_: void, left: Hole, right: Hole) bool {
    return left.offset < right.offset;
}

fn canonicalXattrs(allocator: std.mem.Allocator, xattrs: []const Xattr) ![]const Xattr {
    if (xattrs.len == 0) return &.{};
    const copy = try allocator.dupe(Xattr, xattrs);
    for (copy) |xattr| {
        if (isTransportName(xattr.name)) return error.ReservedTransportName;
        switch (xattr.class) {
            .logical => try validateLogical(xattr.name),
            .raw => try validateRaw(xattr.name),
        }
    }
    std.mem.sort(Xattr, copy, {}, xattrLess);
    if (copy.len > 1) {
        for (copy[1..], 0..) |item, index| {
            const prev = copy[index];
            if (item.class == prev.class and std.mem.eql(u8, item.name, prev.name)) return error.DuplicateXattr;
        }
    }
    return copy;
}

fn canonicalAces(allocator: std.mem.Allocator, aces: []const Ace) ![]const Ace {
    if (aces.len == 0) return &.{};
    const copy = try allocator.dupe(Ace, aces);
    for (copy) |ace| try validateAce(ace);
    std.mem.sort(Ace, copy, {}, aceLess);
    if (copy.len > 1) {
        for (copy[1..], 0..) |item, index| {
            const prev = copy[index];
            if (item.tag == prev.tag and std.mem.eql(u8, item.name, prev.name)) return error.DuplicateAce;
        }
    }
    return copy;
}

fn canonicalHoles(allocator: std.mem.Allocator, holes: []const Hole) ![]const Hole {
    if (holes.len == 0) return &.{};
    const copy = try allocator.dupe(Hole, holes);
    for (copy) |hole| {
        if (hole.length == 0) return error.ZeroLengthHole;
        _ = std.math.add(u64, hole.offset, hole.length) catch return error.HoleOverflow;
    }
    std.mem.sort(Hole, copy, {}, holeLess);
    var count: usize = 0;
    for (copy) |hole| {
        const end = hole.offset + hole.length;
        if (count == 0) {
            copy[0] = hole;
            count = 1;
            continue;
        }
        const prev = &copy[count - 1];
        const prev_end = prev.offset + prev.length;
        if (hole.offset <= prev_end) {
            if (end > prev_end) prev.length = end - prev.offset;
        } else {
            copy[count] = hole;
            count += 1;
        }
    }
    return copy[0..count];
}

fn aclOrigin(os: Os) AclOrigin {
    return switch (os) {
        .linux => .linux,
        .macos => .macos,
        .windows => .windows,
    };
}

fn requireTransport(caps: Caps) MetaError!void {
    if (!caps.logical_xattr) return error.PlanImpossible;
}

fn push(plan: *Plan, item: Compromise) MetaError!void {
    if (plan.compromise_len == plan.compromises.len) return error.PlanImpossible;
    plan.compromises[plan.compromise_len] = item;
    plan.compromise_len += 1;
}

const Put = *const fn (ctx: *anyopaque, bytes: []const u8) anyerror!void;

fn hashPut(ctx: *anyopaque, bytes: []const u8) anyerror!void {
    const hasher: *std.crypto.hash.Blake3 = @ptrCast(@alignCast(ctx));
    hasher.update(bytes);
}

const ListCtx = struct {
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(u8),
};

fn listPut(ctx: *anyopaque, bytes: []const u8) anyerror!void {
    const self: *ListCtx = @ptrCast(@alignCast(ctx));
    try self.list.appendSlice(self.allocator, bytes);
}

fn putInt(put: Put, ctx: *anyopaque, comptime T: type, value: T) !void {
    var raw: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &raw, value, .little);
    try put(ctx, &raw);
}

fn writeCanonical(put: Put, ctx: *anyopaque, meta: Metadata) !void {
    try putInt(put, ctx, u32, @intCast(meta.xattrs.len));
    for (meta.xattrs) |xattr| {
        try putInt(put, ctx, u8, @intFromEnum(xattr.class));
        try putInt(put, ctx, u32, @intCast(xattr.name.len));
        try put(ctx, xattr.name);
        try putInt(put, ctx, u32, @intCast(xattr.value.len));
        try put(ctx, xattr.value);
    }
    try putInt(put, ctx, u32, @intCast(meta.aces.len));
    for (meta.aces) |ace| {
        try putInt(put, ctx, u8, @intFromEnum(ace.tag));
        var bits: u8 = 0;
        if (ace.read) bits |= 1;
        if (ace.write) bits |= 2;
        if (ace.execute) bits |= 4;
        try putInt(put, ctx, u8, bits);
        try putInt(put, ctx, u32, @intCast(ace.name.len));
        try put(ctx, ace.name);
    }
    if (meta.native_acl) |acl| {
        try putInt(put, ctx, u8, @intFromEnum(acl.origin));
        try putInt(put, ctx, u32, @intCast(acl.bytes.len));
        try put(ctx, acl.bytes);
    } else try putInt(put, ctx, u8, 0);
    var time_flags: u8 = 0;
    if (meta.times.mtime != null) time_flags |= 1;
    if (meta.times.atime != null) time_flags |= 2;
    if (meta.times.btime != null) time_flags |= 4;
    try putInt(put, ctx, u8, time_flags);
    if (meta.times.mtime) |time| try writeTime(put, ctx, time);
    if (meta.times.atime) |time| try writeTime(put, ctx, time);
    if (meta.times.btime) |time| try writeTime(put, ctx, time);
    try putInt(put, ctx, u32, meta.finder_flags);
    if (meta.finder_info) |info| {
        try putInt(put, ctx, u8, 1);
        try put(ctx, &info);
    } else try putInt(put, ctx, u8, 0);
    try putInt(put, ctx, u32, @intCast(meta.holes.len));
    for (meta.holes) |hole| {
        try putInt(put, ctx, u64, hole.offset);
        try putInt(put, ctx, u64, hole.length);
    }
    if (meta.hardlink_to) |path| {
        try putInt(put, ctx, u8, 1);
        try putInt(put, ctx, u32, @intCast(path.len));
        try put(ctx, path);
    } else try putInt(put, ctx, u8, 0);
}

fn writeTime(put: Put, ctx: *anyopaque, time: Time) !void {
    try putInt(put, ctx, i64, time.sec);
    try putInt(put, ctx, u32, time.nsec);
}

const Cursor = struct {
    bytes: []const u8,
    pos: usize,

    fn take(self: *Cursor, len: usize) MetaError![]const u8 {
        if (len > self.bytes.len -| self.pos) return error.TruncatedMetadata;
        const out = self.bytes[self.pos..][0..len];
        self.pos += len;
        return out;
    }

    fn int(self: *Cursor, comptime T: type) MetaError!T {
        const raw = try self.take(@sizeOf(T));
        return std.mem.readInt(T, raw[0..@sizeOf(T)], .little);
    }

    fn count(self: *Cursor, comptime minimum_record_bytes: usize) MetaError!usize {
        const value = std.math.cast(usize, try self.int(u32)) orelse return error.BadMetadata;
        if (value > (self.bytes.len - self.pos) / minimum_record_bytes) return error.TruncatedMetadata;
        return value;
    }
};

fn readCanonical(allocator: std.mem.Allocator, cursor: *Cursor) !Metadata {
    const xattr_count = try cursor.count(@sizeOf(u8) + 2 * @sizeOf(u32));
    const xattrs = try allocator.alloc(Xattr, xattr_count);
    errdefer allocator.free(xattrs);
    for (xattrs) |*xattr| {
        const class_raw = try cursor.int(u8);
        const class = std.enums.fromInt(XattrClass, class_raw) orelse return error.BadMetadata;
        const name = try cursor.take(std.math.cast(usize, try cursor.int(u32)) orelse return error.BadMetadata);
        const value = try cursor.take(std.math.cast(usize, try cursor.int(u32)) orelse return error.BadMetadata);
        xattr.* = .{ .class = class, .name = name, .value = value };
    }
    const ace_count = try cursor.count(2 * @sizeOf(u8) + @sizeOf(u32));
    const aces = try allocator.alloc(Ace, ace_count);
    errdefer allocator.free(aces);
    for (aces) |*ace| {
        const tag = std.enums.fromInt(AceTag, try cursor.int(u8)) orelse return error.BadMetadata;
        const bits = try cursor.int(u8);
        if (bits & ~@as(u8, 0x7) != 0) return error.BadMetadata;
        const name = try cursor.take(std.math.cast(usize, try cursor.int(u32)) orelse return error.BadMetadata);
        ace.* = .{
            .tag = tag,
            .read = bits & 1 != 0,
            .write = bits & 2 != 0,
            .execute = bits & 4 != 0,
            .name = name,
        };
    }
    const origin_raw = try cursor.int(u8);
    const native_acl: ?NativeAcl = if (origin_raw == 0) null else blk: {
        const origin = std.enums.fromInt(AclOrigin, origin_raw) orelse return error.BadMetadata;
        const blob = try cursor.take(std.math.cast(usize, try cursor.int(u32)) orelse return error.BadMetadata);
        break :blk .{ .origin = origin, .bytes = blob };
    };
    const time_flags = try cursor.int(u8);
    if (time_flags & ~@as(u8, 0x7) != 0) return error.BadMetadata;
    var times = Times{};
    if (time_flags & 1 != 0) times.mtime = try readTime(cursor);
    if (time_flags & 2 != 0) times.atime = try readTime(cursor);
    if (time_flags & 4 != 0) times.btime = try readTime(cursor);
    const finder_flags = try cursor.int(u32);
    const finder_present = try cursor.int(u8);
    const finder_info: ?[32]u8 = switch (finder_present) {
        0 => null,
        1 => blk: {
            const raw = try cursor.take(32);
            var info: [32]u8 = undefined;
            @memcpy(&info, raw);
            break :blk info;
        },
        else => return error.BadMetadata,
    };
    const hole_count = try cursor.count(2 * @sizeOf(u64));
    const holes = try allocator.alloc(Hole, hole_count);
    errdefer allocator.free(holes);
    for (holes) |*hole| {
        hole.* = .{ .offset = try cursor.int(u64), .length = try cursor.int(u64) };
    }
    const link_present = try cursor.int(u8);
    const hardlink_to: ?[]const u8 = switch (link_present) {
        0 => null,
        1 => try cursor.take(std.math.cast(usize, try cursor.int(u32)) orelse return error.BadMetadata),
        else => return error.BadMetadata,
    };
    return .{
        .xattrs = xattrs,
        .aces = aces,
        .native_acl = native_acl,
        .times = times,
        .finder_flags = finder_flags,
        .finder_info = finder_info,
        .holes = holes,
        .hardlink_to = hardlink_to,
    };
}

fn readTime(cursor: *Cursor) !Time {
    const time = Time{ .sec = try cursor.int(i64), .nsec = try cursor.int(u32) };
    if (time.nsec >= 1_000_000_000) return error.InvalidNsec;
    return time;
}

fn hasCompromise(plan: Plan, code: CompromiseCode) bool {
    for (plan.compromises[0..plan.compromise_len]) |item| {
        if (item.code == code) return true;
    }
    return false;
}

test "parseOmit classifies the family set and rejects junk" {
    const none = try parseOmit("");
    try testing.expect(!none.acl and !none.xattr);
    const some = try parseOmit("acl, xattr,hardlink");
    try testing.expect(some.acl and some.xattr and some.hardlink);
    try testing.expect(!some.finder and !some.sparse and !some.timestamps);
    try testing.expectError(error.UnknownFamily, parseOmit("ACL"));
    try testing.expectError(error.DuplicateFamily, parseOmit("acl,acl"));
    try testing.expectError(error.EmptyFamily, parseOmit("acl,"));
    try testing.expectError(error.UnknownFamily, parseOmit("owner"));
}

test "canonicalize sorts, merges, and strips omitted families" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const meta = Metadata{
        .xattrs = &[_]Xattr{
            .{ .class = .logical, .name = "zeta", .value = "2" },
            .{ .class = .raw, .name = "user.raw", .value = "r" },
            .{ .class = .logical, .name = "alpha", .value = "1" },
        },
        .holes = &[_]Hole{
            .{ .offset = 10, .length = 5 },
            .{ .offset = 0, .length = 10 },
            .{ .offset = 100, .length = 4 },
        },
        .aces = &[_]Ace{.{ .tag = .owner, .read = true }},
        .native_acl = .{ .origin = .windows, .bytes = "dacl" },
        .times = .{ .mtime = .{ .sec = 5, .nsec = 1 } },
        .finder_flags = 1,
        .hardlink_to = "kept",
    };
    const got = try canonicalize(allocator, meta, .{ .acl = true, .timestamps = true, .finder = true });
    try testing.expect(got.native_acl == null);
    try testing.expectEqual(@as(usize, 0), got.aces.len);
    try testing.expect(got.times.mtime == null);
    try testing.expectEqual(@as(u32, 0), got.finder_flags);
    try testing.expectEqualStrings("kept", got.hardlink_to.?);
    try testing.expectEqual(@as(usize, 3), got.xattrs.len);
    try testing.expectEqualStrings("alpha", got.xattrs[0].name);
    try testing.expectEqualStrings("zeta", got.xattrs[1].name);
    try testing.expectEqualStrings("user.raw", got.xattrs[2].name);
    try testing.expectEqual(@as(usize, 2), got.holes.len);
    try testing.expectEqual(@as(u64, 0), got.holes[0].offset);
    try testing.expectEqual(@as(u64, 15), got.holes[0].length);
    try testing.expectEqual(@as(u64, 100), got.holes[1].offset);

    const dup = Metadata{ .xattrs = &[_]Xattr{
        .{ .class = .logical, .name = "alpha", .value = "1" },
        .{ .class = .logical, .name = "alpha", .value = "2" },
    } };
    try testing.expectError(error.DuplicateXattr, canonicalize(allocator, dup, .{}));
    try testing.expectError(error.ZeroLengthHole, canonicalize(allocator, .{ .holes = &[_]Hole{.{ .offset = 1, .length = 0 }} }, .{}));
    try testing.expectError(error.ReservedTransportName, canonicalize(allocator, .{ .xattrs = &[_]Xattr{.{ .class = .logical, .name = "difz.btime", .value = "x" }} }, .{}));
    try testing.expectError(error.InvalidLogicalName, canonicalize(allocator, .{ .xattrs = &[_]Xattr{.{ .class = .logical, .name = "com.apple.FinderInfo", .value = "x" }} }, .{}));
    try testing.expectError(error.InvalidNsec, canonicalize(allocator, .{ .times = .{ .mtime = .{ .sec = 1, .nsec = 1_000_000_000 } } }, .{}));
    try testing.expectError(error.InvalidHardlink, canonicalize(allocator, .{ .hardlink_to = "../out" }, .{}));
    try testing.expectError(error.InvalidAceName, canonicalize(allocator, .{ .aces = &[_]Ace{.{ .tag = .owner, .name = "root" }} }, .{}));
    const raw_ok = try canonicalize(allocator, .{ .xattrs = &[_]Xattr{.{ .class = .raw, .name = "com.apple.FinderInfo", .value = "x" }} }, .{});
    try testing.expectEqual(@as(usize, 1), raw_ok.xattrs.len);
}

test "canonical hash ignores order and sees every family" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const first = try canonicalize(allocator, .{ .xattrs = &[_]Xattr{
        .{ .class = .logical, .name = "b", .value = "2" },
        .{ .class = .logical, .name = "a", .value = "1" },
    } }, .{});
    const second = try canonicalize(allocator, .{ .xattrs = &[_]Xattr{
        .{ .class = .logical, .name = "a", .value = "1" },
        .{ .class = .logical, .name = "b", .value = "2" },
    } }, .{});
    const same = canonicalHash(first);
    try testing.expectEqualSlices(u8, &same, &canonicalHash(second));

    const changed = try canonicalize(allocator, .{ .xattrs = &[_]Xattr{.{ .class = .logical, .name = "a", .value = "9" }} }, .{});
    try testing.expect(!std.mem.eql(u8, &same, &canonicalHash(changed)));

    const sparse = try canonicalize(allocator, .{ .holes = &[_]Hole{.{ .offset = 0, .length = 8 }} }, .{});
    const sparse_hash = canonicalHash(sparse);
    const omitted = try canonicalize(allocator, sparse, .{ .sparse = true });
    try testing.expect(!std.mem.eql(u8, &sparse_hash, &canonicalHash(omitted)));
    try testing.expect(omitted.isEmpty());
}

test "restore plans classify native apply against sidecar compromise" {
    const Case = struct {
        name: []const u8,
        meta: Metadata,
        caps: Caps,
        logical: bool = false,
        raw: bool = false,
        raw_side: bool = false,
        portable: bool = false,
        portable_side: bool = false,
        native: bool = false,
        native_side: bool = false,
        times: bool = false,
        btime: bool = false,
        btime_side: bool = false,
        flags: bool = false,
        flags_side: bool = false,
        finder: bool = false,
        finder_side: bool = false,
        punch: bool = false,
        sparse_side: bool = false,
        link: bool = false,
        copy: bool = false,
        code: ?CompromiseCode = null,
    };
    const info = [_]u8{0xab} ** 32;
    const windows_acl = Metadata{
        .aces = &[_]Ace{.{ .tag = .owner, .read = true, .write = true }},
        .native_acl = .{ .origin = .windows, .bytes = "\x01\x02" },
    };
    const cases = [_]Case{
        .{ .name = "empty", .meta = .{}, .caps = defaultCaps(.linux) },
        .{
            .name = "logical",
            .meta = .{ .xattrs = &[_]Xattr{.{ .class = .logical, .name = "comment", .value = "hi" }} },
            .caps = defaultCaps(.linux),
            .logical = true,
        },
        .{
            .name = "windows-acl-on-linux",
            .meta = windows_acl,
            .caps = defaultCaps(.linux),
            .portable = true,
            .native_side = true,
            .code = .native_acl_preserved,
        },
        .{
            .name = "windows-acl-on-windows",
            .meta = windows_acl,
            .caps = defaultCaps(.windows),
            .native = true,
        },
        .{
            .name = "portable-acl-on-linux",
            .meta = .{ .aces = &[_]Ace{.{ .tag = .everyone, .read = true }} },
            .caps = defaultCaps(.linux),
            .portable = true,
        },
        .{
            .name = "portable-acl-on-windows",
            .meta = .{ .aces = &[_]Ace{.{ .tag = .everyone, .read = true }} },
            .caps = defaultCaps(.windows),
            .portable_side = true,
            .code = .portable_acl_preserved,
        },
        .{
            .name = "finder-on-mac",
            .meta = .{ .finder_flags = 0x8000, .finder_info = info },
            .caps = defaultCaps(.macos),
            .flags = true,
            .finder = true,
        },
        .{
            .name = "finder-on-linux",
            .meta = .{ .finder_flags = 0x8000, .finder_info = info },
            .caps = defaultCaps(.linux),
            .flags_side = true,
            .finder_side = true,
            .code = .finder_info_preserved,
        },
        .{
            .name = "btime-linux",
            .meta = .{ .times = .{ .mtime = .{ .sec = 9, .nsec = 0 }, .btime = .{ .sec = 1, .nsec = 2 } } },
            .caps = defaultCaps(.linux),
            .times = true,
            .btime_side = true,
            .code = .birth_time_preserved,
        },
        .{
            .name = "btime-mac",
            .meta = .{ .times = .{ .btime = .{ .sec = 1, .nsec = 2 } } },
            .caps = defaultCaps(.macos),
            .btime = true,
        },
        .{
            .name = "sparse-punch",
            .meta = .{ .holes = &[_]Hole{.{ .offset = 4096, .length = 4096 }} },
            .caps = defaultCaps(.linux),
            .punch = true,
        },
        .{
            .name = "sparse-sidecar",
            .meta = .{ .holes = &[_]Hole{.{ .offset = 4096, .length = 4096 }} },
            .caps = defaultCaps(.windows),
            .sparse_side = true,
            .code = .sparse_preserved,
        },
        .{
            .name = "hardlink",
            .meta = .{ .hardlink_to = "bin/app" },
            .caps = defaultCaps(.linux),
            .link = true,
        },
        .{
            .name = "hardlink-copy",
            .meta = .{ .hardlink_to = "bin/app" },
            .caps = blk: {
                var caps = defaultCaps(.windows);
                caps.hardlink = false;
                break :blk caps;
            },
            .copy = true,
            .code = .hardlink_copied,
        },
        .{
            .name = "raw-apple-on-linux",
            .meta = .{ .xattrs = &[_]Xattr{.{ .class = .raw, .name = "com.apple.FinderInfo", .value = "abcd" }} },
            .caps = defaultCaps(.linux),
            .raw_side = true,
            .code = .raw_xattr_preserved,
        },
        .{
            .name = "raw-apple-on-mac",
            .meta = .{ .xattrs = &[_]Xattr{.{ .class = .raw, .name = "com.apple.FinderInfo", .value = "abcd" }} },
            .caps = defaultCaps(.macos),
            .raw = true,
        },
    };

    for (cases) |case| {
        const plan = planRestore(case.meta, case.caps) catch {
            std.debug.print("plan failed for {s}\n", .{case.name});
            return error.UnexpectedPlanError;
        };
        const got = plan.actions;
        try testing.expectEqual(case.logical, got.logical_xattr);
        try testing.expectEqual(case.raw, got.raw_xattr);
        try testing.expectEqual(case.raw_side, got.raw_xattr_sidecar);
        try testing.expectEqual(case.portable, got.portable_acl);
        try testing.expectEqual(case.portable_side, got.portable_acl_sidecar);
        try testing.expectEqual(case.native, got.native_acl);
        try testing.expectEqual(case.native_side, got.native_acl_sidecar);
        try testing.expectEqual(case.times, got.mtime_atime);
        try testing.expectEqual(case.btime, got.btime);
        try testing.expectEqual(case.btime_side, got.btime_sidecar);
        try testing.expectEqual(case.flags, got.bsd_flags);
        try testing.expectEqual(case.flags_side, got.bsd_flags_sidecar);
        try testing.expectEqual(case.finder, got.finder_info);
        try testing.expectEqual(case.finder_side, got.finder_info_sidecar);
        try testing.expectEqual(case.punch, got.punch_holes);
        try testing.expectEqual(case.sparse_side, got.sparse_sidecar);
        try testing.expectEqual(case.link, got.hardlink);
        try testing.expectEqual(case.copy, got.hardlink_copy);
        if (case.code) |code| {
            try testing.expect(hasCompromise(plan, code));
        } else {
            try testing.expectEqual(@as(usize, 0), plan.compromise_len);
        }
    }
}

test "compromise text names the foreign ACL and the sidecar" {
    var buf: [256]u8 = undefined;
    const text = compromiseText(.{
        .code = .native_acl_preserved,
        .family = .acl,
        .portable_acl_applied = true,
        .origin = .windows,
    }, &buf);
    try testing.expectEqualStrings(
        "native windows ACL was not applied; portable permissions were applied and the native ACL was preserved in difz.native-acl",
        text,
    );
}
test "metadata omission masks exhaust all family subsets and fixed bit assignments" {
    const single = [_]Omit{
        .{ .xattr = true },  .{ .acl = true },    .{ .timestamps = true },
        .{ .finder = true }, .{ .sparse = true }, .{ .hardlink = true },
    };
    for (single, 0..) |omit, index| {
        const bits = @as(u32, 1) << @intCast(index);
        try testing.expectEqual(bits, omit.bits());
        try testing.expectEqualDeep(omit, try Omit.fromBits(bits));
    }
    for (0..64) |bits| {
        const omit = try Omit.fromBits(@intCast(bits));
        try testing.expectEqual(@as(u32, @intCast(bits)), omit.bits());
        try testing.expectEqualDeep(omit, try Omit.fromBits(omit.bits()));
    }
    for (6..32) |index| {
        try testing.expectError(error.InvalidOmitMask, Omit.fromBits(@as(u32, 1) << @intCast(index)));
    }
}

test "metadata collection counts are bounded by the available bytes before allocation" {
    const huge_xattrs = [_]u8{0xff} ** 4;
    const huge_aces = [_]u8{0} ** 4 ++ [_]u8{0xff} ** 4;
    const huge_holes = [_]u8{0} ** 15 ++ [_]u8{0xff} ** 4;
    for ([_][]const u8{ &huge_xattrs, &huge_aces, &huge_holes }) |bytes| {
        try testing.expectError(error.TruncatedMetadata, decodeCanonical(testing.failing_allocator, bytes));
    }
}

test "metadata decoding rejects invalid and noncanonical records" {
    const Case = struct { meta: Metadata, err: anyerror };
    const cases = [_]Case{
        .{ .meta = .{ .xattrs = &.{.{ .class = .logical, .name = "difz.btime", .value = "x" }} }, .err = error.ReservedTransportName },
        .{ .meta = .{ .xattrs = &.{.{ .class = .raw, .name = "a/b", .value = "x" }} }, .err = error.InvalidRawName },
        .{ .meta = .{ .xattrs = &.{.{ .class = .logical, .name = "", .value = "x" }} }, .err = error.EmptyName },
        .{ .meta = .{ .xattrs = &.{
            .{ .class = .logical, .name = "a", .value = "one" },
            .{ .class = .logical, .name = "a", .value = "two" },
        } }, .err = error.DuplicateXattr },
        .{ .meta = .{ .xattrs = &.{
            .{ .class = .logical, .name = "b", .value = "one" },
            .{ .class = .logical, .name = "a", .value = "two" },
        } }, .err = error.BadMetadata },
        .{ .meta = .{ .aces = &.{.{ .tag = .owner, .name = "unexpected" }} }, .err = error.InvalidAceName },
        .{ .meta = .{ .aces = &.{ .{ .tag = .owner }, .{ .tag = .owner, .read = true } } }, .err = error.DuplicateAce },
        .{ .meta = .{ .aces = &.{ .{ .tag = .group }, .{ .tag = .owner } } }, .err = error.BadMetadata },
        .{ .meta = .{ .native_acl = .{ .origin = .linux, .bytes = "" } }, .err = error.EmptyNativeAcl },
        .{ .meta = .{ .holes = &.{.{ .offset = 0, .length = 0 }} }, .err = error.ZeroLengthHole },
        .{ .meta = .{ .holes = &.{.{ .offset = std.math.maxInt(u64), .length = 1 }} }, .err = error.HoleOverflow },
        .{ .meta = .{ .holes = &.{ .{ .offset = 0, .length = 8 }, .{ .offset = 8, .length = 8 } } }, .err = error.BadMetadata },
        .{ .meta = .{ .hardlink_to = "../a" }, .err = error.InvalidHardlink },
    };
    for (cases) |case| {
        const bytes = try encodeCanonical(testing.allocator, case.meta);
        defer testing.allocator.free(bytes);
        try testing.expectError(case.err, decodeCanonical(testing.allocator, bytes));
    }
}

test "metadata decoder releases allocations on truncation and trailing data" {
    const fixture: Metadata = .{
        .xattrs = &.{.{ .class = .logical, .name = "comment", .value = "hi" }},
        .aces = &.{.{ .tag = .owner, .read = true }},
        .native_acl = .{ .origin = .windows, .bytes = "DACL" },
        .times = .{ .mtime = .{ .sec = -1, .nsec = 999_999_999 }, .btime = .{ .sec = 1 } },
        .finder_flags = 0x8000,
        .finder_info = [_]u8{0x11} ** 32,
        .holes = &.{.{ .offset = 4096, .length = 4096 }},
        .hardlink_to = "a.txt",
    };
    const encoded = try encodeCanonical(testing.allocator, fixture);
    defer testing.allocator.free(encoded);
    for (0..encoded.len) |length| {
        try testing.expectError(error.TruncatedMetadata, decodeCanonical(testing.allocator, encoded[0..length]));
    }
    const trailing = try testing.allocator.alloc(u8, encoded.len + 1);
    defer testing.allocator.free(trailing);
    @memcpy(trailing[0..encoded.len], encoded);
    trailing[encoded.len] = 0;
    try testing.expectError(error.TrailingMetadata, decodeCanonical(testing.allocator, trailing));
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(allocator: std.mem.Allocator, bytes: []const u8) !void {
            const meta = try decodeCanonical(allocator, bytes);
            defer allocator.free(meta.xattrs);
            defer allocator.free(meta.aces);
            defer allocator.free(meta.holes);
            const round_trip = try encodeCanonical(allocator, meta);
            defer allocator.free(round_trip);
            try testing.expectEqualSlices(u8, bytes, round_trip);
        }
    }.run, .{encoded});
}
