import Foundation
import GRDB

/// The app's one SQLite database. Everything stays on this Mac.
///
/// The app opens it at `~/Library/Application Support/Shortlist/shortlist.sqlite`; tests use
/// `AppDatabase.inMemory()`. All schema changes go through `migrator`: never edit a migration
/// that has shipped, add a new one.
public struct AppDatabase: Sendable {
    public let writer: any DatabaseWriter

    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    public var reader: any DatabaseReader { writer }

    /// The on-disk database the app uses, created on first launch.
    public static func onDisk(at url: URL? = nil) throws -> AppDatabase {
        let fileURL = try url ?? defaultURL()
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try AppDatabase(DatabasePool(path: fileURL.path, configuration: configuration))
    }

    /// A throwaway database for tests and previews.
    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue(configuration: configuration))
    }

    public static func defaultURL() throws -> URL {
        try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "Shortlist", directoryHint: .isDirectory)
            .appending(path: "shortlist.sqlite")
    }

    private static var configuration: Configuration {
        var config = Configuration()
        config.foreignKeysEnabled = true
        return config
    }
}

// MARK: - Schema

extension AppDatabase {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        #if DEBUG
        // A changed migration rebuilds the dev database instead of failing silently.
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

        migrator.registerMigration("v1") { db in
            // Your master profile. Exactly one row (id 1). `version` goes up on every edit, so
            // scores made against an older profile can be found and redone.
            try db.create(table: "profile") { t in
                t.primaryKey("id", .integer).check { $0 == 1 }
                t.column("version", .integer).notNull().defaults(to: 1)
                t.column("headline", .text).notNull().defaults(to: "")
                t.column("targetRoles", .jsonText).notNull().defaults(to: "[]")
                t.column("seniority", .text).notNull().defaults(to: "")
                t.column("locations", .jsonText).notNull().defaults(to: "[]")
                t.column("remotePreference", .text).notNull().defaults(to: RemotePreference.any.rawValue)
                t.column("minSalary", .text).notNull().defaults(to: "")
                t.column("mustHaves", .jsonText).notNull().defaults(to: "[]")
                t.column("dealbreakers", .jsonText).notNull().defaults(to: "[]")
                t.column("masterResume", .jsonText).notNull().defaults(to: "{}")
                t.column("updatedAt", .datetime).notNull()
            }

            try db.create(table: "company") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("normalizedName", .text).notNull().unique()
                t.column("atsKind", .text)
                t.column("atsBoardID", .text)
                t.column("isWatched", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
            }

            // Hand-made fixes for names the normalizer can't join on its own,
            // e.g. "facebook" → Meta. `alias` is already normalized.
            try db.create(table: "companyAlias") { t in
                t.primaryKey("alias", .text)
                t.belongsTo("company", onDelete: .cascade).notNull()
            }

            try db.create(table: "source") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("kind", .text).notNull()
                t.column("name", .text).notNull()
                t.column("url", .text)
                t.column("boardID", .text)
                t.belongsTo("company", onDelete: .setNull)
                t.column("isEnabled", .boolean).notNull().defaults(to: true)
                t.column("lastFetchedAt", .datetime)
                t.column("lastError", .text)
            }

