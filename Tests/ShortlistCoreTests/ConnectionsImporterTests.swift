import GRDB
import XCTest
@testable import ShortlistCore

final class ConnectionsImporterTests: XCTestCase {
    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "csv", subdirectory: "Fixtures"))
    }

    // MARK: Parsing

    func test_linkedInExportSkipsTheNotesAboveTheHeader() throws {
        let text = try String(contentsOf: fixture("Connections"), encoding: .utf8)
        let (rows, skipped) = try ConnectionsImporter.parse(text)

        // 9 data rows: one has no name, one repeats Priya.
        XCTAssertEqual(rows.map(\.firstName), ["Priya", "Rahul", "Ana", "Sam", "Kiran", "Neha", "Tom"])
        XCTAssertEqual(skipped, 1)
    }

    func test_quotedFieldsKeepTheirCommasAndLineBreaks() throws {
        let text = try String(contentsOf: fixture("Connections"), encoding: .utf8)
        let rows = try ConnectionsImporter.parse(text).rows

        let rahul = try XCTUnwrap(rows.first { $0.firstName == "Rahul" })
        XCTAssertEqual(rahul.position, "Design Manager, Checkout")
        XCTAssertEqual(rahul.company, "Flipkart Internet Private Limited")

        let neha = try XCTUnwrap(rows.first { $0.firstName == "Neha" })
        XCTAssertEqual(neha.position, "Product Lead\n(ex-Swiggy)")
        XCTAssertEqual(neha.company, "")

        XCTAssertEqual(rows.first { $0.lastName == "O'Brien" }?.company, "Bain & Company")
        XCTAssertEqual(rows.first { $0.firstName == "Ana" }?.lastName, "Gómez")
    }

    func test_aRepeatedPersonKeepsTheLaterRow() throws {
        let text = try String(contentsOf: fixture("Connections"), encoding: .utf8)
        let rows = try ConnectionsImporter.parse(text).rows
        let priyas = rows.filter { $0.firstName == "Priya" }
        XCTAssertEqual(priyas.count, 1)
        XCTAssertEqual(priyas.first?.position, "Staff Product Designer")
    }

    func test_linkedInDatesAreRead() throws {
        let date = try XCTUnwrap(ConnectionsImporter.parseDate("15 Mar 2023"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: date), DateComponents(year: 2023, month: 3, day: 15))
        XCTAssertNotNil(ConnectionsImporter.parseDate("9 Nov 2019"))
        XCTAssertNil(ConnectionsImporter.parseDate("sometime"))
    }

    /// The four-column file from the brief: BOM, CRLF, no URL or date columns.
    func test_aMinimalCSVWorks() throws {
        let text = try String(contentsOf: fixture("MinimalConnections"), encoding: .utf8)
        let rows = try ConnectionsImporter.parse(text).rows
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].firstName, "Aisha")
        XCTAssertEqual(rows[1].position, "PM, Maps")
        XCTAssertNil(rows[1].profileURL)
        XCTAssertNil(rows[1].connectedOn)
    }

    func test_aFileWithoutTheRightColumnsIsRefused() {
        XCTAssertThrowsError(try ConnectionsImporter.parse("Name,Employer\nA,B\n")) {
            XCTAssertEqual($0 as? ConnectionsImporter.ImportError, .headerNotFound)
        }
        XCTAssertThrowsError(try ConnectionsImporter.parse("First Name,Last Name,Position\nA,B,C\n")) {
            XCTAssertEqual($0 as? ConnectionsImporter.ImportError, .missingColumns(["Company"]))
        }
    }

    // MARK: Importing

    func test_importAddsPeopleAndCountsTheOnesWithoutACompany() throws {
        let database = try AppDatabase.inMemory()
        let summary = try ConnectionsImporter.importFile(at: fixture("Connections"), into: database)

        XCTAssertEqual(summary.added, 7)
        XCTAssertEqual(summary.skipped, 1)
        // Kiran is self-employed; Neha has no company.
        XCTAssertEqual(summary.withoutCompany, 2)
        try database.reader.read { db in
            XCTAssertEqual(try Connection.fetchCount(db), 7)
            let priya = try XCTUnwrap(Connection.filter(Column("firstName") == "Priya").fetchOne(db))
            XCTAssertEqual(priya.normalizedCompany, "razorpay")
            XCTAssertEqual(priya.identityKey, "url:linkedin.com/in/priyasharma")
        }
    }

    func test_reimportingUpdatesInsteadOfDuplicating() throws {
        let database = try AppDatabase.inMemory()
        _ = try ConnectionsImporter.importFile(at: fixture("Connections"), into: database)

        let newer = """
            First Name,Last Name,URL,Email Address,Company,Position,Connected On
            Priya,Sharma,https://www.linkedin.com/in/priyasharma/,,Notion Labs,Design Lead,15 Mar 2023
            Rahul,Verma,https://www.linkedin.com/in/rahulverma,,Flipkart Internet Private Limited,"Design Manager, Checkout",02 Jan 2021
            Dev,Patel,https://www.linkedin.com/in/devpatel,,Atlassian,Designer,01 Oct 2026
            """
        let summary = try ConnectionsImporter.importText(newer, into: database)

        XCTAssertEqual(summary.added, 1)
        XCTAssertEqual(summary.updated, 1)
        XCTAssertEqual(summary.unchanged, 1)
        try database.reader.read { db in
            XCTAssertEqual(try Connection.fetchCount(db), 8)
            let priya = try XCTUnwrap(Connection.filter(Column("firstName") == "Priya").fetchOne(db))
            XCTAssertEqual(priya.company, "Notion Labs")
            XCTAssertEqual(priya.normalizedCompany, "notion")
        }
    }
}
