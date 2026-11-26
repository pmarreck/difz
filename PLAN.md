# PLAN

Completed work is retained in docs/PLAN_LOG.md; measurement details live in docs/plan_context/.

## Active


- [ ] Deliver a Rust implementation of difz, using the existing tests and executable as independent oracles. (context: docs/plan_context/rust-port.md)
	- [ ] Establish product-wide differential acceptance tests before replacing any production entry point; qualify codec output limits and performance separately.
	- [ ] Qualify static zstdz linking and Rust buffer/context ownership on all supported targets before publishing the Rust library; the selected codec adapter has no global progress callbacks.
	- [ ] Port the file codec, directory metadata and format, filesystem adapters, C API, and CLI while preserving the declared behavior and platform scope.
		- [x] Implement pinned Windows directory handles and bounded no-follow file reads; all twenty required filesystem cases, the complete suite and exact-commit CI pass under both Wine routes. (done 2026-11-26 05:35 EST; commit db78e4e; context: docs/plan_context/rust-port.md)
		- [x] Implement no-follow Windows entry inspection with complete native identities and timestamps; all twenty-eight Windows cases, the complete suite and exact-commit CI pass. (done 2026-11-26 05:51 EST; commit 1aca8ac; context: docs/plan_context/rust-port.md)
		- [x] Add bounded Windows directory enumeration through independent pinned-handle streams; all forty Windows cases, the complete suite and exact-commit CI pass. (done 2026-11-26 06:11 EST; commit af6b9b7; context: docs/plan_context/rust-port.md)
		- [x] Add bounded no-follow Windows link-target reads; all fifty-two Windows cases, the complete suite and exact-commit CI pass with native junction and substitute/display controls. (done 2026-11-26 06:41 EST; commit 9ca48ca; context: docs/plan_context/rust-port.md)
		- [ ] Reuse bounded tree capture on Windows and qualify metadata-free directory encoding against the original implementation. (context: docs/plan_context/rust-port.md)
			- [x] Qualify metadata-free original Windows directory round trips with portable multi-component links, independent hashes, containment and owned-stage cleanup; all fifty-six Windows cases, the complete suite and exact-commit CI pass. (done 2026-11-26 07:22 EST; commit e4881d5; context: docs/plan_context/rust-port.md)
- [ ] Conform the build to the cross-platform-project-build-arch skill, including canonical implementation selection where applicable, PF/VARIANT/profile outputs, safe host publication, the five-platform matrix, and Nix/native agreement.
	- [x] Build both Windows AMD64 Rust profiles through Nix and qualify CLI units, packaged C ABI ownership/exports, shared file acceptance and standalone runtime imports under bounded Wine; the complete suite and exact-commit CI pass. (done 2026-11-26 03:28 EST; commit 3139c51; context: docs/plan_context/rust-port.md)
	- [x] Build and qualify both Windows ARM64 Rust profiles through the pinned GNU LLVM toolchain, private QEMU/Wine execution and external C ABI acceptance; real ownership/panic recovery, the complete suite and all 22 exact-commit CI targets pass. (done 2026-11-26 04:47 EST; commit ec2c07d; context: docs/plan_context/rust-port.md)
	- [x] Qualify both Windows AMD64 original profiles through bounded Wine file acceptance against the Rust oracle, including compiled ABI identity and binary stdout; the complete suite and exact-commit CI pass. (done 2026-11-26 02:04 EST; commit 508d014; context: docs/plan_context/rust-port.md)
	- [x] Qualify both Windows ARM64 original profiles through bounded ARM64 Wine and QEMU user-mode file acceptance against the Rust oracle, with private process cleanup; the complete suite and exact-commit CI pass. (done 2026-11-26 03:04 EST; commit 26da037; context: docs/plan_context/rust-port.md)
	- [ ] Stamp builds with verified rN-abcdef provenance from the built commit and its recorded yolo base, keeping dirty state separate and rejecting unavailable provenance for releases. (context: docs/plan_context/build-provenance.md)
		- [ ] Activate and qualify the reviewed CI provenance handoff after bounded crash/orphan recovery is verified. (context: docs/plan_context/build-provenance.md)
	- [ ] Qualify native macOS and Windows preventive test boundaries before claiming complete native test execution there. (context: docs/plan_context/test-preparation.md)
- [ ] Qualify metadata capture and restore on macOS and Windows using available native hosts or approved emulated execution; distinguish those results from cross-builds. (context: docs/plan_context/metadata-v2.md)
	- [ ] Establish per-job memory/time enforcement for the native macOS runner and verify bounded Windows AMD64/ARM64 routes before remote qualification waves. (context: docs/plan_context/rust-port.md)
	- [ ] Add native macOS ACL and sparse-file fixtures with independent OS readback before qualifying those metadata families.
	- [x] Establish bounded Windows execution through isolated Wine on AMD64 and QEMU/Wine on ARM64 under the existing Linux job limits; required filesystem, CLI and C ABI controls pass in both profiles, with native Windows/NTFS qualification still open. (done 2026-11-26 07:22 EST; commit e4881d5; context: docs/plan_context/rust-port.md)
- [ ] Enforce `--max-rss-bytes` on Darwin after reproducing its limit rejection against current VM usage. (context: docs/plan_context/memory-ceiling.md)

## Deferred

- [ ] Qualify bounded hostile-prefix decoding and complete output/window contracts if a future decision adopts a Rust codec or multi-frame encoding; production remains single-frame statically linked zstdz. (context: docs/plan_context/rust-port.md)
- [ ] Schedule and qualify a narrow Rust 1.100 compiler-provider update after the current port checkpoint, preserving the lockfile, MSRV and platform holds. (context: docs/plan_context/rust-port.md)
