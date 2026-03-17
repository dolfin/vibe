import Foundation
import Security

/// Thin Keychain wrapper for per-package secret storage.
/// Keys are scoped to `packageId` — the SHA-256 of the signed package manifest —
/// which is stable across re-opens and version saves of the same .vibeapp file.
enum SecretsManager {
    static let service = "ninja.gil.VibeHost.secrets"

    enum KeychainError: Error {
        case unexpectedStatus(OSStatus)
    }

    // MARK: - CRUD

    static func save(_ value: String, packageId: String, name: String) throws {
        let account = "\(packageId).\(name)"
        let data = Data(value.utf8)

        let updateQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        let updateStatus = SecItemUpdate(updateQuery as CFDictionary, [kSecValueData: data] as CFDictionary)
        if updateStatus == errSecSuccess { return }

        let addQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: data
        ]
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(addStatus)
        }
    }

    static func load(packageId: String, name: String) -> String? {
        let account = "\(packageId).\(name)"
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(packageId: String, name: String) {
        let account = "\(packageId).\(name)"
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func deleteAll(for packageId: String, names: [String]) {
        for name in names { delete(packageId: packageId, name: name) }
    }

    static func loadAll(packageId: String, names: [String]) -> [String: String] {
        var result: [String: String] = [:]
        for name in names {
            if let value = load(packageId: packageId, name: name) {
                result[name] = value
            }
        }
        return result
    }

    // MARK: - Vault entry storage (key: "vault.{entryId}")

    static func saveVaultEntry(_ value: String, id: String) throws {
        let account = "vault.\(id)"
        let data = Data(value.utf8)

        let updateQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        let updateStatus = SecItemUpdate(updateQuery as CFDictionary, [kSecValueData: data] as CFDictionary)
        if updateStatus == errSecSuccess { return }

        let addQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: data
        ]
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(addStatus)
        }
    }

    static func loadVaultEntry(id: String) -> String? {
        let account = "vault.\(id)"
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deleteVaultEntry(id: String) {
        let account = "vault.\(id)"
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
