const std = @import("std");
const Blake3 = std.crypto.hash.Blake3;
const testing = std.testing;

pub const Table = [256]u64;

/// Generate a Gear hash table deterministically from a 32-byte seed.
/// Uses BLAKE3 in keyed mode: for each index 0-255, create a keyed hasher
/// with the seed, update with the index byte, finalize to 32 bytes, take
/// first 8 bytes as little-endian u64.
pub fn generateTable(seed: [32]u8) Table {
	var table: Table = undefined;
	for (0..256) |i| {
		var hasher = Blake3.init(.{ .key = seed });
		hasher.update(&[_]u8{@intCast(i)});
		var out: [32]u8 = undefined;
		hasher.final(&out);
		table[i] = std.mem.readInt(u64, out[0..8], .little);
	}
	return table;
}

/// Compute Gear hash of a byte slice (non-rolling convenience function).
/// Calls roll() for each byte, starting from state 0.
pub fn hash(table: *const Table, data: []const u8) u64 {
	var state: u64 = 0;
	for (data) |byte| {
		state = roll(table, state, byte);
	}
	return state;
}

/// Single step of the Gear rolling hash.
/// Shifts state left by 1 bit and adds the table entry for the byte (wrapping).
pub fn roll(table: *const Table, state: u64, byte: u8) u64 {
	return (state << 1) +% table.*[byte];
}

test "generateTable produces deterministic output from seed" {
	const seed = [_]u8{0} ** 32;
	const table1 = generateTable(seed);
	const table2 = generateTable(seed);
	try testing.expectEqualSlices(u64, &table1, &table2);
}

test "generateTable produces different output for different seeds" {
	const seed1 = [_]u8{0} ** 32;
	const seed2 = [_]u8{1} ** 32;
	const table1 = generateTable(seed1);
	const table2 = generateTable(seed2);
	var all_same = true;
	for (table1, table2) |a, b| {
		if (a != b) {
			all_same = false;
			break;
		}
	}
	try testing.expect(!all_same);
}

test "hash of empty input is zero" {
	const seed = [_]u8{0} ** 32;
	const table = generateTable(seed);
	try testing.expectEqual(@as(u64, 0), hash(&table, &[_]u8{}));
}

test "hash is deterministic" {
	const seed = [_]u8{42} ** 32;
	const table = generateTable(seed);
	const data = "hello world";
	try testing.expectEqual(hash(&table, data), hash(&table, data));
}

test "hash changes with different input" {
	const seed = [_]u8{42} ** 32;
	const table = generateTable(seed);
	try testing.expect(hash(&table, "hello") != hash(&table, "world"));
}

test "rolling hash matches full hash" {
	const seed = [_]u8{7} ** 32;
	const table = generateTable(seed);
	const data = "abcdefghij";
	const full = hash(&table, data);
	var state: u64 = 0;
	for (data) |byte| {
		state = roll(&table, state, byte);
	}
	try testing.expectEqual(full, state);
}
