import Foundation
import Security

/// Which model scores jobs. Names live here, not in code, so a better model is a settings change.
public struct ScoringSettings: Codable, Equatable, Sendable {
    public enum Provider: String, Codable, CaseIterable, Sendable {
        case openAI, ollama
    }

    public var provider: Provider = .openAI
    public var openAIModel = "gpt-6-luna"
    /// "none" skips reasoning, which is billed as output. Blank uses the model's default.
    public var reasoningEffort = "none"
    public var ollamaModel = "qwen3:8b"

    public init() {}

    public var modelName: String { provider == .openAI ? openAIModel : ollamaModel }

    /// `apiKey` is only needed for OpenAI.
    public func makeClient(apiKey: String?, http: any HTTPClient) throws -> any ModelClient {
        switch provider {
        case .ollama:
            return OllamaClient(model: ollamaModel, http: http)
        case .openAI:
            guard let apiKey, !apiKey.isEmpty else { throw ModelError.missingKey }
            return OpenAIClient(model: openAIModel, apiKey: apiKey,
                                reasoningEffort: reasoningEffort.isEmpty ? nil : reasoningEffort, http: http)
        }
    }
}

/// What a run probably cost, for the models whose price we know. Doesn't count cached input as
/// cheaper, so it leans high.
public enum Pricing {
    /// Dollars per million tokens, from OpenAI's pricing page on 2026-10-30.
    private static let perMillion: [String: (input: Double, output: Double)] = [
        "gpt-6-luna": (0.10, 0.50),
        "gpt-6.1-sol": (2, 10),
    ]

    public static func dollars(model: String, usage: TokenUsage) -> Double? {
        perMillion[model].map {
            (Double(usage.input) * $0.input + Double(usage.output) * $0.output) / 1_000_000
        }
    }
}

/// Your OpenAI key, kept in the macOS Keychain and nowhere else.
public enum OpenAIKey {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.arpitchandak.shortlist",
         kSecAttrAccount as String: "openai-api-key"]
    }

    /// Checks without reading the secret, so it never triggers a Keychain prompt.
    public static var exists: Bool {
        var attributes = query
        attributes[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(attributes as CFDictionary, nil) == errSecSuccess
    }

    public static func load() -> String? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func save(_ key: String) throws {
        delete()
        var item = query
        item[kSecValueData as String] = Data(key.utf8)
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    public static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
