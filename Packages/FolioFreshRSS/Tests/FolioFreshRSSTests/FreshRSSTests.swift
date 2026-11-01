import Foundation
import Testing
import FolioCore
@testable import FolioFreshRSS

@Suite("Server address")
struct ServerEndpointTests {
    @Test(arguments: [
        ("vault.example.ts.net:8091", "https://vault.example.ts.net:8091/api/greader.php"),
        ("https://rss.example.com/", "https://rss.example.com/api/greader.php"),
        ("https://rss.example.com/freshrss/i/", "https://rss.example.com/freshrss/api/greader.php"),
        ("https://rss.example.com/api/greader.php", "https://rss.example.com/api/greader.php"),
        ("http://127.0.0.1:8787/p/api/greader.php?x=1", "http://127.0.0.1:8787/p/api/greader.php"),
    ])
    func normalizesInput(input: String, expected: String) throws {
        #expect(try ServerEndpoint(userInput: input).apiBase.absoluteString == expected)
    }

    @Test func rejectsGarbage() {
        #expect(throws: GoogleReaderError.self) { try ServerEndpoint(userInput: "  ") }
        #expect(throws: GoogleReaderError.self) { try ServerEndpoint(userInput: "ftp://host") }
    }

    @Test func buildsPathsAndEscapesPlus() {
        let endpoint = ServerEndpoint(apiBase: URL(string: "https://h/api/greader.php")!)
        let url = endpoint.url("reader/api/0/stream/items/ids", query: [URLQueryItem(name: "s", value: "user/-/label/C++")])
        #expect(url.absoluteString.hasPrefix("https://h/api/greader.php/reader/api/0/stream/items/ids?"))
        #expect(url.absoluteString.contains("C%2B%2B"))
        #expect(url.absoluteString.contains("output=json"))
    }
}

@Suite("Item ids")
struct ItemIDTests {
    @Test func convertsBetweenForms() {
        #expect(ItemID.shortForm("tag:google.com,2005:reader/item/000000000000001f") == "31")
        #expect(ItemID.longForm("31") == "tag:google.com,2005:reader/item/000000000000001f")
        // FreshRSS ids are microsecond timestamps and need all 64 bits.
        let big = "1761900000123456"
        #expect(ItemID.shortForm(ItemID.longForm(big)!) == big)
        #expect(ItemID.shortForm("tag:google.com,2005:reader/item/zzz") == nil)
        #expect(ItemID.shortForm("12a") == nil)
    }
}

