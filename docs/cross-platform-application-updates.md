# Cross-platform application updates with difz

Recorded 2026-10-27 from the 2026-10-26 design discussion. This is an updater
integration guide and qualification checklist, not a claim that an end-to-end
Mecha updater is already qualified. No implementation or packaging migration is
authorized by this document alone.

## Conclusion and division of responsibility

Difz can reconstruct release artifacts for Windows, macOS, and Linux. Rebuilding
the exact publisher-signed release from a delta is compatible with code signing.
The publisher signs the final release; the client never re-signs it.

Difz supplies source/target identity checks and reconstruction. The consuming
updater owns release authentication, download policy, installation permissions,
replacement, restart, rollback, and application-data migrations. Successful
patch application alone does not establish safe installation or OS trust.

Read alongside:

- [Mecha delta contract](plan_context/mecha-delta-contract.md): signed descriptor,
  representation identities, key policy and historical resource caps.
- [Mac archive experiments](plan_context/mac-archive-oracle.md): measured signing,
  notarization, packaging and launch evidence.
- [Directory format](directory-format.md) and [metadata scope](plan_context/metadata-v2.md).
- [Engine comparison](plan_context/engine-comparison.md) and
  [Rust port](plan_context/rust-port.md): engine changes and qualification status.

## Release production and authentication

1. Build each OS/architecture/ABI target and finish platform signing, timestamping,
   notarization and stapling as applicable. Freeze the resulting artifacts.
2. Generate deltas between those immutable, final artifacts. Signing or repacking
   afterward changes the target identity. Retain the exact release bytes used.
3. Sign an update manifest binding product, channel, platform, release sequence,
   minimum updater version, source identity, patch identity, target identity,
   lengths and relevant expiration policy. Filenames and HTTPS are insufficient
   authenticity controls.
4. Keep update-signing keys separate from customer-license signing keys. The
   existing contract uses SHA-256 for outer signed objects and BLAKE3 for difz's
   internal source/target checks. Preserve both roles explicitly.
5. Reject unauthorized downgrades and inconsistent metadata. A legitimate local
   recovery to the preserved prior release needs an explicit rollback policy;
   it must not become permission to accept arbitrary old network releases.

A patch can contain internally consistent hashes and still be malicious.
Authenticate its signed descriptor and downloaded digest before handing it to
the parser; retain parser/output/window resource limits regardless.

Compare like representations. An installed EXE is not its download ZIP. An
installed app is not its original archive. If patching archives, retain the exact
base archive in a managed cache or fall back to a full artifact. Repacking an
installed app does not reliably recreate the original archive bytes: timestamps,
metadata, file order and compressor versions can change them.

## OS-specific behavior

### Windows (`mswin`)

Reconstruct the exact final signed EXE and DLL bytes, including their signature
data. Authenticode hashes exclude selected PE fields, so the updater's whole-file
digest remains a useful independent identity check. Verify Authenticode with
`WinVerifyTrust` and enforce the expected publisher policy, including deliberate
certificate rotation; accepting any trusted signer is too broad.

Valid Authenticode does not guarantee SmartScreen reputation, antivirus approval,
Smart App Control acceptance or compliance with an enterprise allowlist. Timestamp,
certificate-chain and revocation policy also matter. Qualify the downloaded-release
path without depending on removal of Mark-of-the-Web or weakened OS controls.

Use an external helper that survives application exit and waits for the exact
process. Loaded EXEs/DLLs and antivirus handles can prevent replacement. Bound
retries and retain the old installation on failure. A per-user installation is
simpler; Program Files or machine-wide changes may require elevation. If the
application is packaged as MSIX, use its deployment machinery rather than
modifying package-owned files behind its back.

