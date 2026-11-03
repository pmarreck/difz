# Nix-prepared tests and preventive execution

The complete `./test` prepares all executables through one `nix build`
invocation. Its output manifest identifies the exact host-test artifact;
execution does not reevaluate a potentially changed source tree to choose
another output. No host-side Zig, Cargo, or Rust compiler fallback remains
in the complete test entry point. Preparation refuses lock updates rather than
rewriting the checkout during a test run.

`packages.<system>.host-tests` joins the Debug CLI and unit-test executable
with the Rust C-ABI consumer. The Zig build's `test-artifacts` step installs
the unit executable without running it. Nix separately builds the library
for the Rust host ABI, verifies that the library-only target installs its
archive/header without the CLI, then compiles the Rust consumer. Linux Rust
uses the GNU ABI; the ordinary standalone CLI retains its musl target.

The eight required Nix checks are Debug core/CLI/installed-C,
benchmark-contract, build-wrapper, cross-apply, rust-codec, rust-core, rust-ffi,
and windows-gnu. The Linux Debug
check now declares the `script` utility, so the PTY assertion executes there.
Cached Nix checks retain their earlier verdicts; their reuse is not described
as fresh runtime execution.

## Linux confinement

After preparation, `./test` admits one runtime job through `build-budget`
when that control is installed. The pinned development environment supplies
Bubblewrap and runtime tools. The project-local `scripts/run-tests-isolated`
uses the shared test-isolation helper's read-only-host design: private tmpfs,
HOME/XDG/work directories, isolated namespaces, dropped capabilities, and no
writable host exceptions. It hides service sockets beneath `/run` and clears
shell startup variables. Missing support refuses execution without a fallback.

Required qualification first demonstrates that the same account can change
disposable protected fixtures without confinement. The boundary must then
reject relative/absolute writes, a scratch symlink escape, writes through a
published executable link, link replacement, rename, chmod, and file creation.
Both the child and parent inspect unchanged bytes, modes, and link targets.
Private writes must succeed, independent invocations must have private HOME
state, and child exit status must propagate.

The prepared-runner contract classifies missing, directory, and non-executable
artifacts in every required executable slot. It exhausts all 63 invalid
combinations of the four slot states; the actual suites supply the all-valid
control. Compiler and executable decoys record any accidental invocation.
Invalid sets must fail before executing
anything. The actual core, CLI, and Rust consumer then run inside confinement;
their success establishes the valid-artifact path independently of the decoys.

This boundary prevents accidental filesystem writes. It does not prevent reads
of other readable host files or establish a hostile-code security sandbox.
Only Linux execution is qualified. Native macOS/Windows boundaries remain open;
the Linux helper explicitly refuses unsupported systems.

## Failures exposed during migration

The first complete confined run failed because Zig's `std.testing.tmpDir`
creates `.zig-cache` relative to the current working directory. The read-only
checkout rejected that write. Running the prepared unit executable from its
private workspace fixes the setup; the checkout remains read-only.

The next run reached the real Linux ACL fixture and rejected its hard-coded
named-user ID because that principal was outside the private user namespace's
UID map. The fixture now uses the mapped caller. It still creates a named-user
ACE and verifies exact access/default ACL bytes through independent kernel
readback after staged reconstruction. Pure numeric-principal parser tests retain
their fixed IDs. No production ACL behavior changed or required test was skipped.

A fresh run on 2026-10-31 exposed inherited Bash functions that wrapped `cp`
and `find` through `$HOME/bin`. Changing HOME for isolation made those wrappers
refer to nonexistent private paths. The sandboxed Nix checks passed, while three
host CLI assertions failed. The isolation contract now exports failing `cp`,
`find`, `mkdir`, and arbitrary helper functions, verifies that an ordinary child
imports them, and requires an isolated child to have no functions and execute
real filesystem tools successfully. The runner clears inherited function
definitions before invoking tools or starting the private shell.

The first complete attempt took 220.57 seconds: 207.58 seconds for Nix
preparation and sandbox checks, followed by a 12.99-second host phase that
exposed the three CLI failures. After the regression failed against the old
runner and the function-clearing fix was applied, the complete suite passed
in 12.01 seconds with prepared artifacts: 7.05 seconds for Nix preparation
and cached checks, then 4.96 seconds for fresh host execution including
environment setup and admission. Core/CLI execution took 460/550 ms, with
95 core passes, one platform-specific skip, and all 92 CLI assertions passing.
The focused regression also waited roughly eight minutes for a shared test
slot before executing; queue waiting is separate from test execution.

## Validation, 2026-10-25

The complete Linux x86_64 entry point passed with these fresh host results
before the feedback optimization below:

| Suite | Result | Execution |
| --- | --- | ---: |
| Prepared-runner contracts | 63 invalid artifact sets and three invalid Rust-consumer paths rejected without execution | 520 ms |
| Debug core | 95 passed, one macOS-only test skipped, zero failed | 420 ms |
| Debug CLI, default metadata and real PTY | 92 passed, zero failed | 540 ms |
| Rust C-ABI consumer | Buffer ownership, limits, directory behavior, static codec linkage passed | 20 ms |

