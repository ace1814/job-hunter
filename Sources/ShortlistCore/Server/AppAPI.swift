import Foundation
import GRDB
import Security

/// What the local server answers: the browser extension's packets, and the web dashboard.
/// Everything except the dashboard's empty page needs your token.
public struct AppAPI: Sendable {
    public static let port: UInt16 = 8787

    private let database: AppDatabase
    private let token: String

    public init(database: AppDatabase, token: String) {
        self.database = database
        self.token = token
    }

    public func handle(_ request: HTTPRequest) async -> HTTPResponse {
        if request.method == "GET" && request.path == "/" {
            return HTTPResponse(contentType: "text/html; charset=utf-8", body: Data(WebPage.html.utf8))
        }
        guard isAuthorized(request) else { return Self.error(401, "Your token is missing or wrong.") }
        do {
            return try await route(request)
        } catch {
            return Self.error(500, error.localizedDescription)
        }
    }

    private func isAuthorized(_ request: HTTPRequest) -> Bool {
        let given = Array((request.headers["authorization"] ?? "").utf8)
        let wanted = Array("Bearer \(token)".utf8)
        guard given.count == wanted.count else { return false }
        // Compare every byte, so timing says nothing about how much of a guess was right.
        return zip(given, wanted).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private func route(_ request: HTTPRequest) async throws -> HTTPResponse {
        let parts = request.path.split(separator: "/").map(String.init)
        switch (request.method, parts) {
        case ("GET", ["api", "today"]):
            return try Self.json(try await database.reader.read { try TodayPayload.fetch($0) })
        case ("GET", ["api", "packet"]):
            return try await packet(for: request.query["url"] ?? "")
        case ("POST", let path) where path.count == 4 && path[0] == "api" && path[1] == "jobs":
            guard let id = Int64(path[2]) else { return Self.error(400, "That isn't a job.") }
            return try await act(path[3], on: id)
        default:
            return Self.error(404, "Nothing here.")
        }
    }

    private func act(_ action: String, on id: Int64) async throws -> HTTPResponse {
        let known = try await database.writer.write { db -> Bool in
            guard try Job.exists(db, key: id) else { return false }
            switch action {
            case "applied": try Pipeline.markApplied(id, db)
            case "dismiss": try Pipeline.dismiss(id, db)
            case "undo":
                if try Job.fetchOne(db, key: id)?.status == .applied {
                    try Pipeline.undoApplied(id, db)
                } else {
                    try Pipeline.restore(id, db)
                }
            default: return false
            }
            return true
        }
        return known ? try Self.json(["ok": true]) : Self.error(404, "Nothing here.")
    }

    private func packet(for url: String) async throws -> HTTPResponse {
        let found = try await database.reader.read { db -> (Job, JobApplication?, Profile)? in
            guard let job = try PostingMatcher.job(for: url, db) else { return nil }
            let application = try JobApplication.filter(Column("jobId") == job.id).fetchOne(db)
            return (job, application, try Profile.current(db))
        }
        guard let (job, application, profile) = found else {
            return Self.error(404, "This posting isn't in Shortlist.")
        }
        guard let application, let path = application.resumePDFPath,
              let resume = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return Self.error(409, "Prepare this application in Shortlist first.")
        }
        return try Self.json(ApplyPacket(
            job: job, master: application.resume ?? profile.masterResume, profile: profile, blurbs: application.blurbs,
            resumeName: URL(fileURLWithPath: path).lastPathComponent, resumeBase64: resume.base64EncodedString()))
    }

    static func json(_ value: some Encodable) throws -> HTTPResponse {
        HTTPResponse(body: try JSONEncoder().encode(value))
    }

    static func error(_ status: Int, _ message: String) -> HTTPResponse {
        let body = (try? JSONEncoder().encode(["error": message])) ?? Data()
        return HTTPResponse(status: status, body: body)
    }

    /// A long random token, for pairing the extension and signing in on the web.
    public static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// Everything the extension needs to fill one application form.
struct ApplyPacket: Encodable {
    var jobId: Int64
    var title: String
    var company: String
    var firstName: String
    var lastName: String
    var name: String
    var email: String
    var phone: String
    var location: String
    var currentCompany: String
    var linkedIn: String
    var portfolio: String
    var blurbs: [JobApplication.Blurb]
    var resumeName: String
    var resumeBase64: String

