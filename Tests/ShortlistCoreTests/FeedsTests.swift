import XCTest
@testable import ShortlistCore

/// Each feed against a trimmed copy of its real response, saved 30 Oct 2026.
final class FeedsTests: XCTestCase {
    private let all = TitleFilter(keywords: [])

    // MARK: Company boards

    func test_greenhouse() async throws {
        let http = StubHTTP()
        try http.serve("https://boards-api.greenhouse.io/v1/boards/figma/jobs?content=true", fixture: "greenhouse.json")
        let source = Source(kind: .greenhouse, name: "Figma", boardID: "figma")

        let result = try await Feeds.fetch(source, http: http, filter: TitleFilter(keywords: ["designer"]))
        XCTAssertEqual(result.listedCount, 2)
        XCTAssertEqual(result.allExternalIDs?.count, 2)
        let job = try XCTUnwrap(result.jobs.first)
        XCTAssertEqual(result.jobs.count, 1)
        XCTAssertEqual(job.title, "Brand Designer, Web")
        XCTAssertEqual(job.companyName, "Figma")
        XCTAssertNotNil(job.postedAt)
        XCTAssertTrue(job.url.hasPrefix("https://"))
        // Greenhouse's entity-encoded HTML comes out as plain text.
        XCTAssertFalse(job.descriptionText.contains("<"))
        XCTAssertFalse(job.descriptionText.contains("&lt;"))
        XCTAssertTrue(job.descriptionText.contains("Figma"))
    }

    func test_lever() async throws {
        let http = StubHTTP()
        try http.serve("https://api.lever.co/v0/postings/cred?mode=json", fixture: "lever.json")
        let result = try await Feeds.fetch(Source(kind: .lever, name: "CRED", boardID: "cred"), http: http, filter: all)

        let job = try XCTUnwrap(result.jobs.first)
        XCTAssertEqual(job.title, "accounts payable manager")
        XCTAssertEqual(job.companyName, "CRED")
        XCTAssertEqual(job.location, "hyderabad")
        XCTAssertEqual(job.remotePolicy, .onsite)
        XCTAssertTrue(job.applyURL?.hasSuffix("/apply") ?? false)
        // Lever's text lives in its "lists" when the plain description is empty.
        XCTAssertTrue(job.descriptionText.contains("Prefr"))
        XCTAssertEqual(Calendar(identifier: .gregorian).component(.year, from: try XCTUnwrap(job.postedAt)), 2026)
    }

    func test_ashby() async throws {
        let http = StubHTTP()
        try http.serve("https://api.ashbyhq.com/posting-api/job-board/notion?includeCompensation=true", fixture: "ashby.json")
        let result = try await Feeds.fetch(Source(kind: .ashby, name: "Notion", boardID: "notion"), http: http,
                                           filter: TitleFilter(keywords: ["brand designer"]))
        XCTAssertEqual(result.listedCount, 2)
        let job = try XCTUnwrap(result.jobs.first)
        XCTAssertEqual(job.title, "Brand Designer, Creative Studio")
        XCTAssertEqual(job.remotePolicy, .hybrid)
        XCTAssertTrue(job.url.hasPrefix("https://jobs.ashbyhq.com/notion/"))
        XCTAssertNotNil(job.postedAt)
    }

