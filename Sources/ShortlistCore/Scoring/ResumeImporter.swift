import Foundation
import PDFKit

/// Turns a resume file into structured data with the same model that scores jobs. Your email and
/// phone number are picked out here and removed first, so they never leave this Mac.
public struct ResumeImporter: Sendable {
    public enum ImportError: LocalizedError {
        case unreadable

        public var errorDescription: String? {
            "Couldn't read any text from that file. Try a PDF with selectable text, or a text file."
        }
    }

    public struct Output: Equatable, Sendable {
        public var resume: MasterResume
        public var headline: String
        public var usage: TokenUsage
    }

    private let client: any ModelClient

    public init(client: any ModelClient) {
        self.client = client
    }

    public static func text(of url: URL) throws -> String {
        let text = url.pathExtension.lowercased() == "pdf"
            ? PDFDocument(url: url)?.string
            : try? String(contentsOf: url, encoding: .utf8)
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ImportError.unreadable
        }
        return text
    }

    public func extract(from text: String) async throws -> Output {
        let (redacted, email, phone) = Self.redact(text)
        let reply = try await client.completeWithRetries(ModelRequest(
            system: """
                Copy this resume into the given structure. Use only what it says, in its words. \
                Never add, improve or guess. Use "" for anything missing, and null for the end of \
                a current job. headline is the person's current title and field in under 10 words.
                """,
            user: redacted, schemaName: "resume", schema: Extracted.schema, maxOutputTokens: 6_000))

        let extracted: Extracted
        do {
            extracted = try JSONDecoder().decode(Extracted.self, from: Data(reply.json.utf8))
        } catch {
            throw ModelError.unreadable(String(describing: error))
        }
        var resume = MasterResume()
        resume.name = extracted.name
        resume.email = email ?? ""
        resume.phone = phone ?? ""
        resume.location = extracted.location
        resume.links = extracted.links
        resume.summary = extracted.summary
        resume.experience = extracted.experience
        resume.education = extracted.education
        resume.skills = extracted.skills
        return Output(resume: resume, headline: extracted.headline, usage: reply.usage)
    }

    static func redact(_ text: String) -> (text: String, email: String?, phone: String?) {
        var result = text
        var email: String?
        for match in matches(of: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, in: text) {
            email = email ?? match
            result = result.replacingOccurrences(of: match, with: "[email]")
        }
        var phone: String?
        for match in matches(of: #"\+?\d[\d\s().-]{8,}\d"#, in: text) {
            // Date ranges look like this too, but have fewer digits.
            let digits = match.filter(\.isNumber).count
            guard (10...13).contains(digits) else { continue }
            phone = phone ?? match
            result = result.replacingOccurrences(of: match, with: "[phone]")
        }
        return (result, email, phone)
    }

    private static func matches(of pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    private struct Extracted: Decodable {
        var name: String
        var headline: String
        var location: String
        var links: [String]
        var summary: String
        var skills: [String]
        var experience: [MasterResume.Experience]
        var education: [MasterResume.Education]

        static let schema = """
            {
              "type": "object",
              "additionalProperties": false,
              "required": ["name", "headline", "location", "links", "summary", "skills", "experience", "education"],
              "properties": {
                "name": { "type": "string" },
                "headline": { "type": "string" },
                "location": { "type": "string" },
                "links": { "type": "array", "items": { "type": "string" } },
                "summary": { "type": "string" },
                "skills": { "type": "array", "items": { "type": "string" } },
                "experience": {
                  "type": "array",
                  "items": {
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["company", "title", "location", "start", "end", "bullets"],
                    "properties": {
                      "company": { "type": "string" },
                      "title": { "type": "string" },
                      "location": { "type": "string" },
                      "start": { "type": "string" },
                      "end": { "type": ["string", "null"] },
                      "bullets": { "type": "array", "items": { "type": "string" } }
                    }
                  }
                },
                "education": {
                  "type": "array",
                  "items": {
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["school", "degree", "year"],
                    "properties": {
                      "school": { "type": "string" },
                      "degree": { "type": "string" },
                      "year": { "type": "string" }
                    }
                  }
                }
              }
            }
            """
    }
}
