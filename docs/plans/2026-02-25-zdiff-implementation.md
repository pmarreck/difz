# ZDiff Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a fast, concise binary differ that uses CDC + Elder/Myers O(ND) to produce BLIP-encoded diffs.

**Architecture:** Zig core (pure, no I/O) with C FFI boundary. C CLI dogfoods the FFI. Two-stage algorithm: Gear hash CDC finds matching chunks, Elder diff refines gaps. Output is a BLIP ARRAY container.

**Tech Stack:** Zig 0.15.x, BLIP library (pmarreck/BLIP), BLAKE3 (Zig stdlib), Nix flake for deps.

---

## Task 1: Project Scaffolding

**Files:**
- Create: `flake.nix`
- Create: `build.zig`
- Create: `build.zig.zon`
- Create: `src/lib.zig` (empty placeholder)
- Create: `build` (shell script)
- Create: `test` (shell script)
- Create: `bm` (shell script)
- Create: `.gitignore`
- Create: `PLAN.md`

**Step 1: Create flake.nix**

```nix
{
  description = "ZDiff: fast binary differ using CDC + Elder/Myers O(ND)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            zig
            hyperfine
            bsdiff
            xdelta
          ];
        };

        packages.default = pkgs.stdenv.mkDerivation {
          pname = "zdiff";
          version = "0.1.0";
          src = ./.;
          nativeBuildInputs = [ pkgs.zig ];
          dontConfigure = true;
          dontInstall = true;
          doCheck = true;
          buildPhase = ''
            mkdir -p .cache
            zig build --cache-dir $(pwd)/.cache --global-cache-dir $(pwd)/.cache -Doptimize=ReleaseFast --prefix $out
          '';
          checkPhase = ''
            zig build test --cache-dir $(pwd)/.cache --global-cache-dir $(pwd)/.cache
          '';
        };
      }
    );
}
```

**Step 2: Create build.zig.zon**

```zig
.{
    .name = .zdiff,
    .version = "0.1.0",
    .minimum_zig_version = "0.15.0",
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "src",
    },
    .dependencies = .{
        .blip = .{
            .url = "https://github.com/pmarreck/BLIP/archive/refs/heads/yolo.tar.gz",
            // hash will be determined on first build attempt
        },
    },
}
```

Note: The `.blip` dependency hash must be determined by running `zig build` and copying the expected hash from the error message.

**Step 3: Create build.zig**

Minimal build.zig that:
- Gets the BLIP dependency and its "blip" module
- Creates a zdiff Zig module (src/lib.zig) that imports "blip"
- Adds a static library with C FFI
- Adds a test step
- Uses ReleaseFast by default per AGENTS.md

**Step 4: Create src/lib.zig**

Minimal placeholder that imports blip and compiles:
```zig
const blip = @import("blip");
const std = @import("std");

// zdiff version
pub const version = "0.1.0";

test "blip dependency works" {
    var buf: [16]u8 = undefined;
    const n = try blip.encode(42, &buf);
    const result = try blip.decode(buf[0..n]);
    try std.testing.expectEqual(@as(u64, 42), result.value);
}
```

**Step 5: Create build, test, bm scripts**

`build`: calls `nix develop -c zig build` with appropriate flags
`test`: calls `nix develop -c zig build test` and accumulates errors
`bm`: placeholder that asserts no DEBUG BUILD

**Step 6: Create .gitignore**

```
zig-out/
zig-cache/
.zig-cache/
.cache/
result
```

**Step 7: Create PLAN.md**

Initial plan with checkboxes for implementation tasks.

**Step 8: Run test to verify scaffolding works**

Run: `nix develop -c zig build test`
Expected: PASS (the blip dependency resolves, the smoke test passes)

**Step 9: Commit**

```bash
git add flake.nix build.zig build.zig.zon src/lib.zig build test bm .gitignore PLAN.md
git commit -m "Scaffold zdiff project with BLIP dependency"
```

---

## Task 2: Gear Hash

**Files:**
- Create: `src/gear_hash.zig`
- Modify: `src/lib.zig` (re-export)
- Modify: `build.zig` (add to test)

The Gear hash is a rolling hash that maps each byte through a 256-entry u64 lookup table. The table is generated deterministically from a 32-byte seed using BLAKE3 in keyed mode.

**Step 1: Write failing tests for Gear hash**

In `src/gear_hash.zig`, write tests:

