import Foundation
import GRDB

/// Fetches your sources and files their jobs: new ones added, known ones refreshed, taken-down
/// ones closed, and new ones checked for referrals.
public struct JobIngestor: Sendable {
    public struct SourceReport: Equatable, Sendable {
        public var sourceName: String
        public var listed = 0
        public var matched = 0
        public var added = 0
        public var updated = 0
        public var closed = 0
        /// Already in from another feed.
        public var duplicates = 0
        public var skippedAsRecent = false
        public var error: String?
    }

    public struct Report: Equatable, Sendable {
        public var sources: [SourceReport] = []

        public init(sources: [SourceReport] = []) {
            self.sources = sources
        }

        public var added: Int { sources.reduce(0) { $0 + $1.added } }
        public var closed: Int { sources.reduce(0) { $0 + $1.closed } }
        public var failed: [SourceReport] { sources.filter { $0.error != nil } }
    }

    private let database: AppDatabase
    private let http: any HTTPClient
    private let now: @Sendable () -> Date

    public init(database: AppDatabase, http: any HTTPClient = URLSessionHTTPClient(), now: @escaping @Sendable () -> Date = { .now }) {
        self.database = database
        self.http = http
        self.now = now
    }

    /// Fetches every enabled source, a few at a time. Unless `force`, sources fetched more
    /// recently than their kind allows are skipped.
    public func refreshAll(force: Bool = false) async throws -> Report {
        let sources = try await database.reader.read { db in
            try Source.filter(Column("isEnabled") == true).order(Column("id")).fetchAll(db)
        }
        let reports = await withTaskGroup(of: (Int, SourceReport).self) { group in
            var results: [(Int, SourceReport)] = []
            var next = 0
            func startNext() {
                guard next < sources.count else { return }
                let (index, source) = (next, sources[next])
                next += 1
                group.addTask { (index, await self.refresh(source, force: force)) }
            }
            for _ in 0..<4 { startNext() }
            for await result in group {
                results.append(result)
                startNext()
            }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
        return Report(sources: reports)
    }

    public func refresh(_ source: Source, force: Bool = true) async -> SourceReport {
        var report = SourceReport(sourceName: source.name)
        if !force, let last = source.lastFetchedAt, now().timeIntervalSince(last) < source.kind.minimumInterval {
            report.skippedAsRecent = true
            return report
        }
        do {
            let keywords = try await database.reader.read { try Settings.titleKeywords($0) }
            let result = try await Feeds.fetch(source, http: http, filter: TitleFilter(keywords: keywords))
            report = try await database.writer.write { [report] db in
                var filed = report
                try file(result, from: source, into: &filed, db)
                return filed
            }
        } catch {
            report.error = error.localizedDescription
            let message = report.error
            try? await database.writer.write { db in
                guard var saved = try Source.fetchOne(db, key: source.id) else { return }
                saved.lastError = message
                try saved.update(db)
            }
        }
        return report
    }

    // MARK: Filing

    private func file(_ result: FeedResult, from source: Source, into report: inout SourceReport, _ db: Database) throws {
        guard let sourceId = source.id else { return }
        let time = now()
        report.listed = result.listedCount
        report.matched = result.jobs.count

        var companies = CompanyResolver()
        var newIDs: [Int64] = []
        for fetched in result.jobs {
            var candidate = Job(
                sourceId: sourceId, externalID: fetched.externalID, companyName: fetched.companyName, title: fetched.title,
                location: fetched.location, remotePolicy: fetched.remotePolicy, url: fetched.url, applyURL: fetched.applyURL,
                descriptionText: fetched.descriptionText, salaryText: fetched.salaryText, postedAt: fetched.postedAt,
                firstSeenAt: time)

            let existing = try Job
                .filter(Column("sourceId") == sourceId && Column("externalID") == fetched.externalID)
                .fetchOne(db)
                ?? Job.filter(Column("dedupeKey") == candidate.dedupeKey).fetchOne(db)

            guard var job = existing else {
                candidate.companyId = try companies.id(for: fetched.companyName, db)
                try candidate.insert(db)
                newIDs.append(candidate.id!)
                report.added += 1
                continue
            }

            if job.sourceId != sourceId {
                report.duplicates += 1
                try job.updateChanges(db) { $0.lastSeenAt = time }
                continue
            }
            let changed = try job.updateChanges(db) {
                $0.url = fetched.url
                $0.applyURL = fetched.applyURL
                $0.descriptionText = fetched.descriptionText
                $0.salaryText = fetched.salaryText
                $0.postedAt = fetched.postedAt ?? $0.postedAt
                if fetched.remotePolicy != .unknown { $0.remotePolicy = fetched.remotePolicy }
                $0.closedAt = nil
            }
            if changed { report.updated += 1 }
            try job.updateChanges(db) { $0.lastSeenAt = time }
        }

        // A company board that still answers but no longer lists a job has taken it down. An empty
        // answer is more likely a hiccup than every job closing at once, so it closes nothing.
        if let listed = result.allExternalIDs, !listed.isEmpty {
            let open = try Job
                .filter(Column("sourceId") == sourceId && Column("closedAt") == nil)
                .fetchAll(db)
            for var job in open where !listed.contains(job.externalID ?? "") {
                try job.updateChanges(db) { $0.closedAt = time }
                report.closed += 1
            }
        }

        if var saved = try Source.fetchOne(db, key: sourceId) {
            try saved.updateChanges(db) {
                $0.lastFetchedAt = time
                $0.lastError = nil
            }
        }
        if !newIDs.isEmpty {
            try ReferralMatcher.refresh(db, jobIds: newIDs)
        }
    }
}

/// Finds or creates the company row for a name, through the alias table, once per name.
struct CompanyResolver {
    private var cache: [String: Int64?] = [:]

    mutating func id(for name: String, _ db: Database) throws -> Int64? {
        let normalized = CompanyNormalizer.normalize(name)
        guard !normalized.isEmpty else { return nil }
        if let cached = cache[normalized] { return cached }

        var id = try Int64.fetchOne(db, sql: "SELECT companyId FROM companyAlias WHERE alias = ?", arguments: [normalized])
        if id == nil {
            id = try Company.filter(Column("normalizedName") == normalized).fetchOne(db)?.id
        }
        if id == nil {
            var company = Company(name: name)
            try company.insert(db)
            id = company.id
        }
        cache[normalized] = id
        return id
    }
}
