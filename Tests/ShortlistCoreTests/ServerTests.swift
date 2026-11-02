import GRDB
import XCTest
@testable import ShortlistCore

final class ServerTests: XCTestCase {
    private let token = "test-token"
    private var database: AppDatabase!
    private var api: AppAPI!
    private var jobId: Int64!
    private var pdf: URL!

    override func setUp() async throws {
        database = try AppDatabase.inMemory()
        api = AppAPI(database: database, token: token)
        pdf = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).pdf")
        try Data("%PDF".utf8).write(to: pdf)
        addTeardownBlock { [pdf] in try? FileManager.default.removeItem(at: pdf!) }
        jobId = try await database.writer.write { db in
            var job = Job(companyName: "Figma", title: "Designer", url: "https://boards.greenhouse.io/figma/jobs/123?gh_jid=123")
            try job.insert(db)
            try JobScore(jobId: job.id!, score: 90, rationale: "Fits.", model: "m", profileVersion: 1).insert(db)
            try DailyQueueEntry(day: Day.today, jobId: job.id!, rank: 1).insert(db)
            return job.id!
        }
    }

    private func call(_ path: String, method: String = "GET", query: [String: String] = [:], token: String? = nil, body: Data = Data()) async -> HTTPResponse {
        await api.handle(HTTPRequest(method: method, path: path, query: query,
                                     headers: ["authorization": "Bearer \(token ?? self.token)"], body: body))
    }

    private func prepare() async throws {
        var resume = MasterResume()
        resume.name = "Asha Devi Rao"
        resume.email = "asha@example.com"
        resume.links = ["https://linkedin.com/in/asha", "https://asha.design"]
        let (id, path, final) = (jobId!, pdf.path, resume)
        try await database.writer.write { db in
            var application = JobApplication(jobId: id, resume: final, resumePDFPath: path,
                                             blurbs: [.init(question: "Q", answer: "A")])
            try application.insert(db)
        }
    }

    // MARK: Saving from the browser

    func test_theExtensionReadsAPageThenSavesWhatYouConfirmed() async throws {
        let reading = try JSONSerialization.data(withJSONObject: [
            "url": "https://www.linkedin.com/jobs/search/?currentJobId=77",
            "head": "<title>Lead Designer | Razorpay | LinkedIn</title>",
            "text": "About the job",
        ])
        let answer = await call("/api/page", method: "POST", body: reading)
        XCTAssertEqual(answer.status, 200)
        let read = try XCTUnwrap(JSONSerialization.jsonObject(with: answer.body) as? [String: Any])
        var page = try XCTUnwrap(read["page"] as? [String: Any])
        XCTAssertEqual(page["url"] as? String, "https://www.linkedin.com/jobs/view/77/")
        XCTAssertEqual(page["company"] as? String, "Razorpay")
        XCTAssertEqual(read["isTracked"] as? Bool, false)

        // The popup sends the page back, with the fields you edited and your note.
        page["title"] = "Lead Product Designer"
        page["note"] = "From Priya"
        let saved = await call("/api/tracker", method: "POST", body: try JSONSerialization.data(withJSONObject: page))
        XCTAssertEqual(saved.status, 200)
        let added = try JSONDecoder().decode(Tracker.Added.self, from: saved.body)
        let (job, snapshot) = try await database.reader.read { (try Job.fetchOne($0, key: added.jobId), try TrackingSnapshot.fetch($0)) }
        XCTAssertEqual(job?.title, "Lead Product Designer")
        XCTAssertEqual(job?.status, .saved)
        XCTAssertEqual(job?.descriptionText, "About the job")
        XCTAssertEqual(snapshot.notes[added.jobId]?.map(\.text), ["From Priya"])

        let again = await call("/api/page", method: "POST", body: reading)
        let second = try XCTUnwrap(JSONSerialization.jsonObject(with: again.body) as? [String: Any])
        XCTAssertEqual(second["isTracked"] as? Bool, true)
    }

    func test_aJobNeedsATitleAndACompany() async throws {
        let body = try JSONEncoder().encode(Tracker.NewJob(url: "https://acme.com/1", title: " ", company: "Acme"))
        let answer = await call("/api/tracker", method: "POST", body: body)
        XCTAssertEqual(answer.status, 400)
    }

    // MARK: Security

    func test_everyDataRouteNeedsTheToken() async {
        for (method, path) in [("GET", "/api/today"), ("GET", "/api/packet"), ("POST", "/api/jobs/1/applied"),
                               ("POST", "/api/page"), ("POST", "/api/tracker")] {
            let wrong = await call(path, method: method, token: "wrong-token")
            XCTAssertEqual(wrong.status, 401, path)
            let none = await api.handle(HTTPRequest(method: method, path: path))
            XCTAssertEqual(none.status, 401, path)
        }
    }

    func test_theEmptyPageCarriesNoData() async {
        let page = await api.handle(HTTPRequest(method: "GET", path: "/"))
        XCTAssertEqual(page.status, 200)
        XCTAssertTrue(page.contentType.hasPrefix("text/html"))
        XCTAssertFalse(String(decoding: page.body, as: UTF8.self).contains(token))
        XCTAssertFalse(String(decoding: page.body, as: UTF8.self).contains("Figma"))
    }

    func test_nothingAllowsOtherSitesToReadResponses() async {
        let bytes = String(decoding: (await call("/api/today")).bytes, as: UTF8.self)
        XCTAssertFalse(bytes.lowercased().contains("access-control-allow-origin"))
    }

    // MARK: Today

    func test_todayListsPicks() async throws {
        let response = await call("/api/today")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        XCTAssertEqual(json["submitted"] as? Int, 0)
        XCTAssertEqual(json["target"] as? Int, 10)
        let jobs = try XCTUnwrap(json["jobs"] as? [[String: Any]])
        XCTAssertEqual(jobs.first?["title"] as? String, "Designer")
        XCTAssertEqual(jobs.first?["score"] as? Int, 90)
    }

    func test_actionsWorkAndUndoGoesBack() async throws {
        var response = await call("/api/jobs/\(jobId!)/applied", method: "POST")
        XCTAssertEqual(response.status, 200)
        var log = try await database.reader.read { try Pipeline.log($0) }
        XCTAssertEqual(log.submittedCount, 1)

        response = await call("/api/jobs/\(jobId!)/undo", method: "POST")
        XCTAssertEqual(response.status, 200)
        log = try await database.reader.read { try Pipeline.log($0) }
        XCTAssertEqual(log.submittedCount, 0)

        response = await call("/api/jobs/\(jobId!)/dismiss", method: "POST")
        XCTAssertEqual(response.status, 200)
        response = await call("/api/jobs/\(jobId!)/delete", method: "POST")
        XCTAssertEqual(response.status, 404)
        response = await call("/api/jobs/99999/applied", method: "POST")
        XCTAssertEqual(response.status, 404)
    }

    // MARK: Packets

    func test_packetNeedsAPreparedApplication() async {
        let notInApp = await call("/api/packet", query: ["url": "https://jobs.lever.co/acme/abc"])
        XCTAssertEqual(notInApp.status, 404)
        let notReady = await call("/api/packet", query: ["url": "https://job-boards.greenhouse.io/figma/jobs/123"])
        XCTAssertEqual(notReady.status, 409)
    }

    func test_aFormWithAnUnknownAddressIsTakenToBeTheJobYouJustOpened() async throws {
        try await prepare()
        let id = jobId!
        let form = ["url": "https://ats.rippling.com/acme/jobs/9"]
        let before = await call("/api/packet", query: form)
        XCTAssertEqual(before.status, 404)

        try await database.writer.write { try Settings.setLastOpenedJob(id, $0) }
        let opened = await call("/api/packet", query: form)
        XCTAssertEqual(opened.status, 200)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: opened.body) as? [String: Any])?["isGuess"] as? Bool, true)

        let known = await call("/api/packet", query: ["url": "https://job-boards.greenhouse.io/figma/jobs/123"])
        XCTAssertEqual((try JSONSerialization.jsonObject(with: known.body) as? [String: Any])?["isGuess"] as? Bool, false)

        try await database.writer.write { try Settings.setLastOpenedJob(id, at: .now - 2 * 3600, $0) }
        let stale = await call("/api/packet", query: form)
        XCTAssertEqual(stale.status, 404)
    }

    func test_packetCarriesEverythingForTheForm() async throws {
        try await prepare()
        let response = await call("/api/packet", query: ["url": "https://job-boards.greenhouse.io/figma/jobs/123"])
        XCTAssertEqual(response.status, 200)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        XCTAssertEqual(json["firstName"] as? String, "Asha")
        XCTAssertEqual(json["lastName"] as? String, "Devi Rao")
        XCTAssertEqual(json["linkedIn"] as? String, "https://linkedin.com/in/asha")
        XCTAssertEqual(json["portfolio"] as? String, "https://asha.design")
        XCTAssertEqual(json["resumeBase64"] as? String, Data("%PDF".utf8).base64EncodedString())
    }

    func test_thePostingsSeveralAddressesAreOneJob() {
        func key(_ url: String) -> String? { PostingMatcher.key(for: url) }
        XCTAssertEqual(key("https://boards.greenhouse.io/figma/jobs/123?gh_jid=123"), "greenhouse:123")
        XCTAssertEqual(key("https://job-boards.greenhouse.io/figma/jobs/123"), "greenhouse:123")
        XCTAssertEqual(key("https://www.figma.com/careers/job?gh_jid=123"), "greenhouse:123")
        XCTAssertEqual(key("https://boards.greenhouse.io/embed/job_app?token=123"), "greenhouse:123")
        XCTAssertEqual(key("https://jobs.lever.co/cred/abc/apply"), key("https://jobs.lever.co/cred/abc"))
        XCTAssertEqual(key("https://jobs.ashbyhq.com/notion/abc/application"), key("https://jobs.ashbyhq.com/notion/abc?utm=x"))
        XCTAssertNotEqual(key("https://jobs.lever.co/cred/abc"), key("https://jobs.lever.co/cred/xyz"))
        XCTAssertNil(key("not a url"))
    }

    // MARK: The real thing

    func test_answersOverARealSocketOnlyOnTheAddressItWasGiven() async throws {
        let server = LocalServer { [api] in await api!.handle($0) }
        let failed = await server.listen(on: ["127.0.0.1"], port: 18787)
        XCTAssertEqual(failed, [])

        var request = URLRequest(url: URL(string: "http://127.0.0.1:18787/api/today")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        var (data, response) = (Data(), URLResponse())
        for attempt in 0..<20 {
            do {
                (data, response) = try await URLSession.shared.data(for: request)
                break
            } catch where attempt < 19 {
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("Designer"))

        var post = URLRequest(url: URL(string: "http://127.0.0.1:18787/api/jobs/\(jobId!)/applied")!)
        post.httpMethod = "POST"
        post.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (_, posted) = try await URLSession.shared.data(for: post)
        XCTAssertEqual((posted as? HTTPURLResponse)?.statusCode, 200)

        _ = await server.listen(on: [], port: 18787)
    }

    func test_requestParsing() {
        let raw = "POST /api/jobs/1/applied?x=1 HTTP/1.1\r\nHost: a\r\nContent-Length: 2\r\n\r\nhi"
        let request = HTTPRequest.parse(Data(raw.utf8))
        XCTAssertEqual(request?.method, "POST")
        XCTAssertEqual(request?.path, "/api/jobs/1/applied")
        XCTAssertEqual(request?.query["x"], "1")
        XCTAssertEqual(request?.body, Data("hi".utf8))
        XCTAssertNil(HTTPRequest.parse(Data("GET / HTTP/1.1\r\nContent-Length: 5\r\n\r\nhi".utf8)), "waits for the whole body")
        XCTAssertNil(HTTPRequest.parse(Data("GET / HT".utf8)))
    }

    func test_tokensAreLongAndNotRepeated() {
        XCTAssertEqual(AppAPI.newToken().count, 64)
        XCTAssertNotEqual(AppAPI.newToken(), AppAPI.newToken())
    }
}
