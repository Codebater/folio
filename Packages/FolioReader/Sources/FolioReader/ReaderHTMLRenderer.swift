import Foundation
import FolioCore

/// What the page header and footer show. The app passes already-localized
/// strings (dates, reading time) so this stays free of locale logic.
public struct ReaderPageMetadata: Sendable, Hashable {
    public var title: String
    public var siteName: String
    public var author: String?
    public var dateText: String?
    public var readingTimeText: String?
    public var originalURL: URL?
    /// Shown in a "Key points" box under the title, when set.
    public var keyPoints: [String]
    public var keyPointsLabel: String

    public init(title: String, siteName: String, author: String? = nil, dateText: String? = nil,
                readingTimeText: String? = nil, originalURL: URL? = nil, keyPoints: [String] = [],
                keyPointsLabel: String = "Key points") {
        self.title = title
        self.siteName = siteName
        self.author = author
        self.dateText = dateText
        self.readingTimeText = readingTimeText
        self.originalURL = originalURL
        self.keyPoints = keyPoints
        self.keyPointsLabel = keyPointsLabel
    }
}

/// Builds the reader page from an `ArticleDocument`.
///
/// Security model: the page only ever contains markup generated here from
/// the allow-listed document, a Content-Security-Policy without any script
/// source, and (in the app) WebKit's `allowsContentJavaScript = false`. The
/// reader script is injected by the app into an isolated content world. Only
/// the browser preview build inlines the script, guarded by a CSP nonce.
public struct ReaderHTMLRenderer: Sendable {
    public enum ScriptMode: Sendable, Hashable {
        /// The app injects `ReaderAssets.script` itself (WKUserScript).
        case injectedByHost
        /// Inline the script for previewing the page in a desktop browser.
        case inlineForPreview(nonce: String)
    }

    public var settings: ReaderSettings
    public var scriptMode: ScriptMode
    /// Rewrites image URLs, e.g. to the app's offline cache scheme. When set,
    /// the CSP only allows that scheme and `data:`, so the page never contacts
    /// image hosts directly.
    public var imageURLRewriter: (@Sendable (URL) -> String)?
    public var imageScheme: String?

    public init(settings: ReaderSettings, scriptMode: ScriptMode = .injectedByHost,
                imageScheme: String? = nil, imageURLRewriter: (@Sendable (URL) -> String)? = nil) {
        self.settings = settings
        self.scriptMode = scriptMode
        self.imageScheme = imageScheme
        self.imageURLRewriter = imageURLRewriter
    }

    public func render(_ document: ArticleDocument, metadata: ReaderPageMetadata) -> String {
        var html = "<!doctype html>\n<html lang=\"\(escape(document.language?.rawValue ?? "en"))\""
        if settings.layout == .paginated { html += " class=\"f-paged\"" }
        html += "><head><meta charset=\"utf-8\">"
        html += "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1, viewport-fit=cover\">"
        html += "<meta http-equiv=\"Content-Security-Policy\" content=\"\(escape(contentSecurityPolicy))\">"
        html += "<meta name=\"referrer\" content=\"no-referrer\">"
        html += "<title>\(escape(metadata.title))</title>"
        html += "<style>:root{\(Self.cssVariables(for: settings))}\n\(ReaderAssets.css)</style></head><body>"
        html += "<article id=\"f-article\">"
        html += header(metadata)
        for block in document.blocks { html += render(block) }
        html += footer(metadata)
        html += "</article>"
        if case .inlineForPreview(let nonce) = scriptMode {
            html += "<script nonce=\"\(escape(nonce))\">\(ReaderAssets.script)</script>"
        }
        html += "</body></html>"
        return html
    }

    var contentSecurityPolicy: String {
        let images: String
        if let imageScheme { images = "\(imageScheme): data:" } else { images = "https: http: data:" }
        var policy = "default-src 'none'; img-src \(images); style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'"
        if case .inlineForPreview(let nonce) = scriptMode { policy += "; script-src 'nonce-\(nonce)'" }
        return policy
    }

