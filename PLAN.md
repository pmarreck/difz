# Difz Implementation Plan

## Active

- [ ] Log in as testuser on m4max and open a Beamer.app restored by a DIFZTREE that copies `com.apple.quarantine`. The tree at `/Users/Shared/difz-gk/Beamer.app` is the 2026-10-04 apply from before xattr capture. (context: docs/macos-bundle-profile.md)
- [ ] DIFZTREE v2 still owes ACLs, Finder flags, sparse extents, hardlink identity, birth-time sidecars, and `--omit-metadata`. (context: docs/plan_context/metadata-v2.md)
- [x] DIFZTREE v2 carries logical and raw extended attributes, including attributes on the snapshot root, and restores them through xattr_stream. (done 2026-10-04 10:40am EDT) (context: docs/plan_context/metadata-v2.md)
- [x] Apply a DIFZTREE of live Beamer.app on m4max. codesign --verify --deep --strict, xcrun stapler validate, and spctl --assess passed; quarantine, provenance, and macl were not copied. (done 2026-10-04 10:09am EDT) (context: docs/plan_context/mac-archive-oracle.md)
- [ ] Allow Developer ID signing from SSH on m4max. The login keychain returns errSecInternalComponent. (context: docs/plan_context/mac-archive-oracle.md)
- [x] Xcode license is accepted on m4max. xcrun stapler validate passed on installed Beamer and balenaEtcher, on a restored Beamer zip, and on original and restored PDF Pals.app. (done 2026-10-01 4:29pm EDT) (context: docs/plan_context/mac-archive-oracle.md)
- [ ] Make `--max-rss-bytes` enforceable on Darwin. `setrlimit(RLIMIT_AS)` returns EINVAL, so difz exits before create. The PDFPals run stayed under 8 GiB when observed with `/usr/bin/time -l`. (context: docs/plan_context/mac-archive-oracle.md)
- [x] Measure PDFPals 1.8.1 to 1.9.0 on m4max: publisher dmgs patched at 99.70% (ULFO versus UDZO); ditto zips of PDF Pals.app patched at 16.10% and codesign --verify --deep --strict passed with the ticket still stapled. (done 2026-10-01 4:02pm EDT) (context: docs/plan_context/mac-archive-oracle.md)
- [x] Qualify archive-first Mac deltas on m4max: Nix difz 0.1.0 restored a ditto zip of stapled Beamer.app and codesign --verify --deep --strict passed with the ticket still stapled. (done 2026-10-01 3:55pm EDT) (context: docs/plan_context/mac-archive-oracle.md)

## Recently completed (2026-09-29)

- [x] Fuzzing suite: fuzz the encoder/decoder for robustness. `./fuzz` mutates a valid ZDIF patch and asserts apply never aborts. (2026-09-29 ~3:45pm EDT)
- [x] Cross-platform CI: test on Linux x86_64/aarch64 and Windows. `./test` builds windows-gnu; flake evaluates aarch64-linux packages.default; GitHub CI runs `./test` on yolo. (2026-09-29 ~3:45pm EDT)
- [x] **Directory tree diffing** — DIFZTREE v1 is in tree (`docs/directory-format-v1.md`, `difz_directory_diff` / `difz_directory_patch`). (done 2026-08-27; checked 2026-09-29 ~3:45pm EDT)
- [x] **Streaming/mmap patcher for large files** — POSIX CLI mmap-loads regular files and passes borrowed buffers into the FFI. The Zig core still requires the full source/target in memory; GB assets fail closed via RSS/output ceilings rather than OOM-on-hope. A callback/seek FFI remains a later core extension. (2026-09-29 ~3:45pm EDT)
- [x] **Game update patching (Steam-style use case)** — first public packaged-binary pair is Neovim AppImages (48.58% patch, round-trip OK). KeePassXC consecutive AppImages hit the 70% fallback. `.pak`/`.vpk` pairs still want a streaming core. (2026-09-29 ~3:45pm EDT)
