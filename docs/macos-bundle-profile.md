# macOS bundle profile (difz v1)

Archive reconstruction was measured on m4max on 2026-10-01. Nix-built
difz 0.1.0 (macOS aarch64) restored a `ditto -c -k --keepParent` zip of
`/Applications/Beamer.app`. `codesign --verify --deep --strict` passed, and
`codesign -dv --verbose=4` still reported `Notarization Ticket=stapled`.
Exact bytes in the main executable are not the whole gate. `xcrun stapler
validate` did not run: the Xcode license is unaccepted and sudo needs a
password. Quarantine and a clean-machine launch were not run. A live `.app`
tree is still not a v1 input.

The same host then compared PDFPals 1.8.1 and 1.9.0, a real version pair.
The publisher disk images are different containers (ULFO/lzfse versus
UDZO/zlib). That patch was 74,726,196 bytes, 99.70% of the 74,948,513-byte
target, so the 70% worker cap would fall back to a full download. Packing
each `PDF Pals.app` with `ditto -c -k --keepParent` produced a 12,121,498-byte
patch, 16.10% of the 75,276,424-byte zip. Create took 0.61 s and 1,295 MiB
RSS. The restored zip and the restored disk image both passed
`codesign --verify --deep --strict`, and `Notarization Ticket=stapled`
survived. `xcrun stapler validate` still did not run.

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
