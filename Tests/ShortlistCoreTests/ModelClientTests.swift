import XCTest
@testable import ShortlistCore

final class ModelClientTests: XCTestCase {
    private let openAIURL = "https://api.openai.com/v1/responses"
    private let request = ModelRequest(system: "sys", user: "usr", schemaName: "answer",
                                       schema: #"{"type":"object"}"#, maxOutputTokens: 100)

    private func client(_ http: StubHTTP) -> OpenAIClient {
        OpenAIClient(model: "gpt-6-luna", apiKey: "test-key", reasoningEffort: "none", http: http)
    }

    private func completed(_ text: String) -> String {
        """
        {"id": "resp_1", "status": "completed", "incomplete_details": null,
         "output": [
           {"type": "reasoning", "summary": []},
           {"type": "message", "role": "assistant",
            "content": [{"type": "output_text", "text": \(String(reflecting: text))}]}
         ],
         "usage": {"input_tokens": 81, "output_tokens": 11, "total_tokens": 92,
                   "output_tokens_details": {"reasoning_tokens": 3}}}
        """
    }

    func test_openAI_sendsStrictSchemaWithoutStoringAndReadsTheMessage() async throws {
        let http = StubHTTP()
        http.serve(openAIURL, json: completed("{}"))

        let reply = try await client(http).complete(request)

        XCTAssertEqual(reply, ModelReply(json: "{}", usage: TokenUsage(input: 81, output: 11, reasoning: 3)))
        XCTAssertEqual(http.postHeaders.first?["Authorization"], "Bearer test-key")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: http.postBodies[0]) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "gpt-6-luna")
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["max_output_tokens"] as? Int, 100)
        XCTAssertEqual((body["reasoning"] as? [String: String])?["effort"], "none")
        let format = try XCTUnwrap((body["text"] as? [String: Any])?["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertEqual(format["name"] as? String, "answer")
        XCTAssertEqual(format["strict"] as? Bool, true)
        XCTAssertEqual((format["schema"] as? [String: String])?["type"], "object")
    }

    func test_openAI_refusalAndCutOffAnswersAreErrors() async throws {
        let refused = """
            {"status": "completed", "output": [{"type": "message", "content": [{"type": "refusal", "refusal": "No."}]}]}
            """
        XCTAssertThrowsError(try OpenAIClient.reply(from: Data(refused.utf8))) {
            XCTAssertEqual($0 as? ModelError, .refused("No."))
        }
        let incomplete = """
            {"status": "incomplete", "incomplete_details": {"reason": "max_output_tokens"}, "output": []}
            """
        XCTAssertThrowsError(try OpenAIClient.reply(from: Data(incomplete.utf8))) {
            XCTAssertEqual($0 as? ModelError, .truncated("max_output_tokens"))
        }
    }

    func test_openAI_statusCodesBecomeUsefulErrors() {
        func error(_ status: Int, _ json: String = "{}") -> ModelError {
            OpenAIClient.error(status: status, data: Data(json.utf8))
        }
        XCTAssertEqual(error(401), .rejectedKey)
        XCTAssertEqual(error(429, #"{"error": {"message": "slow down", "code": "rate_limit_exceeded"}}"#), .rateLimited)
        XCTAssertEqual(error(429, #"{"error": {"message": "pay up", "code": "insufficient_quota"}}"#), .noCredit)
        XCTAssertEqual(error(400, #"{"error": {"message": "bad schema"}}"#), .badRequest("bad schema"))
        XCTAssertEqual(error(503), .server(503))
    }

    func test_ollama_sendsSchemaAsFormatAndReadsTheMessage() async throws {
        let http = StubHTTP()
        http.serve("http://localhost:11434/api/chat", json: """
            {"message": {"role": "assistant", "content": "{\\"a\\": 1}"}, "done": true,
             "prompt_eval_count": 50, "eval_count": 20}
            """)

        let reply = try await OllamaClient(model: "qwen3:8b", http: http).complete(request)

        XCTAssertEqual(reply, ModelReply(json: #"{"a": 1}"#, usage: TokenUsage(input: 50, output: 20)))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: http.postBodies[0]) as? [String: Any])
        XCTAssertEqual(body["stream"] as? Bool, false)
        XCTAssertEqual((body["format"] as? [String: String])?["type"], "object")
    }

    func test_ollama_missingModelSaysHowToGetIt() async {
        do {
            _ = try await OllamaClient(model: "qwen3:8b", http: StubHTTP()).complete(request)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ModelError, .badRequest("qwen3:8b isn't installed. Run: ollama pull qwen3:8b"))
        }
    }

    func test_openAINeedsAKey() {
        XCTAssertThrowsError(try ScoringSettings().makeClient(apiKey: nil, http: StubHTTP())) {
            XCTAssertEqual($0 as? ModelError, .missingKey)
        }
    }

    func test_passingTroubleIsRetriedAndOtherErrorsAreNot() async throws {
        let flaky = FakeModel(failures: [.server(503), .rateLimited])
        _ = try await flaky.completeWithRetries(request, delays: [.zero, .zero])
        XCTAssertEqual(flaky.calls, 3)

        let rejected = FakeModel(failures: [.rejectedKey])
        do {
            _ = try await rejected.completeWithRetries(request, delays: [.zero, .zero])
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(rejected.calls, 1)
        }
    }

    func test_cost() throws {
        let dollars = try XCTUnwrap(Pricing.dollars(model: "gpt-6-luna", usage: TokenUsage(input: 9_000_000, output: 450_000)))
        XCTAssertEqual(dollars, 1.125, accuracy: 0.0001)
        XCTAssertNil(Pricing.dollars(model: "qwen3:8b", usage: TokenUsage(input: 1)))
    }
}

/// Answers from a script. Each job's answer can depend on the request.
final class FakeModel: ModelClient, @unchecked Sendable {
    let name = "fake-model"
    let parallelism: Int
    private let lock = NSLock()
    private var failures: [ModelError]
    private var callCount = 0
    private var requests: [ModelRequest] = []
    private let answer: @Sendable (ModelRequest) -> String

    init(parallelism: Int = 2, failures: [ModelError] = [],
         answer: @escaping @Sendable (ModelRequest) -> String = { _ in FakeModel.assessment() }) {
        self.parallelism = parallelism
        self.failures = failures
        self.answer = answer
    }

    var calls: Int { lock.withLock { callCount } }
    var seen: [ModelRequest] { lock.withLock { requests } }

    func complete(_ request: ModelRequest) async throws -> ModelReply {
        try lock.withLock {
            callCount += 1
            requests.append(request)
            if !failures.isEmpty { throw failures.removeFirst() }
            return ModelReply(json: answer(request), usage: TokenUsage(input: 100, output: 10))
        }
    }

    static func assessment(role: Int = 4, experience: Int = 4, seniority: Int = 4, location: Int = 4, mustHaves: Int = 4,
                           dealbreaker: Bool = false) -> String {
        """
        {"criteria": {"role": \(role), "experience": \(experience), "seniority": \(seniority),
                      "location": \(location), "mustHaves": \(mustHaves)},
         "dealbreakerHit": \(dealbreaker),
         "strengths": ["one", "two", "three", "four"], "gaps": [], "rationale": "Worth applying."}
        """
    }
}
