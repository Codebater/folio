import Foundation
import FolioCore

/// Turns publisher HTML into an `ArticleDocument`.
///
/// Only allow-listed structure survives: paragraphs, headings, quotes,
/// lists, preformatted text, images, rules, tables, embeds as links, and the
/// inline styles in `InlineStyle`. Scripts, styles, event handlers, forms,
/// tracking pixels and `javascript:` links are dropped. The renderer builds
/// fresh HTML from the document, so nothing from the original markup reaches
/// the web view verbatim.
public enum ArticleParser {
    public static func parse(
        html: String, baseURL: URL? = nil, title: String? = nil,
        languageGuesser: any LanguageGuessing = StopwordLanguageGuesser()
    ) -> ArticleDocument {
        let builder = DocumentBuilder(baseURL: baseURL)
        for token in HTMLTokenizer.tokenize(html) { builder.consume(token) }
        builder.flush()
        return builder.finish(title: title, languageGuesser: languageGuesser)
    }
}

final class DocumentBuilder {
    private struct OpenInline {
        let tag: String
        let style: InlineStyle
        var start: Int?
    }

    private struct ListContext {
        let ordered: Bool
        var counter: Int
    }

    private struct TableContext {
        var rows: [[String]] = []
        var row: [String]?
    }

    static let voidElements: Set<String> = [
        "br", "img", "hr", "wbr", "input", "meta", "link", "source", "area", "col", "embed", "param", "track", "base",
    ]
    static let skippedElements: Set<String> = [
        "nav", "form", "button", "select", "option", "svg", "math", "object", "canvas", "audio", "video", "map",
        "rt", "rp", "dialog", "menu", "label", "datalist", "head",
    ]
    static let blockElements: Set<String> = [
        "p", "div", "section", "article", "header", "footer", "main", "aside", "address", "details", "summary",
        "center", "dl", "dt", "dd", "hgroup", "body", "html", "picture", "figure",
    ]
    /// class/id fragments of share bars, related-post widgets and ad slots.
    static let boilerplateMarkers = [
        "sharedaddy", "share-buttons", "social-share", "sharing", "jp-relatedposts", "related-posts", "feedflare",
        "newsletter-signup", "advertisement", "ad-container", "ad-slot",
    ]

    private let baseURL: URL?
    private(set) var blocks: [Block] = []

    private var text = String.UnicodeScalarView()
    private var length = 0
    private var pendingSpace = false
    private var spans: [InlineSpan] = []
    private var openInline: [OpenInline] = []

    private var skipStack: [String] = []
    private var blockquoteDepth = 0
    private var lists: [ListContext] = []
    private var listItems: [BlockKind] = []
    private var headingLevel: Int?
    private var preDepth = 0
    private var figureImageIndex: [Int?] = []
    private var inCaption = false
    private var tableDepth = 0
    private var table = TableContext()

    init(baseURL: URL?) { self.baseURL = baseURL }

    // MARK: Tokens

    func consume(_ token: HTMLToken) {
        switch token {
        case .text(let value):
            guard skipStack.isEmpty else { return }
            if preDepth > 0 { appendPreformatted(value) } else { appendCollapsed(value) }
        case .startTag(let name, let attributes, let selfClosing):
            if !skipStack.isEmpty {
                if Self.skippedElements.contains(name) || isBoilerplate(attributes), !selfClosing, !Self.voidElements.contains(name) {
                    skipStack.append(name)
                } else if name == skipStack.last, !selfClosing, !Self.voidElements.contains(name) {
                    skipStack.append(name)
                }
                return
            }
            start(name, attributes, selfClosing: selfClosing)
        case .endTag(let name):
            if !skipStack.isEmpty {
                if let index = skipStack.lastIndex(of: name) { skipStack.removeSubrange(index...) }
                return
            }
            end(name)
        }
    }

