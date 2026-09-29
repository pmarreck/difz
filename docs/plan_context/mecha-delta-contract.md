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

## Proposed caps (unmeasured; to verify on AppImage, then tighten)

Worker `difz create` (keyless process wrapper, single-flight):

- RSS hard abort 8 GiB
- wall 120 s
- CPU 180 s
- output size at most 70% of target bytes (runbook start gate)
- no caller-supplied binaries or URLs; sources come from retained full artifacts

Client `difz apply` (same host until a slow-client number exists):

- RSS hard abort 1 GiB
- wall 10 s
- temp space at least 2× reconstructed target plus patch

These are hypotheses to fail a gate, not published performance claims.
The 89 MB ELF pair created at 3.34 GiB RSS / 11.0 s wall and applied at
214 MiB RSS / 0.715 s; that row is not a ceiling.

## Hold

Peter withheld external push on this branch. Working tree still has unrelated
dirty files (`ZIG_0.15_TO_0.16_MIGRATION.md` deletion, untracked
`MECHATRON_PRIME_CI.md`). Fetch 2026-09-28 confirmed `origin/yolo` unchanged;
local `yolo` is 7 commits ahead. No force-push.
