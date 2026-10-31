import Foundation
import GRDB

/// Goes through the companies you know people at and connects the public job boards it can confirm
/// are theirs. It only works through open APIs, a few companies at a time, and remembers where it
/// got to.
public struct NetworkBoardScanner: Sendable {
    public struct Progress: Equatable, Sendable {
        public var checked = 0
        public var total = 0
        public var connected = 0

        public init() {}
    }

    public struct Connected: Equatable, Sendable {
        public var company: String
        public var kind: SourceKind
        public var boardID: String
        public var openJobs: Int
    }

    public struct Report: Equatable, Sendable {
        public var checked = 0
        public var connected: [Connected] = []
    }

    /// Companies get checked again after this long, since boards come and go.
    static let recheckAfter: TimeInterval = 30 * 24 * 3600
    private static let companiesAtOnce = 4

    private let database: AppDatabase
    private let http: any HTTPClient
    private let now: @Sendable () -> Date

    public init(database: AppDatabase, http: any HTTPClient, now: @escaping @Sendable () -> Date = { .now }) {
        self.database = database
        self.http = http
        self.now = now
    }

    /// Companies with no board yet and no recent check, those with the most people first.
    public static func companiesToCheck(at date: Date = .now, _ db: Database) throws -> [NetworkCompany] {
        let watched = Set(try Source.fetchAll(db).filter(\.kind.isCompanyBoard).map { CompanyNormalizer.normalize($0.name) })
        let recent = Set(try String.fetchAll(db, sql: "SELECT normalizedCompany FROM boardScan WHERE scannedAt > ?",
                                             arguments: [date.addingTimeInterval(-recheckAfter)]))
        return try NetworkCompany.top(limit: .max, db).filter {
            !watched.contains($0.normalizedCompany) && !recent.contains($0.normalizedCompany)
        }
    }

    public func run(progress: @escaping @Sendable (Progress) -> Void = { _ in }) async throws -> Report {
        let date = now()
        let companies = try await database.reader.read { try Self.companiesToCheck(at: date, $0) }
        let finder = BoardFinder(http: http)

        var report = Report()
        var state = Progress()
        state.total = companies.count
        progress(state)
        await forEachConcurrently(companies, width: Self.companiesAtOnce) { company -> Connected? in
            let board = await finder.findConfirmed(company: company.name)
            // Stopped partway through: leave this company for next time.
            guard !Task.isCancelled else { return nil }
            return await save(board, for: company, at: date)
        } handle: { (connected: Connected?) in
            state.checked += 1
            if let connected {
                report.connected.append(connected)
                state.connected += 1
            }
            progress(state)
            return !Task.isCancelled
        }
        report.checked = state.checked
        return report
    }

    /// Notes the company as checked and connects its board if it has one.
    private func save(_ board: BoardFinder.Board?, for company: NetworkCompany, at date: Date) async -> Connected? {
        try? await database.writer.write { db -> Connected? in
            try db.execute(sql: """
                INSERT INTO boardScan (normalizedCompany, scannedAt) VALUES (?, ?)
                ON CONFLICT(normalizedCompany) DO UPDATE SET scannedAt = excluded.scannedAt
                """, arguments: [company.normalizedCompany, date])
            guard let board else { return nil }
            try Source.add(Source(kind: board.kind, name: company.name, boardID: board.boardID), db)
            return Connected(company: company.name, kind: board.kind, boardID: board.boardID, openJobs: board.openJobs)
        }
    }
}
