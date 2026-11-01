import Foundation

/// Reads the items from an RSS 2.0 or Atom feed.
enum RSSReader {
    struct Item: Equatable {
        var title = ""
        var link = ""
        var guid: String?
        var pubDate: String?
        var description = ""
        /// We Work Remotely's own tag for where you can work from.
        var region: String?
        /// We Work Remotely's own tag for the kind of work.
        var type: String?
        /// Atom's author name.
        var author: String?
    }

    static func items(in data: Data) throws -> [Item] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw FeedError.unreadable(parser.parserError?.localizedDescription ?? "not a feed")
        }
        return delegate.items.filter { !$0.title.isEmpty && !$0.link.isEmpty }
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var items: [Item] = []
        private var current: Item?
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
            switch name {
            case "item", "entry":
                current = Item()
            case "link" where current != nil:
                // Atom puts the URL in an attribute.
                if let href = attributes["href"], current?.link.isEmpty ?? false { current?.link = href }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            text += String(decoding: CDATABlock, as: UTF8.self)
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            defer { text = "" }
            guard current != nil else { return }
            switch name {
            case "item", "entry":
                if let current { items.append(current) }
                current = nil
            case "title": current?.title = value
            case "link" where !value.isEmpty: current?.link = value
            case "guid", "id": current?.guid = value
            case "pubDate", "published", "updated": if current?.pubDate == nil { current?.pubDate = value }
            case "description", "summary", "content": if current?.description.isEmpty ?? true { current?.description = value }
            case "region": current?.region = value
            case "type": current?.type = value
            case "name": current?.author = value
            default: break
            }
        }
    }
}
