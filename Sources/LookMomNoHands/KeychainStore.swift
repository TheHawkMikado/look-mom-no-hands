import Foundation
import Security

/// Minimal Keychain wrapper for the Anthropic API key. Never store the key in
/// UserDefaults or the app bundle — it would ship in plaintext.
enum KeychainStore {
    private static let service = AppIdentity.keychainService
    /// Anthropic key lives under the historical default account; other
    /// providers (ElevenLabs) get their own account under the same service.
    static let defaultAccount = "api-key"

    static func save(_ key: String, account: String = defaultAccount) {
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    /// Removes only the item this app wrote — the manual-entry fallbacks that
    /// `load` consults are the user's own keychain items, not ours to delete.
    static func delete(account: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ] as CFDictionary)
    }

    static func load(account: String = defaultAccount) -> String? {
        // 1. The item this app writes via save().
        if let key = read(service: service, account: account) { return key }
        // The manual-item fallbacks below are Anthropic-specific.
        guard account == defaultAccount else { return nil }

        // 2. Fallback: an item added by hand in Keychain Access. When you create a
        //    password item there, the "Keychain Item Name" becomes the service and
        //    the "Account Name" becomes the account — both "Look Ma No Hands" here.
        for name in AppIdentity.manualKeychainNames {
            if let key = read(service: name, account: name) { return key }
            if let key = read(label: name) { return key }
        }
        return nil
    }

    private static func read(service: String, account: String) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        return copy(&query)
    }

    private static func read(label: String) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrLabel as String: label
        ]
        return copy(&query)
    }

    private static func copy(_ query: inout [String: Any]) -> String? {
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        // Never block on a keychain-access dialog — if the item's ACL requires UI
        // (e.g. an item created in Keychain Access), fail fast instead of hanging.
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        let s = String(decoding: data, as: UTF8.self)
        return s.isEmpty ? nil : s
    }
}
