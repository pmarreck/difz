# ZDiff Design Document

**Date:** 2026-02-25
**Status:** Approved

## Overview

ZDiff is a binary differ that produces compact diffs between two files using a two-stage algorithm: Content-Defined Chunking (CDC) to narrow the search space, followed by a fine-grained O(ND) byte-level diff on the remaining gaps. Output is encoded using the BLIP container format.

Goals: **speed** and **conciseness** (smallest possible diff output).

## Architecture

```
zdiff CLI (C) ──> C FFI boundary ──> Zig core (pure logic, no I/O)
```

The Zig core takes two byte slices and returns a BLIP-encoded diff as a byte slice. All I/O is done by the C CLI. The FFI is dogfooded — the C CLI calls the Zig library through the C header, never importing Zig directly.

### Modules

| Module | Responsibility |
|--------|---------------|
| `gear_hash.zig` | Gear hash rolling hash with configurable seed |
| `cdc.zig` | Content-Defined Chunking using Gear hash |
| `elder_diff.zig` | O(ND) byte-level diff (Elder/Myers algorithm) |
| `diff.zig` | Two-stage orchestrator: CDC -> Elder -> instruction list |
| `patch.zig` | Apply diff instructions to reconstruct file B from A |
| `encoding.zig` | Serialize/deserialize diff instructions to BLIP containers |
| `lib.zig` | Public API + C FFI exports |

Plus `zdiff.c` — the C CLI that dogfoods the FFI.

## Data Flow

```
File A (bytes) --+
                 +---> CDC stage ---> matching chunks [(off_a, off_b, len), ...]
File B (bytes) --+        |
                          v
                    invert matches
                          |
                          v
                    gap regions [(a_start, a_len, b_start, b_len), ...]
                          |
                          v
                    Elder diff on each gap
                          |
                          v
                    instruction list [Copy(off, len), Insert(data), ...]
                          |
                          v
                    BLIP encoding ---> diff output (bytes)
```

### CDC Stage

1. Chunk both files with Gear hash (same seed, same configurable target chunk size)
2. BLAKE3-hash each chunk (std.crypto.hash.Blake3)
3. Build a hash map of B's chunk hashes -> (offset, length)
4. Walk A's chunks, probe B's map for matches
5. Collect matching chunk triples (off_a, off_b, len)
6. Sort by offset_a, merge adjacent/overlapping matches
7. Invert to get gap regions

### Elder Diff Stage

For each gap pair (A's gap slice, B's gap slice), run O(ND) diff algorithm. Output: sequence of Copy and Insert instructions with absolute offsets into A.

### Patch Operation

Read file A + diff blob. Walk instructions: Copy -> memcpy from A; Insert -> memcpy from diff data. Emit reconstructed file B.

## Key Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Rolling hash | Gear hash | Fast, simple, well-understood. 256-entry u64 table seeded deterministically. |
| Chunk fingerprinting | BLAKE3 (Zig stdlib) | Zero dependencies. Can optimize later if bottleneck. |
| Fine-grained diff | Elder/Myers O(ND) in pure Zig | Self-contained, no C dependency beyond our own FFI. |
| Output format | BLIP containers (day one) | Random access, integrity via xxHash64, streaming support. No throwaway format. |
| BLIP dependency | Zig package via git URL (pmarreck/BLIP) | Clean separation, standard Zig dependency management. |
| CDC chunk size default | None yet — configurable, required parameter | Defer default until benchmarks determine optimal heuristic. |
| Diff instruction set | Copy(offset, length) + Insert(data) | Minimal, sufficient. Delete is implicit (anything in A not covered by Copy). |
| CDC seed | Stored in diff metadata | 32-byte seed; Gear hash table derived from it deterministically. |

## Diff Output Format (BLIP)

