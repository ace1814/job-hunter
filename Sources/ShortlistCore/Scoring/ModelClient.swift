import Foundation

public struct TokenUsage: Codable, Equatable, Sendable {
    public var input = 0
    /// Includes `reasoning`, which is billed as output.
    public var output = 0
    public var reasoning = 0

    public init(input: Int = 0, output: Int = 0, reasoning: Int = 0) {
        self.input = input
        self.output = output
        self.reasoning = reasoning
    }

    public static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(input: lhs.input + rhs.input, output: lhs.output + rhs.output, reasoning: lhs.reasoning + rhs.reasoning)
    }
}

/// A request for one JSON answer that follows `schema`.
public struct ModelRequest: Sendable {
    public var system: String
    public var user: String
    public var schemaName: String
    /// A JSON Schema, as JSON text.
    public var schema: String
    public var maxOutputTokens: Int

    public init(system: String, user: String, schemaName: String, schema: String, maxOutputTokens: Int) {
        self.system = system
        self.user = user
        self.schemaName = schemaName
        self.schema = schema
        self.maxOutputTokens = maxOutputTokens
    }
}

public struct ModelReply: Equatable, Sendable {
    public var json: String
    public var usage: TokenUsage

    public init(json: String, usage: TokenUsage = TokenUsage()) {
        self.json = json
        self.usage = usage
    }
}

/// One way of asking a model for structured JSON. The rest of the app doesn't know which.
public protocol ModelClient: Sendable {
    /// The model's name, saved next to everything it produces.
    var name: String { get }
    /// How many requests to run at once.
    var parallelism: Int { get }
    func complete(_ request: ModelRequest) async throws -> ModelReply
}

public enum ModelError: LocalizedError, Equatable {
    case missingKey
    case lockedKey
    case rejectedKey
    case noCredit
    case rateLimited
    case server(Int)
    case badRequest(String)
    case unreachable(String)
    case network(String)
    case refused(String)
    case truncated(String)
    case unreadable(String)
    case emptyProfile

    public var errorDescription: String? {
        switch self {
        case .missingKey: "Add your OpenAI key in Profile first."
        case .lockedKey: "macOS didn't let Shortlist read your key. Press Score again and choose Always Allow."
        case .rejectedKey: "OpenAI rejected the key. Check it in Profile."
        case .noCredit: "Your OpenAI account is out of credit."
        case .rateLimited: "OpenAI is limiting requests. Try again in a minute."
        case .server(let code): "The model server answered \(code)."
        case .badRequest(let message): "The model server refused the request: \(message)"
        case .unreachable(let name): "Couldn't reach \(name)."
        case .network(let message): "Network problem: \(message)"
        case .refused(let message): "The model declined: \(message)"
        case .truncated(let reason): "The model's answer was cut short (\(reason))."
        case .unreadable(let detail): "Couldn't read the model's answer: \(detail)"
        case .emptyProfile: "Fill in your target roles or import your resume first."
        }
    }

    /// Errors every later job would hit too, so the run stops instead of repeating them.
    var stopsTheRun: Bool {
        switch self {
        case .missingKey, .lockedKey, .rejectedKey, .noCredit, .badRequest, .unreachable, .emptyProfile: true
        case .rateLimited, .server, .network, .refused, .truncated, .unreadable: false
        }
    }

    var isWorthRetrying: Bool {
        switch self {
        case .rateLimited, .server, .network: true
        default: false
        }
    }
}

extension ModelClient {
    /// `complete`, with a few waits for rate limits and passing server trouble.
    func completeWithRetries(_ request: ModelRequest, delays: [Duration] = [.seconds(2), .seconds(8)]) async throws -> ModelReply {
        for delay in delays {
            do {
                return try await complete(request)
            } catch let error as ModelError where error.isWorthRetrying {
                try await Task.sleep(for: delay)
            }
        }
        return try await complete(request)
    }
}

extension HTTPClient {
    /// POSTs JSON, turning connection failures into `ModelError`s.
    fileprivate func postJSON(_ url: URL, serverName: String, headers: [String: String] = [:], body: [String: Any]) async throws -> (data: Data, status: Int) {
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        do {
            return try await post(url, headers: headers.merging(["Content-Type": "application/json"]) { $1 }, body: data)
        } catch let error as URLError {
            switch error.code {
            case .cancelled: throw CancellationError()
            case .cannotConnectToHost, .cannotFindHost: throw ModelError.unreachable(serverName)
            default: throw ModelError.network(error.localizedDescription)
            }
        }
    }
}

private func parsedSchema(_ text: String) throws -> Any {
    try JSONSerialization.jsonObject(with: Data(text.utf8))
}

// MARK: - OpenAI

/// The OpenAI Responses API with strict structured output. Nothing is stored on OpenAI's side
/// beyond what `store: false` leaves it.
public struct OpenAIClient: ModelClient {
    public let name: String
    public let parallelism = 4
    private let apiKey: String
    private let reasoningEffort: String?
    private let http: any HTTPClient
    private let endpoint = URL(string: "https://api.openai.com/v1/responses")!

