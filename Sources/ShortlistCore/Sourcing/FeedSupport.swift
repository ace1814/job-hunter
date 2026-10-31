import Foundation

// MARK: - HTTP

/// The network calls feeds and model clients make. A protocol so tests can serve saved responses.
public protocol HTTPClient: Sendable {
    func get(_ url: URL) async throws -> (data: Data, status: Int)
    func post(_ url: URL, headers: [String: String], body: Data) async throws -> (data: Data, status: Int)
}

public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        // RemoteOK refuses requests without a user agent; the others like to know who's calling.
        config.httpAdditionalHeaders = ["User-Agent": "Shortlist/0.1 (personal job search app)"]
        session = URLSession(configuration: config)
    }

    public func get(_ url: URL) async throws -> (data: Data, status: Int) {
        let (data, response) = try await session.data(from: url)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    public func post(_ url: URL, headers: [String: String], body: Data) async throws -> (data: Data, status: Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        // A local model can take a while on one job.
        request.timeoutInterval = 180
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

public enum FeedError: LocalizedError, Equatable {
    /// The board or feed doesn't exist: a wrong board name, usually.
    case notFound
    case badStatus(Int)
    case badURL(String)
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .notFound: "Not found. Check the board name."
        case .badStatus(let code): "The server answered \(code)."
        case .badURL(let text): "Not a usable URL: \(text)"
        case .unreadable(let detail): "Couldn't read the response: \(detail)"
        }
    }
}

extension HTTPClient {
    /// GETs `url` and decodes JSON, turning 404s into `.notFound`.
    func json<T: Decodable>(_ type: T.Type, from url: URL) async throws -> T {
        let data = try await okData(from: url)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw FeedError.unreadable(String(describing: error))
        }
    }

    func okData(from url: URL) async throws -> Data {
        let (data, status) = try await get(url)
        switch status {
        case 200..<300: return data
        case 404: throw FeedError.notFound
        default: throw FeedError.badStatus(status)
        }
    }
}

// MARK: - What a feed returns

/// One job as a feed describes it, before it's matched against the database.
public struct FetchedJob: Equatable, Sendable {
    public var externalID: String
    public var companyName: String
    public var title: String
    public var location: String
    public var remotePolicy: RemotePolicy
    public var url: String
    public var applyURL: String?
    public var descriptionText: String
    public var salaryText: String?
    public var postedAt: Date?

    public init(externalID: String, companyName: String, title: String, location: String = "",
                remotePolicy: RemotePolicy = .unknown, url: String, applyURL: String? = nil,
                descriptionText: String = "", salaryText: String? = nil, postedAt: Date? = nil) {
        self.externalID = externalID
        self.companyName = companyName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.location = location.trimmingCharacters(in: .whitespacesAndNewlines)
        self.remotePolicy = remotePolicy
        self.url = url
        self.applyURL = applyURL
        self.descriptionText = descriptionText
        self.salaryText = salaryText.flatMap { $0.isEmpty ? nil : $0 }
        self.postedAt = postedAt
    }
}

public struct FeedResult: Sendable {
    /// Jobs whose titles passed the filter.
    public var jobs: [FetchedJob]
    /// How many jobs the feed listed before filtering.
    public var listedCount: Int
    /// For a company's own board, the IDs of every job it lists. Anything from this board that's
    /// missing has been taken down. Nil for feeds that only show the latest few.
    public var allExternalIDs: Set<String>?
}

// MARK: - Title filter

/// Keeps jobs whose title contains one of your keywords as whole words or word starts:
/// "product design" matches "Senior Product Designer", "ux" matches "UI/UX Lead".
public struct TitleFilter: Sendable {
    private let phrases: [[String]]

    public init(keywords: [String]) {
        phrases = keywords
            .map { CompanyNormalizer.fold($0).split(separator: " ").map(String.init) }
            .filter { !$0.isEmpty }
    }

    public var isEmpty: Bool { phrases.isEmpty }

    public func matches(_ title: String) -> Bool {
        guard !phrases.isEmpty else { return true }
        let words = CompanyNormalizer.fold(title).split(separator: " ").map(String.init)
        return phrases.contains { phrase in
            guard phrase.count <= words.count else { return false }
            return (0...(words.count - phrase.count)).contains { start in
                phrase.indices.allSatisfy { i in
                    // Every word must match exactly, except the last may be the start of a word.
                    i == phrase.count - 1 ? words[start + i].hasPrefix(phrase[i]) : words[start + i] == phrase[i]
                }
            }
        }
    }
}

