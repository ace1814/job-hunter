import GRDB
import XCTest
@testable import ShortlistCore

final class NetworkBoardScannerTests: XCTestCase {
    private let figmaBoard = "https://boards-api.greenhouse.io/v1/boards/figma/jobs"
    private var database: AppDatabase!
    private var http: StubHTTP!

    override func setUp() async throws {
        database = try AppDatabase.inMemory()
        http = StubHTTP()
        http.serve(figmaBoard, json: #"{"jobs": [{"company_name": "Figma"}]}"#)
        try await addConnections(at: "Figma, Inc.", "Acme")
    }

    private func addConnections(at companies: String...) async throws {
        try await database.writer.write { db in
            for company in companies {
                var connection = Connection(firstName: "A", lastName: company, company: company, position: "Designer")
                try connection.insert(db)
            }
        }
    }

    private func boards() async throws -> [Source] {
        try await database.reader.read { try Source.fetchAll($0) }
    }

    func test_connectsConfirmedBoardsAndRemembersWhatItChecked() async throws {
        let scanner = NetworkBoardScanner(database: database, http: http)
        let report = try await scanner.run()

        XCTAssertEqual(report.checked, 2)
        XCTAssertEqual(report.connected.map(\.boardID), ["figma"])
        let saved = try await boards()
        XCTAssertEqual(saved.map(\.kind), [.greenhouse])
        XCTAssertEqual(saved.first?.boardID, "figma")

        let calls = http.requests.count
        let again = try await scanner.run()
        XCTAssertEqual(again.checked, 0)
        XCTAssertEqual(http.requests.count, calls)
    }

    func test_someoneElsesBoardIsNotConnected() async throws {
        try await addConnections(at: "Step")
        http.serve("https://boards-api.greenhouse.io/v1/boards/step/jobs",
                   json: #"{"jobs": [{"company_name": "Next Step Staffing"}]}"#)
        http.serve("https://api.lever.co/v0/postings/step?mode=json",
                   json: #"[{"text": "Designer", "descriptionPlain": "The first step is a chat."}]"#)

        let report = try await NetworkBoardScanner(database: database, http: http).run()

        XCTAssertFalse(report.connected.contains { $0.company == "Step" })
    }

    func test_boardsWithoutAnOwnerMustTalkAboutThemselves() {
        let own = BoardFinder.Board(kind: .lever, boardID: "cred", openJobs: 2,
                                    postingsText: "CRED is hiring. Join CRED. Life at CRED. Credit cards.")
        XCTAssertTrue(own.belongs(to: "CRED"))

        let mentions = BoardFinder.Board(kind: .lever, boardID: "linkedin", openJobs: 2,
                                         postingsText: "Send your LinkedIn profile. LinkedIn profile URL. Follow us on LinkedIn.")
        XCTAssertFalse(mentions.belongs(to: "LinkedIn"), "naming a site isn't being that company")

        let credit = BoardFinder.Board(kind: .lever, boardID: "cred", openJobs: 2, postingsText: "at credit, about credit, join credits")
        XCTAssertFalse(credit.belongs(to: "CRED"), "a word inside a longer word doesn't count")
    }

    func test_ownerNamesMayAddAWordButNotChangeTheCompany() {
        func board(owner: String) -> BoardFinder.Board {
            BoardFinder.Board(kind: .greenhouse, boardID: "x", openJobs: 1, ownerName: owner)
        }
        XCTAssertTrue(board(owner: "Bosch Group").belongs(to: "Bosch"))
        XCTAssertTrue(board(owner: "Figma").belongs(to: "Figma, Inc."))
        XCTAssertTrue(board(owner: "HackerRank").belongs(to: "Hacker Rank"))
        XCTAssertTrue(board(owner: "Rubrik Job Board").belongs(to: "Rubrik"))
        XCTAssertFalse(board(owner: "Next Step").belongs(to: "Step"))
        XCTAssertFalse(board(owner: "Air").belongs(to: "Air India Limited"))
        XCTAssertFalse(board(owner: "Gemini").belongs(to: "Gemini Solutions Pvt Ltd"))
        XCTAssertFalse(board(owner: "Pine").belongs(to: "Pine Labs"))
    }

    func test_companiesWithBoardsAreLeftOutAndOldChecksComeBack() async throws {
        try await database.writer.write { db in
            try Source.add(Source(kind: .greenhouse, name: "Figma", boardID: "figma"), db)
            try db.execute(sql: "INSERT INTO boardScan (normalizedCompany, scannedAt) VALUES ('acme', ?)", arguments: [Date.now])
        }
        var waiting = try await database.reader.read { try NetworkBoardScanner.companiesToCheck($0) }
        XCTAssertEqual(waiting, [])

        let later = Date.now.addingTimeInterval(31 * 24 * 3600)
        waiting = try await database.reader.read { try NetworkBoardScanner.companiesToCheck(at: later, $0) }
        XCTAssertEqual(waiting.map(\.normalizedCompany), ["acme"])
    }
}
