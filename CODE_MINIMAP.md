# Difz Code Minimap

## Architecture

```
difz CLI (C) ──> C FFI boundary ──> Zig core (pure logic, no I/O)
```

All business logic lives in Zig. The C CLI dogfoods the FFI. The Zig core performs no I/O.

## Source Files

### `src/lib.zig` — Public API + C FFI exports
- `version` — version string ("0.1.0")
- `difz_diff()` — C FFI: compute binary diff between two buffers, returns BLIP-encoded blob
- `difz_patch()` — C FFI: apply diff to source buffer, returns reconstructed target
- `difz_free()` — C FFI: free memory returned by difz_diff or difz_patch
- Test block imports all modules to ensure test discovery

### `src/difz.h` — C header for FFI consumers
- Declares `difz_diff`, `difz_patch`, `difz_free` with C types

### `src/difz.c` — C CLI that dogfoods the FFI
- Diff mode: `difz <file_a> <file_b> [-o output]`
- Patch mode: `difz --patch <file_a> <diff> [-o output]`
- Options: `-h`/`--help`, `--about`, `-o`, `--seed`, `--chunk-size`, `--no-progress`, `--no-ansi`/`--no-color`, `--simple`
- Stream routing: `-`/`@stdin` for stdin, `-`/`@stdout` for stdout, `@stderr` for stderr
- Progress stats to stderr (interactive terminal only)
- Debug build detection (yellow "DEBUG BUILD" via ZDIFF_DEBUG define)

### `src/gear_hash.zig` — Rolling hash with configurable seed
- `Table` — type alias for `[256]u64` lookup table
- `generateTable(seed)` — derive 256-entry u64 table from 32-byte seed via BLAKE3 keyed mode
- `hash(table, data)` — convenience: hash an entire byte slice
- `roll(table, state, byte)` — single-step: `(state << 1) +% table[byte]`
- 6 tests: determinism, seed variance, empty input, rolling consistency

### `src/cdc.zig` — Content-Defined Chunking using Gear hash
- `Chunk` — struct: `{ offset, length }`
- `chunkSlice(allocator, data, seed, target_size)` — split data into variable-size chunks
  - Mask = nextPowerOf2(target) - 1, min = target/4, max = target*4
  - Cut when `(state & mask == 0) and (len >= min)` or `len >= max`
- `nextPowerOf2(n)` — helper for mask computation
- 6 tests: empty, single byte, coverage, determinism, seed variance, average size

### `src/chunk_match.zig` — Find identical chunks between two files
- `Match` — struct: `{ offset_a, offset_b, length }`
- `GapRegion` — struct: `{ offset, length }`
- `GapResult` — struct: `{ gaps_a, gaps_b }`
- `findMatches(allocator, a, b, seed, target_chunk_size)` — CDC both files, BLAKE3-hash chunks, HashMap lookup, sort + merge adjacent matches
- `invertMatches(allocator, matches, len_a, len_b)` — convert matches to gap regions
- `blake3Hash128(data)` — 128-bit BLAKE3 digest for chunk fingerprinting
- 5 tests: identical, different, gap inversion, no matches, shared prefix

### `src/elder_diff.zig` — O(ND) byte-level diff (Myers algorithm) with edit distance cap
- `DiffOp` — struct: `{ tag: .copy|.insert, offset, length, data }`
- `diff(allocator, a, b)` — Myers O(ND) with V-array history and traceback; edit distance capped at `min(sqrt(N+M)*2+16, 8192)` — bails to raw Insert when exceeded (~170x speedup on dissimilar data)
- `freeOps(allocator, ops)` — free DiffOp slice
- `applyOps(allocator, a, ops)` — apply ops to A, produce B
- `editsToDiffOps(allocator, edits, a, b)` — convert edit list to Copy/Insert ops
- 11 tests: identical, empty, insertion, deletion, replacement, random round-trip, edge changes, large dissimilar (cap timing), fine-grained (cap doesn't over-trigger)

### `src/diff.zig` — Two-stage orchestrator: CDC -> Elder -> instruction list
- `DiffOptions` — struct: `{ seed: [32]u8, target_chunk_size: usize }`
- `DiffResult` — struct: `{ ops, options, size_a, size_b }`
- `computeDiff(allocator, a, b, options)` — Stage 1: CDC chunk matching, Stage 2: Elder diff on gaps; matches walked in B-order to support moved/rearranged blocks (monotonic gaps get Elder diff, non-monotonic gaps get raw Insert)
- `freeDiffResult(allocator, result)` — free the ops array
- `applyDiff(allocator, a, ops)` — convenience wrapper around elder_diff.applyOps
- 8 tests: identical, different round-trip, shared regions, empty A/B, metadata, multiple scattered edits, moved/rearranged sections

### `src/encoding.zig` — BLIP serialization of diff instructions
- `DecodeResult` — struct: `{ ops, seed, target_chunk_size, size_a, size_b }`
- `encode(allocator, DiffResult)` — serialize to ZDIF v1 wire format (BLIP ARRAY container)
- `decode(allocator, data)` — deserialize BLIP bytes back to ops + metadata
- `freeDecoded(allocator, result)` — free decoded ops (including insert data allocations)
- `serializeRaw(allocator, payload)` — build a RAW container manually
- `parseRaw(buf)` — extract RAW container payload (zero-copy)
- Wire format: `ARRAY[RAW "ZDIF\x01", RAW metadata(seed+BLIPs), ARRAY[RAW per instruction]]`
- Opcodes: 0x00 = Copy(offset, length), 0x01 = Insert(length, data)
- 7 tests: round-trip, BLIP sentinel, invalid magic, empty ops, large insert, interleaved, metadata

### `src/patch.zig` — Apply diff to reconstruct target file
- `PatchInfo` — struct: `{ size_a, size_b, seed, target_chunk_size, num_ops }`
- `PatchError` — error set for patch failures
- `patch(allocator, a, diff_blob)` — decode + verify sizes + apply ops + verify output size
- `patchInfo(allocator, diff_blob)` — extract metadata without applying
- 6 tests: round-trip, malformed diff, wrong size, empty, patchInfo, large random

## Build & Config Files

- `build.zig` — Zig 0.15 build: difz module, static library (libdifz.a), C executable, tests
- `build.zig.zon` — package manifest with BLIP dependency via GitHub tarball
- `flake.nix` — Nix flake: devShell (zig, hyperfine, bsdiff, xdelta) + packages.default

## Scripts

- `build` — `nix develop -c zig build` (ReleaseFast default, `--test`/`--debug` flags)
- `test` — runs Zig unit tests + CLI integration tests, accumulates errors
- `bm` — benchmark suite: hyperfine stats, difz vs bsdiff vs xdelta3, regression detection

## Test Suites

- **50 Zig unit tests** across all modules (run via `zig build test`)
- **46 CLI integration tests** in `tests/cli/test_cli.bash` (run via `bash tests/cli/test_cli.bash`)
- **Benchmark suite** in `bm` (run via `bash bm`)

## Dependencies

- **Zig 0.15.x** (via Nix flake)
- **BLIP** (Zig package via `pmarreck/BLIP` git URL) — variable-length integer encoding + container format
- **std.crypto.hash.Blake3** (Zig stdlib) — chunk fingerprinting
- **hyperfine** (benchmarking, in flake devShell)
- **bsdiff/bspatch** (benchmark comparison, in flake devShell)
- **xdelta3** (benchmark comparison, in flake devShell)
