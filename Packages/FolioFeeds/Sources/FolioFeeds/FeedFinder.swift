import Foundation
import FolioFreshRSS

/// A feed found for something the reader typed: a feed address, a site, or
/// a page that links its feed.
public struct FoundFeed: Sendable, Hashable {
    public var feedURL: URL
    public var title: String
    public var siteURL: URL?
    /// How many stories it has right now, to show before adding it.
    public var itemCount: Int
}

public enum FeedFinderError: Error, Sendable, Hashable, CustomStringConvertible {
    case invalidAddress
    case noFeed(URL)
    case unreachable(String)

    public var description: String {
        switch self {
        case .invalidAddress: "That doesn't look like a website address."
        case .noFeed(let url): "\(url.host ?? "This site") doesn't offer a feed Paperwire can read."
        case .unreachable(let message): "Couldn't reach the site: \(message)"
        }
    }
}

/// Finds the feed behind an address, the way a browser's "Subscribe" does:
/// the address itself, the feeds the page links, then the usual places.
public struct FeedFinder: Sendable {
    let transport: any HTTPTransport

    public init(transport: any HTTPTransport) {
        self.transport = transport
    }

    public func find(_ input: String) async throws(FeedFinderError) -> FoundFeed {
        guard let url = Self.address(from: input) else { throw .invalidAddress }
        let response: HTTPResponse
        do {
            response = try await transport.send(Self.request(url))
        } catch let error as TransportError {
            throw .unreachable(error.kind == .offline ? "you're offline" : error.message)
        } catch {
            throw .unreachable("\(error)")
        }
        guard (200..<300).contains(response.status) else { throw .unreachable("it answered \(response.status)") }
        if let found = Self.feed(response.body, url: url) { return found }

        // A page: the feeds it links first, then the places feeds usually live.
        let page = String(decoding: response.body.prefix(400_000), as: UTF8.self)
        var candidates = Self.feedLinks(inHTML: page, base: url)
        for guess in Self.guesses(for: url) where !candidates.contains(guess) { candidates.append(guess) }
        for candidate in candidates.prefix(8) {
            guard let answer = try? await transport.send(Self.request(candidate)), (200..<300).contains(answer.status),
                  let found = Self.feed(answer.body, url: candidate)
            else { continue }
            return found
        }
        throw .noFeed(url)
    }

    static func feed(_ data: Data, url: URL) -> FoundFeed? {
        guard FeedParser.looksLikeFeed(data), let feed = try? FeedParser.parse(data, url: url) else { return nil }
        return FoundFeed(feedURL: url, title: feed.title.isEmpty ? (url.host ?? url.absoluteString) : feed.title,
                         siteURL: feed.siteURL, itemCount: feed.items.count)
    }

    static func request(_ url: URL) -> HTTPRequest {
        HTTPRequest(url: url, headers: ["Accept": "application/rss+xml, application/atom+xml, application/feed+json, application/xml;q=0.9, text/html;q=0.8, */*;q=0.5"])
    }

    /// "theverge.com", "www.theverge.com/rss", "https://…": an https URL.
    public static func address(from input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        if text.lowercased().hasPrefix("feed:") { text = String(text.dropFirst(5)).replacingOccurrences(of: "//", with: "", options: .anchored) }
        if !text.lowercased().hasPrefix("http://") && !text.lowercased().hasPrefix("https://") { text = "https://" + text }
        guard let url = URL(string: text), let host = url.host, host.contains("."), !host.hasPrefix("."), !host.hasSuffix(".") else { return nil }
        return url
    }

    /// Feed links a page advertises: `<link rel="alternate" type="application/rss+xml" href="…">`.
    public static func feedLinks(inHTML html: String, base: URL) -> [URL] {
        let types = ["application/rss+xml", "application/atom+xml", "application/feed+json", "application/json"]
        var links: [URL] = []
        var rest = html[...]
        while let open = rest.range(of: "<link", options: .caseInsensitive) {
            guard let close = rest[open.upperBound...].firstIndex(of: ">") else { break }
            let attributes = Self.attributes(String(rest[open.upperBound..<close]))
            rest = rest[close...]
            guard attributes["rel"]?.lowercased().split(separator: " ").contains("alternate") == true,
                  let type = attributes["type"]?.lowercased(), types.contains(type),
                  let href = attributes["href"], let url = URL(string: href, relativeTo: base)?.absoluteURL,
                  !links.contains(url)
            else { continue }
            // Comment feeds are rarely what someone wants.
            if href.lowercased().contains("comments/feed") { continue }
            links.append(url)
        }
        return links
    }

    static func attributes(_ tag: String) -> [String: String] {
        var result: [String: String] = [:]
        var scanner = tag[...]
        while let equals = scanner.firstIndex(of: "=") {
            let name = scanner[..<equals].split(whereSeparator: \.isWhitespace).last.map { $0.lowercased() } ?? ""
            var valueStart = scanner.index(after: equals)
            while valueStart < scanner.endIndex, scanner[valueStart].isWhitespace { valueStart = scanner.index(after: valueStart) }
            guard valueStart < scanner.endIndex else { break }
            let quote = scanner[valueStart]
            let value: Substring
            if quote == "\"" || quote == "'" {
                let start = scanner.index(after: valueStart)
                let end = scanner[start...].firstIndex(of: quote) ?? scanner.endIndex
                value = scanner[start..<end]
                scanner = end < scanner.endIndex ? scanner[scanner.index(after: end)...] : scanner[end...]
            } else {
                let end = scanner[valueStart...].firstIndex { $0.isWhitespace || $0 == "/" } ?? scanner.endIndex
                value = scanner[valueStart..<end]
                scanner = scanner[end...]
            }
            if !name.isEmpty { result[name] = String(value).replacingOccurrences(of: "&amp;", with: "&") }
        }
        return result
    }

    /// Where sites without a feed link usually keep one.
    static func guesses(for url: URL) -> [URL] {
        guard let root = URL(string: "/", relativeTo: url)?.absoluteURL else { return [] }
        return ["feed", "rss", "feed.xml", "rss.xml", "atom.xml", "index.xml", "feed.json", "blog/feed"]
            .compactMap { URL(string: $0, relativeTo: root)?.absoluteURL }
    }
}
