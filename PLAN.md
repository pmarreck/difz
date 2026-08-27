# Difz Implementation Plan

## Active Work — GitHub CI Check Drift

- [x] Reproduce GitHub run `33112172154` with a persistent workflow contract requiring the Test step to call canonical `./test`. The RED control reported the exact stale `nix build .#checks.x86_64-linux.tests` command from GitHub's log. (2026-08-27 4:33pm EDT)
- [x] Replace the stale `checks.x86_64-linux.tests` command and run focused and canonical gates. `./test` now owns both the Debug test derivation and benchmark contract; 61 CLI and 12 benchmark cases pass. (2026-08-27 4:33pm EDT)
- [x] Confirm the existing linked `yolo` GitHub Actions badge and make active-workflow badge presence a regression contract. The contract binds README to `ci.yml` and the `yolo` branch. (2026-08-27 4:33pm EDT)
- [x] Verify both GitHub Actions and Mechatron Prime against exact repair commit `e28097c`. GitHub run `33113939884` and Mechatron's 234-second run both passed; the prior Mechatron success no longer masks a separate GitHub failure. (2026-08-27 4:39pm EDT)

## Active Work — LuaJIT-only Random Dependency

- [x] Add a flake contract proving the benchmark selects `random-luajit` at definitive upstream commit `8ddd6aac19be75cacf09128cd3ea75faf9a08dc4`. The exact-set assertion rejects both the aggregate alias and aggregate-plus-Lua combinations. (2026-08-27 3:52pm EDT)
- [x] Repin `random`, replace the aggregate selector, and prove the benchmark's declared inputs and installed closure exclude the other language implementations. The selected closure has 31 paths totaling 125,312,944 bytes; separate direct-input and transitive-runtime checks find no Zig, Rust/Cargo, Lean, or their `random` packages. (2026-08-27 3:52pm EDT)
- [x] Run the focused contract and canonical suite, commit the known-green change as `8323413`, notify `random`, and recoverably clear all four handled notes. `./test` passed all 61 CLI cases and the benchmark contract; every declared flake system evaluated, the completion note is in `random`'s inbox, and `difz/inbox` is empty. (2026-08-27 3:53pm EDT)

## Active Work — Benchmark Corpus and Generator Repair

- [x] Reproduce the broken `random` invocation with a persistent fail-closed fixture-generation test: nonzero generator exits and successful truncation both stop before benchmarking, and captured diagnostics distinguish the failures. The test also exposed the unchecked protected-`dd` overwrite, now replaced by checked prefix/suffix assembly. (2026-08-27 12:32pm EDT)
- [x] Pin `github:pmarreck/random/yolo` at `eadf4e5d2c6a1b295053bc08b2add4ba432c827c`, restrict flake outputs to `x86_64-linux`, `aarch64-linux`, and `aarch64-darwin`, and prove the pinned CLI emits exactly 4,097 binary bytes. `flake-utils` follows the root; `random` retains its own nixpkgs because its Rust 1.97 MSRV fails against difz's Rust 1.94.1 lock. (2026-08-27 12:32pm EDT)
- [x] Add deterministic high-operation interleaved and representative rebuilt-binary corpus shapes, with exact-size and minimum-operation gates. The first v2 run records 7,731 ops for the 1 MiB interleaved pair and 106,285 ops for the 3,427,272-byte executable-shaped pair; every legacy shared-prefix case has only 3 ops. (2026-08-27 12:32pm EDT)
- [x] Record operation count and peak RSS beside time and patch size, then add deterministic corpus floors plus a 25% operation-normalized apply regression threshold. The ReleaseFast benchmark contract avoids timing-dependent assertions while the source-controlled v2 history tracks measured time and RSS. (2026-08-27 12:32pm EDT)
- [x] Qualify README performance claims to the measured corpus, preserve the historical CSV, run focused and canonical Nix checks, commit known-green work locally as `2ec0453`, and reply to Einstein without pushing. The new schema lives in `benchmark_log_v2.csv`; all three handled notes are recoverably in Trash and the inbox is empty. (2026-08-27 12:36pm EDT)

## Active Overnight Work — Validate GUI Directory Updates

