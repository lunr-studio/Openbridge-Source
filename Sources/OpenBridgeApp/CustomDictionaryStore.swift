import Foundation

struct CustomDictionaryEntry: Equatable, Identifiable {
    let id: UUID
    var heardAs: String
    var replaceWith: String

    init(id: UUID = UUID(), heardAs: String, replaceWith: String) {
        self.id = id
        self.heardAs = heardAs
        self.replaceWith = replaceWith
    }
}

enum CustomDictionaryMutationResult: Equatable {
    case saved
    case emptyHeardAs
    case emptyReplaceWith
    case duplicateHeardAs
    case missingEntry
    case storageFailed(String)

    var message: String? {
        switch self {
        case .saved:
            return nil
        case .emptyHeardAs:
            return "Enter the phrase OpenBridge hears."
        case .emptyReplaceWith:
            return "Enter the replacement text."
        case .duplicateHeardAs:
            return "A custom dictionary entry already exists for that phrase."
        case .missingEntry:
            return "The custom dictionary entry no longer exists."
        case .storageFailed(let details):
            return "Custom dictionary could not be saved: \(details)"
        }
    }
}

struct CustomDictionaryStore {
    enum Permissions {
        static let directory = 0o700
        static let file = 0o600
    }

    enum ValidationError: LocalizedError, Equatable {
        case emptyHeardAs
        case emptyReplaceWith
        case duplicateHeardAs(String)

        var errorDescription: String? {
            switch self {
            case .emptyHeardAs:
                return "Enter the phrase OpenBridge hears."
            case .emptyReplaceWith:
                return "Enter the replacement text."
            case .duplicateHeardAs(let phrase):
                return "A custom dictionary entry already exists for \"\(phrase)\"."
            }
        }
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
            .appendingPathComponent("custom_dictionary.json")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder

        self.decoder = JSONDecoder()
    }

    func load() throws -> [CustomDictionaryEntry] {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return []
        }

        let data = try Data(contentsOf: fileURL)
        let pairs = try decoder.decode([String: String].self, from: data)
        let entries = pairs.map { CustomDictionaryEntry(heardAs: $0.key, replaceWith: $0.value) }
        return try Self.validatedEntries(entries)
            .sorted { $0.heardAs.localizedCaseInsensitiveCompare($1.heardAs) == .orderedAscending }
    }

    @discardableResult
    func save(_ entries: [CustomDictionaryEntry]) throws -> [CustomDictionaryEntry] {
        let normalizedEntries = try Self.validatedEntries(entries)
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
        let pairs = Dictionary(uniqueKeysWithValues: normalizedEntries.map { ($0.heardAs, $0.replaceWith) })
        let data = try encoder.encode(pairs)
        try data.write(to: fileURL, options: [.atomic])
        try fileManager.setAttributes(
            [.posixPermissions: Permissions.file],
            ofItemAtPath: fileURL.path
        )
        return normalizedEntries
    }

    static func validatedEntries(_ entries: [CustomDictionaryEntry]) throws -> [CustomDictionaryEntry] {
        var normalizedEntries: [CustomDictionaryEntry] = []
        var seenHeardAs: Set<String> = []

        for entry in entries {
            let heardAs = entry.heardAs.trimmingCharacters(in: .whitespacesAndNewlines)
            let replaceWith = entry.replaceWith.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !heardAs.isEmpty else {
                throw ValidationError.emptyHeardAs
            }
            guard !replaceWith.isEmpty else {
                throw ValidationError.emptyReplaceWith
            }

            let duplicateKey = heardAs.lowercased()
            guard seenHeardAs.insert(duplicateKey).inserted else {
                throw ValidationError.duplicateHeardAs(heardAs)
            }

            normalizedEntries.append(
                CustomDictionaryEntry(id: entry.id, heardAs: heardAs, replaceWith: replaceWith)
            )
        }

        return normalizedEntries
    }
}
