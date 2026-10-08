# PLAN

Completed work is retained in docs/PLAN_LOG.md; measurement details live in docs/plan_context/.

## Active

- [x] Complete the remaining DIFZTREE v2 metadata work after adopting zstdz; the project remains in break mode, with no v1 compatibility path. (done 2026-10-08 16:02 EDT; context: docs/plan_context/metadata-v2.md)
	- [x] Capture and restore ACLs, birth time, Finder fields, sparse extents, hardlink identity, and snapshot-root metadata with verified fallbacks. (done 2026-10-08 16:02 EDT)
		- [x] Preserve hardlink groups as verified copies when native linking is unavailable, including filtered canonical paths and compromise reporting. (done 2026-10-08 15:58 EDT)
		- [x] Capture native sparse extents, restore physical holes, and preserve layouts the destination cannot represent with verified transport. (done 2026-10-08 15:47 EDT)
		- [x] Capture native Mac Finder information and BSD flags; restore staging-safe flags and preserve unsupported fields on objects, symlinks, and root. (done 2026-10-08 15:38 EDT)
		- [x] Capture Linux access/default ACLs and native Mac/Windows ACLs; verify restore and preserve foreign or unsupported forms, including root and symlink absence. (done 2026-10-08 15:32 EDT)
		- [x] Capture root timestamps and native birth time; preserve unsupported values and timestamp absence through verified transport. (done 2026-10-08 15:19 EDT)
	- [x] Reject sparse extents and hardlink references on directory-root metadata before filesystem staging. (done 2026-10-08 16:02 EDT)
	- [x] Verify builds for all five supported OS/architecture combinations after the metadata changes. (done 2026-10-08 16:02 EDT)
- [ ] Qualify metadata capture and restore on native macOS and Windows hosts; cross-builds establish compilation only. (context: docs/plan_context/metadata-v2.md)
- [ ] Make `--max-rss-bytes` enforceable on Darwin. `setrlimit(RLIMIT_AS)` returns EINVAL, so difz exits before create. The PDFPals run stayed under 8 GiB when observed with `/usr/bin/time -l`. (context: docs/plan_context/mac-archive-oracle.md)

## Recently completed (2026-09-29)
