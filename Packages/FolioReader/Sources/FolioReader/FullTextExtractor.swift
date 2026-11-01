import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import FolioCore

/// Finds the article in a publisher's web page, the way Reader view does,
/// for feeds that only send a summary. The page is fetched on the reader's
/// own device for their own reading; nothing is shared or stored elsewhere.
///
/// Two sources, and the longer one wins:
/// 1. **The page itself.** Navigation, sidebars, comments, share bars and
///    hidden parts are dropped; blocks are scored by the paragraph text they
///    hold (length, commas) and how little of it is links; the best block and
///    its paragraph-rich neighbours are kept, with headings, lists, quotes
///    and images.
/// 2. **Structured data.** Many news sites put the whole text in JSON-LD
///    (`articleBody`), even when the page builds it with JavaScript.
///
/// The result is plain article HTML for `ArticleParser`, which sanitizes it
/// like any feed content.
public enum FullTextExtractor {
    public struct Result: Sendable, Equatable {
        public var html: String
        /// Words of visible text, for deciding whether this beats the summary.
        public var wordCount: Int
        public var source: Source
    }

    public enum Source: String, Sendable { case page, structuredData }

    public static func extract(html: String, url: URL?) -> Result? {
        let fromPage = pageArticle(html: html, url: url)
        let fromData = structuredArticle(html: html)
        switch (fromPage, fromData) {
        case let (page?, data?):
            // The page keeps headings and images, so it wins unless clearly shorter.
            return Double(page.wordCount) >= Double(data.wordCount) * 0.8 ? page : data
        case let (page?, nil): return page
        case let (nil, data?): return data
        default: return nil
        }
    }

    // MARK: Page

    final class Node {
        let name: String
        var attributes: [String: String]
        var text: String
        var children: [Node] = []
        weak var parent: Node?
        var score = 0.0
        var scored = false

        init(name: String, attributes: [String: String] = [:], text: String = "") {
            self.name = name
            self.attributes = attributes
            self.text = text
        }

        var isText: Bool { name == "#text" }

        func append(_ child: Node) {
            child.parent = self
            children.append(child)
        }

        var innerText: String {
            if isText { return text }
            return children.map(\.innerText).joined()
        }

        var linkTextLength: Int {
            if name == "a" { return innerText.count }
            return children.reduce(0) { $0 + $1.linkTextLength }
        }

        var linkDensity: Double {
            let length = innerText.count
            return length == 0 ? 0 : Double(linkTextLength) / Double(length)
        }

        var marker: String { ((attributes["class"] ?? "") + " " + (attributes["id"] ?? "")).lowercased() }

        func descendants() -> [Node] {
            children.flatMap { [$0] + $0.descendants() }
        }
    }

    static let voidElements: Set<String> = ["br", "img", "hr", "meta", "link", "input", "source", "wbr", "area", "col", "embed", "track", "base"]
    static let blockElements: Set<String> = [
        "address", "article", "aside", "blockquote", "div", "dl", "fieldset", "figure", "footer", "form", "h1", "h2", "h3",
        "h4", "h5", "h6", "header", "hr", "li", "main", "nav", "ol", "p", "pre", "section", "table", "ul",
    ]
    static let droppedElements: Set<String> = [
        "script", "style", "noscript", "template", "iframe", "svg", "nav", "aside", "footer", "form", "button", "select",
        "input", "textarea", "dialog", "menu", "object", "canvas", "header",
    ]
    static let unlikely = [
        "-ad-", "ad-break", "advert", "agegate", "banner", "breadcrumb", "combx", "comment", "community", "cookie", "consent",
        "disqus", "footer", "gdpr", "legends", "menu", "modal", "newsletter", "outbrain", "pagination", "pager", "paywall",
        "popup", "promo", "recirc", "related", "remark", "replies", "rss", "share", "sharing", "shoutbox", "sidebar",
        "signup", "skyscraper", "social", "sponsor", "subscribe", "supplemental", "taboola", "toolbar", "trending",
    ]
    static let maybeArticle = ["and", "article", "body", "column", "content", "main", "story", "entry", "post", "text"]
    static let positive = ["article", "body", "content", "entry", "hentry", "h-entry", "main", "page", "post", "text", "blog", "story"]
    static let negative = [
        "-ad-", "hidden", "banner", "combx", "comment", "com-", "contact", "footer", "gdpr", "masthead", "media", "meta",
        "outbrain", "promo", "related", "scroll", "share", "shoutbox", "sidebar", "skyscraper", "sponsor", "shopping",
        "tags", "widget", "byline", "caption-credit",
    ]

