import Foundation
import Testing
@testable import OpenBridgeApp

// MARK: - Spoken Wake-Phrase Detector Tests (#309 / EXT-01)
//
// Covers the acceptance criteria: one invocation → one request; product
// mentions that are not commands never trigger; corrected/superseded text
// cannot double-trigger; enabled/disabled modes; false positives (quoted
// mentions, mid-sentence, false starts); and replay safety.

@Suite(.serialized) struct SpokenWakePhraseDetectorTests {

    private func span(_ id: String, _ text: String, isFinal: Bool = true) -> MeetingTranscriptSegment {
        MeetingTranscriptSegment(
            id: id,
            meetingID: "m1",
            sequence: 0,
            sourceLabel: "Room",
            text: text,
            isFinal: isFinal
        )
    }

    // MARK: - Grammar

    @Test func conversationalOpeningsRecognizeTheSameQuestion() {
        for opening in ["So Open Bridge,", "Uh OpenBridge.", "Um, Open Bridge,", "Okay, OpenBridge,", "OK… OpenBridge:", "Well, so, um, Open Bridge,", "So open   bridge", "We are discussing the plan so OpenBridge,", "We discussed the plan and um OpenBridge,"] {
            #expect(SpokenWakePhraseDetector.detect(in: opening + " what is the largest country?", spanID: "s", configuration: .default)?.commandText == "what is the largest country?", "Lost direct address: \(opening)")
        }
    }

    @Test func conversationalOpeningsDoNotAuthorizeMentions() {
        for text in ["So OpenBridge is a product.", "Uh OpenBridge, our app, records audio.", "Okay, OpenBridge can record meetings.", "She said so OpenBridge, what is the largest country?", "Do not ask OpenBridge, what is the largest country?", "I don't want to ask OpenBridge who owns launch.", "We asked and OpenBridge, what is the largest country?", "\"So OpenBridge, what is the largest country?\"", "(Um OpenBridge, what is the largest country?)"] {
            #expect(SpokenWakePhraseDetector.detect(in: text, spanID: "s", configuration: .default) == nil, "Unauthorized mention: \(text)")
        }
    }

    @Test func fillerHeavyQuestionWaitsAndConsumesAdjacentContinuationOnce() async {
        let detector = SpokenWakePhraseDetector()
        let first = MeetingTranscriptSegment(id: "a", meetingID: "m", sequence: 0, sourceLabel: "Synthetic", text: "OpenBridge, can you tell me um uh you", isFinal: true)
        let next = MeetingTranscriptSegment(id: "b", meetingID: "m", sequence: 1, sourceLabel: "Synthetic", text: "uh you know what the largest country in the world is? Other conversation follows.", isFinal: true)
        #expect(await detector.processAll(first).isEmpty)
        #expect(await detector.processAll(next).map(\.commandText) == ["can you tell me what the largest country in the world is?"])
        #expect(await detector.processAll(next).isEmpty)
    }

    @Test func pendingDeadlineExpiresOnceAndLateContinuationCannotSubmit() async throws {
        let detector = SpokenWakePhraseDetector()
        let time = Date(timeIntervalSince1970: 1000)
        let first = MeetingTranscriptSegment(id: "a", meetingID: "m", sequence: 0, sourceLabel: "Synthetic", text: "Uh OpenBridge, can you tell me, um", isFinal: true)
        let waiting = await detector.processUpdate(first, now: time)
        let pending = try #require(waiting.pending)
        #expect(waiting.invocations.isEmpty)
        #expect(pending.deadline == time.addingTimeInterval(60))
        #expect(await detector.expirePending(requestID: pending.invocation.requestID, now: time.addingTimeInterval(59)) == nil)
        #expect(await detector.expirePending(requestID: "stale", now: time.addingTimeInterval(61)) == nil)
        #expect(await detector.expirePending(requestID: pending.invocation.requestID, now: time.addingTimeInterval(60))?.needsRepeat == true)
        #expect(await detector.expirePending(requestID: pending.invocation.requestID, now: time.addingTimeInterval(61)) == nil)
        let next = MeetingTranscriptSegment(id: "b", meetingID: "m", sequence: 1, sourceLabel: "Synthetic", text: "what the largest country is?", isFinal: true)
        #expect(await detector.processUpdate(next, now: time.addingTimeInterval(61)).invocations.isEmpty)
    }

