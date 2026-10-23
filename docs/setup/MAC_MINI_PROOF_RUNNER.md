# Approved Mac development proof and self-hosted runner

This setup gives the team two deliberately different source-development proofs:

- Franklin runs `make mac-dev-proof` while logged in to the approved Mac and
  explicitly reports whether the named primary user journey worked. Before the
  visible app smoke, the command exercises pinned Parakeet and Gemma models
  through the production source-engine entry point with network denied.
- GitHub runs the `mac-mini-proof` check as `openbridge-ci`. It can prove builds,
  tests, offline source-runtime model inference, an ad-hoc development app
  bundle, and automated launch survival. It records manual observation as
  `not_applicable`; automation must never pretend that a person saw the app.

Neither proof accepts a packaged candidate. They do **not** prove Developer ID
signing, notarization, the contents of a DMG, microphone/TCC behavior, a real
packaged Python/model runtime, long-session model behavior, or Alex's independent
acceptance. Packaged-candidate QA must repeat the required Parakeet and Gemma
checks from the signed artifact; source-runtime success cannot be carried over.

## Machine and account requirements

Use a dedicated Apple-silicon Mac with:

- macOS 14 or newer;
- Xcode 16 or newer selected with `xcode-select`;
- Swift 6 or newer and `python3` available;
- Python 3.14 and the root-owned proof runtime below, installed from the
  repository's hash-locked `requirements-lock.txt`;
- one Standard (non-administrator) account named `franklin` for interactive
  development proof; and
- one dedicated Standard account named `openbridge-ci` for GitHub Actions.

Do not use either account name as a cosmetic label for another account. The
script reads the operating-system account with `id -un` and rejects any other
value. Keep `openbridge-ci` logged in to a GUI session while the runner is
active, because LaunchServices cannot provide a meaningful app-bundle smoke
from a headless daemon session.

An administrator must approve the physical host once. Run:

```sh
sudo install -d -o root -g wheel -m 0755 "/Library/Application Support/OpenBridge"
printf '%s\n' 'franklin-mac-mini' | sudo tee "/Library/Application Support/OpenBridge/mac-mini-runner-label" >/dev/null
sudo chown root:wheel "/Library/Application Support/OpenBridge/mac-mini-runner-label"
sudo chmod 0444 "/Library/Application Support/OpenBridge/mac-mini-runner-label"
/usr/bin/stat -f '%Su %Sg %Lp %N' "/Library/Application Support/OpenBridge/mac-mini-runner-label"
```

The final command must report owner `root` and mode `444`. The marker is a local
approval control, not evidence by itself; the GitHub job also requires the
runner labels `self-hosted`, `macOS`, `ARM64`, and `franklin-mac-mini`.

## Provision the fixed source-runtime dependencies

The self-hosted checkout uses `clean: true`, which correctly deletes ignored
build state such as a repository `.venv`. The proof therefore never relies on
an ignored virtual environment surviving checkout. An administrator installs
one fixed, read-only Python 3.14 runtime outside the checkout, using the exact
hash-locked dependency file from the reviewed source SHA.

Install the approved Python 3.14 distribution first. From the exact
Openbridge-Dev checkout, run as the Mac administrator:

```sh
repository_root=$(/usr/bin/git rev-parse --show-toplevel)
runtime_root="/Library/Application Support/OpenBridge/mac-proof-runtime"
python_base="/Library/Frameworks/Python.framework/Versions/3.14/bin/python3.14"

test -x "$python_base"
sudo /usr/bin/install -d -o root -g wheel -m 0755 "$runtime_root"
sudo "$python_base" -m venv --clear "$runtime_root/venv"
sudo "$runtime_root/venv/bin/python" -m pip install \
  --require-hashes \
  -r "$repository_root/requirements-lock.txt"
lock_digest=$(/usr/bin/shasum -a 256 "$repository_root/requirements-lock.txt" | /usr/bin/awk '{print $1}')
printf '%s\n' "$lock_digest" | sudo /usr/bin/tee "$runtime_root/requirements-lock.sha256" >/dev/null
sudo /usr/sbin/chown -Rh root:wheel "$runtime_root"
sudo /bin/chmod -R go-w "$runtime_root"
sudo /bin/chmod 0444 "$runtime_root/requirements-lock.sha256"
```

