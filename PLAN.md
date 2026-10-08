# PLAN

Completed work is retained in docs/PLAN_LOG.md; measurement details live in docs/plan_context/.

## Active

- [ ] Complete the remaining DIFZTREE v2 metadata work after adopting zstdz; the project remains in break mode, with no v1 compatibility path. (context: docs/plan_context/metadata-v2.md)
	- [ ] Capture and restore ACLs, birth time, Finder fields, sparse extents, hardlink identity, and snapshot-root metadata with verified fallbacks.
		- [x] Capture native Mac Finder information and BSD flags; restore staging-safe flags and preserve unsupported fields on objects, symlinks, and root. (done 2026-10-08 15:38 EDT)
		- [x] Capture Linux access/default ACLs and native Mac/Windows ACLs; verify restore and preserve foreign or unsupported forms, including root and symlink absence. (done 2026-10-08 15:32 EDT)
		- [x] Capture root timestamps and native birth time; preserve unsupported values and timestamp absence through verified transport. (done 2026-10-08 15:19 EDT)
		- [x] Validate physical metadata relations and encode hardlinks as references to earlier canonical files; preserve identity after filtering. (done 2026-10-08 14:52 EDT)
	- [x] Preserve symlink metadata that cannot be stored natively in a parent-directory transport attribute, with canonical readback and a compromise warning. (done 2026-10-08 14:59 EDT)
	- [ ] Verify builds for all five supported OS/architecture combinations after the metadata changes.
- [ ] Make `--max-rss-bytes` enforceable on Darwin. `setrlimit(RLIMIT_AS)` returns EINVAL, so difz exits before create. The PDFPals run stayed under 8 GiB when observed with `/usr/bin/time -l`. (context: docs/plan_context/mac-archive-oracle.md)

## Recently completed (2026-09-29)
