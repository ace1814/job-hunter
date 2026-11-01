import Foundation
import GRDB

/// Where a job is in your pipeline. Stored as its raw value.
public enum JobStatus: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    case new            // imported, not scored yet
    case scored         // has a match score
    case queued         // in a day's top picks
    case applying       // tailored materials being made or reviewed
    case applied
    case interviewing
    case rejected
    case offer
    case dismissed      // you passed on it, or it was filtered out
}

public enum RemotePolicy: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    case remote, hybrid, onsite, unknown
}

public enum RemotePreference: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    case remoteOnly, hybridOrRemote, any
}

/// The kinds of feeds Step 2 will read. Open APIs and RSS only, no scraping.
public enum SourceKind: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    case greenhouse, lever, ashby, smartRecruiters
    case remotive, remoteOK, himalayas, hackerNewsHiring, jobicy
    case rss, reddit
}

/// What kind of work a job is. Contract and freelance work live in the Freelance section, apart
/// from Today, All Jobs and your daily target.
public enum JobType: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    case fullTime, contract, freelance

    public var isFreelanceWork: Bool { self != .fullTime }

    public var label: String {
        switch self {
        case .fullTime: "Full-time"
        case .contract: "Contract"
        case .freelance: "Freelance"
        }
    }
}

/// Would you apply to this job? Your answer, not the model's.
public enum JobLabelValue: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    case yes, maybe, no
}

/// How sure a referral flag is.
public enum ReferralConfidence: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible, Comparable {
    /// The normalized names are the same: "Razorpay" and "Razorpay Software Pvt Ltd".
    case exact
    /// Joined through your alias table: "Facebook" → Meta.
    case alias
    /// One name extends the other: "Flipkart" and "Flipkart Internet". Worth a look, not a promise.
    case possible

    private var rank: Int {
        switch self {
        case .exact: 0
        case .alias: 1
        case .possible: 2
        }
    }

    /// Stronger confidence sorts first.
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}
