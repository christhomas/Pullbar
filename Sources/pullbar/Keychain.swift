import Foundation
import Security

struct KeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
    }
}

/// Stores the GitHub token as a generic password in the user's login keychain.
enum Keychain {
    static let defaultService = "pullbar GitHub token"
    /// Where PR Inbox, pullbar's former name, kept the token.
    static let legacyService = "PRInbox GitHub token"
    private static let account = "github.com"

    private static func baseQuery(service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func readToken(service: String = defaultService) -> String? {
        var query = baseQuery(service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    static func writeToken(_ token: String, service: String = defaultService) throws {
        deleteToken(service: service)
        var attrs = baseQuery(service: service)
        attrs[kSecValueData as String] = Data(token.utf8)
        attrs[kSecAttrLabel as String] = "pullbar (GitHub)"
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    static func deleteToken(service: String = defaultService) {
        SecItemDelete(baseQuery(service: service) as CFDictionary)
    }

    /// Moves a token saved under `legacy` to `service` and deletes the old
    /// item, so upgrading from PR Inbox keeps the user signed in. Returns the
    /// token, or nil when there was none. If saving fails the old item stays,
    /// and the move is tried again on the next launch.
    static func migrateToken(from legacy: String = legacyService, to service: String = defaultService) -> String? {
        guard let token = readToken(service: legacy) else { return nil }
        do {
            try writeToken(token, service: service)
        } catch {
            return token
        }
        deleteToken(service: legacy)
        return token
    }
}
