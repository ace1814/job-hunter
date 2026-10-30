import Foundation

extension SourceKind {
    public var displayName: String {
        switch self {
        case .greenhouse: "Greenhouse"
        case .lever: "Lever"
        case .ashby: "Ashby"
        case .smartRecruiters: "SmartRecruiters"
        case .remotive: "Remotive"
        case .remoteOK: "Remote OK"
        case .himalayas: "Himalayas"
        case .hackerNewsHiring: "HN Who is hiring"
        case .rss: "RSS"
        }
    }

    /// A company's own job board, which lists every open job, so jobs missing from it are closed.
    public var isCompanyBoard: Bool {
        switch self {
        case .greenhouse, .lever, .ashby, .smartRecruiters: true
        default: false
        }
    }

    /// The least time between two fetches. Remotive asks for no more than a few calls a day, and
    /// the HN thread changes slowly.
    public var minimumInterval: TimeInterval {
        switch self {
        case .remotive, .hackerNewsHiring: 6 * 3600
        case .remoteOK, .himalayas, .rss: 3600
        default: 0
        }
    }
}

extension Source {
    /// Good feeds for a senior product designer or PM, global and remote. India on-site roles come
    /// from company boards instead, which you add from your network or by pasting a careers URL.
    public static var recommended: [Source] {
        [
            Source(kind: .himalayas, name: "Himalayas: product designer", boardID: "product designer"),
            Source(kind: .himalayas, name: "Himalayas: product manager", boardID: "product manager"),
            Source(kind: .rss, name: "We Work Remotely: Design", url: "https://weworkremotely.com/categories/remote-design-jobs.rss"),
            Source(kind: .rss, name: "We Work Remotely: Product", url: "https://weworkremotely.com/categories/remote-product-jobs.rss"),
            Source(kind: .remoteOK, name: "Remote OK"),
            Source(kind: .remotive, name: "Remotive"),
            Source(kind: .hackerNewsHiring, name: "HN Who is hiring"),
        ]
    }

    /// The same feed as `other`, so adding it twice can be refused.
    public func isSameFeed(as other: Source) -> Bool {
        kind == other.kind
            && (boardID ?? "").lowercased() == (other.boardID ?? "").lowercased()
            && (url ?? "") == (other.url ?? "")
    }
}

/// Turns a pasted careers-page or feed URL into a source.
public enum SourceLocator {
    public static func source(from text: String) -> Source? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains("://") { trimmed = "https://" + trimmed }
        guard let components = URLComponents(string: trimmed), let host = components.host?.lowercased(),
              host.contains(".") else { return nil }
        let path = components.path.split(separator: "/").map(String.init)
        let first = path.first ?? ""

        func board(_ kind: SourceKind, _ id: String, url: String? = nil) -> Source? {
            guard !id.isEmpty else { return nil }
            return Source(kind: kind, name: prettyName(id), url: url, boardID: id)
        }

        switch host {
        case "boards.greenhouse.io", "job-boards.greenhouse.io", "job-boards.eu.greenhouse.io", "boards.eu.greenhouse.io":
            if first == "embed", let id = components.queryItems?.first(where: { $0.name == "for" })?.value {
                return board(.greenhouse, id)
            }
            return board(.greenhouse, first)
        case "boards-api.greenhouse.io":
            return path.count >= 3 ? board(.greenhouse, path[2]) : nil
        case "jobs.lever.co":
            return board(.lever, first)
        case "jobs.eu.lever.co":
            return board(.lever, first, url: "https://jobs.eu.lever.co/\(first)")
        case "jobs.ashbyhq.com":
            return board(.ashby, first)
        case "jobs.smartrecruiters.com", "careers.smartrecruiters.com":
            return board(.smartRecruiters, first)
        default:
            guard components.scheme == "https" || components.scheme == "http" else { return nil }
            return Source(kind: .rss, name: host.replacingOccurrences(of: "www.", with: ""), url: trimmed)
        }
    }

    /// "razorpay" → "Razorpay", "acme-labs" → "Acme Labs".
    static func prettyName(_ slug: String) -> String {
        slug.split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

/// Looks for a company's public job board by guessing its board name on each ATS.
public struct BoardFinder: Sendable {
    public struct Board: Equatable, Sendable, Identifiable {
        public var kind: SourceKind
        public var boardID: String
        public var openJobs: Int
        public var id: String { "\(kind.rawValue):\(boardID)" }
    }

    private let http: any HTTPClient

    public init(http: any HTTPClient) {
        self.http = http
    }

    /// Board names a company is likely to use: "Tata Consultancy" → tataconsultancy, tata-consultancy.
    public static func candidates(for company: String) -> [String] {
        let words = CompanyNormalizer.normalize(company).split(separator: " ")
        guard !words.isEmpty else { return [] }
        var seen = Set<String>()
        return [words.joined(), words.joined(separator: "-")].filter { seen.insert($0).inserted }
    }

    public func find(company: String) async -> [Board] {
        let probes = Self.candidates(for: company).flatMap { slug in
            [SourceKind.greenhouse, .lever, .ashby, .smartRecruiters].map { (kind: $0, slug: slug) }
        }
        let found = await withTaskGroup(of: Board?.self) { group in
            for probe in probes {
                group.addTask { await self.probe(probe.kind, probe.slug) }
            }
            var boards: [Board] = []
            for await board in group {
                if let board { boards.append(board) }
            }
            return boards
        }
        return found.sorted { ($0.openJobs, $1.id) > ($1.openJobs, $0.id) }
    }

    private struct Count: Decodable {
        var jobs: [Ignored]?
        var totalFound: Int?
    }

    private struct Ignored: Decodable {}

    func probe(_ kind: SourceKind, _ slug: String) async -> Board? {
        do {
            switch kind {
            case .greenhouse:
                let url = try URL.api("https://boards-api.greenhouse.io/v1/boards", [slug, "jobs"])
                let count = try await http.json(Count.self, from: url).jobs?.count ?? 0
                return Board(kind: kind, boardID: slug, openJobs: count)
            case .lever:
                let url = try URL.api("https://api.lever.co/v0/postings", [slug], query: ["mode": "json"])
                return Board(kind: kind, boardID: slug, openJobs: try await http.json([Ignored].self, from: url).count)
            case .ashby:
                let url = try URL.api("https://api.ashbyhq.com/posting-api/job-board", [slug])
                let count = try await http.json(Count.self, from: url).jobs?.count ?? 0
                return Board(kind: kind, boardID: slug, openJobs: count)
            case .smartRecruiters:
                // SmartRecruiters answers for any name, so only a board with jobs counts.
                let url = try URL.api("https://api.smartrecruiters.com/v1/companies", [slug, "postings"], query: ["limit": "1"])
                let count = try await http.json(Count.self, from: url).totalFound ?? 0
                return count > 0 ? Board(kind: kind, boardID: slug, openJobs: count) : nil
            default:
                return nil
            }
        } catch {
            return nil
        }
    }
}
