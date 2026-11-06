# PLAN

Completed work is retained in docs/PLAN_LOG.md; measurement details live in docs/plan_context/.

## Active


- [ ] Deliver a Rust implementation of difz, using the existing tests and executable as independent oracles. (context: docs/plan_context/rust-port.md)
	- [ ] Qualify bounded hostile-prefix decoding and complete output/window resource contracts before adopting a Rust codec or multi-frame encoding.
	- [ ] Establish product-wide differential acceptance tests before replacing any production entry point; qualify codec output limits and performance separately.
	- [ ] Qualify static zstdz linking and Rust buffer/context ownership on all supported targets before publishing the Rust library; the selected codec adapter has no global progress callbacks.
	- [ ] Port the file codec, directory metadata and format, filesystem adapters, C API, and CLI while preserving the declared behavior and platform scope.
		- [ ] Reduce the new growth gate's feedback cost while preserving native-oracle validation, measurement quality and complete declaration/size coverage. (context: docs/plan_context/rust-port.md)
			- [x] Interleave size sampling and attest resolved window/LDM state, retaining the v5 filter failure, paired diagnostics, native instruction controls and four unbaselined v6 observations without changing sample targets or limits. (done 2026-11-06 15:45 EST; context: docs/plan_context/rust-port.md)
			- [x] Release calibration output before timed sampling, enforce output lifetimes with a required Release control, and separate v5 measurements from retained v4 growth diagnostics without changing limits. (done 2026-11-06 13:01 EST; context: docs/plan_context/rust-port.md)
		- [ ] Enforce declared growth for the Rust metadata and directory codecs before production adoption. (context: docs/plan_context/rust-port.md)
		- [ ] Qualify the Rust path filter against the pinned native matcher before directory body decoding. (context: docs/plan_context/rust-port.md)
		- [x] Correct native final-newline glob anchoring with absolute subject anchors and a failing production regression, preserving explicit/wildcard newline consumption. (done 2026-11-06 14:49 EST; context: docs/plan_context/rust-port.md)
		- [x] Port metadata normalization with omission before validation, in-place sorting and extent merging, native coverage for all omission masks and mixed errors, and retained byte ownership. (done 2026-11-06 13:01 EST; context: docs/plan_context/rust-port.md)
		- [x] Port allocation-free metadata restore plans, typed compromises and cumulative reports with native comparison for all capability masks, isolated presence and every report bit combination. (done 2026-11-06 13:25 EST; context: docs/plan_context/rust-port.md)
		- [x] Port allocation-free DIFZTREE path and symlink validation with native error precedence, binary/Unicode sweeps, path limits and lexical containment controls. (done 2026-11-06 13:38 EST; context: docs/plan_context/rust-port.md)
		- [x] Port owned/borrowed tree records with typed portable modes and structural directory/file/symlink variants; compare every u16 mode and record views with native validation and identities. (done 2026-11-06 13:50 EST; context: docs/plan_context/rust-port.md)
		- [x] Port immutable validated snapshots and DIFZTREE identity with native structure/relation error precedence, complete hardlink metadata checks, root restrictions and exact entry-count boundaries. (done 2026-11-06 14:18 EST; context: docs/plan_context/rust-port.md)
		- [x] Port allocation-free DIFZTREE v2 envelope encoding and integrity parsing with native-produced fixtures, accepted mutations, count/body bounds and error precedence; body semantics remain pending. (done 2026-11-06 14:32 EST; context: docs/plan_context/rust-port.md)
- [ ] Conform the build to the cross-platform-project-build-arch skill, including canonical implementation selection where applicable, PF/VARIANT/profile outputs, safe host publication, the five-platform matrix, and Nix/native agreement.
	- [ ] Qualify native macOS and Windows preventive test boundaries before claiming complete native test execution there. (context: docs/plan_context/test-preparation.md)
- [x] Publish the preserved old-cdc-plus-compression-probe-design branch after preparing its original immutable checks and independently verifying the remote ref. (done 2026-11-06 13:08 EST; commit a83c041)
- [ ] Qualify metadata capture and restore on native macOS and Windows hosts; cross-builds establish compilation only. (context: docs/plan_context/metadata-v2.md)
	- [ ] Resolve native-runner resource policy before scheduling additional remote build waves.
	- [ ] Add native macOS ACL and sparse-file fixtures with independent OS readback before qualifying those metadata families.
	- [ ] Locate an available Windows runner before claiming native Windows metadata qualification.
- [ ] Enforce `--max-rss-bytes` on Darwin after reproducing its limit rejection against current VM usage. (context: docs/plan_context/memory-ceiling.md)
