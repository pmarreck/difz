# PLAN

Completed work is retained in docs/PLAN_LOG.md; measurement details live in docs/plan_context/.

## Active

- [ ] Deliver a Rust implementation of difz, using the existing tests and executable as independent oracles. (context: docs/plan_context/rust-port.md)
	- [ ] Decide the Rust boundary after reviewing the static-link proof: Rust core/CLI with zstdz, Rust CLI with the Zig core, or an entirely Rust implementation; keep production entry points unchanged pending that decision.
	- [x] Clarify compressed-byte identity and worker support; record Rusty's multi-frame path and difz's unqualified concatenated-frame acceptance. (done 2026-10-24 10:34 EDT; context: docs/plan_context/rust-port.md)
	- [ ] Qualify multi-job prefix compression and frame acceptance for Rusty_zstd and zstdz, including original-source reach, deterministic output, and resource limits.
	- [x] Investigate structured-zstd's design intent, raw-prefix APIs, history limits, and upstream-reported performance; preserve all seven level-9 scenarios. (done 2026-10-24 10:16 EDT; context: docs/plan_context/rust-port.md)
	- [ ] Qualify structured-zstd with isolated Nix-built prefix cross-apply and resource-limit tests, then compare optimized codecs on the same verified binary delta cases.
	- [x] Preserve the Zig reference and cross-apply Rusty_zstd and zstdz frames, including distant raw-prefix references and a 2 GiB advertised window. (done 2026-10-23 09:11 EDT)
	- [ ] Establish product-wide differential acceptance tests before replacing any production entry point; qualify codec output limits and performance separately.
	- [ ] If the hybrid route is selected, qualify transitive Cargo linking, foreign-buffer ownership, and concurrent/reentrant callback behavior before publishing a Rust library.
	- [ ] Port the file codec, directory metadata and format, filesystem adapters, C API, and CLI while preserving the declared behavior and platform scope.
- [x] Retire CODE_MINIMAP.md after migrating its useful architecture and file-purpose information into dirtree notes. (done 2026-10-23 14:41 EDT)
- [ ] Conform the build to the cross-platform-project-build-arch skill, including canonical implementation selection where applicable, PF/VARIANT/profile outputs, safe host publication, the five-platform matrix, and Nix/native agreement.
	- [ ] Move Rust probe preparation into pinned, source-bounded Nix derivations and execute prepared artifacts in preventive isolation, recording queue, setup, compilation, execution, and total feedback time.
- [x] Document failure containment when difz is a transitive Rust library dependency and distinguish tested Rust zstd candidates from source-reviewed candidates. (done 2026-10-23 14:41 EDT; context: docs/plan_context/rust-port.md)
- [ ] Qualify metadata capture and restore on native macOS and Windows hosts; cross-builds establish compilation only. (context: docs/plan_context/metadata-v2.md)
	- [ ] Resolve native-runner resource policy before scheduling additional remote build waves.
	- [ ] Add native macOS ACL and sparse-file fixtures with independent OS readback before qualifying those metadata families.
	- [ ] Locate an available Windows runner before claiming native Windows metadata qualification.
- [ ] Enforce `--max-rss-bytes` on Darwin after reproducing its limit rejection against current VM usage. (context: docs/plan_context/memory-ceiling.md)
