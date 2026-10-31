import Foundation
import GRDB

/// Your master profile: what jobs are scored against and what tailoring starts from.
public struct Profile: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "profile"

    public var id: Int64 = 1
    public var version: Int
    public var headline: String
    public var targetRoles: [String]
    public var seniority: String
    public var locations: [String]
    public var remotePreference: RemotePreference
    public var minSalary: String
    public var mustHaves: [String]
    public var dealbreakers: [String]
    public var masterResume: MasterResume
    public var updatedAt: Date

    public init(
        version: Int = 1, headline: String = "", targetRoles: [String] = [], seniority: String = "",
        locations: [String] = [], remotePreference: RemotePreference = .any, minSalary: String = "",
        mustHaves: [String] = [], dealbreakers: [String] = [], masterResume: MasterResume = MasterResume(),
        updatedAt: Date = .now
    ) {
        self.version = version
        self.headline = headline
        self.targetRoles = targetRoles
        self.seniority = seniority
        self.locations = locations
        self.remotePreference = remotePreference
        self.minSalary = minSalary
        self.mustHaves = mustHaves
        self.dealbreakers = dealbreakers
        self.masterResume = masterResume
        self.updatedAt = updatedAt
    }
}

extension Profile {
    /// The saved profile, or an empty one before you've filled it in.
    public static func current(_ db: Database) throws -> Profile {
        try Profile.fetchOne(db, key: 1) ?? Profile()
    }

    /// Saves an edit and bumps `version`, so scores made against the old profile go stale.
    /// Saving with nothing changed keeps the version: rescoring every job costs money.
    public static func save(_ profile: Profile, _ db: Database) throws {
        var updated = profile
        let saved = try Profile.fetchOne(db, key: 1)
        if let saved {
            updated.version = saved.version
            updated.updatedAt = saved.updatedAt
            if updated == saved { return }
        }
        updated.version = (saved?.version ?? 0) + 1
        updated.updatedAt = .now
        try updated.save(db)
    }
}

/// Your full resume as structured data. Tailoring picks from it and rewords it; it never invents.
public struct MasterResume: Codable, Equatable, Sendable {
    public var name: String = ""
    public var email: String = ""
    public var phone: String = ""
    public var location: String = ""
    public var links: [String] = []
    public var summary: String = ""
    public var experience: [Experience] = []
    public var education: [Education] = []
    public var skills: [String] = []

    public init() {}

    public struct Experience: Codable, Equatable, Sendable {
        public var company: String
        public var title: String
        public var location: String
        public var start: String
        public var end: String?
        public var bullets: [String]

        public init(company: String, title: String, location: String = "", start: String, end: String? = nil, bullets: [String] = []) {
            self.company = company
            self.title = title
            self.location = location
            self.start = start
            self.end = end
            self.bullets = bullets
        }
    }

    public struct Education: Codable, Equatable, Sendable {
        public var school: String
        public var degree: String
        public var year: String

        public init(school: String, degree: String, year: String = "") {
            self.school = school
            self.degree = degree
            self.year = year
        }
    }
}
