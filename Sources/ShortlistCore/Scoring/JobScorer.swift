import Foundation
import GRDB

/// Scores open jobs against your profile. Scores from an older profile are redone.
public struct JobScorer: Sendable {
    public struct Report: Equatable, Sendable {
        public var scored = 0
        public var failed = 0
        public var usage = TokenUsage()
        /// Why the run ended early, if it did.
        public var stoppedBy: String?
        /// The first problem with a single job, when the run carried on past it.
        public var firstFailure: String?
    }

    /// A cap on one run, so a first run or a profile edit can't quietly spend much.
    public static let defaultLimit = 300

    private let database: AppDatabase
    private let client: any ModelClient
    private let now: @Sendable () -> Date

    public init(database: AppDatabase, client: any ModelClient, now: @escaping @Sendable () -> Date = { .now }) {
        self.database = database
        self.client = client
        self.now = now
    }

    /// Jobs still needing a score, newest first.
    public static func pending(limit: Int = .max, _ db: Database) throws -> [Job] {
        try Job.fetchAll(db, sql: pendingSQL("job.*") + " ORDER BY COALESCE(job.postedAt, job.firstSeenAt) DESC LIMIT ?",
                         arguments: [try Profile.current(db).version, limit])
    }

    public static func pendingCount(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: pendingSQL("COUNT(*)"), arguments: [try Profile.current(db).version]) ?? 0
    }

    private static func pendingSQL(_ columns: String) -> String {
        """
        SELECT \(columns) FROM job
        LEFT JOIN jobScore ON jobScore.jobId = job.id
        WHERE job.closedAt IS NULL AND job.status IN ('new', 'scored', 'queued')
          AND (jobScore.jobId IS NULL OR jobScore.profileVersion != ?)
        """
    }

    /// Scores up to `limit` jobs, saving each as it finishes, so stopping loses nothing.
    public func run(limit: Int = JobScorer.defaultLimit,
                    progress: @escaping @Sendable (_ done: Int, _ total: Int) -> Void = { _, _ in }) async throws -> Report {
        let (profile, jobs) = try await database.reader.read { db in
            (try Profile.current(db), try Self.pending(limit: limit, db))
        }
        guard profile.isScoreable else { throw ModelError.emptyProfile }

        var report = Report()
        var done = 0
        await forEachConcurrently(jobs, width: client.parallelism) { job in
            await score(job, profile: profile)
        } handle: { result in
            done += 1
            progress(done, jobs.count)
            switch result {
            case .success(let usage):
                report.scored += 1
                report.usage = report.usage + usage
                return true
            case .failure(let error):
                if Task.isCancelled || error is CancellationError {
                    report.stoppedBy = report.stoppedBy ?? "Stopped."
                    return false
                }
                report.failed += 1
                if (error as? ModelError)?.stopsTheRun == true {
                    report.stoppedBy = report.stoppedBy ?? error.localizedDescription
                    return false
                }
                report.firstFailure = report.firstFailure ?? error.localizedDescription
                return true
            }
        }
        return report
    }

    private func score(_ job: Job, profile: Profile) async -> Result<TokenUsage, any Error> {
        do {
            let reply = try await client.completeWithRetries(ScoringPrompt.request(job: job, profile: profile))
            let assessment = try Assessment.parse(reply.json)
            let saved = JobScore(assessment, jobId: job.id ?? 0, profile: profile, model: client.name, scoredAt: now())
            try await database.writer.write { db in
                try saved.save(db)
                try db.execute(sql: "UPDATE job SET status = 'scored', statusChangedAt = ? WHERE id = ? AND status = 'new'",
                               arguments: [saved.scoredAt, saved.jobId])
            }
            return .success(reply.usage)
        } catch {
            return .failure(error)
        }
    }
}

extension Profile {
    /// There has to be something to score against.
    public var isScoreable: Bool {
        !targetRoles.isEmpty || !masterResume.summary.isEmpty || !masterResume.experience.isEmpty
    }
}

extension JobScore {
    init(_ assessment: Assessment, jobId: Int64, profile: Profile, model: String, scoredAt: Date) {
        self.init(
            jobId: jobId,
            score: Rubric.score(assessment.criteria, dealbreakerHit: assessment.dealbreakerHit,
                                countMustHaves: !profile.mustHaves.isEmpty),
            rationale: assessment.rationale,
            strengths: Array(assessment.strengths.prefix(3)),
            gaps: Array(assessment.gaps.prefix(3)),
            dealbreakerHit: assessment.dealbreakerHit,
            model: model, profileVersion: profile.version, scoredAt: scoredAt,
            criteria: assessment.criteria)
    }
}

/// Runs `body` over `items`, `width` at a time. `handle` sees results as they arrive; returning
/// false starts nothing more, and work already running is cancelled.
func forEachConcurrently<Item: Sendable, Output: Sendable>(
    _ items: [Item], width: Int,
    body: @escaping @Sendable (Item) async -> Output,
    handle: (Output) -> Bool
) async {
    await withTaskGroup(of: Output.self) { group in
        var next = 0
        func startNext() {
            guard next < items.count, !Task.isCancelled else { return }
            let item = items[next]
            next += 1
            group.addTask { await body(item) }
        }
        for _ in 0..<max(width, 1) { startNext() }
        for await output in group {
            guard handle(output) else {
                group.cancelAll()
                continue
            }
            startNext()
        }
    }
}
