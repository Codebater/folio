import Foundation
import Testing
import FolioCore
import FolioFreshRSS
@testable import FolioFeeds

@Suite("Feed parsing")
struct FeedParserTests {
    let base = URL(string: "https://example.com/feed")!

    @Test func rss2WithFullContentEnclosuresAndAuthors() throws {
        let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/"
                 xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:media="http://search.yahoo.com/mrss/"
                 xmlns:atom="http://www.w3.org/2005/Atom">
            <channel>
              <title>Field &amp; Notes</title>
              <link>https://example.com/</link>
              <atom:link href="https://example.com/feed" rel="self" type="application/rss+xml"/>
              <image><title>Logo</title><url>https://example.com/logo.png</url></image>
              <item>
                <title><![CDATA[Rising <em>seas</em>]]></title>
                <link>https://example.com/seas</link>
                <guid isPermaLink="false">post-42</guid>
                <pubDate>Mon, 2 Nov 2026 20:11:24 EST</pubDate>
                <dc:creator>Mara Ellison</dc:creator>
                <description>A short summary.</description>
                <content:encoded><![CDATA[<p>The whole <b>story</b>.</p>]]></content:encoded>
                <enclosure url="https://example.com/a.mp3" type="audio/mpeg" length="1234"/>
                <media:thumbnail url="https://example.com/t.jpg"/>
              </item>
              <item>
                <title>Second</title>
                <link>/second</link>
                <description>&lt;p&gt;Escaped &amp;amp; summary&lt;/p&gt;</description>
              </item>
            </channel>
            </rss>
            """
        let feed = try FeedParser.parse(Data(xml.utf8), url: base)
        #expect(feed.title == "Field & Notes")
        #expect(feed.siteURL?.absoluteString == "https://example.com/")
        #expect(feed.items.count == 2)
        let first = feed.items[0]
        #expect(first.title == "Rising seas")
        #expect(first.guid == "post-42" && first.url?.absoluteString == "https://example.com/seas")
        #expect(first.html == "<p>The whole <b>story</b>.</p>")  // full content beats the summary
        #expect(first.author == "Mara Ellison")
        #expect(first.published == Date(timeIntervalSince1970: 1_793_668_284))  // 2026-11-03 01:11:24 UTC
        #expect(first.enclosures.map(\.url.absoluteString) == ["https://example.com/a.mp3", "https://example.com/t.jpg"])
        #expect(feed.items[1].url?.absoluteString == "https://example.com/second")
        #expect(feed.items[1].html == "<p>Escaped &amp; summary</p>")
        #expect(feed.items[1].identity == "https://example.com/second")
    }

    @Test func atomWithAPrefixedNamespaceAndXHTMLContent() throws {
        let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <ns6:feed xmlns:ns6="http://www.w3.org/2005/Atom">
              <ns6:title>HBR</ns6:title>
              <ns6:link href="https://hbr.org" rel="alternate" type="text/html"/>
              <ns6:author><ns6:name>Feed Author</ns6:name></ns6:author>
              <ns6:entry>
                <ns6:id>tag:hbr.org,2026:1</ns6:id>
                <ns6:title type="html">Managers &amp;amp; makers</ns6:title>
                <ns6:link rel="alternate" href="/2026/11/managers"/>
                <ns6:published>2026-11-02T22:39:00Z</ns6:published>
                <ns6:updated>2026-11-02T23:00:00.000+01:00</ns6:updated>
                <ns6:author><ns6:name>Ana Ruiz</ns6:name></ns6:author>
                <ns6:content type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml"><p>One &amp; <em>two</em></p></div></ns6:content>
              </ns6:entry>
            </ns6:feed>
            """
        let feed = try FeedParser.parse(Data(xml.utf8), url: base)
        #expect(feed.title == "HBR")
        #expect(feed.siteURL?.absoluteString == "https://hbr.org")
        let entry = try #require(feed.items.first)
        #expect(entry.title == "Managers & makers")
        #expect(entry.guid == "tag:hbr.org,2026:1")
        #expect(entry.url?.absoluteString == "https://example.com/2026/11/managers")
        #expect(entry.author == "Ana Ruiz")
        #expect(entry.html.contains("<p>One &amp; <em>two</em></p>"))
        #expect(entry.published == Date(timeIntervalSince1970: 1_793_659_140))
    }

