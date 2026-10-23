# Rust migration

The requested direction is a Rust build of the complete product: file and directory cores, filesystem metadata adapters, the C ABI implementation, and the CLI. The existing Zig/C implementation and tests are independent oracles during migration. This follows the 2026-10-23 direction from BDFN (Benevolent Dictator For Now). A later clarification leaves combined Zig/Rust packaging under investigation; production entry points stay unchanged while that boundary is settled.

The source reference is preserved at `zig-zstdz-oracle-20261023` (`62973d6`). The earlier CDC engine remains on `old-cdc-plus-compression-probe-design`. The migration keeps ZDIF v4, DIFZTREE v2, BLAKE3 identities, staged verification, and the five supported platform targets. Byte-identical compressed frames are not required; reconstructed bytes, canonical metadata, and declared failure behavior are.

## Codec investigation

The production format needs an encoder and decoder with an external raw prefix, not just a decoder or a trained small dictionary. It also needs level 9, explicit window control through 2 GiB, long-distance matching, and bounded hostile-input decoding. A dependency's own round trip cannot establish interoperability or that it actually uses the source prefix.

| Candidate | Evidence from primary sources | Remaining gate |
| --- | --- | --- |
| [rusty_zstd 0.4.1](https://docs.rs/rusty_zstd/0.4.1/rusty_zstd/) | Pure Rust, MIT/Apache-2.0, no default dependencies; explicit prefix encode/decode, level/window parameters and LDM; Rust 1.85 minimum. | Cross-apply and prefix-reach checks pass below; bounded decoding and performance remain unqualified. |
| [structured-zstd 0.2.5](https://github.com/structured-world/structured-zstd) | Pure Rust, Apache-2.0; raw-content dictionaries, LDM and a C ABI; Rust 1.92 minimum. | Its encoder window bound is 1 GiB, below difz's current 2 GiB bound. Prefix interoperability is not yet qualified here. |
| [zstandard 0.1.9](https://github.com/stephenberry/zstandard) | Pure Rust, MIT/Apache-2.0; raw-content dictionaries, prepared handles, streaming, bounded output and strict single-frame decoding options. | Encoder window bound is 128 MiB; Rust 1.96 minimum exceeds this flake's Rust 1.94.1. Raw input beginning with dictionary magic needs separate qualification. |
| [zenzstd 0.1.0 source](https://github.com/imazen/zenzstd/blob/main/README.crates.md) | Pure Rust, MIT; levels 1–15 are documented as stable, 16–22 have a documented corruption defect. | A matching crates.io package was unavailable during this investigation. Level 9 is in the documented stable range; prefix/window behavior still needs qualification. |
| [ruzstd 0.9.0](https://docs.rs/ruzstd/0.9.0/ruzstd/encoding/) | Pure Rust encoder and decoder with a custom matcher interface. | Its supplied encoder does not establish parity with difz's level-9 prefix matcher. |
| [zstd 0.13.3](https://docs.rs/zstd/0.13.3/zstd/) | Rust bindings to the native zstd implementation, with prefix and parameter APIs exposed through zstd-safe. | Retains native C code; it is a fallback option, not evidence of a pure Rust compressor. |

Maintaining a new codec against upstream zstd changes is a stated concern. Reuse an existing implementation before proposing a rewrite. Combined Zig/Rust packaging is being investigated as another path, so a pure Rust compressor is not an accepted requirement. If an independent Zstandard rewrite becomes necessary, it belongs in a separate public repository, not inside difz. No such rewrite or publication is currently planned.

The encoder bounds above come from the published crates' recorded revisions: [rusty_zstd](https://github.com/Remade-With-Rust/rusty_zstd/blob/cd41258855309fd3dd77c2adf992fdfe4d401666/crates/rusty_zstd/src/params.rs) clamps 64-bit window logs to 31, [structured-zstd](https://github.com/structured-world/structured-zstd/blob/fa09f7ca0d7b662d1087d1f16321af20a17b0370/zstd/src/encoding/parameters.rs) limits them to 30, and [zstandard](https://github.com/stephenberry/zstandard/blob/64d8d8f03c3b682081956417ee8689a854885a96/src/encode.rs) limits its exposed encoder window to 27. These are encoder capability differences; default decoder limits and how much history is effectively searched are separate questions. Accepting a parameter does not by itself qualify every input at that scale.

Rusty_zstd's one-shot prefix decoder accepts a window cap but has no output-limit argument. Its separate bounded one-shot decoder does not accept a prefix. Production adoption therefore still requires a bounded streaming-prefix adapter or an upstream API extension, followed by hostile-input tests. Passing cross-apply checks alone does not establish that resource contract.

Only Rusty_zstd has been executed in this investigation. Structured-zstd 0.2.5 and the other candidates above were reviewed from their published sources; they have no local interoperability or performance result. The Rusty_zstd tests exercise eight input pairs across three test functions. No replacement codec is selected for production.

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
