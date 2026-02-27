# zdiff

A fast binary differ. Given two files A and B, zdiff produces a compact diff — an encoded list of Copy and Insert instructions to transform A into B. Applying the diff to A reconstructs B exactly.

## Performance

Benchmarked on Apple M3 (aarch64), deterministic random binary data:

| File size | Similarity | zdiff | xdelta3 | bsdiff |
|-----------|-----------|-------|---------|--------|
| **10 MB** | 90% | **72 ms** | 120 ms | 2,391 ms |
| **20 MB** | 90% | **135 ms** | 229 ms | 6,106 ms |
| **50 MB** | 90% | **317 ms** | 555 ms | 21,045 ms |
| **20 MB** | 50% | **260 ms** | 1,131 ms | 20,623 ms |
| **20 MB** | 99% | **97 ms** | 47 ms | 2,724 ms |

**1.7x-4.3x faster than xdelta3. 33x-79x faster than bsdiff.** Diff sizes are within 0.5% of both tools. Patch application is 12x faster than bspatch and comparable to xdelta3.

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
zdiff CLI (C) --> C FFI boundary --> Zig core (pure logic, no I/O)
```

The Zig core takes two byte slices and returns a BLIP-encoded diff. All I/O lives in the C CLI. The C CLI calls the Zig library through the C FFI header — dogfooding the same interface that any external consumer would use.

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