The `--clear` flag is intentional: every provisioning run rebuilds the virtual
environment instead of retaining packages removed from the lock. The proof
fails before builds if the runtime or marker is not root-owned, any runtime
file is group/world writable, the interpreter is not Python 3.14, a locked
package/version is missing or different, an undeclared distribution is present
(apart from venv's permitted `pip` bootstrap package), or the lock-file SHA-256
differs. Dependency changes therefore require owner review and explicit clean
reprovisioning; a pull request cannot silently install new Python code on the
persistent runner.

## Provision the pinned public model cache

Run this once while logged in as `franklin`, and again while logged in as
`openbridge-ci`. Do not use `sudo`: each account owns a separate proof cache.
Provisioning needs internet access and several gigabytes of free disk, but the
proof itself is forced offline by both Hugging Face offline flags and the macOS
`sandbox-exec` deny-network policy.

From that account's clean Openbridge-Dev checkout, use the approved shared
runtime (not an ignored checkout `.venv`):

```sh
"/Library/Application Support/OpenBridge/mac-proof-runtime/venv/bin/python" - <<'PY'
from pathlib import Path
from huggingface_hub import snapshot_download

proof_root = Path.home() / "Library" / "Caches" / "OpenBridge" / "mac-proof"
hub = proof_root / "huggingface" / "hub"
speech_models = proof_root / "speech-models"
speech_models.mkdir(parents=True, exist_ok=True)

parakeet_revision = "55c316ecc6eca874d3aff6c5c711d37305159271"
parakeet_snapshot = Path(snapshot_download(
    repo_id="sonic-speech/parakeet-tdt-0.6b-v3",
    revision=parakeet_revision,
    cache_dir=hub,
    token=False,
))
parakeet_link = speech_models / "parakeet-tdt-0.6b-v3-mlx-bf16"
if parakeet_link.exists() or parakeet_link.is_symlink():
    if not parakeet_link.is_symlink() or parakeet_link.resolve() != parakeet_snapshot.resolve():
        raise SystemExit("Inspect the existing Parakeet proof-cache entry; it is not the approved snapshot.")
else:
    parakeet_link.symlink_to(parakeet_snapshot, target_is_directory=True)

gemma_revision = "3d9ef289111449933c22761961f16a5df237ce2a"
gemma_snapshot = Path(snapshot_download(
    repo_id="mlx-community/gemma-3-4b-it-qat-4bit",
    revision=gemma_revision,
    cache_dir=hub,
    token=False,
))
if gemma_snapshot.name != gemma_revision:
    raise SystemExit("Gemma did not resolve to the approved revision.")

gemma_snapshots = gemma_snapshot.parent
unexpected = sorted(
    path.name for path in gemma_snapshots.iterdir()
    if path.is_dir() and path.name != gemma_revision
)
if unexpected:
    raise SystemExit(
        "The dedicated Gemma proof cache contains other revisions; inspect it before proof: "
        + ", ".join(unexpected)
    )
print("Pinned public source-runtime model cache is ready.")
PY
```

The two exact revision identifiers are part of the checked proof contract. A
model upgrade therefore requires a reviewed script, test, documentation, and
Beta-validator change—not an unrecorded cache refresh. Do not put Hugging Face
tokens, private/gated models, customer audio, or transcripts in this cache.

## Protect the proof control plane before enabling the runner

The workflow, proof harness, dependency lock, and their contract tests decide
what counts as evidence. Treat them as a release trust root, not ordinary
candidate code. Merge `.github/CODEOWNERS` to the default branch, then configure
a GitHub ruleset for `main` that:

- requires pull requests and **require review from Code Owners**;
- has **no bypass** actors, including repository administrators, for proof-root
  changes;
- blocks force pushes and branch deletion; and
- requires normal source CI before merge.

CODEOWNERS is only an ownership declaration. It does not enforce review until
the server-side ruleset is active. Do not accept a Mac proof until an owner has
tested the rule with a harmless proof-path pull request and confirmed that the
author cannot approve or bypass their own change.

Create an organization runner group dedicated to this Mac. Grant the group to
`lunr-studio/Openbridge-Dev` only, select **selected workflow** access, and pin
the allowed workflow to exactly:

```text
lunr-studio/Openbridge-Dev/.github/workflows/mac-mini-proof.yml@refs/heads/main
```

Do not use a repository-scoped runner for this gate: it cannot provide the same
selected-workflow restriction. Do not activate the runner until both the
protected-main ruleset and the runner-group restriction have been independently
verified.

**Current activation blocker (2026-09-02):** GitHub's branch-protection API for
this repository returns `403 Upgrade required`, while development collaborators
still have direct write access. Consequently CODEOWNERS cannot yet make the
current `main` workflow a protected trust root. The design in this repository
is ready for review and testing, but its receipts are non-authoritative until
the organization upgrades/enables an enforceable no-bypass `main` ruleset and
removes direct-push paths. If that cannot be enabled, move the controller to a
separate owner-controlled repository with restricted write access, update the
exact workflow reference in the script and validators, and restrict the runner
group to that controller. Merely declaring CODEOWNERS or asking contributors
not to push is not an enforcement mechanism.

## Install the restricted GitHub runner

1. Sign in to the Mac's `openbridge-ci` GUI account.
2. In the `lunr-studio` organization, open **Settings → Actions → Runner
   groups**, open the already restricted proof group, choose its new
   self-hosted-runner action, then select macOS and ARM64.
3. Follow GitHub's generated download and checksum commands inside a directory
   owned only by `openbridge-ci`. Registration tokens are short-lived secrets:
   use the value shown by GitHub once and never paste it into this repository,
   an issue, a receipt, or a log.
4. Run GitHub's generated configuration command with the custom label
   `franklin-mac-mini`. Keep the default labels enabled so GitHub also assigns
   `self-hosted`, `macOS`, and `ARM64`. Confirm registration is in the dedicated
   organization runner group, not at repository scope.
5. From the runner directory, install and start the per-user launch service
   using the `svc.sh` commands GitHub prints. Do this as `openbridge-ci`, not as
   root, and confirm the runner appears online in repository settings.

The proof workflow is manual-dispatch only and its runner group accepts only
the protected-main workflow named above. Candidate source is checked out into
a separate directory; the proof harness runs from the protected control
checkout. Keep the Mac disposable and single-purpose. Do not place any of these
on the runner:

- Developer ID certificates, signing identities, notarization profiles, or
  App Store Connect credentials;
- personal Apple/GitHub credentials or personal files;
- production API/provider keys, private/unapproved model data, transcripts, or
  customer data (the two pinned public proof snapshots above are the only model
  cache exception);
- SSH keys or tokens that grant access beyond this one repository.

The self-hosted Mac job grants only read permissions: `contents: read` for the
private repository and `pull-requests: read` for live PR/review revalidation.
It disables checkout credential persistence and uses ad-hoc signing
(`codesign --sign -`), which needs no signing secret. Only the separate
GitHub-hosted jobs receive `checks: write`. Apply macOS and runner updates
promptly. When retiring the Mac, remove the runner in GitHub first,
stop/uninstall its service, remove its work directory, and remove the local
approval marker.

## Franklin's interactive proof

Start from a committed, clean checkout of the exact intended source SHA:

```sh
git status --short
git rev-parse HEAD
OPENBRIDGE_MANUAL_SCENARIO_ID=issue-123-primary-user-journey make mac-dev-proof
```

The first command must print nothing. Use a lowercase scenario identifier of at
most 64 characters containing only letters, numbers, `.`, `_`, and `-`. Name
the issue and one concrete primary journey; do not use a vague value such as
`smoke`.

The proof runs Python tests, Debug and optimized Release Swift builds, Swift
tests, pinned Parakeet load plus tiny synthetic inference, and a real pinned
Gemma cleanup inference over a synthetic non-sensitive sentence. Both model
commands invoke the current checkout's production `engine_cli.py` while an
outer macOS sandbox denies network access. Raw model input/output stays in a
temporary directory and is deleted; the receipt records only model identifiers,
revisions, runtimes, and results.

The proof then constructs a source-only ad-hoc `.app` from the optimized Release
executable and launches that bundle through macOS LaunchServices. It gives the
launched app a temporary
`CFFIXED_USER_HOME`, so the smoke must not read or change the real OpenBridge
profile. It explicitly points the app at the current checkout's `engine_cli.py`
and the root-owned, hash-locked proof Python, plus the dedicated pinned model
cache, so the source app does not depend on LaunchServices choosing the
repository as its working directory, an ignored `.venv`, or the developer's
shell environment. The bundle identifier is also unique to the source SHA and
cannot collide with the production app's identity or TCC record.

That isolated profile starts without the developer's normal settings. Prepare
only test data and model prerequisites appropriate to the named journey inside
the proof app; never weaken isolation by pointing it at a real user profile.
The receipt is a concise journey-smoke assertion, not the detailed per-criterion
evidence matrix and not Alex's independent packaged-candidate QA.

After the automated survival interval, exercise the named primary journey in
the visible app. Enter `pass` only if all four statements are true:

1. The menu-bar item is visible.
2. The primary UI opens.
3. The app remains responsive.
4. The named primary user journey succeeds.

The script then requires `observed:<exact-40-character-SHA>`. `fail`, omission,
an unsupported `not_run` value, a wrong SHA, or a missing confirmation produces
an overall failed receipt. If the proof was not run, report that plainly; do not
manufacture a pass receipt. The sanitized receipt is:

```text
.build/mac-dev-proof/mac-dev-proof-<exact-sha>.json
```

It contains platform/toolchain versions, the exact commit and clean-worktree
state, nonzero Python/Swift test counts, individual check results, sanitized
source-runtime model metadata/results, the scenario identifier, and Franklin's
SHA-bound confirmation. It contains no transcript, raw model/test/app output,
secret, or user-data path.

### Publish Franklin's authenticated attestation

A local JSON file is not independently attributable to Franklin: anyone with
filesystem access could copy or replace it. After inspecting the successful
receipt, Franklin must post it from his own allowlisted GitHub account to the
candidate pull request. GitHub's authenticated comment author is the external
identity evidence; the receipt's `github_provenance` object deliberately
contains eleven null values because a manual proof must not fabricate Actions
metadata.

On a successful real developer proof, the same trusted script writes a
digest-bound, byte-exact, ready-to-post comment body here:

```text
.build/mac-dev-proof/franklin-attestation-<exact-sha>.md
```

It contains the marker `openbridge-franklin-mac-dev-proof-v1` and an exact
six-key JSON envelope: `schema_version`, `attestation_type`, `target_sha`,
`receipt_sha256`, `scenario_id`, and `receipt_base64`. The base64 value is the
exact sanitized receipt bytes—not a test log or transcript. First ensure the
pull-request head is still the proven SHA, verify the authenticated account,
read the generated body, and only then post it:

```sh
pr_number=123
target_sha=$(/usr/bin/git rev-parse HEAD)
attestation_path=".build/mac-dev-proof/franklin-attestation-${target_sha}.md"
test "$(gh pr view "$pr_number" --json headRefOid --jq .headRefOid)" = "$target_sha"
gh auth status
test "$(gh api user --jq .login | /usr/bin/tr '[:upper:]' '[:lower:]')" = "franklinlunr"
/usr/bin/less "$attestation_path"
gh pr comment "$pr_number" --body-file "$attestation_path"
```

Franklin must read the generated body before posting and must not delegate the
comment to a bot or another team member. The release gate must retrieve the
comment through GitHub, require the exact marker
`openbridge-franklin-mac-dev-proof-v1`, require its authenticated author to be
`franklinlunr`, require the live PR head and `target_sha` to
equal the candidate SHA, decode `receipt_base64`, recompute
`receipt_sha256`, and strictly revalidate the embedded receipt. If the PR head
moves, the observation, receipt, and comment are stale and must be repeated.

## Automated `mac-mini-proof` check

`.github/workflows/mac-mini-proof.yml` is a protected-main control workflow. It
runs only through `workflow_dispatch`; its input `target_sha` is the candidate,
while GitHub's run/head SHA is the protected control commit. The workflow
checks out those two commits separately and runs the control commit's harness
against the exact candidate source. The job/check name is exactly
`mac-mini-proof`. A successful run uploads exactly one sanitized receipt
artifact named:

```text
mac-mini-proof-<exact-sha>
```

Push the frozen candidate SHA so GitHub can fetch it, then dispatch the control
workflow from protected `main`:

```sh
target_sha=$(git rev-parse HEAD)
gh workflow run mac-mini-proof.yml \
  --repo lunr-studio/Openbridge-Dev \
  --ref main \
  -f target_sha="$target_sha"
```

The workflow rejects any non-`main` dispatch, malformed candidate/control SHA,
mismatch between `github.sha` and `github.workflow_sha`, or dispatch whose
control SHA is no longer the live protected `main` tip when hosted preflight
authorizes the target. Because the persistent Mac may remain queued after that
preflight, its first step queries protected `main` again with a read-only token
and fails before either checkout if the control SHA has become stale. For an
approved-PR target, that same step also requires the PR to remain open against
`main` at the exact target head and the receipt's named approver's latest review
to remain `APPROVED` on that SHA. A dismissal, superseding review, closed PR, or
moved head fails before candidate code. Re-dispatch from `main` after restoring
the required current state. Its exact workflow reference is
`lunr-studio/Openbridge-Dev/.github/workflows/mac-mini-proof.yml@refs/heads/main`.
Do not require the Actions run `head_sha` to equal the candidate: for this
control-plane design, `head_sha` is the protected control SHA. Candidate
identity is bound by the workflow input, checkout, receipt `commit_sha`, and
artifact name.

Before the persistent Mac is scheduled, a GitHub-hosted preflight authorizes
the target. It accepts either the exact current `main` SHA (only meaningful once
`main` is genuinely protected) or the exact head of one open same-repository PR
to `main` with a current formal `APPROVED` review on that same commit from the
configured Alex or Trishan account. Moving the PR head invalidates the approval.
A later review state—including dismissal—replaces that reviewer's earlier state.
This prevents Franklin from dispatching arbitrary or no-longer-approved branch
code merely because he can see the workflow button.

The JSON inside is
`.build/mac-mini-proof/mac-mini-proof-<exact-sha>.json`. Its `proof_type` is
`ci_automated`, `account` is `openbridge-ci`, `test_mode` is `false`, and both
the flat and nested manual result are `not_applicable` with null tester,
confirmation, and scenario. The check must fail if the source changes during
the run, a test count cannot be verified, either pinned local model cannot
perform its required offline source-runtime inference, the app exits during the
smoke, or the account/host/toolchain does not match the approved configuration.

Its `github_provenance` object records `event_name`, the exact `workflow_ref`,
equal `workflow_sha` and `control_commit_sha`, positive `run_id`, `run_attempt`,
and `check_run_id`, job `mac-mini-proof`, and the hosted preflight's
`target_authorization`, `pull_request_number`, and `approved_by`. For a current
protected-main target, the latter two values are null; for a reviewed PR they
are a positive PR number and the lowercase authorized reviewer login.

The hosted preflight creates an explicit check run named `mac-mini-proof` on
the candidate SHA, and a separate GitHub-hosted finalizer marks it successful
only after the Mac job and receipt upload pass. Before publishing success, that
finalizer re-queries protected `main` and, for reviewed targets, the live PR head
and latest authorized review states. It rejects otherwise successful evidence
if the controller, PR, head, or named approval changed during proof. If the
Actions API cannot bind exactly one `mac-mini-proof` job to the run, the
finalizer uses the already-known check ID to complete it with `failure` and a
run-level diagnostic link instead of returning early and stranding it as
`in_progress`. The Mac job has only `contents: read` and `pull-requests: read`;
the `checks: write` token is never placed on the persistent runner before or
after candidate code.
Artifact ID and GitHub's artifact digest exist only after upload, so embedding
them in the artifact would be circular.
The Beta gate must obtain those values from GitHub's authenticated
run/job/check/artifact APIs and bind them externally to this receipt and
candidate SHA.

## Residual trust boundaries

These controls make substitution visible; they do not create mathematical
proof that a product works. Acceptance still trusts the protected-main
review/ruleset administrators, Franklin's GitHub account and honest observation,
the root administrator and physical Mac, the GitHub Actions control plane, the
pinned action commits, and the reviewed test/build interfaces in candidate
source. Revision-named model cache directories are exact resolver inputs but
are not cryptographic hashes of every model byte. Most importantly, this gate
tests a source-built ad-hoc app and source-runtime models. The independently
packaged, signed/notarized DMG must still undergo Alex's packaged-engine model,
TCC/microphone, install, and primary-journey QA.

The candidate's reviewed build/test commands still execute under the
`openbridge-ci` account. Therefore this is not a safe service for adversarial
source: arbitrary candidate code could try to leave a process behind or alter
same-account workspace state. The harness verifies its control checkout again
after candidate execution, no write/signing secret is present on the Mac job,
and hosted approval limits which SHA may run, but those are detection and
containment layers rather than a full virtual-machine boundary. Investigate any
anomalous run and rebuild/reimage the dedicated runner before trusting a later
artifact; never run an unreviewed SHA merely to see what happens.

## Test the gate logic without creating evidence

Any developer can run:

```sh
make mac-dev-proof-test
```

The workflow contract tests execute the embedded `github-script` JavaScript
when a system `node` executable is available, including normal GitHub-hosted CI.
They skip those two executable-JavaScript checks with an explicit reason when
system Node.js is absent. Do not install Node solely for `mac-dev-proof`:
GitHub Actions supplies the pinned action's own Node runtime on the runner, and
the approved Mac runtime contract does not otherwise depend on system Node.js.

These unit tests use fake platform commands in disposable repositories, so
they work away from the approved Mac. Every resulting fixture receipt has
`test_mode: true`. Candidate/Beta validation must always reject such a receipt.
