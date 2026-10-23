# Contributor agent instructions

Read README.md, CONTRIBUTING.md and DESIGN.md before relevant changes. Explain important choices in plain language; the maintainer is learning development.

- Keep this repository application-source only: no website, secrets, real recordings/transcripts, model weights, generated runtimes, app bundles or DMGs.
- Preserve existing tests, fixtures, harnesses, expected outcomes and skips. Every edit to them requires explicit human review of the concrete diff and approval before application. Do not weaken a test to obtain a pass.
- For new behavior, establish a meaningful failing test before implementation. Preserve the approved contract, run focused tests and `make test`, and report unavailable native/provider checks explicitly.
- Obtain fresh-context independent programmatic evaluation of the exact candidate; inspection or a mock pass does not prove a real provider or native user journey.
- Record the full commit SHA with results. Distinguish source builds, native behavior and official signed application verification. Do not claim a check that was not executed.
- Do not add private infrastructure access or attach self-hosted runners to this public-source repository. The retained Mac proof scripts/workflow definitions and setup document are legacy test-contract inputs; their fixtures do not establish public infrastructure or public acceptance gates.
- At the end of multi-step work, append a concise entry to a local ignored `claude_feedback.md`; do not publish internal session logs.
- Update third-party notices/provenance when dependencies or assets change. Keep official signing, notarization and binary distribution separate.
