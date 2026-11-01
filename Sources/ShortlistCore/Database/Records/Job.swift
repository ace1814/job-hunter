import Foundation
import GRDB

/// A feed you read jobs from: one company's job board, a remote-jobs API, or an RSS feed.
public struct Source: Codable, Identifiable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "source"

    public var id: Int64?
    public var kind: SourceKind
    public var name: String
    public var url: String?
    public var boardID: String?
    public var companyId: Int64?
    public var isEnabled: Bool
    public var lastFetchedAt: Date?
    public var lastError: String?

    public init(id: Int64? = nil, kind: SourceKind, name: String, url: String? = nil, boardID: String? = nil,
                companyId: Int64? = nil, isEnabled: Bool = true) {
        self.id = id
        self.kind = kind
        self.name = name
        self.url = url
        self.boardID = boardID
        self.companyId = companyId
        self.isEnabled = isEnabled
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct Job: Codable, Identifiable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "job"

    public var id: Int64?
    public var sourceId: Int64?
    public var externalID: String?
    public var dedupeKey: String
    public var companyId: Int64?
    public var companyName: String
    public var title: String
    public var location: String
    public var remotePolicy: RemotePolicy
    public var url: String
    public var applyURL: String?
    public var descriptionText: String
    public var salaryText: String?
    public var postedAt: Date?
    public var firstSeenAt: Date
    public var status: JobStatus
    public var statusChangedAt: Date
    public var lastSeenAt: Date?
    public var closedAt: Date?
    public var jobType: JobType

    public init(
        id: Int64? = nil, sourceId: Int64? = nil, externalID: String? = nil, companyId: Int64? = nil,
        companyName: String, title: String, location: String = "", remotePolicy: RemotePolicy = .unknown,
        url: String, applyURL: String? = nil, descriptionText: String = "", salaryText: String? = nil,
        postedAt: Date? = nil, firstSeenAt: Date = .now, status: JobStatus = .new, jobType: JobType = .fullTime
    ) {
        self.id = id
        self.sourceId = sourceId
        self.externalID = externalID
        self.dedupeKey = Job.dedupeKey(company: companyName, title: title, location: location)
        self.companyId = companyId
        self.companyName = companyName
        self.title = title
        self.location = location
        self.remotePolicy = remotePolicy
        self.url = url
        self.applyURL = applyURL
        self.descriptionText = descriptionText
        self.salaryText = salaryText
        self.postedAt = postedAt
        self.firstSeenAt = firstSeenAt
        self.status = status
        self.statusChangedAt = firstSeenAt
        self.lastSeenAt = firstSeenAt
        self.jobType = jobType
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public var isOpen: Bool { closedAt == nil }

    /// A post you answer yourself, with no application form behind it.
    public var isDirectPost: Bool { url.contains("reddit.com/r/") }

    /// The same role at the same company and place is one job, whichever feed it came from.
    public static func dedupeKey(company: String, title: String, location: String) -> String {
        [CompanyNormalizer.normalize(company), CompanyNormalizer.fold(title), CompanyNormalizer.fold(location)]
            .joined(separator: "|")
    }

    public static let source = belongsTo(Source.self)
    public static let company = belongsTo(Company.self)
    public static let score = hasOne(JobScore.self)
    public static let referrals = hasMany(JobReferral.self)
    public static let application = hasOne(JobApplication.self)
}

/// The scoring model's verdict on one job, against one version of your profile.
public struct JobScore: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "jobScore"

    public var jobId: Int64
    public var score: Int
    public var rationale: String
    public var strengths: [String]
    public var gaps: [String]
    public var dealbreakerHit: Bool
    public var model: String
    public var profileVersion: Int
    public var scoredAt: Date
    public var criteria: Rubric.Criteria?

    public init(jobId: Int64, score: Int, rationale: String, strengths: [String] = [], gaps: [String] = [],
                dealbreakerHit: Bool = false, model: String, profileVersion: Int, scoredAt: Date = .now,
                criteria: Rubric.Criteria? = nil) {
        self.jobId = jobId
        self.score = min(max(score, 0), 100)
        self.rationale = rationale
        self.strengths = strengths
        self.gaps = gaps
        self.dealbreakerHit = dealbreakerHit
        self.model = model
        self.profileVersion = profileVersion
        self.scoredAt = scoredAt
        self.criteria = criteria
    }
}

/// Your own call on a job, used to check how well a model's scores agree with you.
public struct JobLabel: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "jobLabel"

    public var jobId: Int64
    public var label: JobLabelValue
    public var labeledAt: Date

    public init(jobId: Int64, label: JobLabelValue, labeledAt: Date = .now) {
        self.jobId = jobId
        self.label = label
        self.labeledAt = labeledAt
    }
}
