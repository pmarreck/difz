# difz

[![CI](https://github.com/pmarreck/difz/actions/workflows/ci.yml/badge.svg?branch=yolo)](https://github.com/pmarreck/difz/actions/workflows/ci.yml)
[![Mechatron Prime CI](https://img.shields.io/endpoint?url=https%3A%2F%2Fthelio-nixos.tail66c90.ts.net%2Fbadges%2Fdifz.json&style=for-the-badge)](https://thelio-nixos.tail66c90.ts.net/mechatron-prime/)
[![License: BSD 3-Clause](https://img.shields.io/badge/License-BSD_3--Clause-blue.svg)](LICENSE)

A fast binary differ for files and directory trees. File patches encode Copy and Insert instructions and bind them to BLAKE3 identities for both files. Apply rejects a wrong source before reconstruction and verifies the completed target. Directory patches add a canonical manifest, ordered path filters, and a whole-patch identity. Directory apply writes a new sibling stage and commits it only after an independent filesystem re-snapshot matches the target identity.

## Performance

### Current Linux x86_64 real-binary result

This 2026-08-28 run used an AMD Ryzen Threadripper 3990X and difz commit `fc72e215fce361e66a4fd5854a6e1c3495f4a7e2`. The inputs are runnable ReleaseFast Nix outputs from consecutive Validate commits [`e3e73738`](https://github.com/pmarreck/validate/commit/e3e73738a11b6401b19f18a023dfa313f77d0482) and [`c9ab2cdb`](https://github.com/pmarreck/validate/commit/c9ab2cdb8823e69312aa90085aecf60d48fb6aa4), sized 89,229,114 and 89,229,178 bytes. Each tool's reconstructed target matched the original byte-for-byte.

| Metric | difz | bsdiff | xdelta3 | zstd |
|--------|-----:|-------:|--------:|-----:|
| Create wall time | 11.027 s | 29.213 s | 2.594 s | 0.355 s |
| Create CPU time | 15.520 s | 28.960 s | 2.550 s | 0.590 s |
| Apply wall time | 0.715 s | 0.487 s | 0.321 s | 0.176 s |
| Apply CPU time | 0.690 s | 0.460 s | 0.290 s | 0.210 s |
| Patch size | 4,513,223 B | 398,412 B | 3,985,436 B | 6,031,834 B |

The real pair produced 708,379 difz operations. Difz create peaked at 3,497,792 KiB RSS and apply peaked at 213,752 KiB. On this pair, difz created the patch faster than bsdiff but slower than xdelta3 and zstd; it applied slower than all three. Its patch was 4,513,223 bytes, smaller than zstd's 6,031,834 and larger than xdelta3's 3,985,436. bsdiff's patch was 11.3 times smaller than difz's. These are single-run resource measurements; the full inputs, hashes, timings, and sizes are in `tests/benchmark/benchmark_log_v3.csv`. This Validate pair was not measured again on 2026-10-07. The published binaries are not current Nix outputs, and rebuilding those two commits still fetches sources that are private or redirected.

### Public Linux x86_64 AppImage pair (updater pilot)

2026-09-29, same Threadripper host, ReleaseFast `difz`. Consecutive Neovim AppImages [v0.11.3](https://github.com/neovim/neovim/releases/tag/v0.11.3) → [v0.11.4](https://github.com/neovim/neovim/releases/tag/v0.11.4) (10,996,216 B and 11,012,600 B). Create used `--max-output-ratio 70 --max-rss-bytes 8589934592 --max-wall-ms 120000`. The reconstructed target matched byte-for-byte.

| Metric | difz | bsdiff | xdelta3 | zstd |
|--------|-----:|-------:|--------:|-----:|
| Create wall time | 1.019 s | 9.984 s | 1.294 s | 0.120 s |
| Patch size | 5,349,393 B (48.58%) | 5,338,146 B | 5,319,624 B | 5,359,536 B |

Difz create peaked at 413,760 KiB RSS; apply was 0.080 s / 30,772 KiB RSS. On this consecutive AppImage pair, difz, bsdiff, and xdelta3 patches are within 0.6% of each other; difz created ~10× faster than bsdiff. A second public pair, KeePassXC 2.7.9 → 2.7.10 (40.7 MB → 48.2 MB), produced a 47,174,594 B patch (97.86% of target) and was rejected by `--max-output-ratio 70` as designed.

Rerun on 2026-10-03, same host and the same two hashes, ReleaseFast `difz` from this checkout. Create: difz 0.986 s and 426,220 KiB RSS, bsdiff 10.262 s, xdelta3 1.293 s, zstd 0.079 s. Patch bytes: difz 5,341,392 (48.50%), bsdiff 5,338,146, xdelta3 5,319,586, zstd 5,359,536. Apply: difz 0.059 s, bspatch 0.322 s, xdelta3 0.035 s, zstd 0.033 s. All four reconstructions matched the target. bsdiff and zstd patch sizes matched the September row exactly. Current difz emitted 2,119 operations and a patch 8,001 bytes smaller than the September difz patch. The pinned Validate ELF pair was not rerun. Those revisions predate the private-source seed. Their zigDeps step runs `zig build --fetch=all` with no credentials, and the anonymous `libjxlz` archive URL returns 404 because the repository is private. The commit is still there. Current Validate takes that source as a locked non-flake input, `git+ssh://git@github.com/pmarreck/libjxlz`, runs `zig fetch` on the store path, and only then runs `--fetch=all`. The Monkey's Audio SDK URL pinned by those same revisions now redirects to `notfound.html`.

Rerun on 2026-10-07, same host and the same two hashes, ReleaseFast `difz` at `78a2358`. Create used the same three ceilings. difz created in 0.961 s at 398,180 KiB RSS and emitted 2,001 operations. Patch bytes: difz 5,341,213 (48.50% of the target), bsdiff 5,338,146, xdelta3 5,319,624, zstd 5,359,536. Apply: difz 0.061 s, bspatch 0.318 s, xdelta3 0.042 s, zstd 0.024 s. All four reconstructions matched the target. bsdiff, xdelta3, and zstd patch sizes match the 2026-09-29 row. The 2026-10-03 note listed xdelta3 at 5,319,586 bytes, and this run did not reproduce that figure.

### Historical shared-prefix snapshot

This is a historical Apple M4 (aarch64) snapshot using default `--compress best`. Its historical shared-prefix corpus constructed each target as one contiguous prefix from the source followed by a random suffix. A current reproduction of the 10 MiB, 90%-similar case yields only three operations, so this table does not measure scattered edits, rebuilt binaries, or high-operation apply behavior.

| File size | Sim. | difz | xdelta3 | zstd | bsdiff | difz size | xdelta3 size | zstd size | bsdiff size |
|-----------|------|-------|---------|------|--------|-----------|-------------|----------|------------|
| **10 MB** | 90%  | 134 ms | 127 ms | **27 ms** | 2,326 ms | **1,024 KB** | 1,024 KB | 1,035 KB | 1,030 KB |
| **20 MB** | 90%  | **221 ms** | 238 ms | 45 ms | 6,014 ms | **2,048 KB** | 2,048 KB | 2,069 KB | 2,057 KB |
| **50 MB** | 90%  | **417 ms** | 560 ms | 67 ms | 21,114 ms | **5,120 KB** | 5,121 KB | 5,172 KB | 5,144 KB |
| **20 MB** | 50%  | **496 ms** | 1,131 ms | 43 ms | 20,677 ms | **10,240 KB** | 10,241 KB | 10,252 KB | 10,285 KB |
| **20 MB** | 99%  | 127 ms | 51 ms | **37 ms** | 2,759 ms | **205 KB** | 205 KB | 228 KB | 206 KB |

Within the five displayed shared-prefix cases, difz produced the smallest patches. zstd `--patch-from` was the fastest differ but produced patches 1-11% larger in this table. difz measured 1.1x-2.3x faster than xdelta3 on the larger or less-similar rows, while xdelta3 led on the small or highly similar rows; difz measured 17x-51x faster than bsdiff. These observations describe this corpus and machine only.

Historical hyperfine result for the same 10 MiB shared-prefix shape (10+ runs):

```
zstd      16.6 ms ± 1.0 ms
xdelta3  118.7 ms ± 4.9 ms    7.15x slower than zstd
difz    131.7 ms ± 4.3 ms    7.93x slower than zstd
bsdiff     2.30 s ± 0.13 s  138.42x slower than zstd
```

A 2026-10-07 reproduction on this Threadripper, ReleaseFast `difz` at `78a2358`, used the same seeds. Every shared-prefix row and the interleaved row kept the August operation count. Each difz patch is 9 bytes larger than the 2026-08-28 row. bsdiff, xdelta3, and zstd sizes match those rows byte for byte. Hyperfine create on the 10 MiB, 90% pair (10 runs): zstd 49.4 ms ± 5.9 ms, xdelta3 307.0 ms ± 4.8 ms, difz 327.1 ms ± 13.2 ms, bsdiff 3.423 s ± 0.046 s. The harness flagged the single 20 MiB, 90% create sample, 1,045 ms wall and 870 ms CPU against 538 ms and 540 ms in August. The other shared-prefix create samples stayed near the August times. That one sample was not repeated. The full rows are in `tests/benchmark/benchmark_log_v3.csv`.

On 2026-10-07 the same host compared `--compress none`, `lzma2`, `bzip2`, `zstd`, and `best`, ten runs each, with the CDC seed pinned to 32 bytes of `0x2a`. A default create draws a new seed, so these patch bytes are not the unseeded rows above. On the 1 MiB, 10 MiB, and 20 MiB shared-prefix pairs, all five modes wrote the same bytes as uncompressed. `best` still ran the probe. The 1 MiB patch is under the 384 KiB sample cutoff, so `best` compressed the whole patch three times and then once more: 109 ms versus 16 ms for `none` and 35 ms for `lzma2`, for no size change. The 1 MiB interleaved patch did compress. `best` matched `lzma2` byte for byte at 29,133 bytes, against 112,660 uncompressed, 47,046 for bzip2, and 49,064 for zstd. That `best` run took 144 ms, against 77 ms for `lzma2` alone and 40 ms with no compression. The Neovim pair also matched `lzma2` byte for byte: 5,344,292 bytes versus 5,356,052 uncompressed and 5,348,447 for zstd. bzip2 did not shrink it. Create was 515 ms with no compression, 573 ms for zstd, 819 ms for lzma2, and 1,051 ms for `best`. The 10 MiB and 20 MiB timing means are not quoted. Those repeats drifted while the size identity did not.

A 1024 MiB full replace of two uniform streams, one timed run after a warmup on the same host, is large enough for 128 of zstd level 3's 8 MiB jobs. `difz --compress zstd` wrote the same 1,073,742,012 bytes as `--compress none`. Create was 12.1 s wall and 11.9 s CPU with no compression, and 14.2 s wall and 14.5 s CPU with zstd, about one core either way. The zstd 1.5.7 CLI at level 3 took 880 ms wall and 2.47 s CPU with `-T1`, and 946 ms wall and 2.88 s CPU with `-T0` (about 3 cores). Both CLI frames were larger than the patch, 1,073,766,605 bytes. The 16, 64, and 256 MiB rungs of the same ladder also left every difz mode byte-identical to uncompressed, and `-T0` was slower than `-T1` at each rung. lzma2 and bzip2 were not repeated at 1024 MiB. At 256 MiB they had not shrunk the patch, and bzip2's resident set was about 14 GiB.

The same day, one timed run compared the current file engine with `zstd --patch-from` on the official NixOS minimal x86_64 ISOs `26.05.7813` (1,706,262,528 bytes, SHA-256 `d74cb1858a7d8350506bc8889cdc291de6241157c402c9b814a8d817eac8ace9`) and `26.05.9173` (1,709,604,864 bytes, SHA-256 `bc64e5ccb058c7143c3803ad5ded61564d82509b0c13bcf572d012e82ecf3e4e`). `difz` was ReleaseFast at its default `--compress best`, with the CDC seed pinned to 32 bytes of `0x2a`. zstd was 1.5.7. Every listed reconstruction matched the newer ISO.

| Tool | Create wall / CPU / peak RSS | Patch bytes | Apply wall |
|---|---|---:|---:|
| difz `--compress best` | 925.5 s / 1,199 s / 35.1 GiB | 662,865,660 | 9.34 s |
| `zstd --patch-from -3` | 5.19 s / 8.89 s / 3.32 GiB | 562,327,064 | see below |
| `zstd --patch-from -9` | 6.90 s / 11.9 s / 3.51 GiB | 557,813,501 | see below |
| `zstd --patch-from -19` | 110 s / 332 s / 4.79 GiB | 555,099,605 | see below |
| xdelta3 | 604 s / 599 s / 227 MiB | 1,675,137,751 | 2.84 s |
| bsdiff | 5,126 s / 5,084 s / 14.3 GiB | 649,963,439 | 40.3 s |

`zstd -d --patch-from` without a larger window exited 36. The frame window is the target size, 1,709,604,864 bytes, and the decoder's default maximum was the reference size, 1,706,262,528. `zstd -d --long=31 --patch-from` reconstructed the target for levels 3, 9, and 19. Level 19 saved 7,227,459 bytes against level 3 and used about 21 times the wall time.

## How it works

Two-stage algorithm:

1. **Content-Defined Chunking (CDC)** — Gear hash splits both files into variable-size chunks. BLAKE3 fingerprints identify identical regions between files. This finds large matching blocks in O(n) time regardless of where they moved.

2. **Elder/Myers O(ND) byte diff** — For gaps between matched chunks, a fine-grained byte-level diff produces compact Copy+Insert instructions. An edit distance cap prevents quadratic blowup on dissimilar regions.

Output is encoded as source- and target-bound ZDIF v3 in [BLIP](https://github.com/pmarreck/BLIP) format with selectable compression (LZMA2, bzip2, LZ4, or none). The patch stores Gear CDC cut criteria (min, target, max, and bitmask) so inspect/apply can see how chunks were cut. By default (`--compress best`), LZMA2, bzip2, and zstd are each tried on a sample and the smallest one compresses the whole patch. The sample is the entire serialized patch below 384 KiB, and three 128 KiB slices (start, middle, end) above that. LZ4 is available for speed-over-size use cases but is not included in `best` mode. ZDIF v1 patches are rejected because that format has no cryptographic file identities.

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

Compares difz against bsdiff, xdelta3, and zstd across six exact-size shared-prefix pairs, a 1 MiB seeded interleaved-edit stress pair, and independently built Validate Linux x86_64 executables from two consecutive, exact Git revisions. The real-binary pair must remain runnable ReleaseFast ELF input with distinct source and target hashes; the benchmark builds it reproducibly through Nix instead of altering executable bytes.

New results go to `tests/benchmark/benchmark_log_v3.csv`. Each row records the host OS, architecture, CPU model, benchmark revision, corpus repository/revisions/hashes, source and target sizes, operation count, wall and CPU time, peak difz RSS, and patch sizes. Regression checks compare only the same host and corpus identity. The original `tests/benchmark/benchmark_log.csv` and `tests/benchmark/benchmark_log_v2.csv` remain unmodified historical records of the earlier, idealized corpus.

## Dependencies

- **Zig 0.16.0** (via Nix flake)
- **[BLIP](https://github.com/pmarreck/BLIP)** — variable-length integer encoding + container format (Zig package)
- **PCRE2** — dirtree-compatible ordered path filters

## License

BSD 3-Clause. See [LICENSE](LICENSE).
