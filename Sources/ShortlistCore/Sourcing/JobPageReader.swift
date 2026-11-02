import Foundation
import GRDB

/// What Shortlist could learn about a job from its link. Anything it couldn't, you type in.
public struct JobPage: Codable, Equatable, Sendable {
    public enum Reading: String, Codable, Sendable {
        /// One of your feeds already found it.
        case known
        /// From the company's job board API, so it can be trusted.
        case board
        /// From the job data most career sites put in their pages.
        case structured
        /// From the page's title, so it needs checking.
        case guess
        /// Nothing could be read.
        case nothing
    }

    public var url: String
    public var title = ""
    public var company = ""
    public var location = ""
    public var remotePolicy = RemotePolicy.unknown
    public var description = ""
    public var salary: String?
    public var postedAt: Date?
    /// The site's own word for the kind of work, such as "CONTRACTOR".
    public var typeLabel: String?
    public var reading = Reading.nothing
    /// Why the fields are empty, when they are.
    public var problem: String?

    public init(url: String) {
        self.url = url
    }
}

/// Reads a job from a link you pasted. Greenhouse, Lever and Ashby answer through the same open APIs
/// as your feeds. Other career sites get one plain page request, the same as opening it. Sites that
/// keep jobs behind a sign-in are never fetched: the browser extension reads those, from the page
/// you already have open.
public struct JobPageReader: Sendable {
    private let http: any HTTPClient

    public init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    /// A usable address from what you pasted, or nil. Tidies the ones that only work in the session
    /// they were copied from.
    public static func cleanURL(_ text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        if !trimmed.contains("://") { trimmed = "https://" + trimmed }
        guard var parts = URLComponents(string: trimmed), let host = parts.host?.lowercased(), host.contains("."),
              parts.scheme == "https" || parts.scheme == "http" else { return nil }
        if host.hasSuffix("linkedin.com"),
           let id = parts.queryItems?.first(where: { $0.name == "currentJobId" })?.value, !id.isEmpty {
            return URL(string: "https://www.linkedin.com/jobs/view/\(id)/")
        }
        parts.queryItems = parts.queryItems?.filter { !$0.name.lowercased().hasPrefix("utm_") }
        if parts.queryItems?.isEmpty == true { parts.queryItems = nil }
        parts.fragment = nil
        return parts.url
    }

    private static let signInSites = [
        "linkedin.com": "LinkedIn", "naukri.com": "Naukri", "indeed.com": "Indeed", "indeed.co.in": "Indeed",
        "glassdoor.com": "Glassdoor", "glassdoor.co.in": "Glassdoor", "wellfound.com": "Wellfound",
    ]

    private static func signInSite(_ host: String) -> String? {
        signInSites.first { host == $0.key || host.hasSuffix("." + $0.key) }?.value
    }

    /// What Shortlist already holds for a link. It saves a fetch, and some boards refuse apps.
    public static func known(_ text: String, _ db: Database) throws -> JobPage? {
        guard let url = cleanURL(text), let job = try PostingMatcher.job(for: url.absoluteString, db) else { return nil }
        var page = JobPage(url: job.url)
        page.title = job.title
        page.company = job.companyName
        page.location = job.location
        page.remotePolicy = job.remotePolicy
        page.description = job.descriptionText
        page.salary = job.salaryText
        page.postedAt = job.postedAt
        page.reading = .known
        return page
    }

    public func read(_ text: String) async -> JobPage {
        guard let url = Self.cleanURL(text) else {
            var page = JobPage(url: text)
            page.problem = "That doesn't look like a link."
            return page
        }
        var page = JobPage(url: url.absoluteString)
        let host = url.host?.lowercased() ?? ""
        if let name = Self.signInSite(host) {
            page.problem = "\(name) doesn't let apps read its pages. Press Save to Tracker in the extension on that page, or type the details here."
            return page
        }
        if let found = await boardJob(at: url) { return found }
        do {
            let (data, status) = try await http.get(url)
            guard (200..<300).contains(status) else {
                page.problem = "The site answered \(status). Press Save to Tracker in the extension on that page, or type the details here."
                return page
            }
            return JobPageParser.parse(html: String(decoding: data, as: UTF8.self), url: url.absoluteString)
        } catch {
            page.problem = "Couldn't open that link. Type the details here."
            return page
        }
    }

