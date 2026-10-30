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
    }

    private func observeJobs() {
        guard let reader = database?.reader else { return }
        jobsObservation?.cancel()
        let search = jobSearch
        jobsObservation = watch(reader, { try JobListItem.open(matching: search, $0) }) { $0.jobs = $1 }
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
}
