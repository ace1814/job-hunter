import Foundation

/// Reads one source's jobs. Every kind of source is an open API or RSS feed: nothing is scraped.
public enum Feeds {
    public static func fetch(_ source: Source, http: any HTTPClient, filter: TitleFilter) async throws -> FeedResult {
        let board = source.boardID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        func requireBoard() throws -> String {
            guard !board.isEmpty else { throw FeedError.badURL("\(source.kind.rawValue) needs a board name") }
            return board
        }
        switch source.kind {
        case .greenhouse: return try await greenhouse(try requireBoard(), http, filter, fallbackCompany: source.name)
        case .lever: return try await lever(try requireBoard(), eu: source.url?.contains("eu.lever.co") ?? false, http, filter, fallbackCompany: source.name)
        case .ashby: return try await ashby(try requireBoard(), http, filter, fallbackCompany: source.name)
        case .smartRecruiters: return try await smartRecruiters(try requireBoard(), http, filter)
        case .himalayas:
            let parts = board.split(separator: "|", maxSplits: 1).map(String.init)
            return try await himalayas(query: parts.first ?? "product designer", country: parts.dropFirst().first, http, filter)
        case .remotive: return try await remotive(http, filter)
        case .remoteOK: return try await remoteOK(http, filter)
        case .hackerNewsHiring: return try await hackerNews(http, filter)
        case .rss:
            guard let text = source.url, let url = URL(string: text) else { throw FeedError.badURL(source.url ?? "") }
            return try await rss(url, http, filter, fallbackCompany: source.name)
        }
    }

    /// Keeps jobs whose title passes, and reports how many were listed.
    private static func result(_ jobs: [FetchedJob], _ filter: TitleFilter, complete: Bool) -> FeedResult {
        FeedResult(
            jobs: jobs.filter { filter.matches($0.title) },
            listedCount: jobs.count,
            allExternalIDs: complete ? Set(jobs.map(\.externalID)) : nil)
    }

    // MARK: - Company boards (complete lists)

    private struct GreenhouseBoard: Decodable {
        struct Job: Decodable {
            struct Location: Decodable { var name: String? }
            var id: Int
            var title: String
            var absolute_url: String
            var location: Location?
            var content: String?
            var company_name: String?
            var first_published: String?
            var updated_at: String?
        }
        var jobs: [Job]
    }

    static func greenhouse(_ board: String, _ http: any HTTPClient, _ filter: TitleFilter, fallbackCompany: String) async throws -> FeedResult {
        let url = try URL.api("https://boards-api.greenhouse.io/v1/boards", [board, "jobs"], query: ["content": "true"])
        let response = try await http.json(GreenhouseBoard.self, from: url)
        let jobs = response.jobs.map { job in
            let location = job.location?.name ?? ""
            return FetchedJob(
                externalID: String(job.id), companyName: job.company_name ?? fallbackCompany, title: job.title,
                location: location, remotePolicy: FeedText.remotePolicy(from: location), url: job.absolute_url,
                descriptionText: FeedText.plain(fromHTML: job.content ?? ""),
                postedAt: FeedText.date(iso: job.first_published ?? job.updated_at))
        }
        return result(jobs, filter, complete: true)
    }

    private struct LeverPosting: Decodable {
        struct Categories: Decodable { var location: String?; var team: String?; var commitment: String? }
        struct ListBlock: Decodable { var text: String?; var content: String? }
        struct Salary: Decodable { var min: Double?; var max: Double?; var currency: String?; var interval: String? }
        var id: String
        var text: String
        var categories: Categories?
        var createdAt: Int64?
        var descriptionPlain: String?
        var description: String?
        var lists: [ListBlock]?
        var additionalPlain: String?
        var hostedUrl: String
        var applyUrl: String?
        var workplaceType: String?
        var salaryRange: Salary?
    }

    static func lever(_ company: String, eu: Bool, _ http: any HTTPClient, _ filter: TitleFilter, fallbackCompany: String) async throws -> FeedResult {
        let host = eu ? "https://api.eu.lever.co/v0/postings" : "https://api.lever.co/v0/postings"
        let postings = try await http.json([LeverPosting].self, from: try URL.api(host, [company], query: ["mode": "json"]))
        let jobs = postings.map { posting in
            var parts = [posting.descriptionPlain?.nilIfEmpty ?? FeedText.plain(fromHTML: posting.description ?? "")]
            for block in posting.lists ?? [] {
                parts.append([block.text ?? "", FeedText.plain(fromHTML: block.content ?? "")].joined(separator: "\n"))
            }
            parts.append(posting.additionalPlain ?? "")
            let location = posting.categories?.location ?? ""
            let workplace = posting.workplaceType.map(FeedText.remotePolicy(from:)) ?? .unknown
            return FetchedJob(
                externalID: posting.id, companyName: fallbackCompany, title: posting.text, location: location,
                remotePolicy: workplace == .unknown ? FeedText.remotePolicy(from: location) : workplace,
                url: posting.hostedUrl, applyURL: posting.applyUrl,
                descriptionText: parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n\n"),
                salaryText: posting.salaryRange.flatMap {
                    FeedText.salary(min: $0.min, max: $0.max, currency: $0.currency, period: $0.interval)
                },
                postedAt: posting.createdAt.map { Date(timeIntervalSince1970: Double($0) / 1000) })
        }
        return result(jobs, filter, complete: true)
    }