// MARK: - Text helpers

enum FeedText {
    /// Plain text from HTML: block tags become line breaks, list items get bullets, entities are
    /// decoded, and runs of blank lines collapse. Fast and good enough for a model to read.
    static func plain(fromHTML html: String) -> String {
        var text = html
        // Greenhouse sends HTML with its tags entity-encoded.
        if text.contains("&lt;") { text = decodeEntities(text) }
        text = text.replacing(/(?is)<(script|style)[^>]*>.*?<\/\1>/, with: "")
        text = text.replacing(/(?i)<li[^>]*>/, with: "\n• ")
        text = text.replacing(/(?i)<br\s*\/?>|<\/(p|div|h[1-6]|ul|ol|tr|section)>/, with: "\n")
        text = text.replacing(/<[^>]+>/, with: "")
        text = decodeEntities(text)
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.replacing(/[ \t\u{00A0}]+/, with: " ").trimmingCharacters(in: .whitespaces) }
        var out: [String] = []
        for line in lines where !(line.isEmpty && (out.last?.isEmpty ?? true)) {
            out.append(line)
        }
        while out.last?.isEmpty == true { out.removeLast() }
        return out.joined(separator: "\n")
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = ""
        var rest = text[...]
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            let after = rest[amp...]
            if let semi = after.prefix(10).firstIndex(of: ";"),
               let decoded = entity(String(after[after.index(after: amp)..<semi])) {
                out += decoded
                rest = after[after.index(after: semi)...]
            } else {
                out += "&"
                rest = after.dropFirst()
            }
        }
        return out + rest
    }

    private static func entity(_ name: String) -> String? {
        if name.hasPrefix("#x") || name.hasPrefix("#X") {
            return UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
        if name.hasPrefix("#") {
            return UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
        return named[name]
    }

    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "ndash": "–",
        "mdash": "—", "hellip": "…", "rsquo": "’", "lsquo": "‘", "rdquo": "”", "ldquo": "“",
        "bull": "•", "middot": "·", "copy": "©", "reg": "®", "trade": "™", "euro": "€", "pound": "£",
        "rupee": "₹",
    ]

    /// Remote, hybrid or on-site, from whatever words a feed gives.
    static func remotePolicy(from text: String) -> RemotePolicy {
        let lower = text.lowercased()
        if lower.contains("hybrid") { return .hybrid }
        if lower.contains("remote") || lower.contains("anywhere") { return .remote }
        if lower.contains("onsite") || lower.contains("on-site") || lower.contains("in office") { return .onsite }
        return .unknown
    }

    /// ISO 8601 with or without fractional seconds or a zone (no zone means UTC).
    static func date(iso text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        if let date = try? Date(text, strategy: .iso8601) { return date }
        if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
        if let date = try? Date(text + "Z", strategy: .iso8601) { return date }
        return nil
    }

    /// RSS dates: "Thu, 29 Oct 2026 22:42:13 +0000".
    static func date(rfc822 text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss Z", "dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm Z"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text.trimmingCharacters(in: .whitespaces)) { return date }
        }
        return date(iso: text)
    }

    static func salary(min: Double?, max: Double?, currency: String?, period: String? = nil) -> String? {
        let amounts = [min, max].compactMap { $0 }.filter { $0 > 0 }
        guard !amounts.isEmpty else { return nil }
        let money = amounts.map { $0.formatted(.number.notation(.compactName).precision(.fractionLength(0...1))) }
        var text = (currency.map { $0 + " " } ?? "") + money.joined(separator: "–")
        if let period, !period.isEmpty { text += " / \(period)" }
        return text
    }
}

extension URL {
    /// Builds a URL from parts, percent-encoding each path segment.
    static func api(_ base: String, _ segments: [String] = [], query: [String: String] = [:]) throws -> URL {
        guard var components = URLComponents(string: base) else { throw FeedError.badURL(base) }
        let encoded = segments.map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? $0 }
        components.percentEncodedPath += encoded.map { "/" + $0 }.joined()
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw FeedError.badURL(base) }
        return url
    }
}
