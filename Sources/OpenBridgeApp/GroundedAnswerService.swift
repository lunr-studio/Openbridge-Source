import Foundation
import NaturalLanguage

// MARK: - Grounded Answer Service (#307 / INT-04A)
//
// Generates grounded prior-meeting answers from #306 retrieval evidence
// through the #296 provider-neutral contract.
//
// Guarantees:
//   - Constrained to supplied passages: every material sentence in the
//     answer maps to at least one source passage excerpt.
//   - Source metadata (meeting ID, segment IDs, dates, owners) comes from
//     retrieval — never model-generated.
//   - Distinguishes prior discussion, prior decision, and uncertainty.
//   - Abstains when evidence is weak, contradictory, or insufficient.
//   - Provider failure is isolated: the service holds no reference to
//     recording, transcription, or store facilities.
//   - The same fixture runs through fake and reference providers without
//     changing the evidence contract.

// MARK: - Answer Kind

/// The grounding character of an answer sentence or overall answer.
enum GroundedAnswerKind: String, Codable, Equatable, Sendable {
    case priorDiscussion
    case priorDecision
    case uncertainty
}

// MARK: - Result

/// A grounded answer with per-sentence source attribution.
struct GroundedPriorMeetingAnswer: Equatable, Sendable {
    let requestID: String
    let questionText: String
    /// The answer sentences. Every material sentence maps to >= 1 passage.
    let sentences: [GroundedSentence]
    /// Overall kind for presentation.
    let kind: GroundedAnswerKind
    /// Provider confidence in [0, 1].
    let confidence: Double
    /// Retrieval-owned source records for the cited evidence. These retain
    /// the meeting identity and verbatim local passage; the model is never
    /// trusted to invent navigation metadata.
    let sources: [GroundedAnswerSource]

    var isEmpty: Bool { sentences.isEmpty }

    /// The source metadata for citations — derived from retrieval only.
    var citedPassageIDs: [String] {
        sentences.flatMap(\.passageIDs)
    }
}

/// Stable source metadata copied from local retrieval after answer
/// validation. It is deliberately separate from provider citations because
/// meeting IDs, segment IDs, and replay positions must come from our store.
struct GroundedAnswerSource: Equatable, Sendable {
    let evidenceID: String
    let meetingID: String
    let workspaceID: String?
    let segmentID: String
    let sourceLabel: String
    let sequence: Int
    let passage: String
}

/// One answer sentence with its supporting passage IDs.
struct GroundedSentence: Equatable, Sendable {
    let text: String
    let kind: GroundedAnswerKind
    /// Evidence passage IDs supporting this sentence (>= 1 for material).
    let passageIDs: [String]
}

// MARK: - Abstention

enum GroundedAnswerAbstention: Equatable, Sendable {
    case noEvidence
    case weakEvidence
    case contradictoryEvidence
    case providerFailed(String)
    case belowConfidenceThreshold

    var displayName: String {
        switch self {
        case .noEvidence: return "No source found"
        case .weakEvidence: return "Evidence too weak"
        case .contradictoryEvidence: return "Sources conflict"
        case .providerFailed: return "Provider unavailable"
        case .belowConfidenceThreshold: return "Below confidence threshold"
        }
    }
}

// MARK: - Service Errors

enum GroundedAnswerServiceError: LocalizedError, Equatable {
    case retrievalFailed(String)
    case validationFailed(String)

    var errorDescription: String? {
        switch self {
        case .retrievalFailed(let detail):
            return "Retrieval failed: \(detail)"
        case .validationFailed(let detail):
            return "Answer validation failed: \(detail)"
        }
    }
}

// MARK: - Configuration

struct GroundedAnswerConfiguration: Equatable, Sendable {
    /// Maximum passages supplied per answer.
    var maxPassages = 4
    /// Provider confidence floor; below this the service abstains.
    var minConfidence = 0.5

    static let `default` = GroundedAnswerConfiguration()
}

// MARK: - Service

/// Bridges #306 retrieval evidence into #296 grounded-answer generation.
/// The deterministic composer owns sentence-to-passage mapping; the
/// provider runs only through the neutral contract (so fake and reference
/// providers produce identical evidence behavior).
final class GroundedAnswerService: @unchecked Sendable {
    typealias CloudEvidenceAuthorization = @Sendable ([WorkspacePassageMatch]) async -> ProviderConfiguration?
    typealias CloudModelKnowledgeAuthorization = @Sendable (String?) async -> ProviderConfiguration?

    private let provider: any ResearchProvider
    private let configuration: GroundedAnswerConfiguration
    private let cloudEvidenceAuthorization: CloudEvidenceAuthorization
    private let cloudModelKnowledgeAuthorization: CloudModelKnowledgeAuthorization

    init(
        provider: any ResearchProvider = FakeResearchProvider(),
        configuration: GroundedAnswerConfiguration = .default,
        cloudEvidenceAuthorization: @escaping CloudEvidenceAuthorization = { _ in nil },
        cloudModelKnowledgeAuthorization: @escaping CloudModelKnowledgeAuthorization = { _ in nil }
    ) {
        self.provider = provider
        self.configuration = configuration
        self.cloudEvidenceAuthorization = cloudEvidenceAuthorization
        self.cloudModelKnowledgeAuthorization = cloudModelKnowledgeAuthorization
    }

