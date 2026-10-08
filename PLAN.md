# PLAN

Completed work is retained in docs/PLAN_LOG.md; measurement details live in docs/plan_context/.

## Active

- [ ] Complete the remaining DIFZTREE v2 metadata work after adopting zstdz; the project remains in break mode, with no v1 compatibility path. (context: docs/plan_context/metadata-v2.md)
	- [x] Verify metadata-bearing decoder cleanup under truncation, trailing data, and every injected allocation failure; reject impossible collection counts and noncanonical metadata. (done 2026-10-08 14:31 EDT)
	- [x] Persist metadata omission in the patch, apply it before hashing and capture, and expose it through the CLI and C boundary. (done 2026-10-08 14:43 EDT)
	- [ ] Capture and restore ACLs, birth time, Finder fields, sparse extents, hardlink identity, and snapshot-root metadata with verified fallbacks.
		- [x] Validate physical metadata relations and encode hardlinks as references to earlier canonical files; preserve identity after filtering. (done 2026-10-08 14:52 EDT)
	- [x] Preserve symlink metadata that cannot be stored natively in a parent-directory transport attribute, with canonical readback and a compromise warning. (done 2026-10-08 14:59 EDT)
	- [x] Require host filesystem xattr assertions through ./test; report sandbox skips explicitly and fail when required host support is unavailable. (done 2026-10-08 14:31 EDT)
	- [ ] Verify builds for all five supported OS/architecture combinations after the metadata changes.
- [ ] Make `--max-rss-bytes` enforceable on Darwin. `setrlimit(RLIMIT_AS)` returns EINVAL, so difz exits before create. The PDFPals run stayed under 8 GiB when observed with `/usr/bin/time -l`. (context: docs/plan_context/mac-archive-oracle.md)

## Recently completed (2026-09-29)
