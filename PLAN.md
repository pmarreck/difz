# PLAN

Completed work is retained in docs/PLAN_LOG.md; measurement details live in docs/plan_context/.

## Active

- [x] Preserve cross-platform updater caveats, signing evidence, packaging measurements and integration qualification checklist in a linked guide; implementation remains separate from this documentation task. (done 2026-10-27 19:30 EDT; context: docs/cross-platform-application-updates.md)

- [ ] Deliver a Rust implementation of difz, using the existing tests and executable as independent oracles. (context: docs/plan_context/rust-port.md)
	- [x] Retain single-threaded production encoding and application after reviewing the parallel experiment; preserve the prototype and measurements for future review. (done 2026-10-25 16:53 EDT; context: docs/plan_context/parallel-zstd-apply.md)
	- [x] Measure actual 1/4/8-worker zstdz decode against monolithic streams on mixed and repeated-new inputs; preserve all 540 samples, size/CPU/RSS/I/O costs, and transfer break-even calculations. (done 2026-10-25 11:23 EDT; context: docs/plan_context/parallel-zstd-apply.md)
	- [ ] Select the shipped codec for the full Rust port from the measured zstdz, Structured, and Rusty tradeoffs; keep production entry points unchanged pending that decision. (context: docs/plan_context/rust-codec-measurements.md)
	- [x] Explain worker wall-time scaling with verified 8 MiB and 32 MiB ordinary-compression and prefix-diff controls, using explicit 8 MiB jobs. (done 2026-10-24 22:55 EDT; context: docs/plan_context/zstd-worker-apply.md)
	- [x] Compare codec decode and complete difz apply using 24 shuffled blocks and an identical-input control; preserve all 288 paired samples and storage limits. (done 2026-10-24 22:55 EDT; context: docs/plan_context/zstd-worker-apply.md)
	- [x] Characterize four-job prefix reach, deterministic output, frame counts, current native acceptance, and advertised-window limits for Rusty_zstd and zstdz. (done 2026-10-24 23:06 EDT; context: docs/plan_context/rust-port.md)
	- [ ] Qualify bounded hostile-prefix decoding and complete output/window resource contracts before adopting a Rust codec or multi-frame encoding.
	- [x] Qualify Structured-zstd prefix cross-apply, caller-output bounds, checksum verification, and window behavior in Nix; retain complete hostile-input qualification as an adoption gate. (done 2026-10-25 00:28 EDT; context: docs/plan_context/rust-codec-measurements.md)
	- [x] Compare optimized zstdz, Rusty, and Structured codecs on verified 4/16/64 MiB prefix deltas, including source-ownership controls and all 258 timed samples. (done 2026-10-25 00:28 EDT; context: docs/plan_context/rust-codec-measurements.md)
	- [ ] Establish product-wide differential acceptance tests before replacing any production entry point; qualify codec output limits and performance separately.
	- [ ] If the hybrid route is selected, qualify transitive Cargo linking, foreign-buffer ownership, and concurrent/reentrant callback behavior before publishing a Rust library.
	- [ ] Port the file codec, directory metadata and format, filesystem adapters, C API, and CLI while preserving the declared behavior and platform scope.
- [ ] Conform the build to the cross-platform-project-build-arch skill, including canonical implementation selection where applicable, PF/VARIANT/profile outputs, safe host publication, the five-platform matrix, and Nix/native agreement.
	- [x] Move candidate-codec QA into a pinned source-bounded Nix package and sandboxed check; verify compiler-free execution, artifact classification, and source membership. (done 2026-10-24 22:53 EDT; context: docs/plan_context/rust-port.md)
	- [x] Move host-side Zig tests and Rust FFI probes onto Nix-prepared artifacts with preventive Linux filesystem isolation and separate preparation/execution timing. (done 2026-10-25 00:46 EDT; context: docs/plan_context/test-preparation.md)
	- [x] Batch flake-contract evaluation and bound benchmark sources; preserve fresh/cached feedback measurements and verify planning edits leave the benchmark derivation unchanged. (done 2026-10-25 01:04 EDT; context: docs/plan_context/test-preparation.md)
	- [ ] Qualify native macOS and Windows preventive test boundaries before claiming complete native test execution there. (context: docs/plan_context/test-preparation.md)
- [ ] Qualify metadata capture and restore on native macOS and Windows hosts; cross-builds establish compilation only. (context: docs/plan_context/metadata-v2.md)
	- [ ] Resolve native-runner resource policy before scheduling additional remote build waves.
	- [ ] Add native macOS ACL and sparse-file fixtures with independent OS readback before qualifying those metadata families.
	- [ ] Locate an available Windows runner before claiming native Windows metadata qualification.
- [ ] Enforce `--max-rss-bytes` on Darwin after reproducing its limit rejection against current VM usage. (context: docs/plan_context/memory-ceiling.md)