    // MARK: - Public API

    /// Retrieves passages from the workspace index and composes a grounded
    /// answer. Returns nil on abstention — callers surface `noSource`
    /// instead of a weak answer. Provider/validation failures throw a
    /// contained service error; they never touch recording or
    /// transcription (this service holds no such references).
    func answer(
        question: String,
        index: WorkspaceRetrievalIndex,
        workspaceID: String?,
        meetingID: String? = nil,
        mode: ResearchProviderMode = .localOnly
    ) async throws -> GroundedPriorMeetingAnswer? {
        // 1. Retrieve evidence from #306 (abstention-aware). The raw
        // question is passed through for echo detection; the index
        // strips stopwords for matching itself.
        //
        // Post-freeze regression fix (Build 24 QA, PR #98): multi-fact
        // questions are split into clause sub-questions (sentence
        // boundaries and coordinating conjunctions). A segment holding
        // only ONE of a compound question's facts cannot satisfy the
        // whole-question strict-majority rule, so each fact is retrieved
        // by its own clause and the (deduplicated) union is used.
        // Round-2 (PR #99 Codex):
        // - empty-content clauses (interrogative-only fragments like a
        //   standalone "When") are SKIPPED, never aborting the whole answer;
        // - selection is clause-aware: each clause contributes its
        //   top-ranked not-yet-selected match (one evidence row per fact,
        //   interleaved by clause — the first clause can no longer fill the
        //   whole cap). Single-clause questions keep the unchanged
        //   whole-question retrieval; the local provider applies
        //   clause-aware quoting (one claim for a single-clause question);
        // - contradiction is evaluated WITHIN a clause only: an unrelated
        //   cross-clause fact pair never voids the answer (clause groups are
        //   passed through to the composer).
        let clauses = Self.clauseSubQuestions(question)
        var matches: [WorkspacePassageMatch] = []
        var clauseGroups: [[Int]] = []
        if clauses.count > 1 {
            var selectedIDs = Set<String>()
            for clauseItem in clauses {
                let clause = clauseItem.text
                // Round-10 (2): declarative fragments are context, never
                // answer passages.
                guard Self.isAnswerBearing(clause) else { continue }
                guard let clauseMatches = try retrievalMatches(
                    for: clauseItem,
                    index: index,
                    workspaceID: workspaceID
                ) else { continue }
                if clauseMatches.count >= 2,
                   Self.passagesContradict(clauseMatches[0].passage, clauseMatches[1].passage) {
                    continue
                }
                // Round-4 (PR #99 Codex):
                // - (1) an INDEPENDENT clause whose top passage is already
                //   selected is SATISFIED by that shared passage — never
                //   substituted down to a weaker lexical match;
                // - (2) an antecedent-substituted DEPENDENT clause asks a
                //   distinct attribute of the anchor's subject, so it takes
                //   the next UNSELECTED match (a separate-passage fact);
                //   when none exists, the shared passage satisfies it.
                // Round-5 (PR #99 Codex, P1): a substituted dependent
                // attribute CANNOT be verified as actually answering the
                // attribute ("where is the kickoff" matches "we discussed
                // the kickoff" just as well as a location fact), and
                // emitting a lexical maybe is worse than abstaining. The
                // clause abstains — no row; the anchor's verified facts
                // still emit. (Dependent attributes are a recorded known
                // limitation: they abstain rather than guess.)
                if clauseItem.isAntecedentSubstituted {
                    continue
                }
                let pick: WorkspacePassageMatch
                do {
                    guard let top = clauseMatches.first else { continue }
                    if selectedIDs.contains(top.segmentID) { continue }
                    pick = top
                }
                selectedIDs.insert(pick.segmentID)
                clauseGroups.append([matches.count])
                matches.append(pick)
                if matches.count >= configuration.maxPassages { break }
            }
            guard !matches.isEmpty else { return nil }
        } else {
            // Round-7 (2) + round-10 (1): topic-less single clauses abstain
            // only when the missing topic is an unresolvable anaphor ("Who
            // owns it?", "Where is it?"). Verb-led noun-less factual
            // questions ("Who resigned?") search normally.
            if !Self.hasSearchableTopic(question),
               Self.containsAnaphoricPronoun(question) {
                return nil
            }
            guard let clauseItem = clauses.first,
                  let whole = try retrievalMatches(
                for: clauseItem,
                index: index,
                workspaceID: workspaceID
            ), !whole.isEmpty else {
                return nil
            }
            matches = whole
            clauseGroups = [Array(whole.indices)]
        }

        let passages = matches.map { match in
            ResearchGroundingPassage(
                evidenceID: match.segmentID,
                passage: match.passage,
                sourceType: .priorMeeting,
                confidence: min(max(match.relevanceScore, 0), 1)
            )
        }

        // 2. Generate through the provider-neutral contract (#296).
        // Consent belongs to every source meeting, not merely the meeting
        // where the question was asked. If any selected passage lacks its own
        // cloud authorization snapshot, keep the complete answer local.
        let authorizedCloudConfiguration = mode.allowsCloudProvider
            ? await cloudEvidenceAuthorization(matches)
            : nil
        let effectiveMode: ResearchProviderMode = authorizedCloudConfiguration != nil
            ? mode
            : .localOnly
        let request = GroundedAnswerRequest(
            context: ResearchProviderContext(
                meetingID: meetingID,
                workspaceID: workspaceID,
                mode: effectiveMode,
                expectedCloudConfiguration: authorizedCloudConfiguration
            ),
            questionText: question,
            passages: passages
        )
        let providerResponse: GroundedAnswerResponse
        do {
            providerResponse = try await provider.groundedAnswer(request)
        } catch {
            throw GroundedAnswerServiceError.retrievalFailed(
                GroundedAnswerAbstention.providerFailed(String(describing: error)).displayName
            )
        }

        // 3. Validate provider output against #296 rules.
        let knownIDs = Set(passages.map(\.evidenceID))
        do {
            try ResearchProviderResponseValidator.validate(
                response: providerResponse,
                expectedRequestID: request.context.requestID,
                knownEvidenceIDs: knownIDs,
                evidenceTextByID: Dictionary(
                    uniqueKeysWithValues: passages.map { ($0.evidenceID, $0.passage) }
                )
            )
        } catch {
            throw GroundedAnswerServiceError.validationFailed(String(describing: error))
        }

        // 4. Compose the grounded answer with per-sentence attribution.
        return compose(
            requestID: request.context.requestID,
            question: question,
            providerResponse: providerResponse,
            passages: passages,
            matches: matches,
            clauseGroups: clauseGroups
        )
    }

