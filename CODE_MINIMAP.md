# Difz Code Minimap

## Architecture

```text
difz CLI (C) -> C FFI -> pure file and canonical-tree cores
                         -> no-follow snapshot/staging adapter
```

All business logic lives in Zig, and the C CLI dogfoods the FFI. File diffing and canonical tree encoding are pure. `directory_fs.zig` is the filesystem adapter.

## Source Files

### `src/lib.zig` — Public API + C FFI exports
- `version` — version string ("0.1.0")
- `difz_diff()` — C FFI: zstd level 9 prefix patch between two buffers, ZDIF v4 blob
- `difz_patch()` — C FFI: apply diff to source buffer, returns reconstructed target
- `difz_directory_diff()` — C FFI: snapshot two directories and return a DIFZTREE patch
- `difz_directory_patch()` — C FFI: apply into a verified new sibling directory and return a per-call metadata compromise mask
- `difz_write_new_file_atomic()` — C FFI: commit a new patch file without replacement
- `difz_free()` — C FFI: free memory returned by difz_diff or difz_patch
- Test block imports all modules to ensure test discovery

### `src/difz.h` — C header for FFI consumers
- Declares buffer and directory functions, ordered path-rule records, and `difz_free`

### `src/difz.c` — C CLI that dogfoods the FFI
- Diff mode: `difz <file_a> <file_b> [-o output]`
- Patch mode: `difz --patch <file_a> <diff> [-o output]`
- Options: `-h`/`--help`, `--about`, `-o`, `--no-progress`, `--no-ansi`/`--no-color`, `--simple`, resource ceilings. `--seed`, `--chunk-size`, `--compress`, `--truncate`, and `--hexlike` are unknown.
- Stream routing: `-`/`@stdin` for stdin, `-`/`@stdout` for stdout, `@stderr` for stderr
- Progress stats to stderr (interactive terminal only)
- Debug build detection (yellow "DEBUG BUILD" via ZDIFF_DEBUG define)
- Directory/file kind classification, ordered `--allow`/`--deny`, and staged directory apply

### `src/directory.zig` — Canonical tree model
- Strict bytewise UTF-8 paths and hierarchy validation
- Portable modes and contained relative symlink targets
- Domain-separated BLAKE3 tree identity

### `src/directory_patch.zig` — DIFZTREE v2 codec
- Deterministic patch creation using the existing file delta core
- Bounded parser with version, structural, checksum, and allocation-failure controls
- Pure in-memory source verification and target reconstruction

### `src/directory_fs.zig` — Filesystem adapter
- Deterministic no-follow snapshots with ordered PCRE2 filters
- New sibling staging, independent post-write re-snapshot, non-replacing rename
- Cleanup of owned stages, including read-only directory modes
- Native metadata restore with verified transport fallbacks and per-apply compromise reporting

### `src/metadata.zig`, `src/symlink_transport.zig` — Canonical metadata
- Bounded canonical records, omission masks, and metadata identity
- Parent-directory transport for symlink fields and explicit absence

### `src/native_stat.zig`, `src/native_acl.zig`, `src/native_finder.zig`, `src/native_sparse.zig` — Native metadata ports
- No-follow file identity and birth time
- Linux access/default ACLs, macOS extended ACLs, and Windows DACLs
- macOS Finder information and staging-safe BSD flags
- Sparse extent queries and hole punching with readback verification

### `src/path_filter.zig`, `src/glob.zig`, `src/pcre2.zig` — Path classifier
- dirtree-compatible glob conversion and PCRE2 matching
- Later matching rules win; included descendants retain structural ancestors

### `src/zstd_patch.zig` — ZDIF v4 file codec
- Magic `ZDIF\x04`, 85-byte header, then one zstd frame
- `encode` — level 9, single thread, source as `ZSTD_CCtx_refPrefix`
- `applyLimited` — source BLAKE3 before allocation, 2 GiB decode window, target BLAKE3 after
- Window log `floor(log2(max(source, target)))+1`, clamped to 10..31; either length above 2 GiB is `WindowTooLarge`
- v3 magic is `InvalidMagic`

### `src/inspect.zig` — Text description of a file patch
- Prints level, source and target sizes, frame size, and both BLAKE3 digests

### `src/patch.zig` — File apply wrapper
- `patch` / `patchLimited` delegate to `zstd_patch.applyLimited`

## Build & Config Files

- `build.zig` — Zig 0.16 build: difz module, static library (libdifz.a), C executable, tests
- `build.zig.zon` — package manifest: zstdz, pcre2, progrez, xattr_stream
- `flake.nix` — Nix flake: devShell (zig, hyperfine, bsdiff, xdelta) + packages.default

## Scripts

- `build` — optimized Nix build by default; `debug` selects a direct Zig Debug build
- `test` — required host metadata tests and default CLI path, Nix unit/CLI/installed-C checks, benchmark contracts, and Windows cross-build; accumulates failures
- `bm` — benchmark suite: hyperfine stats, difz vs bsdiff vs xdelta3, regression detection

## Test Suites

- Zig unit tests live next to the modules and run through `./test`
- CLI integration tests in `tests/cli/test_cli.bash`, including an independent recursive directory oracle
- Benchmark suite in `bm` (run via `bash bm`). `op_count` stays in the CSV and is recorded as 0

## Dependencies

- **Zig 0.16.0** (via Nix flake)
- **zstdz** — the only compressor
- **std.crypto.hash.Blake3** (Zig stdlib) — file and tree identities
- **PCRE2** — ordered directory path filters
- **progrez** — CLI progress
- **xattr_stream** — directory metadata adapter
- **hyperfine** (benchmarking, in flake devShell)
- **bsdiff/bspatch** (benchmark comparison, in flake devShell)
- **xdelta3** (benchmark comparison, in flake devShell)