    private func boardJob(at url: URL) async -> JobPage? {
        guard let source = SourceLocator.source(from: url.absoluteString),
              [.greenhouse, .lever, .ashby].contains(source.kind),
              let id = Self.jobID(in: url, kind: source.kind),
              let result = try? await Feeds.fetch(source, http: http, filter: TitleFilter(keywords: [])),
              let job = result.jobs.first(where: { $0.externalID == id }) else { return nil }
        var page = JobPage(url: url.absoluteString)
        page.title = job.title
        page.company = job.companyName
        page.location = job.location
        page.remotePolicy = job.remotePolicy
        page.description = job.descriptionText
        page.salary = job.salaryText
        page.postedAt = job.postedAt
        page.typeLabel = job.jobType == .fullTime ? nil : job.jobType.rawValue
        page.reading = .board
        return page
    }

    /// Which job on the board a link means. Lever and Ashby put it after the board's name, and
    /// Greenhouse after "jobs".
    static func jobID(in url: URL, kind: SourceKind) -> String? {
        let parts = url.pathComponents.filter { $0 != "/" }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        switch kind {
        case .greenhouse:
            if let token = items.first(where: { $0.name == "token" || $0.name == "gh_jid" })?.value { return token }
            return parts.firstIndex(of: "jobs").flatMap { $0 + 1 < parts.count ? parts[$0 + 1] : nil }
        default:
            return parts.count >= 2 ? parts[1] : nil
        }
    }
}

/// Reads one job page's HTML. This also handles what the browser extension sends: the same page,
/// read from your own browser.
public enum JobPageParser {
    public static func parse(html: String, url: String, text: String = "") -> JobPage {
        var page = structured(in: html, url: url) ?? guess(from: html, url: url)
        if page.description.isEmpty {
            page.description = text.trimmed
        }
        return page
    }

    // MARK: Job data in the page

