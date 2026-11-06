# Rust migration

The requested direction is a Rust build of the complete product: file and directory cores, filesystem metadata adapters, the C ABI implementation, and the CLI. The existing Zig/C implementation and tests are independent oracles during migration. On 2026-11-06 the owner selected zstdz, statically linked through its C API, and explicitly accepted native-code process-failure risk. Difz itself moves to Rust; wrapping the entire existing Zig core is not the selected implementation. Production entry points change only after the Rust replacement passes acceptance.

The source reference is preserved at `zig-zstdz-oracle-20261023` (`62973d6`). The earlier CDC engine remains on `old-cdc-plus-compression-probe-design`. The migration keeps ZDIF v4, DIFZTREE v2, BLAKE3 identities, staged verification, and the five supported platform targets. Byte-identical compressed frames are not required; reconstructed bytes, canonical metadata, and declared failure behavior are.

## Codec investigation

The production format needs an encoder and decoder with an external raw prefix, not just a decoder or a trained small dictionary. It also needs level 9, explicit window control through 2 GiB, long-distance matching, and bounded hostile-input decoding. A dependency's own round trip cannot establish interoperability or that it actually uses the source prefix.

| Candidate | Evidence from primary sources | Remaining gate |
| --- | --- | --- |
| [rusty_zstd 0.4.1](https://docs.rs/rusty_zstd/0.4.1/rusty_zstd/) | Pure Rust, MIT/Apache-2.0, no default dependencies; explicit prefix encode/decode, level/window parameters and LDM; Rust 1.85 minimum. | Cross-apply, prefix reach, and comparative measurements pass below; bounded hostile-prefix decoding remains open. |
| [structured-zstd 0.2.5](https://github.com/structured-world/structured-zstd) | Pure Rust, Apache-2.0; raw-content dictionaries, LDM and a C ABI; Rust 1.92 minimum. | Local prefix cross-apply and caller-output bounds pass. Its encoder window bound is 1 GiB, below difz's current 2 GiB bound; full resource qualification remains open. |
| [zstandard 0.1.9](https://github.com/stephenberry/zstandard) | Pure Rust, MIT/Apache-2.0; raw-content dictionaries, prepared handles, streaming, bounded output and strict single-frame decoding options. | Encoder window bound is 128 MiB; Rust 1.96 minimum exceeds this flake's Rust 1.94.1. Raw input beginning with dictionary magic needs separate qualification. |
| [zenzstd 0.1.0 source](https://github.com/imazen/zenzstd/blob/main/README.crates.md) | Pure Rust, MIT; levels 1–15 are documented as stable, 16–22 have a documented corruption defect. | A matching crates.io package was unavailable during this investigation. Level 9 is in the documented stable range; prefix/window behavior still needs qualification. |
| [ruzstd 0.9.0](https://docs.rs/ruzstd/0.9.0/ruzstd/encoding/) | Pure Rust encoder and decoder with a custom matcher interface. | Its supplied encoder does not establish parity with difz's level-9 prefix matcher. |
| [zstd 0.13.3](https://docs.rs/zstd/0.13.3/zstd/) | Rust bindings to the native zstd implementation, with prefix and parameter APIs exposed through zstd-safe. | Retains native C code; it is a fallback option, not evidence of a pure Rust compressor. |

Maintaining a new codec against upstream zstd changes is a stated concern. Reuse an existing implementation before proposing a rewrite. Combined Zig/Rust packaging is being investigated as another path, so a pure Rust compressor is not an accepted requirement. If an independent Zstandard rewrite becomes necessary, it belongs in a separate public repository, not inside difz. No such rewrite or publication is currently planned.

The encoder bounds above come from the published crates' recorded revisions: [rusty_zstd](https://github.com/Remade-With-Rust/rusty_zstd/blob/cd41258855309fd3dd77c2adf992fdfe4d401666/crates/rusty_zstd/src/params.rs) clamps 64-bit window logs to 31, [structured-zstd](https://github.com/structured-world/structured-zstd/blob/fa09f7ca0d7b662d1087d1f16321af20a17b0370/zstd/src/encoding/parameters.rs) limits them to 30, and [zstandard](https://github.com/stephenberry/zstandard/blob/64d8d8f03c3b682081956417ee8689a854885a96/src/encode.rs) limits its exposed encoder window to 27. These are encoder capability differences; default decoder limits and how much history is effectively searched are separate questions. Accepting a parameter does not by itself qualify every input at that scale.

Rusty_zstd's one-shot prefix decoder accepts a window cap but has no output-limit argument. Its separate bounded one-shot decoder does not accept a prefix. Production adoption therefore still requires a bounded streaming-prefix adapter or an upstream API extension, followed by hostile-input tests. Passing cross-apply checks alone does not establish that resource contract.

Rusty_zstd and Structured-zstd have now both been executed through pinned Nix builds. The nine-function suite covers cross-apply, prefix reach, multi-job controls, and Structured's caller-output and checksum behavior. Optimized 4/16/64 MiB comparisons separate codec-call timing from process/file-I/O timing and account for raw-dictionary ownership. See [the local results and limits](rust-codec-measurements.md). The other candidates remain source-reviewed only. No replacement codec is selected for production.

## Structured-zstd investigation, 2026-10-24

The inspected package is 0.2.5 at revision `fa09f7ca0d7b662d1087d1f16321af20a17b0370`. Version-pinned source matters: the cached docs.rs `latest` page still described 0.2.0, including an obsolete restriction on long-distance matching. The crates.io API was inaccessible during this follow-up, so this is not a claim that 0.2.5 is the newest release.

### Purpose and design

Structured-zstd implements standard Zstandard frames. The project describes its origin in CoordiNode's database and per-label dictionary workloads, starting from ruzstd. Its name does not designate another compression format or require structured input. It adds prepared dictionary reuse and optional storage-facing APIs, including skippable metadata, partial block decoding and resumable state. Those are useful integration surfaces for database containers. See the [project description](https://github.com/structured-world/structured-zstd#origins).

The library is Rust code without a native libzstd dependency; the separate C ABI package lets existing C consumers call that implementation. Its level-to-strategy mapping follows upstream zstd, while its matching and entropy implementations can produce different frames and performance. It supports runtime CPU dispatch, streaming and no_std configurations. The source contains unsafe pointer and SIMD code, so the pure-Rust description does not establish an entirely safe implementation. Its published manifest includes pointer-provenance tests suitable for Miri. See the [pinned manifest](https://github.com/structured-world/structured-zstd/blob/fa09f7ca0d7b662d1087d1f16321af20a17b0370/zstd/Cargo.toml).

For memory-corruption prevention, safe Rust supplies stronger compile-time ownership and concurrency guarantees than C or Zig; the existence of process-aborting failures does not make their failure probabilities equal. The safety of these particular codecs still depends on their unsafe internals, validation and resource handling. See [Rust's unsafe boundary](https://doc.rust-lang.org/nomicon/what-unsafe-does.html) and [Zig's ownership contract](https://ziglang.org/documentation/0.16.0/#Lifetime-and-Ownership).

### Published performance evidence

The project's [benchmark data](https://structured-world.github.io/structured-zstd/dev/bench/benchmark-delta.json), retrieved 2026-10-24, identifies the same 0.2.5 revision and a generation time of `2026-10-22T20:31:01+03:00`. The downloaded JSON's SHA-256 is `ab6c308f9061bac41529396b64bcf2e18c98f732631bbc101a63e60cc4734a2b`. The [extracted CSV](../benchmarks/structured-zstd-upstream-0.2.5-level9.csv) retains all seven scenarios for its `x86_64-gnu`, `level_9_lazy` cohort. These are upstream-reported measurements, not fresh difz measurements or a local performance baseline.

| Input | Bytes | Encode throughput / C | Decode throughput / C | Compressed bytes / C |
| --- | ---: | ---: | ---: | ---: |
| Repository decode corpus | 1,022,035 | 0.82x | 0.88x | 0.9993 |
| High-entropy random | 1,048,576 | 2.37x | 0.99x | 1.0000 |
| Repetitive log stream | 16,777,216 | 4.89x | 1.03x | 0.0751 |
| Low-entropy patterned | 1,048,576 | 2.75x | 9.28x | 1.0000 |
| Small random | 10,240 | 5.05x | 0.91x | 1.0000 |
| Small random | 1,024 | 7.57x | 0.73x | 1.0000 |
| Log lines | 4,096 | 1.16x | 0.91x | 1.0000 |

Throughput above 1 favors Rust; compressed-byte ratios below 1 favor Rust. Decode rows use the same C-produced frame on both sides. The paired throughput ratios alternate the implementations, with fresh compression contexts and reused output buffers; their values are not always the quotient of the separately timed Criterion arms. The metadata does not identify the CPU model, affinity or exact C codec revision, so these are limited to the author's reported environment. The C binding manifest requests `zstd` 0.14.0, which alone does not identify the linked C source. The seven-scenario spread does not support one universal speed multiplier.

The repository's [methodology](https://github.com/structured-world/structured-zstd/blob/fa09f7ca0d7b662d1087d1f16321af20a17b0370/BENCHMARKS.md) covers entropy extremes, small payloads and corpus data; some older level descriptions lag the actual rows. The [benchmark implementation](https://github.com/structured-world/structured-zstd/blob/fa09f7ca0d7b662d1087d1f16321af20a17b0370/zstd/benches/compare_ffi.rs) is the stronger source for the measured operation. Memory tracking runs separately using allocation counters; those bytes must not be described as RSS. No result here establishes performance against zstdz, Rusty_zstd, real binary release pairs, or the whole-source-prefix workload used by difz.

### Fit for difz

- The raw-content dictionary API can accept arbitrary source bytes; `from_raw_content` avoids interpreting dictionary magic as a trained dictionary. Local cross-apply and distant-prefix controls now pass, including a source beginning with dictionary magic. The CLI advertises `--patch-from`.
- The encoder caps `window_log` at 30 (1 GiB), because its match-finder uses u32 positions across a twice-window eviction band. Difz currently permits window log 31 (2 GiB), so adopting this crate unchanged would narrow its maximum match-history reach. Larger files can still be compressed using a sliding window. See the [parameter bounds](https://github.com/structured-world/structured-zstd/blob/fa09f7ca0d7b662d1087d1f16321af20a17b0370/zstd/src/encoding/parameters.rs).
- The optional allocation-free workspace decoder exposes no external prefix installation and rejects dictionary-naming frames. A separate `FrameDecoder::decode_all_with_dict_handle` path does accept a raw dictionary and caller-sized output. Its capacity, checksum, and advertised-window behavior now have local controls; complete hostile-input and work bounds remain open. See the [workspace decoder](https://github.com/structured-world/structured-zstd/blob/fa09f7ca0d7b662d1087d1f16321af20a17b0370/zstd/src/decoding/workspace.rs) and [our adapter checks](rust-codec-measurements.md).
- The CLI accepts `-T` but ignores it; it does not supply upstream zstd's worker implementation. This is less consequential for difz's current single-threaded file encoder, but it prevents treating the tools as equivalent multicore compressors. LDM is available across strategies in 0.2.5; older docs describing a level-16 floor are stale.

The pinned, source-bounded Structured-zstd probe and isolated shared-profiler comparisons are complete. On the measured 64 MiB source-prefix workload, transferring source ownership gives a 42.4 ms decode and 133 MiB process peak RSS, versus C's 32.3 ms and 133 MiB. Encode takes 351.0 ms versus C's 255.9 ms, with 343 versus 159 MiB peak RSS. Rusty's encode takes 1,840.7 ms. These three-sample codec-call means exclude file I/O; the C anchor is native-GCC-built zstdz source rather than the shipping Zig-built artifact. All sample rows, ownership controls, whole-process results, and remaining gates are recorded in [the local report](rust-codec-measurements.md).

### Nix-prepared Rust codec checks, 2026-10-24

`packages.<system>.rust-codec-tests` compiles the QA test binary and optimized common codec probe through `rustPlatform.buildRustPackage`, using the checked-in Cargo lock and offline compilation after declared dependency fetching. Its source closure contains only the manifest, lock, test module, shared adapters, and probe. C/C++ compiler and archive-tool environment overrides remain disabled during Cargo compilation; Nix separately prepares the pinned C static library used only by the comparison probe. This is a QA artifact, not a replacement product implementation.

`checks.<system>.rust-codec` runs that prepared binary against the separately built optimized Zig/zstdz oracle inside the Nix sandbox. The complete `./test` includes this check by default. The runtime wrapper requires regular executable paths for both artifacts and has no compiler fallback. Its boundary test covers the cross-product of normal paths, paths with spaces, missing paths, directories, and non-executable files; recording compiler decoys must remain unused. Argument boundaries and a failing child exit status are preserved.

The initial Linux x86_64 check passed three codec test functions over eight pairs, plus the wrapper boundary cases, in 0.22 seconds. Subsequent additions bring the suite to nine functions in about one second and require a separate all-encoder/all-decoder probe smoke check. All four Nix checks passed: Debug core/CLI/installed-C, benchmark contracts, Rust codec interoperability, and Windows GNU cross-compilation. The existing Nix CLI check reports its PTY assertion as skipped when `script` is unavailable; this is not full native terminal qualification. The new package and check evaluate for all three declared native Nix systems; native macOS and ARM execution was not performed.

The sandbox setting was enabled. The first source-bounded build fetched the locked Rust crate, compiled the optimized Rust test in 8.68 seconds, and built its Zig oracle in 84 seconds; it then caught a generated fixture's nonportable interpreter path before running the codec suite. After correcting that fixture, the check passed. Log-file creation/modification timestamps bound those two complete build attempts at approximately 87 and 85 seconds, respectively; the second included another 82-second oracle build. These figures do not separately measure daemon queue latency. The original broad Zig source closure included documentation and unrelated Rust QA, which caused needless oracle rebuilds. A tested fileset now retains the Zig build, source, archive helper, CLI tests, and installed consumer tests while excluding documentation and codec QA. Required and excluded path sets are checked independently. The flake metadata test also uses Git-aware `nix flake metadata` rather than a directory `getFlake` that could copy ignored build trees.

The older host-side Zig and Rust-FFI preparation paths were subsequently migrated into Nix. The complete entry point now runs prepared artifacts inside a qualified preventive Linux filesystem boundary; its fresh host core, CLI, and Rust-FFI suites pass. See [test preparation and measured feedback](test-preparation.md). Native macOS/Windows confinement and broader build-layout conformance remain open.

## Encoded bytes and compression workers, 2026-10-24

Interoperability requires the reconstructed target to match exactly. It does not require the compressed frame or complete diff to match another encoder byte for byte. Staying below 1 GiB only avoids the history-window ceiling; it does not force matching token choices, block boundaries, entropy coding or frame options. Both the published ordinary-compression rows and our local prefix measurements have different compressed sizes from C. At 64 MiB, our Structured prefix frame is 4,205,760 bytes versus C's 4,213,663. The ZDIF source/target identities remain stable for the same inputs.

| Implementation | Compression worker support | Evidence and qualification |
| --- | --- | --- |
| Upstream zstd | Yes: `-T#`, `-T0`, and the worker-count API | The [CLI manual](https://github.com/facebook/zstd/blob/dev/programs/zstd.1.md) documents the modes; the experimental CLI and API already appeared in [v1.1.3](https://github.com/facebook/zstd/releases/tag/v1.1.3). |
| Pinned zstdz | Yes on hosted targets | Its `build.zig` enables `ZSTD_MULTITHREAD` except for freestanding targets. |
| Current difz file encoder | Uses zero workers | `src/zstd_patch.zig` explicitly sets `ZSTD_c_nbWorkers` to zero. |
| Rusty_zstd 0.4.1 | Yes with its default std feature | `AdvancedOptions::nb_workers` selects its threaded path. Zero-worker cross-apply and explicit four-job characterization are covered below; this does not qualify production adoption. |
| Structured-zstd 0.2.5 | No implemented worker pipeline | Its CLI accepts `-T` but ignores it. No verified maintainer explanation for the omission was found. |

Parallel compression divides input into jobs and controls how much prior history each job reloads. Job boundaries and available history can change match choices and compressed bytes. Upstream explicitly documents different output between `--single-thread` and `-T1`; the latter overlaps a compression worker with I/O. This does not imply that scheduling must make each run nondeterministic: a fixed partition can produce stable indexed output. Changing the encoder, parameters or mode remains a separate compatibility question. See [upstream's job and overlap parameters](https://github.com/facebook/zstd/blob/dev/lib/zstd.h).

Rusty_zstd's `compress_mt` builds concatenated independent frames when input spans multiple jobs. Its [worker implementation](https://github.com/Remade-With-Rust/rusty_zstd/blob/cd41258855309fd3dd77c2adf992fdfe4d401666/crates/rusty_zstd/src/mt.rs) stores results by job index; later jobs use earlier target bytes for table priming rather than retaining the original external source prefix as their dictionary. One job falls back to its one-shot encoder, so a qualification fixture must exceed the resolved job size to actually exercise multiple jobs.

Difz specifies and emits one frame today. Its apply implementation delegates to `ZSTD_decompressDCtx`, whose general API can read concatenated frames, and does not explicitly count frames. The later direct test below proves that current apply accepts Rusty's four-frame output when later frames require no original prefix. Decoder acceptance does not itself qualify that encoding mode or its resource limits for production.

### Four-job prefix characterization, 2026-10-24

Two Nix-executed tests use a 2 MiB deterministic high-entropy source and a target with one flipped byte in the middle of each 512 KiB job. The explicit job size produces four real jobs rather than testing a worker flag on a single job. Changed targets prevent merely returning the unchanged source from passing reconstruction. The pinned zstdz CLI is a declared Nix input to the runtime check. No production encoder or decoder setting changes.

For Rusty_zstd, the test disables overlap to isolate original-source reach. Its worker stream contains four independently parsed Zstandard frames. The first frame is smaller than one eighth of its 512 KiB output, decodes with the source prefix, and fails without that prefix. Each later frame decodes correctly with no dictionary and is larger than half its output. The complete worker stream is larger than half the 2 MiB target, while the single-frame prefix encoding is smaller than one eighth. These negative controls establish the loss of source reuse after the first job on this workload. Requested worker counts 1 and 4, including a repeated four-worker run, produce identical bytes.

The complete Rusty stream decodes correctly in Rust and in existing native difz after borrowing only the oracle-generated ZDIF v4 header. Native source/target identity checks and an independent byte comparison both pass. Rust's prefix decoder accepts the stream with a 4 MiB window cap and rejects it with a 1 MiB cap. This is advertised-window evidence; its prefix API still has no output cap, so bounded hostile-input adoption remains unqualified.

For zstdz, the test covers `--single-thread`, `-T1`, `-T4`, and a repeated `-T4`, with the same explicit job size. Every stream has exactly one frame, is smaller than one eighth of the target, and reconstructs the entire target through the Rust decoder with the original prefix. Its T1/T4 outputs are byte identical. An ordinary-compression control without the prefix remains larger than one eighth, preventing a merely compressible input from establishing prefix reach. Pinned source-derived job geometry confirms that the 512 KiB request is not raised above that size by the default overlap for this case.

The five-function Nix codec suite, including both multi-job tests and the original eight-pair checks, executes in roughly one second on the measured Linux host. This is correctness and capability evidence. It is not a comparative codec performance benchmark, a full resource-limit qualification, or a decision to adopt Rusty's multiframe path.

## Combined Rust/Zig route

Rust can statically link the existing `libdifz.a` through `unsafe extern "C"` declarations. Rust byte slices cross that boundary as pointer/length pairs. Returned buffers remain owned by difz and must be freed with `difz_free`; Rust must not adopt them with `Vec::from_raw_parts`. This retains the Zig core and zstdz in the same process as the Rust frontend. It is a hybrid implementation, not a complete Rust rewrite. See the [Rust FFI guide](https://doc.rust-lang.org/nomicon/ffi.html).

`zig build lib` installs the flattened archive and public header without building the C CLI. The Rust consumer check in `tests/ffi/test_rust_lib.bash` builds that archive for the Rust host's OS, CPU and C runtime, links it statically, and checks file/directory operations, binary buffers, ownership and failure outputs. Debug GNU builds also link the sanitizer runtime rather than disabling the archive's checks. This proves one application executable can contain the implementation; platform and Debug runtime libraries may still be dynamic. Other target combinations must be built and inspected before claiming packaging coverage.

On 2026-10-23, the Linux x86_64 GNU Debug consumer passed binary and empty buffers, all 64 omission masks, output-limit and wrong-source failures, directory apply, and foreign-buffer cleanup. Inspection found no dynamic difz, zstd, or PCRE2 dependency. The Debug executable does depend on the system's sanitizer runtime. This result does not qualify the other four platform targets.

The Rust codec checks in `tests/codec_rust/` are QA-only dependencies. On the same host, all three tests passed with Rust 1.94.1 and Rusty_zstd 0.4.1. They compare native zstdz and Rust frames in both directions across eight input pairs, retaining the native oracle's container header to isolate codec behavior. The source-prefix fixture uses the first 64 KiB of a 2 MiB random source, including dictionary magic, and has a no-prefix negative control. A separate small fixture exercises a 2 GiB advertised window. That fixture does not qualify actual 2 GiB inputs. These checks do not implement a new Rust difz core or establish performance parity.

The shipped-codec decision is resolved: retain zstdz through its statically linked C API, including raw source prefixes, single-threaded encoding and the 2 GiB window contract. Structured-zstd and Rusty_zstd remain QA comparisons. The prior whole-library static-link proof establishes a packaging mechanism, not a Rust core or a five-platform release. The Rust codec adapter needs its own ownership, transitive-link and resource controls before production replacement.

The complete `./test` passed on that host after these additions, including the existing Debug core, 92 host CLI checks, the Nix Debug and installed-C checks, 25 benchmark-contract checks, and the Windows GNU cross-build. Rust formatting and Bash syntax checks also passed. Windows compilation here covers the existing Zig/C executable, not the Rust consumer.

## Use from another Rust library

A consuming application can depend on a Rust difz crate that links the Zig archive. The Rust library's build configuration must provide the native archive for the final target and propagate its link requirements to the final executable. The existing direct Rust consumer establishes the C ABI link, not a published Cargo package or a transitive dependency packaging test. See the [Rust linkage reference](https://doc.rust-lang.org/reference/linkage.html).

The application, Rust wrapper, Zig core and linked C dependencies share one process and address space. Another crate layer provides no crash containment. The current C ABI converts handled errors into status codes, including wrong-source and output-limit failures; a Rust adapter can return those as `Result`. An abort or fatal memory fault can terminate the entire consuming application. Memory corruption can also damage application state before any visible crash.

The current progress callback and its user pointer are mutable globals. A safe reusable Rust adapter needs an explicit synchronization or per-operation-context contract before allowing concurrent callback registration and calls. The direct consumer test does not establish concurrent or reentrant library safety.

Rust's [`catch_unwind`](https://doc.rust-lang.org/std/panic/fn.catch_unwind.html) catches unwinding Rust panics, not process aborts, and does not turn memory faults into recoverable errors. Changing the declaration to `C-unwind` would not supply crash containment. Rust callbacks must also prevent an unwinding panic from escaping a non-unwinding C ABI boundary. Returning status codes is the supported error path here.

Containing a worker crash requires a separate process and an explicit request/response contract. A CLI could launch its own executable in a worker mode. A reusable Rust library cannot assume its consuming executable implements that mode, so its helper packaging or host-provided worker would need a separate design decision. No worker isolation has been implemented.

If the Rust port is intended to reduce native memory-safety exposure, keeping the Zig/C implementation in process leaves that exposure in the dependency chain. An entirely Rust implementation can reduce it, depending on its unsafe code and native dependencies; it still does not guarantee recovery from every panic, allocation failure or process termination. The language boundary and the failure-containment requirement remain separate choices.

## Build conformance queued

PLAN includes conformance to the updated cross-platform-project-build-arch skill. Project-controlled outputs and publication use `macos-arm64`, `linux-amd64`, `linux-arm64`, `mswin-amd64`, and `mswin-arm64`. GNU/musl variants sit below PF and before the profile; compiler triples and compiler-owned caches retain their native spellings. A mixed-language product counts as one implementation. `CANONICAL_IMPL` and canonization apply when independently executable implementations coexist. Host publication, target inspection, complete build scopes, Nix/native agreement and rollback behavior require tests before conformance is claimed.

## Acceptance and sequence

1. Run the existing complete suite and freeze a known-source executable before changing entry points.
2. Establish a Rust file codec with bidirectional oracle tests over deterministic inputs, edits, moves, empty files, binary data, and prefix references beyond a payload-sized window. Check wrong sources, corruption, truncation and resource bounds separately.
3. Port canonical metadata and DIFZTREE, preserving domain separators, byte layouts, omission semantics and rejection rules. Reuse golden hashes and forged-checksum regressions; cross-apply directory patches with the reference.
4. Port no-follow traversal, metadata capture/transport, stage cleanup and non-replacing publication. Native Mac/Windows qualification gaps remain visible; a language change does not qualify them.
5. Replace the CLI and C ABI implementation, run the shared Bash and installed-C tests, and make the complete `./test` cover the Rust implementation by default before switching the production build.

The reference may catch differences, but it is not an infallible specification. Independent SHA-256/byte comparisons, canonical golden vectors, native filesystem readback, and malformed-input contracts remain necessary. Rust performance must be measured under the shared profiling workflow before carrying over any Zig benchmark claim.

### Cross-apply gate

`tests/acceptance/cross-apply` takes two prepared CLI executables. Six file
cases cover empty inputs, insertion, deletion, identical binary data, edits and
moved bytes. Two tree cases cover empty trees and changes including UTF-8 paths,
contained symlinks, file/directory kind changes, empty directories and modes.
Each implementation creates patches that both implementations must apply.
Independent byte, recursive-tree, symlink and descendant-mode comparisons
verify reconstruction; compressed-byte identity is not required.

Wrong-source controls retain the source length where a distinct same-length
source exists. Truncated patches, altered source/target identities and changed
tree checksums must fail with exit status 1 and no published output. A simulated
abort status is rejected. Source and target inputs must remain unchanged.
Explicit file output currently replaces existing files; directory output must
preserve an existing destination. DIFZTREE excludes root POSIX permissions from
its entry manifest, so reconstruction comparisons cover descendant modes while
input-preservation checks also cover root modes.

The gate contract uses the current native executable plus a forwarding adapter
as its positive control. Seven broken adapters exercise skipped encoding or
application, same-size corrupted files, corrupted tree files, incorrect modes,
masked failures and abort statuses. All 15 invalid executable-shape pairs must
fail before executing either artifact. This qualifies the gate against the
reference; no Rust product executable exists yet, so it does not establish Rust
product compatibility.

The current native reference is retained as a Nix GC root under
`.cache/oracle/zig-zstdz-21eb3cd`, alongside the earlier preserved executable.
Its derivation matches the package evaluated from commit `21eb3cd`; adding this
gate does not change the production executable. Reference preservation and QA
do not select the production Rust codec.

The complete `./test` runs the contract inside the Linux preventive boundary.
The source-bounded `checks.<system>.cross-apply` also runs it in a Nix builder.
The CI manifest is checked against every declared native check, deduplicating
package aliases by derivation identity. Native metadata-family coverage,
installed C-ABI parity, hostile-input resource bounds and foreign-platform
qualification remain separate migration requirements.

The Linux complete suite passed on 2026-11-02 with 95 core passes, one
platform-specific skip, 92 CLI passes, the cross-apply contract, and the Rust
C-ABI consumer. All six Nix checks passed; flake evaluation also passed for all
three declared Nix systems without claiming foreign native execution. The
final run took 1,309.91 seconds: 13.80 seconds of Nix preparation/checks and a
1,296.11-second host phase including resource admission. The five reported host
subsuites totaled 4.00 seconds, including 2.54 seconds for cross-apply; boundary
qualification is additional. Queue waiting dominated feedback. An earlier host
observation measured 4.84 seconds for the gate before moving discriminating
cases earlier; this is not a controlled performance baseline.

The first complete attempt restored missing dependencies and compiled QA for
334.42 seconds. Its host assertions later passed, but changing the entrypoint
while it was waiting caused a shell parse error at completion. That attempt is
incomplete and is not substituted for the final passing run. The missing-gate
Nix failure and the incomplete-CI-manifest failure were both observed before
their corresponding implementations passed.

### Rust header core, 2026-11-02

`rust/` now starts the Rust functional core with ZDIF v4 header encoding and
prefix parsing. The library uses `no_std`, forbids unsafe code, copies the
fixed metadata into typed fields, and borrows the remaining frame. Exhaustive
struct destructuring makes adding a field require serializer review. It does
not allocate or read the frame, verify identities, enforce output/window limits,
or implement compression. Wire lengths retain the complete u64 range; accepting
metadata is not authorization to allocate that size. The file decoder must
enforce its limits separately before allocation.

The six Debug-profile tests cover the byte layout, borrowed payload, all 85
header truncations, all 256 values at each magic/version byte, all 256 values
at every digest-byte position, and representative u64 length boundaries.
Four native-generated patches are checked against independent `b3sum` digests;
Rust-generated headers combined with the native frames must also reconstruct
the original targets through the native executable. These are small fixtures,
not qualification of actual 2 GiB inputs or of a Rust compressor.

`packages.<system>.rust-core-tests` and `checks.<system>.rust-core` use a
source-bounded, locked, offline Cargo build with the pinned Rust 1.94.1 toolchain.
The package requires a nonempty test inventory and executes ignored tests too.
Native-reference and BLAKE3 tools are declared Nix inputs. The production CLI,
C ABI implementation and codec selection remain unchanged.

The initial API-only stub failed compilation; a typed nonfunctional stub then
failed all six tests. The implemented core passed all six in 0.09 seconds under
the normal Nix check, including the native cross-apply controls. All seven Nix
checks and the updated flake preflight passed. Evaluation passed on all three
declared Nix systems; foreign runtime execution is not established.

The earlier complete passing host run remains applicable: the native CLI and
host-test derivation paths are identical to commit `0f23408`, and every host
runner, confinement helper and exercised host test source is unchanged. A
duplicate full-entrypoint attempt completed its Nix phase in 9.95 seconds and
was canceled during host admission after 869.80 seconds. Its interrupted status
is not a new passing host verdict; the earlier exact-artifact result is reused.

### Statically linked zstdz file codec, 2026-11-06

The owner selected zstdz and accepted the native codec's process-failure risk.
`difz-core::file` now implements ZDIF v4 encoding and bounded application in
Rust. It retains level 9, zero compression workers, the reference's parameter
selection and long-distance-matching threshold, raw binary source prefixes,
and the 2 GiB input/window contract. The safe core still forbids unsafe code.
File identities use locked BLAKE3 1.8.2 with its `pure` feature; Cargo is built
with C/C++ compilation disabled, so this adds no other native codec or hash
implementation.

The small `difz-zstdz` workspace dependency contains the native boundary.
Bindings are generated from the pinned zstdz header and linked to its static
archive, both supplied by the same Nix derivation. Its build script propagates
the static library through Cargo. A consuming Rust crate depends only on
`difz-core`; it does not manually add a native link flag. The Nix build supplies
`DIFZ_ZSTDZ_ROOT` and generated `DIFZ_ZSTDZ_BINDINGS` when building from source.
These are declared builder inputs, not runtime configuration or machine-local
dependency paths. Ordinary project builds remain locked and offline.

Each operation owns and frees its own native context. Prefix slices remain
borrowed through synchronous codec execution and context teardown. Returned
bytes use Rust allocations; no C-owned buffer becomes a Rust Vec. The native
adapter writes only into reserved capacity and publishes initialized bytes
after checking the native result and exact decode length. Wrong-source and
output-limit checks precede reconstruction allocation. There are no shared
progress callbacks or persistent native handles in this adapter.

The six existing header tests and five new file tests pass in the Debug Rust
check. Six file pairs cross-apply in both directions with the native reference;
the tested patches also match its bytes exactly and repeated encoding is
deterministic. Additional controls cover every truncation of a small patch,
identity mutations, output limits, u64 length forgeries, all power-of-two
window boundaries through 2 GiB without allocating those inputs, and four
concurrent callers. A deterministic 2 MiB high-entropy prefix beginning with
dictionary magic reconstructs a changed 64 KiB target; encoding without the
prefix is much larger and decoding without it fails. These fixtures do not
qualify actual 2 GiB inputs or all possible compressed-byte identities.

The separate Cargo consumer passes ordinary binary reconstruction and failures.
On Linux it also runs under a 128 MiB address-space limit: a forged 1 GiB output
still returns source/limit errors first, while an otherwise valid unlimited
request reports allocation failure. Binary inspection finds defined
`ZSTD_compress2` and `ZSTD_decompressDCtx` symbols and no dynamic zstd or difz
dependency. System runtime dependencies may remain dynamic.

The complete `./test` passed with fresh confined host execution: 95 core passes,
one platform-specific skip, 92 CLI passes, the acceptance-gate controls and the
existing C ABI consumer. Nix preparation/checks took 15.52 seconds and the host
phase took 5.82 seconds, totaling 21.34 seconds. That host total includes setup
and admission; no five-second full-suite conformance is claimed. Evaluation
passed for all three declared Nix systems. Native Rust execution is qualified
on Linux amd64 only. Directory metadata, filesystem adapters, the exported C
ABI and the production CLI still require Rust implementations; the production
entry point remains the preserved implementation during acceptance work.

### File growth controls, 2026-11-06

The encode/apply declarations share a Rust macro with their function definitions.
It derives a closed operation enum and complete operation list; an added
operation forces the probe's exhaustive dispatch to implement its measurement.
The compiled list is checked against every configuration case. Six negative
registry controls reject omissions, duplicates, stale names, incorrect
models/scopes and sweeps crossing native parameter regimes.

The Release probe uses pinned seeded binary data, scattered edits, and native
reference patches prepared before timing. Every result must equal its independent
reference outside timing. Five samples follow warmup; calibrated batches target
100 ms of process CPU time with a five-call minimum. Monotonic wall and all-thread
CPU durations are recorded per call. Output Vec destruction is outside timing;
native context creation and teardown remain inside. Codec and hash primitives
retain their dependency implementations; SIMD tuning awaits a comparative
component profile.

The first 256 KiB–2 MiB pilot was inconclusive under short samples. Corrected
batching exposed a clean growth-bound failure. Independent pinned-SDK diagnostics
explain the noncommensurate interval: chain/hash logs change from 19/20 to 20/21
at 512 KiB, and LDM switches on at 1 MiB. The stable 1–8 MiB case keeps chain/hash
20/21, search 4, minimum match 5, target length 16, strategy 5 and LDM enabled.
The window scales with input. Independently compiled native parameter records
are checked before measurement; a mixed-regime configuration fails early.
Transition sizes remain native byte-equality/cross-apply fixtures, increasing
the corpus from six to ten pairs. The failed pilot [diagnostics](../benchmarks/rust-file-growth-20261106-diagnostics.ndjson)
are never baseline observations. The model's operating range is explicit; no
universal linear bound over codec configuration transitions is claimed.

`./test` runs fresh declared-bound checks within the admitted preventive boundary,
requesting one and two CPUs explicitly for hosted-CI compatibility. Missing CPUs
fail without downscaling. `./big_o` runs the shared historical engine over all
one-, two- and twelve-core cases, with work in confinement and immutable history
outside the checkout. Twelve-core cases are extended timing cases. Neither runner
changes the production codec's zero-worker setting. Declared-bound checks do not
initialize or claim an accepted historical baseline.

The final complete suite passed in 59.65 seconds: 26.25 seconds of Nix work and
33.40 seconds for host setup/admission/execution. Growth took 25.99 seconds.
All 255 invalid four-artifact sets are rejected before execution, alongside
the existing core, CLI, cross-apply and C-ABI suites. This exceeds the five-second
execution budget; feedback-cost reduction remains open. A serial historical run
passed work, noise and declared-bound checks for all six cases on the first
attempt, returning `UNBASELINED`/exit 3 because no epoch was approved. Its
[raw CPU/wall samples and native parameters](../benchmarks/rust-file-growth-20261106-samples.ndjson)
are preserved. An earlier overlap of our own profiling jobs made a bounded run
inconclusive; it is diagnostic evidence. Profiling runs are now serialized.
Finite sweeps qualify this fixture and range, not application-update performance
or an asymptotic theorem.

### Cargo native-provider protection

The codec adapter declares `links = "zstd"`, matching the native C namespace it
provides. A parent with a second Cargo-managed provider of that namespace fails
dependency resolution, so archive order cannot silently select a different
codec. The Nix check first resolves a parent with an unrelated native provider,
then changes only that fixture's native link key and requires Cargo's explicit
duplicate-provider error. The control failed with the old adapter-specific key
and passed with `zstd`. A parent needing another native zstd wrapper must unify
its provider graph. This protects Cargo-managed providers; arbitrary external
linker inputs remain the consuming application's responsibility.

All eleven Rust tests, the transitive consumer, allocation controls and binary
inspection passed after this packaging change. The consumer is byte-identical
to the complete passing growth-gate revision `997f63e`, with SHA-256
`2a5ae8d289cc2895dfa5e3f3eaecb5b2bc7df8d5476d4844b22af9efa6e6a3e8`.
The host runners and executed test sources are unchanged. Its earlier complete
host verdict is reused; the duplicate queued host attempt was canceled and is
not reported as a new passing run. Native-provider qualification on other
platforms and the remaining Rust migration stay open.

### Metadata primitives, 2026-11-06

The Rust core now implements the six-family omission mask and comma-separated
grammar, optional timestamp transport, and original/observed modification
records. Their fixed-size encoders allocate no heap memory. Signed seconds use
the complete i64 wire domain; nanoseconds must be below one billion. Explicit
absence remains distinct from a present zero timestamp. One family declaration
generates the variants, names, bits and accepted mask.

A separate Nix artifact calls the existing Zig metadata functions directly. Its
small C frontend transfers arbitrary bytes with explicit lengths; neither the
Rust implementation nor a copied parser supplies its expected results. Every
valid mask combination and every unknown bit is checked, alongside invalid
names, duplicates, padding, all 256 timestamp flag values, signed-second extremes,
invalid nanoseconds and every truncation of the modification fixtures. The three
new tests failed with nonfunctional stubs while the prior eleven tests passed;
all fourteen passed after implementation. Variable-size canonical metadata,
tree formats and filesystem restoration remain to be ported.

The complete suite passed with fresh Nix checks and confined host execution:
27.73 seconds for preparation/checks and 38.01 seconds for the host phase,
65.74 seconds total. The host phase includes admission and environment setup;
the declared growth checks took 25.55 seconds. No feedback-budget improvement
or native macOS/Windows qualification is claimed by this step.

### Metadata names and identities

Rust now validates logical and raw xattr names, reserved transport names,
hardlink paths, and ACL entry identities. Closed wire enums cover xattr classes,
ACL tags and the three OS tags; ACL origins reuse the OS representation. The
platform eligibility helper deliberately retains its separate contract:
eligibility alone does not authorize storing a structurally invalid raw name.

Three more differential tests call the existing canonicalizer and platform
helpers, covering every byte in short binary names, length boundaries,
Unicode, case-sensitive transport recognition, reserved prefixes, relative
paths, and every ACL/OS tag byte. Nonfunctional stubs failed these tests while
the preceding fourteen passed; the completed implementation passes all
seventeen. These are pure format rules, not native filesystem qualification.

The complete suite passed again: Nix preparation/checks took 9.51 seconds;
the host phase, including its shared-slot queue, took 262.89 seconds. The fresh
growth checks took 24.44 seconds. Total elapsed time was 272.40 seconds; that
total is not a measurement of test execution alone.

### Reference-process reuse

Each metadata test now owns one reference child and sends bounded binary
requests over pipes. The child still calls the existing Zig functions with a
fresh arena for every request. All six metadata input sweeps remain intact.
An additional test compares successful and failing requests against the original
one-shot interface, checks clean EOF, and rejects truncated headers/bodies and
oversize requests. Crashes, malformed responses and unsuccessful child exits
fail the Rust test. Cleanup reaps only the owned child. The Nix test process group
has a 120-second deadline plus five seconds for termination if IPC stalls.

The first fresh eighteen-test run took 3.40 seconds, compared with 11.28 seconds
for the preceding seventeen-test run. These are observed check-feedback times,
not a codec benchmark or a statistical speedup claim. The product consumer is
byte-identical to the complete passing name-validation run, with SHA-256
`2d58736ff9345e824f50db7501f8f63c9d61109b7eb1802188a98321fd77e012`.
Host runners, configuration and the other host binaries are unchanged, so that
complete host verdict is reused while the changed Rust/reference checks run
fresh. No new host execution is claimed for this helper-only change.
All other required Nix check derivations match the preceding commit exactly;
the complete required Nix target set passes with the changed Rust check rebuilt.

### Reusable zstdz SDK

`packages.<system>.rust-zstdz-sdk` supplies the pinned static archive, headers,
generated Rust bindings and a Rust target-triple manifest. Add this package to
the consuming project's Nix `buildInputs`; its setup hook exports one
`DIFZ_ZSTDZ_ROOT`. The development shell and Rust QA use that same package.
The adapter reads its bindings and archive from this root, verifies the SDK
target against Cargo's `TARGET`, and propagates static linking through Cargo.
Cargo does not compile or fetch the native codec.

A separately resolved Cargo parent outside the difz workspace builds and runs a
binary-data round trip with only a `difz-core` dependency and no manual linker
flags. Its dependencies resolve offline from the declared vendor input; the
subsequent build uses its frozen lock. A control with the correct archive but a
wrong target manifest failed because the previous adapter accepted it; the
new guard rejects it during `cargo check`, before linking. Hook controls cover
initialization, repeated sourcing and conflicting SDK roots. The existing
duplicate-native-provider control remains required.

SDK output and target metadata evaluate for the three native Nix systems.
Actual Rust/native SDK execution is qualified on Linux amd64. This does not
complete the five-platform library qualification or the remaining Rust port.

The complete suite passed with fresh SDK/Rust checks and confined host execution.
Preparation/checks took 30.62 seconds; the host phase, including admission, took
97.66 seconds, for 128.28 seconds total. Growth execution took 24.21 seconds.

### Metadata record ownership and presence

The raw Rust record model covers xattrs, portable/native ACLs, all three times,
Finder fields, sparse holes and hardlink references. Descriptor vectors own
their storage. Byte fields use `Cow<[u8]>` so a decoded record can borrow its
input and a captured record can own its bytes. The default record allocates no
descriptor storage. This is an unvalidated model; it does not authorize
canonical encoding, hashing or restoration.

Portable permissions admit only the three defined bits. All 256 input bytes
are compared with the native canonical decoder and encoder. A second native
fixture checks empty records and each field's presence, including present zero
timestamps, zero Finder data, and present empty fields that later validation
must reject. Exhaustive record destructuring makes a newly added field require
review of the presence check. Both new tests failed with stubs while the prior
eighteen passed; all twenty pass after implementation, in 3.67 seconds.

The required Nix checks and source contracts pass. All four host binaries are
byte-identical to the complete passing SDK run, and host test sources are
unchanged. That host verdict is reused; the duplicate queued attempt was
canceled and is not reported as a new passing host run.

### Growth calibration and seed transport

The v4 measurement definition keeps five samples, three warmups and a 100 ms
estimated CPU-work target. Batch size now rounds up and uses the smallest
bounded count that reaches this target. It retains the 512-call cap and permits
one call for an operation already taking at least 100 ms. The prior formula
could undershoot the target, such as seven 13 ms calls, or force extra work,
such as five 70 ms calls. A required Release consumer test checks both work and
minimality across duration boundaries; it failed with the old formula.

The first historical invocation of v4 exposed a separate adapter bug before
timing: the shared profiler's default seed is 32 hexadecimal digits, while the
probe parsed a decimal u64. All six attempts were `INVALID`, not growth
observations. The probe now preserves the reported seed string and adapts the
shared hexadecimal representation to the pinned generator's `0x` syntax.
Direct provider comparisons cover decimal, explicit hexadecimal and shared
128-bit seeds. A high-bit distinction control rejects accidental truncation.
The calculation and provider tests are part of the required Nix check.

Before that seed fix, the complete v4 suite passed in 468.14 seconds, including
458.36 seconds for host admission/setup/execution. Growth execution took
22.90 seconds, versus 24.21 seconds in the preceding SDK run. These are observed
feedback times, not a statistical speedup claim. The five-second budget remains
open. Historical cohorts still require independent approval.

After correcting seed transport, the default-seed historical command passed
work, variation and growth checks for all six cases on the first attempt.
All return `UNBASELINED`/exit 3; no epoch was approved. The successful
[v4 samples](../benchmarks/rust-file-growth-20261106-v4-samples.ndjson) and all six
[failed-seed diagnostics](../benchmarks/rust-file-growth-20261106-v4-diagnostics.ndjson)
remain separate. The final complete suite passed in 40.37 seconds: 9.07 seconds
of preparation/checks and 31.30 seconds of host admission/setup/execution.
The growth portion took 23.90 seconds. Twenty core tests and both required
Release measurement controls pass. The remaining feedback-budget work stays
open; this change does not qualify new metadata codec performance.

### Canonical metadata validation, encoding and identity

`CanonicalMetadata` consumes a raw record after validating field limits,
names, ordering, duplicates, nanoseconds and sparse extents. Its record view
is immutable. Encoding and BLAKE3 identity use one field writer with exhaustive
record destructuring. Counts and variable field lengths fit the format's u32
fields before serialization; total output length is checked before fallible
reservation. Hashing streams the same bytes after `DIFZMETA\x01` without an
intermediate encoded allocation. Expected work is linear in descriptors/names
for validation and in encoded bytes for encoding/hashing; growth qualification
remains an open production-adoption gate.

A separate native fixture generator constructs records with every family,
binary values, all three ACL origins, signed-second extremes and explicit
presence. Native encoding/decoding and canonical hashing supply the expected
wire bytes, digests and errors. The Rust fixtures are constructed independently.
All 256 selector values cover the valid fixtures and reject unknown selectors;
invalid fixtures cover duplicates, order, names, empty ACLs, timestamps, zero,
overlapping, adjacent and overflowing extents, and hardlink paths. The two new
tests failed with stubs while the prior twenty passed; all twenty-two now pass.

A Linux consumer control aliases 64 MiB across attributes, yielding an encoded
size exceeding 4 GiB. Under the existing 128 MiB virtual-memory cap, encoding
returns `OutOfMemory` instead of aborting or publishing partial output. Both
Release measurement controls and the transitive-consumer/provider checks also
pass. This step does not implement canonical decoding, omission/normalization,
directory patches, filesystem restoration or the remaining Rust entry points.

The complete suite passed: 28.69 seconds for Nix preparation/checks and
297.93 seconds for host admission/setup/execution, totaling 326.62 seconds.
Growth execution took 21.97 seconds. All three native Nix systems evaluate;
native execution remains qualified on Linux amd64 only.

### Canonical metadata decoding

The Rust canonical decoder borrows every variable byte field from its input.
Descriptor storage uses fallible reservation only after a minimum-record-size
check establishes that the count could fit in the remaining bytes. Checked
cursor slices reject truncations, closed enums reject undefined tags and bits,
and the parser rejects trailing bytes before validating the canonical record.
The resulting immutable wrapper shares the encoder and identity contract.

Native fixtures verify decoded records, exact re-encoding, hashes, unchanged
input and borrowed byte locations. Differential controls compare every
truncation of sixteen valid fixtures, every single-bit mutation of a rich
fixture, trailing bytes, forged counts and all 256 values at each tag,
permission and presence field. The first two tests failed with a decoder stub;
all twenty-five core tests now pass, together with both Release measurement
controls. The Linux memory-limited consumer also rejects a forged maximum
count without requesting its descriptor allocation.

The complete suite passed with twenty-four core tests before the final finite
tag-domain control was added: 34.73 seconds for preparation/checks and 297.95
seconds for host admission/setup/execution, totaling 332.68 seconds. Growth
execution took 22.56 seconds. The fresh twenty-five-test Nix result has a
byte-identical runtime consumer, so the complete host verdict applies to it.
All three native Nix systems evaluate. Native execution remains qualified on
Linux amd64, and metadata growth qualification remains open before adoption.

### Metadata normalization and probe output lifetimes

Normalization consumes a raw record, removes omitted families before their
validation, sorts attributes and portable ACL entries, rejects duplicates,
and merges overlapping or adjacent sparse extents. It reuses descriptor and
owned byte storage. Exhaustive family matching and record destructuring make
new families or fields require review. Sorting takes O(n log n) key comparisons;
extent merging is linear after sorting. Metadata growth qualification remains
open before production adoption.

Native differential controls cover all 64 omission masks over 35 raw fixtures,
including mixed invalid families and their error precedence. Additional controls
cover idempotence, exact wire/hash identity, nested/adjacent extents in twelve
orders, maximum u64 extent ends and preservation of owned buffers. Both new
controls failed with a stub while the prior twenty-five passed. All twenty-seven
core tests pass. The memory-limited consumer normalizes reversed descriptors
sharing 64 MiB of values before its recoverable output-allocation check.

The first complete v4 run passed correctness but failed file-apply growth at
4 MiB to 8 MiB: 3.027 times against the 2.8 limit. Its
[diagnostic](../benchmarks/rust-file-growth-20261106-v4-normalization-diagnostic.ndjson)
is retained as a failure, not an accepted observation. Preparation/checks took
32.35 seconds; host admission/setup/execution took 717.18 seconds, totaling
749.53 seconds. The failing growth phase took 13.24 seconds. This does not
establish a cause for the growth failure.

Inspection found that the calibration result remained allocated throughout
subsequent timed samples. A required Release consumer test counts live outputs
through the actual sampling function; it fails if a prior result survives into
the next operation. That test failed with the retained calibration result and
passes after explicitly releasing it before sampling. Measurement definition v5
keeps the same sizes, native validation, three warmups, five samples, 100 ms
estimated work target and growth limits. Its new definition prevents mixing
measurements with v4. All three required Release controls pass; complete v5
host qualification passes. The complete v5 suite took 70.53 seconds: 8.41 for
preparation/checks and 62.12 for host admission/setup/execution. Growth execution
took 22.96 seconds, so this does not close the feedback-time budget.

A [paired diagnostic](../benchmarks/rust-file-apply-20261106-reversed-diagnostics.ndjson)
ran the decoder and normalization binaries with descending sizes. Both observed
about 2.1 times from 4 MiB to 8 MiB, rather than consistently reproducing the
earlier 3.027 ratio. One pair cannot establish a speed difference or identify the
original cause. The retained-buffer defect is independently demonstrated by the
lifetime test; the original failed observation remains a failure. Kernel/SIMD
changes were deferred while correcting this sampling-state defect.

The extended [v5 observations](../benchmarks/rust-file-growth-20261106-v5-samples.ndjson)
cover encode/apply on 1, 2 and 12 allowed cores. All six meet work, variation and
declared growth checks and remain `UNBASELINED`/exit 3. Encode on one core used
its single permitted noise retry; that first attempt remains diagnostic data.
No epoch was approved. These finite sweeps establish the declared bounds for
their observed workloads, not an asymptotic proof or a speedup claim.

### Metadata restore planning

The Rust restore planner accepts validated canonical metadata and explicit
filesystem capabilities. It returns immutable action and ordered compromise
views without allocation. Missing native support requires an available
transport destination. Capabilities use the existing conservative OS defaults;
filesystem probes may override individual flags. `RestoreError` is separate
from the metadata grammar's errors.

The compromise enum carries ACL origin and portable-application status only
for its native-ACL variant. Restore reports combine the ten native effect
codes idempotently, including the symlink-parent and modification-time
transport effects that later filesystem adapters will report. A compile-time
check keeps every effect code inside the report's bitset.

The independent native helper serializes all action fields by reflection and
includes warning code, family, ACL status and origin. Tests compare 19,200
scenarios: all 256 capability masks on all three OSes for sixteen native
fixtures, four raw-name cases and five isolated timestamp/Finder records.
Isolated present-zero fields prevent another populated field from masking a
missing action. A second control compares the default capabilities and all
1,024 report combinations, including repeated effects. The planner control
failed with a stub; both controls pass with the implementation. These are
pure capability-table comparisons executed on Linux, not native filesystem
qualification for macOS or Windows. All twenty-nine core tests and three
Release probe controls pass on the normalization base. The complete suite
passed in 944.45 seconds: 51.07 for preparation/checks and 893.38 for host
admission/setup/execution. Growth execution took 22.16 seconds. All three native
Nix systems evaluate; native execution remains qualified on Linux amd64.

The original CDC design is also published on
`old-cdc-plus-compression-probe-design` at `a83c041`, after preparing that
revision's original checks. An independent fetch confirms the remote ref.

### DIFZTREE paths and symlink targets

The Rust path grammar preserves native UTF-8, relative-path, separator, NUL,
drive-prefix, component and 4096-byte checks, including error precedence.
Symlink targets use the link's parent depth to reject lexical escapes. They
permit dot components and contained parent traversal without filesystem access.
The link path retains its byte limit; the native target grammar has no such
length cap. Both functions use linear scans and allocate no storage. Directory
growth qualification remains open before production adoption.

The native reference now compiles the unchanged metadata and directory sources
under one import root, preserving their shared types. It reaches symlink
validation through the public snapshot boundary and supplies each required
parent directory. The two Rust tests compare binary byte sweeps, Unicode and
malformed UTF-8, conflicting errors, length boundaries, input preservation,
relative targets and parent traversals at depths zero through eight. Both
failed with stubs while the prior twenty-seven passed. The combined base passes
all thirty-one core tests and three Release probe controls.

The complete suite passed in 197.66 seconds: 49.60 for preparation/checks and
148.06 for host admission/setup/execution. Growth execution took 24.20 seconds.
This step does not implement tree records, snapshot identity or directory
patching in Rust.

### Expanded tree records

Raw snapshots own their entry descriptors and may borrow or own path/content
bytes. Each entry and the root hold validated canonical metadata. The content
enum separates directories, regular files and symlinks: directories carry no
data, and symlink views always use mode 0777. Portable file/directory modes
admit only their nine permission bits. Exhaustive field/variant matches make
new representations require review. Default empty snapshots and record views
allocate no storage.

A native comparison covers all 65,536 mode values. Independent client
serialization of record views matches the native tree hash for empty trees,
each kind, binary file content, entry metadata and nonempty root metadata.
Ownership controls retain borrowed and owned byte addresses. Both new tests
failed with stubs while the prior thirty-one passed. All thirty-three core
tests and three Release controls pass. The fresh core tests took 5.02 seconds;
the existing feedback-time budget remains open.

The complete suite passed in 452.04 seconds: 30.82 for preparation/checks and
421.22 for host admission/setup/execution. Growth execution took 21.98 seconds.
Raw snapshots still require hierarchy, symlink and physical metadata relation
validation. This step adds no production snapshot hash or directory codec.

### Validated snapshots and directory identity

`CanonicalSnapshot` consumes raw records after checking structure, physical
metadata relationships and root restrictions in native order. Parent lookup
uses the already ordered prefix. Sparse extents must belong to regular files,
stay within expanded data and cover zero bytes. Hardlinks require an earlier
canonical regular file with matching mode, bytes and every metadata field
except the referring link. Shared metadata compares canonical fields directly.
Root sparse extents and hardlink references are rejected. The returned view
is immutable; consuming it explicitly returns the raw record.

Identity streams the native `DIFZTREE-ID\x02` layout, each canonical metadata
hash, and a `DIFZTREE-ROOT\x01` suffix only for nonempty root metadata.
Validation and hashing allocate no additional storage. Expected validation
work is O(n log n) path comparisons plus scanned path, extent and shared
file/metadata bytes; hashing is linear in file/path and canonical metadata bytes. Directory
growth qualification remains open before production adoption.

Forty-two independent native fixtures cover valid rich/empty/root-only trees,
ordering and hierarchy errors, sparse bounds/content, hardlink kinds, cycles
and chains, mode/data mismatches, every shared metadata family, explicit-zero
presence and mixed-error precedence. Real arrays with 1,000,000 and 1,000,001
entries verify both sides of the count boundary before duplicate checks.
Ownership controls preserve borrowed file storage through validation. Both new
tests failed with stubs while the prior thirty-three passed. All thirty-five
core tests and three Release controls pass; the expanded fresh core run took
8.45 seconds. No execution-budget pass is implied.

The complete suite passed in 860.02 seconds: 10.40 for preparation/checks and
849.62 for host admission/setup/execution. Growth execution took 22.32 seconds.
All three native Nix systems evaluate. Directory patch encoding/decoding,
filesystem adapters and the remaining Rust entry points are still pending.

### DIFZTREE v2 envelope integrity

The Rust envelope parser accepts only the v2 format. It verifies the byte
ceiling, fixed header, magic, format version, domain-separated BLAKE3 checksum,
reader requirement, flags, descriptor limits and conservative body-size bounds
in native order. Reader requirements 0, 1 and 2 describe this same v2 layout;
they do not enable a v1 decoder. The result borrows the body and leaves its
rules, operations and metadata semantically unvalidated. Encoding returns a
fixed 120-byte header for the supplied body. Both operations allocate no
storage and perform O(patch bytes) checksum work.

The reference helper now calls the unchanged native directory codec through
`createPatch` and `readOptions`. Its source closure explicitly includes the
codec and filter dependencies. PCRE2 is a test-helper dependency here; this
change adds no dependency to the shipped Rust library. Four native patch
profiles cover empty trees, root metadata, a binary file and a filter rule.
Accepted identity changes, all omission masks and supported reader requirements
provide positive controls alongside truncation, corruption, version/flag/count
mutations, exact byte ceilings and mixed-error precedence. Combined minimum
rule/entry body lengths are tested at one byte below, exactly and one above
the boundary, without treating envelope acceptance as full body acceptance.

All three new test groups failed with stubs while the prior thirty-five passed.
All thirty-eight core tests and three Release controls pass; fresh core
execution took 6.07 seconds. All three Nix systems evaluate. The complete suite
passed in 334.25 seconds: 33.35 for preparation/checks and 300.90 for host
admission/setup/execution. Growth execution took 22.52 seconds; historical
baselines remain unapproved. Directory body decoding, encoding, application
and filesystem adapters remain pending.

### Whole-path glob anchoring regression

Rust filter comparison exposed a native inconsistency: the glob `*a` accepted
the valid path bytes `a\n`, while `a` and `**a` rejected them. The reproduction
also fails against the production Zig build with its pinned PCRE2 fork,
independently of the Rust implementation and reference-helper dependency.
The new native regression failed with `expected false, found true`; the prior
tests passed or retained their sandbox-dependent skips.

Glob conversion now uses absolute `\A` and `\z` anchors. This preserves the
intended complete-path match instead of depending on `$` and an additional
matcher flag to agree about a final newline. The [PCRE2 pattern
reference](https://www.pcre2.org/doc/pcre2pattern/) specifies the absolute
anchors. Twelve native cases distinguish an unconsumed final newline from
newlines actually consumed by a wildcard or an explicit pattern character.
Rule storage and the DIFZTREE v2 wire format are unchanged.

The complete suite passed in 761.72 seconds: 166.61 for Nix preparation/checks
and 595.11 for host admission/setup/execution. The confined native run passed
ninety-six tests with one platform skip. Growth execution took 30.24 seconds;
declared bounds pass and historical baselines remain unapproved.

### Interleaved sampling and resolved native state

The path-filter prototype's complete run passed correctness and then failed
the unchanged encode growth bound: the 4-to-8 MiB CPU ratio was 2.818351,
above 2.8. The [v5 failure](../benchmarks/rust-file-growth-20261106-v5-filter-failure.ndjson)
remains a nonretryable failure. That run took 830.71 seconds, including 819.24
for host admission/setup/execution; its growth phase stopped after 6.57 seconds.

Four predefined [paired diagnostics](../benchmarks/rust-file-encode-20261106-paired-diagnostics.ndjson)
used the previous and prototype binaries in forward and reverse size order.
Their 4-to-8 MiB arithmetic-mean CPU ratios were 2.1593, 2.1212, 2.1964 and
1.9586, respectively. These diagnostics are not gate retries, eligible baseline
selections, proof of the failure's cause, or evidence of a speedup.

SDK introspection also exposed an incomplete parameter claim. Main search
parameters stay fixed, but the resolved window log grows from 21 to 24 and
LDM hash log from 15 to 18. The context allocation grows from 11,290,656 to
13,132,832 bytes. These are intentionally scaled states, not identical complete
parameter sets. The SDK report now reads resolved state after compression,
using private headers and the archive from the same pinned source and feature
configuration. The gate checks the expected window/LDM trajectory, unchanged
search settings, zero workers and exact SDK records. Six registry mutations
and seven malformed native-profile reports are required negative controls.

[Callgrind diagnostics](../benchmarks/zstd-prefix-work-20261106-instructions.ndjson)
count only native `ZSTD_compress2`, excluding Rust, BLAKE3 and the ZDIF header.
On the benchmark's exact seed-41 corpus they recorded 45,116,324, 90,064,094,
179,136,728 and 357,807,197 instructions. Frame lengths match the retained
Rust benchmark after subtracting its 85-byte header. A separate LCG control
also approximately doubles. These finite controls describe native instruction
work; they do not establish whole-Rust timing or a universal complexity result.
The reproduction uses the current locked SDK and random provider:

```sh
diagnostic_source=$(nix flake metadata --json | jq -er .path)
nix build --impure --no-link --print-out-paths \
  --file docs/benchmarks/research/zstd_prefix_instructions.nix \
  --argstr source "$diagnostic_source"
```

The v6 sampler prepares and retains all four source/target fixtures before
measurement, calibrates each size, then rotates start positions and alternates
direction across five sampling rounds. Every round visits every size. Three
warmups, the 100 ms estimated work target, five samples, validation outside
timing, output destruction and the 2.8 growth ceiling are preserved. Inputs
are jointly resident, so v6 is a new measurement definition. The raw record
includes actual sample order. A deterministic injected-clock control verifies
work order and that validation and destruction occur outside timed intervals;
it failed against size-grouped sampling while the prior controls passed.

All thirty-eight core tests and four Release controls pass; the fresh core
run took 7.62 seconds and controls 0.09 seconds. All three Nix systems evaluate.
The complete suite passed in 971.60 seconds: 44.19 for Nix preparation/checks
and 927.41 for host admission/setup/execution. The required four fresh growth
cases passed their unchanged bounds; growth execution took 22.57 seconds.
Their [v6 observations](../benchmarks/rust-file-growth-20261106-v6-host-samples.ndjson)
remain unbaselined. This single run does not establish a reduction in noise
or explain the earlier failure. No historical epoch is approved.

### Rust path filtering and shared structure checks

Ordered filters now compile globs into Rust tokens and match with two
dynamic-program rows. They preserve original-action default selection, leading
negation, later-rule precedence, escapes, literal class hyphens, Unicode
characters and native newline behavior after the anchoring correction.
Compilation is linear in pattern bytes, including unterminated classes;
matching takes O(total pattern bytes times path characters) work and O(path
bytes) scratch. Allocation is fallible. This adds no production PCRE2
dependency. The reference helper uses the production PCRE2 fork, headers and
target ABI through a dedicated Nix-built static reference artifact.

Native comparisons cover representative rules, invalid paths, 1,110 short
glob patterns, class/escape/Unicode/newline cases, byte paths and adversarial
repetition. The first differential run caught the native anchoring defect;
the original v5 host growth failure is retained above. With v6, the filter
increment independently passes all Nix checks, forty-one core tests and four
Release controls. Its fresh core run took 6.92 seconds. Filter growth and
memory qualification remain part of the directory-codec adoption gate.

Structure validation is now shared between expanded snapshots and forthcoming
wire entries. It checks path, raw mode, directory payload, symlink containment,
ordering and parents in native order. Expanded sparse/hardlink relations and
root restrictions remain separate. The canonical snapshot constructor uses
the shared validator before its existing physical checks. Forty rich native
fixture comparisons establish this boundary; 450 raw path/mode/kind/payload
combinations verify wire-view error precedence. Existing snapshot tests still
exercise both million-entry boundaries through the shared code. Both new test
groups failed with stubs while the earlier thirty-eight passed.

The combined final tree passed forty-three core tests and four Release
controls, all three Nix-system evaluations and the complete suite. Source
inventories require all thirty-three core inputs. Full validation took
558.06 seconds: 152.70 for Nix preparation/checks and 405.36 for host admission,
setup and execution. Fresh growth took 22.83 seconds and passed unchanged
bounds. The filter and structure changes are separate commits; the complete
host suite validates their combined final tree. No latency-budget or native
macOS/Windows qualification is implied.

## Rust DIFZTREE body decoder, 2026-11-06

The Rust parser validates v2 rules, six closed operations, canonical entry and
root metadata, omitted-family absence, payload grammar, trailing bytes and the
shared hierarchy rules. It checks envelope integrity and conservative count
bounds before descriptor allocation. Paths, names and file payloads borrow the
patch. Delta expansion, sparse/hardlink byte relations and source/target
identities remain application checks. Expected work is linear in patch and
pattern bytes plus ordered hierarchy lookups; directory growth qualification
remains open before production adoption.

The independent reference compiles unchanged native codec sources. Five
fixtures cover every operation and all metadata families; the rich fixture is
also produced with all sixty-four omission masks. Comparisons cover every
truncation, resealed body-byte mutations, trailing bytes, all operation,
reserved, mode and selected length/path byte values, and 305 configurable
limit cases. The stub failed two new groups while forty-three earlier tests
passed. The implemented parser passes forty-six core tests and four Release
controls through Nix; all three native-system configurations evaluate.

The complete suite passed in 660.23 seconds: 9.92 for Nix preparation and
checks, followed by 650.31 for host admission, setup and execution. Fresh file
growth took 22.98 seconds and passed the unchanged bounds. The historical
cohorts remain unbaselined; these results do not qualify native macOS/Windows
execution or the pending directory growth and memory contracts.

## Rust DIFZTREE encoder, 2026-11-06

The Rust encoder accepts validated snapshots and emits only DIFZTREE v2.
It chooses unchanged-file copies, single-frame source-prefix deltas, new-file
raw data and canonical hardlinks, plus directories and symlinks. Ordered rules
are recorded after compilation; filesystem selection remains the adapter's
responsibility. Omission projects canonical metadata before hashing both trees,
borrowing file and metadata buffers and fallibly allocating only retained
descriptors. Default omission avoids the projection allocation entirely.
Every append checks the complete patch bound before growing output; metadata
lengths are checked against both payload and u32 wire bounds.

Exact native-byte comparisons pass for all sixty-four omission masks and the
four smaller fixtures, covering every operation, binary data, all metadata
families and root presence. A separate fixture checks type changes and source
root identity. Additional controls verify borrowed file/metadata buffers,
canonical projection, rule-count/pattern limits and output-growth rejection.
The stub failed the native-byte comparison while forty-seven tests passed.

The final increment passes fifty core tests and four Release controls, all
three Nix-system evaluations and the complete suite. Fresh core execution took
7.11 seconds. Full validation took 65.09 seconds: 34.60 for Nix preparation and
checks and 30.49 for host admission, setup and execution. Fresh file growth
took 22.95 seconds and passed unchanged bounds. Directory application and its
growth/memory qualification remain pending; production entry points are still
the existing implementation.

## Rust DIFZTREE application, 2026-11-06

Rust application verifies parsed grammar and the masked source identity before
expanding any files. It reconstructs all six operations, validates expanded
sparse/hardlink relations and verifies the complete target identity. Raw,
symlink and unchanged-file bytes borrow the patch or source; moved canonical
metadata retains its descriptor ownership. Changed files own their Rust output.
Expected work is linear in bytes plus ordered path lookups and codec work.

The aggregate logical-output budget counts symlink and hardlink bytes too.
Unlike the native tree adapter's post-decompression size check, Rust checks a
delta's advertised size before decompression while retaining source/window
error precedence. A corrupt delta that also exceeds this budget can therefore
fail with `LimitExceeded` before frame validation. A resealed 1 GiB advertised
output with a six-byte budget verifies that rejection without allocating the
advertised output. This is an intentional resource-contract improvement.

A hardlink referring to newly decompressed, owned data currently makes a
fallible copy. A returned snapshot cannot safely borrow another entry's Vec;
borrowed source/patch data can be shared directly. The copy preserves bytes and
metadata but can raise memory use compared with the native alias. Qualify this
ownership tradeoff and a shared-buffer representation before production
adoption; no equivalent-memory claim is made.

Cross-apply compares both Rust and native patches against the unchanged native
applicator for all sixty-four omission masks, exact logical-output boundaries
and smaller root/raw/rule fixtures. Rejections cover wrong tree identities,
every byte of a resealed delta, missing source entries, wrong kinds and invalid
expanded hardlink modes. Ownership controls verify borrowed and owned output
and retained source-error precedence. The stub failed both new groups while
fifty earlier tests passed. The implementation passes fifty-four core tests,
four Release controls and all three Nix-system evaluations.

The complete suite passed in 872.52 seconds: 43.70 for Nix preparation/checks
and 828.82 for host admission, setup and execution. Fresh file growth took
24.04 seconds and passed unchanged bounds. Most elapsed time was admission
waiting, not test execution. Directory growth, hardlink memory use, filesystem
integration and native macOS/Windows execution remain unqualified.

## Rust file C boundary, 2026-11-06

The experimental `difz-c-api` crate implements the file C boundary in Rust
and uses the selected static zstdz SDK. Its header is
`rust/c-api/include/difz-rust.h`; the prepared Nix artifact includes that header
and `libdifz_rust.a`. This is not a replacement production library yet.
Filesystem entry points and full target qualification remain pending.

Inputs use pointer/length pairs, including omission text. Empty input permits
a null pointer; nonempty null input and lengths beyond `isize::MAX` fail before
slice construction. Returned buffers use an opaque owner retaining the complete
Vec and actual capacity. Callers query immutable data/length and free the owner
exactly once, without supplying allocation metadata. Owner allocation is
fallible. Output slots are written only after successful production and owner
allocation, preserving caller sentinels on errors.

The narrow unsafe boundary documents pointer validity and ownership; the
functional core still forbids unsafe code. Rust panics become a distinct
status, and a compile guard rejects an aborting panic configuration. Tests
inject a panic, preserve caller output, and check nontrivial Vec capacity.
Native zstdz process failures, invalid caller pointers and OS/allocator aborts
remain outside panic containment; no process-isolation claim is made.

A separately compiled C11 caller checks binary and empty data, limits, wrong
sources, invalid arguments, exact buffer release and embedded-NUL omission
rejection. Its patches are applied by the existing executable; it also applies
native-created patches and compares the independently specified target bytes.
The caller failed against stubs while fifty-four core tests and four Release
controls passed. Nix now passes that caller, bidirectional file exchange,
fifty-four core tests, four Release controls and two boundary controls. A
separate aborting build must fail with the specific compile-guard diagnostic.
All three native-system configurations evaluate; native execution here is
Linux x86_64 only. The linked consumer has no dynamic difz/zstd dependency.

The complete suite passed in 996.27 seconds: 8.52 for Nix preparation/checks
and 987.75 for host admission, setup and execution. Fresh file growth took
22.44 seconds and passed unchanged bounds. Most elapsed time was waiting for
shared admission. Production entry points and native target qualification
remain unchanged by this experimental boundary.

## Parent symlink transport and Linux ACL codecs, 2026-11-06

Rust now implements the approved `difz.symlinks` parent attribute with the
existing DIFZLINK format. Immutable records enforce sorted child basenames,
timestamp absence/observation relations, ACL/Finder override flags and symlink
metadata restrictions. Decoding borrows names and metadata values and checks
record counts before allocating descriptors. Encoding preflights the complete
64 KiB ceiling through an allocation-free metadata length count, before
allocating either output or temporary metadata blobs. Lookup uses binary search;
encoding and decoding are linear in the bounded representation.

Native comparisons cover all 1,408 presence/absence/override combinations,
Unicode, timestamp/ACL/Finder records, every truncation and body-byte mutation,
trailing bytes, invalid basenames and symlink metadata, real descriptor-count
boundaries and values immediately around 65,536 complete encoded bytes. The
stub failed both initial groups while fifty-four earlier tests passed. The
standalone transport increment passes fifty-seven core tests, four Release
controls, two C-boundary controls and all three Nix-system evaluations. Its
fresh core execution took 7.89 seconds.

The Linux ACL layer validates kernel version, entry size/order, permission bits,
principal IDs, required base entries and the mask required for named entries.
It preserves access/default bytes in the existing DIFZACL container and converts
portable ACEs in both directions. Numeric names retain the pinned native
converter's signed-zero, leading-plus and digit-separator grammar, overflow
rejection, numeric kernel ordering and duplicate-ID checks. Conversion uses
fallible descriptor/name allocation; validation and container decoding borrow
input. Linear byte/entry work and sorting for reverse conversion remain subject
to the metadata growth/memory qualification gate.

The independent reference calls the actual production Linux converter, whose
only production change is making the pure reverse-conversion helper public.
Tests exhaust the 512 base-permission combinations, vary tags/IDs and extended
permission values, compare malformed/truncated containers, and cover numeric
aliases, invalid names and missing required entries. Stubs failed two groups
while the earlier fifty-seven passed. The final codec tree passes sixty core
tests, four Release controls, two C-boundary controls and all three system
evaluations; the fresh core run took 8.28 seconds. These pure wire conversions
do not establish native filesystem ACL capture or restore qualification.

The complete suite validates the combined final transport/ACL tree. It passed
in 1,333.27 seconds: 135.81 for Nix preparation/checks and 1,197.46 for host
admission, setup and execution. Fresh file growth took 22.45 seconds and passed
unchanged bounds; historical cohorts remain unbaselined. The two codec changes
are separate commits, with standalone transport Nix evidence and full host
validation for their combined tree. Filesystem integration, metadata/directory
growth and memory, and native macOS/Windows qualification remain pending.

## First Rust filesystem capabilities, 2026-11-06

The experimental `difz-platform` crate starts the OS adapter for Linux and
macOS. Windows has no implementation yet. Directory handles pin identity;
relative child opens validate a single canonical basename and refuse symlinks.
Nonblocking opens let the adapter reject FIFOs and other nonregular entries
before a read can block. Fresh descriptors move directly into Rust File owners,
including on classification/error paths, with close-on-exec enabled.

Bounded file reading preserves arbitrary bytes, permits empty files at a zero
ceiling and reads at most one extra byte to detect an exceeded limit. It checks
the limit before growing output and uses fallible Vec allocation. An injected
reader verifies exact requests, interrupted-call retries, IO failures and
rejection of a broken reader's excessive returned count. Output length is
bounded; allocator capacity and whole-process RSS are separate contracts.

Real scratch fixtures cover a selected directory renamed and replaced by an
outside symlink, symlink and FIFO refusal, invalid names, binary files and exact
length ceilings. Independent Linux kernel readback checks descriptor counts
over repeated success/error paths and close-on-exec flags. Four initial tests
failed against stubs. The final Linux run passes seven platform tests, sixty
core tests, four Release controls and two C-boundary controls through Nix.
The kernel fixture is Linux-specific; six tests are required on macOS, whose
native execution remains unqualified. All three Nix-system configurations
evaluate. This layer does not yet capture metadata or publish output trees.

The owner-directed GitHub Actions CI disable was verified through GitHub's
workflow API; `.github/workflows/ci.yml` remains intact. Mechatron remains the
active service. The README now keeps its canonical Mechatron badge and the
contract rejects an advertised GitHub CI badge. That contract failed against
the former README and passed after the badge change; the retained workflow's
`./test` command is still checked.

The complete suite validates the combined CI-documentation/filesystem tree.
It passed in 177.44 seconds: 11.25 for Nix preparation/checks and 166.19 for
host admission, setup and execution. Fresh file growth took 30.19 seconds.
Encode on one core used the policy's automatic retry after sample variation
made its first correct result inconclusive; the other three cases used one
attempt. The [original diagnostic and succeeding result](../benchmarks/rust-file-growth-20261106-directory-capability-retry.ndjson)
are retained. All final ratios pass unchanged bounds, and cohorts remain
unbaselined. The CI-documentation and filesystem changes are separate commits;
their combined final tree received full host validation. Production entry
points, Windows support and native macOS qualification remain pending.

## Rust entry inspection and symlink reads, 2026-11-06

The filesystem adapter can inspect a child without following a symlink and
read raw symlink bytes through the already-open parent directory. Inspection
returns a closed file/directory/symlink/other kind, portable permission bits,
length and device/inode identity for hardlink detection. Special permission
bits are excluded; symlink mode is the format's canonical 0777. Inspection
and subsequent opens are separate observations, and opened handles still
validate their actual kind.

Symlink reads use fallible allocation and a caller byte ceiling. A buffer
equal to the returned length may be truncated, so the reader grows it and
allows one extra byte to distinguish an exact-limit result from an exceeded
limit. It does not trust a prior stat size. Binary targets remain byte buffers;
the core applies target grammar and containment with the full entry path.

Three initial tests failed against stubs while the existing seven passed.
Scratch fixtures compare inspection with independent standard-library kernel
metadata for files, directories, dangling links and a socket, including
hardlink identity and permission masking. Symlink cases include non-UTF-8
targets, growth past the initial buffer, exact and exceeded limits, invalid
basenames and wrong object kinds. A renamed parent replaced by an outside
symlink leaves inspection and link reads attached to the original directory.
Native execution remains qualified on Linux only; macOS and Windows remain
open migration work.

## Rust directory enumeration, 2026-11-06

The platform adapter exposes an owned directory-name stream through a pinned
parent handle. Each stream reopens the directory itself with an independent
offset, transfers its descriptor to a libc directory owner only on success,
and closes it on drop. Stream position and lifetime are independent of the
original Directory handle. Names remain raw bytes, including hidden files
and non-UTF-8 names; only dot and dot-dot are excluded. Snapshot construction
will enforce canonical path grammar and inspect actual entry kinds.

Caller ceilings bound emitted entry count and each name's byte length before
allocation. Allocation is fallible. Limit, allocation and IO errors finish the
iterator so retrying cannot skip an entry. EOF distinguishes a real readdir
error through cleared errno. The code borrows libc's terminated name without
assuming a fixed dirent record size and copies it before advancing.

Four initial Linux tests failed against stubs while the existing seven passed.
Real scratch fixtures compare names with independent standard-library readback,
check exact and exceeded ceilings, interleave two streams across parent rename
and path replacement, and retain the streams after dropping the parent handle.
Linux kernel readback checks descriptor counts across completion, early drop
and limit failures, and checks close-on-exec on the directory and stream.
An unrelated libc error is seeded before an empty-directory read to ensure
stale errno cannot turn EOF into IO failure. Native macOS execution and Windows
implementation remain pending. Enumeration is not an atomic filesystem
snapshot, and this change does not yet capture or restore metadata.

The combined inspection/enumeration tree passes the complete suite: 337.87
seconds total, with 42.83 seconds in Nix preparation/checks and 295.04 seconds
in host admission, setup and execution. Fresh file growth took 22.95 seconds
and passed unchanged limits; historical cohorts remain unbaselined. Linux
passes fourteen platform tests, sixty core tests, four Release controls and
two C-boundary controls. The macOS requirement is twelve platform tests, whose
native execution remains unqualified. The units retain separate focused Nix
checks and separate commits; this complete host run covers their combined
final tree. The earlier inspection-only run was stopped while still queued
to avoid repeating the unchanged host suites.

## Linux descriptor-based attribute reads, 2026-11-06

The experimental platform adapter reads raw attribute values and names through
a borrowed File descriptor. Attribute names retain their native namespace and
raw bytes; canonical classification belongs to the later metadata capture
layer. Values preserve arbitrary bytes and distinguish an empty value from
ENODATA. Linux uses ENODATA for an absent or inaccessible attribute. Unsupported
filesystems and other errors remain explicit IO failures.

Buffer growth handles ERANGE without trusting a prior size query. Fallible
allocation and caller ceilings bound returned bytes, and listing additionally
bounds name count. A successful xattr call returns the whole value; an
insufficient buffer produces ERANGE. The names wrapper validates termination
and nonempty native names before exposing borrowed byte slices. Name inputs
reject NUL, empty names and lengths beyond the native limit before allocation.

The initial injected buffer/parser control failed against stubs. The three
OS fixtures initially failed during setup because this Nix sandbox rejects
attribute writes with EOPNOTSUPP; those failures do not qualify a behavioral
red result for the adapter. The tests remain mandatory in the confined host
phase of `./test`, using the exact binary prepared and installed by Nix.
Nix runs the buffer/parser controls and explicitly filters the three named
OS fixtures. Host execution checks that all three are present and runs the
entire platform binary without a filter. The prepared-runner gate also requires
that binary before any suite starts.

The complete suite passes in 613.00 seconds: 50.11 seconds of Nix preparation
and checks, followed by 562.89 seconds of host admission, setup and execution.
All eighteen platform tests pass in the required host phase, including binary
attribute names/values, empty/missing values, exact limits and opened-file
identity after path replacement. The platform suite took 40 milliseconds.
The prepared-runner control rejects all 1023 invalid five-artifact sets and
three invalid Rust paths before execution; it took 9.62 seconds. Fresh file
growth took 22.52 seconds and passed unchanged limits. Historical cohorts
remain unbaselined. Attribute restoration, canonical capture integration,
macOS and Windows implementation/qualification remain pending.

## Rust native timestamps and opened-object inspection, 2026-11-06

Entry inspection now includes modification time, optional creation time and
native Darwin flags. Directory roots and already-open File objects have an
inspection path independent of their current filesystem name. The Linux GNU
adapter uses one statx call for each observation, requesting the exact required
fields plus optional creation time. It checks the returned mask and rejects
missing required fields. Unreported creation storage is ignored; a reported
zero timestamp remains present. Linux's existing native reference also uses
statx for creation time. The macOS source uses the pinned libc stat layout,
with fstat for opened objects and no-follow fstatat for children.

All native nanoseconds are validated before entering portable Time records.
The new information still precedes timestamp transport overrides. Native
metadata is an observation, not an atomic snapshot or a transaction with
later reads; opened objects retain identity after path replacement.

Two tests failed against timestamp/root/file stubs while the existing fourteen
passed. Real scratch fixtures set a pre-epoch modification time with fractional
seconds and compare it and creation time with independent standard-library
metadata. Open roots and files retain their identity after their names are
replaced with outside symlinks. A Linux response-mask control checks every
required bit, ignored unreported creation bytes, present zero creation time
and invalid nanoseconds. Seventeen Linux platform tests pass in the focused
Nix run; macOS requires fourteen, with native execution still unqualified.
The complete suite integrating attribute reads passes in 1549.70 seconds:
44.76 seconds for Nix preparation/checks and 1504.94 seconds for host admission,
setup and execution. The long admission wait is included, not attributed to
test execution. All twenty-one platform tests pass in the required host phase.
Fresh file growth took 22.75 seconds and passed unchanged limits on the first
attempt for every case; historical cohorts remain unbaselined. This qualifies
the Linux primitives, while full metadata capture/restore and native macOS or
Windows qualification remain pending.

## Rust native attribute-name mapping, 2026-11-06

The core maps logical/raw attribute names for Linux, macOS and Windows without
allocation. Forward mapping writes a terminated CStr into caller storage and
leaves that storage unchanged on failure. Inverse mapping borrows its input.
Logical Linux names acquire `user.`; the other OSes retain the logical bytes.
Native raw limits and Windows injection/UTF-8 rules match the pinned
xattr_stream policy. Raw inverse mapping is intentionally a byte passthrough,
not validation. Canonical metadata reservations remain separate, so internal
transport names are addressable without becoming legal user metadata.

The logical grammar is shared with canonical metadata validation. The Nix
oracle extracts the original mapping and companion source from the existing
pinned Zig dependency archive, whose hash is read from build.zig.zon. Neither
source is rewritten. The initial missing companion-file build failure was a
setup failure. A subsequent deliberately broken mapper fails both new tests
while all sixty existing core tests pass; restoring the implementation passes
all sixty-two. Sweeps cover every OS/class, every byte in names, native length
boundaries, reserved/native prefixes, binary/UTF-8 cases, output-buffer limits,
unchanged failure buffers and borrowed inverse results. The focused core run
took 7.80 seconds, followed by four Release, two C-boundary and fifteen platform
controls; three native attribute fixtures remain in the required host phase.
All three Nix systems evaluate. These pure policy comparisons do not qualify
native macOS/Windows filesystem execution. The complete suite remains pending.
