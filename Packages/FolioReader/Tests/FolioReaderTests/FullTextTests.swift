import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import FolioCore
@testable import FolioReader

private let paragraph = "The council met late on Thursday, and nobody expected the vote to be unanimous, but it was, after hours of debate about the budget, the new tram line and the old library."

private func newsPage(body: String, extraHead: String = "") -> String {
    """
    <!doctype html><html><head><title>Council vote</title>\(extraHead)</head><body>
    <header class="site-header"><nav><a href="/">Home</a><a href="/world">World</a><a href="/tech">Tech</a></nav></header>
    <div class="layout">
      <aside class="sidebar"><h3>Most read</h3><ul><li><a href="/a">Story A</a></li><li><a href="/b">Story B</a></li></ul></aside>
      \(body)
      <div class="related-stories"><h3>Related</h3><a href="/c">Another story about councils and votes</a></div>
      <div id="comments"><p>Great article, thanks for writing it, I agree with everything here completely.</p></div>
    </div>
    <footer><p>© 2026 Example News. All rights reserved. Terms, privacy and cookies.</p></footer>
    </body></html>
    """
}

@Suite("Full text")
struct FullTextTests {
    let base = URL(string: "https://news.example.com/2026/11/council-vote")!

    @Test func findsTheArticleAndDropsTheChrome() throws {
        let body = """
        <article class="story"><h1>Council vote</h1>
          <div class="share-bar"><a href="/share/x">Share</a><a href="/share/f">Post</a></div>
          <p>\(paragraph)</p><h2>What happens next</h2><p>\(paragraph)</p>
          <figure><img src="/img/tram.jpg" alt="A tram"><figcaption>The new tram line.</figcaption></figure>
          <p>\(paragraph) <a href="/budget">Read the budget</a>.</p>
          <ul><li>Trams from 2027, running every ten minutes between the centre and the river.</li><li>A new library wing with a reading room.</li></ul>
        </article>
        """
        let result = try #require(FullTextExtractor.extract(html: newsPage(body: body), url: base))
        #expect(result.source == .page)
        #expect(result.wordCount > 90)
        #expect(result.html.contains("What happens next"))
        #expect(result.html.contains("https://news.example.com/img/tram.jpg"))  // made absolute
        #expect(result.html.contains("href=\"https://news.example.com/budget\""))
        #expect(result.html.contains("Trams from 2027"))
        for chrome in ["Most read", "Related", "Great article", "All rights reserved", "Share", "Home"] {
            #expect(!result.html.contains(chrome), "kept \(chrome)")
        }
        // The output parses like feed content.
        let document = ArticleParser.parse(html: result.html, baseURL: base, title: "Council vote")
        #expect(document.wordCount > 90)
    }

    @Test func paragraphsWrittenAsDivsCount() throws {
        let body = """
        <div class="article-body">
          <div class="para">\(paragraph)</div><div class="para">\(paragraph)</div><div class="para">\(paragraph)</div>
        </div>
        """
        let result = try #require(FullTextExtractor.extract(html: newsPage(body: body), url: base))
        #expect(result.wordCount > 90)
        #expect(!result.html.contains("Most read"))
    }

    @Test func structuredDataCoversPagesBuiltWithJavaScript() throws {
        let text = Array(repeating: paragraph, count: 6).joined(separator: "\\n")
        let ld = """
        <script type="application/ld+json">{"@context":"https://schema.org","@graph":[{"@type":"WebPage"},
        {"@type":"NewsArticle","headline":"Council vote","articleBody":"\(text)"}]}</script>
        """
        let page = newsPage(body: "<div id=\"app\"><p>Loading…</p></div>", extraHead: ld)
        let result = try #require(FullTextExtractor.extract(html: page, url: base))
        #expect(result.source == .structuredData)
        #expect(result.html.components(separatedBy: "<p>").count - 1 == 6)
        #expect(result.wordCount > 150)
    }

    @Test func lazyImagesAndSrcsetsResolve() throws {
        let body = """
        <article><p>\(paragraph)</p><p>\(paragraph)</p>
        <img src="data:image/gif;base64,R0lGOD" data-src="/lazy.jpg" data-srcset="/lazy-640.jpg 640w, /lazy-1280.jpg 1280w" alt="Lazy">
        <p>\(paragraph)</p></article>
        """
        let result = try #require(FullTextExtractor.extract(html: newsPage(body: body), url: base))
        #expect(result.html.contains("src=\"https://news.example.com/lazy.jpg\""))
        #expect(result.html.contains("https://news.example.com/lazy-1280.jpg 1280w"))
        #expect(!result.html.contains("data:image"))
    }

    @Test func pagesWithoutAnArticleGiveNothing() {
        let index = newsPage(body: """
        <div class="teasers"><ul>\((1...20).map { "<li><a href=\"/s\($0)\">Story number \($0) about the city</a></li>" }.joined())</ul></div>
        """)
        #expect(FullTextExtractor.extract(html: index, url: base) == nil)
        #expect(FullTextExtractor.extract(html: "<html><body><p>Subscribe to read.</p></body></html>", url: base) == nil)
    }

    @Test func hiddenAndScriptContentIsIgnored() throws {
        let body = """
        <article><p>\(paragraph)</p><div style="display: none"><p>Hidden promo text that must never be read aloud to anyone at all.</p></div>
        <script>var tracking = "never shown";</script><p>\(paragraph)</p><p>\(paragraph)</p></article>
        """
        let result = try #require(FullTextExtractor.extract(html: newsPage(body: body), url: base))
        #expect(!result.html.contains("Hidden promo"))
        #expect(!result.html.contains("tracking"))
    }

    @Test func fetcherSkipsVideoAndRedirectPagesAndReadsTheRest() async throws {
        #expect(!FullTextFetcher.isSupported(URL(string: "https://www.youtube.com/watch?v=abc")!))
        #expect(!FullTextFetcher.isSupported(URL(string: "https://news.google.com/rss/articles/CBMi")!))
        #expect(FullTextFetcher.isSupported(base))
        #expect(FullTextFetcher.isVideo(URL(string: "https://youtu.be/abc")))

        let page = newsPage(body: "<article><p>\(paragraph)</p><p>\(paragraph)</p><p>\(paragraph)</p></article>")
        let fetcher = FullTextFetcher { request in
            #expect(request.value(forHTTPHeaderField: "User-Agent")?.contains("Folio") == true)
            return FullTextFetcher.Response(data: Data(page.utf8), status: 200, url: request.url, contentType: "text/html; charset=utf-8")
        }
        #expect(try await fetcher.fetch(base)?.wordCount ?? 0 > 90)
        let video = try await fetcher.fetch(URL(string: "https://www.youtube.com/watch?v=abc")!)
        #expect(video == nil)
        let blocked = FullTextFetcher { _ in FullTextFetcher.Response(data: Data(), status: 403, url: nil, contentType: "text/html") }
        #expect(try await blocked.fetch(base) == nil)
    }

    @Test func latinPagesDecode() {
        let data = "<p>Caf\u{E9} na rohu</p>".data(using: .windowsCP1252)!
        #expect(FullTextFetcher.decode(data, contentType: "text/html; charset=ISO-8859-1").contains("Café"))
        #expect(FullTextFetcher.decode(Data("<p>Kaviareň</p>".utf8), contentType: "text/html").contains("Kaviareň"))
    }
}
