import Foundation

enum EngineServiceError: LocalizedError {
    case missingScript
    case networkSandboxUnavailable
    case processFailed(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingScript:
            return "OpenBridge could not find the bundled Python engine."
        case .networkSandboxUnavailable:
            return "OpenBridge could not start the required offline network sandbox."
        case .processFailed(let message):
            return message
        case .invalidResponse:
            return "The OpenBridge engine returned an invalid response."
        }
    }
}

struct EngineService: Sendable, MeetingEngine, MeetingCleanupEngine {
    private let decoder = JSONDecoder()
    private let defaultTranscriptionLanguage = "en"

    var provenance: MeetingCleanupProvenance { .localGemma }

    private struct PythonConfiguration {
        let executableURL: URL
        let environment: [String: String]
    }

    func doctor() async throws -> EngineDoctor {
        try await runAndDecode(arguments: ["doctor"])
    }

    func listModels() async throws -> EngineModelsListResponse {
        try await runAndDecode(arguments: ["models", "list"])
    }

    func installModel(identifier: String, force: Bool = false) async throws -> InstalledModel {
        var arguments = ["models", "install", "--model", identifier]
        if force {
            arguments.append("--force")
        }
        let response: EngineModelInstallResponse = try await runAndDecode(arguments: arguments)
        return response.model
    }

    func removeModel(identifier: String) async throws -> InstalledModel {
        let response: EngineModelInstallResponse = try await runAndDecode(arguments: ["models", "remove", "--model", identifier])
        return response.model
    }

    func transcribe(
        audioURL: URL,
        modelIdentifier: String,
        formattingEnabled: Bool,
        vocabularyCorrectionsEnabled: Bool,
        customDictionaryURL: URL,
        cleanupMode: TranscriptionCleanupMode
    ) async throws -> TranscriptPayload {
        var arguments = [
            "transcribe-audio",
            "--audio-path",
            audioURL.path,
            "--model",
            modelIdentifier,
            "--language",
            defaultTranscriptionLanguage,
        ]
        if formattingEnabled {
            arguments.append("--formatting-enabled")
        }
        arguments.append("--custom-vocab-path")
        arguments.append(customDictionaryURL.path)
        if !vocabularyCorrectionsEnabled {
            arguments.append("--no-vocab")
        }
        if cleanupMode.usesLocalLLM {
            arguments.append("--llm-enabled")
            arguments.append("--llm-provider")
            arguments.append("auto")
            arguments.append("--ollama-cleanup-mode")
            arguments.append(cleanupMode.rawValue)
            if let ollamaModel = cleanupMode.localLLMModel {
                arguments.append("--ollama-model")
                arguments.append(ollamaModel)
            }
        }
        let response: EngineTranscriptResponse = try await runAndDecode(arguments: arguments)
        return response.transcript
    }

    func transcribeDetailed(
        audioURL: URL,
        modelIdentifier: String,
        formattingEnabled: Bool,
        vocabularyCorrectionsEnabled: Bool,
        customDictionaryURL: URL,
        cleanupMode: TranscriptionCleanupMode
    ) async throws -> TranscriptPayload {
        var arguments = [
            "transcribe-audio",
            "--audio-path",
            audioURL.path,
            "--model",
            modelIdentifier,
            "--language",
            defaultTranscriptionLanguage,
        ]
        arguments.append("--detailed-timestamps")
        if formattingEnabled {
            arguments.append("--formatting-enabled")
        }
        arguments.append("--custom-vocab-path")
        arguments.append(customDictionaryURL.path)
        if !vocabularyCorrectionsEnabled {
            arguments.append("--no-vocab")
        }
        if cleanupMode.usesLocalLLM {
            arguments.append("--llm-enabled")
            arguments.append("--llm-provider")
            arguments.append("auto")
            arguments.append("--ollama-cleanup-mode")
            arguments.append(cleanupMode.rawValue)
            if let ollamaModel = cleanupMode.localLLMModel {
                arguments.append("--ollama-model")
                arguments.append(ollamaModel)
            }
        }
        let response: EngineTranscriptResponse = try await runAndDecode(arguments: arguments)
        return response.transcript
    }

