# PLAN

Completed work is retained in docs/PLAN_LOG.md; measurement details live in docs/plan_context/.

## Active


- [ ] Deliver a Rust implementation of difz, using the existing tests and executable as independent oracles. (context: docs/plan_context/rust-port.md)
	- [ ] Establish product-wide differential acceptance tests before replacing any production entry point; qualify codec output limits and performance separately.
	- [ ] Qualify static zstdz linking and Rust buffer/context ownership on all supported targets before publishing the Rust library; the selected codec adapter has no global progress callbacks.
	- [ ] Port the file codec, directory metadata and format, filesystem adapters, C API, and CLI while preserving the declared behavior and platform scope.
		- [x] Qualify the Linux filesystem and packaged ABI increments with the complete suite, including fresh growth measurements under bounded admission. (done 2026-11-25 18:45 EST; commit ad8584f; context: docs/plan_context/rust-port.md)
		- [x] Reduce the new growth gate's feedback cost while preserving native-oracle validation, measurement quality and complete declaration/size coverage; structure execution fell from 56.59 to 40.90 seconds, with paired controls and unchanged bounds. (done 2026-11-25 22:19 EST; commit 3526bad; context: docs/plan_context/rust-port.md)
		- [x] Enforce declared growth for all eight Rust metadata and directory operations on one and two cores; the complete Linux suite passes every adjacent size ratio. (done 2026-11-25 18:45 EST; commit 7351ce2; context: docs/plan_context/rust-port.md)
			- [x] Qualify shared ownership and bounded memory use for hardlinks referring to Rust-owned delta output, with 96-alias and copy-mutation controls. (done 2026-11-25 18:45 EST; commit 012115f; context: docs/plan_context/rust-port.md)
		- [x] Merge Linux raw-attribute transport and capture native ACL plus strict ACL/Finder/hardlink transports with owned values and thirteen required native fixtures; the complete suite passes. (done 2026-11-18 23:28 EST; commit d37d24c; context: docs/plan_context/rust-port.md)
		- [x] Add bounded Linux timestamp and native attribute capture with transport witnesses, family exclusions and nine mandatory native attribute fixtures; the complete Linux suite passes. (done 2026-11-18 23:06 EST; commit 0b271e5; context: docs/plan_context/rust-port.md)
		- [x] Port allocation-free native attribute-name mapping for every OS/class, using the untouched pinned xattr_stream source as oracle; byte/length/buffer/inverse controls reject a broken mapper, and the combined complete suite passes. (done 2026-11-06 18:52 EST; context: docs/plan_context/rust-port.md)
		- [x] Add Linux descriptor-based raw attribute replacement/removal with independent binary/empty/absence/error/path-replacement readback and all five native fixtures required; the combined complete suite passes. (done 2026-11-06 18:52 EST; context: docs/plan_context/rust-port.md)
- [ ] Conform the build to the cross-platform-project-build-arch skill, including canonical implementation selection where applicable, PF/VARIANT/profile outputs, safe host publication, the five-platform matrix, and Nix/native agreement.
	- [x] Add verified implementation selection, transactional Nix publication, independent SDK checks and all four optimized/Debug Windows Zig cross-builds; native foreign execution remains pending. (done 2026-11-25 18:45 EST; commit ad8584f; context: docs/plan_context/rust-port.md)
	- [ ] Stamp builds with verified rN-abcdef provenance from the built commit and its recorded yolo base, keeping dirty state separate and rejecting unavailable provenance for releases. (context: docs/plan_context/build-provenance.md)
		- [x] Capture source-bound local history, stamp both frontends and SDKs, and guard release preparation; the complete suite, exact-commit CI and both clean r202-f051e6 products pass. (done 2026-11-25 23:41 EST; commit f051e6c; context: docs/plan_context/build-provenance.md)
		- [ ] Activate and qualify the reviewed CI provenance handoff after bounded crash/orphan recovery is verified. (context: docs/plan_context/build-provenance.md)
	- [x] Use static musl consistently for Linux Rust product, SDK and test builders; qualify Linux AMD64 standalone execution for both backends/profiles with independent header, byte, closure and empty-root controls. (done 2026-11-25 21:54 EST; commit b4962de; context: docs/plan_context/rust-port.md)
	- [ ] Qualify native macOS and Windows preventive test boundaries before claiming complete native test execution there. (context: docs/plan_context/test-preparation.md)
- [ ] Qualify metadata capture and restore on native macOS and Windows hosts; cross-builds establish compilation only. (context: docs/plan_context/metadata-v2.md)
	- [ ] Establish per-job memory/time enforcement for the native macOS runner and verify bounded Windows AMD64/ARM64 routes before remote qualification waves. (context: docs/plan_context/rust-port.md)
	- [ ] Add native macOS ACL and sparse-file fixtures with independent OS readback before qualifying those metadata families.
	- [ ] Locate an available Windows runner before claiming native Windows metadata qualification.
- [ ] Enforce `--max-rss-bytes` on Darwin after reproducing its limit rejection against current VM usage. (context: docs/plan_context/memory-ceiling.md)

## Deferred

- [ ] Qualify bounded hostile-prefix decoding and complete output/window contracts if a future decision adopts a Rust codec or multi-frame encoding; production remains single-frame statically linked zstdz. (context: docs/plan_context/rust-port.md)
- [ ] Schedule and qualify a narrow Rust 1.100 compiler-provider update after the current port checkpoint, preserving the lockfile, MSRV and platform holds. (context: docs/plan_context/rust-port.md)
