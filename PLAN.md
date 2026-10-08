# PLAN

Completed work is retained in docs/PLAN_LOG.md; measurement details live in docs/plan_context/.

## Active

- [x] Remeasure the cached ISO pair warm with difz and the pinned CLI in single-thread and T1 modes; verify every reconstruction and record all three samples. (done 2026-10-08 09:49 EDT; context: docs/plan_context/engine-comparison.md)
- [x] Isolate the CLI thread-mode effect on the same zstdz pin; the prior CLI wall-time advantage was not reproduced, so keep difz compression single-threaded. (done 2026-10-08 09:49 EDT; context: docs/plan_context/engine-comparison.md)
- [x] Commit the verified comparison on this branch; preserve the CDC branch and do not push. (done 2026-10-08 09:49 EDT)
- [ ] If the zstd engine is adopted, preserve the CDC tip as old-cdc-plus-compression-probe-design and make the tested zstd implementation yolo; keep both local unless publication is requested.
- [ ] Immediately after the engine decision, complete the remaining DIFZTREE v2 metadata work; API compatibility with the old design is not required because there are no upstream consumers. (context: docs/plan_context/metadata-v2.md)
	- [ ] Preserve symlink metadata that cannot be stored natively in a parent-directory transport attribute, with canonical readback and a compromise warning.
- [x] Branch a per-file zstd --patch-from engine that keeps BLAKE3 checks and DIFZTREE outside and drops CDC plus compression selection. (done 2026-10-08 12:31am EDT)
- [x] Remeasure the branch on the same ISO pair. Keep the CDC engine reachable from the pre-change commit if the branch wins. (done 2026-10-08 12:36am EDT)
- [ ] Make `--max-rss-bytes` enforceable on Darwin. `setrlimit(RLIMIT_AS)` returns EINVAL, so difz exits before create. The PDFPals run stayed under 8 GiB when observed with `/usr/bin/time -l`. (context: docs/plan_context/mac-archive-oracle.md)

## Recently completed (2026-09-29)