    func test_smartRecruitersOnlyFetchesDetailsForMatchingTitles() async throws {
        let http = StubHTTP()
        try http.serve("https://api.smartrecruiters.com/v1/companies/BoschGroup/postings?limit=100&offset=0", fixture: "smartrecruiters.json")
        try http.serve("https://api.smartrecruiters.com/v1/companies/BoschGroup/postings/744000158663520", fixture: "smartrecruiters_detail.json")

        let result = try await Feeds.fetch(Source(kind: .smartRecruiters, name: "Bosch", boardID: "BoschGroup"),
                                           http: http, filter: TitleFilter(keywords: ["servicenow", "service now"]))
        XCTAssertEqual(result.listedCount, 2)
        XCTAssertEqual(result.allExternalIDs, ["744000158663520", "744000158661249"])
        let job = try XCTUnwrap(result.jobs.first)
        XCTAssertEqual(result.jobs.count, 1)
        XCTAssertEqual(job.companyName, "Bosch Group")
        XCTAssertEqual(job.location, "coimbatore, India")
        XCTAssertTrue(job.descriptionText.contains("Job Description"))
        XCTAssertEqual(job.url, "https://jobs.smartrecruiters.com/BoschGroup/744000158663520-service-now-expert")
        XCTAssertFalse(http.requests.contains { $0.hasSuffix("744000158661249") })
    }

    // MARK: Remote boards

    func test_himalayasStopsAtTheLastPage() async throws {
        let http = StubHTTP()
        try http.serve("https://himalayas.app/jobs/api/search?page=1&q=product%20designer", fixture: "himalayas.json")
        let result = try await Feeds.fetch(Source(kind: .himalayas, name: "Himalayas", boardID: "product designer"),
                                           http: http, filter: TitleFilter(keywords: ["product design", "ux"]))
        XCTAssertEqual(result.jobs.map(\.title), ["Senior UI & UX Designer", "Staff Product Designer"])
        XCTAssertEqual(result.jobs.first?.remotePolicy, .remote)
        XCTAssertNil(result.allExternalIDs)
        XCTAssertEqual(http.requests.count, 1)
    }

    func test_himalayasAsksForTheCountryAndPutsItFirst() async throws {
        let http = StubHTTP()
        try http.serve("https://himalayas.app/jobs/api/search?country=Canada&page=1&q=product%20designer", fixture: "himalayas.json")
        let result = try await Feeds.fetch(Source(kind: .himalayas, name: "Himalayas", boardID: "product designer|Canada"),
                                           http: http, filter: TitleFilter(keywords: ["product design", "ux"]))
        XCTAssertFalse(result.jobs.isEmpty)
        XCTAssertEqual(http.requests.count, 1)
    }

    func test_remotive() async throws {
        let http = StubHTTP()
        try http.serve("https://remotive.com/api/remote-jobs", fixture: "remotive.json")
        let result = try await Feeds.fetch(Source(kind: .remotive, name: "Remotive"), http: http,
                                           filter: TitleFilter(keywords: ["product design"]))
        XCTAssertEqual(result.listedCount, 2)
        XCTAssertEqual(result.jobs.map(\.title), ["Product Designer"])
        XCTAssertNotNil(result.jobs.first?.postedAt)
    }

    func test_remoteOKSkipsItsLegalNotice() async throws {
        let http = StubHTTP()
        try http.serve("https://remoteok.com/api", fixture: "remoteok.json")
        let result = try await Feeds.fetch(Source(kind: .remoteOK, name: "Remote OK"), http: http, filter: all)
        XCTAssertEqual(result.listedCount, 2)
        let designer = try XCTUnwrap(result.jobs.first { $0.title == "Senior Product Designer" })
        XCTAssertEqual(designer.location, "Worldwide")
        XCTAssertTrue(designer.url.contains("remoteOK.com"))
    }

    func test_hackerNewsReadsTheHeaderLine() async throws {
        let http = StubHTTP()
        http.serve("https://hn.algolia.com/api/v1/search_by_date?hitsPerPage=10&tags=story,author_whoishiring", json: """
            {"hits":[{"objectID":"1","title":"Ask HN: Who wants to be hired? (October 2026)"},
                     {"objectID":"49922569","title":"Ask HN: Who is hiring? (October 2026)"}]}
            """)
        try http.serve("https://hn.algolia.com/api/v1/items/49922569", fixture: "hn_item.json")

        let result = try await Feeds.fetch(Source(kind: .hackerNewsHiring, name: "HN"), http: http,
                                           filter: TitleFilter(keywords: ["engineer"]))
        XCTAssertEqual(result.listedCount, 3)
        // Shepherd's header names no role, so it can't match.
        XCTAssertEqual(result.jobs.map(\.companyName), ["PrairieLearn", "Sidekick Labs"])
        XCTAssertEqual(result.jobs.first?.title, "Full-Stack Software Engineer")
        XCTAssertEqual(result.jobs.first?.remotePolicy, .remote)
        XCTAssertEqual(result.jobs.last?.title, "Senior SWE, R&D Engineer, Intelligence Engineer")
        XCTAssertTrue(result.jobs.first?.url.hasPrefix("https://news.ycombinator.com/item?id=") ?? false)
    }

