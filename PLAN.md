# Difz Implementation Plan

## Active

- [x] Repin random to a758c902143f8f1dc08c3f33964b8fde7e4a2218 so the dev-shell CLI streams past 1 GiB. (done 2026-10-07 4:59pm EDT)
- [x] Measure a 1024 MiB uniform full-replace: zstd level 3 did not shrink it and -T0 did not beat -T1. (done 2026-10-07 4:59pm EDT)
- [x] Remeasure the shared-prefix rows and the Neovim AppImage pair with the `./bm` method. The August Validate ELFs were not available and were not rebuilt. (done 2026-10-07 9:40am EDT)
- [x] Split create time between the matcher and the `--compress best` probe. On a pinned seed, `best` matched LZMA2 or uncompressed, and the probe was the extra cost. (done 2026-10-07 10:08am EDT)
- [x] Peter opened `/Users/Shared/difz-gk/Beamer.app` as testuser. The only prompt was a network Allow. Afterward the tree still had no xattrs, and codesign plus spctl still passed. (done 2026-10-06 1:47pm EDT) (context: docs/plan_context/mac-archive-oracle.md)
- [ ] DIFZTREE v2 still owes ACLs, Finder flags, sparse extents, hardlink identity, birth-time sidecars, and `--omit-metadata`. (context: docs/plan_context/metadata-v2.md)
- [x] DIFZTREE v2 carries logical and raw extended attributes, including attributes on the snapshot root, and restores them through xattr_stream. (done 2026-10-04 10:40am EDT) (context: docs/plan_context/metadata-v2.md)
- [x] Apply a DIFZTREE of live Beamer.app on m4max. codesign --verify --deep --strict, xcrun stapler validate, and spctl --assess passed; quarantine, provenance, and macl were not copied. (done 2026-10-04 10:09am EDT) (context: docs/plan_context/mac-archive-oracle.md)
- [x] Developer ID signing stays attended. Peter chose that on 2026-10-06: coordinate signing when he is at the Mac, and do not unlock the login keychain from SSH. (done 2026-10-06 10:28am EDT) (context: docs/plan_context/mac-archive-oracle.md)
- [ ] Make `--max-rss-bytes` enforceable on Darwin. `setrlimit(RLIMIT_AS)` returns EINVAL, so difz exits before create. The PDFPals run stayed under 8 GiB when observed with `/usr/bin/time -l`. (context: docs/plan_context/mac-archive-oracle.md)
- [x] Measure PDFPals 1.8.1 to 1.9.0 on m4max: publisher dmgs patched at 99.70% (ULFO versus UDZO); ditto zips of PDF Pals.app patched at 16.10% and codesign --verify --deep --strict passed with the ticket still stapled. (done 2026-10-01 4:02pm EDT) (context: docs/plan_context/mac-archive-oracle.md)
- [x] Qualify archive-first Mac deltas on m4max: Nix difz 0.1.0 restored a ditto zip of stapled Beamer.app and codesign --verify --deep --strict passed with the ticket still stapled. (done 2026-10-01 3:55pm EDT) (context: docs/plan_context/mac-archive-oracle.md)

## Recently completed (2026-09-29)

