# Mac archive oracle

Peter, 2026-10-01: m4max (`m4max.tail66c90.ts.net`) is the Mac runner. Passwordless SSH works, and Nix builds `aarch64-darwin` there. The earlier "no Mac runner" premise was wrong.

v1 stays the post-stapling archive, not a live `.app` tree. difz reconstructs the archive bytes. `ditto` extracts them. Native checks then run on the extracted bundle. The client does not re-sign.

`scripts/mac-archive-oracle` builds two ad-hoc Hello.app trees with the Mac's Nix Zig, packs each with `ditto -c -k --keepParent`, patches with `DIFZ`, and requires `codesign --verify --deep --strict` on the extracted 1.1 app. It then does the same for `DIFZ_SIGNED_APP` (default `/Applications/Beamer.app`) and requires the notarization ticket line to be unchanged. The default fixture is the Beamer.app installed on m4max, so another machine must set `DIFZ_SIGNED_APP`.

## Result, 2026-10-01, Nix difz

Binary: `/nix/store/hgfx6r2plq0hcxg5v59bk2cghs9va6x4-difz-0.1.0/bin/difz`
`difz 0.1.0 -- fast binary differ (CDC + Elder/Myers O(ND)) -- macOS aarch64`

- Ad-hoc Hello 1.0 zip 3,923 bytes, 1.1 zip 3,918 bytes, patch 2,922 bytes. Extracted 1.1 passed `codesign --verify --deep --strict`.
- Beamer.app zip 16,909,042 bytes. Patch from the unrelated Hello zip was 16,587,987 bytes (98% of the target). Extracted Beamer passed `codesign --verify --deep --strict`. Ticket before and after: `stapled`.
- `xcrun stapler validate` exits because the Xcode license is not accepted. `sudo` from SSH asks for a password.
- `codesign --sign "Developer ID Application: Peter Marreck (4TQUA2F676)"` returns `errSecInternalComponent`. The login keychain will not prompt over this SSH session. Ad-hoc signing works.
- Quarantine was not written. A clean-machine launch was not run.
- `/usr/bin/clang` is blocked by the same Xcode license. Zig 0.16 from Nix produced the Hello Mach-O.

DIFZTREE v2 metadata remains separate. It does not make a reconstructed `.app` a Gatekeeper pass.

## Version pair, 2026-10-01 4:02pm EDT

`scripts/mac-archive-pair` on the same Nix binary, reading the two disk images already in Downloads on m4max. Mounts used `$HOME/tmp`. A mountpoint under `/tmp` returned `hdiutil: attach failed - Permission denied` after the image checksum verified. `--max-rss-bytes` was not passed: an earlier attempt exited immediately with `difz: cannot apply RSS ceiling (Invalid argument)` because `setrlimit(RLIMIT_AS)` returns `EINVAL` on this macOS. RSS below is `/usr/bin/time -l`.

| Artifact | Source bytes | Target bytes | Patch bytes | Ratio | Create | Apply |
|---|---:|---:|---:|---:|---|---|
| Publisher dmg | 75,367,610 | 74,948,513 | 74,726,196 | 99.70% | 1.33 s, 4,691 MiB | 0.39 s, 288 MiB |
| ditto zip of the .app | 75,162,176 | 75,276,424 | 12,121,498 | 16.10% | 0.61 s, 1,295 MiB | 0.21 s, 169 MiB |

SHA-256 of the disk images: 1.8.1 `3eadbcc357f6a220523a4f3d9d12b836b67b0b1056dbb55388805d7a92e5d8ee`, 1.9.0 `fe9bbb8521f21e4d1ae161b58aa7707d1b9001bbbf2ed0c890f84a00d905a91c`. `hdiutil imageinfo` reports 1.8.1 as `ULFO` (lzfse, Apple_APFS) and 1.9.0 as `UDZO` (zlib, Apple_HFS).

Both restored archives matched the target byte-for-byte. `PDF Pals.app` from the original 1.9.0 image, from the restored disk image, and from the restored zip passed `codesign --verify --deep --strict`. Ticket before and after: `stapled`. The 70% cap accepts the ditto zip and rejects the publisher-dmg pair. Wall and observed RSS stayed inside 120 s / 8 GiB for create and 10 s / 1 GiB for apply. Quarantine was not written. A clean-machine launch was not run. The client did not re-sign.