import Foundation
import GRDB

/// One job in one day's frozen top picks.
public struct DailyQueueEntry: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "dailyQueue"

    public var day: String
    public var jobId: Int64
    public var rank: Int
    public var profileVersion: Int

    public init(day: String, jobId: Int64, rank: Int, profileVersion: Int = 0) {
        self.day = day
        self.jobId = jobId
        self.rank = rank
        self.profileVersion = profileVersion
    }

    public static let job = belongsTo(Job.self)
}

/// The materials made for one job you chose to apply to.
public struct JobApplication: Codable, Identifiable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "application"

    public var id: Int64?
    public var jobId: Int64
    public var resume: MasterResume?
    public var resumePDFPath: String?
    public var blurbs: [Blurb]
    public var model: String?
    public var createdAt: Date
    public var submittedAt: Date?

    public init(id: Int64? = nil, jobId: Int64, resume: MasterResume? = nil, resumePDFPath: String? = nil,
                blurbs: [Blurb] = [], model: String? = nil, createdAt: Date = .now, submittedAt: Date? = nil) {
        self.id = id
        self.jobId = jobId
        self.resume = resume
        self.resumePDFPath = resumePDFPath
        self.blurbs = blurbs
        self.model = model
        self.createdAt = createdAt
        self.submittedAt = submittedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// An answer to an application question, like "Why do you want to work here?"
    public struct Blurb: Codable, Equatable, Sendable {
        public var question: String
        public var answer: String

        public init(question: String, answer: String) {
            self.question = question
            self.answer = answer
        }
    }

    public static let job = belongsTo(Job.self)
}

/// How many applications went out on one day, against the target.
public struct DailyLog: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "dailyLog"

    public var day: String
    public var target: Int
    public var submittedCount: Int

    public init(day: String, target: Int = 10, submittedCount: Int = 0) {
        self.day = day
        self.target = target
        self.submittedCount = submittedCount
    }
}

/// Days as "yyyy-MM-dd" in your time zone, the key for the queue and the log.
public enum Day {
    public static func key(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    public static var today: String { key(for: .now) }
}
