import Foundation

/// Shared by the approval preview and the local evidence boundary. Website
/// selection is a restriction, not an assertion that a source is authoritative.
public enum WebSearchSourcePolicy {
    public static func domains(from draft: String) -> [String]? {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let values = draft.split(separator: ",", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        guard values.count <= 5, values.allSatisfy(validDomain) else { return nil }
        return Array(Set(values)).sorted()
    }

    public static func validDomain(_ value: String) -> Bool {
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        return value.utf8.count <= 253 && labels.count >= 2 && labels.allSatisfy {
            !$0.isEmpty && $0.utf8.count <= 63
                && $0.range(of: "^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$", options: .regularExpression) != nil
        } && labels.last!.range(of: "[a-z]", options: .regularExpression) != nil
    }

    public static func query(_ draft: String, domains: [String]) -> String {
        let query = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !domains.isEmpty else { return query }
        let sites = domains.map { "site:" + $0 }.joined(separator: " OR ")
        return query + " (" + sites + ")"
    }

    public static func allows(_ url: URL, domains: [String]) -> Bool {
        guard !domains.isEmpty else { return true }
        guard let host = url.host?.lowercased() else { return false }
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}
