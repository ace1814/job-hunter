import Foundation
import GRDB

/// Follow-ups and other things due on a job. Nothing here sends anything: a reminder only tells you.
public enum Reminders {
    /// How far "Later" moves a reminder, in days.
    public static let snoozeDays = 3
    /// The hour a day's reminders are announced.
    public static let notificationHour = 10

    /// Sets the follow-up for an application, `Settings.followUpDays` after it went out. A job only
    /// ever has one waiting.
    static func addFollowUp(_ jobId: Int64, appliedAt date: Date, calendar: Calendar = .current, _ db: Database) throws {
        let days = try Settings.followUpDays(db)
        guard days > 0, try !hasOpen(.followUp, jobId, db),
              let due = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: date)) else { return }
        var reminder = Reminder(jobId: jobId, kind: .followUp, dueAt: due, createdAt: date)
        try reminder.insert(db)
    }

    static func addThankYou(_ jobId: Int64, interviewedAt date: Date, calendar: Calendar = .current, _ db: Database) throws {
        guard try !hasOpen(.thankYou, jobId, db),
              let due = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) else { return }
        var reminder = Reminder(jobId: jobId, kind: .thankYou, dueAt: due, createdAt: date)
        try reminder.insert(db)
    }

    public static func add(_ jobId: Int64, dueAt: Date, note: String, at date: Date = .now, _ db: Database) throws {
        var reminder = Reminder(jobId: jobId, kind: .custom, dueAt: dueAt, note: note.trimmed, createdAt: date)
        try reminder.insert(db)
    }

    public static func finish(_ id: Int64, at date: Date = .now, _ db: Database) throws {
        try db.execute(sql: "UPDATE reminder SET doneAt = ? WHERE id = ?", arguments: [date, id])
    }

    /// Moves a reminder on from today, not from its due date, so an old one doesn't stay overdue.
    public static func snooze(_ id: Int64, now: Date = .now, calendar: Calendar = .current, _ db: Database) throws {
        guard let due = calendar.date(byAdding: .day, value: snoozeDays, to: calendar.startOfDay(for: now)) else { return }
        try db.execute(sql: "UPDATE reminder SET dueAt = ? WHERE id = ?", arguments: [due, id])
    }

    public static func saveDraft(_ id: Int64, subject: String, body: String, _ db: Database) throws {
        try db.execute(sql: "UPDATE reminder SET draftSubject = ?, draftBody = ? WHERE id = ?", arguments: [subject, body, id])
    }

    static func finishFollowUps(_ jobId: Int64, at date: Date, _ db: Database) throws {
        try db.execute(sql: "UPDATE reminder SET doneAt = ? WHERE jobId = ? AND kind = ? AND doneAt IS NULL",
                       arguments: [date, jobId, ReminderKind.followUp])
    }

    static func finishAll(_ jobId: Int64, at date: Date, _ db: Database) throws {
        try db.execute(sql: "UPDATE reminder SET doneAt = ? WHERE jobId = ? AND doneAt IS NULL", arguments: [date, jobId])
    }

    /// For taking back an application: the follow-up was never needed.
    static func removeOpenFollowUps(_ jobId: Int64, _ db: Database) throws {
        try db.execute(sql: "DELETE FROM reminder WHERE jobId = ? AND kind = ? AND doneAt IS NULL",
                       arguments: [jobId, ReminderKind.followUp])
    }

    private static func hasOpen(_ kind: ReminderKind, _ jobId: Int64, _ db: Database) throws -> Bool {
        try Reminder.filter(Column("jobId") == jobId && Column("kind") == kind && Column("doneAt") == nil).fetchCount(db) > 0
    }

    // MARK: Notifications

    /// One notification for one day. At ten applications a day, a banner per job would be noise.
    public struct Announcement: Equatable, Sendable {
        public var day: String
        public var fireAt: DateComponents
        public var title: String
        public var body: String
    }

    /// What to announce from now on: a day each reminder falls due, once. Days already past their
    /// hour are left out, because the Today screen shows those.
    public static func announcements(_ reminders: [Reminder], companies: [Int64: String], now: Date = .now,
                                     calendar: Calendar = .current) -> [Announcement] {
        let byDay = Dictionary(grouping: reminders.filter(\.isOpen)) { calendar.startOfDay(for: $0.dueAt) }
        return byDay.keys.sorted().compactMap { day in
            guard let fire = calendar.date(bySettingHour: notificationHour, minute: 0, second: 0, of: day), fire > now,
                  let due = byDay[day] else { return nil }
            let names = due.sorted { ($0.dueAt, $0.id ?? 0) < ($1.dueAt, $1.id ?? 0) }.compactMap { companies[$0.jobId] }
            let unique = names.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            let shown = unique.prefix(3).joined(separator: ", ")
            let rest = unique.count - min(unique.count, 3)
            return Announcement(
                day: Day.key(for: day, calendar: calendar),
                fireAt: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fire),
                title: due.count == 1 ? "1 follow-up due" : "\(due.count) follow-ups due",
                body: rest > 0 ? "\(shown) and \(rest) more" : shown)
        }
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
