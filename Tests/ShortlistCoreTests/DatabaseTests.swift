import GRDB
import XCTest
@testable import ShortlistCore

final class DatabaseTests: XCTestCase {
    func test_everyTableExistsAfterMigrating() throws {
        let database = try AppDatabase.inMemory()
        try database.reader.read { db in
            for table in ["profile", "company", "companyAlias", "source", "job", "jobFTS", "jobScore",
                          "connection", "jobReferral", "dailyQueue", "application", "dailyLog"] {
                XCTAssertTrue(try db.tableExists(table), table)
            }
        }
    }

    func test_onDiskDatabaseOpensTwice() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            .appending(path: "shortlist.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        _ = try AppDatabase.onDisk(at: url)
        _ = try AppDatabase.onDisk(at: url)
    }

    func test_theSamePostFromTwoFeedsIsOneJob() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            var first = Job(companyName: "Razorpay Software Pvt Ltd", title: "Senior Product Designer",
                            location: "Bengaluru", url: "https://boards.greenhouse.io/razorpay/1")
            try first.insert(db)
            var second = Job(companyName: "Razorpay", title: "Senior Product Designer ",
                             location: "Bengaluru", url: "https://remotive.com/2")
            XCTAssertThrowsError(try second.insert(db))
        }
    }

    func test_profileEditsBumpTheVersion() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            XCTAssertEqual(try Profile.current(db).headline, "")

            var profile = try Profile.current(db)
            profile.headline = "Senior Product Designer"
            profile.targetRoles = ["Senior Product Designer", "Product Manager"]
            profile.masterResume.experience = [.init(company: "Acme", title: "Designer", start: "2020")]
            try Profile.save(profile, db)
            XCTAssertEqual(try Profile.current(db).version, 1)

            profile.headline = "Staff Product Designer"
            try Profile.save(profile, db)
            let saved = try Profile.current(db)
            XCTAssertEqual(saved.version, 2)
            XCTAssertEqual(saved.targetRoles.count, 2)
            XCTAssertEqual(saved.masterResume.experience.first?.company, "Acme")
        }
    }

    func test_scoresAreClampedAndJobsCanBeSearched() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            var job = Job(companyName: "Atlassian", title: "Principal Product Designer",
                          url: "https://example.com", descriptionText: "Own the design system for Jira.")
            try job.insert(db)
            try JobScore(jobId: job.id!, score: 140, rationale: "Strong fit", model: "qwen3:8b", profileVersion: 1).insert(db)
            XCTAssertEqual(try JobScore.fetchOne(db, key: job.id!)?.score, 100)

            let pattern = try XCTUnwrap(FTS5Pattern(matchingAllPrefixesIn: "design jira"))
            let hits = try Job.joining(required: Job.fts.matching(pattern)).fetchAll(db)
            XCTAssertEqual(hits.map(\.id), [job.id])
        }
    }

    func test_dayKeysUseTheLocalCalendar() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        // 20:00 UTC on 30 Oct is 01:30 on 31 Oct in India.
        let date = Date(timeIntervalSince1970: 1_793_390_400)
        XCTAssertEqual(Day.key(for: date, calendar: calendar), "2026-10-31")
    }
}

private extension Job {
    static let fts = hasOne(Table("jobFTS"), using: ForeignKey([Column.rowID], to: [Column.rowID]))
}