    private func start(_ name: String, _ attributes: [String: String], selfClosing: Bool) {
        if Self.skippedElements.contains(name) {
            if name == "video" || name == "audio", let src = attributes["src"], let url = resolve(src, allowData: false) {
                addEmbed(url: url, title: name == "video" ? "Play video" : "Play audio")
            }
            if !selfClosing { skipStack.append(name) }
            return
        }
        if isBoilerplate(attributes), !Self.voidElements.contains(name), !selfClosing {
            skipStack.append(name)
            return
        }
        switch name {
        case "br":
            lineBreak()
        case "img":
            addImage(attributes)
        case "hr":
            flush()
            if case .rule? = blocks.last?.kind {} else if !blocks.isEmpty { blocks.append(Block(id: "", kind: .rule, text: "")) }
        case "iframe":
            if let src = attributes["src"], let url = resolve(src, allowData: false) { addEmbed(url: url, title: nil) }
        case "h1", "h2", "h3", "h4", "h5", "h6":
            flush()
            headingLevel = Int(String(name.dropFirst())) ?? 2
        case "blockquote":
            flush()
            blockquoteDepth += 1
        case "ul", "ol":
            flush()
            let start = Int(attributes["start"] ?? "") ?? 1
            lists.append(ListContext(ordered: name == "ol", counter: start - 1))
        case "li":
            flush()
            if lists.isEmpty { lists.append(ListContext(ordered: false, counter: 0)) }
            // An unclosed sibling <li> is closed implicitly.
            while listItems.count >= lists.count { listItems.removeLast() }
            lists[lists.count - 1].counter += 1
            let context = lists[lists.count - 1]
            listItems.append(.listItem(ordered: context.ordered, ordinal: context.counter, depth: lists.count - 1))
        case "pre":
            flush()
            preDepth += 1
        case "figure":
            flush()
            figureImageIndex.append(nil)
        case "figcaption":
            flush()
            inCaption = true
        case "table":
            flush()
            tableDepth += 1
            if tableDepth == 1 { table = TableContext() }
        case "tr":
            if tableDepth == 1 {
                if let row = table.row, !row.isEmpty { table.rows.append(row) }
                table.row = []
                resetText()
            }
        case "td", "th":
            if tableDepth == 1 {
                if table.row == nil { table.row = [] }
                resetText()
            } else {
                pendingSpace = !text.isEmpty
            }
        case "q":
            appendCollapsed("\u{201C}")
        default:
            if let style = inlineStyle(name, attributes) {
                openInline.append(OpenInline(tag: name, style: style, start: nil))
            } else if Self.blockElements.contains(name) || name == "p" {
                flush()
            }
        }
    }

    private func end(_ name: String) {
        switch name {
        case "h1", "h2", "h3", "h4", "h5", "h6":
            flush()
            headingLevel = nil
        case "blockquote":
            flush()
            blockquoteDepth = max(0, blockquoteDepth - 1)
        case "ul", "ol":
            flush()
            if !lists.isEmpty { lists.removeLast() }
            while listItems.count > lists.count { listItems.removeLast() }
        case "li":
            flush()
            if !listItems.isEmpty, listItems.count >= lists.count { listItems.removeLast() }
        case "pre":
            flush()
            preDepth = max(0, preDepth - 1)
        case "figcaption":
            let caption = takeText()
            inCaption = false
            if let caption {
                if let index = figureImageIndex.last ?? nil {
                    blocks[index].text = caption.text
                    blocks[index].spans = caption.spans
                } else {
                    blocks.append(Block(id: "", kind: .paragraph, text: caption.text, spans: caption.spans))
                }
            }
        case "figure":
            flush()
            if !figureImageIndex.isEmpty { figureImageIndex.removeLast() }
        case "td", "th":
            if tableDepth == 1 {
                table.row = (table.row ?? []) + [takeText()?.text ?? ""]
            }
        case "tr":
            if tableDepth == 1, let row = table.row {
                if !row.isEmpty { table.rows.append(row) }
                table.row = nil
            }
        case "table":
            if tableDepth == 1 { finishTable() }
            tableDepth = max(0, tableDepth - 1)
        case "q":
            appendCollapsed("\u{201D}")
        default:
            if let index = openInline.lastIndex(where: { $0.tag == name }) {
                let open = openInline.remove(at: index)
                if let start = open.start, start < length { spans.append(InlineSpan(start: start, end: length, style: open.style)) }
            } else if Self.blockElements.contains(name) || name == "p" {
                flush()
            }
        }
    }

