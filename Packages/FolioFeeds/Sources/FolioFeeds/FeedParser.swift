import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import FolioCore

/// A feed as published: RSS 2.0, RSS 1.0 (RDF), Atom or JSON Feed.
public struct ParsedFeed: Sendable, Hashable {
    public var title: String
    public var siteURL: URL?
    public var items: [ParsedItem]

    public init(title: String, siteURL: URL? = nil, items: [ParsedItem] = []) {
        self.title = title
        self.siteURL = siteURL
        self.items = items
    }
}

public struct ParsedItem: Sendable, Hashable {
    /// The feed's own id for the item (guid, Atom id); nil when it has none.
    public var guid: String?
    public var url: URL?
    public var title: String
    /// Full content when the feed has it, otherwise the summary.
    public var html: String
    public var author: String?
    public var published: Date?
    public var updated: Date?
    public var enclosures: [Enclosure]

    public init(guid: String? = nil, url: URL? = nil, title: String, html: String, author: String? = nil,
                published: Date? = nil, updated: Date? = nil, enclosures: [Enclosure] = []) {
        self.guid = guid
        self.url = url
        self.title = title
        self.html = html
        self.author = author
        self.published = published
        self.updated = updated
        self.enclosures = enclosures
    }

    /// What identifies the item across fetches: its guid, else its link,
    /// else its title and date.
    public var identity: String {
        if let guid, !guid.isEmpty { return guid }
        if let url { return url.absoluteString }
        return title + "|" + (published.map { String(Int($0.timeIntervalSince1970)) } ?? "")
    }
}

public enum FeedParserError: Error, Sendable, Hashable {
    /// The data isn't a feed: usually a web page.
    case notAFeed
}

public enum FeedParser {
    /// Parses a feed. `url` is where it came from, for relative links.
    public static func parse(_ data: Data, url: URL) throws(FeedParserError) -> ParsedFeed {
        let start = data.prefix(512).drop { $0 == 0xEF || $0 == 0xBB || $0 == 0xBF || $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }
        if start.first == UInt8(ascii: "{") {
            guard let feed = JSONFeed.parse(data, base: url) else { throw .notAFeed }
            return feed
        }
        let reader = XMLFeedReader(base: url)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = reader
        parser.parse()
        // A feed broken near the end still gives the items before the error.
        guard reader.kind != nil else { throw .notAFeed }
        return reader.result
    }

    /// Whether data looks like a feed rather than a web page.
    public static func looksLikeFeed(_ data: Data) -> Bool {
        let head = String(decoding: data.prefix(1024), as: UTF8.self).lowercased()
        if head.contains("<html") { return false }
        return head.contains("<rss") || head.contains("<feed") || head.contains("<rdf:rdf") || head.contains(":feed")
            || head.contains("jsonfeed.org")
    }
}

/// SAX-style reader for the XML formats. Element names are local names; the
/// namespace tells Atom's `link` from RSS's and keeps prefixed feeds working.
private final class XMLFeedReader: NSObject, XMLParserDelegate {
    enum Kind { case rss, atom }

    static let atom = "http://www.w3.org/2005/Atom"
    static let content = "http://purl.org/rss/1.0/modules/content/"
    static let dc = "http://purl.org/dc/elements/1.1/"
    static let media = "http://search.yahoo.com/mrss/"
    static let xhtml = "http://www.w3.org/1999/xhtml"

    let base: URL
    var kind: Kind?
    var result = ParsedFeed(title: "")

    private var item: ParsedItem?
    private var text = ""
    private var contentHTML: String?
    private var summaryHTML: String?
    private var depth = 0
    private var itemDepth = 0
    /// Inside Atom content of type xhtml: its markup is rebuilt as text.
    private var xhtmlDepth: Int?
    private var inAuthor = false

