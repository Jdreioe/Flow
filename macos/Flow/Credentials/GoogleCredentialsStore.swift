import Foundation
import Security

enum GoogleConfigurationError: LocalizedError {
    case invalidKey
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidKey: L10n.string("Enter a valid Google Cloud API key.")
        case .keychain: L10n.string("Flow could not save the Google Cloud credential in your Keychain.")
        }
    }
}

enum GoogleAPIKey {
    static func validate(_ rawValue: String) throws -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(where: \.isWhitespace) else {
            throw GoogleConfigurationError.invalidKey
        }
        return value
    }
}

enum GoogleCredentialsStore {
    private static let service = "io.github.jdreioe.flow.google-cloud-tts"
    private static let account = "byok"

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ apiKey: String) throws {
        clear()
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(apiKey.utf8),
        ]
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw GoogleConfigurationError.keychain(status) }
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
