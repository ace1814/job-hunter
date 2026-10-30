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

    private(set) var network = NetworkSnapshot()
    private(set) var isImporting = false
    /// The result of the last import, shown until the next one.
    private(set) var importMessage: String?

    @ObservationIgnored private var observation: Task<Void, Never>?

    init() {
        do {
            database = try AppDatabase.onDisk()
        } catch {
            database = nil
            databaseError = error.localizedDescription
        }
        observeNetwork()
    }

    private func observeNetwork() {
        guard let reader = database?.reader else { return }
        let values = ValueObservation.tracking { try NetworkSnapshot.fetch($0) }.values(in: reader)
        observation = Task { [weak self] in
            do {
                for try await snapshot in values {
                    self?.network = snapshot
                }
            } catch {
                self?.databaseError = error.localizedDescription
            }
        }
    }

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
}