    init(base: URL) {
        self.base = base
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI ns: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        depth += 1
        if let xhtmlDepth, depth > xhtmlDepth {
            text += "<" + name + attributes.map { " \($0.key)=\"\(Self.escape($0.value))\"" }.joined() + ">"
            return
        }
        let ns = ns ?? ""
        if kind == nil {
            switch name {
            case "rss", "RDF": kind = .rss
            case "feed": kind = .atom
            default: break
            }
        }
        switch name {
        case "item" where kind == .rss, "entry" where kind == .atom:
            item = ParsedItem(title: "", html: "")
            itemDepth = depth
            contentHTML = nil
            summaryHTML = nil
        case "link" where ns == Self.atom:
            let rel = attributes["rel"] ?? "alternate"
            guard let href = attributes["href"], let url = URL(string: href, relativeTo: base)?.absoluteURL else { break }
            if item != nil {
                if rel == "alternate", item?.url == nil { item?.url = url }
                if rel == "enclosure" { item?.enclosures.append(Enclosure(url: url, mimeType: attributes["type"])) }
            } else if rel == "alternate", result.siteURL == nil {
                result.siteURL = url
            }
        case "enclosure" where item != nil:
            if let href = attributes["url"], let url = URL(string: href, relativeTo: base)?.absoluteURL {
                item?.enclosures.append(Enclosure(url: url, mimeType: attributes["type"], length: attributes["length"].flatMap { Int($0) }))
            }
        case "content" where ns == Self.media, "thumbnail" where ns == Self.media:
            if item != nil, let href = attributes["url"], let url = URL(string: href, relativeTo: base)?.absoluteURL,
               !(item?.enclosures.contains { $0.url == url } ?? true) {
                let type = attributes["type"] ?? (attributes["medium"] == "image" || name == "thumbnail" ? "image/jpeg" : nil)
                item?.enclosures.append(Enclosure(url: url, mimeType: type))
            }
        case "content" where ns == Self.atom && attributes["type"] == "xhtml":
            xhtmlDepth = depth
        case "author" where ns == Self.atom:
            inAuthor = true
        default:
            break
        }
        text = ""
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI ns: String?, qualifiedName: String?) {
        defer { depth -= 1 }
        if let xhtmlDepth {
            if depth > xhtmlDepth {
                text += "</" + name + ">"
                return
            }
            self.xhtmlDepth = nil
        }
        let ns = ns ?? ""
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { if xhtmlDepth == nil { text = "" } }
        if name == "author", ns == Self.atom, item == nil { inAuthor = false }

        guard item != nil else {
            // Feed-level fields sit directly under the channel or feed.
            if name == "title", result.title.isEmpty, ns != Self.media { result.title = Self.plain(value) }
            if name == "link", ns != Self.atom, result.siteURL == nil, let url = URL(string: value, relativeTo: base)?.absoluteURL {
                result.siteURL = url
            }
            return
        }
        switch name {
        case "item" where kind == .rss, "entry" where kind == .atom:
            guard depth == itemDepth, var finished = item else { break }
            finished.html = contentHTML ?? summaryHTML ?? ""
            if finished.published == nil { finished.published = finished.updated }
            if !finished.title.isEmpty || !finished.html.isEmpty { result.items.append(finished) }
            item = nil
        case "title" where ns != Self.media:
            if item?.title.isEmpty == true { item?.title = Self.plain(value) }
        case "link" where ns != Self.atom:
            if item?.url == nil, let url = URL(string: value, relativeTo: base)?.absoluteURL { item?.url = url }
        case "guid", "id" where ns == Self.atom:
            if !value.isEmpty { item?.guid = value }
        case "encoded" where ns == Self.content:
            if !value.isEmpty { contentHTML = value }
        case "content" where ns == Self.atom:
            if !value.isEmpty { contentHTML = value }
        case "description", "summary" where ns == Self.atom:
            if !value.isEmpty { summaryHTML = value }
        case "pubDate", "published", "issued":
            item?.published = FeedDates.parse(value) ?? item?.published
        case "date" where ns == Self.dc:
            if item?.published == nil { item?.published = FeedDates.parse(value) }
        case "updated", "modified":
            item?.updated = FeedDates.parse(value)
        case "creator" where ns == Self.dc, "author" where ns != Self.atom:
            if item?.author == nil, !value.isEmpty { item?.author = Self.plain(value) }
        case "name" where inAuthor:
            if item?.author == nil, !value.isEmpty { item?.author = Self.plain(value) }
        case "author" where ns == Self.atom:
            inAuthor = false
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += xhtmlDepth != nil ? Self.escape(string) : string
    }

    func parser(_ parser: XMLParser, foundCDATA block: Data) {
        text += String(decoding: block, as: UTF8.self)
    }

    /// Titles arrive as text, escaped HTML or with tags: plain text out.
    static func plain(_ value: String) -> String {
        var out = ""
        var inTag = false
        for character in value {
            if character == "<" { inTag = true } else if character == ">" && inTag { inTag = false } else if !inTag { out.append(character) }
        }
        return HTMLText.decodeEntities(out).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// JSON Feed 1.0 and 1.1 (https://jsonfeed.org).
private enum JSONFeed {
    struct Author: Decodable { var name: String? }
    struct Attachment: Decodable { var url: String; var mime_type: String?; var size_in_bytes: Int? }
    struct Item: Decodable {
        var id: String?
        var url: String?
        var title: String?
        var content_html: String?
        var content_text: String?
        var summary: String?
        var image: String?
        var date_published: String?
        var date_modified: String?
        var author: Author?
        var authors: [Author]?
        var attachments: [Attachment]?
    }
    struct Document: Decodable {
        var version: String
        var title: String?
        var home_page_url: String?
        var items: [Item]
    }

    static func parse(_ data: Data, base: URL) -> ParsedFeed? {
        guard let document = try? JSONDecoder().decode(Document.self, from: data), document.version.contains("jsonfeed.org") else { return nil }
        func url(_ string: String?) -> URL? { string.flatMap { URL(string: $0, relativeTo: base)?.absoluteURL } }
        let items = document.items.map { item in
            var enclosures = (item.attachments ?? []).compactMap { attachment in
                url(attachment.url).map { Enclosure(url: $0, mimeType: attachment.mime_type, length: attachment.size_in_bytes) }
            }
            if let image = url(item.image) { enclosures.insert(Enclosure(url: image, mimeType: "image/jpeg"), at: 0) }
            let text = item.content_text.map { "<p>" + PlainText.paragraphs($0) + "</p>" }
            return ParsedItem(
                guid: item.id, url: url(item.url), title: item.title ?? "", html: item.content_html ?? text ?? item.summary ?? "",
                author: item.authors?.first?.name ?? item.author?.name,
                published: item.date_published.flatMap(FeedDates.parse), updated: item.date_modified.flatMap(FeedDates.parse),
                enclosures: enclosures)
        }
        return ParsedFeed(title: document.title ?? base.host ?? "", siteURL: url(document.home_page_url), items: items)
    }
}

private enum PlainText {
    /// Plain text as HTML paragraphs.
    static func paragraphs(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\n\n", with: "</p><p>")
    }
}
