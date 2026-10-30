import XCTest
@testable import ShortlistCore

final class SourceCatalogTests: XCTestCase {
    // MARK: Pasted URLs

    func test_careersURLsBecomeBoards() throws {
        func detect(_ text: String) -> (SourceKind, String?)? {
            SourceLocator.source(from: text).map { ($0.kind, $0.boardID) }
        }
        XCTAssertTrue(detect("https://boards.greenhouse.io/razorpay")! == (.greenhouse, "razorpay"))
        XCTAssertTrue(detect("job-boards.greenhouse.io/figma/jobs/123")! == (.greenhouse, "figma"))
        XCTAssertTrue(detect("https://boards.greenhouse.io/embed/job_board?for=groww")! == (.greenhouse, "groww"))
        XCTAssertTrue(detect("https://jobs.lever.co/cred")! == (.lever, "cred"))
        XCTAssertTrue(detect("https://jobs.ashbyhq.com/notion/1fc3")! == (.ashby, "notion"))
        XCTAssertTrue(detect("https://jobs.smartrecruiters.com/BoschGroup")! == (.smartRecruiters, "BoschGroup"))

        let eu = try XCTUnwrap(SourceLocator.source(from: "https://jobs.eu.lever.co/acme-labs"))
        XCTAssertEqual(eu.url, "https://jobs.eu.lever.co/acme-labs")
        XCTAssertEqual(eu.name, "Acme Labs")
    }

    func test_otherURLsAreTreatedAsFeeds() throws {
        let feed = try XCTUnwrap(SourceLocator.source(from: "https://www.example.com/jobs.rss"))
        XCTAssertEqual(feed.kind, .rss)
        XCTAssertEqual(feed.name, "example.com")
        XCTAssertNil(SourceLocator.source(from: "not a url"))
        XCTAssertNil(SourceLocator.source(from: "https://boards.greenhouse.io/"))
    }

    func test_addingTheSameFeedTwiceKeepsOne() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            try Source.add(Source(kind: .greenhouse, name: "Figma", boardID: "figma"), db)
            try Source.add(Source(kind: .greenhouse, name: "Figma again", boardID: "Figma"), db)
            for source in Source.recommended { try Source.add(source, db) }
            for source in Source.recommended { try Source.add(source, db) }
            XCTAssertEqual(try Source.fetchCount(db), 1 + Source.recommended.count)
        }
    }

    // MARK: Finding boards

    func test_boardNameGuesses() {
        XCTAssertEqual(BoardFinder.candidates(for: "Razorpay Software Pvt Ltd"), ["razorpay"])
        XCTAssertEqual(BoardFinder.candidates(for: "Tata Consultancy"), ["tataconsultancy", "tata-consultancy"])
        XCTAssertEqual(BoardFinder.candidates(for: "Self-employed"), [])
    }

    func test_findingABoard() async throws {
        let http = StubHTTP()
        try http.serve("https://boards-api.greenhouse.io/v1/boards/figma/jobs", fixture: "greenhouse.json")
        http.serve("https://api.smartrecruiters.com/v1/companies/figma/postings?limit=1",
                   json: #"{"offset":0,"limit":1,"totalFound":0,"content":[]}"#)

        let boards = await BoardFinder(http: http).find(company: "Figma, Inc.")
        XCTAssertEqual(boards, [.init(kind: .greenhouse, boardID: "figma", openJobs: 2)])
        // Greenhouse, Lever, Ashby and SmartRecruiters were all tried.
        XCTAssertEqual(http.requests.count, 4)
    }

    func test_networkLeadsLeaveOutCompaniesYouWatch() throws {
        let database = try AppDatabase.inMemory()
        _ = try ConnectionsImporter.importText("""
            First Name,Last Name,Company,Position
            A,One,Razorpay,Designer
            B,Two,Razorpay,PM
            C,Three,Atlassian,Designer
            """, into: database)
        try database.writer.write { db in
            XCTAssertEqual(try NetworkLead.unwatched(limit: 10, db).map(\.company.normalizedCompany), ["razorpay", "atlassian"])
            try Source.add(Source(kind: .lever, name: "Razorpay", boardID: "razorpay"), db)
            XCTAssertEqual(try NetworkLead.unwatched(limit: 10, db).map(\.company.normalizedCompany), ["atlassian"])
        }
    }

    func test_titleKeywordsDefaultUntilYouSetThem() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            XCTAssertEqual(try Settings.titleKeywords(db), Settings.defaultTitleKeywords)
            try Settings.setTitleKeywords(["  designer ", "", "pm"], db)
            XCTAssertEqual(try Settings.titleKeywords(db), ["designer", "pm"])
        }
    }
}
