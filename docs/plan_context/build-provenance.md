# Build provenance

The build revision is `rN-abcdef`, independent of the product version. The suffix
comes from the built commit. N counts every commit reachable from the selected
base on the recorded primary branch's first-parent history. Dirty state remains
separate. Git history belongs to the Git-aware collector; pure Nix validation
cannot independently reconstruct or authenticate that graph.

## Source-bound consumer checkpoint, 2026-11-25

Difz declares the nonflake `build-provenance` input, containing `record.json`.
Its in-repository default explicitly reports unavailable provenance. The exact
regular `.mechatron-prime/build-provenance` marker opts into the CI handoff
prototype; it does not activate a service or authorize a release.

The pure validator checks schema and field completeness, full commit/base/tip
identities, positive integer count, revision consistency and a separate boolean
dirty flag. It requires the supplied source NAR to equal the actual root NAR.
When Nix provides a root Git revision, that must match too. A caller requesting
clean release provenance rejects both unavailable and dirty records. Mechanical
field/type/omission controls, separate dirty/release controls and SHA-1/SHA-256
identity cases execute with the required build-wrapper Nix evaluation.

Every packages/checks/devShells output validates the handoff before its value is
evaluated. Output names remain available first, avoiding recursion through Nix's
later-attached `self.narHash` metadata. The initial candidate validated only the
metadata output; an actual-production-target negative test caught that a bad
record could otherwise be ignored. The same test fails before this correction
and passes afterward.

The complete entry point also tests the actual immutable flake snapshot. An
external synthetic metadata input is passed with `--no-write-lock-file` to both
a production target and the build-wrapper check. Correct metadata is preserved;
wrong source hash, inconsistent revision and missing record each reject both
targets. The root NAR and source lockfile remain unchanged. These are pure Nix
preparation checks, with owned temporary metadata; no product publication or
runtime filesystem adapter is executed by this fixture.

Complete `./test` passed in 159.40 seconds: 18.26 seconds of Nix preparation and
checks, then 141.14 seconds of host admission/setup/execution. All required Linux
native, ABI, CLI, standalone and Windows cross-build checks passed. Fresh file
and structure growth took 25.23 and 40.96 seconds; sampling and acceptance policy
are unchanged. The five-second execution budget remains exceeded.

## Compiled identity and SDK checkpoint, 2026-11-25

Both frontends compile `BUILD` and `DIRTY` into their single-line `--about`
identity. Uncaptured builds explicitly report `BUILD=unavailable DIRTY=unknown`.
Original native products, all four Windows cross products, the reusable zstdz
SDK, and optimized/Debug Rust libraries and frontends retain the same canonical
record in `nix-support/build-provenance.json`. The Rust library checks its SDK
record, and the separately built frontend checks the complete packaged library
record before linking. Its negative control changes only provenance while
keeping the target, archive and bindings valid.

Publication requires the manifest even for foreign products, whose executables
are not invoked. Native verification compares the compiled fields with that
manifest under contradictory environment variables. Missing, malformed and
mismatched metadata are rejected with other product prerequisites intact. The
shared CLI suite requires both fields and verifies that runtime environment
variables cannot change the identity. The new check first rejected an old
unstamped product, then passed against the stamped products.

Complete `./test` passed in 494.21 seconds: 236.94 seconds for Nix preparation
and checks, then 257.27 seconds including host admission and execution. Both
94-case CLI suites, required Linux native and ABI fixtures, standalone controls
and all four Windows cross products passed. File growth took 27.36 seconds and
structure growth 42.30 seconds, retaining every declared size, operation, core
scope and acceptance bound. These remain unbaselined measurements; the complete
execution feedback budget remains exceeded.

A separate bounded compilation check supplied a source-bound available dirty
record (`r201-125da0`) for this development snapshot. Both backends and both
profiles passed the publication verifier, and their manifests plus the reusable
SDK manifest matched the captured full JSON record exactly. This complements
the complete suite's unavailable-provenance case; it is not a clean release or
an activated CI attestation.

## Local capture and release preparation

`./build` captures the complete Git history context before invoking the pure
build. It selects the closest ancestor on the recorded `yolo` first-parent
history, counts that base's full ancestry, and checks the full source commit
against Nix metadata. A clean capture requires the Git export to match the
actual source NAR. Tracked changes remain a separate dirty flag; excluded
untracked envelopes do not change the built source. Shallow history, grafts,
submodules, missing primary history and source disagreements report unavailable
provenance. The collector disables ambient Git overrides and lazy fetching.

The wrapper builds from the captured immutable source path with an external
metadata input and no lockfile writes. Before publishing any product, it
compares the entire retained record with the capture and rechecks source
identity, including its full commit. A commit change with identical source
bytes still aborts publication. Existing transactional rollback and GC roots
remain required.

`./build --for-release` first evaluates `releaseProvenance` from that exact
source and input. This rejects unavailable and dirty captures before building
or publishing. It prepares products; it does not publish a tagged release.
Plain optimized builds can still report unavailable provenance explicitly.
Retain the full manifest when rebuilding an archived or detached source;
the display prefix alone does not identify a source uniquely.

Required controls use real Git graphs and private-store Nix snapshots, including
merged ancestry, a topic behind a later primary tip, excluded untracked files,
dirty state, stale snapshots, same-tree commit changes, hostile Git environment,
and shallow or wrong-NAR inputs. Actual-flake controls verify the clean release
guard and reject dirty/unavailable records. The publication fixture separately
rejects mismatched captures and both content and commit changes while preserving
the previous product. The complete combined `./test` passed in 292.51 seconds:
195.46 seconds for Nix preparation/checks and 97.05 seconds including host
admission/execution. Both 94-case CLI suites and every required native, ABI,
standalone and Windows cross check passed. File growth took 33.92 seconds and
structure growth 43.59 seconds; sampling, bounds and unbaselined status remain
unchanged. The feedback budget remains exceeded.

Commit `f051e6c4fa1a832c051c88c349dfa39bff43c219` was pushed and independently
matched against the fetched remote branch. Its exact CI run passed in 36
seconds. A subsequent capture from that clean committed source produced
`r202-f051e6`, count 202, with the same commit as source, primary tip and base.
The actual release guard accepted the record. Bounded Nix builds of both
optimized backends retained that exact full record and passed native identity
verification with `DIRTY=false`, including contradictory runtime variables.
These controls cover available clean, available dirty and unavailable builds.

## Infrastructure integration

A validated JSON record alone is not an independent Git-history proof or a
release attestation. The local Git-aware collector supplies that graph context;
the CI handoff remains a separately reviewed integration.

The infrastructure prototype initially supports authenticated primary-branch
pushes: tip and base equal the built commit, with complete ancestry fetched and
its Git export independently compared with the actual Nix-prefetched source.
Missing history, submodules and export mismatches fail closed. The same immutable
record input is retained for all targets, evaluated from the compared source
path; Git-only `self.rev` is therefore optional. Initial topic capture and private
Git fetch are outside that prototype's scope. Existing immutable records can be
replayed while their commit and history remain obtainable.

Infrastructure activation and end-to-end exact-commit CI evidence remain
pending. Independent review reproduced destination-symlink publication, missing
runtime tools, inherited controller leases and a masked shallow-history control.
All four repairs passed independent tests against an immutable candidate.
Handled termination now requeues the job and removes its private root; recovery
after a hard kill or power loss remains a pre-deployment qualification gap.
Native macOS/Windows runner bounds and preventive write boundaries are separate
unresolved dependencies.
