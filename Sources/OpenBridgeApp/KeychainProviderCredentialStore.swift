import Foundation
import Security

/// #310: Keychain-backed credential store (production).
/// SecItem add/copy/delete for the provider API key. Tests keep using
/// the in-memory store; the settings UI injects this one.
struct KeychainProviderCredentialStore: ProviderCredentialStore {
    private let service: String
    private let account: String

    init(service: String = "dev.openbridge.providerCredentials", account: String = "researchProviderAPIKey") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    func readAPIKey() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let key = String(data: data, encoding: .utf8) else {
                throw ProviderSettingsError.keychainFailure("malformed stored credential")
            }
            return key
        case errSecItemNotFound:
            return nil
        default:
            throw ProviderSettingsError.keychainFailure("read status \(status)")
        }
    }

    func writeAPIKey(_ key: String?) throws {
        if let key {
            let data = Data(key.utf8)
            var add = baseQuery
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let updateAttrs: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            ]
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            if addStatus == errSecDuplicateItem {
                let updateQuery = baseQuery
                let status = SecItemUpdate(updateQuery as CFDictionary, updateAttrs as CFDictionary)
                guard status == errSecSuccess else {
                    throw ProviderSettingsError.keychainFailure("update status \(status)")
                }
            } else if addStatus != errSecSuccess {
                throw ProviderSettingsError.keychainFailure("add status \(addStatus)")
            }
        } else {
            let status = SecItemDelete(baseQuery as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw ProviderSettingsError.keychainFailure("delete status \(status)")
            }
        }
    }
}
