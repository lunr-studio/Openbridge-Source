import Foundation

/// Manages durable local workspace storage under Application Support.
///
/// Workspaces are stored as a single JSON file for simplicity.
/// All operations are local-only.
struct WorkspaceStore {
    let fileURL: URL
    private let fileManager = FileManager.default

    init(rootDirectory: URL? = nil) {
        let baseDir: URL
        if let rootDirectory {
            baseDir = rootDirectory
        } else {
            let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            baseDir = appSupport
                .appendingPathComponent("OpenBridge", isDirectory: true)
                .appendingPathComponent("Meetings", isDirectory: true)
        }
        self.fileURL = baseDir.appendingPathComponent("workspaces.json")
    }

    // MARK: - CRUD

    func load() throws -> [Workspace] {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return [Workspace.defaultWorkspace]
        }

        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let workspaces = try decoder.decode([Workspace].self, from: data)

        // Ensure default workspace always exists
        if !workspaces.contains(where: { $0.id == Workspace.defaultWorkspace.id }) {
            return [Workspace.defaultWorkspace] + workspaces
        }

        return workspaces
    }

    func save(_ workspaces: [Workspace]) throws {
        let dir = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(workspaces)
        try data.write(to: fileURL, options: [Data.WritingOptions.atomic])
        try setPrivatePermissions(fileURL)
    }

    func create(_ workspace: Workspace) throws -> [Workspace] {
        var workspaces = try load()
        guard !workspaces.contains(where: { $0.id == workspace.id }) else {
            return workspaces
        }
        workspaces.append(workspace)
        try save(workspaces)
        return workspaces
    }

    func update(_ workspace: Workspace) throws -> [Workspace] {
        var workspaces = try load()
        guard let index = workspaces.firstIndex(where: { $0.id == workspace.id }) else {
            return workspaces
        }
        workspaces[index] = workspace
        try save(workspaces)
        return workspaces
    }

    func delete(id: String) throws -> [Workspace] {
        var workspaces = try load()
        // Never delete the default workspace
        guard id != Workspace.defaultWorkspace.id else { return workspaces }
        workspaces.removeAll { $0.id == id }
        try save(workspaces)
        return workspaces
    }

    // MARK: - Private

    private func setPrivatePermissions(_ url: URL) throws {
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}