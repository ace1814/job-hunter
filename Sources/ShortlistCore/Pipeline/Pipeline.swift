import Foundation
import GRDB

/// What you do with a job. Applying always happens by you, in your browser: these only record it.
public enum Pipeline {
    /// Records that you applied, and counts it toward `day`. Doing it twice counts once.
    public static func markApplied(_ jobId: Int64, day: String = Day.today, at date: Date = .now, _ db: Database) throws {
        guard let job = try Job.fetchOne(db, key: jobId), job.status != .applied else { return }

        if var application = try JobApplication.filter(Column("jobId") == jobId).fetchOne(db) {
            application.submittedAt = date
            try application.update(db)
        } else {
            var application = JobApplication(jobId: jobId, createdAt: date, submittedAt: date)
            try application.insert(db)
        }
        try setStatus(.applied, of: jobId, at: date, db)
        try db.execute(sql: """
            INSERT INTO dailyLog (day, submittedCount) VALUES (?, 1)
            ON CONFLICT(day) DO UPDATE SET submittedCount = submittedCount + 1
            """, arguments: [day])
    }

    /// Takes back a "Mark Applied", from the day it was counted on. Tailored materials stay.
    public static func undoApplied(_ jobId: Int64, _ db: Database) throws {
        guard var application = try JobApplication.filter(Column("jobId") == jobId).fetchOne(db),
              let submitted = application.submittedAt else { return }
        application.submittedAt = nil
        try application.update(db)
        try db.execute(sql: "UPDATE dailyLog SET submittedCount = MAX(submittedCount - 1, 0) WHERE day = ?",
                       arguments: [Day.key(for: submitted)])
        try restore(jobId, db)
    }

    public static func dismiss(_ jobId: Int64, at date: Date = .now, _ db: Database) throws {
        try setStatus(.dismissed, of: jobId, at: date, db)
    }

    /// Puts a job back where it would be if you hadn't acted on it.
    public static func restore(_ jobId: Int64, _ db: Database) throws {
        let isPicked = try DailyQueueEntry.filter(Column("jobId") == jobId).fetchCount(db) > 0
        let isScored = try JobScore.filter(Column("jobId") == jobId).fetchCount(db) > 0
        try setStatus(isPicked ? .queued : isScored ? .scored : .new, of: jobId, at: .now, db)
    }

    /// Moves an application along after you've sent it.
    public static func setStage(_ status: JobStatus, of jobId: Int64, at date: Date = .now, _ db: Database) throws {
        try setStatus(status, of: jobId, at: date, db)
    }

    public static func log(day: String = Day.today, _ db: Database) throws -> DailyLog {
        try DailyLog.fetchOne(db, key: day) ?? DailyLog(day: day)
    }

    private static func setStatus(_ status: JobStatus, of jobId: Int64, at date: Date, _ db: Database) throws {
        try db.execute(sql: "UPDATE job SET status = ?, statusChangedAt = ? WHERE id = ?",
                       arguments: [status, date, jobId])
    }
}

extension JobStatus {
    /// Still needs a decision from you.
    public var isWaiting: Bool {
        switch self {
        case .new, .scored, .queued, .applying: true
        case .applied, .interviewing, .rejected, .offer, .dismissed: false
        }
    }
}
