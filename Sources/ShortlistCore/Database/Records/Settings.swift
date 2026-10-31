import Foundation
import GRDB

/// App-wide settings, each stored as JSON under a key in the `setting` table.
public enum Settings {
    /// Only jobs whose title matches one of these are kept. It's the cheap first cut, before the
    /// scoring model reads anything.
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

    public static func scoring(_ db: Database) throws -> ScoringSettings {
        try value(for: "scoring", db) ?? ScoringSettings()
    }

    public static func setScoring(_ scoring: ScoringSettings, _ db: Database) throws {
        try setValue(scoring, for: "scoring", db)
    }

    public static func scoreChecks(_ db: Database) throws -> [ScoreCheck.Result] {
        try value(for: "scoreChecks", db) ?? []
    }

    /// Keeps the latest check for each model, so models can be compared side by side.
    public static func addScoreCheck(_ result: ScoreCheck.Result, _ db: Database) throws {
        let others = try scoreChecks(db).filter { $0.model != result.model }
        try setValue(others + [result], for: "scoreChecks", db)
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
