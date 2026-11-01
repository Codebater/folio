import Foundation
import Testing
import FolioCore
@testable import FolioReader

func parse(_ html: String, base: String? = "https://site.example/posts/1", title: String? = nil) -> ArticleDocument {
    ArticleParser.parse(html: html, baseURL: base.flatMap(URL.init(string:)), title: title)
}

@Suite("Article parsing")
struct ParserTests {
    @Test func buildsParagraphsAndHeadingsWithStableIDs() {
        let doc = parse("<h2>Intro</h2><p>First  paragraph.</p>\n<p>Second\nparagraph.</p>")
        #expect(doc.blocks.map(\.id) == ["b0", "b1", "b2"])
        #expect(doc.blocks[0].kind == .heading(level: 2))
        #expect(doc.blocks.map(\.text) == ["Intro", "First paragraph.", "Second paragraph."])
    }

    @Test func collapsesWhitespaceAcrossInlineTags() {
        let doc = parse("<p>  Hello <em> wide </em>  <strong>world</strong> !</p>")
        #expect(doc.blocks[0].text == "Hello wide world !")
        let em = doc.blocks[0].spans.first { $0.style == .emphasis }
        #expect(em.map { $0.start..<$0.end } == 6..<10)  // "wide", no surrounding spaces
    }

    @Test func dropsScriptsStylesAndHandlers() {
        let doc = parse("""
            <p onclick="steal()">Safe <b>text</b></p><script>alert(1)</script><style>p{}</style>
            <p>More<img src="x.png" onerror="alert(2)" width="300" height="200"></p>
            """)
        #expect(doc.blocks.map(\.text).joined(separator: "|") == "Safe text|More|")
        let rendered = ReaderHTMLRenderer(settings: ReaderSettings()).render(doc, metadata: ReaderPageMetadata(title: "T", siteName: "S"))
        #expect(!rendered.contains("alert"))
        #expect(!rendered.contains("onclick"))
        #expect(!rendered.contains("onerror"))
        #expect(!rendered.lowercased().contains("<script"))
    }

