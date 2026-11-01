import Foundation

extension JobType {
    /// From a feed's own word for the kind of work, if it has one, and the job's title, which
    /// overrides it: a "full-time" feed can still list "Product Designer (Contract)".
    public init(label: String?, title: String) {
        let word = (label ?? "").lowercased()
        let name = title.lowercased()
        if word.contains("freelanc") || name.contains("freelanc") {
            self = .freelance
        } else if word.contains("contract") || word.contains("temporary") || Self.saysContract(name) {
            self = .contract
        } else {
            self = .fullTime
        }
    }

    /// "Smart Contract" and "Contract Manager" name the work, not the terms.
    private static func saysContract(_ title: String) -> Bool {
        title.contains(/\b(contract(or)?\b(?! (management|manager|lifecycle|review))|fixed[- ]term)/)
            && !title.contains("smart contract")
    }
}

/// The money a freelance post mentions, in the few ways people write it: "$500", "$1,500-$2,000/month",
/// "€70/h", "₹20k", "6000 USD".
public enum Budget {
    private static let amount = #"(?:(?:[$€£₹]|(?i:usd|eur|gbp|inr|rs\.?) ?)\d[\d,]*(?:\.\d+)?(?: ?(?i:k|m|million)\b)?|\d[\d,]*(?:\.\d+)? ?(?i:k)? ?(?i:usd|eur|gbp|inr|dollars|rupees)\b)"#
    private static let rate = #"(?: ?(?i:usd|eur|gbp|inr|dollars))? ?(?:/ ?\w+|(?i:per|every) \w+|(?i:an?) (?i:hour|hr|day|week|month|year|video|post|article|image)\b|(?i:hourly|daily|weekly|monthly|each)\b)"#

    private static let mention = try! NSRegularExpression(pattern: "\(amount)(?: ?(?:-|–|—|(?i:to)) ?\(amount))?(\(rate))?")
    private static let single = try! NSRegularExpression(pattern: amount)

    /// The first mention, as written.
    public static func text(in post: String) -> String? {
        let range = NSRange(post.startIndex..., in: post)
        return mention.firstMatch(in: post, range: range)
            .flatMap { Range($0.range, in: post) }
            .map { String(post[$0]).trimmingCharacters(in: .whitespaces) }
    }

    /// The most a post offers for the whole job, roughly in dollars. Nil when it names no money, or
    /// pays by the hour, month or piece, which can't be held against a project budget.
    public static func flatDollars(in post: String) -> Double? {
        let range = NSRange(post.startIndex..., in: post)
        var highest: Double?
        for match in mention.matches(in: post, range: range) {
            if match.range(at: 1).location != NSNotFound { return nil }
            guard let found = Range(match.range, in: post) else { continue }
            let written = String(post[found])
            for part in single.matches(in: written, range: NSRange(written.startIndex..., in: written)) {
                guard let piece = Range(part.range, in: written), let value = dollars(String(written[piece])) else { continue }
                highest = max(highest ?? 0, value)
            }
        }
        return highest
    }

    private static func dollars(_ written: String) -> Double? {
        let lower = written.lowercased()
        guard let digits = lower.firstMatch(of: /\d[\d,]*(?:\.\d+)?/),
              var value = Double(digits.output.replacingOccurrences(of: ",", with: "")) else { return nil }
        let after = lower[digits.range.upperBound...].trimmingCharacters(in: .whitespaces)
        if after.hasPrefix("k") { value *= 1_000 }
        if after.hasPrefix("m") { value *= 1_000_000 }
        // Rough rates: this only decides whether a post clears your minimum.
        if lower.contains("₹") || lower.contains("inr") || lower.contains("rs") || lower.contains("rupee") { value /= 85 }
        if lower.contains("€") || lower.contains("eur") { value *= 1.1 }
        if lower.contains("£") || lower.contains("gbp") { value *= 1.3 }
        return value
    }
}