    init(job: Job, master: MasterResume, profile: Profile, blurbs: [JobApplication.Blurb], resumeName: String, resumeBase64: String) {
        jobId = job.id ?? 0
        title = job.title
        company = job.companyName
        let names = master.name.split(separator: " ").map(String.init)
        firstName = names.first ?? ""
        lastName = names.dropFirst().joined(separator: " ")
        name = master.name
        email = master.email
        phone = master.phone
        location = master.location.isEmpty ? profile.basedIn : master.location
        currentCompany = master.experience.first?.company ?? ""
        linkedIn = master.links.first { $0.lowercased().contains("linkedin") } ?? ""
        portfolio = master.links.first { !$0.lowercased().contains("linkedin") } ?? ""
        self.blurbs = blurbs
        self.resumeName = resumeName
        self.resumeBase64 = resumeBase64
    }
}

/// Finds the job a browser page is showing. The same posting has several addresses: the listing,
/// its apply page, and for Greenhouse a page on the company's own site.
public enum PostingMatcher {
    public static func key(for text: String) -> String? {
        guard let url = URLComponents(string: text), let host = url.host?.lowercased() else { return nil }
        let items = url.queryItems ?? []
        if let id = items.first(where: { $0.name == "gh_jid" })?.value, !id.isEmpty { return "greenhouse:\(id)" }
        if host.contains("greenhouse.io") {
            if let id = items.first(where: { $0.name == "token" })?.value, !id.isEmpty { return "greenhouse:\(id)" }
            let parts = url.path.split(separator: "/")
            if let index = parts.firstIndex(of: "jobs"), parts.count > index + 1 { return "greenhouse:\(parts[index + 1])" }
        }
        var parts = url.path.split(separator: "/").map(String.init)
        if let last = parts.last?.lowercased(), ["apply", "application"].contains(last) { parts.removeLast() }
        return ([host.replacingOccurrences(of: "www.", with: "")] + parts).joined(separator: "/").lowercased()
    }

    static func job(for url: String, _ db: Database) throws -> Job? {
        guard let wanted = key(for: url) else { return nil }
        return try Job.filter(Column("closedAt") == nil).fetchAll(db).first { job in
            [job.url, job.applyURL].compactMap { $0 }.contains { key(for: $0) == wanted }
        }
    }
}

/// Today's page for the web dashboard.
struct TodayPayload: Encodable {
    var day: String
    var submitted: Int
    var target: Int
    var streak: Int
    var jobs: [Item]

    struct Item: Encodable {
        var id: Int64
        var title: String
        var company: String
        var location: String
        var work: String
        var score: Int?
        var rationale: String
        var strengths: [String]
        var gaps: [String]
        var people: [String]
        var url: String
        var status: String
        var isWaiting: Bool
        var isPrepared: Bool
    }

    static func fetch(_ db: Database) throws -> TodayPayload {
        let log = try Pipeline.log(db)
        let jobs = try JobListItem.open(order: .today, db).map { item in
            Item(id: item.id, title: item.job.title, company: item.job.companyName, location: item.job.location,
                 work: item.job.remotePolicy.rawValue, score: item.score?.score, rationale: item.score?.rationale ?? "",
                 strengths: item.score?.strengths ?? [], gaps: item.score?.gaps ?? [],
                 people: try ReferralFlag.forJob(item.id, db).map(\.connection.fullName),
                 url: item.job.applyURL ?? item.job.url, status: item.job.status.rawValue,
                 isWaiting: item.job.status.isWaiting, isPrepared: item.isPrepared)
        }
        return TodayPayload(day: log.day, submitted: log.submittedCount, target: log.target,
                            streak: try ProgressStats.fetch(db).currentStreak, jobs: jobs)
    }
}

extension Settings {
    /// The server's token, made the first time it's needed.
    public static func serverToken(_ db: Database) throws -> String {
        if let token: String = try value(for: "serverToken", db) { return token }
        let token = AppAPI.newToken()
        try setValue(token, for: "serverToken", db)
        return token
    }

    public static func setServerToken(_ token: String, _ db: Database) throws {
        try setValue(token, for: "serverToken", db)
    }

    public static func webAccess(_ db: Database) throws -> Bool {
        try value(for: "webAccess", db) ?? false
    }

    public static func setWebAccess(_ enabled: Bool, _ db: Database) throws {
        try setValue(enabled, for: "webAccess", db)
    }

    /// The model that writes tailored materials. Stored apart from `scoring`, because a request
    /// here costs far more than a score and is worth changing on its own.
    public static func tailoringModel(_ db: Database) throws -> String {
        try value(for: "tailoringModel", db) ?? "gpt-6.1-sol"
    }

    public static func setTailoringModel(_ model: String, _ db: Database) throws {
        try setValue(model, for: "tailoringModel", db)
    }

    /// The hour of the morning refresh, or nil when it's off.
    public static func morningHour(_ db: Database) throws -> Int? {
        let stored: Int = try value(for: "morningHour", db) ?? 8
        return stored < 0 ? nil : stored
    }

    public static func setMorningHour(_ hour: Int?, _ db: Database) throws {
        try setValue(hour ?? -1, for: "morningHour", db)
    }

    public static func lastMorningRun(_ db: Database) throws -> String? {
        try value(for: "lastMorningRun", db)
    }

    public static func setLastMorningRun(_ day: String, _ db: Database) throws {
        try setValue(day, for: "lastMorningRun", db)
    }
}