    /// CSS custom properties for the theme and typography; the reader script
    /// updates these in place when settings change.
    public static func cssVariables(for settings: ReaderSettings) -> String {
        let t = settings.theme
        let ty = settings.typography.clamped()
        let vars: [(String, String)] = [
            ("--bg", t.background.hex), ("--fg", t.text.hex), ("--fg2", t.secondaryText.hex), ("--accent", t.accent.hex),
            ("--word", t.spokenWord.hex), ("--block", t.spokenBlock.hex), ("--font", ty.font.cssStack),
            ("--size", "\(format(ty.fontSize))px"), ("--lh", format(ty.lineHeight)), ("--margin", "\(format(ty.margin))px"),
            ("--ls", "\(format(ty.letterSpacing))em"), ("--align", ty.justify ? "justify" : "start"),
            ("--hyphens", ty.hyphenate ? "auto" : "manual"), ("color-scheme", t.isDark ? "dark" : "light"),
        ]
        return vars.map { "\($0.0):\($0.1)" }.joined(separator: ";")
    }

    static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.3f", value)
            .replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
    }

    // MARK: Blocks

    private func header(_ m: ReaderPageMetadata) -> String {
        var html = "<header class=\"f-head\">"
        html += "<p class=\"f-site\">\(escape(m.siteName))</p>"
        html += "<h1 class=\"f-title\" id=\"title\" data-b=\"title\">\(escape(m.title))</h1>"
        let meta = [m.author.map { "By \($0)" }, m.dateText, m.readingTimeText].compactMap { $0 }.filter { !$0.isEmpty }
        if !meta.isEmpty { html += "<p class=\"f-meta\">\(meta.map(escape).joined(separator: " · "))</p>" }
        if !m.keyPoints.isEmpty {
            // A native disclosure: opens and closes without any script.
            html += "<details class=\"f-points\" open><summary>\(escape(m.keyPointsLabel))</summary><ul>"
            html += m.keyPoints.map { "<li>\(escape($0))</li>" }.joined()
            html += "</ul></details>"
        }
        return html + "</header>"
    }

    private func footer(_ m: ReaderPageMetadata) -> String {
        var html = "<footer class=\"f-foot\">"
        if let url = m.originalURL {
            let host = url.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? url.absoluteString
            html += "<p><a class=\"f-original\" href=\"\(escape(url.absoluteString))\">Read the original on \(escape(host))</a></p>"
        }
        html += "<p>Published by \(escape(m.siteName)). All rights belong to the publisher.</p>"
        return html + "</footer>"
    }

    func render(_ block: Block) -> String {
        let id = escape(block.id)
        switch block.kind {
        case .paragraph:
            return "<p id=\"\(id)\" data-b=\"\(id)\">\(inline(block))</p>"
        case .heading(let level):
            // The article title is the page's h1, so content headings start at h2.
            let tag = "h\(min(max(level, 1) + 1, 4))"
            return "<\(tag) class=\"f-h\" id=\"\(id)\" data-b=\"\(id)\">\(inline(block))</\(tag)>"
        case .quote:
            return "<blockquote class=\"f-quote\" id=\"\(id)\" data-b=\"\(id)\">\(inline(block))</blockquote>"
        case .listItem(let ordered, let ordinal, let depth):
            let cls = ordered ? "f-li f-ol" : "f-li"
            return "<p class=\"\(cls)\" id=\"\(id)\" data-b=\"\(id)\" data-n=\"\(ordinal)\" data-depth=\"\(min(depth, 3))\">\(inline(block))</p>"
        case .preformatted:
            return "<pre class=\"f-pre\" id=\"\(id)\" data-b=\"\(id)\">\(escape(block.text))</pre>"
        case .image(let info):
            var html = "<figure class=\"f-img\" id=\"\(id)\" data-b=\"\(id)\"><img src=\"\(escape(imageSource(info.source)))\""
            html += " alt=\"\(escape(info.alt))\" loading=\"lazy\" decoding=\"async\""
            if let w = info.width, let h = info.height, w > 0, h > 0 { html += " width=\"\(w)\" height=\"\(h)\"" }
            html += ">"
            if !block.text.isEmpty { html += "<figcaption>\(inline(block))</figcaption>" }
            return html + "</figure>"
        case .rule:
            return "<div class=\"f-rule\" id=\"\(id)\" role=\"separator\"></div>"
        case .embed(let url):
            let host = url.host ?? ""
            return "<a class=\"f-embed\" id=\"\(id)\" data-b=\"\(id)\" href=\"\(escape(url.absoluteString))\">"
                + "<span class=\"f-embed-icon\" aria-hidden=\"true\">\u{25B6}\u{FE0E}</span>"
                + "<span class=\"f-embed-title\">\(escape(block.text))</span><span class=\"f-embed-host\">\(escape(host))</span></a>"
        case .table(let rows):
            var html = "<div class=\"f-table\" id=\"\(id)\"><table>"
            for (r, row) in rows.enumerated() {
                html += "<tr>"
                for cell in row { html += r == 0 ? "<th>\(escape(cell))</th>" : "<td>\(escape(cell))</td>" }
                html += "</tr>"
            }
            return html + "</table></div>"
        }
    }

    private func imageSource(_ url: URL) -> String {
        if url.scheme?.lowercased() == "data" { return url.absoluteString }
        return imageURLRewriter?(url) ?? url.absoluteString
    }

    /// Text with inline spans as well-formed nested tags. Text nodes are
    /// emitted exactly as `Block.text` (newlines as `<br>`), which keeps the
    /// UTF-16 offsets the reader script computes identical to Swift's.
    func inline(_ block: Block) -> String {
        let units = Array(block.text.utf16)
        guard !block.spans.isEmpty else { return escapeUnits(units[...]) }
        let spans = block.spans.filter { $0.start < $0.end && $0.start >= 0 && $0.end <= units.count }
        var boundaries = Set([0, units.count])
        for span in spans {
            boundaries.insert(span.start)
            boundaries.insert(span.end)
        }
        let points = boundaries.sorted()
        var html = ""
        var stack: [InlineSpan] = []
        for (a, b) in zip(points, points.dropFirst()) {
            // Active spans for this segment, outermost (earliest, longest) first.
            let active = spans.filter { $0.start <= a && $0.end >= b }
                .sorted { ($0.start, -$0.end) < ($1.start, -$1.end) }
            var common = 0
            while common < stack.count, common < active.count, stack[common] == active[common] { common += 1 }
            while stack.count > common { html += closeTag(stack.removeLast().style) }
            for span in active[common...] {
                html += openTag(span.style)
                stack.append(span)
            }
            html += escapeUnits(units[a..<b])
        }
        while let span = stack.popLast() { html += closeTag(span.style) }
        return html
    }

    private func openTag(_ style: InlineStyle) -> String {
        switch style {
        case .emphasis: "<em>"
        case .strong: "<strong>"
        case .code: "<code>"
        case .link(let url): "<a href=\"\(escape(url.absoluteString))\">"
        case .superscript: "<sup>"
        case .subscript: "<sub>"
        case .strikethrough: "<s>"
        case .mark: "<mark>"
        }
    }

    private func closeTag(_ style: InlineStyle) -> String {
        switch style {
        case .emphasis: "</em>"
        case .strong: "</strong>"
        case .code: "</code>"
        case .link: "</a>"
        case .superscript: "</sup>"
        case .subscript: "</sub>"
        case .strikethrough: "</s>"
        case .mark: "</mark>"
        }
    }

    private func escapeUnits(_ units: ArraySlice<UInt16>) -> String {
        escape(String(decoding: units, as: UTF16.self)).replacingOccurrences(of: "\n", with: "<br>")
    }

    func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for c in s.unicodeScalars {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.unicodeScalars.append(c)
            }
        }
        return out
    }
}
