import Foundation
import GRDB

public struct Company: Codable, Identifiable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "company"

    public var id: Int64?
    public var name: String
    public var normalizedName: String
    /// Which public job board the company posts on, for watched companies.
    public var atsKind: SourceKind?
    public var atsBoardID: String?
    public var isWatched: Bool
    public var createdAt: Date

    public init(id: Int64? = nil, name: String, atsKind: SourceKind? = nil, atsBoardID: String? = nil,
                isWatched: Bool = false, createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.normalizedName = CompanyNormalizer.normalize(name)
        self.atsKind = atsKind
        self.atsBoardID = atsBoardID
        self.isWatched = isWatched
        self.createdAt = createdAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let aliases = hasMany(CompanyAlias.self)
    public static let jobs = hasMany(Job.self)
}

/// Another name that means this company. `alias` is stored normalized.
public struct CompanyAlias: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "companyAlias"

    public var alias: String
    public var companyId: Int64

    public init(alias: String, companyId: Int64) {
        self.alias = CompanyNormalizer.normalize(alias)
        self.companyId = companyId
    }

    public static let company = belongsTo(Company.self)
}

extension Company {
    /// Adds an alias so `name` matches this company, e.g. `"Facebook"` for Meta.
    public func addAlias(_ name: String, _ db: Database) throws {
        guard let id else { return }
        let alias = CompanyAlias(alias: name, companyId: id)
        guard !alias.alias.isEmpty, alias.alias != normalizedName else { return }
        try alias.save(db)
    }
}