    static func buildTree(_ html: String) -> Node {
        let root = Node(name: "#root")
        var stack: [Node] = [root]
        for token in HTMLTokenizer.tokenize(html) {
            switch token {
            case .startTag(let name, let attributes, let selfClosing):
                // An open paragraph ends where a block starts, as in HTML.
                if blockElements.contains(name), stack.last?.name == "p" { stack.removeLast() }
                if name == "li", let index = stack.lastIndex(where: { $0.name == "li" }),
                   !stack[(index + 1)...].contains(where: { $0.name == "ul" || $0.name == "ol" })
                {
                    stack.removeSubrange(index...)
                }
                let node = Node(name: name, attributes: attributes)
                stack.last?.append(node)
                if !selfClosing && !voidElements.contains(name) { stack.append(node) }
            case .endTag(let name):
                if let index = stack.lastIndex(where: { $0.name == name }), index > 0 { stack.removeSubrange(index...) }
            case .text(let text):
                stack.last?.append(Node(name: "#text", text: text))
            }
        }
        return root
    }

    static func isHidden(_ node: Node) -> Bool {
        if node.attributes["hidden"] != nil || node.attributes["aria-hidden"] == "true" { return true }
        let style = (node.attributes["style"] ?? "").replacingOccurrences(of: " ", with: "").lowercased()
        return style.contains("display:none") || style.contains("visibility:hidden")
    }

    /// Removes navigation, chrome and anything unlikely to be article text.
    /// With `byClass` off, only elements and hidden parts go (the retry when
    /// class names misled the first pass).
    static func prune(_ node: Node, byClass: Bool = true) {
        node.children.removeAll { child in
            guard !child.isText else { return false }
            if droppedElements.contains(child.name) || isHidden(child) { return true }
            let marker = child.marker
            if byClass, !marker.trimmingCharacters(in: .whitespaces).isEmpty, child.name != "body", child.name != "article",
               child.name != "main", unlikely.contains(where: marker.contains), !maybeArticle.contains(where: marker.contains),
               // A layout wrapper named for its sidebar ("ContainerWithSidebar") may hold the article itself.
               !child.descendants().contains(where: { $0.name == "article" || $0.name == "main" })
            {
                return true
            }
            return false
        }
        for child in node.children where !child.isText { prune(child, byClass: byClass) }
    }

    static func classWeight(_ node: Node) -> Double {
        var weight = 0.0
        for value in [node.attributes["class"], node.attributes["id"]].compactMap({ $0?.lowercased() }) where !value.isEmpty {
            if negative.contains(where: value.contains) { weight -= 25 }
            if positive.contains(where: value.contains) { weight += 25 }
        }
        return weight
    }

    static func baseScore(_ node: Node) -> Double {
        switch node.name {
        case "div", "article", "main", "section": 5
        case "pre", "td", "blockquote": 3
        case "address", "ol", "ul", "dl", "dd", "dt", "li", "form": -3
        case "h1", "h2", "h3", "h4", "h5", "h6", "th": -5
        default: 0
        }
    }

    /// Paragraph-like: a `p`, `pre` or `blockquote`, or a `div`/`section` that
    /// holds only inline content (sites that write paragraphs as divs).
    static func isParagraphLike(_ node: Node) -> Bool {
        if ["p", "pre", "blockquote"].contains(node.name) { return true }
        guard node.name == "div" || node.name == "section" else { return false }
        return !node.children.contains { !$0.isText && blockElements.contains($0.name) }
    }

