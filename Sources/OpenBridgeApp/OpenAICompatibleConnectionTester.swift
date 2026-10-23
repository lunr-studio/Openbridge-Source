import Foundation

/// Verifies the provider can perform the exact structured operation required
/// by cloud cleanup. The eight source strings are fixed synthetic text sized
/// like the largest production cleanup batch; no
/// meeting title, transcript, question, or user content is included.
struct OpenAICompatibleConnectionTester: ProviderConnectionTester {
    typealias Transport = OpenAICompatibleCloudModelClient.Transport

    static let probePrompt = #"{"segments":[{"index":1,"text":"um hello everyone thanks for joining today I wanted to review the launch checklist and make sure each owner understands the remaining work before Friday"},{"index":2,"text":"so the design draft is ready and the engineering review found two small changes that should be completed tomorrow afternoon"},{"index":3,"text":"we agreed that Jordan will confirm the schedule while Casey checks the final copy and shares any corrections with the group"},{"index":4,"text":"okay the next step is to collect those updates test the revised flow and send a short status note before the end of the day"},{"index":5,"text":"the support notes are mostly complete but we should simplify the opening paragraph and verify that every link points to the correct page"},{"index":6,"text":"Morgan will run the final checks on Thursday morning and record any blockers in the shared checklist before the review starts"},{"index":7,"text":"if no new issues appear the release can proceed as planned otherwise the team will pause and agree on a revised date"},{"index":8,"text":"thanks everyone please share your updates in writing so the final decision and each follow up action remain clear"}]}"#

    private let transport: Transport

    init(transport: @escaping Transport = Self.urlSessionTransport) {
        self.transport = transport
    }

    func test(settings: ProviderSettings, apiKey: String?) async -> ProviderConnectionTestResult {
        guard let apiKey, !apiKey.isEmpty,
              let configuration = try? settings.configuration.validated() else {
            return .notConfigured
        }

        let format: CloudResponseFormat = configuration.preset == .openRouter
            ? .strictCleanupSchema(itemCount: MeetingCleanupContract.chunkSize)
            : .jsonObject
        let request = CloudChatCompletionRequest(
            messages: [
                CloudChatMessage(
                    role: .system,
                    content: "Clean eight numbered speech-to-text samples. Return only JSON with segments containing index and non-empty cleanedText."
                ),
                CloudChatMessage(role: .user, content: Self.probePrompt),
            ],
            maxTokens: 1_000,
            temperature: 0,
            responseFormat: format,
            reasoning: configuration.preset == .openRouter ? .disabled : nil
        )
        let authorization = AuthorizedCloudRequest(
            requestID: "structured-cleanup-capability-test",
            configuration: configuration,
            apiKey: apiKey
        )

        let start = ContinuousClock.now
        do {
            let content = try await OpenAICompatibleCloudModelClient(transport: transport)
                .complete(request, authorization: authorization)
            guard Self.isValidStructuredProbe(content) else {
                return .malformedResponse
            }
            let elapsed = start.duration(to: .now)
            let milliseconds = max(0, Int(elapsed.components.seconds * 1_000)
                + Int(elapsed.components.attoseconds / 1_000_000_000_000_000))
            return .success(latencyMS: milliseconds)
        } catch let error as CloudModelClientError {
            switch error {
            case .authenticationFailed:
                return .authenticationFailed
            case .creditUnavailable:
                return .creditOrRateLimited("The provider reports that credit or billing is unavailable.")
            case .rateLimited:
                return .creditOrRateLimited("The provider rate limit has been reached. Try again later.")
            case .offline:
                return .offline
            case .timeout:
                return .timeout
            case .cancelled:
                return .cancelled
            case .malformedResponse, .responseTooLarge:
                return .malformedResponse
            case .providerFailure(let statusCode):
                return .providerError("HTTP \(statusCode).")
            }
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .providerError("The structured cleanup capability test could not be completed.")
        }
    }

    private static func isValidStructuredProbe(_ raw: String) -> Bool {
        guard let start = raw.firstIndex(of: "{"),
              let end = raw.lastIndex(of: "}"),
              start < end,
              let data = String(raw[start...end]).data(using: .utf8),
              let envelope = try? JSONDecoder().decode(ProbeEnvelope.self, from: data),
              envelope.segments.count == MeetingCleanupContract.chunkSize else {
            return false
        }
        return envelope.segments.enumerated().allSatisfy { offset, item in
            item.index == offset + 1
                && !item.cleanedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private static let urlSessionTransport: Transport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudModelClientError.malformedResponse
        }
        return (data, http)
    }
}

private struct ProbeEnvelope: Decodable {
    let segments: [CleanupGenerationItem]
}
