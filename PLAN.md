# PLAN

Completed work is retained in docs/PLAN_LOG.md; measurement details live in docs/plan_context/.

## Active

- [ ] Qualify metadata capture and restore on native macOS and Windows hosts; cross-builds establish compilation only. (context: docs/plan_context/metadata-v2.md)
	- [x] Complete the single admitted native-runner reservation without starting an additional remote build wave. (done 2026-10-14 14:53 EDT)
	- [x] Run the native macOS metadata suite in an isolated runner checkout and preserve failures or qualification evidence; 89 passed, seven Linux cases skipped at c59caee. (done 2026-10-14 14:53 EDT)
	- [ ] Resolve native-runner resource policy before scheduling additional remote build waves.
	- [ ] Add native macOS ACL and sparse-file fixtures with independent OS readback before qualifying those metadata families.
	- [ ] Locate an available Windows runner before claiming native Windows metadata qualification.
- [ ] Enforce `--max-rss-bytes` on Darwin after reproducing its limit rejection against current VM usage. (context: docs/plan_context/memory-ceiling.md)
	- [x] Verify that an 8 GiB Darwin virtual-memory ceiling can fall below initial VM size while a ceiling above current usage succeeds in isolated shell processes. (done 2026-10-14 14:43 EDT; evidence: 51acfb3)
