import Foundation

/// A small RFC 4180 CSV reader: quoted fields, `""` escapes, commas and line breaks inside quotes,
/// CRLF or LF line ends, and a leading byte-order mark.
enum CSVParser {
    static func rows(in text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var chars = text.unicodeScalars.makeIterator()
        var pending = chars.next()
        if pending == "\u{FEFF}" { pending = chars.next() }

        func endField() {
            row.append(field)
            field = ""
        }
        func endRow() {
            endField()
            // A blank line is one empty field; drop it rather than return a hollow row.
            if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
            row = []
        }

        while let c = pending {
            pending = chars.next()
            if inQuotes {
                if c == "\"" {
                    if pending == "\"" {
                        field.unicodeScalars.append("\"")
                        pending = chars.next()
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.unicodeScalars.append(c)
                }
                continue
            }
            switch c {
            case "\"" where field.isEmpty:
                inQuotes = true
            case ",":
                endField()
            case "\r":
                if pending == "\n" { pending = chars.next() }
                endRow()
            case "\n":
                endRow()
            default:
                field.unicodeScalars.append(c)
            }
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }
}