    private static func structured(in html: String, url: String) -> JobPage? {
        for match in html.matches(of: /(?is)<script[^>]*application\/ld\+json[^>]*>(.*?)<\/script>/) {
            let raw = String(match.output.1)
            let json = (try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: .fragmentsAllowed))
                ?? (try? JSONSerialization.jsonObject(with: Data(FeedText.decodeEntities(raw).utf8), options: .fragmentsAllowed))
            if let posting = json.flatMap(jobPosting(in:)), let page = page(from: posting, url: url) { return page }
        }
        return nil
    }

    /// The JobPosting among the page's data, which can sit in a list or a `@graph`.
    private static func jobPosting(in value: Any) -> [String: Any]? {
        if let list = value as? [Any] { return list.lazy.compactMap(jobPosting(in:)).first }
        guard let object = value as? [String: Any] else { return nil }
        let types = (object["@type"] as? [String]) ?? [(object["@type"] as? String) ?? ""]
        if types.contains("JobPosting") { return object }
        return object["@graph"].flatMap(jobPosting(in:))
    }

    private static func page(from posting: [String: Any], url: String) -> JobPage? {
        guard let title = (posting["title"] as? String)?.nilIfEmpty else { return nil }
        var page = JobPage(url: url)
        page.title = FeedText.decodeEntities(title).trimmed
        let company = (posting["hiringOrganization"] as? [String: Any])?["name"] as? String ?? posting["hiringOrganization"] as? String
        page.company = company.map { FeedText.decodeEntities($0).trimmed } ?? ""
        let isRemote = (posting["jobLocationType"] as? String)?.uppercased() == "TELECOMMUTE"
        page.location = places(posting["jobLocation"]).nilIfEmpty
            ?? places(posting["applicantLocationRequirements"]).nilIfEmpty
            ?? (isRemote ? "Remote" : "")
        page.remotePolicy = isRemote ? .remote : FeedText.remotePolicy(from: page.location)
        page.description = FeedText.plain(fromHTML: posting["description"] as? String ?? "")
        page.salary = salary(posting["baseSalary"])
        // Often a bare date, which the ISO reader wants a time for.
        let posted = posting["datePosted"] as? String
        page.postedAt = FeedText.date(iso: posted) ?? FeedText.date(iso: posted.map { $0 + "T00:00:00Z" })
        page.typeLabel = ((posting["employmentType"] as? [String])?.joined(separator: " ")) ?? posting["employmentType"] as? String
        page.reading = page.company.isEmpty ? .guess : .structured
        if page.company.isEmpty { page.company = companyFromAddress(url) }
        return page
    }

    private static func places(_ value: Any?) -> String {
        if let list = value as? [Any] {
            let names = list.map(places).filter { !$0.isEmpty }
            return names.prefix(3).joined(separator: " • ")
        }
        guard let place = value as? [String: Any] else { return (value as? String) ?? "" }
        guard let address = place["address"] as? [String: Any] else { return (place["name"] as? String) ?? "" }
        let country = address["addressCountry"]
        let parts = [address["addressLocality"] as? String, address["addressRegion"] as? String,
                     (country as? [String: Any])?["name"] as? String ?? country as? String]
        return parts.compactMap { $0?.trimmed.nilIfEmpty }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            .joined(separator: ", ")
    }

    private static func salary(_ value: Any?) -> String? {
        guard let pay = value as? [String: Any] else { return nil }
        let amounts = pay["value"] as? [String: Any]
        func number(_ key: String) -> Double? {
            (amounts?[key] as? Double) ?? (amounts?[key] as? String).flatMap(Double.init)
        }
        return FeedText.salary(min: number("minValue") ?? number("value") ?? (pay["value"] as? Double), max: number("maxValue"),
                               currency: pay["currency"] as? String, period: (amounts?["unitText"] as? String)?.lowercased())
    }

    // MARK: Guessing from the title

    private static func guess(from html: String, url: String) -> JobPage {
        var page = JobPage(url: url)
        let metas = metaTags(in: html)
        let pageTitle = html.firstMatch(of: /(?is)<title[^>]*>(.*?)<\/title>/).map { FeedText.decodeEntities(String($0.output.1)).trimmed } ?? ""
        let heading = metas["og:title"] ?? metas["twitter:title"] ?? pageTitle
        guard !heading.isEmpty else {
            page.problem = "Nothing on that page could be read. Type the details here."
            return page
        }
        page.reading = .guess
        page.description = metas["og:description"] ?? metas["description"] ?? ""

        let cleaned = heading.replacing(/^\(\d+\)\s*/, with: "")
        if let linkedIn = cleaned.firstMatch(of: /^(.+?) hiring (.+?) in (.+?) \| LinkedIn$/) {
            (page.company, page.title, page.location) = (String(linkedIn.output.1), String(linkedIn.output.2), String(linkedIn.output.3))
        } else if let linkedIn = cleaned.firstMatch(of: /^(.+?) \| (.+?) \| LinkedIn$/) {
            (page.title, page.company) = (String(linkedIn.output.1), String(linkedIn.output.2))
        } else if let at = cleaned.firstMatch(of: /^(.+?) at (.+?)(?: [|–—-] .*)?$/) {
            (page.title, page.company) = (String(at.output.1), String(at.output.2))
        } else {
            let parts = cleaned.split(separator: /\s+[|–—-]\s+/).map(String.init)
            page.title = parts.first ?? cleaned
            page.company = metas["og:site_name"] ?? (parts.count > 1 ? parts[1] : companyFromAddress(url))
        }
        return page
    }

    private static func metaTags(in html: String) -> [String: String] {
        var tags: [String: String] = [:]
        for tag in html.matches(of: /(?is)<meta\s[^>]*>/) {
            let text = String(tag.output)
            guard let name = attribute("property", in: text) ?? attribute("name", in: text),
                  let content = attribute("content", in: text) else { continue }
            tags[name.lowercased()] = FeedText.decodeEntities(content).trimmed
        }
        return tags
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        for match in tag.matches(of: /(?is)([a-z:-]+)\s*=\s*("([^"]*)"|'([^']*)')/) where match.output.1.lowercased() == name {
            return String(match.output.3 ?? match.output.4 ?? "")
        }
        return nil
    }

    /// "careers.acme-labs.com" → "Acme Labs".
    private static func companyFromAddress(_ url: String) -> String {
        guard let host = URLComponents(string: url)?.host?.lowercased() else { return "" }
        let parts = host.split(separator: ".").map(String.init).filter { !["www", "careers", "jobs", "apply", "boards"].contains($0) }
        return SourceLocator.prettyName(parts.first ?? "")
    }
}
