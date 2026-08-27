# Difz - Project Specification

Difz is a fast binary differ for files and directory trees. Given two files, it emits Copy and Insert instructions. Given two directories, it emits a canonical target manifest whose changed regular files use the same file delta core. Directory deletion is implicit because reconstruction starts from an empty stage.

## Architecture

```text
difz CLI (C) -> C FFI -> pure file and canonical-tree cores
                         -> no-follow snapshot/staging adapter
```

The C CLI calls the Zig library through the C header. File algorithms and canonical tree encoding take in-memory values. A separate Zig adapter owns directory traversal and staged filesystem writes.

## Directory patches

`DIFZTREE` v1 stores sorted relative UTF-8 paths, directories, regular files, contained relative symlinks, portable modes, ordered filter rules, and BLAKE3 identities for the source tree, target tree, and complete patch bytes. The parser rejects traversal, duplicates, unsupported special files, truncation, mutation, incompatible versions, and declared sizes beyond its limits.

Apply verifies the source identity before creating output. It reconstructs into a uniquely named sibling stage, snapshots that filesystem tree again, compares the target identity, and performs a non-replacing rename. It never edits the source or replaces a live tree. See `docs/directory-format-v1.md` for the byte format and platform limitations.

## The Algorithm

### Stage 1: Content-Defined Chunking (CDC)

Uses Gear hash (a rolling hash with a 256-entry u64 lookup table seeded via BLAKE3) to split both files into variable-size chunks. Each chunk is fingerprinted with BLAKE3 (128-bit). A HashMap matches B's chunk hashes to find identical regions between files. Matches are sorted and merged to produce a list of `(offset_a, offset_b, length)` triples.

CDC chunk size is configurable via `--chunk-size` (default: 4096 bytes).

### Stage 2: Elder/Myers O(ND) Byte Diff

For each gap between matched chunks, the Myers O(ND) diff algorithm runs on the raw bytes to produce fine-grained Copy and Insert instructions. Copy offsets are adjusted to be absolute positions in file A.

Reference: https://blog.robertelder.org/diff-algorithm/

## File output format (ZDIF v2)

The diff is encoded as a BLIP container:

```
ARRAY (top-level, with xxHash64 integrity)
+-- [0] DATA: magic "ZDIF" + version byte (0x02)
+-- [1] DATA: metadata
|   +-- 32-byte CDC seed
|   +-- 32-byte BLAKE3 source identity
|   +-- 32-byte BLAKE3 target identity
|   +-- BLIP(chunk_size) + BLIP(size_a) + BLIP(size_b)
+-- [2] ARRAY: instructions
    +-- [i] DATA: opcode + BLIP fields [+ data]

Opcodes:
  0x00 = Copy(offset_in_A, length)     — BLIP(offset) + BLIP(length)
  0x01 = Insert(length, data)          — BLIP(length) + raw bytes
```

BLIP is a variable-length integer encoding + container format. See [pmarreck/BLIP](https://github.com/pmarreck/BLIP).

Apply checks the source length and BLAKE3 identity before allocating the reconstruction output. It checks the target length and BLAKE3 identity before returning bytes to the caller. ZDIF v1 is intentionally incompatible because it stored lengths but no file identities.

## CLI Interface

```
difz <file_a> <file_b> [-o output | -]       # produce diff
difz --patch <file_a> <diff> [-o output | -]  # apply diff
difz [--allow GLOB] [--deny GLOB] <dir_a> <dir_b> -o patch
difz --patch <dir_a> <patch> -o <new_dir>
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

- **Zig 0.16.0** (via Nix flake)
- **BLIP** (Zig package via pmarreck/BLIP)
- **std.crypto.hash.Blake3** (Zig stdlib)
- **hyperfine, bsdiff, xdelta3** (benchmarking, in devShell)

## Status

v0.1.0 — file and directory diff/patch paths are functional. The canonical suite has 92 Zig tests and 61 CLI integration checks. Filesystem metadata outside portable mode bits, including xattrs, ACLs, timestamps, hardlink identity, sparse layout, Finder flags, and external notarization state, remains outside DIFZTREE v1.
