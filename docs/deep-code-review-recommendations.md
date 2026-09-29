# deep-code-review skill recommendations (difz 2026-09-04 audit)

Do not edit the shared skill from this repository. These notes are for a
separate skill-implementation request.

- Require an installed-package consumer, not only the in-repo CLI.
- Require a resource model: input bytes, distinct vs repeated chunks,
  candidate count, operation count, and page overhead are different axes.
- Label source-proven vs runtime-proven, and Debug vs ReleaseFast, on every
  panic or crash claim.
- Put complexity controls in the unit suite; keep timing history in `./bm`.
- A content filter that blocks a reviewer's final answer is not evidence of
  a malicious request. Durable on-disk notes survive; the chat UI may not.
- Do not treat "the suite is green" as coverage of I/O fail-closed, FFI
  install contracts, or Windows-only paths.
- Interrupted sub-reviews (memory-safety, coverage, error-handling, futile
  tests) must be recorded as incomplete, not implied green.