    func transcribeMedia(
        fileURL: URL,
        modelIdentifier: String,
        formattingEnabled: Bool,
        vocabularyCorrectionsEnabled: Bool,
        customDictionaryURL: URL,
        cleanupMode: TranscriptionCleanupMode
    ) async throws -> EngineMediaTranscriptResponse {
        var arguments = [
            "transcribe-media",
            "--media-path",
            fileURL.path,
            "--model",
            modelIdentifier,
            "--language",
            defaultTranscriptionLanguage,
        ]
        if formattingEnabled {
            arguments.append("--formatting-enabled")
        }
        arguments.append("--custom-vocab-path")
        arguments.append(customDictionaryURL.path)
        if !vocabularyCorrectionsEnabled {
            arguments.append("--no-vocab")
        }
        if cleanupMode.usesLocalLLM {
            arguments.append("--llm-enabled")
            arguments.append("--llm-provider")
            arguments.append("auto")
            arguments.append("--ollama-cleanup-mode")
            arguments.append(cleanupMode.rawValue)
            if let ollamaModel = cleanupMode.localLLMModel {
                arguments.append("--ollama-model")
                arguments.append(ollamaModel)
            }
        }
        return try await runAndDecode(arguments: arguments)
    }

    func transcribeURL(
        urlString: String,
        modelIdentifier: String,
        formattingEnabled: Bool,
        vocabularyCorrectionsEnabled: Bool,
        customDictionaryURL: URL,
        cleanupMode: TranscriptionCleanupMode
    ) async throws -> EngineMediaTranscriptResponse {
        var arguments = [
            "transcribe-url",
            "--url",
            urlString,
            "--model",
            modelIdentifier,
            "--language",
            defaultTranscriptionLanguage,
        ]
        if formattingEnabled {
            arguments.append("--formatting-enabled")
        }
        arguments.append("--custom-vocab-path")
        arguments.append(customDictionaryURL.path)
        if !vocabularyCorrectionsEnabled {
            arguments.append("--no-vocab")
        }
        if cleanupMode.usesLocalLLM {
            arguments.append("--llm-enabled")
            arguments.append("--llm-provider")
            arguments.append("auto")
            arguments.append("--ollama-cleanup-mode")
            arguments.append(cleanupMode.rawValue)
            if let ollamaModel = cleanupMode.localLLMModel {
                arguments.append("--ollama-model")
                arguments.append(ollamaModel)
            }
        }
        return try await runAndDecode(arguments: arguments)
    }

    func transformSelectedText(
        selectedText: String,
        instruction: String,
        appContext: String
    ) async throws -> EngineCommandModeResponse {
        try await runAndDecode(arguments: [
            "command-mode",
            "transform",
            "--selected-text",
            selectedText,
            "--instruction",
            instruction,
            "--app-context",
            appContext,
        ])
    }

    func warmModel(identifier: String) async throws {
        _ = try await runAndDecode(arguments: ["warm-model", "--model", identifier]) as EngineWarmModelResponse
    }

    func checkReadiness(
        modelIdentifier: String,
        cleanupMode: TranscriptionCleanupMode,
        includeLoadCheck: Bool = false,
        includeInferenceCheck: Bool = false
    ) async throws -> EngineReadinessPayload {
        var arguments = [
            "readiness",
            "--model",
            modelIdentifier,
            "--cleanup-mode",
            cleanupMode.rawValue,
        ]
        if includeLoadCheck {
            arguments.append("--load-check")
        }
        if includeInferenceCheck {
            arguments.append("--inference-check")
        }
        let response: EngineReadinessResponse = try await runAndDecode(arguments: arguments)
        return response.readiness
    }