    // MARK: - Clause Sub-Questions (post-freeze regression fix)

    /// Splits a question into clause sub-questions at sentence boundaries
    /// and question-restarting coordinating conjunctions, so multi-fact
    /// questions retrieve each fact independently. A single-sentence
    /// single-clause question returns itself (behavior unchanged).
    ///
    /// Round-2 (PR #99 Codex):
    /// - terminators between digits do NOT split (decimals "v1.2", times
    ///   "10:30");
    /// - a conjunction only splits when the NEXT word is an interrogative
    ///   starting a new question clause ("...and who is..." splits; the
    ///   noun phrase "Sales and Marketing" stays intact).
    /// Anaphoric pronouns: a clause containing one has an unresolvable
    /// subject reference and takes the dependent (abstention) path.
    /// Acronym-cased tokens ("IT", "WHO") are never pronouns.
    private static let anaphoricPronouns: Set<String> = [
        "it", "its", "they", "them", "their", "this", "that",
        "these", "those", "he", "she", "him", "her", "his", "hers"
    ]

    /// True when the clause contains an anaphoric pronoun in raw casing
    /// (acronym-cased tokens excluded; no acronym immunity inside
    /// all-caps clauses).
    static func containsAnaphoricPronoun(_ clause: String) -> Bool {
        clause.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .contains { word in
                anaphoricPronouns.contains(word.lowercased())
                    && !WorkspaceRetrievalIndex.isAcronymToken(word, inRaw: clause)
            }
    }

    /// Round-7 (2): a clause has a searchable topic when it contains a
    /// noun/proper-noun that is not itself a pronoun (NLTagger lexical
    /// class). "What did they decide about the budget?" — budget is a
    /// topic. "Who owns it?" — owns is a verb and it is the (unresolvable)
    /// topic, so the clause is topic-less. Falls back to non-pronominal
    /// content terms only when tagging yields nothing, so a clause is
    /// never silently dropped by a tagging failure.
    static func hasSearchableTopic(_ clause: String) -> Bool {
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = clause
        var sawAnyTag = false
        var foundTopic = false
        tagger.enumerateTags(
            in: clause.startIndex..<clause.endIndex,
            unit: .word,
            scheme: .lexicalClass,
            options: [.omitPunctuation, .omitWhitespace]
        ) { tag, range in
            sawAnyTag = true
            let word = String(clause[range])
            // Acronym-cased tokens ("IT", "WHO") are topics even when the
            // tagger will not call them nouns.
            if WorkspaceRetrievalIndex.isAcronymToken(word, inRaw: clause) {
                foundTopic = true
                return false
            }
            if tag == .noun, !anaphoricPronouns.contains(word.lowercased()) {
                foundTopic = true
                return false
            }
            return true
        }
        if foundTopic { return true }
        // The content-term fallback also applies to all-caps clauses, whose
        // tokens the tagger may not label as plain nouns (round-7 (3)).
        let allCaps = clause == clause.uppercased() && clause != clause.lowercased()
        guard !sawAnyTag || allCaps else { return false }
        // Round-8 (3): the fallback never resurrects an anaphoric
        // topic-less clause — "WHO OWNS IT?" keeps a leftover bare verb
        // after pronoun stripping, and a verb is not a topic.
        guard !Self.containsAnaphoricPronoun(clause) else { return false }
        let content = WorkspaceRetrievalIndex.contentTerms(
            ReplayHarness.retrievalQuery(for: clause), rawQuestion: clause
        )
        return content.contains { !anaphoricPronouns.contains($0) }
    }

