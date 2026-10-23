import AppKit
import Darwin
import Foundation

enum OpenBridgeHelpError: LocalizedError {
    case missingScript
    case noAvailablePort
    case failedToStart(String)
    case failedToWriteDiagnostics(String)
    case serverDidNotRespond

    var errorDescription: String? {
        switch self {
        case .missingScript:
            return "Openbridge could not find the local Help server."
        case .noAvailablePort:
            return "Openbridge Help could not find an available local port."
        case .failedToStart(let message):
            return message
        case .failedToWriteDiagnostics(let message):
            return message
        case .serverDidNotRespond:
            return "Openbridge Help started, but the local page did not respond."
        }
    }
}

@MainActor
final class OpenBridgeHelpController {
    static let shared = OpenBridgeHelpController()

    private struct PythonConfiguration {
        let executableURL: URL
        let environment: [String: String]
    }

    private let portRange: ClosedRange<UInt16> = 17643...17653
    private var process: Process?
    private var activePort: UInt16?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var setupDiagnosticsURL: URL?

    private init() {}

    func openHelp(setupDiagnostics: SetupDiagnosticsSnapshot) {
        Task {
            await openHelpPage(setupDiagnostics: setupDiagnostics)
        }
    }

    func stop() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        stderrPipe = nil

        if process?.isRunning == true {
            process?.terminate()
        }
        process = nil
        activePort = nil
        if let setupDiagnosticsURL {
            try? FileManager.default.removeItem(at: setupDiagnosticsURL)
        }
        setupDiagnosticsURL = nil
    }

    func availabilityStatus() -> HelpAvailabilityStatus {
        do {
            _ = try helpServerScriptURL()
            return HelpAvailabilityStatus(
                available: true,
                message: "Local Help server files are available.",
                recovery: nil
            )
        } catch {
            return HelpAvailabilityStatus(
                available: false,
                message: error.localizedDescription,
                recovery: "Reinstall OpenBridge or use a build that includes the local Help server."
            )
        }
    }

    private func openHelpPage(setupDiagnostics: SetupDiagnosticsSnapshot) async {
        do {
            try writeSetupDiagnostics(setupDiagnostics)
            let url = try startIfNeeded()
            guard await waitForServer(at: url) else {
                throw OpenBridgeHelpError.serverDidNotRespond
            }
            NSWorkspace.shared.open(url)
        } catch {
            presentHelpError(error)
        }
    }

    private func startIfNeeded() throws -> URL {
        if let activePort, process?.isRunning == true {
            return helpURL(for: activePort)
        }

        process = nil
        activePort = nil

        let scriptURL = try helpServerScriptURL()
        let port = try availablePort()
        let python = pythonConfiguration()

        let nextProcess = Process()
        nextProcess.executableURL = python.executableURL
        nextProcess.arguments = [
            scriptURL.path,
            "--host",
            "127.0.0.1",
            "--port",
            String(port),
        ]
        nextProcess.environment = python.environment
        nextProcess.currentDirectoryURL = scriptURL.deletingLastPathComponent()

        let stdout = Pipe()
        let stderr = Pipe()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        nextProcess.standardOutput = stdout
        nextProcess.standardError = stderr
        nextProcess.terminationHandler = { [weak self, weak nextProcess] _ in
            Task { @MainActor [weak self, weak nextProcess] in
                guard let self, self.process === nextProcess else { return }
                self.stdoutPipe?.fileHandleForReading.readabilityHandler = nil
                self.stderrPipe?.fileHandleForReading.readabilityHandler = nil
                self.stdoutPipe = nil
                self.stderrPipe = nil
                self.process = nil
                self.activePort = nil
            }
        }

        do {
            try nextProcess.run()
        } catch {
            throw OpenBridgeHelpError.failedToStart("Openbridge Help could not start: \(error.localizedDescription)")
        }

        process = nextProcess
        activePort = port
        stdoutPipe = stdout
        stderrPipe = stderr
        return helpURL(for: port)
    }

    private func helpURL(for port: UInt16) -> URL {
        URL(string: "http://127.0.0.1:\(port)/help")!
    }

    private func writeSetupDiagnostics(_ snapshot: SetupDiagnosticsSnapshot) throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenBridgeHelp", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let fileURL = directoryURL.appendingPathComponent("setup-diagnostics.json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
            setupDiagnosticsURL = fileURL
        } catch {
            throw OpenBridgeHelpError.failedToWriteDiagnostics(
                "Openbridge Help could not prepare the local setup summary: \(error.localizedDescription)"
            )
        }
    }

    private func waitForServer(at url: URL) async -> Bool {
        for _ in 0..<30 {
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            request.timeoutInterval = 0.4

            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let httpResponse = response as? HTTPURLResponse,
                   (200..<500).contains(httpResponse.statusCode) {
                    return true
                }
            } catch {
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }
        return false
    }

    private func presentHelpError(_ error: Error) {
        NSApplication.shared.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Openbridge Help could not open"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func availablePort() throws -> UInt16 {
        for port in portRange where Self.canBind(port: port) {
            return port
        }
        throw OpenBridgeHelpError.noAvailablePort
    }

    private static func canBind(port: UInt16) -> Bool {
        let fileDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else { return false }
        defer { close(fileDescriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                bind(fileDescriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    private func helpServerScriptURL() throws -> URL {
        let fm = FileManager.default
        if let explicit = ProcessInfo.processInfo.environment["OPENBRIDGE_HELP_SERVER_SCRIPT"] {
            let url = URL(fileURLWithPath: explicit)
            if fm.fileExists(atPath: url.path) {
                return url
            }
        }

        let cwdURL = URL(fileURLWithPath: fm.currentDirectoryPath)
        let cwdScript = cwdURL
            .appendingPathComponent("scripts")
            .appendingPathComponent("openbridge_help_review_server.py")
        if fm.fileExists(atPath: cwdScript.path) {
            return cwdScript
        }

        if let resourceScript = Bundle.main.resourceURL?
            .appendingPathComponent("scripts")
            .appendingPathComponent("openbridge_help_review_server.py"),
            fm.fileExists(atPath: resourceScript.path) {
            return resourceScript
        }

        throw OpenBridgeHelpError.missingScript
    }

    private func pythonConfiguration() -> PythonConfiguration {
        var environment = environmentWithToolPathDefaults(ProcessInfo.processInfo.environment)
        if let setupDiagnosticsURL {
            environment["OPENBRIDGE_SETUP_DIAGNOSTICS_PATH"] = setupDiagnosticsURL.path
        }

        if let explicitPythonPath = environment["OPENBRIDGE_HELP_SERVER_PYTHON"],
           !explicitPythonPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return PythonConfiguration(
                executableURL: URL(fileURLWithPath: explicitPythonPath),
                environment: environment
            )
        }

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

        environment["OPENBRIDGE_HELP_SERVER_PYTHON"] = "/usr/bin/python3"
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

        var environment = baseEnvironment
        environment["OPENBRIDGE_HELP_SERVER_PYTHON"] = executableURL.path
        environment["PYTHONHOME"] = pythonHomeURL.path
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["PYTHONNOUSERSITE"] = "1"
        environment["PYTHONPATH"] = pythonPath(
            prepending: [sitePackagesURL.path, resourcesURL.appendingPathComponent("python").path],
            to: environment["PYTHONPATH"]
        )
        environment["PATH"] = pythonPath(
            prepending: [executableURL.deletingLastPathComponent().path],
            to: environment["PATH"]
        )

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
}