```zig
const std = @import("std");

test "generateTable produces deterministic output from seed" {
    const seed = [_]u8{0} ** 32;
    const table1 = generateTable(seed);
    const table2 = generateTable(seed);
    try std.testing.expectEqualSlices(u64, &table1, &table2);
}

test "generateTable produces different output for different seeds" {
    const seed1 = [_]u8{0} ** 32;
    const seed2 = [_]u8{1} ** 32;
    const table1 = generateTable(seed1);
    const table2 = generateTable(seed2);
    // At least one entry must differ
    var all_same = true;
    for (table1, table2) |a, b| {
        if (a != b) { all_same = false; break; }
    }
    try std.testing.expect(!all_same);
}

test "hash of empty input is zero" {
    const seed = [_]u8{0} ** 32;
    const table = generateTable(seed);
    try std.testing.expectEqual(@as(u64, 0), hash(&table, &[_]u8{}));
}

test "hash is deterministic" {
    const seed = [_]u8{42} ** 32;
    const table = generateTable(seed);
    const data = "hello world";
    try std.testing.expectEqual(hash(&table, data), hash(&table, data));
}

test "hash changes with different input" {
    const seed = [_]u8{42} ** 32;
    const table = generateTable(seed);
    try std.testing.expect(hash(&table, "hello") != hash(&table, "world"));
}

test "rolling hash matches full hash" {
    const seed = [_]u8{7} ** 32;
    const table = generateTable(seed);
    const data = "abcdefghij";
    // Full hash of entire data
    const full = hash(&table, data);
    // Rolling: feed bytes one at a time
    var state: u64 = 0;
    for (data) |byte| {
        state = roll(&table, state, byte);
    }
    try std.testing.expectEqual(full, state);
}
```

**Step 2: Run tests to verify they fail**

Run: `nix develop -c zig build test`
Expected: FAIL (functions not defined)

**Step 3: Implement Gear hash**

```zig
const std = @import("std");
const Blake3 = std.crypto.hash.Blake3;

/// 256-entry u64 lookup table for Gear hash.
pub const Table = [256]u64;

/// Generate a Gear hash table deterministically from a 32-byte seed.
/// Uses BLAKE3 in keyed mode to expand the seed into 256 * 8 = 2048 bytes.
pub fn generateTable(seed: [32]u8) Table {
    var table: Table = undefined;
    // Use BLAKE3 with the seed as key, hash sequential counter bytes
    for (0..256) |i| {
        var hasher = Blake3.init(.{ .key = seed });
        const idx: [1]u8 = .{@intCast(i)};
        hasher.update(&idx);
        var out: [32]u8 = undefined;
        hasher.final(&out);
        // Take first 8 bytes as little-endian u64
        table[i] = std.mem.readInt(u64, out[0..8], .little);
    }
    return table;
}

/// Compute Gear hash of a byte slice (non-rolling, for testing).
pub fn hash(table: *const Table, data: []const u8) u64 {
    var state: u64 = 0;
    for (data) |byte| {
        state = roll(table, state, byte);
    }
    return state;
}

/// Single step of the Gear rolling hash.
/// state = (state << 1) + table[byte]
pub fn roll(table: *const Table, state: u64, byte: u8) u64 {
    return (state << 1) +% table[byte];
}
```

**Step 4: Run tests to verify they pass**

Run: `nix develop -c zig build test`
Expected: PASS

**Step 5: Commit**

```bash
git add src/gear_hash.zig
git commit -m "Add Gear hash rolling hash with seed-based table generation"
```

---

## Task 3: CDC (Content-Defined Chunking)

**Files:**
- Create: `src/cdc.zig`
- Modify: `src/lib.zig` (re-export)

CDC splits a byte slice into variable-size chunks by scanning with the Gear hash and cutting when `hash & mask == 0`. The mask is derived from the target average chunk size.

**Step 1: Write failing tests for CDC**