```
ARRAY (top-level)
+-- [0] RAW: magic "ZDIF" + version byte (0x01)
+-- [1] DICT: metadata
|   +-- "cs" -> BLIP integer (CDC chunk size used)
|   +-- "ha" -> UTF8 "blake3" (hash algorithm)
|   +-- "sa" -> BLIP integer (size of file A)
|   +-- "sb" -> BLIP integer (size of file B)
|   +-- "sd" -> RAW (32 bytes, Gear hash seed)
+-- [2] ARRAY: instructions
    +-- [0] RAW: [opcode byte + BLIP offset + BLIP length]
    +-- [1] RAW: [opcode byte + BLIP offset + BLIP length + insert data]
    +-- ...

Opcodes:
  0x00 = Copy(offset_in_A, length)
  0x01 = Insert(length, data)
```

## Edge Cases

| Scenario | Diff output |
|----------|------------|
| Files identical | Copy(0, sizeof(A)) |
| Files completely different | Insert(0, all_of_B) |
| B is empty | Copy(0, 0) or Insert(0, "") |
| A is empty | Insert(0, all_of_B) |

## CLI Interface

```
zdiff <file_a> <file_b> [-o output | -]       # produce diff
zdiff --patch <file_a> <diff> [-o output | -]  # apply diff
zdiff -h / --help
zdiff --about
```

### Progress (stderr, interactive terminal only)

```
zdiff: [1/3] Chunking files...          [=====>        ] 45% 2.1s ETA 2.6s
zdiff: [2/3] Comparing chunks...        [========>     ] 67% 3.4s ETA 1.7s
zdiff: [3/3] Fine-grained diffing...    [===========>  ] 89% 4.1s ETA 0.5s
zdiff: Done. Diff: 12.4 KB (0.8% of original)
```

Suppressible via `--no-progress`. Stats line always emitted to stderr.

### CLI Conventions (per AGENTS.md)

- `-` / `@stdin` / `@stdout` / `@stderr` for stream paths
- `--lang` with locale detection, `ZDIFF_LANG` env var override
- `--no-ansi`, `--no-color`, `--simple` (removes ANSI + emoji)
- `--json` for structured output
- Paths with spaces (quoted or escaped)
- 30-language translation groundwork (English default, defer actual translations)
- Later args override earlier conflicting args
- Non-positional named args parseable in any order

## Testing Strategy

| Layer | What | How |
|-------|------|-----|
| `gear_hash` | Rolling hash correctness, seed determinism | Known-answer tests with fixed seeds |
| `cdc` | Chunk boundary detection, size distribution | Deterministic inputs via `random --seed`, verify boundary positions |
| `elder_diff` | O(ND) correctness | Small known diffs, empty/identical/fully-different inputs |
| `diff` (orchestrator) | End-to-end round-trip | `patch(A, diff(A, B)) == B` |
| `encoding` | BLIP serialization round-trip | Encode -> decode -> compare instructions |
| `patch` | Apply correctness, edge cases | Round-trip + malformed diff rejection |
| CLI | Bash test suite (`tests/cli/`) | Invokes C CLI binary through various scenarios |
| Integration | Real-world-ish files | `gen-fake-tree` + `random` for similar file pairs |

## Benchmark Suite (`./bm`)

- Uses `hyperfine` for statistical benchmarking
- Logs CPU + wall time over time (source-controlled log)
- Detects sudden % changes from most recent run (LOUDLY)
- Asserts no "DEBUG BUILD" in output
- **Competitive comparison**: benchmarks zdiff against other available binary diff tools:
  - `bsdiff` / `bspatch` (suffix sort based)
  - `xdelta3` (VCDIFF/RFC 3284)
  - `hdiffpatch` (if available)
  - Measures both **speed** (time to diff + patch) and **conciseness** (diff size / change size ratio)
  - Test corpus: varying file sizes, similarity ratios, file types (binary, source code, random)

## Build Scripts

- `./build` — ReleaseFast by default, `--test` for test build, `--debug` for debug
- `./test` — all unit + integration + CLI tests, accumulates errors, returns error count
- `./bm` — benchmark suite (ReleaseFast only)
- `./fuzz` — fuzzing suite (when implemented)

## Dependencies

- **Zig 0.15.x** (via Nix flake)
- **BLIP** (Zig package via `pmarreck/BLIP` git URL)
- **hyperfine** (benchmarking, in flake devShell)
- **std.crypto.hash.Blake3** (Zig stdlib, no external dep)