    // MARK: Text

    private func push(_ scalar: Unicode.Scalar) {
        if scalar != " " && scalar != "\n" {
            for i in openInline.indices where openInline[i].start == nil { openInline[i].start = length }
        }
        text.append(scalar)
        length += scalar.utf16.count
    }

    private func appendCollapsed(_ value: String) {
        for scalar in value.precomposedStringWithCanonicalMapping.unicodeScalars {
            if TextNormalizer.isDroppable(scalar) { continue }
            if TextNormalizer.isCollapsibleWhitespace(scalar) {
                if !text.isEmpty && text.last != "\n" { pendingSpace = true }
                continue
            }
            if pendingSpace {
                push(" ")
                pendingSpace = false
            }
            push(scalar)
        }
    }

    private func appendPreformatted(_ value: String) {
        var normalized = value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if text.isEmpty, normalized.hasPrefix("\n") { normalized.removeFirst() }  // HTML drops the first newline in <pre>
        for scalar in normalized.unicodeScalars where !TextNormalizer.isDroppable(scalar) || scalar == "\t" {
            push(scalar)
        }
    }

    private func lineBreak() {
        if preDepth > 0 {
            push("\n")
            return
        }
        if tableDepth > 0 {
            pendingSpace = !text.isEmpty
            return
        }
        guard !text.isEmpty else { return }
        if text.last == "\n" {
            flush()  // <br><br> is a paragraph break in many feeds
        } else {
            pendingSpace = false
            push("\n")
        }
    }

    /// Ends the current text run and returns it with its spans, closing
    /// inline styles at the boundary (they continue in the next run).
    private func takeText() -> (text: String, spans: [InlineSpan])? {
        while let last = text.last, last == "\n" || last == " " {
            text.removeLast()
            length -= 1
        }
        for i in openInline.indices {
            if let start = openInline[i].start, start < length {
                spans.append(InlineSpan(start: start, end: length, style: openInline[i].style))
            }
            openInline[i].start = nil
        }
        let result = String(text)
        let resultSpans = spans
            .map { InlineSpan(start: $0.start, end: min($0.end, length), style: $0.style) }
            .filter { $0.start < $0.end }
        resetText()
        return result.unicodeScalars.contains(where: { !TextNormalizer.isCollapsibleWhitespace($0) && $0 != "\u{00A0}" })
            ? (result, resultSpans) : nil
    }

    private func resetText() {
        text.removeAll(keepingCapacity: true)
        length = 0
        pendingSpace = false
        spans.removeAll()
        for i in openInline.indices { openInline[i].start = nil }
    }

    func flush() {
        if tableDepth > 0 {
            pendingSpace = !text.isEmpty
            return
        }
        if inCaption { return }  // captions are collected until </figcaption>
        guard let run = takeText() else { return }
        blocks.append(Block(id: "", kind: currentKind(), text: run.text, spans: run.spans))
    }

    private func currentKind() -> BlockKind {
        if preDepth > 0 { return .preformatted }
        if let headingLevel { return .heading(level: headingLevel) }
        if let item = listItems.last { return item }
        if blockquoteDepth > 0 { return .quote }
        return .paragraph
    }

    // MARK: Media

    private func addImage(_ attributes: [String: String]) {
        guard let url = imageURL(attributes), !isTrackingPixel(attributes, url) else { return }
        if tableDepth == 0 { flush() }
        if case .image(let info)? = blocks.last?.kind, info.source == url { return }
        let info = ImageInfo(
            source: url, alt: TextNormalizer.normalize(attributes["alt"] ?? ""),
            width: attributes["width"].flatMap { Int($0) }, height: attributes["height"].flatMap { Int($0) })
        blocks.append(Block(id: "", kind: .image(info), text: ""))
        if !figureImageIndex.isEmpty { figureImageIndex[figureImageIndex.count - 1] = blocks.count - 1 }
    }

