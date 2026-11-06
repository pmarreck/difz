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
		- [x] Add parent-relative entry inspection and bounded raw symlink reads with independent kernel metadata, byte ceilings and rename-replacement controls; the complete suite covers the combined inspection/enumeration tree. (done 2026-11-06 17:54 EST; commit 4565b9f; context: docs/plan_context/rust-port.md)
		- [x] Add owned directory-name streams with independent offsets, raw bytes, bounded allocation, errno/EOF handling and descriptor readback; all required checks pass without claiming native macOS or Windows qualification. (done 2026-11-06 17:54 EST; context: docs/plan_context/rust-port.md)
		- [x] Add Linux/macOS directory capabilities and bounded binary reads, with real rename/symlink/FIFO cases, injected IO and Linux kernel descriptor readback; the complete suite passes, while Windows and native macOS qualification remain pending. (done 2026-11-06 17:29 EST; context: docs/plan_context/rust-port.md)
		- [x] Port bounded parent symlink transport with exact native encodings, all presence/absence/override combinations and byte/count boundary controls; full host validation covers the combined transport/ACL tree. (done 2026-11-06 17:19 EST; commit 4dc3993; context: docs/plan_context/rust-port.md)
		- [x] Port bidirectional Linux ACL wire conversion and access/default containers with native permission/ID/name grammar controls; the combined complete suite passes without claiming filesystem restore qualification. (done 2026-11-06 17:20 EST; context: docs/plan_context/rust-port.md)
		- [x] Implement an experimental Rust file C boundary with opaque buffer ownership, byte-length inputs and panic/status containment; compiled C/native cross-apply, allocation-capacity/abort controls and the complete suite pass. (done 2026-11-06 16:54 EST; context: docs/plan_context/rust-port.md)
		- [x] Port DIFZTREE application with source/target verification, bounded delta expansion and native cross-apply over all omission masks; ownership, malformed-delta and source/kind/link rejection controls plus the complete suite pass. (done 2026-11-06 16:37 EST; context: docs/plan_context/rust-port.md)
		- [x] Port DIFZTREE v2 encoding with borrowed omission projection, all six operations and exact native bytes for all omission masks; source-root, type-change, allocation-bound controls and the complete suite pass. (done 2026-11-06 16:18 EST; context: docs/plan_context/rust-port.md)
		- [x] Port bounded DIFZTREE v2 body parsing with borrowed fields, canonical metadata and shared hierarchy checks; native malformed-body and configurable-limit comparisons plus the complete suite pass. (done 2026-11-06 16:15 EST; context: docs/plan_context/rust-port.md)
- [ ] Conform the build to the cross-platform-project-build-arch skill, including canonical implementation selection where applicable, PF/VARIANT/profile outputs, safe host publication, the five-platform matrix, and Nix/native agreement.
	- [x] Disable GitHub Actions CI without deleting its workflow, verify the remote disabled state and retain the canonical Mechatron badge and complete test command. (done 2026-11-06 17:29 EST; commit c89c159)
	- [ ] Qualify native macOS and Windows preventive test boundaries before claiming complete native test execution there. (context: docs/plan_context/test-preparation.md)
- [ ] Qualify metadata capture and restore on native macOS and Windows hosts; cross-builds establish compilation only. (context: docs/plan_context/metadata-v2.md)
	- [ ] Resolve native-runner resource policy before scheduling additional remote build waves.
	- [ ] Add native macOS ACL and sparse-file fixtures with independent OS readback before qualifying those metadata families.
	- [ ] Locate an available Windows runner before claiming native Windows metadata qualification.
- [ ] Enforce `--max-rss-bytes` on Darwin after reproducing its limit rejection against current VM usage. (context: docs/plan_context/memory-ceiling.md)
