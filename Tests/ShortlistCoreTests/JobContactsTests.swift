import XCTest
@testable import ShortlistCore

final class JobContactsTests: XCTestCase {
    private func flag(_ name: String, _ position: String, confidence: ReferralConfidence = .exact, id: Int64) -> ReferralFlag {
        ReferralFlag(jobReferral: JobReferral(jobId: 1, connectionId: id, confidence: confidence),
                     connection: Connection(id: id, firstName: name, lastName: "X", company: "Razorpay", position: position))
    }

    func test_readingTitles() {
        let cases: [(String, JobContacts.Field, JobContacts.Role)] = [
            ("Head of Design", .design, .teamLeader),
            ("VP, User Experience", .design, .teamLeader),
            ("Design Lead", .design, .teamLeader),
            ("Senior Product Designer", .design, .teammate),
            ("Co-Founder & CEO", .design, .founder),
            ("Managing Director", .design, .founder),
            ("Talent Acquisition Partner", .design, .recruiter),
            ("Senior HR Business Partner", .design, .recruiter),
            ("Software Engineer", .design, .other),
            ("Head of Product", .product, .teamLeader),
            ("Senior Product Manager", .product, .teammate),
            ("Head of Design", .product, .other),
            ("Hardware Engineer", .design, .other),
        ]
        for (title, field, role) in cases {
            XCTAssertEqual(JobContacts.role(of: title, in: field), role, title)
        }
    }

    func test_theMostUsefulPeopleComeFirst() {
        let job = Job(companyName: "Razorpay", title: "Senior Product Designer", url: "https://a.test")
        let contacts = JobContacts(job: job, referrals: [
            flag("Ann", "Software Engineer", id: 1),
            flag("Bea", "Recruiter", id: 2),
            flag("Cal", "Founder", id: 3),
            flag("Dev", "Head of Design", confidence: .possible, id: 4),
            flag("Eli", "Design Director", id: 5),
        ])
        XCTAssertEqual(contacts.people.map(\.connection.firstName), ["Eli", "Cal", "Bea", "Ann", "Dev"])
    }

    func test_searchesFollowTheJob() throws {
        let design = JobContacts(job: Job(companyName: "Razorpay", title: "Product Designer", url: "https://a.test"), referrals: [])
        XCTAssertEqual(design.searches.map(\.title), ["Head of Design", "CEO / Founder", "HR / Recruiter"])
        let product = JobContacts(job: Job(companyName: "Tata & Sons", title: "Senior Product Manager", url: "https://a.test"), referrals: [])
        XCTAssertEqual(product.searches.first?.title, "Head of Product")

        let link = try XCTUnwrap(URLComponents(url: product.searches[1].url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(link.host, "www.linkedin.com")
        XCTAssertEqual(link.queryItems?.first?.value, #""Tata & Sons" (CEO OR founder)"#)
    }
}
