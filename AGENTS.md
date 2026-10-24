# Contributor agent instructions

Read README.md, CONTRIBUTING.md and DESIGN.md before relevant changes. Explain important choices in plain language; the maintainer is learning development.

- Keep this repository application-source only: no website, secrets, real recordings/transcripts, model weights, generated runtimes, app bundles or DMGs.
- Preserve existing tests, fixtures, harnesses, expected outcomes and skips. Every edit to them requires explicit human review of the concrete diff and approval before application. Do not weaken a test to obtain a pass.
- For new behavior, establish a meaningful failing test before implementation. Preserve the approved contract, run focused tests during development and `make test` at merge readiness, and report unavailable native/provider checks explicitly.
- Obtain fresh-context independent programmatic evaluation of the exact candidate; inspection or a mock pass does not prove a real provider or native user journey.
- Record the full commit SHA with results. Distinguish source builds, native behavior and official signed application verification. Do not claim a check that was not executed.
- Do not add private infrastructure access or attach self-hosted runners to this public-source repository. The retained Mac proof scripts/workflow definitions and setup document are legacy test-contract inputs; their fixtures do not establish public infrastructure or public acceptance gates.
- At the end of multi-step work, append a concise entry to a local ignored `claude_feedback.md`; do not publish internal session logs.
- Update third-party notices/provenance when dependencies or assets change. Keep official signing, notarization and binary distribution separate.

## CI cadence — owner-approved 24 October 2026

- Develop with a draft PR and focused local checks; batch fixes before marking
  it ready. Routine GitHub CI jobs allocate no runners while the PR is a draft.
- Mark ready for review after local verification. Existing required suites run
  for ready PRs when opened, updated, reopened or marked ready. Required checks
  must pass on the final candidate before merge; a skipped draft check is not
  acceptance evidence. Return to draft for another substantial development cycle.
- Routine suites no longer repeat automatically on a `main` push. Scheduled
  security scans and separately authorized manual proof/release workflows retain
  their existing triggers. A changed merge result or relevant execution input
  still needs affected verification; do not claim that earlier evidence covers it.
- Cancel obsolete work only within the same PR and workflow, including when
  converting back to draft. Preserve all test commands, required check names,
  permissions, independent review and platform/release acceptance requirements.
- Native changes still require focused local Mac checks and the existing Mac
  suites at merge readiness. This cadence grants no deployment, signing,
  publishing, privileged installation or account/access change authority.
