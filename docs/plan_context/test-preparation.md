# Nix-prepared tests and preventive execution

The complete `./test` prepares all executables through one `nix build`
invocation. Its output manifest identifies the exact host-test artifact;
execution does not reevaluate a potentially changed source tree to choose
another output. No host-side Zig, Cargo, or Rust compiler fallback remains
in the complete test entry point.

`packages.<system>.host-tests` joins the Debug CLI and unit-test executable
with the Rust C-ABI consumer. The Zig build's `test-artifacts` step installs
the unit executable without running it. Nix separately builds the library
for the Rust host ABI, verifies that the library-only target installs its
archive/header without the CLI, then compiles the Rust consumer. Linux Rust
uses the GNU ABI; the ordinary standalone CLI retains its musl target.

The five Nix check attributes are Debug core/CLI/installed-C,
benchmark-contract, rust-codec, rust-ffi, and windows-gnu. The Linux Debug
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

## Validation, 2026-10-25

The final complete Linux x86_64 entry point passed with these fresh host results:

| Suite | Result | Execution |
| --- | --- | ---: |
| Prepared-runner contracts | 63 invalid artifact sets and three invalid Rust-consumer paths rejected without execution | 520 ms |
| Debug core | 95 passed, one macOS-only test skipped, zero failed | 420 ms |
| Debug CLI, default metadata and real PTY | 92 passed, zero failed | 540 ms |
| Rust C-ABI consumer | Buffer ownership, limits, directory behavior, static codec linkage passed | 20 ms |

The final host phase, including confinement qualification, environment
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
the benchmark check's broad source closure remain feedback costs to investigate.

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