            try db.create(table: "job") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("source", onDelete: .setNull)
                t.column("externalID", .text)
                // Company + title + location, normalized: the same post from two feeds is one job.
                t.column("dedupeKey", .text).notNull().unique()
                t.belongsTo("company", onDelete: .setNull)
                t.column("companyName", .text).notNull()
                t.column("title", .text).notNull()
                t.column("location", .text).notNull().defaults(to: "")
                t.column("remotePolicy", .text).notNull().defaults(to: RemotePolicy.unknown.rawValue)
                t.column("url", .text).notNull()
                t.column("applyURL", .text)
                t.column("descriptionText", .text).notNull().defaults(to: "")
                t.column("salaryText", .text)
                t.column("postedAt", .datetime)
                t.column("firstSeenAt", .datetime).notNull()
                t.column("status", .text).notNull().indexed().defaults(to: JobStatus.new.rawValue)
                t.column("statusChangedAt", .datetime).notNull()
                t.uniqueKey(["sourceId", "externalID"])
            }

            // Keyword search over jobs, kept in step with the job table by triggers.
            try db.create(virtualTable: "jobFTS", using: FTS5()) { t in
                t.synchronize(withTable: "job")
                t.tokenizer = .unicode61()
                t.column("title")
                t.column("companyName")
                t.column("descriptionText")
            }

            try db.create(table: "jobScore") { t in
                t.primaryKey { t.belongsTo("job", onDelete: .cascade) }
                t.column("score", .integer).notNull().check { $0 >= 0 && $0 <= 100 }
                t.column("rationale", .text).notNull()
                t.column("strengths", .jsonText).notNull().defaults(to: "[]")
                t.column("gaps", .jsonText).notNull().defaults(to: "[]")
                t.column("dealbreakerHit", .boolean).notNull().defaults(to: false)
                t.column("model", .text).notNull()
                t.column("profileVersion", .integer).notNull()
                t.column("scoredAt", .datetime).notNull()
            }

            try db.create(table: "connection") { t in
                t.autoIncrementedPrimaryKey("id")
                // The LinkedIn profile URL when there is one, otherwise name + company.
                // Re-importing a newer export updates people instead of adding them twice.
                t.column("identityKey", .text).notNull().unique()
                t.column("firstName", .text).notNull()
                t.column("lastName", .text).notNull()
                t.column("company", .text).notNull()
                t.column("normalizedCompany", .text).notNull().indexed()
                t.column("position", .text).notNull()
                t.column("profileURL", .text)
                t.column("connectedOn", .date)
                t.column("importedAt", .datetime).notNull()
            }

            try db.create(table: "jobReferral") { t in
                t.primaryKey {
                    t.belongsTo("job", onDelete: .cascade)
                    t.belongsTo("connection", onDelete: .cascade)
                }
                t.column("confidence", .text).notNull()
            }

            // Each day's top picks, frozen when the day starts so the list doesn't reshuffle
            // while you work through it. `day` is "yyyy-MM-dd" in your time zone.
            try db.create(table: "dailyQueue") { t in
                t.primaryKey {
                    t.column("day", .text)
                    t.belongsTo("job", onDelete: .cascade)
                }
                t.column("rank", .integer).notNull()
            }

            try db.create(table: "application") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("job", onDelete: .cascade).notNull().unique()
                t.column("resume", .jsonText)
                t.column("resumePDFPath", .text)
                t.column("blurbs", .jsonText).notNull().defaults(to: "[]")
                t.column("model", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("submittedAt", .datetime)
            }

            try db.create(table: "dailyLog") { t in
                t.primaryKey("day", .text)
                t.column("target", .integer).notNull().defaults(to: 10)
                t.column("submittedCount", .integer).notNull().defaults(to: 0)
            }
        }

        migrator.registerMigration("v2") { db in
            // Small app-wide settings, stored as JSON by key (see `Settings`).
            try db.create(table: "setting") { t in
                t.primaryKey("key", .text)
                t.column("value", .jsonText).notNull()
            }
            try db.alter(table: "job") { t in
                // When the job was last in its feed, and when a full company board stopped
                // listing it. Closed jobs never reach the daily queue.
                t.add(column: "lastSeenAt", .datetime)
                t.add(column: "closedAt", .datetime)
            }
        }

        migrator.registerMigration("v3") { db in
            try db.alter(table: "jobScore") { t in
                // The rubric answers the score was worked out from.
                t.add(column: "criteria", .jsonText)
            }
            // Your own yes / maybe / no on a job. The model check measures scores against these.
            try db.create(table: "jobLabel") { t in
                t.primaryKey { t.belongsTo("job", onDelete: .cascade) }
                t.column("label", .text).notNull()
                t.column("labeledAt", .datetime).notNull()
            }
        }

        migrator.registerMigration("v4") { db in
            // Which network companies have been checked for a job board, so a stopped scan can
            // pick up where it left off and a finished one doesn't repeat itself.
            try db.create(table: "boardScan") { t in
                t.primaryKey("normalizedCompany", .text)
                t.column("scannedAt", .datetime).notNull()
            }
        }

        migrator.registerMigration("v5") { db in
            try db.alter(table: "profile") { t in
                // Where you live, which decides whether a remote job is open to you.
                t.add(column: "basedIn", .text).notNull().defaults(to: "")
            }
            try db.execute(sql: "UPDATE profile SET basedIn = 'India', version = version + 1")
            try db.alter(table: "dailyQueue") { t in
                // The profile a pick was chosen for. A pick from an older profile gives way once
                // its job has been scored again.
                t.add(column: "profileVersion", .integer).notNull().defaults(to: 0)
            }
        }

        migrator.registerMigration("v6") { db in
            // Search for jobs open in India rather than fetching the US ones and rejecting them.
            try db.execute(sql: """
                UPDATE source SET boardID = boardID || '|India', name = name || ' in India', lastFetchedAt = NULL
                WHERE kind = 'himalayas' AND boardID NOT LIKE '%|%'
                """)
            // Those searches should run the next time the app opens, not tomorrow.
            try db.execute(sql: "DELETE FROM setting WHERE key = 'lastMorningRun'")
        }

        return migrator
    }
}
