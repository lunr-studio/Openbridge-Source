# Privacy, Storage, Permissions, and Networking

Openbridge capture/transcription are local-first. Existing explicitly selected
BYOK cloud cleanup/research can send authorized text to the selected provider;
separate web research can send approved queries to Brave. These permissions do
not authorize shared meeting upload. The proposed hosted Openbridge Cloud path
is specified in [PRD.md](../PRD.md) and [ARCHITECTURE.md](../ARCHITECTURE.md); this
foundation change does not implement or deploy it.

## Local data

Depending on the user’s settings, the app may store:

- preferences in macOS user defaults
- dictation history, snippets, and custom dictionary data under the `OpenBridge` Application Support area
- upstream model files in local cache directories
- temporary audio while a transcription is active
- meeting manifests, segmented audio, canonical typed transcripts, and derived
  post-meeting cleanup revisions under the `OpenBridge` Application Support area

Temporary audio is removed after the flow completes. The app exposes controls for local history and dictionary data. Users remain responsible for clipboard contents and data pasted into other applications.

## macOS permissions

| Permission | Purpose |
| --- | --- |
| Microphone | capture spoken audio |
| Accessibility | read or replace selected text and paste into the active app |
| Input Monitoring | detect configured global shortcuts |
| Automation, when macOS requests it | interact with another app for paste behaviour |

macOS associates permissions with a particular app identity and location. Source-run behaviour can differ from an independently installed official app.

## Network activity

| Trigger | Destination | Data |
| --- | --- | --- |
| first use or model change | Hugging Face model providers | model metadata and weights are downloaded |
| user enters a supported media URL | the media host through yt-dlp | the requested media stream is fetched |
| dependency setup | Python package indexes or configured mirrors | software packages are downloaded |
| explicitly selected BYOK cloud cleanup after Stop | selected provider, including OpenRouter | authorized finalized transcript text for derived cleanup |
| purpose-specific cloud Meeting Intelligence/research | selected authorized AI provider | approved question and transcript context |
| explicit authorized web research | Brave and selected synthesis provider | approved search query/evidence context |
| proposed per-meeting Openbridge Cloud opt-in | hosted Cloud Run, approved OpenRouter/Vertex and Firestore | original transcript/segments, query snapshot and sensitive derived records; not audio |

Local capture/transcription, dictionary matching, clipboard and paste do not
require hosted Cloud. Local Gemma cleanup runs in a macOS network-denial sandbox
with an already complete model snapshot. A separately authorized BYOK cleanup
choice uses its selected provider; neither choice automatically falls back or
changes the original transcript. Cleanup settings, research consent and proposed
Cloud sharing consent remain independent.

Cloud sharing is per meeting, off by default, and explicitly discloses Trishan and
Alex as the shared audience. Uploader/Trishan-admin deletion and the local retention
policy cover originals and sensitive derived embeddings. Expiry/deletion must
exclude retrieval immediately and remove descendants/vectors; TTL alone is not
sufficient. Never-store-transcript meetings are ineligible. All of these hosted
controls remain proposed until implementation and real evaluation evidence exist.

Third-party providers receive ordinary connection metadata such as IP address and request timing. Their current terms and privacy practices apply.

## Model terms

Model weights are not committed to this repository. Whisper, Parakeet, and Gemma assets have separate upstream terms recorded in `THIRD_PARTY_NOTICES.md` and `docs/governance/ASSET_AND_MODEL_PROVENANCE.md`.

## Contributor rules

- Never commit real transcripts, patient information, credentials, or private logs.
- Use synthetic fixtures.
- Update this document when adding a new network path or persisted data field.
- Treat privacy claims as behaviours that must be verified against source and tests.