    private struct AshbyBoard: Decodable {
        struct Job: Decodable {
            struct Secondary: Decodable { var location: String? }
            struct Compensation: Decodable { var compensationTierSummary: String? }
            var id: String
            var title: String
            var location: String?
            var secondaryLocations: [Secondary]?
            var isRemote: Bool?
            var workplaceType: String?
            var publishedAt: String?
            var jobUrl: String
            var applyUrl: String?
            var descriptionPlain: String?
            var descriptionHtml: String?
            var isListed: Bool?
            var compensation: Compensation?
        }
        var jobs: [Job]
    }

    static func ashby(_ board: String, _ http: any HTTPClient, _ filter: TitleFilter, fallbackCompany: String) async throws -> FeedResult {
        let url = try URL.api("https://api.ashbyhq.com/posting-api/job-board", [board], query: ["includeCompensation": "true"])
        let response = try await http.json(AshbyBoard.self, from: url)
        let jobs = response.jobs.filter { $0.isListed ?? true }.map { job in
            let locations = ([job.location] + (job.secondaryLocations ?? []).map(\.location)).compactMap { $0 }
            var policy = job.workplaceType.map(FeedText.remotePolicy(from:)) ?? .unknown
            if policy == .unknown, job.isRemote == true { policy = .remote }
            return FetchedJob(
                externalID: job.id, companyName: fallbackCompany, title: job.title,
                location: locations.joined(separator: " • "), remotePolicy: policy, url: job.jobUrl, applyURL: job.applyUrl,
                descriptionText: job.descriptionPlain?.nilIfEmpty ?? FeedText.plain(fromHTML: job.descriptionHtml ?? ""),
                salaryText: job.compensation?.compensationTierSummary,
                postedAt: FeedText.date(iso: job.publishedAt))
        }
        return result(jobs, filter, complete: true)
    }

    private struct SmartRecruitersPage: Decodable {
        struct Posting: Decodable {
            struct Company: Decodable { var name: String? }
            struct Location: Decodable { var fullLocation: String?; var city: String?; var country: String?; var remote: Bool?; var hybrid: Bool? }
            var id: String
            var name: String
            var company: Company?
            var location: Location?
            var releasedDate: String?
        }
        var totalFound: Int
        var content: [Posting]
    }

    private struct SmartRecruitersDetail: Decodable {
        struct JobAd: Decodable {
            struct Section: Decodable { var title: String?; var text: String? }
            var sections: [String: Section]?
        }
        var postingUrl: String?
        var applyUrl: String?
        var jobAd: JobAd?
    }

    /// SmartRecruiters lists titles only. Full text comes from one call per posting, so it's only
    /// fetched for titles that pass your filter.
    static func smartRecruiters(_ company: String, _ http: any HTTPClient, _ filter: TitleFilter, maxPages: Int = 20) async throws -> FeedResult {
        var postings: [SmartRecruitersPage.Posting] = []
        var complete = false
        for page in 0..<maxPages {
            let url = try URL.api("https://api.smartrecruiters.com/v1/companies", [company, "postings"],
                                  query: ["limit": "100", "offset": String(page * 100)])
            let response = try await http.json(SmartRecruitersPage.self, from: url)
            postings += response.content
            if response.content.isEmpty || postings.count >= response.totalFound {
                complete = true
                break
            }
        }
        if postings.isEmpty { throw FeedError.notFound }

        var jobs: [FetchedJob] = []
        for posting in postings where filter.matches(posting.name) {
            let detailURL = try URL.api("https://api.smartrecruiters.com/v1/companies", [company, "postings", posting.id])
            let detail = try? await http.json(SmartRecruitersDetail.self, from: detailURL)
            let order = ["companyDescription", "jobDescription", "qualifications", "additionalInformation"]
            let text = order.compactMap { detail?.jobAd?.sections?[$0] }
                .map { [$0.title ?? "", FeedText.plain(fromHTML: $0.text ?? "")].joined(separator: "\n") }
                .joined(separator: "\n\n")
            let location = posting.location
            var policy = RemotePolicy.unknown
            if location?.remote == true { policy = .remote } else if location?.hybrid == true { policy = .hybrid }
            jobs.append(FetchedJob(
                externalID: posting.id, companyName: posting.company?.name ?? company, title: posting.name,
                location: location?.fullLocation?.replacingOccurrences(of: ", ,", with: ",") ?? "",
                remotePolicy: policy,
                url: detail?.postingUrl ?? "https://jobs.smartrecruiters.com/\(company)/\(posting.id)",
                applyURL: detail?.applyUrl, descriptionText: text,
                postedAt: FeedText.date(iso: posting.releasedDate)))
        }
        return FeedResult(jobs: jobs, listedCount: postings.count,
                          allExternalIDs: complete ? Set(postings.map(\.id)) : nil)
    }

