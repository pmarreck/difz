# Difz Implementation Plan

## Active Overnight Work — Validate GUI Directory Updates

- [x] Reconcile the detached `c93648e` checkout and preserve all Peter/agent-owned edits; establish a recoverable working branch before committing. The dirty `elder_diff` bytes matched existing `yolo` commit `9a28ab7`; both symlink edits remain untouched. (2026-08-27 12:26am EDT)
- [x] Reproduce the canonical `./test` zlib-path failure with a persistent failing harness test, then minimally fix the test path and run `./test` plus the exact Nix checks. `./test` now builds `checks.<system>.test`, whose pinned Debug derivation runs Zig units and all 46 CLI cases against static zlib. (2026-08-27 12:26am EDT)
- [x] Prove the existing `elder_diff` allocation-failure regression test RED without its two `errdefer`s and GREEN with them. Without the fix, allocation 2/34 leaked 456 bytes when history growth failed; with `9a28ab7`, the focused test passes and the file matches that commit byte-for-byte. (2026-08-27 12:28am EDT)
- [x] Specify the versioned directory patch contract: canonical bytewise UTF-8 paths, supported entry types/modes, Windows behavior, parser limits, source/target BLAKE3 identities, ordered filters, and staging-only reconstruction. The tree serializer matches an external `b3sum` oracle. (2026-08-27 12:41am EDT)
- [x] Add deterministic no-follow filesystem snapshotting on top of the GREEN canonical path/tree core and ordered `dirtree`-compatible PCRE2 classifier. Escaped wildcards, later-rule precedence, dotfiles, Unicode, negation, and platform-stable case behavior are covered as classifiers over sets. Excluded parents are traversed, included descendants retain structural ancestors, directory symlinks are never followed, and allocation injection is clean. (2026-08-27 1:07am EDT)
- [x] Add TDD-first directory patch encoding and parsing for files, directories, symlinks, mode changes, additions, omissions/deletions, and empty trees. BLAKE3 binds every patch byte; bounded parsing rejects truncation, mutation, traversal, duplicates, unsorted paths, future versions, and excess limits. Allocation injection also found and fixed a pre-existing `encoding.encode` handoff leak. (2026-08-27 12:52am EDT)
- [x] Add TDD-first staged reconstruction using the existing file delta core, with preflight source-tree identity and post-write target-tree identity checks. Wrong same-sized sources and corrupted patches create no stage; preexisting outputs and stage collisions are preserved; owned stages become writable before cleanup; allocation injection leaves no partial output. Symlink targets must remain lexically inside the reconstructed root. (2026-08-27 1:20am EDT)
- [ ] Add independent round-trip, mutation/corruption, traversal, truncation, deterministic-repeat, and wrong-source controls; extend fuzzing where useful. Curiosity poke: pair rejection mutations with known-good specificity cases so reject-everything cannot pass.
- [ ] Dogfood the directory core through the C FFI/CLI where practical, document API/format decisions and limitations, update `dirtree` notes, and replace obsolete Garnix CI metadata through the Mechatron workflow if present. Curiosity poke: determine which packaging metadata is outside difz's portable tree model.
- [ ] Run `./test`, optimized `./build`, exact Nix checks, and applicable cross-platform builds; commit each known-good unit, push after green, and reply to Einstein with hashes and evidence. Curiosity poke: verify whether a canonically packaged notarized `.app` can be reconstructed byte-for-byte without claiming preservation of external notarization state.
- [ ] After the directory deliverable is shipped, reproduce Einstein's >3-minute apply pathology on the 36,508,624-byte raw Validate GUI client with a persistent performance regression test, profile the file patch decoder/applicator, and fix it TDD-first without regressing the 16 MB fused-client result. Curiosity poke: distinguish decompression/decoding cost from instruction application, and obtain the exact source/patch artifacts or a deterministic shape-equivalent fixture if they are not already in scope.

## Completed Tasks

- [x] Task 1: Project Scaffolding — flake.nix, build.zig, build.zig.zon, src/lib.zig, shell scripts, .gitignore (2026-02-25 ~10:30pm EST)
- [x] Task 2: Gear Hash — rolling hash with BLAKE3-seeded 256-entry u64 lookup table (2026-02-25 ~10:45pm EST)
- [x] Task 3: CDC — Content-Defined Chunking using Gear hash (2026-02-25 ~11:00pm EST)
- [x] Task 4: Chunk Matching — BLAKE3 fingerprinting, HashMap-based match finding (2026-02-25 ~11:15pm EST)
- [x] Task 5: Elder/Myers O(ND) Byte Diff — fine-grained byte-level diffing (2026-02-25 ~11:30pm EST)
- [x] Task 6: Two-Stage Diff Orchestrator — CDC coarse matching + Elder gap refinement (2026-02-25 ~11:45pm EST)
- [x] Task 7: BLIP Encoding — serialize diff instructions as BLIP ARRAY container (2026-02-26 ~12:00am EST)
- [x] Task 8: Patch — apply BLIP-encoded diff to reconstruct target (2026-02-26 ~12:15am EST)
- [x] Task 9: C FFI Layer — difz_diff, difz_patch, difz_free exports + difz.h (2026-02-26 ~12:30am EST)
- [x] Task 10: C CLI — C program dogfooding the FFI, 46 CLI integration tests (2026-02-26 ~12:45am EST)
- [x] Task 11: Benchmark Suite — hyperfine stats, difz vs bsdiff vs xdelta3 (2026-02-26 ~1:00am EST)
- [x] Task 12: Documentation — CODE_MINIMAP.md, PLAN.md, PROJECT_SPEC.md updates (2026-02-26 ~1:15am EST)

- [x] Task 13: Edit Distance Cap — cap Myers at sqrt(N+M)*2+16, bail to raw Insert on large dissimilar gaps (~170x speedup on 100KB/10% similar) (2026-02-26)

## Next Steps

- [x] ~~Performance optimization: Elder/Myers O(ND) is O(n*d) which is very slow for large dissimilar regions~~ — DONE: edit distance cap (Task 13)
- [ ] Diff size optimization: currently 3x larger than bsdiff/xdelta3 — investigate compression of insert data and more efficient encoding
- [ ] Progress indication: the Zig core currently provides no progress callbacks; need to add a callback mechanism for the C CLI to display stage progress
- [ ] Translation groundwork: lay foundation for 30-language support per AGENTS.md CLI guidelines
- [ ] Fuzzing suite: fuzz the encoder/decoder for robustness
- [ ] Cross-platform CI: test on Linux x86_64/aarch64 and Windows

## Future Exploration

- [ ] **Directory tree diffing** — orchestration layer above the C FFI that walks two directory trees, diffs each changed file via `difz_diff()`, and packages results into a single archive (manifest + per-file diff blobs). Rename detection via whole-file BLAKE3. Could live as `difz --recursive` or a separate `difz-tree` tool. The Zig core stays untouched; this is purely CLI/tooling.
- [ ] **Streaming/mmap patcher for large files** — current model materializes both inputs in memory; GB-scale game assets need a streaming or mmap-based patch path. Would require a new FFI shape (callback-based or seekable reader) — a clean core extension, not a rewrite.
- [ ] **Game update patching (Steam-style use case)** — games repack large archive files (`.pak`, `.vpk`, Unity asset bundles) where content is ~95% identical but offsets shift everywhere. Fixed-chunk delta systems (like Steam's) re-download entire chunks for any change. difz's CDC natively handles shifted content, potentially producing patches 5-10x smaller. Requires the directory tree and streaming layers above. Compelling benchmark target: real game update before/after pairs.