```zig
test "chunk empty input produces no chunks" {
    const seed = [_]u8{0} ** 32;
    const chunks = try chunkSlice(testing.allocator, &[_]u8{}, seed, 1024);
    defer testing.allocator.free(chunks);
    try testing.expectEqual(@as(usize, 0), chunks.len);
}

test "chunk single byte produces one chunk" {
    const seed = [_]u8{0} ** 32;
    const data = [_]u8{0x42};
    const chunks = try chunkSlice(testing.allocator, &data, seed, 1024);
    defer testing.allocator.free(chunks);
    try testing.expectEqual(@as(usize, 1), chunks.len);
    try testing.expectEqual(@as(usize, 0), chunks[0].offset);
    try testing.expectEqual(@as(usize, 1), chunks[0].length);
}

test "chunks cover entire input without gaps or overlaps" {
    const seed = [_]u8{42} ** 32;
    // Use random to generate deterministic test data
    var prng = std.Random.DefaultPrng.init(12345);
    var data: [8192]u8 = undefined;
    prng.random().bytes(&data);
    const chunks = try chunkSlice(testing.allocator, &data, seed, 256);
    defer testing.allocator.free(chunks);

    // First chunk starts at 0
    try testing.expectEqual(@as(usize, 0), chunks[0].offset);
    // Each chunk starts where previous ended
    for (1..chunks.len) |i| {
        try testing.expectEqual(
            chunks[i - 1].offset + chunks[i - 1].length,
            chunks[i].offset,
        );
    }
    // Last chunk ends at data.len
    const last = chunks[chunks.len - 1];
    try testing.expectEqual(data.len, last.offset + last.length);
}

test "same input and seed produce same chunks" {
    const seed = [_]u8{7} ** 32;
    const data = "the quick brown fox jumps over the lazy dog" ** 20;
    const c1 = try chunkSlice(testing.allocator, data, seed, 64);
    defer testing.allocator.free(c1);
    const c2 = try chunkSlice(testing.allocator, data, seed, 64);
    defer testing.allocator.free(c2);
    try testing.expectEqual(c1.len, c2.len);
    for (c1, c2) |a, b| {
        try testing.expectEqual(a.offset, b.offset);
        try testing.expectEqual(a.length, b.length);
    }
}

test "different seeds produce different chunk boundaries" {
    const data = "the quick brown fox jumps over the lazy dog" ** 20;
    const c1 = try chunkSlice(testing.allocator, data, [_]u8{1} ** 32, 64);
    defer testing.allocator.free(c1);
    const c2 = try chunkSlice(testing.allocator, data, [_]u8{2} ** 32, 64);
    defer testing.allocator.free(c2);
    // Boundaries should (almost certainly) differ
    try testing.expect(c1.len != c2.len or c1[1].offset != c2[1].offset);
}

test "average chunk size is roughly target" {
    const seed = [_]u8{99} ** 32;
    var prng = std.Random.DefaultPrng.init(54321);
    var data: [65536]u8 = undefined;
    prng.random().bytes(&data);
    const target: usize = 1024;
    const chunks = try chunkSlice(testing.allocator, &data, seed, target);
    defer testing.allocator.free(chunks);
    const avg = data.len / chunks.len;
    // Average should be within 2x of target (loose but sensible)
    try testing.expect(avg > target / 3);
    try testing.expect(avg < target * 3);
}
```

**Step 2: Run tests to verify they fail**

Run: `nix develop -c zig build test`
Expected: FAIL

**Step 3: Implement CDC**

```zig
const std = @import("std");
const gear_hash = @import("gear_hash.zig");

pub const Chunk = struct {
    offset: usize,
    length: usize,
};

/// Chunk a byte slice using Gear hash CDC.
/// Returns a list of Chunk structs covering the entire input.
/// `target_size` is the desired average chunk size in bytes.
pub fn chunkSlice(
    allocator: std.mem.Allocator,
    data: []const u8,
    seed: [32]u8,
    target_size: usize,
) ![]Chunk {
    if (data.len == 0) return try allocator.alloc(Chunk, 0);

    const table = gear_hash.generateTable(seed);

    // mask = target_size - 1 (requires target_size is power of 2)
    // If not power of 2, round up to next power of 2
    const mask = blk: {
        var v = target_size;
        v -= 1;
        v |= v >> 1;
        v |= v >> 2;
        v |= v >> 4;
        v |= v >> 8;
        v |= v >> 16;
        break :blk v;
    };

    // Min/max chunk sizes to prevent degenerate cases
    const min_size = target_size / 4;
    const max_size = target_size * 4;

    var chunks = std.ArrayListUnmanaged(Chunk){};
    defer chunks.deinit(allocator); // only on error path

    var chunk_start: usize = 0;
    var state: u64 = 0;

    for (data, 0..) |byte, i| {
        state = gear_hash.roll(&table, state, byte);
        const chunk_len = i + 1 - chunk_start;

        const at_boundary = (state & mask == 0) and (chunk_len >= min_size);
        const at_max = chunk_len >= max_size;

        if (at_boundary or at_max) {
            try chunks.append(allocator, .{
                .offset = chunk_start,
                .length = chunk_len,
            });
            chunk_start = i + 1;
            state = 0;
        }
    }

    // Final chunk (remainder)
    if (chunk_start < data.len) {
        try chunks.append(allocator, .{
            .offset = chunk_start,
            .length = data.len - chunk_start,
        });
    }

    return try chunks.toOwnedSlice(allocator);
}
```

