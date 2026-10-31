import Foundation
import GRDB

/// Measures a model against your own yes / maybe / no labels. It never touches saved scores, so
/// you can try another model freely.
public struct ScoreCheck: Sendable {
    /// Enough labels for the result to mean something.
    public static let suggestedLabels = 30

    public struct Result: Codable, Equatable, Sendable, Identifiable {
        public var model: String
        public var labeled: Int
        /// How often a job you like more scored higher than one you like less, 0 to 1.
        public var agreement: Double
        public var yesAverage: Double?
        public var maybeAverage: Double?
        public var noAverage: Double?
        public var usage: TokenUsage
        public var seconds: Double
        public var ranAt: Date

        public var id: String { model }
    }

    private let database: AppDatabase
    private let client: any ModelClient

    public init(database: AppDatabase, client: any ModelClient) {
        self.database = database
        self.client = client
    }

    public func run() async throws -> Result {
        let (profile, labeled) = try await database.reader.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT job.*, jobLabel.label AS labelValue FROM job
                JOIN jobLabel ON jobLabel.jobId = job.id
                """)
            return (try Profile.current(db), try rows.map { (try Job(row: $0), $0["labelValue"] as JobLabelValue) })
        }
        guard profile.isScoreable else { throw ModelError.emptyProfile }

        let client = client
        let started = Date.now
        var pairs: [(JobLabelValue, Int)] = []
        var usage = TokenUsage()
        var failure: (any Error)?
        await forEachConcurrently(labeled, width: client.parallelism) { job, label in
            do {
                let reply = try await client.completeWithRetries(ScoringPrompt.request(job: job, profile: profile))
                let assessment = try Assessment.parse(reply.json)
                let score = Rubric.score(assessment.criteria, dealbreakerHit: assessment.dealbreakerHit,
                                         countMustHaves: !profile.mustHaves.isEmpty)
                return Swift.Result<(JobLabelValue, Int, TokenUsage), any Error>.success((label, score, reply.usage))
            } catch {
                return .failure(error)
            }
        } handle: { result in
            switch result {
            case .success(let (label, score, used)):
                pairs.append((label, score))
                usage = usage + used
                return true
            case .failure(let error):
                failure = failure ?? error
                return false
            }
        }
        if let failure { throw failure }

        var result = Self.evaluate(pairs)
        result.model = client.name
        result.usage = usage
        result.seconds = Date.now.timeIntervalSince(started)
        let saved = result
        try await database.writer.write { try Settings.addScoreCheck(saved, $0) }
        return saved
    }

    static func evaluate(_ pairs: [(label: JobLabelValue, score: Int)]) -> Result {
        func rank(_ label: JobLabelValue) -> Int {
            switch label {
            case .yes: 2
            case .maybe: 1
            case .no: 0
            }
        }
        func average(_ label: JobLabelValue) -> Double? {
            let scores = pairs.filter { $0.label == label }.map { Double($0.score) }
            return scores.isEmpty ? nil : scores.reduce(0, +) / Double(scores.count)
        }

        var compared = 0.0
        var right = 0.0
        for (index, first) in pairs.enumerated() {
            for second in pairs[(index + 1)...] where rank(first.label) != rank(second.label) {
                compared += 1
                let liked = rank(first.label) > rank(second.label) ? first : second
                let other = rank(first.label) > rank(second.label) ? second : first
                if liked.score > other.score { right += 1 } else if liked.score == other.score { right += 0.5 }
            }
        }
        return Result(model: "", labeled: pairs.count, agreement: compared == 0 ? 0 : right / compared,
                      yesAverage: average(.yes), maybeAverage: average(.maybe), noAverage: average(.no),
                      usage: TokenUsage(), seconds: 0, ranAt: .now)
    }
}
