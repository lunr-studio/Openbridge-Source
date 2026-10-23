import Foundation

struct SnippetStore {
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
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        self.fileURL = supportURL
            .appendingPathComponent("OpenBridge", isDirectory: true)
            .appendingPathComponent("snippets.json")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func load() throws -> [Snippet] {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return []
        }

        let data = try Data(contentsOf: fileURL)
        return try decoder.decode([Snippet].self, from: data)
    }

    func save(_ snippets: [Snippet]) throws {
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
        let data = try encoder.encode(snippets)
        try data.write(to: fileURL, options: [.atomic])
        try fileManager.setAttributes(
            [.posixPermissions: Permissions.file],
            ofItemAtPath: fileURL.path
        )
    }
}