**Step 4: Run tests to verify they pass**

Run: `nix develop -c zig build test`
Expected: PASS

**Step 5: Commit**

```bash
git add src/cdc.zig
git commit -m "Add CDC chunking with Gear hash boundary detection"
```

---

## Task 4: Chunk Matching (CDC Stage 2)

**Files:**
- Create: `src/chunk_match.zig`

Given two chunked files, find matching chunks by comparing BLAKE3 hashes. Then invert the matches to produce gap regions.

**Step 1: Write failing tests**

```zig
test "identical files produce one match covering everything" {
    const data = "hello world this is test data" ** 10;
    const seed = [_]u8{0} ** 32;
    const matches = try findMatches(testing.allocator, data, data, seed, 64);
    defer testing.allocator.free(matches);
    // Should have matches covering the full file
    var total_matched: usize = 0;
    for (matches) |m| total_matched += m.length;
    try testing.expectEqual(data.len, total_matched);
}

test "completely different files produce no matches" {
    var prng1 = std.Random.DefaultPrng.init(111);
    var prng2 = std.Random.DefaultPrng.init(222);
    var a: [4096]u8 = undefined;
    var b: [4096]u8 = undefined;
    prng1.random().bytes(&a);
    prng2.random().bytes(&b);
    const seed = [_]u8{0} ** 32;
    const matches = try findMatches(testing.allocator, &a, &b, seed, 256);
    defer testing.allocator.free(matches);
    try testing.expectEqual(@as(usize, 0), matches.len);
}

test "invertMatches covers full file lengths" {
    // One match in the middle
    const matches = &[_]Match{.{ .offset_a = 100, .offset_b = 200, .length = 50 }};
    const gaps = try invertMatches(testing.allocator, matches, 300, 400);
    defer {
        testing.allocator.free(gaps.gaps_a);
        testing.allocator.free(gaps.gaps_b);
    }
    // gaps_a: [0..100), [150..300)
    try testing.expectEqual(@as(usize, 2), gaps.gaps_a.len);
    try testing.expectEqual(@as(usize, 0), gaps.gaps_a[0].offset);
    try testing.expectEqual(@as(usize, 100), gaps.gaps_a[0].length);
    try testing.expectEqual(@as(usize, 150), gaps.gaps_a[1].offset);
    try testing.expectEqual(@as(usize, 150), gaps.gaps_a[1].length);
}

test "round-trip: files with shared prefix produce correct gaps" {
    const shared = "shared prefix data " ** 20;
    const a = shared ++ "AAAA unique to A";
    const b = shared ++ "BBBB unique to B";
    const seed = [_]u8{0} ** 32;
    const matches = try findMatches(testing.allocator, a, b, seed, 32);
    defer testing.allocator.free(matches);
    // Should have matches in the shared region
    var total_matched: usize = 0;
    for (matches) |m| total_matched += m.length;
    try testing.expect(total_matched > 0);
    try testing.expect(total_matched <= shared.len);
}
```

**Step 2: Run tests to verify they fail**

Run: `nix develop -c zig build test`
Expected: FAIL

**Step 3: Implement chunk matching**

Core algorithm:
1. Chunk both A and B with CDC
2. BLAKE3-hash each chunk
3. Build HashMap(blake3_hash -> list of (offset, length)) from B's chunks
4. Walk A's chunks, look up in B's map
5. Collect matches as (offset_a, offset_b, length) triples
6. Sort by offset_a, merge adjacent

`invertMatches`: given sorted matches and file lengths, produce gap regions for both A and B.

**Step 4: Run tests to verify they pass**

**Step 5: Commit**

```bash
git add src/chunk_match.zig
git commit -m "Add CDC chunk matching and gap inversion"
```

---

## Task 5: Elder/Myers O(ND) Byte Diff

**Files:**
- Create: `src/elder_diff.zig`

Implementation of the O(ND) difference algorithm for byte sequences. Operates on two byte slices and produces a list of Copy/Insert instructions.

**Step 1: Write failing tests**

