import Foundation
import GRDB

/// Whether you can apply to a job at all, from where you live. This is plain rules, not the model:
/// a model reads "work from anywhere" in a Canada-only posting and calls it open. A job passes only
/// if its location names where you live, a place you listed, or a region that includes you, or if
/// it names no place and its text doesn't limit it to one.
public enum Eligibility {
    public enum Verdict: Equatable, Sendable {
        case open
        case closed(reason: String)
    }

    /// The `model` on a score written by this check rather than by a model.
    public static let checkName = "location check"
    public static let budgetCheckName = "budget check"

    // MARK: Judging one job

    public static func verdict(for job: Job, profile: Profile) -> Verdict {
        let home = profile.basedIn.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !home.isEmpty else { return .open }

        let words = normalized(job.location).split(separator: " ").map(String.init)
        let namesAPlace = words.contains { !placelessWords.contains($0) }
        if namesAPlace {
            if accepted(profile: profile, home: home).contains(where: { contains($0, in: job.location) }) { return .open }
            return .closed(reason: "Not open to people in \(home). It's limited to \(job.location).")
        }
        if let place = limitedPlace(in: job.descriptionText) ?? limitedPlace(inTitle: job.title) {
            return .closed(reason: "Not open to people in \(home). The posting limits it to \(place).")
        }
        return .open
    }

    /// Why a post you'd answer yourself pays too little to bother with, if it does. Only for those
    /// posts: a company's contract job can mention small sums that aren't the pay.
    public static func budgetLimit(for job: Job, minimum: Int) -> String? {
        guard job.isDirectPost, job.jobType.isFreelanceWork,
              let offered = Budget.flatDollars(in: [job.title, job.salaryText ?? "", job.descriptionText].joined(separator: "\n")),
              offered < Double(minimum) else { return nil }
        return "It pays about $\(Int(offered)), under your $\(minimum) minimum."
    }

    /// Words that say a job can be done remotely without saying where.
    private static let placelessWords: Set<String> = [
        "remote", "remotely", "fully", "anywhere", "worldwide", "global", "globally", "international", "world",
        "the", "in", "from", "work", "home", "wfh", "any", "location", "locations", "distributed", "first",
    ]

    private static let indianPlaces = [
        "india", "bharat", "bengaluru", "bangalore", "mumbai", "delhi", "new delhi", "ncr", "gurgaon", "gurugram",
        "noida", "hyderabad", "pune", "chennai", "kolkata", "ahmedabad", "jaipur", "kochi", "indore", "chandigarh",
        "coimbatore", "thiruvananthapuram", "trivandrum", "goa", "nagpur", "mysuru", "mysore", "vadodara", "surat",
        "lucknow", "bhubaneswar", "visakhapatnam",
        "apac", "asia pacific", "south asia", "asia",
    ]

    /// Regions with "Asia" in the name that leave India out.
    private static let otherAsias = ["southeast asia", "south east asia", "east asia", "central asia", "west asia"]

    private static func accepted(profile: Profile, home: String) -> [String] {
        let listed = profile.locations.map { place in
            normalized(place).split(separator: " ")
                .filter { !["on", "site", "onsite", "hybrid", "remote", "or", "and", "in"].contains($0) }
                .joined(separator: " ")
        }
        var places = [normalized(home)] + listed.filter { !$0.isEmpty }
        if places.contains("india") { places += indianPlaces }
        return places
    }

