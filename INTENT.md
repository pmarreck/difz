# Intent

difz creates binary deltas for files and directory trees. It serves callers that distribute changed artifacts, including software updaters, and callers that use its C library directly.

Patches should reduce transfer size without excessive creation time, application time, or memory use. Reconstruction must reject the wrong source and verify the completed target. Directory apply must construct and independently verify a new tree before publishing it.

The functional core operates on in-memory values behind a C FFI. Filesystem adapters own traversal, metadata transfer, and staged writes. The CLI exercises that same public boundary. Supported metadata and platform limitations belong in the format specifications; unsupported fidelity must not be implied.

The current file-engine direction delegates byte matching and compression to zstdz while preserving BLAKE3 identities and DIFZTREE. Architectural simplicity is a reason to prefer this direction even if the preserved content-defined chunking engine wins individual workloads. Comparative measurements should expose the costs and gains across file sizes and edit patterns, with real release pairs as separate evidence.

There are no upstream consumers requiring compatibility with the old API. Interface changes may simplify the current design. Completing the remaining DIFZTREE v2 metadata scope follows the file-engine decision.

Updater deltas reconstruct publisher-produced bytes. Clients do not re-sign applications. macOS directory updates remain outside the qualified updater path until a supported bundle profile or archive representation passes the required checks.

Correctness is checked through `./test`, including the installed C consumer and CLI adapters. Performance claims must identify the engine revision, inputs, build, resource measurements, and reconstruction checks, and remain limited to the workloads measured.

See [PLAN.md](PLAN.md) for active work, [PROJECT_SPEC.md](PROJECT_SPEC.md) for the implementation contract, [the updater contract](docs/plan_context/mecha-delta-contract.md), and [metadata scope](docs/plan_context/metadata-v2.md).
