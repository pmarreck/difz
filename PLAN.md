# PLAN

Completed work is retained in docs/PLAN_LOG.md; measurement details live in docs/plan_context/.

## Active

- [x] Recover the interrupted rebase and reconcile the remote symlink cleanup while preserving all 49 local commits through 7b29142; the complete suite passes. (done 2026-10-31 09:04 EDT; commit a7c7134)
- [x] Reproduce and fix exported shell functions leaking into the private test HOME; retain a failing-function-set regression and the complete passing host suite. (done 2026-10-31 09:04 EDT; commit a7c7134; context: docs/plan_context/test-preparation.md)
- [x] Publish the recovered branch and verify Mechatron Prime CI for a7c7134 plus zero local/remote divergence; finish tested work with prompt pushes and fetched-revision checks, explicitly reporting holds or divergence. (done 2026-10-31 09:07 EDT; commit a7c7134)
- [x] Preserve cross-platform updater caveats, signing evidence, packaging measurements and integration qualification checklist in a linked guide; implementation remains separate from this documentation task. (done 2026-10-27 19:30 EDT; context: docs/cross-platform-application-updates.md)

- [ ] Deliver a Rust implementation of difz, using the existing tests and executable as independent oracles. (context: docs/plan_context/rust-port.md)
	- [x] Retain single-threaded production encoding and application after reviewing the parallel experiment; preserve the prototype and measurements for future review. (done 2026-10-25 16:53 EDT; context: docs/plan_context/parallel-zstd-apply.md)
	- [x] Select the shipped codec for the full Rust port. Answer: Retain zstdz through its statically linked C API; accept native-code process-failure risk while rewriting difz itself in Rust. (done 2026-11-06 09:04 EST; context: docs/plan_context/rust-port.md)
	- [ ] Qualify bounded hostile-prefix decoding and complete output/window resource contracts before adopting a Rust codec or multi-frame encoding.
	- [ ] Establish product-wide differential acceptance tests before replacing any production entry point; qualify codec output limits and performance separately.
		- [x] Qualify a reusable file and portable-tree cross-apply gate, seven broken adapters, 15 invalid artifact pairs, and complete native CI registration. (done 2026-11-02 20:51 EST; context: docs/plan_context/rust-port.md)
	- [ ] Qualify static zstdz linking and Rust buffer/context ownership on all supported targets before publishing the Rust library; the selected codec adapter has no global progress callbacks.
	- [ ] Port the file codec, directory metadata and format, filesystem adapters, C API, and CLI while preserving the declared behavior and platform scope.
		- [x] Implement the Rust ZDIF v4 file codec with a statically linked zstdz adapter, independent cross-apply and hostile-input controls, and a transitive Cargo consumer; native Linux qualification passes. (done 2026-11-06 09:18 EST; context: docs/plan_context/rust-port.md)
		- [ ] Enforce declared linear growth for the Rust file encode/apply hot paths through the shared profiler, with optimized in-memory measurements and independent result checks.
		- [x] Port allocation-free ZDIF v4 header parsing and encoding to Rust, using native headers and independent BLAKE3 identities as acceptance controls. (done 2026-11-02 21:24 EST; context: docs/plan_context/rust-port.md)
- [ ] Conform the build to the cross-platform-project-build-arch skill, including canonical implementation selection where applicable, PF/VARIANT/profile outputs, safe host publication, the five-platform matrix, and Nix/native agreement.
	- [x] Require Nix for optimized and Debug builds, select the exact returned artifact, and verify refusal and preparation-failure preservation through the real build adapter in disposable projects. (done 2026-11-02 21:28 EST; context: docs/plan_context/test-preparation.md)
	- [ ] Qualify native macOS and Windows preventive test boundaries before claiming complete native test execution there. (context: docs/plan_context/test-preparation.md)
- [ ] Qualify metadata capture and restore on native macOS and Windows hosts; cross-builds establish compilation only. (context: docs/plan_context/metadata-v2.md)
	- [ ] Resolve native-runner resource policy before scheduling additional remote build waves.
	- [ ] Add native macOS ACL and sparse-file fixtures with independent OS readback before qualifying those metadata families.
	- [ ] Locate an available Windows runner before claiming native Windows metadata qualification.
- [ ] Enforce `--max-rss-bytes` on Darwin after reproducing its limit rejection against current VM usage. (context: docs/plan_context/memory-ceiling.md)
