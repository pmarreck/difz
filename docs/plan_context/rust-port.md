# Rust migration

The requested direction is a Rust build of the complete product: file and directory cores, filesystem metadata adapters, the C ABI implementation, and the CLI. The existing Zig/C implementation and tests are independent oracles during migration. This follows the 2026-10-23 direction from BDFN (Benevolent Dictator For Now). A later clarification leaves combined Zig/Rust packaging under investigation; production entry points stay unchanged while that boundary is settled.

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

The complete entry point still has older host-side Zig and Rust-FFI preparation paths. Their Nix migration and preventive host execution boundary remain open under build conformance; this codec change does not establish full-project conformance or a passing new execution of all host-only checks.

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

The remaining owner decision is the implementation boundary: port the core and CLI while retaining zstdz through its C ABI, port only the CLI over the existing Zig core, or port everything including the codec dependency to Rust. The static-link proof establishes a local packaging mechanism, not the final choice or a five-platform release.

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
