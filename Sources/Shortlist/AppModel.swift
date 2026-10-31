import Foundation
import GRDB
import Observation
import ShortlistCore

/// The app's state: the open database and what the screens show from it.
/// Screens read live values here; GRDB observation keeps them current after any write.
@MainActor
@Observable
final class AppModel {
    let database: AppDatabase?
    private(set) var databaseError: String?
    private let http = URLSessionHTTPClient()

    // Network
    private(set) var network = NetworkSnapshot()
    private(set) var isImporting = false
    /// The result of the last import, shown until the next one.
    private(set) var importMessage: String?

    // Sources
    private(set) var sources: [SourceListItem] = []
    private(set) var leads: [NetworkLead] = []
    private(set) var titleKeywords: [String] = []
    private(set) var isRefreshing = false
    private(set) var refreshMessage: String?
    private(set) var boardSearches: [String: BoardSearch] = [:]

    enum BoardSearch: Equatable {
        case searching
        case found([BoardFinder.Board])
    }

    // Jobs
    private(set) var jobs: [JobListItem] = []
    var jobSearch = "" {
        didSet { if jobSearch != oldValue { observeJobs() } }
    }
    var jobOrder = JobOrder.bestMatch {
        didSet { if jobOrder != oldValue { observeJobs() } }
    }

    // Profile and scoring
    private(set) var profile = Profile()
    private(set) var scoring = ScoringSettings()
    private(set) var hasOpenAIKey = OpenAIKey.exists
    private(set) var pendingScores = 0
    private(set) var labeledJobs = 0
    private(set) var today: [JobListItem] = []
    private(set) var todayLog = DailyLog(day: Day.today)
    private(set) var scoreChecks: [ScoreCheck.Result] = []
    private(set) var scoringProgress: (done: Int, total: Int)?
    private(set) var scoringMessage: String?
    private(set) var isCheckingModel = false
    private(set) var checkMessage: String?
    private(set) var isImportingResume = false
    private(set) var resumeMessage: String?
    var isScoring: Bool { scoringTask != nil }
    private var scoringTask: Task<Void, Never>?

    @ObservationIgnored private var observations: [Task<Void, Never>] = []
    @ObservationIgnored private var jobsObservation: Task<Void, Never>?

