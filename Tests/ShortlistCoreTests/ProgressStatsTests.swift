import GRDB
import XCTest
@testable import ShortlistCore

final class ProgressStatsTests: XCTestCase {
    private var database: AppDatabase!
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return calendar
    }()

    override func setUp() async throws {
        database = try AppDatabase.inMemory()
    }

    private func stats(today: String, logs: [(String, Int)]) throws -> ProgressStats {
        try database.writer.write { db in
            for (day, count) in logs { try DailyLog(day: day, submittedCount: count).save(db) }
            return try ProgressStats.fetch(today: today, calendar: calendar, db)
        }
    }

    func test_streakCountsDaysThatHitTheTarget() throws {
        let result = try stats(today: "2026-10-31", logs: [("2026-10-29", 10), ("2026-10-30", 12), ("2026-10-31", 10)])
        XCTAssertEqual(result.currentStreak, 3)
    }

    func test_aDayStillInProgressDoesntBreakTheStreak() throws {
        let result = try stats(today: "2026-10-31", logs: [("2026-10-29", 10), ("2026-10-30", 10), ("2026-10-31", 2)])
        XCTAssertEqual(result.currentStreak, 2)
    }

    func test_aMissedDayEndsTheStreakButBestRemembersIt() throws {
        let result = try stats(today: "2026-10-31", logs: [
            ("2026-10-25", 10), ("2026-10-26", 10), ("2026-10-27", 10), ("2026-10-28", 3), ("2026-10-30", 10),
        ])
        XCTAssertEqual(result.currentStreak, 1)
        XCTAssertEqual(result.bestStreak, 3)
    }

    func test_streaksCrossMonths() throws {
        let result = try stats(today: "2026-11-01", logs: [("2026-10-31", 10), ("2026-11-01", 10)])
        XCTAssertEqual(result.currentStreak, 2)
    }

    func test_recentDaysFillGapsAndEndToday() throws {
        let result = try stats(today: "2026-10-31", logs: [("2026-10-30", 4)])
        XCTAssertEqual(result.recentDays.count, 14)
        XCTAssertEqual(result.recentDays.last?.day, "2026-10-31")
        XCTAssertEqual(result.recentDays[12].submitted, 4)
        XCTAssertEqual(result.recentDays.first?.day, "2026-10-18")
    }

    func test_outcomesCountAsApplied() throws {
        try database.writer.write { db in
            for (index, status) in [JobStatus.applied, .interviewing, .offer, .rejected, .dismissed].enumerated() {
                var job = Job(companyName: "Co \(index)", title: "T", url: "u\(index)", status: status)
                try job.insert(db)
            }
        }
        let result = try stats(today: "2026-10-31", logs: [])
        XCTAssertEqual(result.totalApplied, 4)
        XCTAssertEqual(result.interviewing, 1)
        XCTAssertEqual(result.offers, 1)
        XCTAssertEqual(result.rejected, 1)
    }

    func test_morningRunsOnceADayFromTheChosenHour() {
        var calendar = self.calendar
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let at = { (hour: Int) in calendar.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: hour))! }

        XCTAssertFalse(MorningSchedule.isDue(at: at(7), hour: 8, lastRun: nil, calendar: calendar))
        XCTAssertTrue(MorningSchedule.isDue(at: at(8), hour: 8, lastRun: "2026-10-30", calendar: calendar))
        XCTAssertTrue(MorningSchedule.isDue(at: at(14), hour: 8, lastRun: nil, calendar: calendar), "a late start still runs")
        XCTAssertFalse(MorningSchedule.isDue(at: at(9), hour: 8, lastRun: "2026-10-31", calendar: calendar))
        XCTAssertFalse(MorningSchedule.isDue(at: at(9), hour: nil, lastRun: nil, calendar: calendar), "turned off")
    }
}
