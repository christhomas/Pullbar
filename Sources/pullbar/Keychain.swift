import Foundation
import Security

struct KeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
    }
}

/// Stores the GitHub token as a generic password in the user's login keychain.
///
/// `service` defaults to pullbar's own item; tests pass a throwaway name so
/// they never touch the real token.
enum Keychain {
    static let defaultService = "pullbar GitHub token"
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
        return normalizedToken(String(decoding: data, as: UTF8.self))
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

    /// Trims whitespace; an empty token counts as no token.
    static func normalizedToken(_ raw: String) -> String? {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }
}