    /// One clause sub-question, marked when it was rebuilt by antecedent
    /// substitution (round-4: a pronoun-dependent clause re-queries with
    /// its anchor's terms instead of being merged away).
    struct ClauseSubQuestion: Equatable, Sendable {
        let text: String
        let isAntecedentSubstituted: Bool
    }

    /// Separates words that describe the request from words that describe
    /// the fact being requested. Retrieval uses the fact words as its
    /// relevance threshold; an explicit scope is applied afterward as a
    /// conservative candidate filter.
    private struct ClauseFraming {
        let scopeWords: [String]
        let coreWords: [String]
        let hasImperativePreamble: Bool

        var coreText: String { coreWords.joined(separator: " ") }
    }

    private static let politenessPrefixes: Set<String> = ["please", "kindly"]
    private static let imperativeObjects: Set<String> = ["me", "us"]
    private static let namedScopeMarkers: Set<String> = [
        "project", "client", "account", "workspace",
    ]

    private static func normalizedToken(_ word: String) -> String {
        normalizedOpenerHead(word.trimmingCharacters(in: .punctuationCharacters))
    }

    /// Returns the discriminating term after a named-scope marker. Generic
    /// words such as "project", "mobile", and "app" may appear in several
    /// passages; the name after the marker ("Atlas" in "Project Atlas")
    /// must match so a long scope cannot leak into another project.
    private static func namedScopeIdentityTerms(_ scopeWords: [String]) -> [String] {
        let normalized = scopeWords.map(normalizedToken)
        for (offset, word) in normalized.enumerated()
            where namedScopeMarkers.contains(word) && offset + 1 < normalized.count {
            let identity = normalized[offset + 1]
            if !identity.isEmpty { return [identity] }
        }
        return []
    }

    /// Parses optional scope and conversational request framing. This is
    /// shared by answer-bearing detection and retrieval so grammar cannot be
    /// interpreted one way by the splitter and another way by search.
    private static func clauseFraming(_ clause: String) -> ClauseFraming {
        let words = clause.split(separator: " ").map(String.init)
        guard !words.isEmpty else {
            return ClauseFraming(scopeWords: [], coreWords: [], hasImperativePreamble: false)
        }

        var scopeWords: [String] = []
        var coreWords = words
        if let openerIndex = words.firstIndex(where: { isClauseOpenerWord($0) }),
           openerIndex > 0 {
            let candidateScope = Array(words[0..<openerIndex])
            if isScopePhrase(candidateScope) {
                scopeWords = candidateScope
                coreWords = Array(words[openerIndex...])
            }
        }

        var requestIndex = 0
        while requestIndex < coreWords.count,
              politenessPrefixes.contains(normalizedToken(coreWords[requestIndex])) {
            requestIndex += 1
        }
        guard requestIndex < coreWords.count,
              imperativeOpeners.contains(normalizedToken(coreWords[requestIndex])) else {
            return ClauseFraming(
                scopeWords: scopeWords,
                coreWords: coreWords,
                hasImperativePreamble: false
            )
        }

        requestIndex += 1
        if requestIndex < coreWords.count,
           imperativeObjects.contains(normalizedToken(coreWords[requestIndex])) {
            requestIndex += 1
        }
        return ClauseFraming(
            scopeWords: scopeWords,
            coreWords: Array(coreWords.dropFirst(requestIndex)),
            hasImperativePreamble: true
        )
    }

    /// Words that open question clauses: interrogatives, "what" (a
    /// retrieval stopword, not an interrogative — round-8 (1)), and
    /// auxiliary inversions. The contraction head covers "who's"/"what's"
    /// (round-7 (1)).
    private static let clauseOpenerWords: Set<String> = WorkspaceRetrievalIndex.interrogatives.union([
        "what", "is", "are", "was", "were", "do", "does", "did", "will", "would",
        "can", "could", "should", "may", "might", "has", "have", "had", "must"
    ])

    /// Round-12 (1): imperative verbs restart clauses too — "Tell me X and
    /// show me Y" splits at the conjunction because the NEXT word opens a
    /// new command clause, exactly like a question opener.
    private static func isClauseOpenerWord(_ word: String) -> Bool {
        let head = normalizedOpenerHead(word)
        return clauseOpenerWords.contains(head) || imperativeOpeners.contains(head)
    }

    /// Round-11 (1): imperative verbs open answer-bearing fragments too
    /// ("Tell me the kickoff date") — at position zero only.
    private static let imperativeOpeners: Set<String> = ["tell", "show", "list", "give", "find"]

    /// Round-12: leading prepositional scope words — a fragment starting
    /// with one carries shared scope into its question core (round-12 (2))
    /// and into restarted clauses (round-10 (3)).
    private static let scopePrepositions: Set<String> = [
        "for", "about", "regarding", "on", "in", "with", "at", "by"
    ]

