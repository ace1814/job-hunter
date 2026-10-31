import GRDB
import XCTest
@testable import ShortlistCore

final class PipelineTests: XCTestCase {
    private let day = "2026-10-31"
    private var database: AppDatabase!
    private var jobId: Int64!

    override func setUp() async throws {
        database = try AppDatabase.inMemory()
        jobId = try await database.writer.write { db in
            var job = Job(companyName: "Co", title: "Designer", url: "https://example.com", status: .scored)
            try job.insert(db)
            try JobScore(jobId: job.id!, score: 80, rationale: "r", model: "m", profileVersion: 1).insert(db)
            return job.id!
        }
    }

    private func status() throws -> JobStatus? {
        try database.reader.read { try Job.fetchOne($0, key: self.jobId)?.status }
    }

    private func submitted() throws -> Int {
        try database.reader.read { try Pipeline.log(day: self.day, $0).submittedCount }
    }

    func test_markingAppliedCountsOnceAndRecordsTheApplication() throws {
        try database.writer.write { db in
            try Pipeline.markApplied(jobId, day: day, db)
            try Pipeline.markApplied(jobId, day: day, db)
        }
        XCTAssertEqual(try status(), .applied)
        XCTAssertEqual(try submitted(), 1)
        let application = try database.reader.read { try JobApplication.filter(Column("jobId") == self.jobId).fetchOne($0) }
        XCTAssertNotNil(application?.submittedAt)
    }

    func test_undoTakesItBackFromTheDayItWasCounted() throws {
        let date = Date(timeIntervalSince1970: 1_793_000_000)
        let countedDay = Day.key(for: date)
        try database.writer.write { db in
            try Pipeline.markApplied(jobId, day: countedDay, at: date, db)
            try Pipeline.undoApplied(jobId, db)
        }
        XCTAssertEqual(try status(), .scored)
        let count = try database.reader.read { try Pipeline.log(day: countedDay, $0).submittedCount }
        XCTAssertEqual(count, 0)
    }

    func test_undoKeepsTailoredMaterials() throws {
        try database.writer.write { db in
            var application = JobApplication(jobId: jobId, blurbs: [.init(question: "Why?", answer: "Because.")])
            try application.insert(db)
            try Pipeline.markApplied(jobId, day: day, db)
            try Pipeline.undoApplied(jobId, db)
        }
        let application = try database.reader.read { try JobApplication.filter(Column("jobId") == self.jobId).fetchOne($0) }
        XCTAssertEqual(application?.blurbs.count, 1)
        XCTAssertNil(application?.submittedAt)
    }

    func test_dismissedJobsLeaveTheQueueAndCanComeBack() throws {
        try database.writer.write { db in
            try DailyQueueEntry(day: day, jobId: jobId, rank: 1).insert(db)
            try Pipeline.dismiss(jobId, db)
        }
        XCTAssertEqual(try status(), .dismissed)
        let waiting = try database.reader.read { try JobListItem.open(order: .today, day: self.day, $0) }.filter(\.job.status.isWaiting)
        XCTAssertTrue(waiting.isEmpty)

        try database.writer.write { try Pipeline.restore(jobId, $0) }
        XCTAssertEqual(try status(), .queued)
    }

    func test_anEmptyDayStartsAtZeroOfTen() throws {
        let log = try database.reader.read { try Pipeline.log(day: "2030-01-01", $0) }
        XCTAssertEqual(log.submittedCount, 0)
        XCTAssertEqual(log.target, 10)
    }
}