- [x] Reconcile the detached `c93648e` checkout and preserve all Peter/agent-owned edits; establish a recoverable working branch before committing. The dirty `elder_diff` bytes matched existing `yolo` commit `9a28ab7`; both symlink edits remain untouched. (2026-08-27 12:26am EDT)
- [x] Reproduce the canonical `./test` zlib-path failure with a persistent failing harness test, then minimally fix the test path and run `./test` plus the exact Nix checks. `./test` now builds `checks.<system>.test`, whose pinned Debug derivation runs Zig units and all 46 CLI cases against static zlib. (2026-08-27 12:26am EDT)
- [x] Prove the existing `elder_diff` allocation-failure regression test RED without its two `errdefer`s and GREEN with them. Without the fix, allocation 2/34 leaked 456 bytes when history growth failed; with `9a28ab7`, the focused test passes and the file matches that commit byte-for-byte. (2026-08-27 12:28am EDT)
- [x] Specify the versioned directory patch contract: canonical bytewise UTF-8 paths, supported entry types/modes, Windows behavior, parser limits, source/target BLAKE3 identities, ordered filters, and staging-only reconstruction. The tree serializer matches an external `b3sum` oracle. (2026-08-27 12:41am EDT)
- [x] Add deterministic no-follow filesystem snapshotting on top of the GREEN canonical path/tree core and ordered `dirtree`-compatible PCRE2 classifier. Escaped wildcards, later-rule precedence, dotfiles, Unicode, negation, and platform-stable case behavior are covered as classifiers over sets. Excluded parents are traversed, included descendants retain structural ancestors, directory symlinks are never followed, and allocation injection is clean. (2026-08-27 1:07am EDT)
- [x] Add TDD-first directory patch encoding and parsing for files, directories, symlinks, mode changes, additions, omissions/deletions, and empty trees. BLAKE3 binds every patch byte; bounded parsing rejects truncation, mutation, traversal, duplicates, unsorted paths, future versions, and excess limits. Allocation injection also found and fixed a pre-existing `encoding.encode` handoff leak. (2026-08-27 12:52am EDT)
- [x] Add TDD-first staged reconstruction using the existing file delta core, with preflight source-tree identity and post-write target-tree identity checks. Wrong same-sized sources and corrupted patches create no stage; preexisting outputs and stage collisions are preserved; owned stages become writable before cleanup; allocation injection leaves no partial output. Symlink targets must remain lexically inside the reconstructed root. (2026-08-27 1:20am EDT)
- [x] **URGENT updater blocker:** reproduce Einstein's one-byte, same-length wrong-file-source acceptance with a persistent test, add cryptographic source and target identities to the native file patch format, reject wrong sources before reconstruction, and verify the reconstructed target identity before returning or writing output. The old ZDIF v1 control returned wrong bytes; ZDIF v2 rejects Einstein's exact one-byte-mutated 16,398,440-byte source with no output, while the correct source reconstructs the target with independent SHA-256 `b141320fbf33914adffe13c35a55fbbe8241b5320fae1779d68e0e5f6eac3344`. (2026-08-27 1:49am EDT)
- [x] Add independent round-trip, mutation/corruption, traversal, truncation, deterministic-repeat, and wrong-source controls; extend fuzzing where useful. The 92 Zig tests cover bounded parsing, structural mutations, checksums, allocation injection, deterministic encoding, and source/target identities; 61 CLI checks add independent SHA-256/cmp/diff filesystem oracles and paired valid controls. A separate fuzz executable was not added because these deterministic byte-mutation and allocation matrices already exercise the new bounded formats. (2026-08-27 1:49am EDT)
- [x] Dogfood the directory core through the C FFI/CLI where practical, document API/format decisions and limitations, update `dirtree` notes, and replace obsolete Garnix CI metadata through the Mechatron workflow if present. The canonical badge and exact target manifest are committed; a read-only GitHub check reports the existing webhook active and healthy. (2026-08-27 1:57am EDT)
- [x] Run `./test`, optimized `./build`, exact Nix checks, and applicable cross-platform evaluation; commit each known-good unit and reply to Einstein with hashes and evidence. The local x86_64-linux package and check targets are green, all four flake system outputs evaluate, and the canonical suite reports 92 Zig plus 61 CLI checks. No `build_all` script exists yet, so native/cross execution for all five supported CLI targets remains a separate build-system gap. Peter did not authorize an external push; `yolo` remains local. A canonical tree can reproduce in-scope `.app` bytes and portable modes, but not xattrs, ACLs, timestamps, hardlink identity, sparse layout, Finder flags, or external notarization state. (2026-08-27 1:57am EDT)
- [x] With the directory deliverable locally complete and its push explicitly withheld, reproduce Einstein's >3-minute apply pathology on the 36,508,624-byte raw Validate GUI client with persistent complexity and allocation-count regressions, profile the file patch decoder/applicator, and fix it TDD-first without regressing the 16 MB fused-client result. The 741,822-op legacy patch performs about 275 billion index-entry decodes because `elementAt(i)` rescans from zero. A stateful cursor reduces this to O(op_count), while one contiguous INSERT allocation replaces hundreds of thousands of page-backed allocations. On the exact artifacts, ReleaseFast apply completes in 0.72s at 105,748 KB peak RSS with no debug marker and matches independent target SHA-256 `9d6680e36e76e36cff496d8789b191adf04eb21b64526c48a0781f12b6c891c1`; the Debug fused control completes in 1.47s and its wrong same-sized source still fails with no output. (2026-08-27 2:16am EDT)

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
