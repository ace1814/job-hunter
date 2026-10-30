import Foundation
import GRDB

/// A job as the job list shows it: the job, where it came from, and how many people you know there.
public struct JobListItem: Equatable, Sendable, Identifiable, FetchableRecord {
    public var job: Job
    public var sourceKind: SourceKind?
    public var sourceName: String?
    public var referralCount: Int

    public var id: Int64 { job.id ?? 0 }

    public init(row: Row) throws {
        job = try Job(row: row)
        sourceKind = row["sourceKind"]
        sourceName = row["sourceName"]
        referralCount = row["referralCount"]
    }

    /// Open jobs, newest first, optionally narrowed by a keyword search over title, company and text.
    public static func open(matching search: String = "", limit: Int = 500, _ db: Database) throws -> [JobListItem] {
        var sql = """
            SELECT job.*, source.kind AS sourceKind, source.name AS sourceName,
                   (SELECT COUNT(*) FROM jobReferral WHERE jobReferral.jobId = job.id) AS referralCount
            FROM job
            LEFT JOIN source ON source.id = job.sourceId
            WHERE job.closedAt IS NULL
            """
        var arguments: StatementArguments = []
        if let pattern = FTS5Pattern(matchingAllPrefixesIn: search) {
            sql += " AND job.id IN (SELECT rowid FROM jobFTS WHERE jobFTS MATCH ?)"
            arguments += [pattern]
        }
        sql += " ORDER BY COALESCE(job.postedAt, job.firstSeenAt) DESC LIMIT ?"
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