    static func pageArticle(html: String, url: URL?) -> Result? {
        let strict = pageArticle(html: html, url: url, pruneByClass: true)
        if let strict, strict.wordCount >= 150 { return strict }
        // Too little: class names may have hidden the article. Try again without them.
        let loose = pageArticle(html: html, url: url, pruneByClass: false)
        return (loose?.wordCount ?? 0) > (strict?.wordCount ?? 0) ? loose : strict
    }

    static func pageArticle(html: String, url: URL?, pruneByClass: Bool) -> Result? {
        let root = buildTree(html)
        let body = root.descendants().first { $0.name == "body" } ?? root
        prune(body, byClass: pruneByClass)

        var candidates: [Node] = []
        func credit(_ node: Node?, _ amount: Double) {
            guard let node, !node.isText, node.name != "#root" else { return }
            if !node.scored {
                node.scored = true
                node.score = baseScore(node) + classWeight(node)
                candidates.append(node)
            }
            node.score += amount
        }
        for node in body.descendants() where !node.isText {
            // Long list items count half (release notes, step-by-step articles).
            let weight: Double
            if isParagraphLike(node) {
                weight = 1
            } else if node.name == "li", node.innerText.count >= 60, node.linkDensity < 0.5 {
                weight = 0.5
            } else {
                continue
            }
            let text = node.innerText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= 25 else { continue }
            let score = weight * (1 + Double(text.filter { $0 == "," || $0 == "،" || $0 == "，" }.count) + min(Double(text.count / 100), 3))
            // Up to five ancestors share the score, less with distance, so a
            // shared article container wins even when every paragraph has its
            // own wrapper divs (BBC).
            var ancestor = node.parent
            for level in 0..<5 {
                guard let current = ancestor else { break }
                credit(current, score / (level == 0 ? 1 : (level == 1 ? 2 : Double(level) * 3)))
                ancestor = current.parent
            }
        }
        // Link-heavy blocks (menus, link lists) lose most of their score.
        let ranked = candidates.map { ($0, $0.score * (1 - $0.linkDensity)) }.sorted { $0.1 > $1.1 }
        guard var top = ranked.first?.0, let topScore = ranked.first?.1 else { return nil }
        let finalScore = Dictionary(uniqueKeysWithValues: ranked.map { (ObjectIdentifier($0.0), $0.1) })

        // Several blocks scoring almost as well as the best one are parts of
        // the same article (BBC splits it into text blocks): use the nearest
        // ancestor they share.
        let alternatives = ranked.dropFirst().prefix(4).filter { $0.1 >= topScore * 0.75 }.map(\.0)
        if alternatives.count >= 2 {
            var shared: Node? = top.parent
            while let candidate = shared, !alternatives.allSatisfy({ isAncestor(candidate, of: $0) }) { shared = candidate.parent }
            if let shared, shared.name != "body", shared.name != "#root", shared.name != "html" { top = shared }
        }
        // A wrapper with nothing else in it adds nothing: step up to its parent.
        while let parent = top.parent, parent.name != "body", parent.name != "#root",
              parent.children.filter({ !$0.isText }).count == 1
        {
            top = parent
        }

        // Neighbours of the best block that are also article text.
        var parts: [Node] = [top]
        if let parent = top.parent {
            let threshold = max(10, top.score * 0.2)
            parts = parent.children.filter { sibling in
                if sibling === top { return true }
                guard !sibling.isText else { return false }
                if let score = finalScore[ObjectIdentifier(sibling)], score >= threshold { return true }
                if sibling.name == "p" {
                    let text = sibling.innerText
                    return (text.count > 80 && sibling.linkDensity < 0.25) || (text.count > 0 && sibling.linkDensity == 0 && text.contains(". "))
                }
                return false
            }
        }
        for part in parts { clean(part) }
        let output = parts.map { serialize($0, base: url) }.joined()
        let words = parts.reduce(0) { $0 + TextNormalizer.wordCount($1.innerText) }
        let length = parts.reduce(0) { $0 + $1.innerText.count }
        let links = parts.reduce(0) { $0 + $1.linkTextLength }
        // Mostly links is a list of stories, not an article.
        guard words >= 40, length == 0 || Double(links) / Double(length) < 0.5 else { return nil }
        return Result(html: output, wordCount: words, source: .page)
    }