Sources: [PE signatures](https://learn.microsoft.com/en-us/windows/win32/secbp/understanding-pe-signatures),
[WinVerifyTrust](https://learn.microsoft.com/en-us/windows/win32/api/wintrust/nf-wintrust-winverifytrust),
[file sharing](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-createfilew),
[SmartScreen reputation](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/smartscreen-reputation).

### macOS (`macos`)

Reconstruct the signed/notarized bundle, including sealed resources, embedded
code and required metadata. The acceptance claim is about the authentic complete
release, not merely a binary whose hash was previously seen by Apple. A detached
signature or server-side hash record alone does not replace the bundle's signing
requirements.

Stage a new `.app`, validate it, exit and replace through a helper. Do not modify
the running executable or live bundle in place. Preserve required modes, symlinks
and notarization evidence. Installation permissions and quarantine behavior remain
separate from byte reconstruction. Do not copy arbitrary machine-specific metadata
blindly; define and qualify the supported bundle profile.

The recorded experiments passed `codesign --verify --deep --strict`,
`xcrun stapler validate` and `spctl --assess`; a restored Beamer copy also launched
from a clean account. That copy had no quarantine attribute. These results establish
useful signature/notarization compatibility, but not a download-style first-open
test. Repeat with actual signed Mecha releases and normal download provenance.

Canonical post-stapling archives remain the proposed initial Mecha representation;
the successful directory experiment does not by itself supersede that contract.
See [the experimental record](plan_context/mac-archive-oracle.md) and
[Sparkle's delta documentation](https://sparkle-project.github.io/documentation/delta-updates/).

### Linux (`linux`)

Ordinary desktop ELF execution generally has no mandatory Authenticode-equivalent
publisher check. The updater must enforce the signed manifest itself. Enterprise
IMA/appraisal, SELinux, mount options and other local controls can add constraints.

For writable standalone installations, reconstruct a sibling artifact on the same
filesystem, preserve executable permissions, verify, and replace after exit. A
same-filesystem rename can atomically replace a file; it does not make a series of
directory renames transactional. Crash durability also requires appropriate file
and directory synchronization. Keep a recovery journal or equivalent transaction
state for multi-step replacement.

Respect installation ownership. Nix store outputs are immutable; Nix manages their
updates. Flatpak and distro packages likewise use their package managers. Offer
self-update for supported standalone locations, not silent writes into `/nix/store`
or package-manager-owned system paths. Check ABI, loader and shared-library
requirements as well as OS and architecture.

Sources: [rename semantics](https://man7.org/linux/man-pages/man2/rename.2.html),
[NixOS store model](https://wiki.nixos.org/wiki/Overview_of_the_NixOS_Linux_distribution).

## Shared installation transaction

Authenticate manifest → select exact source/platform → download and authenticate
patch → reconstruct new artifact → verify complete target and native signatures →
exit → recoverably replace → restart → confirm health → retire rollback copy.

- Never overwrite the source or running installation while applying a patch.
- Keep mutable settings, licenses and databases outside the patched release tree.
- Lock the update transaction and account for multiple application instances.
- Secure staging against symlink/path substitution, especially across elevation.
- Retain the previous working release until startup and required backend handshakes
  succeed. Do not run irreversible user-data migrations before recovery is safe.
- Restoring an executable alone cannot roll back an incompatible database migration.
  Define migration compatibility, backup and recovery together with binary rollback.
- Bound download, reconstruction, memory and temporary-space consumption. A small
  patch can still require full source, target and rollback storage.
- Make interruption recovery idempotent; neither retries nor restart should repeat
  already-completed migrations or leave mixed-version files active.

## Fallback, caching and efficiency

Always publish an authenticated full release. Use it when the base is absent or
modified, the patch format is unsupported, resource bounds would be exceeded,
or the patch is not economical. A failed authenticity check must never weaken
verification of the fallback.

Keep recent full releases as regeneration anchors; cache direct source-to-target
patches under immutable content identities. Avoid requiring long chains of
intermediate deltas for ordinary updates. Cache regeneration must reproduce the
already-signed patch digest or follow the existing signing policy; otherwise serve
the full release. Cache expiry is not permission to invent a new signing key.

"Vastly more efficient" needs workload evidence. Existing systems already support
deltas: [MSIX](https://learn.microsoft.com/en-us/windows/msix/app-package-updates),
[Sparkle](https://sparkle-project.github.io/documentation/delta-updates/) and
[Flatpak](https://docs.flatpak.org/en/latest/repositories.html). Compare download
bytes, CPU, memory, storage and time-to-ready, not download size alone.

Packaging can dominate results. The October 1 PDF Pals 1.8.1 → 1.9.0 experiment
produced a patch 99.70% of the target publisher DMG, versus approximately 16% for
ditto ZIPs of the app. The DMGs used different container/compression formats.
Those are historical CDC-engine measurements, not current-engine predictions.
Keep packing methods stable and benchmark actual signed release pairs.

## Current capability limits and qualification work

As documented on October 26, the production file path uses ZDIF v4 with a zstd
prefix frame and source/target BLAKE3 checks; directory patches use DIFZTREE v2.
The file engine rejects either input above 2 GiB. Whole-file core memory needs,
Darwin resource-limit behavior and native metadata fidelity remain relevant.
The Rust implementation is under active evaluation; do not assume its candidates
have replaced production or inherit qualification from the Zig/C implementation.
Recheck README, PLAN and the selected revision before integration.

The next integration qualification should use two genuine release builds for each
supported platform and installation type. Record source/target/patch hashes,
engine and updater revisions, signature identities, packaging, patch ratio, create
and apply time, peak memory, temporary space and restart outcome. Exercise:

- Correct update and replay of the completed transaction.
- Same-sized wrong base, damaged patch, wrong platform and unauthorized rollback.
- Interrupted download and forced termination at each installation boundary.
- Disk exhaustion, read-only destination and locked/in-use files.
- Multiple instances and concurrent update attempts.
- New-version startup failure and recovery of the prior app plus compatible data.
- Native signature checks and launches under normal OS download protections.
- Full-release fallback and recovery when the old archive cache is missing.

Use disposable installations and injected failure points; never test replacement
against a live customer or developer installation. Passing cross-compilation or
byte-reconstruction tests alone does not qualify native installation behavior.
