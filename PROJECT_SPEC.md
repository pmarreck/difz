# Difz - Project Specification

Difz is a fast, concise binary differ. Given 2 files of some unknown similarity A and B, it outputs a compact diff — an encoded list of Copy and Insert instructions to transform A into B. Delete is implicit (anything in A not covered by a Copy is discarded).

## Architecture

```
difz CLI (C) ──> C FFI boundary ──> Zig core (pure logic, no I/O)
```

The Zig core takes two byte slices and returns a BLIP-encoded diff as a byte slice. All I/O is done by the C CLI. The FFI is dogfooded — the C CLI calls the Zig library through the C header, never importing Zig directly.

## The Algorithm

### Stage 1: Content-Defined Chunking (CDC)

Uses Gear hash (a rolling hash with a 256-entry u64 lookup table seeded via BLAKE3) to split both files into variable-size chunks. Each chunk is fingerprinted with BLAKE3 (128-bit). A HashMap matches B's chunk hashes to find identical regions between files. Matches are sorted and merged to produce a list of `(offset_a, offset_b, length)` triples.

CDC chunk size is configurable via `--chunk-size` (default: 4096 bytes).

### Stage 2: Elder/Myers O(ND) Byte Diff

For each gap between matched chunks, the Myers O(ND) diff algorithm runs on the raw bytes to produce fine-grained Copy and Insert instructions. Copy offsets are adjusted to be absolute positions in file A.

Reference: https://blog.robertelder.org/diff-algorithm/

## Output Format (ZDIF v1)

The diff is encoded as a BLIP container:

```
ARRAY (top-level, with xxHash64 integrity)
+-- [0] RAW: magic "ZDIF" + version byte (0x01)
+-- [1] RAW: metadata (32-byte seed + BLIP(chunk_size) + BLIP(size_a) + BLIP(size_b))
+-- [2] ARRAY: instructions
    +-- [i] RAW: opcode + BLIP fields [+ data]

Opcodes:
  0x00 = Copy(offset_in_A, length)     — BLIP(offset) + BLIP(length)
  0x01 = Insert(length, data)          — BLIP(length) + raw bytes
```

BLIP is a variable-length integer encoding + container format. See [pmarreck/BLIP](https://github.com/pmarreck/BLIP).

## CLI Interface

```
difz <file_a> <file_b> [-o output | -]       # produce diff
difz --patch <file_a> <diff> [-o output | -]  # apply diff
difz -h / --help
difz --about
```

## Edge Cases

| Scenario | Diff output |
|----------|------------|
| Files identical | Copy(0, sizeof(A)) |
| Files completely different | Insert(0, all_of_B) |
| B is empty | (empty instruction list) |
| A is empty | Insert(0, all_of_B) |

## Dependencies

- **Zig 0.15.x** (via Nix flake)
- **BLIP** (Zig package via pmarreck/BLIP)
- **std.crypto.hash.Blake3** (Zig stdlib)
- **hyperfine, bsdiff, xdelta3** (benchmarking, in devShell)

## Status

v0.1.0 — functional, all tests pass (50 Zig unit + 46 CLI integration). Performance needs optimization for large files with low similarity (Elder/Myers O(ND) is quadratic in edit distance).