    /// For tuning: the best-scoring blocks with their scores and where they sit.
    public static func diagnose(html: String) -> [String] {
        let root = buildTree(html)
        let body = root.descendants().first { $0.name == "body" } ?? root
        let before = body.descendants().filter { !$0.isText && isParagraphLike($0) && $0.innerText.count >= 25 }.count
        prune(body)
        let after = body.descendants().filter { !$0.isText && isParagraphLike($0) && $0.innerText.count >= 25 }.count
        var lines = ["paragraph-like blocks: \(before) before pruning, \(after) after"]
        let unpruned = buildTree(html)
        if let first = unpruned.descendants().first(where: { $0.name == "p" && $0.innerText.count > 100 }) {
            var chain: [String] = []
            var current = first.parent
            while let node = current, node.name != "#root" {
                let marker = node.marker.trimmingCharacters(in: .whitespaces)
                let dropped = droppedElements.contains(node.name) || isHidden(node)
                    || (!marker.isEmpty && unlikely.contains(where: marker.contains) && !maybeArticle.contains(where: marker.contains))
                chain.append((dropped ? "✗ " : "") + node.name + (marker.isEmpty ? "" : "." + marker.prefix(40)))
                current = node.parent
            }
            lines.append("first paragraph's ancestors: " + chain.joined(separator: " < "))
        }
        _ = pageArticle(html: html, url: nil)
        func path(_ node: Node) -> String {
            var parts: [String] = []
            var current: Node? = node
            while let n = current, n.name != "#root" {
                parts.append(n.name + (n.marker.trimmingCharacters(in: .whitespaces).isEmpty ? "" : "." + n.marker.prefix(24)))
                current = n.parent
            }
            return parts.reversed().suffix(5).joined(separator: " > ")
        }
        // Re-score on a fresh tree to report candidates.
        let fresh = buildTree(html)
        let freshBody = fresh.descendants().first { $0.name == "body" } ?? fresh
        prune(freshBody)
        var scored: [Node] = []
        for node in freshBody.descendants() where !node.isText && isParagraphLike(node) && node.innerText.count >= 25 {
            var ancestor = node.parent
            for level in 0..<5 {
                guard let current = ancestor else { break }
                if !current.scored { current.scored = true; current.score = baseScore(current) + classWeight(current); scored.append(current) }
                current.score += 1 / (level == 0 ? 1 : (level == 1 ? 2 : Double(level) * 3))
                ancestor = current.parent
            }
        }
        for node in scored.sorted(by: { $0.score > $1.score }).prefix(6) {
            lines.append(String(format: "%.1f (links %.2f, %d chars): ", node.score, node.linkDensity, node.innerText.count) + path(node))
        }
        return lines
    }

    static func isAncestor(_ ancestor: Node, of node: Node) -> Bool {
        var current = node.parent
        while let next = current {
            if next === ancestor { return true }
            current = next.parent
        }
        return false
    }

    /// Inside the article: drops link lists, empty wrappers and leftover chrome.
    static func clean(_ node: Node) {
        node.children.removeAll { child in
            guard !child.isText else { return false }
            if ["div", "ul", "ol", "section", "table"].contains(child.name) {
                let text = child.innerText.trimmingCharacters(in: .whitespacesAndNewlines)
                let images = child.descendants().contains { $0.name == "img" }
                if text.isEmpty && !images { return true }
                if child.linkDensity > 0.6 || (child.linkDensity > 0.5 && text.count < 240) { return true }
                if classWeight(child) < 0 && text.count < 300 { return true }
            }
            return false
        }
        for child in node.children where !child.isText { clean(child) }
    }

