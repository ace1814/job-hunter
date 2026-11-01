import Foundation
import GRDB

/// How your search is going, for the Progress screen and the streak on Today.
public struct ProgressStats: Equatable, Sendable {
    public struct Day: Equatable, Sendable, Identifiable {
        public var day: String
        public var submitted: Int
        public var target: Int
        public var id: String { day }
    }

    /// Days in a row you've hit your target. Today only counts once you've hit it, so a day that's
    /// still in progress never breaks a streak.
    public var currentStreak = 0
    public var bestStreak = 0
    public var totalApplied = 0
    /// Freelance proposals you've sent. These don't count toward `totalApplied` or your target.
    public var proposals = 0
    public var interviewing = 0
    public var offers = 0
    public var rejected = 0
    /// The last 14 days, oldest first, with gaps filled in.
    public var recentDays: [Day] = []

    public init() {}

    public static func fetch(today: String = ShortlistCore.Day.today, calendar: Calendar = .current, _ db: Database) throws -> ProgressStats {
        var stats = ProgressStats()
        let logs = Dictionary(uniqueKeysWithValues: try DailyLog.fetchAll(db).map { ($0.day, $0) })

        var best = 0
        var run = 0
        var previous: Date?
        for log in logs.values.sorted(by: { $0.day < $1.day }) where log.submittedCount >= log.target {
            guard let date = date(log.day, calendar) else { continue }
            let follows = previous.flatMap { calendar.dateComponents([.day], from: $0, to: date).day } == 1
            run = follows ? run + 1 : 1
            best = max(best, run)
            previous = date
        }
        stats.bestStreak = best

        if var cursor = date(today, calendar) {
            func hit(_ date: Date) -> Bool {
                logs[ShortlistCore.Day.key(for: date, calendar: calendar)].map { $0.submittedCount >= $0.target } ?? false
            }
            if !hit(cursor), let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor) { cursor = yesterday }
            while hit(cursor), let earlier = calendar.date(byAdding: .day, value: -1, to: cursor) {
                stats.currentStreak += 1
                cursor = earlier
            }
            stats.recentDays = (0..<14).reversed().compactMap { offset in
                calendar.date(byAdding: .day, value: -offset, to: date(today, calendar) ?? cursor).map { day in
                    let key = ShortlistCore.Day.key(for: day, calendar: calendar)
                    let log = logs[key] ?? DailyLog(day: key)
                    return Day(day: key, submitted: log.submittedCount, target: log.target)
                }
            }
        }

        let counts = Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT status, COUNT(*) AS count FROM job GROUP BY status")
            .map { (row: Row) -> (String, Int) in (row["status"], row["count"]) })
        stats.interviewing = counts["interviewing"] ?? 0
        stats.offers = counts["offer"] ?? 0
        stats.rejected = counts["rejected"] ?? 0
        stats.proposals = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM job
            WHERE jobType != 'fullTime' AND status IN ('applied', 'interviewing', 'rejected', 'offer')
            """) ?? 0
        stats.totalApplied = (counts["applied"] ?? 0) + stats.interviewing + stats.offers + stats.rejected - stats.proposals
        return stats
    }

    private static func date(_ key: String, _ calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}
