# Difz Implementation Plan

## Active

- [x] Baseline current difz against zstd --patch-from levels 3, 9, and 19 on the official NixOS minimal 26.05.7813 to 26.05.9173 x86_64 ISOs. (done 2026-10-07 9:23pm EDT)
- [x] Branch a per-file zstd --patch-from engine that keeps BLAKE3 checks and DIFZTREE outside and drops CDC plus compression selection. (done 2026-10-08 12:31am EDT)
- [x] Remeasure the branch on the same ISO pair. Keep the CDC engine reachable from the pre-change commit if the branch wins. (done 2026-10-08 12:36am EDT)
- [x] Repin random to a758c902143f8f1dc08c3f33964b8fde7e4a2218 so the dev-shell CLI streams past 1 GiB. (done 2026-10-07 4:59pm EDT)
- [x] Measure a 1024 MiB uniform full-replace: zstd level 3 did not shrink it and -T0 did not beat -T1. (done 2026-10-07 4:59pm EDT)
- [x] Remeasure the shared-prefix rows and the Neovim AppImage pair with the `./bm` method. The August Validate ELFs were not available and were not rebuilt. (done 2026-10-07 9:40am EDT)
- [x] Split create time between the matcher and the `--compress best` probe. On a pinned seed, `best` matched LZMA2 or uncompressed, and the probe was the extra cost. (done 2026-10-07 10:08am EDT)
- [x] Peter opened `/Users/Shared/difz-gk/Beamer.app` as testuser. The only prompt was a network Allow. Afterward the tree still had no xattrs, and codesign plus spctl still passed. (done 2026-10-06 1:47pm EDT) (context: docs/plan_context/mac-archive-oracle.md)
- [ ] DIFZTREE v2 still owes ACLs, Finder flags, sparse extents, hardlink identity, birth-time sidecars, and `--omit-metadata`. (context: docs/plan_context/metadata-v2.md)
- [x] DIFZTREE v2 carries logical and raw extended attributes, including attributes on the snapshot root, and restores them through xattr_stream. (done 2026-10-04 10:40am EDT) (context: docs/plan_context/metadata-v2.md)
- [x] Developer ID signing stays attended. Peter chose that on 2026-10-06: coordinate signing when he is at the Mac, and do not unlock the login keychain from SSH. (done 2026-10-06 10:28am EDT) (context: docs/plan_context/mac-archive-oracle.md)
- [ ] Make `--max-rss-bytes` enforceable on Darwin. `setrlimit(RLIMIT_AS)` returns EINVAL, so difz exits before create. The PDFPals run stayed under 8 GiB when observed with `/usr/bin/time -l`. (context: docs/plan_context/mac-archive-oracle.md)

## Recently completed (2026-09-29)

