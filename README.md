# difz

[![CI](https://github.com/pmarreck/difz/actions/workflows/ci.yml/badge.svg?branch=yolo)](https://github.com/pmarreck/difz/actions/workflows/ci.yml)
[![Mechatron Prime CI](https://img.shields.io/endpoint?url=https%3A%2F%2Fthelio-nixos.tail66c90.ts.net%2Fbadges%2Fdifz.json&style=for-the-badge)](https://thelio-nixos.tail66c90.ts.net/mechatron-prime/)
[![License: BSD 3-Clause](https://img.shields.io/badge/License-BSD_3--Clause-blue.svg)](LICENSE)

A fast binary differ for files and directory trees. File patches encode Copy and Insert instructions and bind them to BLAKE3 identities for both files. Apply rejects a wrong source before reconstruction and verifies the completed target. Directory patches add a canonical manifest, ordered path filters, and a whole-patch identity. Directory apply writes a new sibling stage and commits it only after an independent filesystem re-snapshot matches the target identity.

## Performance

Benchmarked on Apple M4 (aarch64), deterministic random binary data (using default `--compress best`):

| File size | Sim. | difz | xdelta3 | zstd | bsdiff | difz size | xdelta3 size | zstd size | bsdiff size |
|-----------|------|-------|---------|------|--------|-----------|-------------|----------|------------|
| **10 MB** | 90%  | 134 ms | 127 ms | **27 ms** | 2,326 ms | **1,024 KB** | 1,024 KB | 1,035 KB | 1,030 KB |
| **20 MB** | 90%  | **221 ms** | 238 ms | 45 ms | 6,014 ms | **2,048 KB** | 2,048 KB | 2,069 KB | 2,057 KB |
| **50 MB** | 90%  | **417 ms** | 560 ms | 67 ms | 21,114 ms | **5,120 KB** | 5,121 KB | 5,172 KB | 5,144 KB |
| **20 MB** | 50%  | **496 ms** | 1,131 ms | 43 ms | 20,677 ms | **10,240 KB** | 10,241 KB | 10,252 KB | 10,285 KB |
| **20 MB** | 99%  | 127 ms | 51 ms | **37 ms** | 2,759 ms | **205 KB** | 205 KB | 228 KB | 206 KB |

**difz produces the smallest diffs** across all test cases. zstd `--patch-from` is the fastest differ (dictionary compression, not true delta encoding) but produces 1-11% larger patches. difz is 1.1x-2.3x faster than xdelta3 on larger/less-similar inputs (xdelta3 leads on small or highly-similar files) and 17x-51x faster than bsdiff. Patch application is up to 16x faster than bspatch and comparable to xdelta3 and zstd.

Hyperfine statistical benchmark (10 MB, 90% similar, 10+ runs):

```
zstd      16.6 ms ± 1.0 ms
xdelta3  118.7 ms ± 4.9 ms    7.15x slower than zstd
difz    131.7 ms ± 4.3 ms    7.93x slower than zstd
bsdiff     2.30 s ± 0.13 s  138.42x slower than zstd
```

## How it works

Two-stage algorithm:

1. **Content-Defined Chunking (CDC)** — Gear hash splits both files into variable-size chunks. BLAKE3 fingerprints identify identical regions between files. This finds large matching blocks in O(n) time regardless of where they moved.

2. **Elder/Myers O(ND) byte diff** — For gaps between matched chunks, a fine-grained byte-level diff produces compact Copy+Insert instructions. An edit distance cap prevents quadratic blowup on dissimilar regions.

Output is encoded as source- and target-bound ZDIF v2 in [BLIP](https://github.com/pmarreck/BLIP) format with selectable compression (LZMA2, bzip2, LZ4, or none). By default (`--compress best`), LZMA2 and bzip2 are both tried and the smallest result is kept. LZ4 is available for speed-over-size use cases but is not included in `best` mode since it never wins on ratio. ZDIF v1 patches are rejected because that format has no cryptographic file identities.

## Usage

```bash
# Produce a diff
difz old_file new_file -o patch.difz

# Apply a diff
difz --patch old_file patch.difz -o new_file

# Diff and reconstruct directory trees
difz old_directory new_directory -o update.difz
difz --patch old_directory update.difz -o reconstructed_directory

# Scope a directory snapshot; rules are ordered and later matches win
difz --allow 'Contents/**' --deny '**/*.tmp' old.app new.app -o update.difz

# Pipe to stdout
difz old_file new_file > patch.difz
difz --patch old_file patch.difz > new_file

# Inspect a diff file (human-readable op dump)
difz --inspect patch.difz
difz --inspect --truncate 128 --hexlike patch.difz
```

### Options

```
-o <file>            Output file (default: stdout)
--patch              Apply diff mode
--inspect            Pretty-print the ops in a diff file
--compress <algo>    Compression: best, lzma2, bzip2, lz4, none (default: best)
--truncate <n>       Max bytes of INSERT data to display (default: 64)
--hexlike            Use hexlike encoding for binary data display
--seed <hex>         32-byte seed as 64-char hex string
--chunk-size <n>     Target CDC chunk size (default: 4096)
--allow <glob>       Include matching directory paths (repeatable, ordered)
--deny <glob>        Exclude matching directory paths (repeatable, ordered)
--no-progress        Suppress progress output
--about              Show version, platform, architecture
```

## Architecture

```text
difz CLI (C) -> C FFI -> pure file and canonical-tree cores
                         -> no-follow snapshot/staging adapter
```

The file algorithm and canonical directory patch logic remain pure in-memory Zig. A narrow Zig filesystem adapter snapshots directory handles without following links and reconstructs through a new sibling stage. The C CLI calls both paths through the public FFI, so external consumers exercise the same boundary.

### Source layout

```
src/
├── lib.zig          # Buffer and filesystem C FFI exports
├── difz.h          # C header for FFI consumers
├── difz.c          # CLI: file I/O, arg parsing, progress display (uses progrez)
├── diff.zig         # Two-stage orchestrator: CDC matching + Elder gap refinement
├── cdc.zig          # Content-Defined Chunking via Gear hash
├── gear_hash.zig    # Gear rolling hash with BLAKE3-seeded lookup table
├── chunk_match.zig  # BLAKE3 fingerprint matching between chunk sets
├── elder_diff.zig   # Myers O(ND) byte-level diff with edit distance cap
├── encoding.zig     # BLIP serialization + selectable compression (lzma2/bzip2/lz4/best/none)
├── inspect.zig      # Diff file pretty-printer (decode + human-readable op dump)
├── patch.zig        # File diff application (decode + reconstruct)
├── directory.zig    # Canonical paths, entries, validation, and tree identity
├── directory_patch.zig # DIFZTREE encoder, bounded parser, and pure applicator
├── directory_fs.zig # No-follow snapshots and verified staged reconstruction
├── path_filter.zig  # Ordered include/exclude classifier
├── glob.zig         # dirtree-compatible glob-to-PCRE2 conversion
└── pcre2.zig        # Small PCRE2 wrapper
```

### Data flow

**Diff:** `(A, B) → CDC chunk both → BLAKE3 match → sort by B-offset → Elder diff gaps → encode ops → compress (best of lzma2/bzip2) → output`

**Patch:** `(A, diff) → decompress → decode → verify BLAKE3(A) → apply Copy/Insert → verify BLAKE3(B) → output B`

### Design decisions

- **C FFI is the real API.** Even the CLI written in C calls through FFI rather than importing Zig directly. This guarantees the FFI boundary is always exercised and tested.
- **CDC handles moved blocks.** Matches are sorted by B-offset, not A-offset, so rearranged sections are correctly detected. Non-monotonic gaps (moved blocks) emit raw Inserts; monotonic gaps get fine-grained Elder diffing.
- **Edit distance cap.** Myers O(ND) is capped at `sqrt(N+M)*2+16` (max 8192) to prevent quadratic blowup on dissimilar gap regions. When exceeded, the gap falls back to a raw Insert.
- **Try-best compression.** By default, LZMA2 and bzip2 are both tried (using a distributed sampling heuristic for large diffs) and the smallest result is kept. LZ4 is available via `--compress lz4` for speed-over-size scenarios but is excluded from `best` since it never wins on ratio. Random/incompressible data passes through uncompressed.
- **Deterministic seeds.** The CDC Gear hash table is seeded via BLAKE3, so the same seed produces the same chunking. Seeds can be specified explicitly for reproducible diffs.
- **Linear patch decoding.** ZDIF instruction offsets are consumed by a stateful cursor in O(op_count), and decoded INSERT bytes share one contiguous allocation. This avoids quadratic index rescans and per-INSERT page-allocation overhead on patches with hundreds of thousands of small operations.

## Building

Requires [Nix](https://nixos.org/) with flakes enabled:

```bash
./build  # reproducible optimized Nix build
./test   # canonical Nix unit and CLI checks
```

## Running benchmarks

```bash
nix develop -c bash bm
```

Compares difz against bsdiff and xdelta3 across multiple file sizes and similarity levels. Results are logged to `tests/benchmark/benchmark_log.csv` with automatic regression detection.

## Dependencies

- **Zig 0.16.0** (via Nix flake)
- **[BLIP](https://github.com/pmarreck/BLIP)** — variable-length integer encoding + container format (Zig package)
- **PCRE2** — dirtree-compatible ordered path filters

## License

BSD 3-Clause. See [LICENSE](LICENSE).
