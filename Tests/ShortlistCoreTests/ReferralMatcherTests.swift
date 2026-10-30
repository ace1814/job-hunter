import GRDB
import XCTest
@testable import ShortlistCore

final class ReferralMatcherTests: XCTestCase {
    private func matcher(_ companies: [Int64: String], aliases: [String: String] = [:]) -> ReferralMatcher {
        ReferralMatcher(
            connections: companies.map { (id: $0.key, normalizedCompany: CompanyNormalizer.normalize($0.value)) },
            aliases: aliases)
    }

    // MARK: Matching

    func test_differentSpellingsOfTheSameCompanyMatchExactly() {
        let m = matcher([1: "Razorpay Software Pvt. Ltd.", 2: "Atlassian"])
        XCTAssertEqual(m.matches(forCompany: "Razorpay"), [.init(connectionId: 1, confidence: .exact)])
        XCTAssertEqual(m.matches(forCompany: "Atlassian Corporation Plc"), [.init(connectionId: 2, confidence: .exact)])
    }

    func test_aSimilarNameIsNotAMatch() {
        let m = matcher([1: "Metabase", 2: "GE Healthcare"])
        XCTAssertEqual(m.matches(forCompany: "Meta"), [])
        // Too short to trust as a partial match.
        XCTAssertEqual(m.matches(forCompany: "GE"), [])
    }

    func test_aLongerFormOfTheNameIsAPossibleMatch() {
        let m = matcher([1: "Flipkart Internet Private Limited", 2: "Flipkart"])
        XCTAssertEqual(m.matches(forCompany: "Flipkart"), [
            .init(connectionId: 2, confidence: .exact),
            .init(connectionId: 1, confidence: .possible),
        ])
    }

    func test_aliasesJoinNamesTheNormalizerCant() {
        let m = matcher([1: "Facebook", 2: "Meta"], aliases: ["facebook": "meta"])
        XCTAssertEqual(m.matches(forCompany: "Meta"), [
            .init(connectionId: 2, confidence: .exact),
            .init(connectionId: 1, confidence: .alias),
        ])
        XCTAssertEqual(m.matches(forCompany: "Facebook").first, .init(connectionId: 1, confidence: .exact))
    }

    func test_placeholderEmployersNeverMatch() {
        let m = matcher([1: "Self-employed", 2: ""])
        XCTAssertEqual(m.matches(forCompany: "Self Employed"), [])
        XCTAssertEqual(m.matches(forCompany: ""), [])
    }

    // MARK: Flags in the database

    func test_importingConnectionsFlagsExistingJobs() throws {
        let database = try AppDatabase.inMemory()
        let jobIds = try database.writer.write { db in
            var razorpay = Job(companyName: "Razorpay", title: "Senior Product Designer", url: "https://example.com/1")
            var meta = Job(companyName: "Meta", title: "Product Designer", location: "London", url: "https://example.com/2")
            var nobody = Job(companyName: "Nowhere Inc", title: "Designer", url: "https://example.com/3")
            try razorpay.insert(db)
            try meta.insert(db)
            try nobody.insert(db)
            return [razorpay.id!, meta.id!, nobody.id!]
        }

        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "Connections", withExtension: "csv", subdirectory: "Fixtures"))
        let summary = try ConnectionsImporter.importFile(at: fixture, into: database)
        XCTAssertEqual(summary.jobsWithReferrals, 2)

        try database.reader.read { db in
            let razorpayFlags = try ReferralFlag.forJob(jobIds[0], db)
            XCTAssertEqual(razorpayFlags.map(\.connection.fullName), ["Priya Sharma"])
            XCTAssertEqual(razorpayFlags.first?.jobReferral.confidence, .exact)

            // Ana at Meta, not Sam at Metabase.
            XCTAssertEqual(try ReferralFlag.forJob(jobIds[1], db).map(\.connection.fullName), ["Ana Gómez"])
            XCTAssertEqual(try ReferralFlag.forJob(jobIds[2], db), [])
        }
    }

    func test_addingAnAliasAndRefreshingPicksUpTheMatch() throws {
        let database = try AppDatabase.inMemory()
        _ = try ConnectionsImporter.importText("""
            First Name,Last Name,Company,Position
            Old,Timer,Facebook,Designer
            """, into: database)

        try database.writer.write { db in
            var job = Job(companyName: "Meta Platforms", title: "Product Designer", url: "https://example.com/1")
            try job.insert(db)
            XCTAssertEqual(try ReferralMatcher.refresh(db, jobIds: [job.id!]), 0)

            var meta = Company(name: "Meta Platforms")
            try meta.insert(db)
            try meta.addAlias("Facebook", db)
            XCTAssertEqual(try ReferralMatcher.refresh(db, jobIds: [job.id!]), 1)
            XCTAssertEqual(try ReferralFlag.forJob(job.id!, db).first?.jobReferral.confidence, .alias)
        }
    }

    func test_networkSummaryRanksCompaniesByPeople() throws {
        let database = try AppDatabase.inMemory()
        _ = try ConnectionsImporter.importText("""
            First Name,Last Name,Company,Position
            A,One,Razorpay,Designer
            B,Two,Razorpay Software Pvt Ltd,PM
            C,Three,Atlassian,Designer
            D,Four,Self-employed,Consultant
            """, into: database)
        let top = try database.reader.read { try NetworkCompany.top(limit: 5, $0) }
        XCTAssertEqual(top.map(\.normalizedCompany), ["razorpay", "atlassian"])
        XCTAssertEqual(top.map(\.count), [2, 1])

        let snapshot = try database.reader.read { try NetworkSnapshot.fetch($0) }
        XCTAssertEqual(snapshot.connectionCount, 4)
        XCTAssertEqual(snapshot.companyCount, 2)
        XCTAssertEqual(snapshot.withoutCompanyCount, 1)
        XCTAssertNotNil(snapshot.lastImportedAt)
    }
}
