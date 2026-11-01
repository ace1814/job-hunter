import CoreGraphics
import CoreText
import Foundation

/// Draws a resume as a plain one-column A4 PDF. Real text in reading order, with no columns or
/// tables, because applicant tracking systems read these before people do.
public enum ResumePDF {
    private static let page = CGRect(x: 0, y: 0, width: 595, height: 842)
    private static let margin: CGFloat = 48

    public static func render(_ resume: MasterResume) -> Data {
        let data = NSMutableData()
        var box = page
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &box, [
                  kCGPDFContextTitle: "\(resume.name) Resume" as CFString,
                  kCGPDFContextAuthor: resume.name as CFString,
              ] as CFDictionary) else { return Data() }

        let text = content(of: resume)
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let frameRect = page.insetBy(dx: margin, dy: margin)
        var start = 0
        repeat {
            context.beginPDFPage(nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: start, length: 0), CGPath(rect: frameRect, transform: nil), nil)
            CTFrameDraw(frame, context)
            context.endPDFPage()
            let drawn = CTFrameGetVisibleStringRange(frame).length
            if drawn == 0 { break }
            start += drawn
        } while start < text.length
        context.closePDF()
        return data as Data
    }

    private enum Style {
        case name, contact, heading, role, body, bullet

        var size: CGFloat {
            switch self {
            case .name: 22
            case .heading: 11
            case .role: 10.5
            default: 10
            }
        }

        var fontName: String {
            switch self {
            case .name, .heading, .role: "HelveticaNeue-Medium"
            default: "HelveticaNeue"
            }
        }

        var spaceBefore: CGFloat {
            switch self {
            case .heading: 12
            case .role: 7
            case .bullet: 2
            default: 0
            }
        }

        var indent: CGFloat { self == .bullet ? 10 : 0 }
    }

    private static func content(of resume: MasterResume) -> NSAttributedString {
        let text = NSMutableAttributedString()
        func add(_ string: String, _ style: Style) {
            guard !string.isEmpty else { return }
            let prefix = text.length == 0 ? "" : "\n"
            text.append(NSAttributedString(string: prefix + string, attributes: attributes(style)))
        }

        add(resume.name, .name)
        add(([resume.location, resume.email, resume.phone] + resume.links).filter { !$0.isEmpty }.joined(separator: "  |  "), .contact)

        if !resume.summary.isEmpty {
            add("Summary", .heading)
            add(resume.summary, .body)
        }
        if !resume.experience.isEmpty {
            add("Experience", .heading)
            for role in resume.experience {
                add("\(role.title), \(role.company)", .role)
                add(["\(role.start) to \(role.end ?? "Present")", role.location].filter { !$0.isEmpty }.joined(separator: "  |  "), .contact)
                for bullet in role.bullets { add("•  \(bullet)", .bullet) }
            }
        }
        if !resume.education.isEmpty {
            add("Education", .heading)
            for school in resume.education {
                add([school.degree, school.school, school.year].filter { !$0.isEmpty }.joined(separator: ", "), .body)
            }
        }
        if !resume.skills.isEmpty {
            add("Skills", .heading)
            add(resume.skills.joined(separator: ", "), .body)
        }
        return text
    }

    private static func attributes(_ style: Style) -> [NSAttributedString.Key: Any] {
        let font = CTFontCreateWithName(style.fontName as CFString, style.size, nil)
        let gray = style == .contact ? 0.35 : 0.1
        var spaceBefore = style.spaceBefore
        var indent = style.indent
        var lineSpacing: CGFloat = 1.5
        let paragraph = withUnsafeBytes(of: &spaceBefore) { before in
            withUnsafeBytes(of: &indent) { head in
                withUnsafeBytes(of: &lineSpacing) { line in
                    [
                        CTParagraphStyleSetting(spec: .paragraphSpacingBefore, valueSize: MemoryLayout<CGFloat>.size, value: before.baseAddress!),
                        CTParagraphStyleSetting(spec: .headIndent, valueSize: MemoryLayout<CGFloat>.size, value: head.baseAddress!),
                        CTParagraphStyleSetting(spec: .lineSpacingAdjustment, valueSize: MemoryLayout<CGFloat>.size, value: line.baseAddress!),
                    ].withUnsafeBufferPointer { CTParagraphStyleCreate($0.baseAddress!, $0.count) }
                }
            }
        }
        return [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: gray, alpha: 1),
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
        ]
    }
}