    /// Round-15 (P1 + P2): a GENUINE leading scope phrase — the only text
    /// eligible for the colon exemption and for scope propagation. It must
    /// start with a scope preposition and contain NO verb (NLTagger): "For
    /// Project Atlas" and "For the Project Atlas mobile app" qualify; a
    /// declarative prepositional preface ("In yesterday's meeting we
    /// discussed hiring") does not and is context, never scope. The first
    /// clause opener supplies the structural boundary, so an arbitrary word
    /// cap is both unnecessary and incorrect.
    static func isScopePhrase(_ words: [String]) -> Bool {
        guard !words.isEmpty,
              let first = words.first,
              scopePrepositions.contains(contractionHead(first).lowercased())
        else { return false }
        let phrase = words.joined(separator: " ")
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = phrase
        var containsVerb = false
        tagger.enumerateTags(
            in: phrase.startIndex..<phrase.endIndex,
            unit: .word,
            scheme: .lexicalClass,
            options: [.omitPunctuation, .omitWhitespace]
        ) { tag, _ in
            if tag == .verb {
                containsVerb = true
                return false
            }
            return true
        }
        return !containsVerb
    }

    private static func contractionHead(_ word: String) -> String {
        word.components(separatedBy: CharacterSet(charactersIn: "'’")).first ?? word
    }

    /// Round-16 (1): standard negative contractions normalize back to
    /// their auxiliary before opener lookups — the apostrophe head maps
    /// "isn't" to the non-word "isn"; the opener is "is".
    static let negativeContractions: [String: String] = [
        "isn't": "is", "aren't": "are", "wasn't": "was", "weren't": "were",
        "don't": "do", "doesn't": "does", "didn't": "did",
        "won't": "will", "can't": "can", "couldn't": "could",
        "shouldn't": "should", "wouldn't": "would", "mustn't": "must",
        "hasn't": "has", "haven't": "have", "hadn't": "had"
    ]

    /// The single normalized opener-head used by EVERY opener lookup on
    /// the path (splitter restarts, answer-bearing heads and cores,
    /// delimiter exemptions): typographic apostrophe normalized,
    /// negative contractions mapped to their auxiliary, then the head.
    private static func normalizedOpenerHead(_ word: String) -> String {
        let straightened = word.replacingOccurrences(of: "’", with: "'")
        if let auxiliary = negativeContractions[straightened.lowercased()] {
            return auxiliary
        }
        return contractionHead(straightened).lowercased()
    }

    /// Round-10 (2) + round-11 (2) + round-12 (2): answer-bearing is
    /// POSITIONAL, not token-presence. A fragment bears a question when
    /// it ends interrogatively ("?"), OPENS with an auxiliary inversion or
    /// an imperative verb, or — after an optional leading prepositional
    /// scope phrase ("For Project Atlas, when is...") — its question CORE
    /// opens with an interrogative. An interrogative merely embedded in a
    /// declarative ("We discussed who owns it") is an indirect question:
    /// context, never an answer.
    static func isAnswerBearing(_ clause: String) -> Bool {
        if clause.contains("?") { return true }
        let framing = clauseFraming(clause)
        if framing.hasImperativePreamble {
            return true
        }
        guard let firstCoreWord = framing.coreWords.first else { return false }
        // Round-16 (2): the scoped core accepts the full opener set —
        // interrogatives, imperatives, AND auxiliary inversions ("For
        // Project Atlas, is the kickoff Monday").
        let coreHead = normalizedOpenerHead(firstCoreWord)
        return clauseOpenerWords.contains(coreHead) || imperativeOpeners.contains(coreHead)
    }

    static func clauseSubQuestions(_ question: String) -> [ClauseSubQuestion] {
        let conjunctions: Set<String> = ["and", "or", "but", "nor", "so", "yet"]
        var clauses: [String] = []
        for sentence in sentenceFragments(question) {
            var current: [String] = []
            let words = sentence.split(separator: " ").map(String.init)
            // Round-10 (3) + round-11 (1): shared leading scope is the
            // leading PREPOSITIONAL phrase before the first opener word
            // ("For Project Atlas, when is..."). Imperative openers
            // ("Tell me the kickoff date") are their own clauses, not
            // scope, so they never swallow the following question.
            let scopePrefix: [String]
            if let openerIndex = words.firstIndex(where: { isClauseOpenerWord($0) }),
               openerIndex > 0,
               Self.isScopePhrase(Array(words[0..<openerIndex])) {
                // Round-15 (P2): only a GENUINE scope phrase propagates — a
                // declarative prepositional preface never does.
                scopePrefix = Array(words[0..<openerIndex])
            } else {
                scopePrefix = []
            }
            var sentenceClauses: [[String]] = []
            for (i, word) in words.enumerated() {
                if conjunctions.contains(word.lowercased()),
                   !current.isEmpty,
                   i + 1 < words.count,
                   isClauseOpenerWord(words[i + 1]) {
                    sentenceClauses.append(current)
                    current = []
                    continue
                }
                current.append(word)
            }
            if !current.isEmpty {
                sentenceClauses.append(current)
            }
            for (index, clauseWords) in sentenceClauses.enumerated() {
                var text = clauseWords.joined(separator: " ")
                if index > 0, !scopePrefix.isEmpty {
                    text = scopePrefix.joined(separator: " ") + " " + text
                }
                clauses.append(text)
            }
        }
        let nonEmpty = clauses.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        // Round-4 (PR #99 Codex): antecedent substitution. A dependent
        // clause with no content of its own — pronoun-only, e.g. the
        // "where is it" tail — is REBUILT against its anchor's terms
        // ("where is the kickoff") instead of being merged away, so a fact
        // living in a separate passage can still be emitted as its own row.
        var result: [ClauseSubQuestion] = []
        for clause in nonEmpty {
            // Round-7 (2) — the equilibrium rule: dependency is
            // TOPIC-LESS-only. A clause with a searchable noun topic is a
            // normal clause even when it contains a pronoun ("What did
            // they decide about the budget?" searches [decide, budget]);
            // only clauses whose topic IS the unresolvable pronoun ("who
            // owns it?" — verb only, no noun) route to the abstention
            // path. Round 5 was too narrow (merge-back), round 6 too broad
            // (any pronoun); topic-less-only is the settling point.
            // Round-8 (2): topic-less clauses abstain regardless of
            // position — no first-clause exception ("Who owns it and…"
            // must never run the bare verb as an independent clause).
            // Round-10 (1): the topic-less abstention is gated on an
            // ACTUAL anaphor. A valid clause with no noun but also no
            // pronoun ("Who resigned?" — verb-led factual question) is a
            // normal independent clause and keeps its prior retrieval
            // behavior; only clauses whose topic is an unresolvable
            // pronoun take the dependent (abstention) path.
            let hasTopic = Self.hasSearchableTopic(clause)
            if hasTopic || !Self.containsAnaphoricPronoun(clause) {
                result.append(ClauseSubQuestion(text: clause, isAntecedentSubstituted: false))
            } else {
                let anchor = result.isEmpty ? clause : result[result.count - 1].text
                result.append(ClauseSubQuestion(
                    text: anchor + " and " + clause,
                    isAntecedentSubstituted: true
                ))
            }
        }
        return result.isEmpty
            ? [ClauseSubQuestion(text: question, isAntecedentSubstituted: false)]
            : result
    }

