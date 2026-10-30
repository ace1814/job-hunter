import Foundation
import GRDB

/// Your network at a glance, for the Network screen.
public struct NetworkSnapshot: Equatable, Sendable {
    public var connectionCount = 0
    public var companyCount = 0
    public var withoutCompanyCount = 0
    public var lastImportedAt: Date?
    public var topCompanies: [NetworkCompany] = []

    public init() {}

    public static func fetch(_ db: Database, topLimit: Int = 30) throws -> NetworkSnapshot {
        var snapshot = NetworkSnapshot()
        snapshot.connectionCount = try Connection.fetchCount(db)
        snapshot.companyCount = try Int.fetchOne(db, sql: """
            SELECT COUNT(DISTINCT normalizedCompany) FROM connection WHERE normalizedCompany != ''
            """) ?? 0
        snapshot.withoutCompanyCount = try Connection.filter(Column("normalizedCompany") == "").fetchCount(db)
        snapshot.lastImportedAt = try Date.fetchOne(db, sql: "SELECT MAX(importedAt) FROM connection")
        snapshot.topCompanies = try NetworkCompany.top(limit: topLimit, db)
        return snapshot
    }
}