    static let keptTags: Set<String> = [
        "p", "br", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "blockquote", "pre", "code", "em", "i", "strong",
        "b", "a", "img", "figure", "figcaption", "picture", "source", "table", "thead", "tbody", "tr", "td", "th", "sup",
        "sub", "dl", "dt", "dd", "hr",
    ]

    static func serialize(_ node: Node, base: URL?) -> String {
        if node.isText { return escape(node.text) }
        let inner = node.children.map { serialize($0, base: base) }.joined()
        let name = ["div", "section", "article", "main"].contains(node.name) ? "div" : node.name
        guard keptTags.contains(name) || name == "div" else { return inner }  // span, font… unwrap
        var attributes: [(String, String)] = []
        switch name {
        case "a":
            if let href = node.attributes["href"], let resolved = resolve(href, base: base) { attributes.append(("href", resolved)) }
        case "img", "source":
            let lazy = node.attributes["data-src"] ?? node.attributes["data-original"] ?? node.attributes["data-lazy-src"]
            let src = node.attributes["src"].flatMap { $0.hasPrefix("data:") ? nil : $0 }
            if let chosen = lazy ?? src, let resolved = resolve(chosen, base: base) { attributes.append(("src", resolved)) }
            if let srcset = node.attributes["data-srcset"] ?? node.attributes["srcset"] {
                let resolved = srcset.split(separator: ",").compactMap { entry -> String? in
                    let parts = entry.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
                    guard let first = parts.first, let url = resolve(String(first), base: base) else { return nil }
                    return parts.count > 1 ? "\(url) \(parts[1])" : url
                }.joined(separator: ", ")
                if !resolved.isEmpty { attributes.append(("srcset", resolved)) }
            }
            if let alt = node.attributes["alt"] { attributes.append(("alt", alt)) }
            if name == "img" && attributes.first(where: { $0.0 == "src" || $0.0 == "srcset" }) == nil { return "" }
        default:
            break
        }
        let attributeText = attributes.map { " \($0.0)=\"\(escape($0.1, quotes: true))\"" }.joined()
        if voidElements.contains(name) { return "<\(name)\(attributeText)>" }
        return "<\(name)\(attributeText)>\(inner)</\(name)>"
    }

    static func resolve(_ link: String, base: URL?) -> String? {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.lowercased().hasPrefix("javascript:") else { return nil }
        return URL(string: trimmed, relativeTo: base)?.absoluteURL.absoluteString
    }

    static func escape(_ text: String, quotes: Bool = false) -> String {
        var result = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        if quotes { result = result.replacingOccurrences(of: "\"", with: "&quot;") }
        return result
    }

    // MARK: Structured data

    static func structuredArticle(html: String) -> Result? {
        var bodies: [String] = []
        var searchFrom = html.startIndex
        while let open = html.range(of: "<script", options: .caseInsensitive, range: searchFrom..<html.endIndex) {
            guard let tagEnd = html.range(of: ">", range: open.upperBound..<html.endIndex) else { break }
            let tag = html[open.upperBound..<tagEnd.lowerBound].lowercased()
            guard let close = html.range(of: "</script", options: .caseInsensitive, range: tagEnd.upperBound..<html.endIndex) else { break }
            if tag.contains("ld+json"), let data = String(html[tagEnd.upperBound..<close.lowerBound]).data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            {
                collectBodies(json, into: &bodies)
            }
            searchFrom = close.upperBound
        }
        guard let body = bodies.max(by: { $0.count < $1.count }), body.count >= 400 else { return nil }
        let text = HTMLText.decodeEntities(body)
        var paragraphs = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if paragraphs.count == 1, text.count > 1200 { paragraphs = groupSentences(text) }
        let html = paragraphs.map { "<p>\(escape($0))</p>" }.joined()
        return Result(html: html, wordCount: TextNormalizer.wordCount(text), source: .structuredData)
    }