    @Test func rdfAndJSONFeeds() throws {
        let rdf = """
            <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns="http://purl.org/rss/1.0/"
                     xmlns:dc="http://purl.org/dc/elements/1.1/">
              <channel rdf:about="https://dw.com"><title>DW</title><link>https://dw.com</link></channel>
              <item rdf:about="https://dw.com/a"><title>Alpha</title><link>https://dw.com/a</link>
                <description>Text</description><dc:date>2026-11-02T23:37:00Z</dc:date></item>
            </rdf:RDF>
            """
        let dw = try FeedParser.parse(Data(rdf.utf8), url: base)
        #expect(dw.title == "DW" && dw.items.count == 1 && dw.items[0].published != nil)

        let json = """
            {"version": "https://jsonfeed.org/version/1.1", "title": "Inkwell", "home_page_url": "https://ink.example",
             "items": [{"id": "1", "url": "https://ink.example/1", "title": "Plain", "content_text": "Hello.\\n\\nWorld.",
                        "date_published": "2026-11-01T10:00:00+00:00", "authors": [{"name": "Kim"}], "image": "https://ink.example/1.jpg"}]}
            """
        let ink = try FeedParser.parse(Data(json.utf8), url: base)
        #expect(ink.title == "Inkwell")
        #expect(ink.items.first?.html == "<p>Hello.</p><p>World.</p>")
        #expect(ink.items.first?.author == "Kim")
        #expect(ink.items.first?.enclosures.first?.mimeType == "image/jpeg")
    }

    @Test func webPagesAreNotFeeds() {
        let html = Data("<!doctype html><html><head><title>Hi</title></head><body><p>Hello</p></body></html>".utf8)
        #expect(throws: FeedParserError.notAFeed) { try FeedParser.parse(html, url: base) }
        #expect(!FeedParser.looksLikeFeed(html))
    }

    @Test(arguments: [
        ("Mon, 02 Nov 2026 22:53:20 GMT", 1_793_660_000.0),
        ("Mon, 2 Nov 2026 20:11:24 EST", 1_793_668_284.0),
        ("Tue, 3 Nov 2026 03:37:00 +0100", 1_793_673_420.0),
        ("02 Nov 2026 22:53 +0000", 1_793_659_980.0),
        ("Tue, 03 Nov 2026 02:30:10 -0000", 1_793_673_010.0),
        ("2026-11-02T22:39:00", 1_793_659_140.0),
        ("2026-11-02T22:39:00.123Z", 1_793_659_140.123),
        ("2026-11-02", 1_793_577_600.0),
    ])
    func datesInTheWild(raw: String, expected: Double) throws {
        let date = try #require(FeedDates.parse(raw))
        #expect(abs(date.timeIntervalSince1970 - expected) < 0.01)
    }
}

@Suite("Finding feeds")
struct FeedFinderTests {
    @Test func addressesFromWhatPeopleType() {
        #expect(FeedFinder.address(from: "theverge.com")?.absoluteString == "https://theverge.com")
        #expect(FeedFinder.address(from: " https://example.org/blog ")?.absoluteString == "https://example.org/blog")
        #expect(FeedFinder.address(from: "feed://example.org/rss")?.absoluteString == "https://example.org/rss")
        #expect(FeedFinder.address(from: "not a site") == nil)
        #expect(FeedFinder.address(from: "localhost") == nil)
    }

