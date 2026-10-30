import Foundation
import GRDB

/// Finds the 1st-degree connections who work at a job's company.
///
/// Build one from the database with `load(_:)` and reuse it across many jobs: matching is a
/// dictionary lookup, so an import of hundreds of jobs stays instant.
public struct ReferralMatcher: Sendable {
    public struct Match: Equatable, Sendable {
        public var connectionId: Int64
        public var confidence: ReferralConfidence
    }

    /// Names shorter than this never count as a partial match: "ge" shouldn't flag "GE Vernova".
    static let minimumPartialLength = 4

    private struct Employer {
        var normalized: String
        var tokens: [Substring]
        var connectionIds: [Int64]
    }

    /// Connections grouped by their employer's canonical name.
    private var byCanonical: [String: [Employer]] = [:]
    /// The same employers, filed by first word, for partial matches.
    private var byFirstToken: [Substring: [String]] = [:]
    /// Normalized alias → the company's normalized name.
    private let aliases: [String: String]

    /// - Parameters:
    ///   - connections: each connection's id and normalized company.
    ///   - aliases: normalized alias → normalized company name.
    public init(connections: [(id: Int64, normalizedCompany: String)], aliases: [String: String] = [:]) {
        self.aliases = aliases
        var grouped: [String: [Int64]] = [:]
        for connection in connections where !connection.normalizedCompany.isEmpty {
            grouped[connection.normalizedCompany, default: []].append(connection.id)
        }
        for (normalized, ids) in grouped {
            let canonical = aliases[normalized] ?? normalized
            let employer = Employer(normalized: normalized, tokens: normalized.split(separator: " "), connectionIds: ids)
            if byCanonical[canonical] == nil, let first = canonical.split(separator: " ").first {
                byFirstToken[first, default: []].append(canonical)
            }
            byCanonical[canonical, default: []].append(employer)
        }
    }

    public static func load(_ db: Database) throws -> ReferralMatcher {
        let connections = try Row.fetchAll(db, sql: "SELECT id, normalizedCompany FROM connection")
            .map { (id: $0["id"] as Int64, normalizedCompany: $0["normalizedCompany"] as String) }
        let aliases = try Row.fetchAll(db, sql: """
            SELECT companyAlias.alias, company.normalizedName
            FROM companyAlias JOIN company ON company.id = companyAlias.companyId
            """)
        return ReferralMatcher(
            connections: connections,
            aliases: Dictionary(aliases.map { ($0[0] as String, $0[1] as String) }, uniquingKeysWith: { a, _ in a }))
    }

    /// Everyone you know at `company`, strongest matches first.
    public func matches(forCompany company: String) -> [Match] {
        let normalized = CompanyNormalizer.normalize(company)
        guard !normalized.isEmpty else { return [] }
        let canonical = aliases[normalized] ?? normalized

        var best: [Int64: ReferralConfidence] = [:]
        func record(_ ids: [Int64], _ confidence: ReferralConfidence) {
            for id in ids where best[id].map({ confidence < $0 }) ?? true {
                best[id] = confidence
            }
        }

        for employer in byCanonical[canonical] ?? [] {
            record(employer.connectionIds, employer.normalized == normalized ? .exact : .alias)
        }

        // Partial: one name is the other plus more words, like "flipkart" and "flipkart internet".
        let tokens = canonical.split(separator: " ")
        if let first = tokens.first {
            for other in byFirstToken[first] ?? [] where other != canonical {
                let otherTokens = other.split(separator: " ")
                let (short, long) = tokens.count < otherTokens.count ? (tokens, otherTokens) : (otherTokens, tokens)
                guard short.count < long.count, long.starts(with: short),
                      short.joined(separator: " ").count >= Self.minimumPartialLength else { continue }
                for employer in byCanonical[other] ?? [] {
                    record(employer.connectionIds, .possible)
                }
            }
        }

        return best
            .map { Match(connectionId: $0.key, confidence: $0.value) }
            .sorted { ($0.confidence, $0.connectionId) < ($1.confidence, $1.connectionId) }
    }

    /// Rebuilds the referral flags for `jobIds`, or for every job when nil.
    /// Run it after importing connections, editing aliases, or adding jobs.
    @discardableResult
    public static func refresh(_ db: Database, jobIds: [Int64]? = nil) throws -> Int {
        let matcher = try load(db)
        var jobs = Job.select(Column("id"), Column("companyName"))
        if let jobIds { jobs = jobs.filter(keys: jobIds) }
        let rows = try Row.fetchAll(db, jobs)

        if let jobIds {
            try JobReferral.filter(jobIds.contains(Column("jobId"))).deleteAll(db)
        } else {
            try JobReferral.deleteAll(db)
        }

        var count = 0
        for row in rows {
            let jobId: Int64 = row["id"]
            for match in matcher.matches(forCompany: row["companyName"]) {
                try JobReferral(jobId: jobId, connectionId: match.connectionId, confidence: match.confidence).insert(db)
                count += 1
            }
        }
        return count
    }
}

// MARK: - Reading flags

/// A referral flag with the person behind it, for showing on a job.
public struct ReferralFlag: Decodable, Equatable, Sendable, FetchableRecord {
    public var jobReferral: JobReferral
    public var connection: Connection

    public static func forJob(_ jobId: Int64, _ db: Database) throws -> [ReferralFlag] {
        try JobReferral
            .filter(Column("jobId") == jobId)
            .including(required: JobReferral.connection)
            .asRequest(of: ReferralFlag.self)
            .fetchAll(db)
            .sorted { ($0.jobReferral.confidence, $0.connection.fullName) < ($1.jobReferral.confidence, $1.connection.fullName) }
    }
}

/// Where your network is: the companies you know the most people at.
public struct NetworkCompany: Decodable, Equatable, Sendable, FetchableRecord, Identifiable {
    public var normalizedCompany: String
    public var name: String
    public var count: Int

    public var id: String { normalizedCompany }

    public static func top(limit: Int, _ db: Database) throws -> [NetworkCompany] {
        try NetworkCompany.fetchAll(db, sql: """
            SELECT normalizedCompany, MAX(company) AS name, COUNT(*) AS count
            FROM connection
            WHERE normalizedCompany != ''
            GROUP BY normalizedCompany
            ORDER BY count DESC, name
            LIMIT ?
            """, arguments: [limit])
    }
}
