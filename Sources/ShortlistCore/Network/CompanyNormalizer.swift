import Foundation

/// Turns a company name into a key that matches however a job board or LinkedIn spells it.
///
/// "Razorpay Software Pvt. Ltd." and "Razorpay" both become `razorpay`. It only strips words that
/// say what kind of company it is, never the part that says which one, so "Meta" and "Metabase"
/// stay apart. Names it can't join, like "Facebook" and "Meta", go in the alias table.
public enum CompanyNormalizer {
    public static func normalize(_ name: String) -> String {
        var text = name
        // "Meta (formerly Facebook)" → "Meta"
        text = text.replacing(/\([^)]*\)/, with: " ")
        // "Amazon.com" → "Amazon", "Notion.so" stays readable as "Notion"
        text = text.replacing(/(?i)\.(com|io|ai|co|in|so|app|net|org)\b/, with: " ")

        var tokens = fold(text).split(separator: " ").map(String.init)
        if tokens.first == "the", tokens.count > 1 { tokens.removeFirst() }
        while tokens.count > 1, let last = tokens.last, trailingNoise.contains(last) {
            tokens.removeLast()
        }

        let result = tokens.joined(separator: " ")
        return notACompany.contains(result) ? "" : result
    }

    /// Lowercase, no accents, "&" read as "and", and everything but letters and digits made a
    /// single space.
    public static func fold(_ text: String) -> String {
        let folded = text
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "&", with: " and ")
        var out = ""
        var lastWasSpace = true
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastWasSpace = false
            } else if scalar == "'" || scalar == "\u{2019}" {
                continue  // "McKinsey's" → "mckinseys"
            } else if !lastWasSpace {
                out.append(" ")
                lastWasSpace = true
            }
        }
        if out.hasSuffix(" ") { out.removeLast() }
        return out
    }

    /// Words at the end of a name that describe the legal form or the line of business, or a
    /// country office. Stripped from the end only, and never the last word left.
    static let trailingNoise: Set<String> = [
        "inc", "incorporated", "llc", "llp", "ltd", "limited", "pvt", "private", "plc", "pte",
        "corp", "corporation", "co", "company", "and", "gmbh", "ag", "sa", "sas", "bv", "nv", "ab", "oy",
        "technologies", "technology", "labs", "software", "solutions", "systems", "group", "holdings",
        "india", "global", "international", "hq",
    ]

    /// What people put in the company field when there isn't one. These never match a job.
    static let notACompany: Set<String> = [
        "", "self employed", "selfemployed", "freelance", "freelancer", "stealth", "stealth startup",
        "stealth mode", "stealth mode startup", "confidential", "independent", "independent consultant",
        "consultant", "n a", "na", "none", "nil", "retired", "unemployed", "student",
        "looking for opportunities", "open to work", "open to opportunities", "career break",
    ]
}
