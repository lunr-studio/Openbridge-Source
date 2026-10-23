import Foundation

struct DictationHistoryStore {
    enum Permissions {
        static let directory = 0o700
        static let file = 0o600
    }

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    let fileURL: URL

    init(fileManager: FileManager = .default, applicationSupportDirectory: URL? = nil) {
        self.fileManager = fileManager

        let supportURL = applicationSupportDirectory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        self.fileURL = supportURL
            .appendingPathComponent("OpenBridge", isDirectory: true)
            .appendingPathComponent("dictation_history.json")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    var hasSavedHistoryFile: Bool {
        fileManager.fileExists(atPath: fileURL.path)
    }

    func load() throws -> [DictationHistoryEntry] {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return []
        }

        let data = try Data(contentsOf: fileURL)
        return try decoder.decode([DictationHistoryEntry].self, from: data)
    }

    func save(_ entries: [DictationHistoryEntry]) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: Permissions.directory]
        )
        try fileManager.setAttributes(
            [.posixPermissions: Permissions.directory],
            ofItemAtPath: directoryURL.path
        )
        let data = try encoder.encode(entries)
        try data.write(to: fileURL, options: [.atomic])
        try fileManager.setAttributes(
            [.posixPermissions: Permissions.file],
            ofItemAtPath: fileURL.path
        )
    }

    func delete() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return
        }
        try fileManager.removeItem(at: fileURL)
    }
}
