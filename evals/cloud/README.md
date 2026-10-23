# OpenBridge Cloud evaluation harness

CLOUD-01 delivers **Component tooling**. Read [EVAL](../../EVAL.md),
[architecture](../../ARCHITECTURE.md). Internal execution planning is maintained separately.
Node 20 or newer is required (CI uses Node 22); Playwright 1.64.0 is locked.
No browser download is needed: these tests use Playwright's HTTP request client.

```sh
npm ci --prefix evals/cloud
npm test --prefix evals/cloud
node evals/cloud/cli.mjs --lane D
```

For every code change the **full accumulated regression** is both `make test`
and `npm test --prefix evals/cloud`. Existing Makefile/tests/workflows were not
edited. A new CI job runs harness controls and reports alongside existing source
CI and CodeQL. No Cloud service, production backend, app integration or release is
included. Never interpret a green harness CI job as Cloud acceptance.

## What runs

- 54 Node checks verify fixture fingerprints, the fixed clock, UTF-8 ID bounds,
  source identity, protected inputs, fact/citation grading, setup classification,
  retry reporting, current-run report integrity and separation of D/R/N/C/A.
- Five Playwright checks exercise localhost HTTP ingestion, a controlled readiness
  barrier, idempotent replay/conflict, invalid segment IDs, the exact live question
  and snapshot, and an HTTP JSON-RPC tool call. Every test has a fresh ephemeral
  loopback server, independent in-memory state and teardown. No provider is called.
- Three goldens use the checked-in original segment IDs/text. `expectations.json`
  defines **normalized contract observations**, not additional product API fields.
  The mock service provides those observations; future staging adapters must
  demonstrate that normalization preserves actual evidence and be human reviewed.

The reference's in-memory storage and fixture identity header are explicit test
doubles. They do not exercise Firestore, deployed membership/IAM/OAuth, provider
privacy or model quality. The readiness notification is a **client intent** only;
it proves no Notification Center display. The MCP check uses an HTTP client,
not actual Codex. Retrieval responses are fixed; ranking, history seeding and
semantic retrieval quality are not implemented or accepted by this reference.

The grader checks required normalized facts, unknown/duplicate facts, original
meeting/revision/segment identities, exact source quotations, provisional state
and explicit forbidden prose. Normalized facts use fixed fixture statements;
free-form model prose may vary in a real lane. This grader does **not** prove
semantic entailment of arbitrary prose or prompt-injection resistance. Those
require real-target checks and independent review under the feature issues.

## Failure evidence and lane boundaries

```sh
node evals/cloud/cli.mjs --lane D --target absent
node evals/cloud/cli.mjs --lane R
node evals/cloud/cli.mjs --lane N
node evals/cloud/cli.mjs --lane C
node evals/cloud/cli.mjs --lane A
```

Exit 0 means the selected Component checks passed; exit 1 means executed checks
failed/flaked/skipped; exit 2 means setup/lane is blocked. Invalid command syntax
is a CLI usage error, never baseline proof. The absent reference answers health
successfully but returns 501 for feature routes. All five contract checks must
fail with that response, and the report must confirm `negative_control.demonstrated`.
This is a **failure-detector negative control**, not a production feature baseline
or a claim that absent features were implemented after a red run. Its failed output
is retained. Product baselines remain blocked until a real authorized target and
its setup are available; feature issues must obtain their own initial failures.

R is blocked pending an implemented, isolated staging adapter, authenticated
seeding/cleanup, service/config/model identities and approved privacy/retention
controls. N requires native automation or named operator evidence; C requires
Alex's actual Codex/OAuth invocation; A requires the exact signed candidate,
Alex QA and Trishan acceptance. They deliberately cannot reuse D results. See
[native procedures](native-journeys.md) and [Codex procedure](codex-journey.md).
No credential environment variable can silently activate real uploads in this
version; these lanes make no network calls and honestly report their blockers.

## Frozen inputs and evidence