    func cleanMeetingSegments(
        _ segments: [MeetingTranscriptSegment]
    ) async throws -> MeetingCleanupEngineOutput {
        struct Request: Encodable {
            let contractVersion: Int
            let modelRepository: String
            let chunkSize: Int
            let segments: [MeetingTranscriptSegment]
        }
        struct Response: Decodable {
            let cleanup: MeetingCleanupEngineOutput
        }

        let request = Request(
            contractVersion: MeetingCleanupContract.version,
            modelRepository: MeetingCleanupContract.modelRepository,
            chunkSize: MeetingCleanupContract.chunkSize,
            segments: segments
        )
        let input = try JSONEncoder().encode(request)
        let response: Response = try await runAndDecode(
            arguments: ["meeting-cleanup"],
            standardInput: input,
            denyNetwork: true
        )
        return response.cleanup
    }

    private func runAndDecode<T: Decodable>(
        arguments: [String],
        standardInput: Data? = nil,
        denyNetwork: Bool = false
    ) async throws -> T {
        let data = try await run(
            arguments: arguments,
            standardInput: standardInput,
            denyNetwork: denyNetwork
        )
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            if let engineError = decodeEngineError(from: data) {
                throw EngineServiceError.processFailed(engineError.displayMessage)
            }
            throw EngineServiceError.invalidResponse
        }
    }

    private func run(
        arguments: [String],
        standardInput: Data? = nil,
        denyNetwork: Bool = false
    ) async throws -> Data {
        try Task.checkCancellation()
        let scriptURL = try engineScriptURL()
        let pythonConfiguration = self.pythonConfiguration()
        let process = Process()

        var environment = pythonConfiguration.environment
        if denyNetwork {
            // Defense in depth: the OS sandbox is authoritative, and the
            // cleanup child also receives no inherited cloud credentials.
            for key in [
                "OPENAI_API_KEY",
                "OPENROUTER_API_KEY",
                "ANTHROPIC_API_KEY",
                "HTTP_PROXY",
                "HTTPS_PROXY",
                "ALL_PROXY",
            ] {
                environment.removeValue(forKey: key)
            }
            environment["HF_HUB_OFFLINE"] = "1"
            environment["TRANSFORMERS_OFFLINE"] = "1"
            environment["HF_HUB_DISABLE_TELEMETRY"] = "1"
            environment["OPENBRIDGE_NETWORK_SANDBOX"] = "macos-deny-network"
            let sandboxURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            guard FileManager.default.isExecutableFile(atPath: sandboxURL.path) else {
                throw EngineServiceError.networkSandboxUnavailable
            }
            process.executableURL = sandboxURL
            process.arguments = [
                "-p",
                "(version 1) (allow default) (deny network*)",
                pythonConfiguration.executableURL.path,
                scriptURL.path,
            ] + arguments
        } else {
            process.executableURL = pythonConfiguration.executableURL
            process.arguments = [scriptURL.path] + arguments
        }
        process.environment = environment

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr
                let stdin = standardInput.map { _ in Pipe() }
                process.standardInput = stdin

                process.terminationHandler = { process in
                    let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
                    let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
                    if process.terminationStatus == 0 {
                        continuation.resume(returning: stdoutData)
                        return
                    }

                    if let engineError = decodeEngineError(from: stderrData) ?? decodeEngineError(from: stdoutData) {
                        continuation.resume(throwing: EngineServiceError.processFailed(engineError.displayMessage))
                        return
                    }

                    let stderrText = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let stdoutText = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: EngineServiceError.processFailed(stderrText?.isEmpty == false ? stderrText! : (stdoutText ?? "The engine process failed.")))
                }

                do {
                    try process.run()
                    if Task.isCancelled {
                        process.terminate()
                    }
                    if let standardInput, let stdin {
                        try? stdin.fileHandleForWriting.write(contentsOf: standardInput)
                        try? stdin.fileHandleForWriting.close()
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
        }
    }

    private func pythonConfiguration() -> PythonConfiguration {
        var environment = environmentWithToolPathDefaults(ProcessInfo.processInfo.environment)

        if let explicitPythonPath = environment["OPENBRIDGE_ENGINE_PYTHON"],
           !explicitPythonPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return PythonConfiguration(
                executableURL: URL(fileURLWithPath: explicitPythonPath),
                environment: environment
            )
        }

        if let bundledConfiguration = bundledPythonConfiguration(baseEnvironment: environment) {
            return bundledConfiguration
        }

        environment["OPENBRIDGE_ENGINE_PYTHON"] = "/usr/bin/python3"
        return PythonConfiguration(
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            environment: environment
        )
    }

    private func bundledPythonConfiguration(baseEnvironment: [String: String]) -> PythonConfiguration? {
        let fm = FileManager.default
        guard let executableURL = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("openbridge-python"),
            fm.isExecutableFile(atPath: executableURL.path),
            let resourcesURL = Bundle.main.resourceURL,
            let frameworksURL = Bundle.main.privateFrameworksURL else {
            return nil
        }

        let runtimeURL = resourcesURL.appendingPathComponent("python-runtime")
        let versionURL = runtimeURL.appendingPathComponent("python-version")
        let sitePackagesURL = runtimeURL.appendingPathComponent("site-packages")
        let helperBinariesURL = executableURL.deletingLastPathComponent()
        guard fm.fileExists(atPath: sitePackagesURL.path),
              let version = try? String(contentsOf: versionURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !version.isEmpty else {
            return nil
        }

        let pythonHomeURL = frameworksURL
            .appendingPathComponent("Python.framework")
            .appendingPathComponent("Versions")
            .appendingPathComponent(version)
        guard fm.fileExists(atPath: pythonHomeURL.path) else {
            return nil
        }

        let engineSourceURL = resourcesURL.appendingPathComponent("python")
        var environment = baseEnvironment
        environment["OPENBRIDGE_ENGINE_PYTHON"] = executableURL.path
        environment["PYTHONHOME"] = pythonHomeURL.path
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["PYTHONNOUSERSITE"] = "1"
        environment["PYTHONPATH"] = pythonPath(
            prepending: [sitePackagesURL.path, engineSourceURL.path],
            to: environment["PYTHONPATH"]
        )
        environment["PATH"] = pythonPath(
            prepending: [helperBinariesURL.path],
            to: environment["PATH"]
        )

        let ffmpegURL = helperBinariesURL.appendingPathComponent("ffmpeg")
        if fm.isExecutableFile(atPath: ffmpegURL.path) {
            environment["OPENBRIDGE_FFMPEG_PATH"] = ffmpegURL.path
        }

        return PythonConfiguration(executableURL: executableURL, environment: environment)
    }

    private func environmentWithToolPathDefaults(_ environment: [String: String]) -> [String: String] {
        var updated = environment
        let preferredPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let existingPaths = (updated["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        var mergedPaths: [String] = []

        for path in preferredPaths + existingPaths where !mergedPaths.contains(path) {
            mergedPaths.append(path)
        }

        updated["PATH"] = mergedPaths.joined(separator: ":")
        return updated
    }

    private func pythonPath(prepending paths: [String], to existingValue: String?) -> String {
        var mergedPaths: [String] = []
        for path in paths where !path.isEmpty && !mergedPaths.contains(path) {
            mergedPaths.append(path)
        }
        for path in (existingValue ?? "").split(separator: ":").map(String.init)
            where !path.isEmpty && !mergedPaths.contains(path) {
            mergedPaths.append(path)
        }
        return mergedPaths.joined(separator: ":")
    }

    private func engineScriptURL() throws -> URL {
        let fm = FileManager.default
        if let explicit = ProcessInfo.processInfo.environment["OPENBRIDGE_ENGINE_SCRIPT"] {
            let url = URL(fileURLWithPath: explicit)
            if fm.fileExists(atPath: url.path) {
                return url
            }
        }

        let cwdURL = URL(fileURLWithPath: fm.currentDirectoryPath)
        let cwdScript = cwdURL.appendingPathComponent("engine_cli.py")
        if fm.fileExists(atPath: cwdScript.path) {
            return cwdScript
        }

        if let resourceScript = Bundle.main.resourceURL?.appendingPathComponent("python/engine_cli.py"),
           fm.fileExists(atPath: resourceScript.path) {
            return resourceScript
        }

        throw EngineServiceError.missingScript
    }

    private func decodeEngineError(from data: Data) -> EngineErrorResponse? {
        guard !data.isEmpty else { return nil }
        return try? decoder.decode(EngineErrorResponse.self, from: data)
    }
}
