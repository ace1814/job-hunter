import Foundation
import GRDB

/// App-wide settings, each stored as JSON under a key in the `setting` table.
public enum Settings {
    /// Only jobs whose title matches one of these are kept. It's the cheap first cut, before the
    /// local model reads anything.
    public static let defaultTitleKeywords = [
        "product design", "ux", "ui", "design lead", "design manager", "head of design",
        "product manager", "product lead", "head of product", "product owner",
    ]

    public static func titleKeywords(_ db: Database) throws -> [String] {
        try value(for: "titleKeywords", db) ?? defaultTitleKeywords
    }

    public static func setTitleKeywords(_ keywords: [String], _ db: Database) throws {
        let cleaned = keywords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        try setValue(cleaned, for: "titleKeywords", db)
    }

    // MARK: Storage

    static func value<T: Decodable>(for key: String, _ db: Database) throws -> T? {
        guard let json = try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key = ?", arguments: [key]) else {
            return nil
        }
        return try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    static func setValue<T: Encodable>(_ value: T, for key: String, _ db: Database) throws {
        let json = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        try db.execute(
            sql: "INSERT INTO setting (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            arguments: [key, json])
    }
}