```zig
test "diff of identical slices is single Copy" {
    const data = "hello";
    const ops = try diff(testing.allocator, data, data);
    defer testing.allocator.free(ops);
    try testing.expectEqual(@as(usize, 1), ops.len);
    try testing.expectEqual(DiffOp.Tag.copy, ops[0].tag);
    try testing.expectEqual(@as(usize, 0), ops[0].offset);
    try testing.expectEqual(@as(usize, 5), ops[0].length);
}

test "diff of empty A into non-empty B is single Insert" {
    const ops = try diff(testing.allocator, "", "hello");
    defer freeOps(testing.allocator, ops);
    try testing.expectEqual(@as(usize, 1), ops.len);
    try testing.expectEqual(DiffOp.Tag.insert, ops[0].tag);
    try testing.expectEqualStrings("hello", ops[0].data.?);
}

test "diff of non-empty A into empty B is empty (no ops needed)" {
    const ops = try diff(testing.allocator, "hello", "");
    defer testing.allocator.free(ops);
    try testing.expectEqual(@as(usize, 0), ops.len);
}

test "diff with insertion in middle" {
    const a = "helloworld";
    const b = "hello_world";
    const ops = try diff(testing.allocator, a, b);
    defer freeOps(testing.allocator, ops);
    // Apply ops to A and verify we get B
    const result = try applyOps(testing.allocator, a, ops);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings(b, result);
}

test "diff with deletion" {
    const a = "hello world";
    const b = "helloworld";
    const ops = try diff(testing.allocator, a, b);
    defer freeOps(testing.allocator, ops);
    const result = try applyOps(testing.allocator, a, ops);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings(b, result);
}

test "diff with replacement" {
    const a = "hello";
    const b = "hXllo";
    const ops = try diff(testing.allocator, a, b);
    defer freeOps(testing.allocator, ops);
    const result = try applyOps(testing.allocator, a, ops);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings(b, result);
}

test "round-trip property on random data" {
    var prng = std.Random.DefaultPrng.init(42);
    var a: [256]u8 = undefined;
    var b: [256]u8 = undefined;
    prng.random().bytes(&a);
    // b = a with some random mutations
    @memcpy(&b, &a);
    for (0..30) |_| {
        const idx = prng.random().intRangeLessThan(usize, 0, 256);
        b[idx] = prng.random().int(u8);
    }
    const ops = try diff(testing.allocator, &a, &b);
    defer freeOps(testing.allocator, ops);
    const result = try applyOps(testing.allocator, &a, ops);
    defer testing.allocator.free(result);
    try testing.expectEqualSlices(u8, &b, result);
}
```

**Step 2: Run tests to verify they fail**

**Step 3: Implement Elder/Myers O(ND) diff**

The algorithm:
1. Compute the shortest edit script using the O(ND) greedy algorithm
2. Walk the edit script and emit Copy/Insert operations
3. Merge adjacent Copies, merge adjacent Inserts

The `DiffOp` type:
```zig
pub const DiffOp = struct {
    pub const Tag = enum { copy, insert };
    tag: Tag,
    offset: usize,  // for copy: offset in A. for insert: offset in B where data comes from
    length: usize,
    data: ?[]const u8, // for insert: the actual bytes. null for copy.
};
```

`applyOps` is a test helper that reconstructs B from A + ops:
```zig
fn applyOps(allocator: Allocator, a: []const u8, ops: []const DiffOp) ![]u8 {
    var result = std.ArrayListUnmanaged(u8){};
    for (ops) |op| {
        switch (op.tag) {
            .copy => try result.appendSlice(allocator, a[op.offset..][0..op.length]),
            .insert => try result.appendSlice(allocator, op.data.?),
        }
    }
    return try result.toOwnedSlice(allocator);
}
```

**Step 4: Run tests to verify they pass**

**Step 5: Commit**

```bash
git add src/elder_diff.zig
git commit -m "Add Elder/Myers O(ND) byte-level diff algorithm"
```

---

## Task 6: Two-Stage Diff Orchestrator

**Files:**
- Create: `src/diff.zig`

Combines CDC chunk matching (Task 4) with Elder diff (Task 5) into the full two-stage algorithm.

**Step 1: Write failing tests**

