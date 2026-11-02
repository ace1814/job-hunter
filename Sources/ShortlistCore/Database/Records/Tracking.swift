import Foundation
import GRDB

/// A dated note you wrote on a job.
public struct JobNote: Codable, Identifiable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "jobNote"

    public var id: Int64?
    public var jobId: Int64
    public var text: String
    public var createdAt: Date

    public init(id: Int64? = nil, jobId: Int64, text: String, createdAt: Date = .now) {
        self.id = id
        self.jobId = jobId
        self.text = text
        self.createdAt = createdAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// Someone you're in touch with about a job. You add these yourself.
public struct JobContact: Codable, Identifiable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "jobContact"

    public var id: Int64?
    public var jobId: Int64
    public var name: String
    public var email: String
    public var createdAt: Date

    public init(id: Int64? = nil, jobId: Int64, name: String, email: String = "", createdAt: Date = .now) {
        self.id = id
        self.jobId = jobId
        self.name = name
        self.email = email
        self.createdAt = createdAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public enum ReminderKind: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    /// Set when you apply: ask how it's going.
    case followUp
    /// Set after an interview: say thanks.
    case thankYou
    /// One you set yourself.
    case custom

    public var title: String {
        switch self {
        case .followUp: "Follow up"
        case .thankYou: "Send a thank-you"
        case .custom: "Reminder"
        }
    }
}

/// Something to do on a job by a date. Shortlist drafts a message for it; you send it yourself.
public struct Reminder: Codable, Identifiable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "reminder"

    public var id: Int64?
    public var jobId: Int64
    public var kind: ReminderKind
    public var dueAt: Date
    public var note: String
    public var draftSubject: String
    public var draftBody: String
    public var doneAt: Date?
    public var createdAt: Date

    public init(id: Int64? = nil, jobId: Int64, kind: ReminderKind, dueAt: Date, note: String = "", createdAt: Date = .now) {
        self.id = id
        self.jobId = jobId
        self.kind = kind
        self.dueAt = dueAt
        self.note = note
        draftSubject = ""
        draftBody = ""
        self.createdAt = createdAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public var isOpen: Bool { doneAt == nil }
    public var hasDraft: Bool { !draftBody.isEmpty }

    /// Due today or earlier. A reminder is for a day, not a time.
    public func isDue(now: Date = .now, calendar: Calendar = .current) -> Bool {
        dueAt < calendar.startOfDay(for: now).addingTimeInterval(86_400) && isOpen
    }

    /// Whole days until it's due, negative when it's overdue.
    public func daysLeft(now: Date = .now, calendar: Calendar = .current) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: dueAt)).day ?? 0
    }
}

/// Every note, contact and open reminder, by job. The tables are small and the screens need them
/// live, so they're read together.
public struct TrackingSnapshot: Equatable, Sendable {
    public var notes: [Int64: [JobNote]] = [:]
    public var contacts: [Int64: [JobContact]] = [:]
    public var reminders: [Int64: [Reminder]] = [:]

    public init() {}

    public static func fetch(_ db: Database) throws -> TrackingSnapshot {
        var snapshot = TrackingSnapshot()
        snapshot.notes = Dictionary(grouping: try JobNote.order(Column("createdAt").desc, Column("id").desc).fetchAll(db), by: \.jobId)
        snapshot.contacts = Dictionary(grouping: try JobContact.order(Column("createdAt"), Column("id")).fetchAll(db), by: \.jobId)
        snapshot.reminders = Dictionary(grouping: try Reminder.filter(Column("doneAt") == nil)
            .order(Column("dueAt"), Column("id")).fetchAll(db), by: \.jobId)
        return snapshot
    }

    public var openReminders: [Reminder] { reminders.values.flatMap { $0 } }

    /// The address a message about this job goes to. The first one you added with an email.
    public func recipient(for jobId: Int64) -> JobContact? {
        contacts[jobId]?.first { !$0.email.isEmpty }
    }
}
