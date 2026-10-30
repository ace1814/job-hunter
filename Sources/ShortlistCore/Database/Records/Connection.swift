import Foundation
import GRDB

/// A 1st-degree connection, from your LinkedIn export.
public struct Connection: Codable, Identifiable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "connection"

    public var id: Int64?
    public var identityKey: String
    public var firstName: String
    public var lastName: String
    public var company: String
    public var normalizedCompany: String
    public var position: String
    public var profileURL: String?
    public var connectedOn: Date?
    public var importedAt: Date

    public init(id: Int64? = nil, firstName: String, lastName: String, company: String, position: String,
                profileURL: String? = nil, connectedOn: Date? = nil, importedAt: Date = .now) {
        self.id = id
        self.firstName = firstName
        self.lastName = lastName
        self.company = company
        self.normalizedCompany = CompanyNormalizer.normalize(company)
        self.position = position
        self.profileURL = profileURL
        self.connectedOn = connectedOn
        self.importedAt = importedAt
        self.identityKey = Connection.identityKey(
            firstName: firstName, lastName: lastName, company: company, profileURL: profileURL)
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public var fullName: String {
        [firstName, lastName].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The profile URL identifies a person best. Without one, name + company is the fallback,
    /// so someone who changed jobs shows up as a new row; the URL is in every LinkedIn export.
    public static func identityKey(firstName: String, lastName: String, company: String, profileURL: String?) -> String {
        if let url = profileURL?.trimmingCharacters(in: .whitespaces).lowercased(), !url.isEmpty {
            var key = url
            for prefix in ["https://", "http://", "www."] where key.hasPrefix(prefix) {
                key.removeFirst(prefix.count)
            }
            while key.hasSuffix("/") { key.removeLast() }
            return "url:" + key
        }
        let name = CompanyNormalizer.fold("\(firstName) \(lastName)")
        return "name:\(name)|\(CompanyNormalizer.normalize(company))"
    }

    public static let referrals = hasMany(JobReferral.self)
}

/// A flag that you know someone at the company hiring for a job.
public struct JobReferral: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "jobReferral"

    public var jobId: Int64
    public var connectionId: Int64
    public var confidence: ReferralConfidence

    public init(jobId: Int64, connectionId: Int64, confidence: ReferralConfidence) {
        self.jobId = jobId
        self.connectionId = connectionId
        self.confidence = confidence
    }

    public static let job = belongsTo(Job.self)
    public static let connection = belongsTo(Connection.self)
}