    /// Retrieves by the factual question core, then applies explicit scope
    /// without making generic framing words mandatory evidence. This keeps
    /// "For the Thursday demo" useful as context when it is absent from the
    /// transcript, while "For Project Atlas" selects Atlas rather than an
    /// equally named fact from another project.
    private func retrievalMatches(
        for clause: ClauseSubQuestion,
        index: WorkspaceRetrievalIndex,
        workspaceID: String?
    ) throws -> [WorkspacePassageMatch]? {
        let framing = Self.clauseFraming(clause.text)
        let coreText = framing.coreText
        let coreQuery = ReplayHarness.retrievalQuery(for: coreText)
        let coreTerms = Self.uniqueTerms(
            WorkspaceRetrievalIndex.contentTerms(coreQuery, rawQuestion: coreText)
        )
        // A pronoun-only or interrogative-only core is not a searchable
        // question. Preserve the established fail-closed noSource behavior.
        guard !coreTerms.isEmpty else { return nil }

        let scopeText = framing.scopeWords.dropFirst().joined(separator: " ")
        let scopeQuery = ReplayHarness.retrievalQuery(for: scopeText)
        let scopeTerms = Self.uniqueTerms(
            WorkspaceRetrievalIndex.contentTerms(scopeQuery, rawQuestion: scopeText)
        )
        let namedScopeIdentityTerms = Self.namedScopeIdentityTerms(framing.scopeWords)
        let candidateLimit = scopeTerms.isEmpty
            ? configuration.maxPassages
            : configuration.maxPassages * 4
        guard let candidates = try index.searchOrAbstain(
            coreTerms.joined(separator: " "),
            workspaceID: workspaceID,
            limit: candidateLimit,
            rawQuestion: coreText
        ), !candidates.isEmpty else {
            return nil
        }
        guard !scopeTerms.isEmpty else {
            return Array(candidates.prefix(configuration.maxPassages))
        }

        let scored = candidates.enumerated().map { offset, candidate in
            (candidate, Self.scopeHitCount(scopeTerms, in: candidate.passage), offset)
        }
        let requiredScopeHits = min(2, scopeTerms.count)
        let scoped = scored
            .filter { candidate, hitCount, _ in
                hitCount >= requiredScopeHits
                    && Self.scopeContainsAll(
                        namedScopeIdentityTerms,
                        in: candidate.passage
                    )
            }
            .sorted { lhs, rhs in
                lhs.1 == rhs.1 ? lhs.2 < rhs.2 : lhs.1 > rhs.1
            }
            .map(\.0)
        if !scoped.isEmpty {
            return Array(scoped.prefix(configuration.maxPassages))
        }

        // No scope word appears in any factual candidate: the prefix is
        // contextual framing rather than a corpus identity, so use the fact
        // matches. Partial scope overlap is ambiguous and abstains instead
        // of leaking to a similarly named project.
        guard namedScopeIdentityTerms.isEmpty, scored.allSatisfy({ $0.1 == 0 }) else { return nil }
        return Array(candidates.prefix(configuration.maxPassages))
    }

    private static func uniqueTerms(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        return terms.filter { seen.insert($0).inserted }
    }

    private static func scopeHitCount(_ scopeTerms: [String], in passage: String) -> Int {
        let passageTerms = Set(WorkspaceRetrievalIndex.contentTerms(passage))
        return scopeTerms.filter { scopeTerm in
            passageTerms.contains { WorkspaceRetrievalIndex.stemMatches(scopeTerm, $0) }
        }.count
    }

