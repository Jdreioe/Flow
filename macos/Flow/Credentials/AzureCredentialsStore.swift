import Foundation
import Security

struct AzureSpeechCredentials: Codable, Equatable {
    let endpoint: String
    let subscriptionKey: String

    init(endpoint rawEndpoint: String, subscriptionKey rawKey: String) throws {
        guard let endpoint = AzureSpeechEndpoint.normalize(rawEndpoint) else {
            throw AzureConfigurationError.invalidEndpoint
        }
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains(where: \.isWhitespace) else {
            throw AzureConfigurationError.invalidKey
        }
        self.endpoint = endpoint
        subscriptionKey = key
    }
}

enum AzureConfigurationError: LocalizedError {
    case invalidEndpoint
    case invalidKey
    case invalidVoice
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: L10n.string("Enter an Azure Speech region or HTTPS endpoint.")
        case .invalidKey: L10n.string("Enter a valid Azure Speech subscription key.")
        case .invalidVoice: L10n.string("Enter a valid Azure neural voice name.")
        case .keychain: L10n.string("Flow could not save the Azure credential in your Keychain.")
        }
    }
}

enum AzureSpeechEndpoint {
    static func normalize(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty, !value.contains(where: \.isWhitespace) else { return nil }
        if !value.contains(".") && !value.contains("://") {
            return value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
                ? "https://\(value).tts.speech.microsoft.com"
                : nil
        }
        let candidate = value.contains("://") ? value : "https://\(value)"
        guard let components = URLComponents(string: candidate),
              components.scheme == "https",
              let host = components.host,
              components.user == nil,
              components.password == nil,
              components.port == nil || components.port == 443,
              components.path.isEmpty || components.path == "/",
              components.query == nil,
              components.fragment == nil else { return nil }
        let supported = host.hasSuffix(".tts.speech.microsoft.com") ||
            host.hasSuffix(".tts.speech.azure.com") ||
            host.hasSuffix(".cognitiveservices.azure.com")
        guard supported, host.split(separator: ".").count >= 4 else { return nil }
        return "https://\(host)"
    }
}

enum AzureCredentialsStore {
    private static let service = "io.github.jdreioe.flow.azure-speech"
    private static let account = "byok"

    static func load() -> AzureSpeechCredentials? {
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
        return try? JSONDecoder().decode(AzureSpeechCredentials.self, from: data)
    }

    static func save(_ credentials: AzureSpeechCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        clear()
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw AzureConfigurationError.keychain(status) }
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
