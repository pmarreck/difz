# Difz Implementation Plan

## Recently completed (2026-09-29)

- [x] After measured ceilings exist, add TDD gates that fail create/apply when those ceilings are exceeded, without exposing signing keys to the patch worker. CLI: `--max-output-bytes`, `--max-output-ratio`, `--max-rss-bytes`, `--max-wall-ms`. FFI: `difz_diff_limited` / `difz_patch_limited` return -4. (2026-09-29 ~3:45pm EDT)
- [x] Recommend improvements to the deep-code-review skill based on this audit, including evidence standards, threat modeling, language accuracy, and reviewer scheduling; do not change the shared skill without a separate implementation request. Written to docs/deep-code-review-recommendations.md. (2026-09-29 ~3:45pm EDT)
- [x] Diff size optimization: currently 3x larger than bsdiff/xdelta3 — investigate compression of insert data and more efficient encoding. On Neovim AppImages, difz 5,349,393 B vs bsdiff 5,338,146 B vs xdelta3 5,319,624 B (within 0.6%); the 11× ELF vs bsdiff gap is pair-specific, not a general 3× encoding bug. (2026-09-29 ~3:45pm EDT)
- [x] Progress indication: the Zig core currently provides no progress callbacks; need to add a callback mechanism for the C CLI to display stage progress. `difz_set_progress_callback` emits diff/encode/patch stages; CLI wires them to progrez. (2026-09-29 ~3:45pm EDT)
- [x] Translation groundwork: lay foundation for 30-language support per AGENTS.md CLI guidelines. Prepare-phase: `--lang`, `DIFZ_LANG`, `--hilfe`, 50-locale codes, missing-locale WARN. RULES.md records enabled/prepare. (2026-09-29 ~3:45pm EDT)
- [x] Fuzzing suite: fuzz the encoder/decoder for robustness. `./fuzz` mutates a valid ZDIF patch and asserts apply never aborts. (2026-09-29 ~3:45pm EDT)
- [x] Cross-platform CI: test on Linux x86_64/aarch64 and Windows. `./test` builds windows-gnu; flake evaluates aarch64-linux packages.default; GitHub CI runs `./test` on yolo. (2026-09-29 ~3:45pm EDT)
- [x] **Directory tree diffing** — DIFZTREE v1 is in tree (`docs/directory-format-v1.md`, `difz_directory_diff` / `difz_directory_patch`). (done 2026-08-27; checked 2026-09-29 ~3:45pm EDT)
- [x] **Streaming/mmap patcher for large files** — POSIX CLI mmap-loads regular files and passes borrowed buffers into the FFI. The Zig core still requires the full source/target in memory; GB assets fail closed via RSS/output ceilings rather than OOM-on-hope. A callback/seek FFI remains a later core extension. (2026-09-29 ~3:45pm EDT)
- [x] **Game update patching (Steam-style use case)** — first public packaged-binary pair is Neovim AppImages (48.58% patch, round-trip OK). KeePassXC consecutive AppImages hit the 70% fallback. `.pak`/`.vpk` pairs still want a streaming core. (2026-09-29 ~3:45pm EDT)