    private func imageURL(_ attributes: [String: String]) -> URL? {
        let srcset = attributes["srcset"] ?? attributes["data-srcset"]
        if let srcset, let best = Self.bestCandidate(srcset), let url = resolve(best, allowData: false) { return url }
        let src = attributes["src"] ?? ""
        let isPlaceholder = src.isEmpty || (src.hasPrefix("data:image/gif") && src.count < 200)
        for key in ["data-src", "data-lazy-src", "data-original", "data-url"] where isPlaceholder {
            if let value = attributes[key], let url = resolve(value, allowData: false) { return url }
        }
        return isPlaceholder ? nil : resolve(src, allowData: true)
    }

    /// Picks the widest candidate up to 1600w (or the highest density).
    static func bestCandidate(_ srcset: String) -> String? {
        var best: (url: String, score: Double)?
        for candidate in srcset.split(separator: ",") {
            let parts = candidate.split(whereSeparator: \.isWhitespace)
            guard let url = parts.first else { continue }
            var score = 1.0
            if parts.count > 1 {
                let descriptor = parts[1]
                if descriptor.hasSuffix("w"), let width = Double(descriptor.dropLast()) {
                    // Oversized candidates rank below every one within the limit, smallest first.
                    score = width <= 1600 ? width : -width
                } else if descriptor.hasSuffix("x"), let density = Double(descriptor.dropLast()) {
                    score = density * 1000
                }
            }
            if best == nil || score > best!.score { best = (String(url), score) }
        }
        return best?.url
    }

    private func isTrackingPixel(_ attributes: [String: String], _ url: URL) -> Bool {
        let width = attributes["width"].flatMap { Int($0) }
        let height = attributes["height"].flatMap { Int($0) }
        if let width, width <= 2 { return true }
        if let height, height <= 2 { return true }
        let text = url.absoluteString.lowercased()
        return ["feeds.feedburner.com/~r/", "/~ff/", "pixel.wp.com", "stats.wordpress.com", "doubleclick.net",
                "/pixel.gif", "/tracking/", "beacon."].contains { text.contains($0) }
    }

    private func addEmbed(url: URL, title: String?) {
        if tableDepth == 0 { flush() }
        let (link, label) = Self.embedLink(for: url)
        blocks.append(Block(id: "", kind: .embed(url: link), text: title ?? label))
    }

    static func embedLink(for url: URL) -> (URL, String) {
        let host = (url.host ?? "").lowercased()
        let parts = url.path.split(separator: "/")
        if host.contains("youtube.com") || host.contains("youtube-nocookie.com"), parts.count >= 2, parts[0] == "embed",
           let watch = URL(string: "https://www.youtube.com/watch?v=\(parts[1])")
        {
            return (watch, "Watch on YouTube")
        }
        if host == "player.vimeo.com", parts.count >= 2, parts[0] == "video", let watch = URL(string: "https://vimeo.com/\(parts[1])") {
            return (watch, "Watch on Vimeo")
        }
        return (url, "Open embedded content")
    }

    private func finishTable() {
        if let row = table.row, !row.isEmpty { table.rows.append(row) }
        let rows = table.rows.filter { $0.contains { !$0.isEmpty } }
        table = TableContext()
        resetText()
        guard !rows.isEmpty else { return }
        if rows.allSatisfy({ $0.count <= 1 }) {
            // Single-column tables are layout, not data: keep the text as paragraphs.
            for row in rows where !(row.first ?? "").isEmpty {
                blocks.append(Block(id: "", kind: .paragraph, text: row[0]))
            }
        } else {
            blocks.append(Block(id: "", kind: .table(rows: rows), text: rows.map { $0.joined(separator: " · ") }.joined(separator: "\n")))
        }
    }