    @Test func incompleteQuestionCannotConsumeUnrelatedConversationOrNewRequest() async {
        for text in ["We are done for today.", "OpenBridge, what is two plus two?", "So OpenBridge, what is two plus two?"] {
            let detector = SpokenWakePhraseDetector()
            _ = await detector.processUpdate(.init(id: "a", meetingID: "m", sequence: 0, sourceLabel: "Synthetic", text: "OpenBridge, can you tell me um", isFinal: true))
            let result = await detector.processUpdate(.init(id: "b", meetingID: "m", sequence: 1, sourceLabel: "Synthetic", text: text, isFinal: true))
            #expect(result.invocations.map(\.commandText) == (text.hasPrefix("We") ? [] : ["what is two plus two?"]))
            #expect(result.pending == nil)
        }
    }

    @Test func correctedPendingQuestionInvalidatesItsOldDeadline() async throws {
        let detector = SpokenWakePhraseDetector()
        let time = Date(timeIntervalSince1970: 1000)
        let old = await detector.processUpdate(.init(id: "a", meetingID: "m", sequence: 0, sourceLabel: "Synthetic", text: "OpenBridge, can you", isFinal: true), now: time)
        let oldID = try #require(old.pending?.invocation.requestID)
        let new = await detector.processUpdate(.init(id: "a", meetingID: "m", sequence: 0, sourceLabel: "Synthetic", text: "So OpenBridge, tell me", isFinal: true), now: time.addingTimeInterval(10))
        #expect(new.pending != nil)
        #expect(await detector.expirePending(requestID: oldID, now: time.addingTimeInterval(60)) == nil)
    }

    @Test func screenshotPunctuationKeepsCompleteQuestion() {
        let cases = [
            ("Open bridge? Can you tell me what Deep Seek is?", "can you tell me what deep seek is?"),
            ("Open Bridge. What? is induction loop hearing aid technology?", "what is induction loop hearing aid technology?"),
            ("But OpenBridge, can you tell me the next number after four?", "can you tell me the next number after four?"),
        ]
        for (text, expected) in cases {
            #expect(SpokenWakePhraseDetector.detect(in: text, spanID: "s", configuration: .default)?.commandText == expected)
        }
    }

    @Test func splitQuestionWaitsForItsContinuation() async {
        let detector = SpokenWakePhraseDetector()
        let first = MeetingTranscriptSegment(id: "a", meetingID: "m1", sequence: 0, sourceLabel: "Room", text: "Open bridge. Can you", isFinal: true)
        let next = MeetingTranscriptSegment(id: "b", meetingID: "m1", sequence: 1, sourceLabel: "Room", text: "tell me what an induction hearing loop is? Other conversation follows.", isFinal: true)
        #expect(await detector.process(first) == nil)
        #expect(await detector.process(next)?.commandText == "can you tell me what an induction hearing loop is?")
        #expect(await detector.process(next) == nil)
    }

    @Test func multipleRequestsAndPendingTailHaveDistinctStableIdentities() async {
        let detector = SpokenWakePhraseDetector()
        let first = MeetingTranscriptSegment(id: "multi", meetingID: "m1", sequence: 0, sourceLabel: "Room",
            text: "OpenBridge, what is two plus two? Open Bridge. What? is an induction loop? OpenBridge, can you", isFinal: true)
        let batch = await detector.processAll(first)
        #expect(batch.map(\.commandText) == ["what is two plus two?", "what is an induction loop?"])
        #expect(batch.map(\.commandIndex) == [0, 1])
        #expect(await detector.processAll(first).isEmpty)
        let next = MeetingTranscriptSegment(id: "tail", meetingID: "m1", sequence: 1, sourceLabel: "Room",
            text: "tell me what a water sign is? OpenBridge, explain deep learning.", isFinal: true)
        let continued = await detector.processAll(next)
        #expect(continued.map(\.commandText) == ["can you tell me what a water sign is?", "explain deep learning."])
        #expect(continued.first?.sourceSpanID == "multi")
        #expect(continued.first?.commandIndex == 2)
    }