    func test_weWorkRemotelyRSSSplitsCompanyAndRole() async throws {
        let http = StubHTTP()
        let feed = "https://weworkremotely.com/categories/remote-design-jobs.rss"
        try http.serve(feed, fixture: "wwr.rss")
        let result = try await Feeds.fetch(Source(kind: .rss, name: "WWR", url: feed), http: http,
                                           filter: TitleFilter(keywords: ["designer"]))
        XCTAssertEqual(result.listedCount, 2)
        let job = try XCTUnwrap(result.jobs.first)
        XCTAssertEqual(job.companyName, "Thatch")
        XCTAssertEqual(job.title, "Brand Designer")
        XCTAssertEqual(job.remotePolicy, .remote)
        XCTAssertEqual(job.url, "https://weworkremotely.com/remote-jobs/thatch-brand-designer")
        XCTAssertNotNil(job.postedAt)
        XCTAssertFalse(job.descriptionText.contains("<p>"))
    }

    func test_aMissingBoardSaysSo() async {
        let source = Source(kind: .ashby, name: "Nope", boardID: "zzqqnotreal")
        do {
            _ = try await Feeds.fetch(source, http: StubHTTP(), filter: all)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? FeedError, .notFound)
        }
    }

    // MARK: Helpers

    func test_titleFilter() {
        let filter = TitleFilter(keywords: ["product design", "ux", "product manager", "head of design"])
        XCTAssertTrue(filter.matches("Senior Product Designer"))
        XCTAssertTrue(filter.matches("UI/UX Lead"))
        XCTAssertTrue(filter.matches("Group Product Manager, Payments"))
        XCTAssertTrue(filter.matches("Head of Design"))
        XCTAssertFalse(filter.matches("Product Marketing Manager"))
        XCTAssertFalse(filter.matches("Design Engineer"))
        XCTAssertFalse(filter.matches("Luxury Sales"))
        XCTAssertTrue(TitleFilter(keywords: [" ", ""]).matches("Anything"))
    }

    func test_htmlToPlainText() {
        let html = "&lt;p&gt;Hello &amp;amp; welcome&lt;/p&gt;&lt;ul&gt;&lt;li&gt;One&lt;/li&gt;&lt;li&gt;Two&lt;/li&gt;&lt;/ul&gt;"
        XCTAssertEqual(FeedText.plain(fromHTML: html), "Hello & welcome\n\n• One\n• Two")
        XCTAssertEqual(FeedText.plain(fromHTML: "<p>It&#x27;s &#8377;40L</p><br><br><br><p>Done</p>"), "It's ₹40L\n\nDone")
        XCTAssertEqual(FeedText.plain(fromHTML: "AT&T <b>rocks</b>"), "AT&T rocks")
    }

    func test_dates() {
        XCTAssertNotNil(FeedText.date(iso: "2026-10-27T13:40:12-04:00"))
        XCTAssertNotNil(FeedText.date(iso: "2026-08-24T14:44:49.699+00:00"))
        XCTAssertNotNil(FeedText.date(iso: "2026-10-27T12:56:13"))
        XCTAssertNotNil(FeedText.date(rfc822: "Thu, 29 Oct 2026 22:42:13 +0000"))
        XCTAssertNil(FeedText.date(iso: "soon"))
    }
}
