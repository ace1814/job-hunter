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
        case .jobicy: "Jobicy"
        case .rss: "RSS"
        case .reddit: "Reddit"
        }
    }

    /// A company's own job board, which lists every open job, so jobs missing from it are closed.
    public var isCompanyBoard: Bool {
        switch self {
        case .greenhouse, .lever, .ashby, .smartRecruiters: true
        default: false
        }
    }

    /// The least time between two fetches. Remotive asks for no more than a few calls a day, the
    /// HN thread changes slowly, and Reddit is strict with anyone not signed in.
    public var minimumInterval: TimeInterval {
        switch self {
        case .remotive, .hackerNewsHiring, .jobicy: 6 * 3600
        case .reddit: 3 * 3600
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
            Source(kind: .himalayas, name: "Himalayas: product designer in India", boardID: "product designer|India"),
            Source(kind: .himalayas, name: "Himalayas: product manager in India", boardID: "product manager|India"),
            Source(kind: .rss, name: "We Work Remotely: Design", url: "https://weworkremotely.com/categories/remote-design-jobs.rss"),
            Source(kind: .rss, name: "We Work Remotely: Product", url: "https://weworkremotely.com/categories/remote-product-jobs.rss"),
            Source(kind: .remoteOK, name: "Remote OK"),
            Source(kind: .remotive, name: "Remotive"),
            Source(kind: .hackerNewsHiring, name: "HN Who is hiring"),
            Source(kind: .himalayas, name: "Himalayas: contract product designer in India", boardID: "product designer|India|Contractor"),
            Source(kind: .himalayas, name: "Himalayas: contract product manager in India", boardID: "product manager|India|Contractor"),
            Source(kind: .jobicy, name: "Jobicy: design", boardID: "design"),
            Source(kind: .reddit, name: "Reddit: r/forhire", boardID: "forhire"),
            Source(kind: .reddit, name: "Reddit: r/DesignJobs", boardID: "DesignJobs"),
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
        if trimmed.hasPrefix("r/") { return subreddit(String(trimmed.dropFirst(2))) }
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
        case "reddit.com", "www.reddit.com", "old.reddit.com":
            return first == "r" && path.count >= 2 ? subreddit(path[1]) : nil
        default:
            guard components.scheme == "https" || components.scheme == "http" else { return nil }
            return Source(kind: .rss, name: host.replacingOccurrences(of: "www.", with: ""), url: trimmed)
        }
    }

    private static func subreddit(_ name: String) -> Source? {
        let name = name.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !name.isEmpty else { return nil }
        return Source(kind: .reddit, name: "Reddit: r/\(name)", boardID: name)
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
        /// The company name the board gives for itself, where it gives one.
        public var ownerName: String?
        /// What the board's postings say, for boards that don't name their owner.
        var postingsText: String?

        public var id: String { "\(kind.rawValue):\(boardID)" }

        /// Whether this is really `company`'s board, not another one that took the same name.
        /// Stricter than matching people to jobs: a wrong board adds jobs you never asked for.
        /// "Air India" isn't "Air", even though both reduce to the same board name.
        public func belongs(to company: String) -> Bool {
            let wanted = Self.nameWords(company)
            guard !wanted.isEmpty else { return false }
            if let ownerName {
                return Self.sameCompany(wanted, Self.nameWords(ownerName))
            }
            let name = NSRegularExpression.escapedPattern(for: wanted.joined(separator: " "))
            let pattern = "\\b(?:at|about|join|joining|why) \(name)\\b|\\b\(name)(?: is|'s)\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
            let text = CompanyNormalizer.fold(postingsText ?? "")
            return regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) >= Self.requiredMentions
        }

        /// A company writes "at Notion" or "Notion is" all through its postings. A stranger's
        /// postings might mention it, but not like that.
        private static let requiredMentions = 2
        private static let legalWords: Set<String> = [
            "pvt", "private", "ltd", "limited", "inc", "incorporated", "llc", "llp", "corp", "corporation", "co", "plc", "gmbh",
        ]
        /// Words a company can add to its name and still be the same company.
        private static let harmlessWords: Set<String> = [
            "group", "holdings", "technologies", "technology", "software", "international", "job", "jobs", "board", "careers",
        ]

        private static func nameWords(_ name: String) -> [String] {
            CompanyNormalizer.fold(name)
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
                .filter { !legalWords.contains($0) }
        }

        private static func sameCompany(_ first: [String], _ second: [String]) -> Bool {
            guard !first.isEmpty, !second.isEmpty else { return false }
            if first.joined() == second.joined() { return true }
            let (short, long) = first.count < second.count ? (first, second) : (second, first)
            return long.starts(with: short) && Set(long.dropFirst(short.count)).isSubset(of: harmlessWords)
        }
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

    /// The company's own board, when one can be confirmed. Safe to add without asking.
    public func findConfirmed(company: String) async -> Board? {
        await find(company: company).first { $0.belongs(to: company) }
    }

    private struct Count: Decodable {
        var jobs: [Posting]?
        var content: [Posting]?
        var totalFound: Int?
    }

    private struct Posting: Decodable {
        var company_name: String?
        var company: Owner?

        struct Owner: Decodable {
            var name: String?
        }
    }

    func probe(_ kind: SourceKind, _ slug: String) async -> Board? {
        do {
            switch kind {
            case .greenhouse:
                let url = try URL.api("https://boards-api.greenhouse.io/v1/boards", [slug, "jobs"])
                let jobs = try await http.json(Count.self, from: url).jobs ?? []
                return Board(kind: kind, boardID: slug, openJobs: jobs.count, ownerName: jobs.first?.company_name)
            case .lever:
                let url = try URL.api("https://api.lever.co/v0/postings", [slug], query: ["mode": "json"])
                let data = try await http.okData(from: url)
                let jobs = try JSONDecoder().decode([Posting].self, from: data)
                return Board(kind: kind, boardID: slug, openJobs: jobs.count, postingsText: String(decoding: data, as: UTF8.self))
            case .ashby:
                let url = try URL.api("https://api.ashbyhq.com/posting-api/job-board", [slug])
                let data = try await http.okData(from: url)
                let count = try JSONDecoder().decode(Count.self, from: data).jobs?.count ?? 0
                return Board(kind: kind, boardID: slug, openJobs: count, postingsText: String(decoding: data, as: UTF8.self))
            case .smartRecruiters:
                // SmartRecruiters answers for any name, so only a board with jobs counts.
                let url = try URL.api("https://api.smartrecruiters.com/v1/companies", [slug, "postings"], query: ["limit": "1"])
                let page = try await http.json(Count.self, from: url)
                let count = page.totalFound ?? 0
                return count > 0 ? Board(kind: kind, boardID: slug, openJobs: count, ownerName: page.content?.first?.company?.name) : nil
            default:
                return nil
            }
        } catch {
            return nil
        }
    }
}