```zig
test "diff identical files produces minimal output" {
    const data = "hello world" ** 100;
    const result = try computeDiff(testing.allocator, data, data, .{
        .seed = [_]u8{0} ** 32,
        .target_chunk_size = 64,
    });
    defer freeDiffResult(testing.allocator, result);
    // Should be a single Copy
    try testing.expectEqual(@as(usize, 1), result.ops.len);
    try testing.expectEqual(DiffOp.Tag.copy, result.ops[0].tag);
}

test "diff completely different files produces Insert of entire B" {
    var prng1 = std.Random.DefaultPrng.init(111);
    var prng2 = std.Random.DefaultPrng.init(222);
    var a: [4096]u8 = undefined;
    var b: [4096]u8 = undefined;
    prng1.random().bytes(&a);
    prng2.random().bytes(&b);
    const result = try computeDiff(testing.allocator, &a, &b, .{
        .seed = [_]u8{0} ** 32,
        .target_chunk_size = 256,
    });
    defer freeDiffResult(testing.allocator, result);
    // Apply and verify
    const reconstructed = try applyDiff(testing.allocator, &a, result.ops);
    defer testing.allocator.free(reconstructed);
    try testing.expectEqualSlices(u8, &b, reconstructed);
}

test "round-trip: files with shared regions" {
    // Build two files that share a large prefix and suffix
    const shared_prefix = "SHARED PREFIX " ** 50;
    const shared_suffix = " SHARED SUFFIX" ** 50;
    const a = shared_prefix ++ "AAA middle of A" ++ shared_suffix;
    const b = shared_prefix ++ "BBB different middle" ++ shared_suffix;
    const result = try computeDiff(testing.allocator, a, b, .{
        .seed = [_]u8{0} ** 32,
        .target_chunk_size = 64,
    });
    defer freeDiffResult(testing.allocator, result);
    const reconstructed = try applyDiff(testing.allocator, a, result.ops);
    defer testing.allocator.free(reconstructed);
    try testing.expectEqualStrings(b, reconstructed);
}

test "diff B empty" {
    const result = try computeDiff(testing.allocator, "hello", "", .{
        .seed = [_]u8{0} ** 32,
        .target_chunk_size = 64,
    });
    defer freeDiffResult(testing.allocator, result);
    const reconstructed = try applyDiff(testing.allocator, "hello", result.ops);
    defer testing.allocator.free(reconstructed);
    try testing.expectEqualStrings("", reconstructed);
}

test "diff A empty" {
    const result = try computeDiff(testing.allocator, "", "hello", .{
        .seed = [_]u8{0} ** 32,
        .target_chunk_size = 64,
    });
    defer freeDiffResult(testing.allocator, result);
    const reconstructed = try applyDiff(testing.allocator, "", result.ops);
    defer testing.allocator.free(reconstructed);
    try testing.expectEqualStrings("hello", reconstructed);
}
```

**Step 2: Run tests to verify they fail**

**Step 3: Implement orchestrator**

```zig
pub const DiffOptions = struct {
    seed: [32]u8,
    target_chunk_size: usize,
};

pub const DiffResult = struct {
    ops: []DiffOp,
    options: DiffOptions,
    size_a: usize,
    size_b: usize,
};

pub fn computeDiff(allocator: Allocator, a: []const u8, b: []const u8, options: DiffOptions) !DiffResult {
    // Stage 1: CDC chunk matching
    const matches = try chunk_match.findMatches(allocator, a, b, options.seed, options.target_chunk_size);
    defer allocator.free(matches);

    const gap_result = try chunk_match.invertMatches(allocator, matches, a.len, b.len);
    defer { allocator.free(gap_result.gaps_a); allocator.free(gap_result.gaps_b); }

    // Stage 2: Elder diff on each gap pair
    // ... combine matched regions (as Copy ops) with Elder diff results on gaps

    return .{ .ops = ops, .options = options, .size_a = a.len, .size_b = b.len };
}
```

**Step 4: Run tests to verify they pass**

**Step 5: Commit**

```bash
git add src/diff.zig
git commit -m "Add two-stage diff orchestrator (CDC + Elder)"
```

---

## Task 7: BLIP Encoding of Diff Output

**Files:**
- Create: `src/encoding.zig`

Serialize a DiffResult into a BLIP ARRAY container, and deserialize back.

**Step 1: Write failing tests**