That host phase, including confinement qualification, environment
setup, resource admission and result delivery, took 4.71 seconds. Nix
evaluation/preparation/sandbox checks took 12.46 seconds; the total was
17.17 seconds. Executables were reused; the benchmark-contract check rebuilt
after new source files were staged. The earlier complete passing run took
101.57 seconds, including 98.84 seconds of Nix work and 2.73 seconds of host
execution, before the artifact classifier expanded from nine to 63 invalid
sets. These intervals use Linux `/proc/uptime` at 10 ms resolution.
Queue, fetching, compilation and Nix-check execution were not separately
instrumented and must not be reported as zero. The Rust FFI derivation
reported 52 seconds in its build phase; several Zig targets also rebuilt.
The confined host phase meets the five-second execution budget on this run;
total fresh execution across the mixed Nix phase is not separately measured,
so full-suite latency conformance is not claimed. Repeated Nix evaluation and
the benchmark check's broad source closure were investigated below.

The earlier failed full run took 105.29 seconds, including 97.50 seconds
of Nix work and 7.79 seconds in the phase that hit the working-directory
panic. The subsequent focused runtime run exposed the ACL fixture issue.
These attempts remain diagnostic evidence, rather than being replaced by the
passing result. Correctness-driven reruns followed actual fixes.

All five Nix check attributes passed. The codec check executed nine Rust
test functions plus cross-apply probe controls; the benchmark contract ran
25 assertions and the installed C consumer ran seven. Windows GNU compilation
is compilation evidence only. Shell syntax, shellcheck, Zig formatting, and
flake output/source-membership checks also passed.

This completes Nix preparation and preventive Linux execution for `./test`.
The broader build migration still needs PF/VARIANT publication, canonical
implementation selection where appropriate, and native agreement across the
five supported platforms. Native-runner policy and the production Rust codec
choice remain separate dependencies.

## Nix-only build adapter, 2026-11-02

Both `./build` and `./build debug` now require Nix and refuse a missing Nix
executable before running a compiler or publishing anything. The optimized
route selects `packages.<system>.default`; Debug selects a package alias of the
checked Debug artifact. Neither route updates the lock file. The wrapper uses
the output path returned by that specific Nix build instead of assuming that
`result` identifies the requested artifact, including with a custom output link.

The source-bounded `build-wrapper` check copies the real adapter into a private
project and supplies controlled Nix and Zig children. Both profiles refuse
missing Nix without calling Zig. Successful profile selection and an alternate
output path have positive controls. A failed build and five invalid artifact
shapes (missing, directory, nonexecutable, empty response and multiple outputs)
must preserve the previous executable's bytes. These checks execute in a Nix
builder and never publish into the live checkout.

All eight native Nix checks passed; the README change also reran the benchmark
contract's 26 assertions. Bash syntax, ShellCheck and flake preflight passed.
All three declared Nix systems evaluated, including the exact Debug-package
alias and required/excluded source sets. The earlier complete passing host
result is reused because the prepared native artifacts, confinement and
exercised host test sources remain unchanged. This does not claim a new host
execution or foreign-platform runtime qualification.

Publication still uses the legacy `zig-out/bin` location. PF/VARIANT/profile
trees, full-product publication, executable compatibility inspection, serialized
atomic selection and the five-platform build scopes remain open. This change
completes the required-Nix boundary, not the broader build-conformance item.

## Feedback investigation

The original preflight used thirteen Nix commands and took 5.23 seconds in
one warm observation. Adding the benchmark-source classifier brought that
to fourteen commands and 5.79 seconds. A single snapshot query now reads all
flake fields from the immutable Git-filtered store path returned by
`nix flake metadata`. This avoids copying ignored working-tree caches while
keeping related field reads on the same source snapshot. The Bash assertions
retain the package, pin, tool, runtime-check and source-membership expectations.
Required/excluded path sets also have explicit expected counts.

The consolidated preflight uses two Nix commands and took 1.11 seconds in
one observation. These individual GNU-time measurements exclude the enclosing
`nix develop` setup. They explain an observed feedback cost; they are not an
approved performance baseline or a general speed multiplier.

The benchmark check's source closure now contains only `bm`, `profiling.json`,
the README's tested performance claims, and `tests/benchmark`. Eleven required
paths and eight exclusions are checked as sets. The new assertion failed
against the original broad input and passed after narrowing it. All 25 actual
benchmark-contract assertions still execute. Planning notes, unrelated codec
QA, and product-source edits no longer invalidate this source closure; a
product change can still invalidate the separately linked difz oracle.

The first complete run with these changes passed in 13.60 seconds: 8.91 seconds
for Nix work, including a fresh benchmark check, and 4.69 seconds in the host
phase. Fresh host core/CLI/Rust-FFI execution took 410/510/20 ms; the exhaustive
artifact-set classifier took 510 ms. No executable compilation was needed.

After changing only these planning notes, the benchmark derivation path
remained byte-identical. A subsequent complete run reused all five Nix check
results and passed in 7.44 seconds: 4.50 seconds for preflight/preparation and
2.94 seconds for the fresh confined host phase. The classifier/core/CLI/Rust
consumer took 520/430/530/20 ms. These observations retain the earlier
17.17-second result and distinguish cached checks from fresh execution;
they do not establish full-suite fresh-execution latency conformance.