    // MARK: Helpers

    private func inlineStyle(_ name: String, _ attributes: [String: String]) -> InlineStyle? {
        switch name {
        case "em", "i", "cite", "dfn", "var": return .emphasis
        case "strong", "b": return .strong
        case "code", "kbd", "samp", "tt": return preDepth > 0 ? nil : .code
        case "sup": return .superscript
        case "sub": return .subscript
        case "s", "strike", "del": return .strikethrough
        case "mark": return .mark
        case "a":
            guard let href = attributes["href"], !href.hasPrefix("#"),
                  let url = resolve(href, allowData: false), ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "")
            else { return nil }
            return .link(url)
        default: return nil
        }
    }

    private func isBoilerplate(_ attributes: [String: String]) -> Bool {
        let marker = ((attributes["class"] ?? "") + " " + (attributes["id"] ?? "")).lowercased()
        guard marker.count > 1 else { return false }
        return Self.boilerplateMarkers.contains { marker.contains($0) }
    }

    private func resolve(_ raw: String, allowData: Bool) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("data:") {
            guard allowData, lower.hasPrefix("data:image/") else { return nil }
            return URL(string: trimmed)
        }
        if lower.hasPrefix("javascript:") || lower.hasPrefix("vbscript:") || lower.hasPrefix("file:") { return nil }
        if trimmed.hasPrefix("//") { return URL(string: (baseURL?.scheme ?? "https") + ":" + trimmed) }
        let escaped = trimmed.replacingOccurrences(of: " ", with: "%20")
        if let url = URL(string: escaped, relativeTo: baseURL)?.absoluteURL, url.scheme != nil { return url }
        return nil
    }

    // MARK: Finish

    func finish(title: String?, languageGuesser: any LanguageGuessing) -> ArticleDocument {
        var result = blocks
        // Feeds often repeat the headline as the first line.
        if let title, let first = result.firstIndex(where: \.isTextual),
           Self.comparable(result[first].text) == Self.comparable(title)
        {
            result.remove(at: first)
        }
        while case .rule? = result.first?.kind { result.removeFirst() }
        while case .rule? = result.last?.kind { result.removeLast() }
        for i in result.indices { result[i].id = "b\(i)" }

        let textual = result.filter(\.isTextual)
        let wordCount = textual.reduce(0) { $0 + TextNormalizer.wordCount($1.text) }
        let leadImage = result.lazy.compactMap { block -> URL? in
            if case .image(let info) = block.kind { return info.source }
            return nil
        }.first
        let sample = ArticleLanguage.prose(String(result.filter(\.isSpeakable).map(\.text).joined(separator: " ").prefix(3000)))
        // A weak guess on a short summary is worse than none: it picks the
        // voice. Links and numbers don't count as words for it.
        let guess = TextNormalizer.wordCount(sample) >= ArticleLanguage.minimumWords ? languageGuesser.guess(sample) : nil
        return ArticleDocument(
            blocks: result, language: guess.flatMap { $0.confidence >= 0.5 ? $0.language : nil }, wordCount: wordCount,
            leadImageURL: leadImage, excerpt: Self.excerpt(from: result))
    }

    static func comparable(_ s: String) -> String {
        TextNormalizer.normalize(s).lowercased().filter { $0.isLetter || $0.isNumber }
    }

    static func excerpt(from blocks: [Block], limit: Int = 280) -> String {
        var pieces: [String] = []
        var total = 0
        for block in blocks where block.isSpeakable {
            if case .heading = block.kind { continue }
            pieces.append(block.text.replacingOccurrences(of: "\n", with: " "))
            total += block.text.count
            if total >= limit { break }
        }
        let joined = pieces.joined(separator: " ")
        guard joined.count > limit else { return joined }
        let cut = joined.prefix(limit)
        let end = cut.lastIndex(where: \.isWhitespace) ?? cut.endIndex
        return String(cut[..<end]).trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)) + "…"
    }
}
