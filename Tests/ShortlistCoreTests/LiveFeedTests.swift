import XCTest
@testable import ShortlistCore

/// Hits the real APIs, into a throwaway database. Skipped unless you ask for it:
///
///     SHORTLIST_LIVE=1 swift test --filter LiveFeedTests
///
/// Run it when a feed starts failing in the app, to see whether the API changed.
final class LiveFeedTests: XCTestCase {
    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SHORTLIST_LIVE"] == "1", "set SHORTLIST_LIVE=1 to run")
    }

    func test_everyKindOfFeedAnswers() async throws {
        let database = try AppDatabase.inMemory()
        try await database.writer.write { db in
            for source in Source.recommended { try Source.add(source, db) }
            try Source.add(Source(kind: .greenhouse, name: "Figma", boardID: "figma"), db)
            try Source.add(Source(kind: .lever, name: "CRED", boardID: "cred"), db)
            try Source.add(Source(kind: .ashby, name: "Notion", boardID: "notion"), db)
            try Source.add(Source(kind: .smartRecruiters, name: "Bosch", boardID: "BoschGroup"), db)
        }

        let report = try await JobIngestor(database: database).refreshAll(force: true)
        for source in report.sources {
            print("LIVE \(source.sourceName): listed \(source.listed), kept \(source.matched), added \(source.added)"
                  + (source.duplicates > 0 ? ", \(source.duplicates) duplicates" : "")
                  + (source.error.map { " — ERROR \($0)" } ?? ""))
        }
        XCTAssertEqual(report.failed.map(\.sourceName), [])
        XCTAssertTrue(report.sources.allSatisfy { $0.listed > 0 }, "a feed came back empty")

        let jobs = try await database.reader.read { try JobListItem.open($0) }
        for item in jobs.prefix(12) {
            print("LIVE job: \(item.job.title) — \(item.job.companyName) — \(item.job.location) [\(item.job.remotePolicy.rawValue)] \(item.job.descriptionText.count) chars")
        }
        XCTAssertTrue(jobs.allSatisfy { !$0.job.title.isEmpty && !$0.job.companyName.isEmpty })
    }

    func test_findingBoardsForWellKnownCompanies() async {
        let finder = BoardFinder(http: URLSessionHTTPClient())
        for company in ["Figma", "CRED", "Notion", "Razorpay", "Groww", "Atlassian"] {
            let boards = await finder.find(company: company)
            print("LIVE boards for \(company): " + (boards.isEmpty ? "none" : boards.map { "\($0.kind.rawValue)/\($0.boardID) (\($0.openJobs))" }.joined(separator: ", ")))
        }
    }
}
