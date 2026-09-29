# Mecha delta contract (difz-owned slice)

Canonical sources: `MECHA_RELEASE_PLAN.md` (Sep23 amendment),
`validate_gui/docs/MECHA_VALIDATE_RELEASE_RUNBOOK.md`,
`EXECUTION_CONTEXT_TRUST.md` (2026-09-23), Sigil `fa49dfb`.

## Recorded answers (Einstein 2026-09-23)

- SHA-256 is the outer signed object digest. BLAKE3 is the inner ZDIF/DIFZTREE
  source/target check. The signed descriptor records both. Filenames are not trust.
- Format names are `ZDIF` v3 and `DIFZTREE` v1, independent of the URL prefix
  `deltas/difz-v1/`.
- Updater-pilot measurement is a real Linux x86_64 AppImage pair. Keep the
  historic 89 MB Validate ELF row as engine provenance only.
- A delta may reconstruct an already-signed target, including its signature.
  The client never re-signs. Apple requires new-file replacement, not in-place
  overwrite (kernel signature cache).
- Sparkle does not preserve arbitrary xattrs/ACLs. Define a supported bundle
  profile and reject unsupported states. Do not treat complete filesystem-backup
  fidelity as Apple's requirement.
- Sigil v1 is file targets only. macOS directory targets are unsupported.
  Canonical post-stapling archive is the proposed v1 Mac representation; Mac
  deltas stay disabled until that path is measured and qualified.
- Same-representation only: package-to-package or installed-file-to-installed-file.
  Windows installed EXE identity is `installed_sha256`, not the ZIP SHA-256.
- Cold-key regeneration: serve bytes that match the already-signed patch digest
  exactly; otherwise immediate full-artifact fallback. No new hot key.
- Resource ceilings need fresh actual-artifact measurements. Do not treat the
  89 MB ELF numbers as bounds. Record proposed caps before running those
  measurements.

## Measured caps (2026-09-29, Threadripper 3990X, ReleaseFast)

Worker `difz create` (CLI process wrapper, no signing keys):

- RSS hard abort 8 GiB (`--max-rss-bytes`)
- wall 120 s (`--max-wall-ms 120000`)
- output size at most 70% of target bytes (`--max-output-ratio 70`)
- `--max-output-bytes` for an absolute cap
- no caller-supplied URLs in the library; the worker must pass retained artifacts

Client `difz apply`:

- RSS hard abort 1 GiB
- wall 10 s

Public samples (not committed):

| Pair | Create wall | Create RSS | Apply wall | Apply RSS | Patch vs target |
|---|---:|---:|---:|---:|---:|
| Neovim 0.11.3 → 0.11.4 AppImage | 1.019 s | 404 MiB | 0.080 s | 30 MiB | 48.58% (allowed) |
| KeePassXC 2.7.9 → 2.7.10 AppImage | 5.9 s | 4.27 GiB | n/a | n/a | 97.86% (rejected by 70% gate) |
| Validate ELF 89 MB (historic) | 11.027 s | 3.34 GiB | 0.715 s | 214 MiB | 5.06% |

SHA-256: nvim source `5f377dc48c49a4170bd698a80ef461a702b8ebb8b2f7ddbb776341503d36415f`, target `79e7e160f9505819a5e12f3d9366be94213f5309fb912ef4ef3af52df3982977`. KeePassXC source `2a868b681a8ec4e381ac14203aec3d80ff6fa7a535fa102265a3ec9329b4b846`, target `3f8308a4d905d067367d541b4dccd5e80700798039046ffc388ede4f50887b36`.

## Push

Peter authorized push 2026-09-29. Unrelated dirty files still must not mix.