```zig
test "encode then decode produces identical ops" {
    // Build a small DiffResult
    var ops = [_]DiffOp{
        .{ .tag = .copy, .offset = 0, .length = 100, .data = null },
        .{ .tag = .insert, .offset = 0, .length = 5, .data = "hello" },
        .{ .tag = .copy, .offset = 105, .length = 200, .data = null },
    };
    const result = DiffResult{
        .ops = &ops,
        .options = .{ .seed = [_]u8{42} ** 32, .target_chunk_size = 1024 },
        .size_a = 305,
        .size_b = 305,
    };
    const encoded = try encode(testing.allocator, result);
    defer testing.allocator.free(encoded);

    // Verify it starts with ZDIF magic
    // (Check first few bytes after ARRAY header)

    const decoded = try decode(testing.allocator, encoded);
    defer freeDecoded(testing.allocator, decoded);
    try testing.expectEqual(result.ops.len, decoded.ops.len);
    try testing.expectEqual(result.size_a, decoded.size_a);
    try testing.expectEqual(result.size_b, decoded.size_b);
    try testing.expectEqualSlices(u8, &result.options.seed, &decoded.options.seed);
}

test "encoded diff is valid BLIP container" {
    // ... encode a simple diff, then parse it with blip.array_mod.ArrayReader
}
```

**Step 2: Run tests to verify they fail**

**Step 3: Implement BLIP encoding/decoding**

Using the BLIP library API:
- `blip.array_mod.serializeArray` for the top-level and instructions arrays
- `blip.data_mod.serializeData` or leaf serialization for raw instruction data
- Dict serialization for metadata

**Step 4: Run tests to verify they pass**

**Step 5: Commit**

```bash
git add src/encoding.zig
git commit -m "Add BLIP encoding/decoding for diff instructions"
```

---

## Task 8: Patch (Apply Diff)

**Files:**
- Create: `src/patch.zig`

Apply a BLIP-encoded diff to file A to reconstruct file B.

**Step 1: Write failing tests**

```zig
test "full round-trip: diff then patch" {
    const a = "the quick brown fox" ** 50;
    const b = "the quick red fox" ** 50;
    const options = DiffOptions{ .seed = [_]u8{0} ** 32, .target_chunk_size = 64 };
    const result = try diff_mod.computeDiff(testing.allocator, a, b, options);
    defer diff_mod.freeDiffResult(testing.allocator, result);
    const encoded = try encoding_mod.encode(testing.allocator, result);
    defer testing.allocator.free(encoded);
    const reconstructed = try patch(testing.allocator, a, encoded);
    defer testing.allocator.free(reconstructed);
    try testing.expectEqualStrings(b, reconstructed);
}

test "patch with malformed diff returns error" {
    const result = patch(testing.allocator, "hello", "not a valid diff");
    try testing.expectError(error.InvalidMagic, result);
}
```

**Step 2: Run tests to verify they fail**

**Step 3: Implement patch**

```zig
pub fn patch(allocator: Allocator, a: []const u8, diff_blob: []const u8) ![]u8 {
    const decoded = try encoding_mod.decode(allocator, diff_blob);
    defer encoding_mod.freeDecoded(allocator, decoded);

    var result = std.ArrayListUnmanaged(u8){};
    for (decoded.ops) |op| {
        switch (op.tag) {
            .copy => try result.appendSlice(allocator, a[op.offset..][0..op.length]),
            .insert => try result.appendSlice(allocator, op.data.?),
        }
    }
    return try result.toOwnedSlice(allocator);
}
```

**Step 4: Run tests to verify they pass**

**Step 5: Commit**

```bash
git add src/patch.zig
git commit -m "Add patch module to apply BLIP-encoded diffs"
```

---

## Task 9: C FFI Layer

**Files:**
- Modify: `src/lib.zig`
- Create: `src/zdiff.h`
- Modify: `build.zig` (add static library + header install)

**Step 1: Write failing FFI tests in lib.zig**

```zig
test "C FFI: zdiff_diff and zdiff_patch round-trip" {
    const a = "the quick brown fox" ** 50;
    const b = "the quick red fox" ** 50;
    var diff_out: [*]u8 = undefined;
    var diff_len: usize = undefined;
    const rc = zdiff_diff(a.ptr, a.len, b.ptr, b.len, /* seed */ null, 64, &diff_out, &diff_len);
    try testing.expectEqual(@as(i32, 0), rc);
    defer zdiff_free(diff_out, diff_len);

    var patch_out: [*]u8 = undefined;
    var patch_len: usize = undefined;
    const rc2 = zdiff_patch(a.ptr, a.len, diff_out, diff_len, &patch_out, &patch_len);
    try testing.expectEqual(@as(i32, 0), rc2);
    defer zdiff_free(patch_out, patch_len);

    try testing.expectEqualStrings(b, patch_out[0..patch_len]);
}
```

**Step 2: Run tests to verify they fail**

**Step 3: Implement C FFI exports**

