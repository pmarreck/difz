# Intent

difz creates binary deltas for files and directory trees. It serves callers that distribute changed artifacts, including software updaters, and callers that use its C library directly.

Patches should reduce transfer size without excessive creation time, application time, or memory use. Reconstruction must reject the wrong source and verify the completed target. Directory apply must construct and independently verify a new tree before publishing it.

The functional core operates on in-memory values behind a C FFI. Filesystem adapters own traversal, metadata transfer, and staged writes. The CLI exercises that same public boundary. Supported metadata and platform limitations belong in the format specifications; unsupported fidelity must not be implied.

The file engine delegates byte matching and compression to Zstandard source-prefix frames while preserving BLAKE3 identities and DIFZTREE. Architectural simplicity is a reason for this choice even where the preserved content-defined chunking engine wins individual workloads. Comparative measurements expose the costs and gains across file sizes and edit patterns, with real release pairs as separate evidence.

Keep production file encoding and application single-threaded for now. Encoding retains one source-prefix frame per file, preserving compression across newly introduced target data. The independent-frame parallel prototype and its measurements remain available for future review; they are outside the current production direction. See [the measured tradeoffs and decision](docs/plan_context/parallel-zstd-apply.md).

The requested Rust build covers the CLI, library cores, C ABI implementation, and filesystem adapters. The selected codec remains zstdz, statically linked through its C API; the owner accepts its native-code process-failure risk. Rewrite difz itself in Rust while retaining the existing Zig/C implementation as a validation oracle. Existing Rust Zstandard codecs were evaluated; no codec rewrite is planned. See [the Rust migration](docs/plan_context/rust-port.md) for scope, sequence, and qualification requirements.

There are no upstream consumers requiring compatibility with old APIs or formats. The project remains in break mode: simplify the current design without maintaining compatibility branches. DIFZTREE v2 is the only supported directory format, including metadata-free snapshots. Completing its remaining metadata scope follows the file-engine decision.

Updater deltas reconstruct publisher-produced bytes. Clients do not re-sign applications. macOS directory updates remain outside the qualified updater path until a supported bundle profile or archive representation passes the required checks.

Correctness is checked through `./test`, including the installed C consumer and CLI adapters. Performance claims must identify the engine revision, inputs, build, resource measurements, and reconstruction checks, and remain limited to the workloads measured.

See [PLAN.md](PLAN.md) for active work, [PROJECT_SPEC.md](PROJECT_SPEC.md) for the implementation contract, [the updater contract](docs/plan_context/mecha-delta-contract.md), and [metadata scope](docs/plan_context/metadata-v2.md).