    /// Whole words only, so India doesn't match Indiana.
    private static func contains(_ place: String, in text: String) -> Bool {
        var haystack = " \(normalized(text)) "
        for region in otherAsias { haystack = haystack.replacingOccurrences(of: " \(region) ", with: " ") }
        return haystack.contains(" \(place) ")
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : " " }
            .joined()
            .split(separator: " ")
            .joined(separator: " ")
    }

    // MARK: Limits stated in the posting

    private static let place = #"(?:U\.?S\.?A?\.?|(?i:united states|america|canada)|UK|(?i:united kingdom|europe)|EU|EMEA|LATAM|(?i:latin america|australia|germany|brazil))"#

    /// Only the ways of saying where the candidate must be. A company "based in the US" or
    /// selling to "customers in Europe" says nothing about who it hires.
    private static let limitPatterns: [NSRegularExpression] = [
        #"\b(\#(place))[ -]only\b"#,
        #"(?i:must|need to|required to|have to|should)(?: currently)?(?: be)?(?: currently)? (?i:based|located|living|residing|reside|live|work)(?: and \w+)? (?i:in|from|within) (?:the )?(\#(place))\b"#,
        #"(?i:authori[sz]ed|eligible|permitted|legally able) to work (?i:in|for) (?:the )?(\#(place))\b"#,
        #"(?i:right to work) in (?:the )?(\#(place))\b"#,
        #"(?i:remote)[^.\n]{0,30} (?i:within|in|across) (?:the )?(\#(place))\b"#,
        #"(?i:only|exclusively) (?i:hiring|accepting|considering)[^.\n]{0,40} (?i:in|from) (?:the )?(\#(place))\b"#,
        #"\b(\#(place))[ -](?i:based) (?i:candidates|applicants|employees|team members|only)\b"#,
        #"(?i:remote) ?[-–—] ?(\#(place))(?![a-z])"#,
        #"\b((?:PST|PDT|EST|EDT|CST|CDT|US|U\.S\.) (?i:time ?zones?|hours|business hours|working hours))\b"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    private static let titleLimit = try? NSRegularExpression(pattern: #"\b(\#(place))[ -](?i:based|only|residents?|citizens?)\b"#)

    /// Unlike a company's description, a title's "US-based" is about who they want.
    static func limitedPlace(inTitle title: String) -> String? {
        titleLimit?.firstMatch(in: title, range: NSRange(title.startIndex..., in: title))
            .flatMap { Range($0.range(at: 1), in: title) }
            .map { String(title[$0]) }
    }

    /// The place a posting's text restricts it to, if it does.
    static func limitedPlace(in description: String) -> String? {
        let range = NSRange(description.startIndex..., in: description)
        for pattern in limitPatterns {
            if let match = pattern.firstMatch(in: description, range: range),
               let found = Range(match.range(at: 1), in: description) {
                return String(description[found]).trimmingCharacters(in: CharacterSet(charactersIn: "."))
            }
        }
        return nil
    }

    // MARK: Applying it

    /// Scores every job you can't apply to or that pays too little as 0, which keeps it off your
    /// lists and saves paying a model to read it, and takes it off today's list if it was there.
    /// Your other picks stay put. A job that has since become open, because a feed, your profile or
    /// your minimum changed, goes back to be scored.
    @discardableResult
    public static func apply(now: Date = .now, _ db: Database) throws -> Int {
        let profile = try Profile.current(db)
        let minimum = try Settings.minimumBudget(db)
        let jobs = try Job
            .filter(Column("closedAt") == nil)
            .filter([JobStatus.new, .scored, .queued].map(\.rawValue).contains(Column("status")))
            .fetchAll(db)
        let checked = Dictionary(
            try JobScore.filter([checkName, budgetCheckName].contains(Column("model"))).fetchAll(db).map { ($0.jobId, $0) },
            uniquingKeysWith: { first, _ in first })

        var closed = 0
        for job in jobs {
            guard let id = job.id else { continue }
            var check = checkName
            var reason: String?
            if case .closed(let why) = verdict(for: job, profile: profile) {
                reason = why
            } else if let why = budgetLimit(for: job, minimum: minimum) {
                (check, reason) = (budgetCheckName, why)
            }
            guard let reason else {
                if checked[id] != nil { try JobScore.deleteOne(db, key: id) }
                continue
            }
            closed += 1
            if let saved = checked[id], saved.rationale == reason, saved.profileVersion == profile.version { continue }
            try JobScore(jobId: id, score: 0, rationale: reason, model: check, profileVersion: profile.version,
                         scoredAt: now).save(db)
            try db.execute(sql: "DELETE FROM dailyQueue WHERE day = ? AND jobId = ?", arguments: [Day.today, id])
            try db.execute(sql: "UPDATE job SET status = 'scored' WHERE id = ?", arguments: [id])
        }
        return closed
    }
}
