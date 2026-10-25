# PLAN

Completed work is retained in docs/PLAN_LOG.md; measurement details live in docs/plan_context/.

## Active

- [ ] Deliver a Rust implementation of difz, using the existing tests and executable as independent oracles. (context: docs/plan_context/rust-port.md)
	- [ ] Decide the Rust boundary after reviewing the static-link proof: Rust core/CLI with zstdz, Rust CLI with the Zig core, or an entirely Rust implementation; keep production entry points unchanged pending that decision.
	- [x] Explain worker wall-time scaling with verified 8 MiB and 32 MiB ordinary-compression and prefix-diff controls, using explicit 8 MiB jobs. (done 2026-10-24 22:55 EDT; context: docs/plan_context/zstd-worker-apply.md)
	- [x] Compare codec decode and complete difz apply using 24 shuffled blocks and an identical-input control; preserve all 288 paired samples and storage limits. (done 2026-10-24 22:55 EDT; context: docs/plan_context/zstd-worker-apply.md)
	- [x] Clarify compressed-byte identity and worker support; record Rusty's multi-frame path and difz's unqualified concatenated-frame acceptance. (done 2026-10-24 10:34 EDT; context: docs/plan_context/rust-port.md)
	- [x] Characterize four-job prefix reach, deterministic output, frame counts, current native acceptance, and advertised-window limits for Rusty_zstd and zstdz. (done 2026-10-24 23:06 EDT; context: docs/plan_context/rust-port.md)
	- [ ] Qualify bounded hostile-prefix decoding and complete output/window resource contracts before adopting a Rust codec or multi-frame encoding.
	- [x] Measure zstdz level-9 single-thread versus worker modes on partially compressible seeded-random prefix deltas; preserve all 72 verified samples and source-derived multi-job coverage. (done 2026-10-24 11:29 EDT; context: docs/plan_context/zstd-worker-modes.md)
	- [x] Investigate structured-zstd's design intent, raw-prefix APIs, history limits, and upstream-reported performance; preserve all seven level-9 scenarios. (done 2026-10-24 10:16 EDT; context: docs/plan_context/rust-port.md)
	- [x] Qualify Structured-zstd prefix cross-apply, caller-output bounds, checksum verification, and window behavior in Nix; retain complete hostile-input qualification as an adoption gate. (done 2026-10-25 00:28 EDT; context: docs/plan_context/rust-codec-measurements.md)
	- [x] Compare optimized zstdz, Rusty, and Structured codecs on verified 4/16/64 MiB prefix deltas, including source-ownership controls and all 258 timed samples. (done 2026-10-25 00:28 EDT; context: docs/plan_context/rust-codec-measurements.md)
	- [ ] Establish product-wide differential acceptance tests before replacing any production entry point; qualify codec output limits and performance separately.
	- [ ] If the hybrid route is selected, qualify transitive Cargo linking, foreign-buffer ownership, and concurrent/reentrant callback behavior before publishing a Rust library.
	- [ ] Port the file codec, directory metadata and format, filesystem adapters, C API, and CLI while preserving the declared behavior and platform scope.
- [ ] Conform the build to the cross-platform-project-build-arch skill, including canonical implementation selection where applicable, PF/VARIANT/profile outputs, safe host publication, the five-platform matrix, and Nix/native agreement.
	- [x] Move candidate-codec QA into a pinned source-bounded Nix package and sandboxed check; verify compiler-free execution, artifact classification, and source membership. (done 2026-10-24 22:53 EDT; context: docs/plan_context/rust-port.md)
	- [ ] Move the remaining host-side Zig tests and Rust FFI probes onto Nix-prepared artifacts with qualified preventive filesystem isolation and complete feedback accounting.
- [x] Document failure containment when difz is a transitive Rust library dependency and distinguish tested Rust zstd candidates from source-reviewed candidates. (done 2026-10-23 14:41 EDT; context: docs/plan_context/rust-port.md)
- [ ] Qualify metadata capture and restore on native macOS and Windows hosts; cross-builds establish compilation only. (context: docs/plan_context/metadata-v2.md)
	- [ ] Resolve native-runner resource policy before scheduling additional remote build waves.
	- [ ] Add native macOS ACL and sparse-file fixtures with independent OS readback before qualifying those metadata families.
	- [ ] Locate an available Windows runner before claiming native Windows metadata qualification.
- [ ] Enforce `--max-rss-bytes` on Darwin after reproducing its limit rejection against current VM usage. (context: docs/plan_context/memory-ceiling.md)
