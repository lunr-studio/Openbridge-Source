enum ManagedModelMaintenancePolicy {
    static let whisperFallbackIdentifier = "whisper-base"

    static func orderedIdentifiers(
        selectedIdentifier: String,
        availableIdentifiers: [String]
    ) -> [String] {
        let available = Set(availableIdentifiers)
        var ordered: [String] = []

        for preferredIdentifier in [whisperFallbackIdentifier, selectedIdentifier] {
            if available.contains(preferredIdentifier), !ordered.contains(preferredIdentifier) {
                ordered.append(preferredIdentifier)
            }
        }

        for identifier in availableIdentifiers where !ordered.contains(identifier) {
            ordered.append(identifier)
        }
        return ordered
    }

    static func shouldWarm(identifier: String, selectedIdentifier: String) -> Bool {
        identifier == whisperFallbackIdentifier || identifier == selectedIdentifier
    }
}