    /// `reasoningEffort` nil leaves it to the model's default.
    public init(model: String, apiKey: String, reasoningEffort: String? = nil, http: any HTTPClient = URLSessionHTTPClient()) {
        name = model
        self.apiKey = apiKey
        self.reasoningEffort = reasoningEffort
        self.http = http
    }

    public func complete(_ request: ModelRequest) async throws -> ModelReply {
        var body: [String: Any] = [
            "model": name,
            "store": false,
            "max_output_tokens": request.maxOutputTokens,
            "input": [
                ["role": "system", "content": request.system],
                ["role": "user", "content": request.user],
            ],
            "text": ["format": [
                "type": "json_schema",
                "name": request.schemaName,
                "strict": true,
                "schema": try parsedSchema(request.schema),
            ] as [String: Any]],
        ]
        if let reasoningEffort { body["reasoning"] = ["effort": reasoningEffort] }

        let (data, status) = try await http.postJSON(
            endpoint, serverName: "OpenAI", headers: ["Authorization": "Bearer \(apiKey)"], body: body)
        guard (200..<300).contains(status) else { throw Self.error(status: status, data: data) }
        return try Self.reply(from: data)
    }

    static func reply(from data: Data) throws -> ModelReply {
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw ModelError.unreadable(String(describing: error))
        }
        if response.status == "incomplete" {
            throw ModelError.truncated(response.incomplete_details?.reason ?? "unknown")
        }
        let parts = response.output.first { $0.type == "message" }?.content ?? []
        if let refusal = parts.first(where: { $0.type == "refusal" }) {
            throw ModelError.refused(refusal.refusal ?? "no reason given")
        }
        guard let text = parts.first(where: { $0.type == "output_text" })?.text else {
            throw ModelError.unreadable("no text in the response")
        }
        let usage = TokenUsage(input: response.usage?.input_tokens ?? 0, output: response.usage?.output_tokens ?? 0,
                               reasoning: response.usage?.output_tokens_details?.reasoning_tokens ?? 0)
        return ModelReply(json: text, usage: usage)
    }

    static func error(status: Int, data: Data) -> ModelError {
        let detail = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
        switch status {
        case 401, 403: return .rejectedKey
        case 429: return detail?.code == "insufficient_quota" ? .noCredit : .rateLimited
        case 400..<500: return .badRequest(detail?.message ?? "status \(status)")
        default: return .server(status)
        }
    }

    private struct Response: Decodable {
        var status: String?
        var incomplete_details: Incomplete?
        var output: [Item]
        var usage: Usage?

        struct Incomplete: Decodable {
            var reason: String?
        }
        struct Item: Decodable {
            var type: String
            var content: [Part]?
        }
        struct Part: Decodable {
            var type: String
            var text: String?
            var refusal: String?
        }
        struct Usage: Decodable {
            var input_tokens: Int?
            var output_tokens: Int?
            var output_tokens_details: Details?

            struct Details: Decodable {
                var reasoning_tokens: Int?
            }
        }
    }

    private struct ErrorBody: Decodable {
        var error: Detail

        struct Detail: Decodable {
            var message: String?
            var code: String?
        }
    }
}

// MARK: - Ollama

/// A model running on this Mac through Ollama. Free and offline, one job at a time.
public struct OllamaClient: ModelClient {
    public let name: String
    public let parallelism = 1
    private let baseURL: URL
    private let http: any HTTPClient

    public init(model: String, baseURL: URL = URL(string: "http://localhost:11434")!, http: any HTTPClient = URLSessionHTTPClient()) {
        name = model
        self.baseURL = baseURL
        self.http = http
    }

    public func complete(_ request: ModelRequest) async throws -> ModelReply {
        let body: [String: Any] = [
            "model": name,
            "stream": false,
            "think": false,
            "format": try parsedSchema(request.schema),
            "options": ["temperature": 0],
            "messages": [
                ["role": "system", "content": request.system],
                ["role": "user", "content": request.user],
            ],
        ]
        let (data, status) = try await http.postJSON(
            baseURL.appending(path: "api/chat"), serverName: "Ollama. Is it running?", body: body)
        switch status {
        case 200..<300: break
        case 404: throw ModelError.badRequest("\(name) isn't installed. Run: ollama pull \(name)")
        case 400..<500: throw ModelError.badRequest("status \(status)")
        default: throw ModelError.server(status)
        }
        do {
            let response = try JSONDecoder().decode(Response.self, from: data)
            return ModelReply(json: response.message.content,
                              usage: TokenUsage(input: response.prompt_eval_count ?? 0, output: response.eval_count ?? 0))
        } catch {
            throw ModelError.unreadable(String(describing: error))
        }
    }

    private struct Response: Decodable {
        var message: Message
        var prompt_eval_count: Int?
        var eval_count: Int?

        struct Message: Decodable {
            var content: String
        }
    }
}