    @Test func removesJavascriptLinksButKeepsText() {
        let doc = parse(#"<p>Click <a href="javascript:evil()">here</a> or <a href="/about">about</a>.</p>"#)
        #expect(doc.blocks[0].text == "Click here or about.")
        #expect(doc.blocks[0].spans == [InlineSpan(start: 14, end: 19, style: .link(URL(string: "https://site.example/about")!))])
    }

    @Test func dropsTrackingPixelsAndResolvesImages() {
        let doc = parse("""
            <p><img src="https://feeds.feedburner.com/~r/x/~4/abc" width="1" height="1">Text</p>
            <img src="//cdn.example/photo.jpg" alt=" A  photo ">
            <img src="data:image/gif;base64,R0lGOD" data-src="/lazy.jpg">
            <img srcset="/s.jpg 400w, /m.jpg 1200w, /xl.jpg 3000w" src="/fallback.jpg">
            """)
        let images = doc.blocks.compactMap { block -> ImageInfo? in
            if case .image(let info) = block.kind { return info }
            return nil
        }
        #expect(images.map(\.source.absoluteString) == [
            "https://cdn.example/photo.jpg", "https://site.example/lazy.jpg", "https://site.example/m.jpg",
        ])
        #expect(images[0].alt == "A photo")
        #expect(doc.leadImageURL?.absoluteString == "https://cdn.example/photo.jpg")
    }

    @Test func attachesFigureCaptions() {
        let doc = parse(#"<figure><img src="/a.jpg"><figcaption>The <em>caption</em></figcaption></figure><p>After</p>"#)
        #expect(doc.blocks.count == 2)
        #expect(doc.blocks[0].text == "The caption")
        #expect(!doc.blocks[0].isSpeakable)
    }

    @Test func parsesListsWithDepthAndOrdinals() {
        let doc = parse("<ol start='3'><li>Three<ul><li>Nested</li></ul></li><li>Four</ol><ul><li>Dot")
        #expect(doc.blocks.map(\.kind) == [
            .listItem(ordered: true, ordinal: 3, depth: 0), .listItem(ordered: false, ordinal: 1, depth: 1),
            .listItem(ordered: true, ordinal: 4, depth: 0), .listItem(ordered: false, ordinal: 1, depth: 0),
        ])
        #expect(doc.blocks.map(\.text) == ["Three", "Nested", "Four", "Dot"])
    }

    @Test func keepsPreformattedWhitespace() {
        let doc = parse("<pre><code>\nlet x = 1\n  if x { }\n</code></pre>")
        #expect(doc.blocks[0].kind == .preformatted)
        #expect(doc.blocks[0].text == "let x = 1\n  if x { }")
        #expect(!doc.blocks[0].isSpeakable)
    }

    @Test func handlesLineBreaks() {
        let doc = parse("<p>Line one<br>line two<br/><br>New para</p>")
        #expect(doc.blocks.map(\.text) == ["Line one\nline two", "New para"])
    }

    @Test func quotesAndEntities() {
        let doc = parse("<blockquote><p>It&#8217;s &ldquo;fine&rdquo; &amp; calm</p></blockquote><p>He said <q>hi</q>.</p>")
        #expect(doc.blocks[0].kind == .quote)
        #expect(doc.blocks[0].text == "It\u{2019}s \u{201C}fine\u{201D} & calm")
        #expect(doc.blocks[1].text == "He said \u{201C}hi\u{201D}.")
    }

    @Test func turnsEmbedsIntoLinks() {
        let doc = parse(#"<iframe src="https://www.youtube.com/embed/abc123" width="560"></iframe>"#)
        #expect(doc.blocks[0].kind == .embed(url: URL(string: "https://www.youtube.com/watch?v=abc123")!))
        #expect(doc.blocks[0].text == "Watch on YouTube")
    }

    @Test func dropsDuplicateTitleAndBoilerplate() {
        let doc = parse(#"<h1>My Title</h1><p>Body</p><div class="sharedaddy"><p>Share this</p></div><nav>Menu</nav>"#,
                        title: "My title")
        #expect(doc.blocks.map(\.text) == ["Body"])
    }

    @Test func tablesBecomeDataOrParagraphs() {
        let data = parse("<table><tr><th>A</th><th>B</th></tr><tr><td>1</td><td>2</td></tr></table>")
        #expect(data.blocks[0].kind == .table(rows: [["A", "B"], ["1", "2"]]))
        let layout = parse("<table><tr><td><p>Just text</p></td></tr><tr><td>More</td></tr></table>")
        #expect(layout.blocks.map(\.text) == ["Just text", "More"])
    }

    @Test func survivesMalformedMarkup() {
        let doc = parse("<p>Unclosed <b>bold <i>both</p><p>next</b> after</i><div><<>> & </div><!-- c --><p>end")
        #expect(doc.blocks.map(\.text) == ["Unclosed bold both", "next after", "<<>> &", "end"])
        for block in doc.blocks {
            for span in block.spans { #expect(span.start < span.end && span.end <= block.text.utf16Length) }
        }
    }

    @Test func computesExcerptWordCountLanguage() {
        let doc = parse("<p>The measure is the length of a line, and it matters more than the typeface you pick for a book.</p>")
        #expect(doc.wordCount == 20)
        #expect(doc.language == .english)
        #expect(doc.excerpt.hasPrefix("The measure"))
    }

    @Test func offsetsAreUTF16() {
        let doc = parse("<p>Emoji \u{1F600} <b>bold</b></p>")
        let bold = doc.blocks[0].spans[0]
        #expect(doc.blocks[0].text.utf16Slice(bold.start..<bold.end) == "bold")
        #expect(bold.start == 9)  // "Emoji " (6) + emoji (2) + " " (1)
    }
}

@Suite("Rendering")
struct RendererTests {
    let renderer = ReaderHTMLRenderer(settings: ReaderSettings())

    /// The text a browser would see inside an element: tags removed, <br>
    /// as "\n", entities decoded. Must equal `Block.text` for offsets to match.
    func visibleText(of html: String) -> String {
        var s = html.replacingOccurrences(of: "<br>", with: "\n")
        while let open = s.firstIndex(of: "<"), let close = s[open...].firstIndex(of: ">") { s.removeSubrange(open...close) }
        return HTMLText.decodeEntities(s)
    }

    @Test func renderedTextMatchesBlockText() {
        let doc = parse("""
            <p>A <b>bold <i>and italic</i></b> mix &amp; <a href="/x">a link</a>, then <code>code</code>.</p>
            <p>Line<br>break with <sup>sup</sup> &lt;tags&gt; &quot;quotes&quot;</p>
            """)
        for block in doc.blocks {
            let html = renderer.render(block)
            let inner = html.drop { $0 != ">" }.dropFirst()
            let body = String(inner[..<inner.range(of: "</", options: .backwards)!.lowerBound])
            #expect(visibleText(of: body) == block.text)
        }
    }

    @Test func nestsOverlappingSpansWellFormed() {
        let block = Block(id: "b0", kind: .paragraph, text: "abcdef", spans: [
            InlineSpan(start: 0, end: 4, style: .strong), InlineSpan(start: 2, end: 6, style: .emphasis),
        ])
        #expect(renderer.inline(block) == "<strong>ab<em>cd</em></strong><em>ef</em>")
    }

    @Test func escapesEverything() {
        let block = Block(id: "b0", kind: .paragraph, text: "<script>\"x\" & 'y'</script>")
        #expect(renderer.inline(block) == "&lt;script&gt;&quot;x&quot; &amp; &#39;y&#39;&lt;/script&gt;")
    }

    @Test func pageHasStrictPolicyAndAttribution() {
        let doc = parse("<p>Hi</p>")
        let meta = ReaderPageMetadata(title: "T & U", siteName: "Site", author: "Ana", dateText: "Oct 31",
                                      readingTimeText: "1 min", originalURL: URL(string: "https://www.site.example/p"))
        let app = ReaderHTMLRenderer(settings: ReaderSettings(), imageScheme: "folio-image") { "folio-image://x?u=\($0.absoluteString)" }
            .render(doc, metadata: meta)
        let escapedPolicy = "default-src &#39;none&#39;; img-src folio-image: data:; style-src &#39;unsafe-inline&#39;"
        #expect(app.contains("http-equiv=\"Content-Security-Policy\" content=\"\(escapedPolicy)"))
        #expect(!app.contains("script-src"))
        #expect(!app.contains("<script"))
        #expect(app.contains("Read the original on site.example"))
        #expect(app.contains("<h1 class=\"f-title\" id=\"title\" data-b=\"title\">T &amp; U</h1>"))

        let preview = ReaderHTMLRenderer(settings: ReaderSettings(), scriptMode: .inlineForPreview(nonce: "abc")).render(doc, metadata: meta)
        #expect(preview.contains("script-src &#39;nonce-abc&#39;"))
        #expect(preview.contains("<script nonce=\"abc\">"))
    }

    @Test func rewritesImagesExceptDataURIs() {
        let r = ReaderHTMLRenderer(settings: ReaderSettings(), imageScheme: "folio-image") { _ in "folio-image://cached" }
        let remote = Block(id: "b1", kind: .image(ImageInfo(source: URL(string: "https://x/a.jpg")!)), text: "")
        let inline = Block(id: "b2", kind: .image(ImageInfo(source: URL(string: "data:image/png;base64,AAAA")!)), text: "")
        #expect(r.render(remote).contains("src=\"folio-image://cached\""))
        #expect(r.render(inline).contains("src=\"data:image/png;base64,AAAA\""))
    }

    @Test func themeVariablesAndPagedClass() {
        var settings = ReaderSettings(theme: .oledBlack, layout: .paginated)
        settings.typography.fontSize = 99  // clamped
        let html = ReaderHTMLRenderer(settings: settings).render(parse("<p>x</p>"), metadata: ReaderPageMetadata(title: "t", siteName: "s"))
        #expect(html.contains("class=\"f-paged\""))
        #expect(html.contains("--bg:#000000"))
        #expect(html.contains("--size:32px"))
    }
}

@Suite("Themes and settings")
struct ThemeTests {
    @Test func builtInThemesAreReadable() {
        for theme in ReadingTheme.builtIn {
            #expect(theme.text.contrast(with: theme.background) >= 7, "\(theme.name) body text below WCAG AAA")
            #expect(theme.secondaryText.contrast(with: theme.background) >= 3, "\(theme.name) secondary text too faint")
        }
    }

    @Test func appColoursKeepTextReadable() {
        let white = ThemeColor("#FFFFFF")
        let keys = ["mix", "topic:design", "language:de", "source:42", "The Verge", "Ünïcode Daily"]
        for theme in ReadingTheme.builtIn {
            #expect(theme.surface != theme.background, "\(theme.name) cards don't stand out")
            #expect(theme.text.contrast(with: theme.surface) >= 7, "\(theme.name) text on cards below WCAG AAA")
            #expect(theme.text.contrast(with: theme.spokenWord) >= 4.5, "\(theme.name) spoken word below WCAG AA")
            #expect(theme.accent.contrast(with: theme.background) >= 4.5, "\(theme.name) accent text below WCAG AA")
            var bottoms: Set<ThemeColor> = []
            for key in keys {
                let art = theme.artwork(for: key)
                #expect(white.contrast(with: art.bottom) >= 4.5, "\(theme.name) artwork \(key) too light for white text")
                #expect(theme.artwork(for: key).top == art.top, "artwork must be stable per key")
                bottoms.insert(art.bottom)
            }
            #expect(bottoms.count >= 3, "\(theme.name) artwork has too little variety")
        }
    }

    @Test func colourConversions() {
        #expect(ThemeColor(hue: 0, saturation: 1, brightness: 1) == ThemeColor("#FF0000"))
        #expect(ThemeColor(hue: 1.0 / 3, saturation: 1, brightness: 1) == ThemeColor("#00FF00"))
        #expect(ThemeColor(hue: 2.0 / 3 + 1, saturation: 1, brightness: 1) == ThemeColor("#0000FF"))  // hue wraps
        #expect(abs(ThemeColor("#00FF00").hue - 1.0 / 3) < 0.001)
        #expect(ThemeColor("#808080").hue == 0)
        #expect(ThemeColor("#000000").mixed(with: ThemeColor("#FFFFFF"), 0.5) == ThemeColor("#808080"))
    }

    @Test func savedBuiltInThemeUsesCurrentPalette() {
        var old = ReadingTheme.warmPaper
        old.background = ThemeColor("#F6EFE3")  // Warm Paper before it was brightened
        let settings = ReaderSettings(theme: old, automaticThemes: nil)
        #expect(settings.effectiveTheme(systemIsDark: true) == .warmPaper)
        var custom = old
        custom.id = "my-theme"
        #expect(ReaderSettings(theme: custom, automaticThemes: nil).effectiveTheme(systemIsDark: false) == custom)
    }

    @Test func premiumGating() {
        var settings = ReaderSettings()
        settings.typography.font = .charter  // every typeface is free
        #expect(!settings.requiresPremium)
        settings.typography.letterSpacing = 0.02
        #expect(settings.requiresPremium)
        let free = settings.restrictedToFree()
        #expect(free.typography.font == .charter && free.typography.letterSpacing == 0 && !free.requiresPremium)
    }

    @Test func settingsRoundTripThroughJSON() throws {
        let settings = ReaderSettings(theme: .midnight, typography: Typography(font: .systemSans, fontSize: 21), layout: .paginated)
        let decoded = try JSONDecoder().decode(ReaderSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
    }

    @Test func followsSystemAppearance() {
        let settings = ReaderSettings()
        #expect(settings.effectiveTheme(systemIsDark: true).id == "midnight")
        #expect(settings.effectiveTheme(systemIsDark: false).id == "warm-paper")
    }
}

@Suite("Reading progress")
struct ProgressTests {
    let doc = parse("<p>0123456789</p><img src='/a.jpg'><p>abcdefghij</p>")

    @Test func mapsPositionsToProgressAndBack() {
        let map = ProgressMap(document: doc)
        #expect(map.total == 10 + ProgressMap.imageWeight + 10)
        #expect(map.progress(blockID: "b0", offset: 5) == 5.0 / Double(map.total))
        #expect(map.progress(blockID: "b2", offset: 10) == 1)
        #expect(map.position(at: 0)! == ("b0", 0))
        let mid = map.position(at: Double(10 + ProgressMap.imageWeight + 3) / Double(map.total))!
        #expect(mid.blockID == "b2" && mid.offset == 3)
        #expect(map.position(at: 1)!.blockID == "b2")
    }

    @Test func restoresByBlockOrFallsBackToFraction() {
        let map = ProgressMap(document: doc)
        let exact = ReadingPosition(articleID: "1", blockID: "b2", offset: 4, progress: 0.1, updatedAt: Date())
        #expect(map.resolve(exact)! == ("b2", 4))
        let stale = ReadingPosition(articleID: "1", blockID: "b99", offset: 4, progress: 0, updatedAt: Date())
        #expect(map.resolve(stale)!.blockID == "b0")
    }
}

@Suite("Key points box")
struct KeyPointsBoxTests {
    @Test func keyPointsRenderAsAnOpenDisclosureWithoutScript() {
        let meta = ReaderPageMetadata(title: "T", siteName: "S", keyPoints: ["First <point>.", "Second point."])
        let html = ReaderHTMLRenderer(settings: ReaderSettings()).render(ArticleParser.parse(html: "<p>Body.</p>"), metadata: meta)
        #expect(html.contains("<details class=\"f-points\" open><summary>Key points</summary>"))
        #expect(html.contains("<li>First &lt;point&gt;.</li>"))
        #expect(!ReaderHTMLRenderer(settings: ReaderSettings()).render(ArticleParser.parse(html: "<p>Body.</p>"),
                                                                       metadata: ReaderPageMetadata(title: "T", siteName: "S"))
            .contains("f-points\""))
    }
}