    static func collectBodies(_ value: Any, into bodies: inout [String]) {
        if let object = value as? [String: Any] {
            if let body = object["articleBody"] as? String { bodies.append(body) }
            for nested in object.values { collectBodies(nested, into: &bodies) }
        } else if let array = value as? [Any] {
            for nested in array { collectBodies(nested, into: &bodies) }
        }
    }

    /// One long block of text becomes paragraphs of about four sentences.
    static func groupSentences(_ text: String) -> [String] {
        var paragraphs: [String] = []
        var current = ""
        var sentences = 0
        var previous: Character = " "
        for character in text {
            current.append(character)
            if character == " ", ".!?".contains(previous) {
                sentences += 1
                if sentences == 4 {
                    paragraphs.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                    sentences = 0
                }
            }
            previous = character
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { paragraphs.append(current.trimmingCharacters(in: .whitespaces)) }
        return paragraphs
    }
}

/// Downloads a page and runs `FullTextExtractor` on it. Transport is
/// injectable for tests; the default uses URLSession on the device.
public struct FullTextFetcher: Sendable {
    public struct Response: Sendable {
        public var data: Data
        public var status: Int
        public var url: URL?
        public var contentType: String?

        public init(data: Data, status: Int, url: URL?, contentType: String?) {
            self.data = data
            self.status = status
            self.url = url
            self.contentType = contentType
        }
    }

    public typealias Transport = @Sendable (URLRequest) async throws -> Response

    /// Pages that never hold article text (video, social) or only redirect with JavaScript.
    public static let unsupportedHosts = ["youtube.com", "youtu.be", "news.google.com", "x.com", "twitter.com", "vimeo.com",
                                          "tiktok.com", "instagram.com", "reddit.com"]

    private let transport: Transport

    public init(transport: @escaping Transport = FullTextFetcher.urlSession) { self.transport = transport }

    /// Feed links sometimes arrive with HTML-escaped ampersands.
    public static func cleaned(_ url: URL) -> URL {
        URL(string: url.absoluteString.replacingOccurrences(of: "&amp;", with: "&")) ?? url
    }

    public static func isSupported(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", let host = url.host?.lowercased() else {
            return false
        }
        return !unsupportedHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    public static func isVideo(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return false }
        return ["youtube.com", "youtu.be", "vimeo.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// The article on the page, or nil when there isn't one Folio can read.
    /// Background fetches (after a sync) stay off cellular and Low Data Mode.
    public func fetch(_ url: URL, background: Bool = false) async throws -> FullTextExtractor.Result? {
        guard Self.isSupported(url) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 20)
        #if canImport(Darwin)
        if background {
            request.allowsExpensiveNetworkAccess = false
            request.allowsConstrainedNetworkAccess = false
        }
        #endif
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        // Pages are fetched for Reader-style reading on the user's device, as Safari's Reader does.
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1 Folio/0.1",
                         forHTTPHeaderField: "User-Agent")
        let response = try await transport(request)
        guard response.status == 200, response.data.count <= 5_000_000,
              response.contentType.map({ $0.lowercased().contains("html") }) ?? true
        else { return nil }
        let html = Self.decode(response.data, contentType: response.contentType)
        return FullTextExtractor.extract(html: html, url: response.url ?? url)
    }

    static func decode(_ data: Data, contentType: String?) -> String {
        let declared = (contentType ?? "").lowercased()
        let head = String(decoding: data.prefix(2048), as: UTF8.self).lowercased()
        let latin = declared.contains("iso-8859-1") || declared.contains("windows-1252")
            || head.contains("charset=iso-8859-1") || head.contains("charset=\"iso-8859-1") || head.contains("charset=windows-1252")
        if !latin, let text = String(data: data, encoding: .utf8) { return text }
        return String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
    }

    public static let urlSession: Transport = { request in
        try await withCheckedThrowingContinuation { continuation in
            URLSession.shared.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    let http = response as? HTTPURLResponse
                    continuation.resume(returning: Response(data: data ?? Data(), status: http?.statusCode ?? 0, url: http?.url,
                                                            contentType: http?.value(forHTTPHeaderField: "Content-Type")))
                }
            }.resume()
        }
    }
}
