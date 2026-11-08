import Foundation
import Security

/// Stores each service's credential fields as one generic-password item in the macOS Keychain (DEC-013).
/// Secrets never touch the database, preferences, logs or files.
struct KeychainStore: Sendable {
    enum KeychainError: Error, Equatable {
        case unexpectedStatus(OSStatus)
        case corruptItem
    }

    let serviceName: String

    init(serviceName: String = "app.itspendtracker.ITSpendTracker.credentials") {
        self.serviceName = serviceName
    }

    func save(_ fields: [String: String], for account: UUID) throws {
        let data = try JSONEncoder().encode(fields)
        let query = baseQuery(account)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecAttrLabel as String] = "IT Spend Tracker credentials"
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func load(for account: UUID) throws -> [String: String]? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let data = result as? Data,
              let fields = try? JSONDecoder().decode([String: String].self, from: data)
        else { throw KeychainError.corruptItem }
        return fields
    }

    func delete(for account: UUID) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func baseQuery(_ account: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account.uuidString,
        ]
    }
}