@Suite("FreshRSS JSON")
struct DTODecodingTests {
    // Shapes copied from FreshRSS 1.30 p/api/greader.php output.
    @Test func decodesStreamContentsItem() throws {
        let json = #"""
        {"id":"user/-/state/com.google/reading-list","updated":1761900000,"items":[{
          "id":"tag:google.com,2005:reader/item/0006425ef8a3c040",
          "crawlTimeMsec":"1761900000123","timestampUsec":"1761900000123456","published":1761899000,
          "title":"Tom &amp; Jerry","canonical":[{"href":"https://ex.com/a"}],"alternate":[{"href":"https://ex.com/a"}],
          "categories":["user/-/state/com.google/reading-list","user/-/label/News","user/-/state/com.google/read",
                        "user/-/state/org.freshrss/main"],
          "origin":{"streamId":"feed/7","htmlUrl":"https://ex.com/","title":"Example"},
          "summary":{"content":"<p>Hello</p>"},"author":"Ana",
          "enclosure":[{"href":"https://ex.com/i.jpg","type":"image/jpeg","length":"1234"}]}],
          "continuation":"1761800000000000"}
        """#
        let dto = try JSONDecoder().decode(StreamContentsDTO.self, from: Data(json.utf8))
        #expect(dto.continuation == "1761800000000000")
        let article = try #require(ArticleMapper.article(from: dto.items[0]))
        #expect(article.id == ArticleID(String(UInt64("0006425ef8a3c040", radix: 16)!)))
        #expect(article.feedID == FeedID("feed/7"))
        #expect(article.title == "Tom & Jerry")
        #expect(article.isRead && !article.isStarred)
        #expect(article.contentHTML == "<p>Hello</p>")
        #expect(article.publishedAt == Date(timeIntervalSince1970: 1_761_899_000))
        #expect(article.updatedAt == nil)
        #expect(article.enclosures.first?.length == 1234)
    }

    @Test func toleratesNumbersAsStringsAndMissingFields() throws {
        let json = #"{"items":[{"id":"42","timestampUsec":1761900000000000,"origin":{"streamId":"feed/1"},"categories":[]}]}"#
        let dto = try JSONDecoder().decode(StreamContentsDTO.self, from: Data(json.utf8))
        let article = try #require(ArticleMapper.article(from: dto.items[0]))
        #expect(article.title == "Untitled")
        #expect(article.publishedAt == Date(timeIntervalSince1970: 1_761_900_000))
        #expect(article.contentHTML.isEmpty)
    }

    @Test func mapsSubscriptionsAndLabels() throws {
        let subs = try JSONDecoder().decode(SubscriptionListDTO.self, from: Data(#"""
            {"subscriptions":[{"id":"feed/2","title":"La Br&uacute;jula","categories":[{"id":"user/-/label/World","label":"World"}],
              "url":"https://b.example/rss","htmlUrl":"https://b.example/","iconUrl":"","frss:priority":10}]}
            """#.utf8))
        let tags = try JSONDecoder().decode(TagListDTO.self, from: Data(#"""
            {"tags":[{"id":"user/-/state/com.google/starred"},{"id":"user/-/label/World","type":"folder"},
                     {"id":"user/-/label/Later","type":"tag","unread_count":3}]}
            """#.utf8))
        let (feeds, categories) = GoogleReaderClient.map(subscriptions: subs.subscriptions, tags: tags.tags)
        #expect(feeds.first?.title == "La Brújula")
        #expect(feeds.first?.categoryIDs == [CategoryID("user/-/label/World")])
        #expect(categories.map(\.label) == ["World"])  // user tags (type "tag") are not folders
    }

    @Test func parsesClientLogin() {
        #expect(GoogleReaderClient.parseClientLogin("SID=a/b\nLSID=null\nAuth=alice/8e6845e0\n") == "alice/8e6845e0")
        #expect(GoogleReaderClient.parseClientLogin("Error=BadAuthentication") == nil)
    }
}

@Suite("Google Reader client")
struct ClientTests {
    func client(_ server: InMemoryReaderServer, password: String = InMemoryReaderServer.demoPassword) -> GoogleReaderClient {
        GoogleReaderClient(endpoint: InMemoryReaderServer.demoEndpoint,
                           credentials: Credentials(username: "demo", apiPassword: password), transport: server)
    }

    @Test func verifiesCredentials() async throws {
        let server = InMemoryReaderServer()
        try await client(server).verifyCredentials()
        let paths = await server.requestLog.map(\.url.path)
        #expect(paths.contains { $0.hasSuffix("accounts/ClientLogin") })
        #expect(await server.requestLog.last?.headers["Authorization"]?.hasPrefix("GoogleLogin auth=") == true)
    }

    @Test func rejectsWrongPassword() async {
        let server = InMemoryReaderServer()
        await #expect(throws: GoogleReaderError.invalidCredentials) {
            try await client(server, password: "wrong").verifyCredentials()
        }
    }

    @Test func reportsOfflineAsTransport() async {
        let server = InMemoryReaderServer()
        await server.setOutage(TransportError(kind: .offline, message: "The Internet connection appears to be offline."))
        do {
            try await client(server).verifyCredentials()
            Issue.record("expected failure")
        } catch {
            #expect(error == .transport(TransportError(kind: .offline, message: "The Internet connection appears to be offline.")))
            #expect(error.isTransient)
            #expect(error.description == "You're offline.")
        }
    }

    @Test func loadsSubscriptionsAndCounts() async throws {
        let c = client(InMemoryReaderServer())
        let (feeds, categories) = try await c.subscriptions()
        #expect(feeds.count == 5)
        #expect(categories.map(\.label) == ["Design", "Science", "World"])
        let counts = try await c.unreadCounts()
        #expect(counts[StreamID.readingList] == 8)
    }

    @Test func followsContinuationsForItemIDs() async throws {
        let server = InMemoryReaderServer()
        let c = client(server)
        // 8 unread in the seed; ask in pages of 3 by limiting n via limit.
        let all = try await c.itemIDs(stream: StreamID.readingList, excludeRead: true, newerThan: nil, limit: 100)
        #expect(all.count == 8)
        #expect(Set(all).count == 8)
        let starred = try await c.itemIDs(stream: StreamID.starred, excludeRead: false, newerThan: nil, limit: 100)
        #expect(Set(starred) == [ArticleID("1730390400000001"), ArticleID("1730390400000009")])
    }

    @Test func fetchesContentsAndEditsTags() async throws {
        let server = InMemoryReaderServer()
        let c = client(server)
        let articles = try await c.articles(ids: [ArticleID("1730390400000003"), ArticleID("1730390400000005")])
        #expect(Set(articles.map(\.title)) == ["The quiet engineering of a bird's wing", "Die Stadt, die nachts arbeitet"])
        try await c.setRead(true, ids: [ArticleID("1730390400000003")])
        try await c.setStarred(true, ids: [ArticleID("1730390400000003")])
        #expect(await server.isRead("1730390400000003") == true)
        #expect(await server.isStarred("1730390400000003") == true)
        try await c.setRead(false, ids: [ArticleID("1730390400000003")])
        #expect(await server.isRead("1730390400000003") == false)
    }

    @Test func retriesOnceWithFreshActionToken() async throws {
        let server = InMemoryReaderServer()
        let c = client(server)
        try await c.setRead(true, ids: [ArticleID("1730390400000002")])  // caches a token
        await server.setRejectNextActionToken(true)
        try await c.setRead(false, ids: [ArticleID("1730390400000002")])
        #expect(await server.isRead("1730390400000002") == false)
        let tokenFetches = await server.requestLog.filter { $0.url.path.hasSuffix("reader/api/0/token") }.count
        #expect(tokenFetches == 2)
    }

    @Test func mapsMissingAPIToHelpfulError() async {
        struct NotFound: HTTPTransport {
            func send(_ request: HTTPRequest) async throws -> HTTPResponse { HTTPResponse(status: 404, body: Data("nope".utf8)) }
        }
        let c = GoogleReaderClient(endpoint: InMemoryReaderServer.demoEndpoint,
                                   credentials: Credentials(username: "u", apiPassword: "p"), transport: NotFound())
        await #expect(throws: GoogleReaderError.apiNotFound) { try await c.verifyCredentials() }

        struct Disabled: HTTPTransport {
            func send(_ request: HTTPRequest) async throws -> HTTPResponse { HTTPResponse(status: 503, body: Data("API disabled".utf8)) }
        }
        let disabled = GoogleReaderClient(endpoint: InMemoryReaderServer.demoEndpoint,
                                          credentials: Credentials(username: "u", apiPassword: "p"), transport: Disabled())
        await #expect(throws: GoogleReaderError.apiNotFound) { try await disabled.verifyCredentials() }
    }

    @Test func classifiesServerErrors() {
        #expect(GoogleReaderError.server(status: 503, message: "").isTransient)
        #expect(GoogleReaderError.server(status: 429, message: "").isTransient)
        #expect(!GoogleReaderError.server(status: 400, message: "").isTransient)
        #expect(!GoogleReaderError.invalidCredentials.isTransient)
        #expect(GoogleReaderError.unauthorized.isAuthenticationFailure)
    }

    @Test func encodesRepeatedFormKeys() {
        var form = FormBody()
        form.append("i", "1")
        form.append("i", "2")
        form.append("a", "user/-/state/com.google/read")
        #expect(String(decoding: form.encoded, as: UTF8.self) == "i=1&i=2&a=user%2F-%2Fstate%2Fcom.google%2Fread")
        #expect(FormBody.decode(form.encoded).map(\.1) == ["1", "2", "user/-/state/com.google/read"])
    }
}

@Suite("Credentials")
struct CredentialTests {
    @Test func storesPerServerAndUser() throws {
        let store = InMemoryCredentialStore()
        let config = AccountConfiguration(endpoint: InMemoryReaderServer.demoEndpoint, username: "demo")
        try store.setPassword("secret", for: config.credentialKey)
        #expect(try store.password(for: config.credentialKey) == "secret")
        try store.removePassword(for: config.credentialKey)
        #expect(try store.password(for: config.credentialKey) == nil)
        #expect(config.credentialKey == "demo@https://demo.folio.invalid/api/greader.php")
    }
}
