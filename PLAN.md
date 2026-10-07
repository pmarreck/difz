# Difz Implementation Plan

## Active

- [x] Remeasure the shared-prefix rows and the Neovim AppImage pair with the `./bm` method. The August Validate ELFs were not available and were not rebuilt. (done 2026-10-07 9:40am EDT)
- [x] Split create time between the matcher and the `--compress best` probe. On a pinned seed, `best` matched LZMA2 or uncompressed, and the probe was the extra cost. (done 2026-10-07 10:08am EDT)
- [x] Peter opened `/Users/Shared/difz-gk/Beamer.app` as testuser. The only prompt was a network Allow. Afterward the tree still had no xattrs, and codesign plus spctl still passed. (done 2026-10-06 1:47pm EDT) (context: docs/plan_context/mac-archive-oracle.md)
- [ ] DIFZTREE v2 still owes ACLs, Finder flags, sparse extents, hardlink identity, birth-time sidecars, and `--omit-metadata`. (context: docs/plan_context/metadata-v2.md)
- [x] DIFZTREE v2 carries logical and raw extended attributes, including attributes on the snapshot root, and restores them through xattr_stream. (done 2026-10-04 10:40am EDT) (context: docs/plan_context/metadata-v2.md)
- [x] Apply a DIFZTREE of live Beamer.app on m4max. codesign --verify --deep --strict, xcrun stapler validate, and spctl --assess passed; quarantine, provenance, and macl were not copied. (done 2026-10-04 10:09am EDT) (context: docs/plan_context/mac-archive-oracle.md)
- [x] Developer ID signing stays attended. Peter chose that on 2026-10-06: coordinate signing when he is at the Mac, and do not unlock the login keychain from SSH. (done 2026-10-06 10:28am EDT) (context: docs/plan_context/mac-archive-oracle.md)
- [x] Xcode license is accepted on m4max. xcrun stapler validate passed on installed Beamer and balenaEtcher, on a restored Beamer zip, and on original and restored PDF Pals.app. (done 2026-10-01 4:29pm EDT) (context: docs/plan_context/mac-archive-oracle.md)
- [ ] Make `--max-rss-bytes` enforceable on Darwin. `setrlimit(RLIMIT_AS)` returns EINVAL, so difz exits before create. The PDFPals run stayed under 8 GiB when observed with `/usr/bin/time -l`. (context: docs/plan_context/mac-archive-oracle.md)
- [x] Measure PDFPals 1.8.1 to 1.9.0 on m4max: publisher dmgs patched at 99.70% (ULFO versus UDZO); ditto zips of PDF Pals.app patched at 16.10% and codesign --verify --deep --strict passed with the ticket still stapled. (done 2026-10-01 4:02pm EDT) (context: docs/plan_context/mac-archive-oracle.md)
- [x] Qualify archive-first Mac deltas on m4max: Nix difz 0.1.0 restored a ditto zip of stapled Beamer.app and codesign --verify --deep --strict passed with the ticket still stapled. (done 2026-10-01 3:55pm EDT) (context: docs/plan_context/mac-archive-oracle.md)

## Recently completed (2026-09-29)

- [x] **Directory tree diffing** — DIFZTREE v1 is in tree (`docs/directory-format-v1.md`, `difz_directory_diff` / `difz_directory_patch`). (done 2026-08-27; checked 2026-09-29 ~3:45pm EDT)
- [x] **Streaming/mmap patcher for large files** — POSIX CLI mmap-loads regular files and passes borrowed buffers into the FFI. The Zig core still requires the full source/target in memory; GB assets fail closed via RSS/output ceilings rather than OOM-on-hope. A callback/seek FFI remains a later core extension. (2026-09-29 ~3:45pm EDT)
- [x] **Game update patching (Steam-style use case)** — first public packaged-binary pair is Neovim AppImages (48.58% patch, round-trip OK). KeePassXC consecutive AppImages hit the 70% fallback. `.pak`/`.vpk` pairs still want a streaming core. (2026-09-29 ~3:45pm EDT)
