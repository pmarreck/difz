# zdiff

[![CI](https://github.com/pmarreck/zdiff/actions/workflows/ci.yml/badge.svg?branch=yolo)](https://github.com/pmarreck/zdiff/actions/workflows/ci.yml)
[![Garnix](https://img.shields.io/endpoint.svg?url=https://garnix.io/api/badges/pmarreck/zdiff&style=flat)](https://garnix.io/repo/pmarreck/zdiff)

A fast binary differ. Given two files A and B, zdiff produces a compact diff — an encoded list of Copy and Insert instructions to transform A into B. Applying the diff to A reconstructs B exactly.

## Performance

Benchmarked on Apple M4 (aarch64), deterministic random binary data:

| File size | Sim. | zdiff time | xdelta3 time | bsdiff time | zdiff size | xdelta3 size | bsdiff size |
|-----------|------|-----------|-------------|------------|-----------|-------------|------------|
| **10 MB** | 90%  | **72 ms** | 120 ms | 2,391 ms | 1,025 KB | 1,024 KB | 1,030 KB |
| **20 MB** | 90%  | **135 ms** | 229 ms | 6,106 ms | 2,051 KB | 2,048 KB | 2,057 KB |
| **50 MB** | 90%  | **317 ms** | 555 ms | 21,045 ms | 5,121 KB | 5,121 KB | 5,144 KB |
| **20 MB** | 50%  | **260 ms** | 1,131 ms | 20,623 ms | 10,244 KB | 10,241 KB | 10,285 KB |
| **20 MB** | 99%  | **97 ms** | 47 ms | 2,724 ms | 207 KB | 205 KB | 206 KB |

**1.7x-4.3x faster than xdelta3. 33x-79x faster than bsdiff.** All three tools produce nearly identical diff sizes (within 0.5%). Patch application is 12x faster than bspatch and comparable to xdelta3.

Hyperfine statistical benchmark (10 MB, 90% similar, 10+ runs):

```
zdiff     67.4 ms ± 4.3 ms
xdelta3  111.6 ms ± 1.8 ms    1.66x slower
bsdiff     2.37 s ± 0.03 s   35.18x slower
```

## How it works

Two-stage algorithm:

1. **Content-Defined Chunking (CDC)** — Gear hash splits both files into variable-size chunks. BLAKE3 fingerprints identify identical regions between files. This finds large matching blocks in O(n) time regardless of where they moved.

2. **Elder/Myers O(ND) byte diff** — For gaps between matched chunks, a fine-grained byte-level diff produces compact Copy+Insert instructions. An edit distance cap prevents quadratic blowup on dissimilar regions.

Output is encoded in [BLIP](https://github.com/pmarreck/BLIP) format with optional LZMA2 compression (used automatically when it reduces size).

## Usage

```bash
# Produce a diff
zdiff old_file new_file -o patch.zdiff

# Apply a diff
zdiff --patch old_file patch.zdiff -o new_file

# Pipe to stdout
zdiff old_file new_file > patch.zdiff
zdiff --patch old_file patch.zdiff > new_file
```

### Options

```
-o <file>          Output file (default: stdout)
--patch            Apply diff mode
--seed <hex>       32-byte seed as 64-char hex string
--chunk-size <n>   Target CDC chunk size (default: 4096)
--no-progress      Suppress progress output
--about            Show version, platform, architecture
```

## Architecture

```
zdiff CLI (C) ──> C FFI boundary ──> Zig core (pure logic, no I/O)
```

The Zig core is a pure library — it takes two byte slices and returns a BLIP-encoded diff as a byte slice. No file I/O, no allocation policy decisions, no CLI concerns. All I/O lives in the C CLI, which calls the Zig library through its C FFI header. This dogfoods the same interface any external consumer would use.

### Source layout

```
src/
├── lib.zig          # C FFI exports: zdiff_diff(), zdiff_patch(), zdiff_free()
├── zdiff.h          # C header for FFI consumers
├── zdiff.c          # CLI: file I/O, arg parsing, progress display
├── diff.zig         # Two-stage orchestrator: CDC matching + Elder gap refinement
├── cdc.zig          # Content-Defined Chunking via Gear hash
├── gear_hash.zig    # Gear rolling hash with BLAKE3-seeded lookup table
├── chunk_match.zig  # BLAKE3 fingerprint matching between chunk sets
├── elder_diff.zig   # Myers O(ND) byte-level diff with edit distance cap
├── encoding.zig     # BLIP serialization + optional LZMA2 compression
└── patch.zig        # Diff application (decode + reconstruct)
```

### Data flow

**Diff:** `(A, B) → CDC chunk both → BLAKE3 match → sort by B-offset → Elder diff gaps → encode ops → LZMA2 compress (if smaller) → output`

**Patch:** `(A, diff) → LZMA2 decompress (if needed) → decode ops → apply Copy/Insert against A → output B`

### Design decisions

- **C FFI is the real API.** Even the CLI written in C calls through FFI rather than importing Zig directly. This guarantees the FFI boundary is always exercised and tested.
- **CDC handles moved blocks.** Matches are sorted by B-offset, not A-offset, so rearranged sections are correctly detected. Non-monotonic gaps (moved blocks) emit raw Inserts; monotonic gaps get fine-grained Elder diffing.
- **Edit distance cap.** Myers O(ND) is capped at `sqrt(N+M)*2+16` (max 8192) to prevent quadratic blowup on dissimilar gap regions. When exceeded, the gap falls back to a raw Insert.
- **Try-compress.** LZMA2 compression is attempted on the encoded output; the compressed version is kept only if it's actually smaller. Random/incompressible data passes through uncompressed.
- **Deterministic seeds.** The CDC Gear hash table is seeded via BLAKE3, so the same seed produces the same chunking. Seeds can be specified explicitly for reproducible diffs.

## Building

Requires [Nix](https://nixos.org/) with flakes enabled:

```bash
nix develop    # enter dev shell with Zig 0.15 + benchmark tools
zig build      # build zdiff
zig build test # run all tests
```

## Running benchmarks

```bash
nix develop -c bash bm
```

Compares zdiff against bsdiff and xdelta3 across multiple file sizes and similarity levels. Results are logged to `tests/benchmark/benchmark_log.csv` with automatic regression detection.

## Dependencies

- **Zig 0.15.x** (via Nix flake)
- **[BLIP](https://github.com/pmarreck/BLIP)** — variable-length integer encoding + container format (Zig package)

## License

BSD 3-Clause. See [LICENSE](LICENSE).