    @Test func fragmentsNeverCrossMeetingsGapsOrNewWakeQuestions() async {
        for (meeting, sequence, text) in [("m2", 1, "tell me what an induction loop is?"),
                                          ("m1", 2, "tell me what an induction loop is?"),
                                          ("m1", 1, "OpenBridge, what is two plus two?")] {
            let detector = SpokenWakePhraseDetector()
            _ = await detector.processAll(.init(id: "a", meetingID: "m1", sequence: 0, sourceLabel: "Room", text: "OpenBridge, can you", isFinal: true))
            let results = await detector.processAll(.init(id: "b", meetingID: meeting, sequence: sequence, sourceLabel: "Room", text: text, isFinal: true))
            #expect(results.map(\.commandText) == (text.hasPrefix("OpenBridge") ? ["what is two plus two?"] : []))
        }
    }

    @Test func unpunctuatedFragmentCanContinueButMentionsCannot() async {
        let detector = SpokenWakePhraseDetector()
        #expect(await detector.process(.init(id: "a", meetingID: "m", sequence: 0, sourceLabel: "Synthetic", text: "OpenBridge can you", isFinal: true)) == nil)
        #expect(await detector.process(.init(id: "b", meetingID: "m", sequence: 1, sourceLabel: "Synthetic", text: "tell me what two plus two is?", isFinal: true))?.commandText == "can you tell me what two plus two is?")
        for text in ["We discussed it and OpenBridge, our app, worked.", "We tried but OpenBridge, the product, failed.", "OpenBridge can record meetings."] {
            #expect(SpokenWakePhraseDetector.detect(in: text, spanID: "negative", configuration: .default) == nil)
        }
    }

    @Test func detectsSimpleInvocation() async throws {
        let detector = SpokenWakePhraseDetector()
        let invocation = await detector.process(span("s1", "OpenBridge, what did we decide about pricing?"))
        let detected = try #require(invocation)
        #expect(detected.commandText.contains("what did we decide"))
        #expect(detected.sourceSpanID == "s1")
        #expect(detected.form == "openbridge,")
    }

    @Test func detectsHeyPrefix() async throws {
        let detector = SpokenWakePhraseDetector()
        let invocation = await detector.process(span("s1", "Hey OpenBridge, summarize the budget."))
        let detected = try #require(invocation)
        #expect(detected.form == "hey openbridge,")
        #expect(detected.commandText.contains("summarize"))
    }

    @Test func heyPrefixCanBeDisabled() async throws {
        let detector = SpokenWakePhraseDetector(configuration: .init(allowHeyPrefix: false))
        let invocation = await detector.process(span("s1", "Hey OpenBridge, summarize the budget."))
        #expect(invocation == nil, "Hey prefix disabled must not trigger")
    }

    // MARK: - Non-Commands Never Trigger

    @Test func deliberateAskAndUnpunctuatedQuestionsTrigger() async throws {
        let cases = [
            ("I want to ask Open Bridge who the king of Cyprus was.", "who the king of cyprus was."),
            ("Ask OpenBridge what we decided about pricing?", "what we decided about pricing?"),
            ("Can I ask Open Bridge to tell me how the research rail works?", "tell me how the research rail works?"),
            ("Open bridge what did we decide?", "what did we decide?"),
            ("That didn't work.\nOpen bridge, try again.", "try again."),
            ("I want to ask Open Bridge who owns launch? We are still recording.", "who owns launch?"),
        ]
        for (text, expected) in cases {
            let detector = SpokenWakePhraseDetector()
            let result = await detector.process(span("s1", text))
            #expect(result?.commandText == expected, "Explicit request was lost: \(text)")
            #expect(await detector.process(span("s1", text)) == nil)
        }
    }

