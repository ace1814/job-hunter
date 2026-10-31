import Foundation
import GRDB

/// Each day's top picks. Once a job is on a day's list it stays there at its rank, so the list
/// doesn't reshuffle while you work through it. A day that started short can still fill up.
public enum DailyQueue {
    public static let size = 15
    /// Below this a job isn't worth your time, even on a quiet day.
    public static let minimumScore = 50

    /// Adds the best waiting jobs until `day` has `size` picks. Returns how many it added.
    @discardableResult
    public static func fill(day: String = Day.today, _ db: Database) throws -> Int {
        let held = try DailyQueueEntry.filter(Column("day") == day).fetchCount(db)
        guard held < size else { return 0 }

        let ids = try Int64.fetchAll(db, sql: """
            SELECT job.id FROM job
            JOIN jobScore ON jobScore.jobId = job.id
            WHERE job.closedAt IS NULL
              AND job.status IN ('scored', 'queued')
              AND jobScore.dealbreakerHit = 0
              AND jobScore.score >= ?
              AND jobScore.profileVersion = ?
              AND job.id NOT IN (SELECT jobId FROM dailyQueue WHERE day = ?)
            ORDER BY jobScore.score DESC,
                     (SELECT COUNT(*) FROM jobReferral WHERE jobReferral.jobId = job.id) DESC,
                     COALESCE(job.postedAt, job.firstSeenAt) DESC
            LIMIT ?
            """, arguments: [minimumScore, try Profile.current(db).version, day, size - held])

        for (offset, id) in ids.enumerated() {
            try DailyQueueEntry(day: day, jobId: id, rank: held + offset + 1).insert(db)
            try db.execute(sql: "UPDATE job SET status = 'queued', statusChangedAt = ? WHERE id = ? AND status = 'scored'",
                           arguments: [Date.now, id])
        }
        return ids.count
    }
}
