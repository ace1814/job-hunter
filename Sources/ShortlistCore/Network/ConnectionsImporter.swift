import Foundation
import GRDB

/// Reads your connections CSV into the database, then re-checks every job for referrals.
///
/// Built for LinkedIn's export (Settings → Data privacy → Get a copy of your data →
/// Connections), which starts with a few lines of notes before the real header. Any CSV with
/// First Name, Last Name and Company columns also works; Position, URL and Connected On are
/// used when present. Importing a newer export updates people in place. Nobody is deleted.
public enum ConnectionsImporter {
    public struct Row: Equatable, Sendable {
        public var firstName: String
        public var lastName: String
        public var company: String
        public var position: String
        public var profileURL: String?
        public var connectedOn: Date?
    }

    public struct Summary: Equatable, Sendable {
        public var added = 0
        public var updated = 0
        public var unchanged = 0
        /// Rows with no name at all.
        public var skipped = 0
        /// People with no company listed, or one like "Self-employed": kept, but never matched.
        public var withoutCompany = 0
        /// Jobs flagged with at least one connection after the import.
        public var jobsWithReferrals = 0

        public var imported: Int { added + updated + unchanged }
    }

    public enum ImportError: LocalizedError, Equatable {
        case unreadable
        case headerNotFound
        case missingColumns([String])

        public var errorDescription: String? {
            switch self {
            case .unreadable:
                "The file couldn't be read as text. Is it a CSV?"
            case .headerNotFound:
                "No header row with First Name and Last Name was found."
            case .missingColumns(let columns):
                "The CSV is missing these columns: \(columns.joined(separator: ", "))."
            }
        }
    }

    // MARK: Import

    public static func importFile(at url: URL, into database: AppDatabase) throws -> Summary {
        let data = try Data(contentsOf: url)
        // UTF-8 from LinkedIn; Windows-1252 if the file went through Excel.
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) else {
            throw ImportError.unreadable
        }
        return try importText(text, into: database)
    }

    public static func importText(_ text: String, into database: AppDatabase, now: Date = .now) throws -> Summary {
        let (rows, skipped) = try parse(text)
        return try database.writer.write { db in
            var summary = Summary(skipped: skipped)
            var existing: [String: Connection] = [:]
            for connection in try Connection.fetchAll(db) {
                existing[connection.identityKey] = connection
            }

            for row in rows {
                var incoming = Connection(
                    firstName: row.firstName, lastName: row.lastName, company: row.company,
                    position: row.position, profileURL: row.profileURL, connectedOn: row.connectedOn,
                    importedAt: now)
                if incoming.normalizedCompany.isEmpty { summary.withoutCompany += 1 }

                if let saved = existing[incoming.identityKey] {
                    incoming.id = saved.id
                    if incoming.sameDetails(as: saved) {
                        summary.unchanged += 1
                    } else {
                        try incoming.update(db)
                        summary.updated += 1
                    }
                } else {
                    try incoming.insert(db)
                    summary.added += 1
                }
                existing[incoming.identityKey] = incoming
            }

            try ReferralMatcher.refresh(db)
            summary.jobsWithReferrals = try JobReferral
                .select(Column("jobId"), as: Int64.self).distinct().fetchCount(db)
            return summary
        }
    }

    // MARK: Parse

    /// The usable rows, deduplicated by person (a later row wins), and how many rows had no name.
    public static func parse(_ text: String) throws -> (rows: [Row], skipped: Int) {
        let table = CSVParser.rows(in: text)
        let key = { (cell: String) in
            cell.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        guard let headerIndex = table.firstIndex(where: { row in
            let cells = Set(row.map(key))
            return cells.contains("first name") && cells.contains("last name")
        }) else {
            throw ImportError.headerNotFound
        }

        let header = table[headerIndex].map(key)
        func column(_ names: String...) -> Int? {
            names.lazy.compactMap { header.firstIndex(of: $0) }.first
        }
        guard let first = column("first name"), let last = column("last name") else {
            throw ImportError.headerNotFound
        }
        guard let company = column("company", "company name", "organization") else {
            throw ImportError.missingColumns(["Company"])
        }
        let position = column("position", "title", "job title")
        let url = column("url", "profile url", "linkedin url")
        let connectedOn = column("connected on")

        var order: [String] = []
        var byPerson: [String: Row] = [:]
        var skipped = 0
        for cells in table[(headerIndex + 1)...] {
            func value(_ index: Int?) -> String {
                guard let index, index < cells.count else { return "" }
                return cells[index].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let row = Row(
                firstName: value(first), lastName: value(last), company: value(company),
                position: value(position), profileURL: value(url).isEmpty ? nil : value(url),
                connectedOn: parseDate(value(connectedOn)))
            guard !(row.firstName.isEmpty && row.lastName.isEmpty) else {
                skipped += 1
                continue
            }
            let identity = Connection.identityKey(
                firstName: row.firstName, lastName: row.lastName, company: row.company, profileURL: row.profileURL)
            if byPerson.updateValue(row, forKey: identity) == nil { order.append(identity) }
        }
        return (order.compactMap { byPerson[$0] }, skipped)
    }

    /// LinkedIn writes "15 Mar 2023"; ISO dates are accepted too.
    static func parseDate(_ text: String) -> Date? {
        guard !text.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        for format in ["dd MMM yyyy", "d MMM yyyy", "yyyy-MM-dd", "MM/dd/yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}

private extension Connection {
    func sameDetails(as other: Connection) -> Bool {
        firstName == other.firstName && lastName == other.lastName && company == other.company
            && position == other.position && profileURL == other.profileURL && connectedOn == other.connectedOn
    }
}