    // MARK: - Remote job boards (latest jobs only)

    private struct HimalayasPage: Decodable {
        struct Job: Decodable {
            var title: String
            var companyName: String
            var locationRestrictions: [String]?
            var description: String?
            var minSalary: Double?
            var maxSalary: Double?
            var currency: String?
            var pubDate: Double?
            var applicationLink: String?
            var guid: String
        }
        var jobs: [Job]
    }

    /// Himalayas search, 20 a page. `query` is what you'd type in its search box. With `country` it
    /// returns jobs open there, worldwide ones included, and that country leads the location so a
    /// long list doesn't cut it off.
    static func himalayas(query: String, country: String? = nil, _ http: any HTTPClient, _ filter: TitleFilter, pages: Int = 5) async throws -> FeedResult {
        var all: [FetchedJob] = []
        for page in 1...pages {
            var parameters = ["q": query, "page": String(page)]
            parameters["country"] = country
            let url = try URL.api("https://himalayas.app/jobs/api/search", query: parameters)
            let response = try await http.json(HimalayasPage.self, from: url)
            all += response.jobs.map { job in
                let listed = job.locationRestrictions ?? []
                let places = listed.filter { $0 == country } + listed.filter { $0 != country }
                return FetchedJob(
                    externalID: job.guid, companyName: job.companyName, title: job.title,
                    location: places.isEmpty ? "Anywhere" : places.prefix(6).joined(separator: ", ") + (places.count > 6 ? " +\(places.count - 6) more" : ""),
                    remotePolicy: .remote, url: job.guid, applyURL: job.applicationLink,
                    descriptionText: FeedText.plain(fromHTML: job.description ?? ""),
                    salaryText: FeedText.salary(min: job.minSalary, max: job.maxSalary, currency: job.currency),
                    postedAt: job.pubDate.map { Date(timeIntervalSince1970: $0) })
            }
            if response.jobs.count < 20 { break }
        }
        return result(all, filter, complete: false)
    }

    private struct RemotivePage: Decodable {
        struct Job: Decodable {
            var id: Int
            var url: String
            var title: String
            var company_name: String
            var publication_date: String?
            var candidate_required_location: String?
            var salary: String?
            var description: String?
        }
        var jobs: [Job]
    }

    /// Remotive asks that its API is called at most a few times a day; `Source.minimumInterval` sees to it.
    static func remotive(_ http: any HTTPClient, _ filter: TitleFilter) async throws -> FeedResult {
        let response = try await http.json(RemotivePage.self, from: try URL.api("https://remotive.com/api/remote-jobs"))
        let jobs = response.jobs.map { job in
            FetchedJob(
                externalID: String(job.id), companyName: job.company_name, title: job.title,
                location: job.candidate_required_location ?? "Anywhere", remotePolicy: .remote, url: job.url,
                descriptionText: FeedText.plain(fromHTML: job.description ?? ""), salaryText: job.salary,
                postedAt: FeedText.date(iso: job.publication_date))
        }
        return result(jobs, filter, complete: false)
    }

    private struct RemoteOKItem: Decodable {
        var id: LossyString?
        var company: String?
        var position: String?
        var location: String?
        var description: String?
        var salary_min: Double?
        var salary_max: Double?
        var epoch: Double?
        var url: String?
        var apply_url: String?
    }

    /// RemoteOK's terms ask for a link back to the posting, which the job keeps as its URL.
    static func remoteOK(_ http: any HTTPClient, _ filter: TitleFilter) async throws -> FeedResult {
        let items = try await http.json([RemoteOKItem].self, from: try URL.api("https://remoteok.com/api"))
        // The first item is the legal notice, not a job.
        let jobs: [FetchedJob] = items.compactMap { item in
            guard let id = item.id?.value, let title = item.position, let url = item.url else { return nil }
            return FetchedJob(
                externalID: id, companyName: item.company ?? "", title: title,
                location: item.location?.nilIfEmpty ?? "Anywhere", remotePolicy: .remote, url: url, applyURL: item.apply_url,
                descriptionText: FeedText.plain(fromHTML: item.description ?? ""),
                salaryText: FeedText.salary(min: item.salary_min, max: item.salary_max, currency: "USD"),
                postedAt: item.epoch.map { Date(timeIntervalSince1970: $0) })
        }
        return result(jobs, filter, complete: false)
    }

