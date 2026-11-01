import GRDB
import XCTest
@testable import ShortlistCore

final class EligibilityTests: XCTestCase {
    private let profile = Profile(basedIn: "India", locations: ["India on-site or hybrid"])

    private func verdict(_ location: String, policy: RemotePolicy = .remote, description: String = "") -> Eligibility.Verdict {
        Eligibility.verdict(for: Job(companyName: "A", title: "Designer", location: location, remotePolicy: policy,
                                     url: "https://a.test", descriptionText: description), profile: profile)
    }

    private func isOpen(_ location: String, policy: RemotePolicy = .remote, description: String = "") -> Bool {
        verdict(location, policy: policy, description: description) == .open
    }

    func test_jobsLimitedToOtherPlacesAreClosed() {
        for place in ["South Africa", "Kuwait, Saudi Arabia, United Arab Emirates", "Canada", "Argentina", "Sweden", "Thailand",
                      "United States", "Canada, United States", "Remote - US", "Remote, Europe", "LATAM", "EMEA", "Americas",
                      "Melbourne", "Indiana, United States", "Anywhere in the United States", "Southeast Asia"] {
            XCTAssertFalse(isOpen(place), place)
        }
    }

    func test_jobsThatIncludeYouAreOpen() {
        for place in ["India", "Bengaluru, KA, India", "Bangalore", "Remote - India", "United States, India", "Gurugram", "APAC",
                      "Asia Pacific", "Asia", "India, Afghanistan, Albania +188 more"] {
            XCTAssertTrue(isOpen(place), place)
        }
    }

    func test_jobsNamingNoPlaceAreOpen() {
        for place in ["", "Remote", "Anywhere", "Anywhere in the World", "Worldwide", "Global", "Remote (Global)"] {
            XCTAssertTrue(isOpen(place), place)
        }
    }

    func test_anOfficeJobElsewhereIsClosedAndOneInAPlaceYouListedIsOpen() {
        XCTAssertFalse(isOpen("San Francisco, CA", policy: .onsite))
        XCTAssertTrue(isOpen("Pune", policy: .hybrid))
        var movingToDubai = profile
        movingToDubai.locations = ["Dubai"]
        let job = Job(companyName: "A", title: "Designer", location: "Dubai, UAE", remotePolicy: .onsite, url: "https://a.test")
        XCTAssertEqual(Eligibility.verdict(for: job, profile: movingToDubai), .open)
    }

    func test_aPostingThatLimitsItselfIsClosedEvenWhenTheFeedSaysAnywhere() {
        for text in ["This role is US-only.", "You must be based in the United States.", "Candidates must reside in Canada.",
                     "You must be authorized to work in the US.", "This is a remote position within the US.",
                     "Must have the right to work in the UK.", "Must overlap with PST hours.", "Headquarters: Remote - US",
                     "Headquarters: Remote - United States\n\nAbout us"] {
            XCTAssertFalse(isOpen("Anywhere in the World", description: text), text)
        }
    }

    func test_mentioningACountryDoesntLimitAJob() {
        for text in ["We help customers in the United States and Europe.", "Founded in Canada, our team is everywhere.",
                     "Headquarters: San Francisco.", "Headquarters: Remote\n\nAbout us", "Tell us about yourself.", "Help us grow in Europe."] {
            XCTAssertTrue(isOpen("Anywhere", description: text), text)
        }
    }

    func test_nobodyIsScreenedWithoutAHome() {
        let job = Job(companyName: "A", title: "Designer", location: "Canada", url: "https://a.test")
        XCTAssertEqual(Eligibility.verdict(for: job, profile: Profile()), .open)
    }

    func test_applyTakesClosedJobsOffTodayAndWithoutPayingAModel() async throws {
        let database = try AppDatabase.inMemory()
        let (canada, india) = try await database.writer.write { db -> (Int64, Int64) in
            var saved = try Profile.current(db)
            saved.basedIn = "India"
            saved.targetRoles = ["Designer"]
            try Profile.save(saved, db)
            let version = try Profile.current(db).version
            var ids: [Int64] = []
            for (rank, place) in ["Canada", "India"].enumerated() {
                var job = Job(companyName: place, title: "Designer", location: place, remotePolicy: .remote, url: "https://a.test/\(place)", status: .queued)
                try job.insert(db)
                try JobScore(jobId: job.id!, score: 100, rationale: "Great.", model: "m", profileVersion: version).insert(db)
                try DailyQueueEntry(day: Day.today, jobId: job.id!, rank: rank + 1, profileVersion: version).insert(db)
                ids.append(job.id!)
            }
            return (ids[0], ids[1])
        }

        try await database.writer.write { db in try DailyQueue.fill(db) }

        try await database.reader.read { db in
            XCTAssertEqual(try DailyQueueEntry.filter(Column("day") == Day.today).fetchAll(db).map(\.jobId), [india])
            let score = try JobScore.fetchOne(db, key: canada)
            XCTAssertEqual(score?.score, 0)
            XCTAssertEqual(score?.model, Eligibility.checkName)
            XCTAssertEqual(try JobScorer.pendingCount(db), 0)
        }
    }

    func test_aJobThatOpensUpGoesBackToBeScored() async throws {
        let database = try AppDatabase.inMemory()
        try await database.writer.write { db in
            var saved = try Profile.current(db)
            saved.basedIn = "India"
            try Profile.save(saved, db)
            var job = Job(companyName: "A", title: "Designer", location: "Canada", remotePolicy: .remote, url: "https://a.test")
            try job.insert(db)
            try Eligibility.apply(db)
            XCTAssertEqual(try JobScorer.pendingCount(db), 0)

            job.location = "India, Canada"
            try job.update(db)
            try Eligibility.apply(db)
            XCTAssertEqual(try JobScorer.pendingCount(db), 1)
        }
    }
}
