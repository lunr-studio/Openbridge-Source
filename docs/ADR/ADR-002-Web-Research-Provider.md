# ADR-002: Web Research Provider Selection

**Status:** Accepted  
**Date:** 2026-08-14  
**Issue:** [lunr-studio/Openbridge-Beta#312](https://github.com/lunr-studio/Openbridge-Beta/issues/312)
**Decider:** Engineering  

## September 27 amendment — Brave LLM Context

The owner-approved research decision
selects **Brave LLM Context** for the first live BYOK integration, superseding the Tavily
reference decision below. The historical comparison is retained as dated context, not
current pricing, feature or privacy guidance.

Use the documented `POST /res/v1/llm/context`: one approved query, extracted text chunks,
no separate crawler. The key goes only in `X-Subscription-Token`; no query in the URL,
no cookies/cache, no redirects, one 20-second bounded request, at most 512KiB accepted.
Ask for at most five sources and 4096 context tokens; enforce bounds locally as well.
Normalize title, HTTPS URL, excerpt, provider and retrieval time. Preserve provider order;
score is optional because Brave does not supply a numeric relevance confidence.
Empty/unsafe sources never become citations. Partial and exhaustive coverage are distinct.

Brave sees the approved query and network metadata. A regular plan/key is **not** proof
of enterprise ZDR. Existing cloud AI consent and policy remain separate. This is a local
BYOK experiment, not the V4 server-managed subscription allowance.

Primary references, checked September 27, 2026:
- [LLM Context endpoint, limits and response schema](https://api-dashboard.search.brave.com/documentation/services/llm-context)
- [Authentication](https://api-dashboard.search.brave.com/documentation/guides/authentication)
- [Enterprise ZDR](https://brave.com/blog/search-api-zero-data-retention/)

## Historical context — August 14


The Research Observatory rail (#318) defines a `web` evidence scope. When a
user explicitly authorizes cloud web research for a question, Openbridge
must query a web search provider, normalize the results into the existing
`ResearchEvidence` contract, and surface them as citable evidence with
source URLs.

This ADR selects the web search provider for that future integration and
defines the normalized contract. **No production web requests are made in
this issue** — this branch delivers the ADR, the normalized
`ResearchWebResult` contract, and a `FakeWebResearchProvider` for tests.

Requirements:

1. **Citation quality first** — results must carry a canonical URL, a
   stable title, and an extractable passage. Search snippets are the
   minimum; content extraction is preferred.
2. **Explicit consent** — web scope is opt-in per question
   (`ResearchQuestion.allowsCloudWeb`) and gated by
   `MeetingAIMode.cloudOptIn`.
3. **Credential handling** — API keys must be user-provided, stored in the
   Keychain (never UserDefaults, never environment variables in production).
4. **Local-first preserved** — the app remains fully functional with no web
   provider configured. Web evidence is additive, never required.
5. **Provider-neutral** — the Research Observatory consumes a normalized
   contract; swapping providers must not touch UI or orchestration code.

## Options Considered

| Criterion | Tavily | Brave Search API | Serper.dev | Bing Web Search† |
|-----------|--------|------------------|------------|------------------|
| Purpose-built for LLM/RAG | ✅ core product | ❌ general search | ⚠️ SERP proxy | ❌ general search |
| Returns passages/snippets | ✅ content + snippet | ⚠️ snippet only | ⚠️ snippet only | ⚠️ snippet only |
| Content extraction built-in | ✅ | ❌ (separate API) | ❌ | ❌ |
| Monthly free tier | 1,000 calls | 2,000 calls | 2,500 calls | Retiring (Aug 2025) |
| Simple key auth | ✅ | ✅ | ✅ | ✅ |
| Privacy policy for query data | 30-day retention, no training by default | Anonymous queries available (no IP logging on some tiers) | Standard retention | Standard retention |
| Result quality for research Qs | Strong (reranks for answer extraction) | Strong (independent index) | Mirrors Google results | Good |
| Lock-in risk | Low (REST + JSON) | Low (REST + JSON) | Low (REST + JSON) | Medium (deprecation history) |

† Bing Web Search API retirement announced August 2025; excluded from
serious consideration.

### Option A: Tavily

- **Pros:** Purpose-built for RAG — returns distilled passages and scores;
  `include_raw_content` gives full-page extraction in one call; simple
  pricing; the de facto standard for grounded-answer pipelines.
- **Cons:** Younger company; fewer result diversity controls; every query
  transits their infrastructure (privacy surface identical to any cloud
  call).

### Option B: Brave Search API

- **Pros:** Independent index (not a Google/Bing proxy); competitive free
  tier; strong privacy posture; snippets are clean.
- **Cons:** Snippets only — we would need a separate extraction step
  (readability parser) to get passages, doubling latency and moving parts.

### Option C: Serper.dev

- **Pros:** Google-quality results via a SERP proxy; generous free tier;
  fast.
- **Cons:** Snippets only; results reflect Google's ad-influenced ranking
  for commercial queries; proxying adds an intermediary that sees query
  text.

## Decision

**We select Tavily as the reference web research provider**, with the
normalized contract designed so Brave or Serper can be added later without
touching callers.

### Rationale

1. **Citation quality is the acceptance criterion.** Tavily is the only
   option that returns answer-grade passages and per-result scores in a
   single call, which maps directly onto `ResearchEvidence.passage` and
   `confidence`.
2. **One moving part.** Built-in extraction avoids a second network
   dependency for readability parsing.
3. **Provider-neutral contract de-risks the choice.** `ResearchWebProvider`
   + `WebResearchResponse` mean the selection is reversible; if Tavily's
   pricing, quality, or privacy posture changes, a Brave adapter is a
   single new file plus an ADR amendment.

### Privacy & consent analysis

- Web scope requires **both** `ResearchEvidenceScope.web` in the question's
  scopes **and** `allowsCloudWeb == true` **and** the meeting's
  `privacySettings.allowsCloudIntelligence`.
- The question text is the only payload sent. Transcript passages are
  **never** sent to the web provider — retrieval happens locally first;
  only the question itself goes out.
- API keys live in the macOS Keychain, scoped to the app's access group.
- Queries are logged with the same redacted structural logger as #296
  (operation, provider, duration, outcome — never the question text).
- Failure, rate-limit, and no-key states all degrade to "web evidence
  unavailable" — never an error surfaced mid-meeting.

## Normalized Contract

Defined in `Sources/OpenBridgeApp/ResearchWebProvider.swift` (this branch):

```text
protocol ResearchWebProvider: Sendable
    func search(_ request: WebResearchRequest) async throws -> WebResearchResponse

struct WebResearchRequest     // question text, max results, consent flag
struct WebResearchResult      // title, url, passage, score, providerRank
struct WebResearchResponse    // results + provider metadata
```

Normalization rules (enforced by `WebResearchResponseValidator`):

- `url` must be absolute `https` (http results are dropped, not upgraded).
- `passage` must be non-empty; `score` clamped to 0.0–1.0.
- `WebResearchResult.toEvidence()` maps onto the existing `ResearchEvidence`
  with `type: .web` and `sourceLocator: .web(url:title:)`.
- Duplicate URLs are collapsed, keeping the highest-scored instance.

## Fake Provider

`FakeWebResearchProvider` returns deterministic synthetic results keyed off
the query, supports failure/latency injection, and records calls. Tests use
it exclusively — **no production web requests exist on this branch**.

## Consequences

- The future live Tavily adapter (separate issue) implements
  `ResearchWebProvider`; orchestration, UI, and tests are already written
  against the protocol via the fake.
- Adding Brave or Serper later = new adapter file + ADR amendment; zero
  changes to callers.
- Keychain storage design is deferred to the live-adapter issue.
- No network code ships in #312.