    @Test func expandedGrammarStillRejectsMentionsAndIncompleteRequests() async {
        let cases = [
            "I don't want to ask OpenBridge who owns launch.",
            "We could ask OpenBridge who owns launch.",
            "She said I want to ask OpenBridge who owns launch.",
            "\"I want to ask OpenBridge who owns launch?\"",
            "(OpenBridge, who owns launch?)",
            "We talked about OpenBridge. It records meetings.",
            "Ask OpenBridge",
            "I want to ask OpenBridge who's",
            "OpenBridge is a great product.",
            "OpenBridge can record meetings.",
            "She said 'example. Ask OpenBridge who owns launch?'",
            "She said \"example. OpenBridge, who owns launch?\"",
        ]
        for text in cases {
            let detector = SpokenWakePhraseDetector()
            #expect(await detector.process(span("s1", text)) == nil, "Not a complete deliberate request: \(text)")
        }
    }

    @Test func plainMentionDoesNotTrigger() async throws {
        let detector = SpokenWakePhraseDetector()
        let cases = [
            "We use OpenBridge for meetings.",
            "I heard about OpenBridge yesterday.",
            "OpenBridge is a great product.",
            "The OpenBridge team shipped a release.",
        ]
        for text in cases {
            let invocation = await detector.process(span("s-\(text.hashValue)", text))
            #expect(invocation == nil, "Mention must not trigger: '\(text)'")
        }
    }

    @Test func quotedMentionDoesNotTrigger() async throws {
        let detector = SpokenWakePhraseDetector()
        let invocation = await detector.process(span("s1", "\"OpenBridge\""))
        #expect(invocation == nil)
    }

    @Test func falseStartDoesNotTrigger() async throws {
        let detector = SpokenWakePhraseDetector()
        let invocation = await detector.process(span("s1", "OpenBridge,"))
        #expect(invocation == nil, "Wake phrase with no command must not trigger")
    }

    @Test func midSentenceTriggerIgnored() async throws {
        let detector = SpokenWakePhraseDetector()
        // Mid-sentence mention without sentence punctuation before it.
        let invocation = await detector.process(span("s1", "We asked OpenBridge, but nothing happened."))
        #expect(invocation == nil, "Mid-sentence occurrence must not trigger")
    }

    @Test func afterSentencePunctuationTriggers() async throws {
        let detector = SpokenWakePhraseDetector()
        let invocation = await detector.process(span("s1", "That didn't work. OpenBridge, try again."))
        let detected = try #require(invocation)
        #expect(detected.commandText.contains("try again"))
    }

    // MARK: - Exactly Once

    @Test func sameSpanNeverTriggersTwice() async throws {
        let detector = SpokenWakePhraseDetector()
        let first = await detector.process(span("s1", "OpenBridge, what is the pricing?"))
        #expect(first != nil)

        // Replay identical content (revisions/replays cannot duplicate).
        let second = await detector.process(span("s1", "OpenBridge, what is the pricing?"))
        #expect(second == nil, "Identical replay must not double-trigger")
    }

    @Test func sameCommandDifferentSpansTriggersEach() async throws {
        let detector = SpokenWakePhraseDetector()
        let first = await detector.process(span("s1", "OpenBridge, what is the pricing?"))
        let second = await detector.process(span("s2", "OpenBridge, what is the pricing?"))
        #expect(first != nil)
        #expect(second != nil, "A genuinely new utterance in a new span must trigger")
    }

    // MARK: - Corrections

