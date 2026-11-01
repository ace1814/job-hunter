import Foundation

/// Who to reach at a job's company. People you know come from your connections, ranked by how much
/// they can help with this job. For people you don't know it gives LinkedIn searches, which show
/// who holds the job today and how you're connected. No model names anyone: it would make people up.
public struct JobContacts: Equatable, Sendable {
    /// What kind of job this is, which decides whose team it's on.
    public enum Field: Equatable, Sendable {
        case design, product

        init(jobTitle: String) {
            let title = " \(jobTitle.lowercased()) "
            let isProduct = title.contains("product manager") || title.contains("product owner")
                || title.contains("head of product") || title.contains("product lead")
            self = isProduct ? .product : .design
        }
    }

    public enum Role: Int, Comparable, Sendable {
        case teamLeader, founder, recruiter, teammate, other

        public static func < (a: Role, b: Role) -> Bool { a.rawValue < b.rawValue }

        public func label(in field: Field) -> String? {
            switch self {
            case .teamLeader: field == .design ? "Design leader" : "Product leader"
            case .founder: "Founder / CEO"
            case .recruiter: "HR / Recruiter"
            case .teammate: "Same field"
            case .other: nil
            }
        }
    }

    public struct Person: Equatable, Sendable {
        public var connection: Connection
        public var role: Role
        public var isPossible: Bool
    }

    public struct Search: Equatable, Sendable {
        public var title: String
        public var url: URL
    }

    public var field: Field
    public var people: [Person]
    public var searches: [Search]

    public init(job: Job, referrals: [ReferralFlag]) {
        let field = Field(jobTitle: job.title)
        self.field = field
        people = referrals
            .map { Person(connection: $0.connection, role: Self.role(of: $0.connection.position, in: field),
                          isPossible: $0.jobReferral.confidence == .possible) }
            .sorted { ($0.isPossible ? 1 : 0, $0.role, $0.connection.fullName) < ($1.isPossible ? 1 : 0, $1.role, $1.connection.fullName) }
        searches = Self.searches(company: job.companyName, field: field)
    }

    // MARK: Reading a job title

    static func role(of position: String, in field: Field) -> Role {
        let title = " " + position.lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : " " }
            .joined()
            .split(separator: " ").joined(separator: " ") + " "
        func has(_ terms: String...) -> Bool { terms.contains { title.contains(" \($0) ") } }

        if has("founder", "cofounder", "co founder", "ceo", "chief executive officer", "chief executive", "managing director") {
            return .founder
        }
        if has("recruiter", "recruiting", "recruitment", "talent", "hr", "hrbp", "human resources", "people partner", "people operations") {
            return .recruiter
        }
        let isDesign = has("design", "designer", "designers", "ux", "ui", "user experience", "cdo")
        let isProduct = has("product", "products", "cpo")
        let isSenior = has("head", "vp", "svp", "vice president", "director", "chief", "cdo", "cpo")
        switch field {
        case .design:
            if isDesign && (isSenior || has("lead", "principal", "manager")) { return .teamLeader }
            if isDesign { return .teammate }
        case .product:
            if isProduct && !isDesign && isSenior { return .teamLeader }
            if isProduct && !isDesign { return .teammate }
        }
        return .other
    }

    // MARK: LinkedIn searches

    private static func searches(company: String, field: Field) -> [Search] {
        let leaders = field == .design
            ? ("Head of Design", #""head of design" OR "design director" OR "VP design""#)
            : ("Head of Product", #""head of product" OR "VP product" OR "chief product officer""#)
        let groups = [
            leaders,
            ("CEO / Founder", "CEO OR founder"),
            ("HR / Recruiter", #"recruiter OR "talent acquisition" OR "human resources""#),
        ]
        return groups.compactMap { title, roles in
            var link = URLComponents(string: "https://www.linkedin.com/search/results/people/")
            link?.queryItems = [URLQueryItem(name: "keywords", value: #""\#(company)" (\#(roles))"#)]
            return link?.url.map { Search(title: title, url: $0) }
        }
    }
}
