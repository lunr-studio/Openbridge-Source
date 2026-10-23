import Foundation

// MARK: - Workspace model

/// Represents a user-defined workspace for organizing meetings.
///
/// Workspaces are local-only collections. Meetings reference a workspace
/// via their optional `workspaceID` field.
struct Workspace: Identifiable, Codable, Equatable {
    let id: String
    var name: String
    var createdAt: Date
    var colorHex: String  // e.g. "#4A90D9"

    init(
        id: String = UUID().uuidString,
        name: String,
        createdAt: Date = Date(),
        colorHex: String = "#4A90D9"
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.colorHex = colorHex
    }
}

// MARK: - Preset workspaces

extension Workspace {
    /// The default workspace created on first launch.
    static let defaultWorkspace = Workspace(
        id: "personal",
        name: "Personal",
        colorHex: "#4A90D9"
    )

    /// Suggested preset workspaces for new users.
    static let presets: [Workspace] = [
        Workspace(id: "personal", name: "Personal", colorHex: "#4A90D9"),
        Workspace(id: "team", name: "Team", colorHex: "#E8923A"),
        Workspace(id: "client", name: "Client", colorHex: "#5BAA6E"),
    ]
}