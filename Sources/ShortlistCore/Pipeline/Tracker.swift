import Foundation
import GRDB

/// Jobs you follow yourself, from anywhere. A job you add is an ordinary job, so tailoring, form
/// filling and contacts all work on it. It stays out of scoring and the daily picks, because you've
/// already chosen it.
public enum Tracker {
    /// A job you're adding, from the app or the extension.
    public struct NewJob: Codable, Equatable, Sendable {
        public var url: String
        public var title: String
        public var company: String
        public var location = ""
        public var remotePolicy = RemotePolicy.unknown
        public var description = ""
        public var salary: String?
        public var postedAt: Date?
        public var typeLabel: String?
        public var note = ""
        /// When you applied, if you already have.
        public var appliedAt: Date?

        public init(url: String, title: String, company: String) {
            self.url = url
            self.title = title
            self.company = company
        }

        public init(page: JobPage) {
            self.init(url: page.url, title: page.title, company: page.company)
            location = page.location
            remotePolicy = page.remotePolicy
            description = page.description
            salary = page.salary
            postedAt = page.postedAt
            typeLabel = page.typeLabel
        }

        public var isComplete: Bool { !title.trimmed.isEmpty && !company.trimmed.isEmpty && !url.trimmed.isEmpty }
    }

    public struct Added: Codable, Equatable, Sendable {
        public var jobId: Int64
        /// It was already in Shortlist, so nothing new was made.
        public var wasKnown: Bool
    }

    /// Adds a job, or moves it to the Tracker if a feed already found it.
    @discardableResult
    public static func add(_ new: NewJob, at date: Date = .now, _ db: Database) throws -> Added {
        let (title, company, location) = (new.title.trimmed, new.company.trimmed, new.location.trimmed)
        let key = Job.dedupeKey(company: company, title: title, location: location)
        let known = try PostingMatcher.job(for: new.url, db) ?? Job.filter(Column("dedupeKey") == key).fetchOne(db)

        let id: Int64
        if let known, let knownId = known.id {
            id = knownId
            try Pipeline.save(id, at: date, db)
        } else {
            var job = Job(
                companyName: company, title: title, location: location, remotePolicy: new.remotePolicy, url: new.url.trimmed,
                descriptionText: new.description, salaryText: new.salary, postedAt: new.postedAt, firstSeenAt: date,
                status: .saved, jobType: JobType(label: new.typeLabel, title: title))
            job.savedAt = date
            var companies = CompanyResolver()
            job.companyId = try companies.id(for: company, db)
            try job.insert(db)
            id = job.id!
            try ReferralMatcher.refresh(db, jobIds: [id])
        }

        if !new.note.trimmed.isEmpty { try addNote(new.note, to: id, at: date, db) }
        if let applied = new.appliedAt { try Pipeline.markApplied(id, day: Day.key(for: applied), at: applied, db) }
        return Added(jobId: id, wasKnown: known != nil)
    }

    public static func addNote(_ text: String, to jobId: Int64, at date: Date = .now, _ db: Database) throws {
        guard !text.trimmed.isEmpty else { return }
        var note = JobNote(jobId: jobId, text: text.trimmed, createdAt: date)
        try note.insert(db)
    }

    public static func addContact(name: String, email: String, to jobId: Int64, at date: Date = .now, _ db: Database) throws {
        guard !name.trimmed.isEmpty || !email.trimmed.isEmpty else { return }
        var contact = JobContact(jobId: jobId, name: name.trimmed, email: email.trimmed, createdAt: date)
        try contact.insert(db)
    }
}
