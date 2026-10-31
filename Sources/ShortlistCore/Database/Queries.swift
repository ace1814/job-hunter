import Foundation
import GRDB

/// How the job list is ordered.
public enum JobOrder: String, CaseIterable, Sendable {
    case newest
    case bestMatch
    /// Only today's frozen top picks, in their order.
    case today
}

/// A job as the job list shows it: the job, where it came from, how many people you know there,
/// its score, and your own label.
public struct JobListItem: Equatable, Sendable, Identifiable, FetchableRecord {
    public var job: Job
    public var sourceKind: SourceKind?
    public var sourceName: String?
    public var referralCount: Int
    public var score: JobScore?
    public var label: JobLabelValue?

    public var id: Int64 { job.id ?? 0 }

    public init(row: Row) throws {
        job = try Job(row: row)
        sourceKind = row["sourceKind"]
        sourceName = row["sourceName"]
        referralCount = row["referralCount"]
        let scoreValue: Int? = row["score"]
        score = scoreValue == nil ? nil : try JobScore(row: row)
        label = row["labelValue"]
    }

    /// Open jobs, optionally narrowed by a keyword search over title, company and text.
    public static func open(matching search: String = "", order: JobOrder = .newest, day: String = Day.today,
                            limit: Int = 500, _ db: Database) throws -> [JobListItem] {
        var sql = """
            SELECT job.*, jobScore.*, source.kind AS sourceKind, source.name AS sourceName,
                   jobLabel.label AS labelValue,
                   (SELECT COUNT(*) FROM jobReferral WHERE jobReferral.jobId = job.id) AS referralCount
            FROM job
            LEFT JOIN source ON source.id = job.sourceId
            LEFT JOIN jobScore ON jobScore.jobId = job.id
            LEFT JOIN jobLabel ON jobLabel.jobId = job.id
            """
        var arguments: StatementArguments = []
        if order == .today {
            sql += " JOIN dailyQueue ON dailyQueue.jobId = job.id AND dailyQueue.day = ?"
            arguments += [day]
        }
        sql += " WHERE job.closedAt IS NULL"
        if let pattern = FTS5Pattern(matchingAllPrefixesIn: search) {
            sql += " AND job.id IN (SELECT rowid FROM jobFTS WHERE jobFTS MATCH ?)"
            arguments += [pattern]
        }
        switch order {
        case .newest:
            sql += " ORDER BY COALESCE(job.postedAt, job.firstSeenAt) DESC"
        case .bestMatch:
            sql += " ORDER BY jobScore.score IS NULL, jobScore.score DESC, COALESCE(job.postedAt, job.firstSeenAt) DESC"
        case .today:
            sql += " ORDER BY dailyQueue.rank"
        }
        sql += " LIMIT ?"
        arguments += [limit]
        return try JobListItem.fetchAll(db, sql: sql, arguments: arguments)
    }
}

/// A source as the Sources screen shows it, with how many open jobs it has given you.
public struct SourceListItem: Equatable, Sendable, Identifiable, FetchableRecord {
    public var source: Source
    public var openJobs: Int

    public var id: Int64 { source.id ?? 0 }

    public init(row: Row) throws {
        source = try Source(row: row)
        openJobs = row["openJobs"]
    }

    public static func all(_ db: Database) throws -> [SourceListItem] {
        try SourceListItem.fetchAll(db, sql: """
            SELECT source.*,
                   (SELECT COUNT(*) FROM job WHERE job.sourceId = source.id AND job.closedAt IS NULL) AS openJobs
            FROM source
            ORDER BY source.kind IN ('greenhouse', 'lever', 'ashby', 'smartRecruiters') DESC, source.name COLLATE NOCASE
            """)
    }
}

extension Source {
    /// Adds `source` unless the same feed is already there. Returns the saved source.
    @discardableResult
    public static func add(_ source: Source, _ db: Database) throws -> Source {
        if let existing = try Source.fetchAll(db).first(where: { $0.isSameFeed(as: source) }) {
            return existing
        }
        var new = source
        try new.insert(db)
        return new
    }
}

/// Companies you know people at, with no board you're watching yet: the best places to look.
public struct NetworkLead: Equatable, Sendable, Identifiable {
    public var company: NetworkCompany
    public var id: String { company.id }

    public static func unwatched(limit: Int, _ db: Database) throws -> [NetworkLead] {
        let watched = Set(try Source.fetchAll(db).filter(\.kind.isCompanyBoard).map { CompanyNormalizer.normalize($0.name) })
        return try NetworkCompany.top(limit: limit + watched.count, db)
            .filter { !watched.contains($0.normalizedCompany) }
            .prefix(limit)
            .map(NetworkLead.init(company:))
    }
}