    // MARK: - Hacker News "Who is hiring?"

    private struct HNSearch: Decodable {
        struct Hit: Decodable { var objectID: String; var title: String? }
        var hits: [Hit]
    }

    private struct HNItem: Decodable {
        var id: Int
        var text: String?
        var created_at: String?
        var children: [HNItem]?
    }

    /// This month's thread. Each top-level comment is one company, its first line written as
    /// "Company | Role | Location | ...".
    static func hackerNews(_ http: any HTTPClient, _ filter: TitleFilter) async throws -> FeedResult {
        let searchURL = try URL.api("https://hn.algolia.com/api/v1/search_by_date",
                                    query: ["tags": "story,author_whoishiring", "hitsPerPage": "10"])
        let search = try await http.json(HNSearch.self, from: searchURL)
        guard let story = search.hits.first(where: { $0.title?.hasPrefix("Ask HN: Who is hiring?") ?? false }) else {
            throw FeedError.notFound
        }
        let thread = try await http.json(HNItem.self, from: try URL.api("https://hn.algolia.com/api/v1/items", [story.objectID]))
        let comments = (thread.children ?? []).filter { !($0.text ?? "").isEmpty }
        let jobs = comments.compactMap { comment in hackerNewsJob(comment.text ?? "", id: comment.id, created: comment.created_at, filter: filter) }
        return FeedResult(jobs: jobs, listedCount: comments.count, allExternalIDs: nil)
    }

    static func hackerNewsJob(_ html: String, id: Int, created: String?, filter: TitleFilter) -> FetchedJob? {
        let headerHTML = html.components(separatedBy: "<p>").first ?? html
        let header = FeedText.plain(fromHTML: headerHTML)
        let segments = header
            .split(whereSeparator: { $0 == "|" || $0 == "—" || $0 == "•" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard segments.count >= 2 else { return nil }
        let rest = segments.dropFirst()
        let locationWords = ["remote", "onsite", "on-site", "hybrid", "office"]
        let isLocation = { (s: String) in locationWords.contains { s.lowercased().contains($0) } || s.contains(",") && s.count < 60 }
        // The role is the segment your filter likes, else the first one that isn't a place or pay.
        let title = rest.first(where: { filter.matches($0) && !filter.isEmpty })
            ?? rest.first(where: { !isLocation($0) && !$0.contains("$") && !$0.lowercased().contains("full-time") })
        guard let title, filter.matches(title) else { return nil }
        return FetchedJob(
            externalID: String(id),
            companyName: segments[0].replacing(/\s*\(.*\)\s*$/, with: ""),
            title: title,
            location: rest.first(where: isLocation) ?? "",
            remotePolicy: FeedText.remotePolicy(from: header),
            url: "https://news.ycombinator.com/item?id=\(id)",
            descriptionText: FeedText.plain(fromHTML: html),
            postedAt: FeedText.date(iso: created))
    }

    // MARK: - RSS

    /// RSS 2.0 or Atom. Titles written "Company: Role" (We Work Remotely does this) are split;
    /// otherwise the source's name is used as the company.
    static func rss(_ url: URL, _ http: any HTTPClient, _ filter: TitleFilter, fallbackCompany: String) async throws -> FeedResult {
        let data = try await http.okData(from: url)
        let items = try RSSReader.items(in: data)
        let jobs = items.map { item in
            var company = fallbackCompany
            var title = item.title
            if let range = item.title.range(of: ": ") {
                company = String(item.title[..<range.lowerBound])
                title = String(item.title[range.upperBound...])
            }
            let location = item.region ?? ""
            return FetchedJob(
                externalID: item.guid ?? item.link, companyName: company, title: title, location: location,
                remotePolicy: FeedText.remotePolicy(from: location).orRemoteIf(url.host()?.contains("weworkremotely") ?? false),
                url: item.link, descriptionText: FeedText.plain(fromHTML: item.description),
                postedAt: FeedText.date(rfc822: item.pubDate))
        }
        return result(jobs, filter, complete: false)
    }
}

// MARK: - Small helpers

/// Decodes a JSON string or number as a string: RemoteOK's ids are either.
struct LossyString: Decodable {
    var value: String

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else {
            value = String(try container.decode(Int64.self))
        }
    }
}

extension String {
    var nilIfEmpty: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}

private extension RemotePolicy {
    func orRemoteIf(_ condition: Bool) -> RemotePolicy {
        self == .unknown && condition ? .remote : self
    }
}
