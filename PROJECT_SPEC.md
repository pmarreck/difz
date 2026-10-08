# Difz - Project Specification

Difz is a fast binary differ for files and directory trees. Given two files, it emits one zstd level 9 prefix frame. Given two directories, it emits a canonical target manifest whose changed regular files use that same frame. Directory deletion is implicit because reconstruction starts from an empty stage.

## Architecture

```text
difz CLI (C) -> C FFI -> pure file and canonical-tree cores
                         -> no-follow snapshot/staging adapter
```

The C CLI calls the Zig library through the C header. File algorithms and canonical tree encoding take in-memory values. A separate Zig adapter owns directory traversal and staged filesystem writes.

## Directory patches

`DIFZTREE` v2 stores sorted relative UTF-8 paths, directories, regular files, contained relative symlinks, portable modes, canonical metadata, ordered filter rules, and BLAKE3 identities for the source tree, target tree, and complete patch bytes. Every entry has a metadata record, including when empty. The parser rejects v1, traversal, duplicates, unsupported special files, truncation, mutation, incompatible versions, and declared sizes beyond its limits.

Apply verifies the source identity before creating output. It reconstructs into a uniquely named sibling stage, snapshots that filesystem tree again, compares the target identity, and performs a non-replacing rename. It never edits the source or replaces a live tree. See `docs/directory-format.md` for the byte format and platform limitations.

## The file algorithm

Hash both inputs with BLAKE3. Compress the target with the source as a zstd prefix at level 9, single-threaded. The window log is `floor(log2(max(source, target))) + 1`, clamped to 10 through 31. Either input longer than 2 GiB is rejected. Decode sets the maximum window to 2 GiB before attaching the source prefix.

## File output format (ZDIF v4)

```
magic "ZDIF" + version byte 0x04          5 bytes
source BLAKE3                             32 bytes
target BLAKE3                             32 bytes
source length, little-endian u64           8 bytes
target length, little-endian u64           8 bytes
zstd frame
```

Apply checks the source length and BLAKE3 identity before allocating the reconstruction output. It checks the decompressed length and the target BLAKE3 before returning bytes. `ZDIF\x03` fails the magic check.

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

| Scenario | Result |
|----------|--------|
| Files identical | Round-trips through one zstd frame |
| Target empty | A valid empty frame, reconstructed length 0 |
| Source empty | Target compressed with no prefix |
| Wrong source hash | Fails before the reconstruction allocation |
| `ZDIF\x03` | Rejected as a bad magic |

## Dependencies

- **Zig 0.16.0** (via Nix flake)
- **zstdz** (the only compressor)
- **PCRE2** (directory path filters)
- **progrez** (CLI progress)
- **xattr_stream** (directory metadata adapter)
- **std.crypto.hash.Blake3** (Zig stdlib)
- **hyperfine, bsdiff, xdelta3** (benchmarking, in devShell)

## Status

v0.1.0: file and directory diff/patch paths are functional. DIFZTREE v2 is the sole directory codec, with canonical records for every metadata family. The filesystem adapter currently restores xattrs and mtime; remaining native metadata and transport work is tracked in `PLAN.md` and `docs/plan_context/metadata-v2.md`. macOS updater qualification remains a separate requirement.
