# PLAN

Completed work is retained in docs/PLAN_LOG.md; measurement details live in docs/plan_context/.

## Active


- [ ] Deliver a Rust implementation of difz, using the existing tests and executable as independent oracles. (context: docs/plan_context/rust-port.md)
	- [ ] Qualify bounded hostile-prefix decoding and complete output/window resource contracts before adopting a Rust codec or multi-frame encoding.
	- [ ] Establish product-wide differential acceptance tests before replacing any production entry point; qualify codec output limits and performance separately.
	- [ ] Qualify static zstdz linking and Rust buffer/context ownership on all supported targets before publishing the Rust library; the selected codec adapter has no global progress callbacks.
	- [ ] Port the file codec, directory metadata and format, filesystem adapters, C API, and CLI while preserving the declared behavior and platform scope.
		- [ ] Reduce the new growth gate's feedback cost while preserving native-oracle validation, measurement quality and complete declaration/size coverage. (context: docs/plan_context/rust-port.md)
		- [ ] Enforce declared growth for the Rust metadata and directory codecs before production adoption. (context: docs/plan_context/rust-port.md)
			- [ ] Qualify shared ownership and memory use for hardlinks referring to Rust-owned delta output before production adoption. (context: docs/plan_context/rust-port.md)
		- [x] Port allocation-free native attribute-name mapping for every OS/class, using the untouched pinned xattr_stream source as oracle; byte/length/buffer/inverse controls reject a broken mapper, and the combined complete suite passes. (done 2026-11-06 18:52 EST; context: docs/plan_context/rust-port.md)
		- [x] Add Linux descriptor-based raw attribute replacement/removal with independent binary/empty/absence/error/path-replacement readback and all five native fixtures required; the combined complete suite passes. (done 2026-11-06 18:52 EST; context: docs/plan_context/rust-port.md)
		- [x] Add native modification/creation time and opened-root/file inspection with independent negative-time/readback fixtures, strict Linux response masks and path-replacement controls; the complete Linux suite passes. (done 2026-11-06 18:36 EST; context: docs/plan_context/rust-port.md)
		- [x] Add bounded Linux descriptor-based attribute reads and a required Nix-prepared host platform suite; binary/name/limit/rename fixtures, 1023 invalid artifact sets and the complete suite pass without skipping native coverage. (done 2026-11-06 18:08 EST; context: docs/plan_context/rust-port.md)
		- [x] Add parent-relative entry inspection and bounded raw symlink reads with independent kernel metadata, byte ceilings and rename-replacement controls; the complete suite covers the combined inspection/enumeration tree. (done 2026-11-06 17:54 EST; commit 4565b9f; context: docs/plan_context/rust-port.md)
		- [x] Add owned directory-name streams with independent offsets, raw bytes, bounded allocation, errno/EOF handling and descriptor readback; all required checks pass without claiming native macOS or Windows qualification. (done 2026-11-06 17:54 EST; context: docs/plan_context/rust-port.md)
		- [x] Add Linux/macOS directory capabilities and bounded binary reads, with real rename/symlink/FIFO cases, injected IO and Linux kernel descriptor readback; the complete suite passes, while Windows and native macOS qualification remain pending. (done 2026-11-06 17:29 EST; context: docs/plan_context/rust-port.md)
		- [x] Port bounded parent symlink transport with exact native encodings, all presence/absence/override combinations and byte/count boundary controls; full host validation covers the combined transport/ACL tree. (done 2026-11-06 17:19 EST; commit 4dc3993; context: docs/plan_context/rust-port.md)
		- [x] Port bidirectional Linux ACL wire conversion and access/default containers with native permission/ID/name grammar controls; the combined complete suite passes without claiming filesystem restore qualification. (done 2026-11-06 17:20 EST; context: docs/plan_context/rust-port.md)
- [ ] Conform the build to the cross-platform-project-build-arch skill, including canonical implementation selection where applicable, PF/VARIANT/profile outputs, safe host publication, the five-platform matrix, and Nix/native agreement.
	- [x] Disable GitHub Actions CI without deleting its workflow, verify the remote disabled state and retain the canonical Mechatron badge and complete test command. (done 2026-11-06 17:29 EST; commit c89c159)
	- [ ] Qualify native macOS and Windows preventive test boundaries before claiming complete native test execution there. (context: docs/plan_context/test-preparation.md)
- [ ] Qualify metadata capture and restore on native macOS and Windows hosts; cross-builds establish compilation only. (context: docs/plan_context/metadata-v2.md)
	- [ ] Resolve native-runner resource policy before scheduling additional remote build waves.
	- [ ] Add native macOS ACL and sparse-file fixtures with independent OS readback before qualifying those metadata families.
	- [ ] Locate an available Windows runner before claiming native Windows metadata qualification.
- [ ] Enforce `--max-rss-bytes` on Darwin after reproducing its limit rejection against current VM usage. (context: docs/plan_context/memory-ceiling.md)