    @Test func pagesAdvertiseTheirFeeds() {
        let html = """
            <head>
            <link rel="stylesheet" href="/style.css">
            <link rel="alternate" type="application/rss+xml" title="Posts" href="/feed/">
            <link type='application/atom+xml' rel='alternate' href='https://cdn.example.org/atom.xml'/>
            <link rel="alternate" type="application/rss+xml" title="Comments" href="/comments/feed/">
            <LINK REL="alternate" TYPE="application/feed+json" HREF="/feed.json?a=1&amp;b=2">
            </head>
            """
        let links = FeedFinder.feedLinks(inHTML: html, base: URL(string: "https://example.org/post/1")!)
        #expect(links.map(\.absoluteString) == [
            "https://example.org/feed/", "https://cdn.example.org/atom.xml", "https://example.org/feed.json?a=1&b=2",
        ])
    }

    @Test func findsTheFeedBehindAPage() async throws {
        let transport = FakeTransport([
            "https://example.org": .ok("<html><head><link rel=\"alternate\" type=\"application/rss+xml\" href=\"/rss.xml\"></head></html>"),
            "https://example.org/rss.xml": .ok(Fixtures.rss(title: "Example", items: [("1", "One", "Mon, 02 Nov 2026 10:00:00 GMT")])),
        ])
        let found = try await FeedFinder(transport: transport).find("example.org")
        #expect(found.feedURL.absoluteString == "https://example.org/rss.xml")
        #expect(found.title == "Example" && found.itemCount == 1)
        await #expect(throws: FeedFinderError.self) { try await FeedFinder(transport: transport).find("nothing.example") }
    }

    /// Run with FOLIO_FEED_SAMPLES=<folder of downloaded feeds> to check the
    /// parser against real feeds (the catalog's, for example).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FOLIO_FEED_SAMPLES"] != nil))
    func realFeedsParse() throws {
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FOLIO_FEED_SAMPLES"]!)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "feed" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var failures: [String] = []
        for file in files {
            let data = try Data(contentsOf: file)
            guard !data.isEmpty else { continue }
            do {
                let feed = try FeedParser.parse(data, url: URL(string: "https://example.com/")!)
                let dated = feed.items.filter { $0.published != nil }.count
                let newest = feed.items.compactMap(\.published).max().map { ISO8601DateFormatter().string(from: $0) } ?? "-"
                print("FEED \(file.lastPathComponent) \(feed.items.count) items, \(dated) dated, newest \(newest), \(feed.title)")
                if feed.items.isEmpty { failures.append(file.lastPathComponent) }
            } catch {
                print("FEED \(file.lastPathComponent) FAILED \(error)")
                failures.append(file.lastPathComponent)
            }
        }
        #expect(failures.isEmpty, "\(failures)")
    }
}

/// Answers from a table; anything else is a 404.
actor FakeTransport: HTTPTransport {
    enum Answer: Sendable {
        case ok(String)
        case status(Int)
        case notModified
    }

    var answers: [String: Answer]
    private(set) var requests: [HTTPRequest] = []

    init(_ answers: [String: Answer]) {
        self.answers = answers
    }

    func set(_ url: String, _ answer: Answer) { answers[url] = answer }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        switch answers[request.url.absoluteString] {
        case .ok(let body): return HTTPResponse(status: 200, headers: ["etag": "\"v1\""], body: Data(body.utf8))
        case .status(let code): return HTTPResponse(status: code)
        case .notModified: return HTTPResponse(status: 304)
        case nil: return HTTPResponse(status: 404)
        }
    }
}

enum Fixtures {
    static func rss(title: String, items: [(guid: String, title: String, date: String)]) -> String {
        let entries = items.map { item in
            "<item><title>\(item.title)</title><guid>\(item.guid)</guid><link>https://example.org/\(item.guid)</link>"
                + "<pubDate>\(item.date)</pubDate><description>Story \(item.guid) in a few words.</description></item>"
        }
        return "<rss version=\"2.0\"><channel><title>\(title)</title><link>https://example.org/</link>\(entries.joined())</channel></rss>"
    }
}

@Suite("Feed catalog")
struct FeedCatalogTests {
    @Test func everyPackFeedIsInTheCatalogAndAddressesAreUnique() {
        let urls = FeedCatalog.feeds.map(\.url)
        #expect(Set(urls).count == urls.count)
        for pack in FeedCatalog.packs {
            for url in pack.feedURLs {
                #expect(FeedCatalog.feed(url)?.language == pack.language, "\(pack.title): \(url)")
            }
        }
        for language in FeedCatalog.languages {
            #expect(FeedCatalog.packs.contains { $0.language == language })
            #expect(!FeedCatalog.feeds(in: [language]).isEmpty)
        }
        #expect(FeedCatalog.feeds.allSatisfy { FeedCatalog.languages.contains($0.language) && $0.url.scheme?.hasPrefix("http") == true })
    }
}
