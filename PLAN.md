# PLAN

Completed work is retained in docs/PLAN_LOG.md; measurement details live in docs/plan_context/.

## Active

- [ ] Deliver a Rust implementation of difz, using the existing tests and executable as independent oracles. (context: docs/plan_context/rust-port.md)
	- [ ] Decide the Rust boundary after reviewing the static-link proof: Rust core/CLI with zstdz, Rust CLI with the Zig core, or an entirely Rust implementation; keep production entry points unchanged pending that decision.
	- [x] Prove that a Rust executable statically links the installed Zig/libdifz archive and passes binary buffers through the existing C ABI on Linux x86_64. (done 2026-10-23 09:11 EDT)
	- [x] Compare Rust zstd candidates' raw-prefix APIs, encoder windows, long-distance matching, toolchain requirements, and native dependencies. (done 2026-10-23 09:11 EDT)
	- [x] Preserve the Zig reference and cross-apply Rusty_zstd and zstdz frames, including distant raw-prefix references and a 2 GiB advertised window. (done 2026-10-23 09:11 EDT)
	- [ ] Establish product-wide differential acceptance tests before replacing any production entry point; qualify codec output limits and performance separately.
	- [ ] Port the file codec, directory metadata and format, filesystem adapters, C API, and CLI while preserving the declared behavior and platform scope.
- [ ] Qualify metadata capture and restore on native macOS and Windows hosts; cross-builds establish compilation only. (context: docs/plan_context/metadata-v2.md)
	- [x] Complete the single admitted native-runner reservation without starting an additional remote build wave. (done 2026-10-14 14:53 EDT)
	- [x] Run the native macOS metadata suite in an isolated runner checkout and preserve failures or qualification evidence; 89 passed, seven Linux cases skipped at c59caee. (done 2026-10-14 14:53 EDT)
	- [ ] Resolve native-runner resource policy before scheduling additional remote build waves.
	- [ ] Add native macOS ACL and sparse-file fixtures with independent OS readback before qualifying those metadata families.
	- [ ] Locate an available Windows runner before claiming native Windows metadata qualification.
- [ ] Enforce `--max-rss-bytes` on Darwin after reproducing its limit rejection against current VM usage. (context: docs/plan_context/memory-ceiling.md)
