import GRDB
import XCTest
@testable import ShortlistCore

final class JobIngestorTests: XCTestCase {
    private let figmaURL = "https://boards-api.greenhouse.io/v1/boards/figma/jobs?content=true"
    private var database: AppDatabase!
    private var http: StubHTTP!
    private var source: Source!

    override func setUp() async throws {
        database = try AppDatabase.inMemory()
        http = StubHTTP()
        try http.serve(figmaURL, fixture: "greenhouse.json")
        source = try await database.writer.write { db in
            try Settings.setTitleKeywords(["designer", "account executive"], db)
            return try Source.add(Source(kind: .greenhouse, name: "Figma", boardID: "figma"), db)
        }
    }

    private func ingestor(at time: Date = .now) -> JobIngestor {
        JobIngestor(database: database, http: http, now: { time })
    }

    private func reloadSource() async throws -> Source {
        try await database.reader.read { [source] in try XCTUnwrap(Source.fetchOne($0, key: source!.id)) }
    }

    // MARK: Adding and refreshing

    func test_aFirstFetchAddsJobsAndLinksTheirCompany() async throws {
        let report = await ingestor().refresh(source)
        XCTAssertNil(report.error)
        XCTAssertEqual(report.added, 2)

        try await database.reader.read { db in
            let jobs = try Job.fetchAll(db)
            XCTAssertEqual(jobs.count, 2)
            XCTAssertTrue(jobs.allSatisfy { $0.status == .new && $0.isOpen && $0.companyId != nil })
            XCTAssertEqual(try Company.fetchCount(db), 1)
        }
        let saved = try await reloadSource()
        XCTAssertNotNil(saved.lastFetchedAt)
        XCTAssertNil(saved.lastError)
    }

    func test_fetchingAgainChangesNothing() async throws {
        _ = await ingestor().refresh(source)
        let again = await ingestor().refresh(try await reloadSource())
        XCTAssertEqual(again.added, 0)
        XCTAssertEqual(again.updated, 0)
        XCTAssertEqual(again.closed, 0)
        let count = try await database.reader.read { try Job.fetchCount($0) }
        XCTAssertEqual(count, 2)
    }

    func test_titlesOutsideYourKeywordsAreNotKept() async throws {
        try await database.writer.write { try Settings.setTitleKeywords(["designer"], $0) }
        let report = await ingestor().refresh(source)
        XCTAssertEqual(report.listed, 2)
        XCTAssertEqual(report.matched, 1)
        XCTAssertEqual(report.added, 1)
    }

    // MARK: Closing

    func test_aJobTakenOffTheBoardIsClosedAndReopensIfItComesBack() async throws {
        _ = await ingestor().refresh(source)

        var board = try JSONSerialization.jsonObject(with: Fixture.data("greenhouse.json")) as! [String: Any]
        let jobs = board["jobs"] as! [[String: Any]]
        board["jobs"] = [jobs[0]]
        http.serve(figmaURL, data: try JSONSerialization.data(withJSONObject: board))

        let afterRemoval = await ingestor().refresh(try await reloadSource())
        XCTAssertEqual(afterRemoval.closed, 1)
        let open = try await database.reader.read { try JobListItem.open($0) }
        XCTAssertEqual(open.map(\.job.title), [jobs[0]["title"] as! String])

        try http.serve(figmaURL, fixture: "greenhouse.json")
        let afterReturn = await ingestor().refresh(try await reloadSource())
        XCTAssertEqual(afterReturn.updated, 1)
        let reopened = try await database.reader.read { try JobListItem.open($0) }
        XCTAssertEqual(reopened.count, 2)
    }

    func test_anEmptyBoardClosesNothing() async throws {
        _ = await ingestor().refresh(source)
        http.serve(figmaURL, json: #"{"jobs":[],"meta":{"total":0}}"#)
        let report = await ingestor().refresh(try await reloadSource())
        XCTAssertEqual(report.closed, 0)
    }

    // MARK: Across sources

    func test_theSameJobFromAnotherFeedIsADuplicate() async throws {
        _ = await ingestor().refresh(source)
        let first = try await database.reader.read { try XCTUnwrap(Job.fetchOne($0)) }

        let feed = "https://example.com/jobs.rss"
        http.serve(feed, json: """
            <?xml version="1.0"?><rss version="2.0"><channel><title>Jobs</title>
            <item><title>\(first.companyName): \(first.title)</title><link>https://example.com/1</link>
            <guid>1</guid><description>Same job</description></item>
            </channel></rss>
            """.replacingOccurrences(of: "&", with: "&amp;"))
        // The RSS item has no location, so give the board's job none either.
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE job SET location = '', dedupeKey = ? WHERE id = ?",
                           arguments: [Job.dedupeKey(company: first.companyName, title: first.title, location: ""), first.id])
        }
        let rssSource = try await database.writer.write { try Source.add(Source(kind: .rss, name: "Feed", url: feed), $0) }
        try await database.writer.write { try Settings.setTitleKeywords([], $0) }

        let report = await ingestor().refresh(rssSource)
        XCTAssertNil(report.error)
        XCTAssertEqual(report.added, 0)
        XCTAssertEqual(report.duplicates, 1)
    }

    func test_newJobsAreFlaggedForReferrals() async throws {
        _ = try ConnectionsImporter.importText("""
            First Name,Last Name,Company,Position
            Maya,Chen,"Figma, Inc.",Design Manager
            """, into: database)
        _ = await ingestor().refresh(source)
        let flagged = try await database.reader.read { try JobListItem.open($0) }
        XCTAssertEqual(flagged.map(\.referralCount), [1, 1])
    }

    // MARK: Failures and pacing

    func test_aFailingSourceKeepsItsError() async throws {
        let missing = try await database.writer.write {
            try Source.add(Source(kind: .lever, name: "Nobody", boardID: "zzqqnotreal"), $0)
        }
        let report = await ingestor().refresh(missing)
        XCTAssertEqual(report.error, FeedError.notFound.errorDescription)
        let saved = try await database.reader.read { try Source.fetchOne($0, key: missing.id) }
        XCTAssertEqual(saved?.lastError, FeedError.notFound.errorDescription)
    }

    func test_refreshAllRespectsEachFeedsPace() async throws {
        let now = Date.now
        try await database.writer.write { db in
            var remotive = try Source.add(Source(kind: .remotive, name: "Remotive"), db)
            try remotive.updateChanges(db) { $0.lastFetchedAt = now.addingTimeInterval(-600) }
        }
        let report = try await ingestor(at: now).refreshAll()
        XCTAssertEqual(report.sources.map(\.sourceName), ["Figma", "Remotive"])
        XCTAssertEqual(report.sources.map(\.skippedAsRecent), [false, true])
        XCTAssertEqual(report.added, 2)
        XCTAssertFalse(http.requests.contains { $0.contains("remotive") })
    }

    // MARK: Lists

    func test_jobListSearchAndSourceCounts() async throws {
        _ = await ingestor().refresh(source)
        try await database.reader.read { db in
            XCTAssertEqual(try JobListItem.open(matching: "brand", db).map(\.job.title), ["Brand Designer, Web"])
            XCTAssertEqual(try JobListItem.open(matching: "", db).count, 2)
            XCTAssertEqual(try JobListItem.open(db).first?.sourceKind, .greenhouse)
            XCTAssertEqual(try SourceListItem.all(db).map(\.openJobs), [2])
        }
    }
}