`contract-lock.json` freezes fixture files, acceptance assertions, harness/grader
code, dependency manifests and configuration at initial creation. It is never
automatically rewritten. Any later edit to existing tests, fixtures, harness,
grader or the lock requires **explicit human review and approval before editing**
under [AGENTS](../../AGENTS.md). Do not regenerate the lock to hide a mismatch.
New feature test additions follow the specification/baseline sequence and must
have reviewed protection/version updates. Runtime changes also require a new
exact-candidate evaluation; old evidence cannot be carried forward.

Each CLI invocation writes an independent UUID run directory under ignored
`.local-evidence/cloud/` (or an explicit `--out` directory). `report.json` retains
source Git SHA, dirty flag, full source-tree digest, evaluation file hashes,
fixture/grader versions, OS/runtime, frozen clock, target/service/model identities,
the complete Node/script argv (including repeated options and `--out`), working
directory, and first-attempt outcomes/durations/retries/skips. Primary setup findings
remain alongside secondary exit/report mismatches. `playwright-{run_id}.json`
retains raw synthetic-only check output. A reused explicit output directory gets a
fresh raw filename for each run; the report retains the child exit status, signal
and error code. Missing/malformed reports, child process failures and contradictory
exit/report outcomes are blocked. Previous passing output cannot become evidence
for a later failed execution. The runner also requires the exact five unique
file/title/project contracts, consistent attempt/spec/summary status and counts,
and report/attempt timestamps within the current child execution window (100ms
allowance for reporter clock rounding). Selected subsets are blocked. These
controls assume a trusted local runner and do not attest execution against a
malicious child or compromised host that can forge all report fields.
No credentials or real meeting data are
used. CI artifacts retain reports for 30 days; baseline/final summaries and hashes
must also be posted to the canonical issue for durable traceability.

`component_status` and `product_status` are separate. `cases.json` retains all
sixteen specified scenarios and requirements. `reference_checks` records the five
executed mock checks; **product specified/implemented/run/passed remain separate
and false beyond specification**. A partial N05 ID check cannot pass the entire
provider/storage-failure case. Per-test retries default to zero; a retry-only
pass is flaky and the CLI exits nonzero. Setup or missing reports never become
valid absent-behavior proof.

The initial creation receipt records execution of the newly authored checks and
the negative control. It does not manufacture a red-to-green product history.

Independent evaluation found and reproduced a stale-output false pass in the
initial runner. The owner explicitly approved the concrete four-file repair
before its application on 2026-10-10. Ten permanent runner-integrity checks were
authored and executed against the unchanged initial candidate first: seven failed,
including the decisive `expected exit 2, actual exit 0` after an early child exit.
The approved repair preserves golden expectations and adds current-run/exit-status
validation. Its baseline and approval identity are retained on CLOUD-01. This is
a genuine harness-repair baseline, separate from unimplemented Cloud behavior.

A second fresh evaluation found that a genuine one-contract filtered run could
satisfy the wrapper, and that copied old content or inconsistent summary metadata
was not rejected. Fourteen new permanent controls all failed against that unchanged
candidate. The owner approved the exact second repair before application on
2026-10-10: frozen contract inventory and raw report consistency/freshness checks.
The original ten controls and all golden expectations remain unchanged. Both
independent failed verdicts and approval identities are retained on CLOUD-01;
only the fresh final-revision verdict supports the resulting Component claim.

Automatic GitHub review subsequently found that the retained command omitted
output/repeated options and that a secondary mismatch could replace a primary
setup blocker. Both new reporting controls failed against the unchanged reviewed
candidate. The owner approved the exact three-file repair before application on
2026-10-10. It records actual argv/cwd and accumulates findings, preserving all
previous assertions and golden facts. Approval and baseline identity are retained
on CLOUD-01; the repaired revision requires fresh independent/full-suite evidence.

## References

Checked 2026-10-10: [Playwright API testing](https://playwright.dev/docs/api-testing),
[configuration](https://playwright.dev/docs/test-configuration) and
[JSON reporting](https://playwright.dev/docs/test-reporters).
