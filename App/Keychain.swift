import Foundation
import Security

/// A Keychain call that did not succeed, with the status it returned.
struct KeychainError: Error {
    let status: OSStatus
}

/// The owner's Anthropic API key, kept in the Keychain as a generic password that stays on this device. The Mac uses
/// the login keychain, which needs no keychain-access-group entitlement.
enum Keychain {
    /// The key, or nil when none is saved or it cannot be read.
    static func apiKey() -> String? {
        var query = item
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Saves `key`, replacing the one saved before.
    static func setAPIKey(_ key: String) throws {
        let data = Data(key.utf8)
        var status = SecItemUpdate(item as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var new = item
            new[kSecValueData as String] = data
            new[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(new as CFDictionary, nil)
        }
        if status != errSecSuccess { throw KeychainError(status: status) }
    }

    /// Removes the key; none being saved is not an error.
    static func deleteAPIKey() throws {
        let status = SecItemDelete(item as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound { throw KeychainError(status: status) }
    }

    /// What finds the key's item.
    private static var item: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.smidley.vynscope",
            kSecAttrAccount as String: "anthropic-api-key",
        ]
    }
}
