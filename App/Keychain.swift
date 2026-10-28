import BMWCodingCore
import Foundation
import Security

/// A Keychain call that did not succeed, with the status it returned.
struct KeychainError: Error, CustomStringConvertible {
    let status: OSStatus

    /// What the system says the status means, or `Keychain error <status>` when it says nothing.
    var description: String {
        SecCopyErrorMessageString(status, nil).map { $0 as String } ?? "Keychain error \(status)"
    }
}

/// The owner's secrets, each a generic password under the app's service that stays on this device: the Anthropic API
/// key (`anthropic-api-key`), the ChatGPT sign-in (`chatgpt-account`) and the device's registration with OpenAI
/// (`chatgpt-registration`). The Mac uses the login keychain, which needs no keychain-access-group entitlement.
enum Keychain {
    /// The item saved under `account`, or nil when none is saved or it cannot be read.
    static func data(for account: String) -> Data? {
        var query = item(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    /// Saves `data` under `account`, replacing what was saved before.
    static func set(_ data: Data, for account: String) throws {
        var status = SecItemUpdate(item(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var new = item(account)
            new[kSecValueData as String] = data
            new[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(new as CFDictionary, nil)
        }
        if status != errSecSuccess { throw KeychainError(status: status) }
    }

    /// Removes the item saved under `account`; none being saved is not an error.
    static func delete(_ account: String) throws {
        let status = SecItemDelete(item(account) as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound { throw KeychainError(status: status) }
    }

    /// The API key, or nil when none is saved or it cannot be read.
    static func apiKey() -> String? {
        data(for: apiKeyAccount).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func setAPIKey(_ key: String) throws { try set(Data(key.utf8), for: apiKeyAccount) }

    static func deleteAPIKey() throws { try delete(apiKeyAccount) }

    private static let apiKeyAccount = "anthropic-api-key"

    /// What finds the item saved under `account`.
    private static func item(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.smidley.vynscope",
            kSecAttrAccount as String: account,
        ]
    }
}

/// The ChatGPT sign-in as `ChatGPTSession` keeps it, in the Keychain: the account in `chatgpt-account`, the host and
/// client ids in `chatgpt-registration`, each as JSON with ISO 8601 dates. They are read once, here; a record that
/// cannot be decoded reads as none. Each change is written as it is made, and a write that fails keeps the value for
/// this run only.
final class KeychainAccountStore: ChatGPTAccountStore {
    var account: ChatGPTAccount? {
        didSet { Self.write(account, to: Self.accountItem) }
    }
    var hostID: String? {
        didSet { writeRegistration() }
    }
    var clientID: String? {
        didSet { writeRegistration() }
    }

    init() {
        account = Self.read(ChatGPTAccount.self, from: Self.accountItem)
        let registration = Self.read(Registration.self, from: Self.registrationItem)
        hostID = registration?.hostID
        clientID = registration?.clientID
    }

    private struct Registration: Codable {
        var hostID: String?
        var clientID: String?
    }

    private static let accountItem = "chatgpt-account"
    private static let registrationItem = "chatgpt-registration"

    private func writeRegistration() {
        Self.write(Registration(hostID: hostID, clientID: clientID), to: Self.registrationItem)
    }

    private static func read<Value: Decodable>(_ type: Value.Type, from item: String) -> Value? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return Keychain.data(for: item).flatMap { try? decoder.decode(type, from: $0) }
    }

    /// Saves `value` as JSON under `item`, or removes the item when `value` is nil.
    private static func write<Value: Encodable>(_ value: Value?, to item: String) {
        guard let value else {
            try? Keychain.delete(item)
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return }  // cannot fail: strings, numbers and dates
        try? Keychain.set(data, for: item)
    }
}
