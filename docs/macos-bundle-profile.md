# macOS bundle profile (difz v1)

macOS `difz` deltas stay **disabled**. Exact bytes in the main executable
are not a Gatekeeper gate. This file is the supported profile, not a promise
that delivery is on.

Canonical sources: `EXECUTION_CONTEXT_TRUST.md`, Sparkle BinaryDelta,
`docs/directory-format-v1.md`.

## v1 representation

Preferred: reconstruct the **canonical post-stapling archive** (exact
SHA-256 of the retained cut artifact), then extract through the tested Mac
packaging path and run native verification. This requires the old archive
bytes, not the live installed tree.

Future: a versioned **app tree** patch of the installed bundle. Not v1.

`DIFZTREE` v1 is not a Mac updater input. It omits owner/group, timestamps,
ACLs, xattrs, Finder flags, sparse extents, and hardlink identity.

## Supported vs rejected

Supported (Sparkle-like): regular files, directories, contained relative
symlinks, portable mode bits, code-signature xattrs that belong to the
already-signed target.

Rejected: ACL-bearing inputs, arbitrary third-party xattrs, resource forks,
hardlink identity, sparse holes, Finder flags, rewriting quarantine to
manufacture a pass.

A delta may reconstruct an already-signed target, including its signature.
The client never re-signs. Apple requires **new-file replacement**, not
in-place overwrite (kernel signature cache).

## Acceptance (native oracles)

`codesign --verify --deep --strict`, `xcrun stapler validate`, quarantine
present as provenance, clean-machine launch. Hash equality is identity, not
installation policy.