```zig
export fn zdiff_diff(
    a_ptr: [*]const u8, a_len: usize,
    b_ptr: [*]const u8, b_len: usize,
    seed: ?*const [32]u8,
    target_chunk_size: usize,
    out_ptr: *[*]u8, out_len: *usize,
) callconv(.c) i32 { ... }

export fn zdiff_patch(
    a_ptr: [*]const u8, a_len: usize,
    diff_ptr: [*]const u8, diff_len: usize,
    out_ptr: *[*]u8, out_len: *usize,
) callconv(.c) i32 { ... }

export fn zdiff_free(ptr: [*]u8, len: usize) callconv(.c) void { ... }
```

**Step 4: Create zdiff.h**

```c
#ifndef ZDIFF_H
#define ZDIFF_H

#include <stddef.h>
#include <stdint.h>

/* Compute a binary diff between files A and B.
 * seed: 32-byte rolling hash seed (NULL for random).
 * Returns 0 on success, -1 on error. */
int zdiff_diff(
    const uint8_t *a, size_t a_len,
    const uint8_t *b, size_t b_len,
    const uint8_t seed[32],
    size_t target_chunk_size,
    uint8_t **out, size_t *out_len);

/* Apply a diff to file A to reconstruct file B.
 * Returns 0 on success, -1 on error. */
int zdiff_patch(
    const uint8_t *a, size_t a_len,
    const uint8_t *diff, size_t diff_len,
    uint8_t **out, size_t *out_len);

/* Free memory returned by zdiff_diff or zdiff_patch. */
void zdiff_free(uint8_t *ptr, size_t len);

#endif
```

**Step 5: Run tests to verify they pass**

**Step 6: Commit**

```bash
git add src/lib.zig src/zdiff.h build.zig
git commit -m "Add C FFI layer for zdiff_diff, zdiff_patch, zdiff_free"
```

---

## Task 10: C CLI

**Files:**
- Create: `src/zdiff.c`
- Modify: `build.zig` (add C executable linking static lib)

**Step 1: Implement C CLI**

The CLI:
- Reads two files (or stdin via `-`/`@stdin`)
- Calls `zdiff_diff` or `zdiff_patch` through the FFI
- Writes output to file or stdout
- Shows progress to stderr (stage indicators, progress bar, ETA)
- Supports `--help`, `--about`, `--no-progress`, `--no-ansi`, `--simple`, `--json`
- Debug build detection: prints yellow "DEBUG BUILD" to stderr

**Step 2: Create CLI test suite**

Create `tests/cli/test_cli.bash`:
- Test diff + patch round-trip via CLI
- Test stdin/stdout piping
- Test `--help` and `--about`
- Test paths with spaces
- Test error cases (missing file, bad diff)

**Step 3: Run CLI tests**

**Step 4: Commit**

```bash
git add src/zdiff.c tests/cli/test_cli.bash build.zig
git commit -m "Add C CLI that dogfoods the zdiff FFI"
```

---

## Task 11: Benchmark Suite

**Files:**
- Create: `bm` (update from placeholder)
- Create: `tests/benchmark/`

The benchmark suite:
1. Uses `hyperfine` for statistical benchmarking
2. Generates test data with `gen-fake-tree --seed` and `random --seed` for reproducibility
3. Tests varying file sizes (1KB, 100KB, 10MB) and similarity ratios (0%, 50%, 90%, 99%)
4. Compares against `bsdiff` and `xdelta3` (both speed and output size)
5. Logs results to `tests/benchmark/benchmark_log.csv` (source-controlled)
6. Detects regressions (>10% change from previous run = LOUD warning)
7. Asserts no "DEBUG BUILD" in zdiff output

**Step 1: Implement benchmark script**

**Step 2: Run benchmarks, capture baseline**

**Step 3: Commit**

```bash
git add bm tests/benchmark/
git commit -m "Add benchmark suite comparing zdiff vs bsdiff vs xdelta3"
```

---

## Task 12: Documentation and Final Polish

**Files:**
- Create/update: `CODE_MINIMAP.md`
- Update: `PLAN.md` (check off completed items)
- Update: `PROJECT_SPEC.md` (add output format details)

**Step 1: Write CODE_MINIMAP.md**

Map of every source file, its purpose, and key functions.

**Step 2: Update PLAN.md**

Check off all completed items, add any follow-up items discovered.

**Step 3: Final test run**

Run: `./test` (full suite)
Run: `./bm` (benchmarks)

**Step 4: Commit**

```bash
git add CODE_MINIMAP.md PLAN.md PROJECT_SPEC.md
git commit -m "Add documentation: CODE_MINIMAP, update PLAN and PROJECT_SPEC"
```