    private static func scopeContainsAll(_ requiredTerms: [String], in passage: String) -> Bool {
        guard !requiredTerms.isEmpty else { return true }
        let passageTerms = Set(WorkspaceRetrievalIndex.contentTerms(passage))
        return requiredTerms.allSatisfy { required in
            passageTerms.contains { WorkspaceRetrievalIndex.stemMatches(required, $0) }
        }
    }

    /// Sentence fragments of the raw question (round-3, PR #99 Codex):
    /// NLTokenizer sentence segmentation — which respects dotted
    /// abbreviations ("Dr. Smith", "Mr.") and decimals — followed by the
    /// digit-safe ";" / ":" clause split ("10:30" stays intact).
    private static func sentenceFragments(_ text: String) -> [String] {
        var sentences: [String] = []
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            sentences.append(String(text[range]))
            return true
        }
        if sentences.isEmpty { sentences = [text] }
        var fragments: [String] = []
        for sentence in sentences {
            fragments.append(contentsOf: semicolonFragments(sentence))
        }
        return fragments
    }

    /// Digit-safe ";" / ":" split inside one sentence: a terminator
    /// between digits ("10:30") never splits.
    ///
    /// Round-13 + round-14 (exemption scope): a delimiter directly after a
    /// CONTENT-FREE opening phrase ("Tell me:") is punctuation of the same
    /// clause — granted at most ONCE per fragment, and only while no
    /// content terms precede the delimiter. Every later delimiter — or a
    /// delimiter after content ("When is the kickoff; who is X?") — splits
    /// normally.
    private static func semicolonFragments(_ text: String) -> [String] {
        var fragments: [String] = []
        var current = ""
        var grantedOpenerExemption = false
        let chars = Array(text)
        for (i, ch) in chars.enumerated() {
            current.append(ch)
            if ch == ";" || ch == ":" {
                if !grantedOpenerExemption {
                    let headFragment = current.trimmingCharacters(in: .whitespaces)
                    let headWords = headFragment.split(separator: " ").map(String.init)
                    if let firstWord = headWords.first {
                        let head = normalizedOpenerHead(firstWord)
                        var exempt = false
                        if clauseOpenerWords.contains(head) || imperativeOpeners.contains(head) {
                            let content = WorkspaceRetrievalIndex.contentTerms(
                                ReplayHarness.retrievalQuery(for: headFragment),
                                rawQuestion: headFragment
                            )
                            exempt = content.isEmpty
                        } else if Self.isScopePhrase(headWords) {
                            // Round-15 (P1): a genuine scope label before a
                            // colon ("For Project Atlas:") stays attached.
                            exempt = true
                        }
                        if exempt {
                            grantedOpenerExemption = true
                            continue
                        }
                    }
                }
                let prevIsDigit = i > 0 && chars[i - 1].isNumber
                let nextIsDigit = i + 1 < chars.count && chars[i + 1].isNumber
                if !(prevIsDigit && nextIsDigit) {
                    fragments.append(current)
                    current = ""
                    grantedOpenerExemption = false
                }
            }
        }
        if !current.isEmpty { fragments.append(current) }
        return fragments
    }

    // MARK: - Model Knowledge (#60)

    struct ModelKnowledgeAnswer: Equatable, Sendable {
        let text: String
        let confidence: Double
    }

    /// Spoken-path API (#60): zero-passage groundedAnswer request. The
    /// provider answers from model knowledge; validation still enforces
    /// request identity and citation honesty (nothing to cite, so any
    /// citation fails validation). Returns nil on provider abstention.
    func answerFromModelKnowledge(
        question: String,
        meetingID: String? = nil,
        mode: ResearchProviderMode = .localOnly
    ) async throws -> ModelKnowledgeAnswer? {
        // Model knowledge is a network-only capability in production. The
        // current meeting must explicitly allow cloud intelligence, and its
        // immutable provider snapshot must still match the active tested
        // provider before the request is constructed.
        guard mode.allowsCloudProvider,
              let authorizedConfiguration = await cloudModelKnowledgeAuthorization(meetingID)
        else { return nil }
        let request = GroundedAnswerRequest(
            context: ResearchProviderContext(
                meetingID: meetingID,
                mode: mode,
                expectedCloudConfiguration: authorizedConfiguration
            ),
            questionText: question,
            passages: []
        )
        let providerResponse: GroundedAnswerResponse
        do {
            providerResponse = try await provider.groundedAnswer(request)
        } catch {
            throw GroundedAnswerServiceError.retrievalFailed(
                GroundedAnswerAbstention.providerFailed(String(describing: error)).displayName
            )
        }
        do {
            try ResearchProviderResponseValidator.validate(
                response: providerResponse,
                expectedRequestID: request.context.requestID,
                knownEvidenceIDs: []
            )
        } catch {
            throw GroundedAnswerServiceError.validationFailed(String(describing: error))
        }
        guard !providerResponse.abstained, !providerResponse.answerText.isEmpty else {
            return nil
        }
        return ModelKnowledgeAnswer(
            text: providerResponse.answerText,
            confidence: providerResponse.confidence
        )
    }

    // MARK: - Composition

    /// Splits the provider answer into sentences and maps each material
    /// sentence to the passages supporting it. Unmappable sentences are
    /// dropped — never presented unsupported.
    private func compose(
        requestID: String,
        question: String,
        providerResponse: GroundedAnswerResponse,
        passages: [ResearchGroundingPassage],
        matches: [WorkspacePassageMatch],
        clauseGroups: [[Int]]? = nil
    ) -> GroundedPriorMeetingAnswer? {
        if providerResponse.abstained {
            #if DEBUG
            print("[observatory] nil: provider abstained")
            #endif
            return nil
        }
        if providerResponse.confidence < configuration.minConfidence {
            #if DEBUG
            print("[observatory] nil: confidence \(providerResponse.confidence) < \(configuration.minConfidence)")
            #endif
            return nil
        }

        // Contradiction check WITHIN clause groups only (round-2, PR #99
        // Codex): cross-clause facts are unrelated by construction, so
        // comparing them would void legitimate multi-fact answers.
        let groups = clauseGroups ?? [Array(matches.indices)]
        for group in groups where group.count >= 2 {
            if Self.passagesContradict(matches[group[0]].passage, matches[group[1]].passage) {
                return nil
            }
        }

        let rawSentences = ResearchProviderResponseValidator.answerClaims(
            in: providerResponse.answerText
        )
        let citedPassageIDs = Set(providerResponse.citations.map(\.evidenceID))

        var kind = GroundedAnswerKind.priorDiscussion
        var sentences: [GroundedSentence] = []

        for rawSentence in rawSentences {
            let normalized = Self.normalize(rawSentence)
            guard !normalized.isEmpty else { continue }

            // Sentences of pure uncertainty are retained and labeled.
            if Self.isUncertainty(normalized) {
                sentences.append(GroundedSentence(
                    text: rawSentence,
                    kind: .uncertainty,
                    passageIDs: []
                ))
                kind = .uncertainty
                continue
            }

            // Material sentence: must map to at least one passage.
            let supporting = passages.filter { passage in
                citedPassageIDs.contains(passage.evidenceID)
                    && ResearchProviderResponseValidator.evidenceText(
                        passage.passage,
                        supports: rawSentence
                    )
            }
            guard !supporting.isEmpty else {
                // Unsupported sentence — dropped.
                continue
            }

            let sentenceKind: GroundedAnswerKind = Self.isDecision(normalized) ? .priorDecision : .priorDiscussion
            if sentenceKind == .priorDecision { kind = .priorDecision }
            sentences.append(GroundedSentence(
                text: rawSentence,
                kind: sentenceKind,
                passageIDs: supporting.map(\.evidenceID)
            ))
        }

        // Weak evidence: nothing survived mapping.
        guard !sentences.isEmpty else {
            #if DEBUG
            print("[observatory] nil: no sentences mapped to passages")
            #endif
            return nil
        }

        let citedIDs = Set(sentences.flatMap(\.passageIDs))
        let sources = matches.compactMap { match -> GroundedAnswerSource? in
            guard citedIDs.contains(match.segmentID) else { return nil }
            return GroundedAnswerSource(
                evidenceID: match.segmentID,
                meetingID: match.meetingID,
                workspaceID: match.workspaceID,
                segmentID: match.segmentID,
                sourceLabel: match.sourceLabel,
                sequence: match.sequence,
                passage: match.passage
            )
        }

        return GroundedPriorMeetingAnswer(
            requestID: requestID,
            questionText: question,
            sentences: sentences,
            kind: kind,
            confidence: providerResponse.confidence,
            sources: sources
        )
    }

    // MARK: - Deterministic Checks

    /// Direct negation conflict: one passage asserts X while the other
    /// asserts "not X" for substantially overlapping content words.
    static func passagesContradict(_ a: String, _ b: String) -> Bool {
        let na = normalize(a)
        let nb = normalize(b)
        let negations = ["not ", "no ", "never ", "isn't ", "wasn't ", "didn't "]
        let aNegated = negations.contains { na.contains($0) }
        let bNegated = negations.contains { nb.contains($0) }
        guard aNegated != bNegated else { return false }
        let aWords = Set(Self.contentWords(na))
        let bWords = Set(Self.contentWords(nb))
        let overlap = aWords.intersection(bWords)
        return overlap.count >= max(3, min(aWords.count, bWords.count) / 2)
    }

    static func isDecision(_ normalizedSentence: String) -> Bool {
        let markers = ["we decided", "we agreed", "decision", "we chose", "we will use"]
        return markers.contains { normalizedSentence.contains($0) }
    }

    static func isUncertainty(_ normalizedSentence: String) -> Bool {
        let markers = ["not clear", "unclear", "not specified", "cannot determine",
                       "no record", "does not say", "doesn't say", "unknown"]
        return markers.contains { normalizedSentence.contains($0) }
    }

    // MARK: - Text Helpers

    static func normalize(_ raw: String) -> String {
        raw.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
            .replacingOccurrences(of: "\u{2026}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func contentWords(_ text: String) -> [String] {
        text.components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: CharacterSet.alphanumerics.inverted) }
            .filter { $0.count > 2 }
    }

    private static func firstContentWords(of sentence: String, count: Int = 5) -> String {
        contentWords(sentence).prefix(count).joined(separator: " ")
    }
}