    @Test func correctedTextCannotDoubleTrigger() async throws {
        let detector = SpokenWakePhraseDetector()
        _ = await detector.process(span("s1", "OpenBridge, what is the prcing?"))

        // Correction revises the span; the OLD invocation is superseded and
        // the corrected text triggers exactly once.
        let corrected = await detector.process(span("s1", "OpenBridge, what is the pricing?"))
        #expect(corrected != nil, "Corrected new text is a fresh command")
        #expect(corrected?.commandText.contains("pricing") == true)

        // Replaying the corrected text must not re-trigger.
        let replay = await detector.process(span("s1", "OpenBridge, what is the pricing?"))
        #expect(replay == nil)
    }

    @Test func correctionToNonCommandSupersedes() async throws {
        let detector = SpokenWakePhraseDetector()
        _ = await detector.process(span("s1", "OpenBridge, summarize the call."))

        // Corrected into a plain sentence: prior invocation superseded.
        let after = await detector.process(span("s1", "I meant to say the summary is fine."))
        #expect(after == nil)
        let active = await detector.activeInvocations
        #expect(active.isEmpty, "Superseded invocation must be removed")
    }

    // MARK: - Modes

    @Test func disabledModeNeverTriggers() async throws {
        let detector = SpokenWakePhraseDetector(configuration: .init(enabled: false))
        let invocation = await detector.process(span("s1", "OpenBridge, what is the pricing?"))
        #expect(invocation == nil)
    }

    @Test func nonFinalSpansIgnored() async throws {
        let detector = SpokenWakePhraseDetector()
        let invocation = await detector.process(span("s1", "OpenBridge, what is the pricing?", isFinal: false))
        #expect(invocation == nil)
    }

    // MARK: - Bounded Context

    @Test func commandTextIsBounded() async throws {
        let detector = SpokenWakePhraseDetector(configuration: .init(maximumCommandWords: 3))
        let invocation = await detector.process(span("s1", "OpenBridge, one two three four five"))
        let detected = try #require(invocation)
        #expect(detected.commandText.split(separator: " ").count == 3)
    }

    // MARK: - External-Knowledge Labeling (via routing contract)

    @Test func invocationIsARoutingContractOnly() async throws {
        // The SpokenInvocation type carries only routing data; the caller
        // (rail) must route it through #296 and label external/model
        // knowledge distinctly from prior-meeting memory. The detector has
        // no provider/web references — verified by construction here.
        let detector = SpokenWakePhraseDetector()
        let invocation = await detector.process(span("s1", "OpenBridge, search the web for pricing."))
        _ = try #require(invocation)
    }
    // MARK: - #309 ASR-realistic forms (runtime evidence)

    @Test func asrTwoWordFormTriggers() async {
        // Exact text from the 09:55 manifest, segment 2.
        let detector = SpokenWakePhraseDetector()
        let segment = MeetingTranscriptSegment(
            meetingID: "m1", sequence: 2, sourceLabel: "Room",
            text: "Open bridge, what did we decide about the launch date? Yeah,",
            isFinal: true
        )
        let invocation = await detector.process(segment)
        #expect(invocation != nil)
        #expect(invocation?.commandText.contains("what did we decide") == true)
    }

    @Test func asrHeyTwoWordFormTriggers() async {
        let detector = SpokenWakePhraseDetector()
        let segment = MeetingTranscriptSegment(
            meetingID: "m1", sequence: 0, sourceLabel: "Room",
            text: "Hey open bridge, pull up the budget notes",
            isFinal: true
        )
        let invocation = await detector.process(segment)
        #expect(invocation != nil)
    }

    @Test func twoWordNearMissStillDoesNotTrigger() async {
        // Mid-sentence two-word mention — still no trigger.
        let detector = SpokenWakePhraseDetector()
        let segment = MeetingTranscriptSegment(
            meetingID: "m1", sequence: 0, sourceLabel: "Room",
            text: "We should open a bridge to the new market soon.",
            isFinal: true
        )
        let invocation = await detector.process(segment)
        #expect(invocation == nil)
    }

}
