# PLAN

Completed work is retained in docs/PLAN_LOG.md; measurement details live in docs/plan_context/.

## Active

- [x] Commit the verified comparison on this branch; preserve the CDC branch and do not push. (done 2026-10-08 09:49 EDT)
- [x] Adopt zstdz on yolo and preserve the CDC tip as old-cdc-plus-compression-probe-design; keep both local unless publication is requested. (done 2026-10-08 14:17 EDT)
- [x] Make DIFZTREE v2 the only supported tree format, including metadata-free trees; remove v1 codec and identity branches and reject v1 input. (done 2026-10-08 14:23 EDT)
- [ ] Complete the remaining DIFZTREE v2 metadata work after adopting zstdz; the project remains in break mode, with no v1 compatibility path. (context: docs/plan_context/metadata-v2.md)
	- [ ] Verify metadata-bearing decoder cleanup under truncation, trailing data, and every injected allocation failure.
	- [ ] Persist metadata omission in the patch, apply it before hashing and capture, and expose it through the CLI and C boundary.
	- [ ] Capture and restore ACLs, birth time, Finder fields, sparse extents, hardlink identity, and snapshot-root metadata with verified fallbacks.
	- [ ] Preserve symlink metadata that cannot be stored natively in a parent-directory transport attribute, with canonical readback and a compromise warning.
	- [ ] Include host filesystem metadata checks in ./test and verify builds for all five supported OS/architecture combinations.
- [x] Branch a per-file zstd --patch-from engine that keeps BLAKE3 checks and DIFZTREE outside and drops CDC plus compression selection. (done 2026-10-08 12:31am EDT)
- [x] Remeasure the branch on the same ISO pair. Keep the CDC engine reachable from the pre-change commit if the branch wins. (done 2026-10-08 12:36am EDT)
- [ ] Make `--max-rss-bytes` enforceable on Darwin. `setrlimit(RLIMIT_AS)` returns EINVAL, so difz exits before create. The PDFPals run stayed under 8 GiB when observed with `/usr/bin/time -l`. (context: docs/plan_context/mac-archive-oracle.md)

## Recently completed (2026-09-29)