    init() {
        do {
            database = try AppDatabase.onDisk()
        } catch {
            database = nil
            databaseError = error.localizedDescription
        }
        observe()
        observeJobs()
        Task { await fillToday() }
        // Left open past midnight, the app still starts the new day's list.
        observations.append(Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .NSCalendarDayChanged) {
                await self?.fillToday()
            }
        })
    }

    // MARK: Observation

    private func observe() {
        guard let reader = database?.reader else { return }
        observations.append(watch(reader, { try NetworkSnapshot.fetch($0) }) { $0.network = $1 })
        observations.append(watch(reader, { db in
            (try SourceListItem.all(db), try NetworkLead.unwatched(limit: 15, db), try Settings.titleKeywords(db))
        }) { model, value in
            (model.sources, model.leads, model.titleKeywords) = value
        })
        observations.append(watch(reader, { db in
            ScoringState(
                profile: try Profile.current(db), scoring: try Settings.scoring(db),
                pending: try JobScorer.pendingCount(db), labeled: try JobLabel.fetchCount(db),
                checks: try Settings.scoreChecks(db))
        }) { model, state in
            model.profile = state.profile
            model.scoring = state.scoring
            model.pendingScores = state.pending
            model.labeledJobs = state.labeled
            model.scoreChecks = state.checks
        })
        observations.append(watch(reader, { db in
            (try JobListItem.open(order: .today, db), try Pipeline.log(db))
        }) { model, value in
            (model.today, model.todayLog) = value
        })
    }

    private struct ScoringState: Sendable {
        var profile: Profile
        var scoring: ScoringSettings
        var pending: Int
        var labeled: Int
        var checks: [ScoreCheck.Result]
    }

    private func observeJobs() {
        guard let reader = database?.reader else { return }
        jobsObservation?.cancel()
        let (search, order) = (jobSearch, jobOrder)
        jobsObservation = watch(reader, { try JobListItem.open(matching: search, order: order, $0) }) { $0.jobs = $1 }
    }

    private func watch<Value: Sendable>(
        _ reader: any DatabaseReader,
        _ fetch: @escaping @Sendable (Database) throws -> Value,
        apply: @escaping @MainActor (AppModel, Value) -> Void
    ) -> Task<Void, Never> {
        let values = ValueObservation.tracking(fetch).values(in: reader)
        return Task { [weak self] in
            do {
                for try await value in values {
                    guard let self else { return }
                    apply(self, value)
                }
            } catch {
                self?.databaseError = error.localizedDescription
            }
        }
    }

    // MARK: Network

    func importConnections(from url: URL) async {
        guard let database, !isImporting else { return }
        isImporting = true
        defer { isImporting = false }

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let summary = try await Task.detached {
                try ConnectionsImporter.importFile(at: url, into: database)
            }.value
            importMessage = Self.describe(summary)
        } catch {
            importMessage = error.localizedDescription
        }
    }

    private static func describe(_ summary: ConnectionsImporter.Summary) -> String {
        var parts = ["\(summary.added) added"]
        if summary.updated > 0 { parts.append("\(summary.updated) updated") }
        if summary.unchanged > 0 { parts.append("\(summary.unchanged) unchanged") }
        if summary.skipped > 0 { parts.append("\(summary.skipped) rows without a name skipped") }
        return parts.joined(separator: " · ")
    }

    // MARK: Sources

    /// Fetches every enabled source. `force` ignores each feed's minimum wait.
    func refreshAll(force: Bool = false) async {
        guard let database, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let report = try await JobIngestor(database: database, http: http).refreshAll(force: force)
            refreshMessage = Self.describe(report)
            await fillToday()
        } catch {
            refreshMessage = error.localizedDescription
        }
    }

    func refresh(_ source: Source) async {
        guard let database else { return }
        let report = await JobIngestor(database: database, http: http).refresh(source)
        refreshMessage = report.error.map { "\(source.name): \($0)" } ?? Self.describe(JobIngestor.Report(sources: [report]))
    }

    private static func describe(_ report: JobIngestor.Report) -> String {
        let fetched = report.sources.filter { !$0.skippedAsRecent && $0.error == nil }
        var parts = ["\(report.added) new job\(report.added == 1 ? "" : "s") from \(fetched.count) source\(fetched.count == 1 ? "" : "s")"]
        if report.closed > 0 { parts.append("\(report.closed) closed") }
        let skipped = report.sources.filter(\.skippedAsRecent).count
        if skipped > 0 { parts.append("\(skipped) checked recently") }
        if !report.failed.isEmpty { parts.append("\(report.failed.count) failed") }
        return parts.joined(separator: " · ")
    }

    /// Adds a source and fetches it straight away.
    func add(_ source: Source) async {
        guard let database else { return }
        do {
            let saved = try await database.writer.write { try Source.add(source, $0) }
            await refresh(saved)
        } catch {
            refreshMessage = error.localizedDescription
        }
    }

    func addRecommended() async {
        guard let database else { return }
        do {
            try await database.writer.write { db in
                for source in Source.recommended { try Source.add(source, db) }
            }
            await refreshAll()
        } catch {
            refreshMessage = error.localizedDescription
        }
    }

    func setEnabled(_ enabled: Bool, for source: Source) {
        try? database?.writer.write { db in
            var saved = source
            try saved.updateChanges(db) { $0.isEnabled = enabled }
        }
    }

    /// Removes a source. Its open jobs are closed so they drop out of your lists; anything you've
    /// applied to keeps its history.
    func remove(_ source: Source) {
        try? database?.writer.write { db in
            try db.execute(sql: "UPDATE job SET closedAt = ? WHERE sourceId = ? AND closedAt IS NULL",
                           arguments: [Date.now, source.id])
            _ = try Source.deleteOne(db, key: source.id)
        }
    }

    func setTitleKeywords(_ text: String) {
        let keywords = text.split(separator: ",").map(String.init)
        try? database?.writer.write { try Settings.setTitleKeywords(keywords, $0) }
    }

    // MARK: Finding boards

    func findBoards(for lead: NetworkLead) async {
        boardSearches[lead.id] = .searching
        let boards = await BoardFinder(http: http).find(company: lead.company.name)
        boardSearches[lead.id] = .found(boards)
    }

    func watch(_ board: BoardFinder.Board, for lead: NetworkLead) async {
        boardSearches[lead.id] = nil
        await add(Source(kind: board.kind, name: lead.company.name, boardID: board.boardID))
    }

    // MARK: Jobs

    func referrals(for job: Job) -> [ReferralFlag] {
        guard let id = job.id else { return [] }
        return (try? database?.reader.read { try ReferralFlag.forJob(id, $0) }) ?? []
    }

    /// Sets your own label, or clears it when you pick the same one again.
    func setLabel(_ label: JobLabelValue, for item: JobListItem) {
        try? database?.writer.write { db in
            if item.label == label {
                _ = try JobLabel.deleteOne(db, key: item.id)
            } else {
                try JobLabel(jobId: item.id, label: label).save(db)
            }
        }
    }

    // MARK: Acting on jobs

    func markApplied(_ item: JobListItem) {
        try? database?.writer.write { try Pipeline.markApplied(item.id, $0) }
    }

    func undoApplied(_ item: JobListItem) {
        try? database?.writer.write { try Pipeline.undoApplied(item.id, $0) }
    }

    func dismiss(_ item: JobListItem) {
        try? database?.writer.write { try Pipeline.dismiss(item.id, $0) }
    }

    func restore(_ item: JobListItem) {
        try? database?.writer.write { try Pipeline.restore(item.id, $0) }
    }

    /// Everything scoring needs is in place.
    var isReadyToScore: Bool {
        !sources.isEmpty && profile.isScoreable && (scoring.provider == .ollama || hasOpenAIKey)
    }

    // MARK: Profile

    func save(_ profile: Profile) {
        try? database?.writer.write { try Profile.save(profile, $0) }
    }

    func save(_ scoring: ScoringSettings) {
        try? database?.writer.write { try Settings.setScoring(scoring, $0) }
    }

    func saveOpenAIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try OpenAIKey.save(trimmed)
            scoringMessage = nil
        } catch {
            scoringMessage = "Couldn't save the key: \(error.localizedDescription)"
        }
        hasOpenAIKey = OpenAIKey.exists
    }

    func removeOpenAIKey() {
        OpenAIKey.delete()
        hasOpenAIKey = OpenAIKey.exists
    }

    private func makeClient() throws -> any ModelClient {
        try scoring.makeClient(apiKey: scoring.provider == .openAI ? OpenAIKey.load() : nil, http: http)
    }

    /// Reads a resume file into your profile. You review it on the Profile screen.
    func importResume(from url: URL) async {
        guard !isImportingResume else { return }
        isImportingResume = true
        defer { isImportingResume = false }

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let text = try ResumeImporter.text(of: url)
            let output = try await ResumeImporter(client: makeClient()).extract(from: text)
            var updated = profile
            updated.masterResume = output.resume
            if updated.headline.isEmpty { updated.headline = output.headline }
            save(updated)
            resumeMessage = "Read \(output.resume.experience.count) roles from \(url.lastPathComponent). Check them below."
        } catch {
            resumeMessage = error.localizedDescription
        }
    }

    // MARK: Scoring

    /// Scores waiting jobs, then fills today's top picks.
    func scoreJobs() {
        guard let database, scoringTask == nil else { return }
        scoringMessage = nil
        scoringTask = Task {
            defer {
                scoringTask = nil
                scoringProgress = nil
            }
            do {
                let client = try makeClient()
                scoringProgress = (0, 0)
                let report = try await JobScorer(database: database, client: client).run { done, total in
                    Task { @MainActor [weak self] in
                        guard let self, self.scoringTask != nil else { return }
                        self.scoringProgress = (done, total)
                    }
                }
                // In its own task, so a pressed Stop doesn't cancel this write too.
                let added = try await Task { try await database.writer.write { try DailyQueue.fill($0) } }.value
                scoringMessage = Self.describe(report, model: client.name, addedToToday: added)
            } catch {
                scoringMessage = error.localizedDescription
            }
        }
    }

    func stopScoring() {
        scoringTask?.cancel()
    }

    func clearScoringMessage() {
        scoringMessage = nil
    }

    /// Picks today's list from scores you already have, which a new day needs even with nothing to score.
    private func fillToday() async {
        _ = try? await database?.writer.write { try DailyQueue.fill($0) }
    }

    private static func describe(_ report: JobScorer.Report, model: String, addedToToday: Int) -> String {
        var parts = ["\(report.scored) scored"]
        if addedToToday > 0 { parts.append("\(addedToToday) added to today") }
        if let dollars = Pricing.dollars(model: model, usage: report.usage), report.usage.input > 0 {
            parts.append(String(format: "about $%.3f", dollars))
        }
        if report.failed > 0 { parts.append("\(report.failed) failed") }
        if let reason = report.stoppedBy ?? report.firstFailure { parts.append(reason) }
        return parts.joined(separator: " · ")
    }

    /// Runs the labeled jobs through the chosen model and records how well it agrees with you.
    func checkModel() async {
        guard let database, !isCheckingModel else { return }
        isCheckingModel = true
        checkMessage = nil
        defer { isCheckingModel = false }
        do {
            _ = try await ScoreCheck(database: database, client: makeClient()).run()
        } catch {
            checkMessage = error.localizedDescription
        }
    }
}
