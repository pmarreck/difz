# PLAN

Completed work is retained in docs/PLAN_LOG.md; measurement details live in docs/plan_context/.

## Active


- [ ] Deliver a Rust implementation of difz, using the existing tests and executable as independent oracles. (context: docs/plan_context/rust-port.md)
	- [ ] Qualify bounded hostile-prefix decoding and complete output/window resource contracts before adopting a Rust codec or multi-frame encoding.
	- [ ] Establish product-wide differential acceptance tests before replacing any production entry point; qualify codec output limits and performance separately.
	- [ ] Qualify static zstdz linking and Rust buffer/context ownership on all supported targets before publishing the Rust library; the selected codec adapter has no global progress callbacks.
		- [x] Package the pinned archive and bindings as a reusable Nix SDK; verify a standalone Rust parent, matching target metadata, idempotent setup and rejection of wrong targets or conflicting roots. (done 2026-11-06 11:06 EST; context: docs/plan_context/rust-port.md)
	- [ ] Port the file codec, directory metadata and format, filesystem adapters, C API, and CLI while preserving the declared behavior and platform scope.
		- [x] Implement the Rust ZDIF v4 file codec with a statically linked zstdz adapter, independent cross-apply and hostile-input controls, and a transitive Cargo consumer; native Linux qualification passes. (done 2026-11-06 09:18 EST; context: docs/plan_context/rust-port.md)
		- [x] Enforce declared linear growth for Rust file encode/apply in the stable 1–8 MiB parameter regime, with native-oracle checks, required 1/2-core coverage and extended 12-core measurements; historical cohorts remain unbaselined. (done 2026-11-06 09:56 EST; context: docs/plan_context/rust-port.md)
		- [ ] Reduce the new growth gate's feedback cost while preserving native-oracle validation, measurement quality and complete declaration/size coverage. (context: docs/plan_context/rust-port.md)
			- [x] Correct batch rounding and remove the forced five-call floor; preserve the 100 ms estimated target and five samples, accept shared 128-bit seeds, and retain all six valid unbaselined historical observations plus failed seed diagnostics. (done 2026-11-06 12:06 EST; context: docs/plan_context/rust-port.md)
		- [ ] Enforce declared growth for the Rust metadata codec before production adoption. (context: docs/plan_context/rust-port.md)
		- [x] Port omission masks and timestamp transport records to allocation-free Rust with a separately built reference helper, all valid mask combinations, unknown bits, signed-second extremes and malformed-record controls. (done 2026-11-06 10:34 EST; context: docs/plan_context/rust-port.md)
		- [x] Port metadata attribute, ACL and hardlink name validation with closed wire enums and independent binary-byte, tag, Unicode and boundary sweeps. (done 2026-11-06 10:44 EST; context: docs/plan_context/rust-port.md)
		- [x] Reuse owned reference processes for complete metadata sweeps, require one-shot equivalence and malformed-frame rejection, and bound stalled test process groups; a fresh eighteen-test run took 3.40 seconds. (done 2026-11-06 10:52 EST; context: docs/plan_context/rust-port.md)
		- [x] Port the raw metadata record model with owned/borrowed byte fields, legal portable permission masks and explicit field presence; native wire and presence sweeps pass over every selector byte. (done 2026-11-06 11:20 EST; context: docs/plan_context/rust-port.md)
		- [x] Port canonical metadata validation, encoding and BLAKE3 identity behind an immutable validated wrapper; verify all families against native fixtures and recoverable allocation failure under a 128 MiB cap. (done 2026-11-06 12:15 EST; context: docs/plan_context/rust-port.md)
		- [x] Port canonical metadata decoding with borrowed byte fields, preallocation count checks and native differential coverage for truncations, mutations, tags and presence bytes. (done 2026-11-06 12:32 EST; context: docs/plan_context/rust-port.md)
- [ ] Conform the build to the cross-platform-project-build-arch skill, including canonical implementation selection where applicable, PF/VARIANT/profile outputs, safe host publication, the five-platform matrix, and Nix/native agreement.
	- [ ] Qualify native macOS and Windows preventive test boundaries before claiming complete native test execution there. (context: docs/plan_context/test-preparation.md)
- [ ] Qualify metadata capture and restore on native macOS and Windows hosts; cross-builds establish compilation only. (context: docs/plan_context/metadata-v2.md)
	- [ ] Resolve native-runner resource policy before scheduling additional remote build waves.
	- [ ] Add native macOS ACL and sparse-file fixtures with independent OS readback before qualifying those metadata families.
	- [ ] Locate an available Windows runner before claiming native Windows metadata qualification.
- [ ] Enforce `--max-rss-bytes` on Darwin after reproducing its limit rejection against current VM usage. (context: docs/plan_context/memory-ceiling.md)
