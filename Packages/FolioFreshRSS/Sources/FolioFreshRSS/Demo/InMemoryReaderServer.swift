import Foundation
import FolioCore

/// An in-process Google Reader server backed by the demo seed.
///
/// It powers the app's demo account (so the app works with no server, which
/// App Review also needs), SwiftUI previews and tests. It answers like
/// FreshRSS's greader.php for every call Folio makes, keeps read/starred
/// state, and can simulate outages.
public actor InMemoryReaderServer: HTTPTransport {
    public static let demoUsername = "demo"
    public static let demoPassword = "folio-demo"
    public static let demoEndpoint = ServerEndpoint(apiBase: URL(string: "https://demo.folio.invalid/api/greader.php")!)

    struct SeedFeed: Decodable { var id, title, url, htmlUrl: String; var categories: [String] }
    struct SeedCategory: Decodable { var id, label: String }
    struct SeedArticle: Decodable {
        var id, feed, title, url, html: String
        var author: String?
        var published: Int64
        var read, starred: Bool
    }
    struct Seed: Decodable { var categories: [SeedCategory]; var feeds: [SeedFeed]; var articles: [SeedArticle] }

    private let username: String
    private let password: String
    private let authToken: String
    private let actionToken: String
    private var feeds: [SeedFeed]
    private var categories: [SeedCategory]
    private var articles: [String: SeedArticle]

    /// Every request received, for assertions in tests.
    public private(set) var requestLog: [HTTPRequest] = []
    /// When set, every request fails with this transport error.
    public var simulatedOutage: TransportError?
    /// When true, the action token is rejected once (stale-token path).
    public var rejectNextActionToken = false

    /// Seed dates are shifted so the newest article is two hours old at `now`;
    /// the demo always looks fresh and retention pruning never eats it.
    public init(username: String = demoUsername, password: String = demoPassword, now: Date = Date()) {
        self.username = username
        self.password = password
        authToken = "\(username)/demo0auth0token"
        actionToken = String(repeating: "a", count: 40) + String(repeating: "Z", count: 17)
        // The seed is generated from MockServer/seed.json; a decoding failure
        // is a build-time bug, so crash loudly in debug and start empty otherwise.
        let seed: Seed
        do {
            seed = try JSONDecoder().decode(Seed.self, from: Data(DemoSeed.json.utf8))
        } catch {
            assertionFailure("Demo seed is invalid: \(error)")
            seed = Seed(categories: [], feeds: [], articles: [])
        }
        feeds = seed.feeds
        categories = seed.categories
        let newest = seed.articles.map(\.published).max() ?? 0
        let shift = Int64(now.timeIntervalSince1970) - 7200 - newest
        articles = Dictionary(uniqueKeysWithValues: seed.articles.map { article in
            var shifted = article
            shifted.published += shift
            return (article.id, shifted)
        })
    }

    public func setOutage(_ error: TransportError?) { simulatedOutage = error }
    public func setRejectNextActionToken(_ value: Bool) { rejectNextActionToken = value }

    /// Adds an article as if the server had just fetched it.
    public func publish(id: String, feed: String, title: String, html: String, published: Date) {
        articles[id] = SeedArticle(
            id: id, feed: feed, title: title, url: "https://demo.folio.invalid/\(id)", html: html,
            author: nil, published: Int64(published.timeIntervalSince1970), read: false, starred: false)
    }

    public func isRead(_ id: String) -> Bool? { articles[id]?.read }
    public func isStarred(_ id: String) -> Bool? { articles[id]?.starred }

    // MARK: HTTPTransport

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requestLog.append(request)
        if let simulatedOutage { throw simulatedOutage }

        guard let components = URLComponents(url: request.url, resolvingAgainstBaseURL: false),
              let range = components.percentEncodedPath.range(of: "/greader.php/")
        else { return text(404, "Not found") }
        let path = String(components.percentEncodedPath[range.upperBound...]).removingPercentEncoding ?? ""
        var params: [(String, String)] = (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        if request.method == .post { params += FormBody.decode(request.body) }
        func all(_ name: String) -> [String] { params.filter { $0.0 == name }.map(\.1) }
        func one(_ name: String) -> String? { all(name).first }

        if path == "accounts/ClientLogin" {
            guard one("Email") == username, one("Passwd") == password else { return unauthorized() }
            return text(200, "SID=\(authToken)\nLSID=null\nAuth=\(authToken)\n")
        }
        guard request.headers["Authorization"] == "GoogleLogin auth=\(authToken)" else { return unauthorized() }

        switch path {
        case "reader/api/0/token":
            return text(200, actionToken + "\n")
        case "reader/api/0/user-info":
            return json(["userId": "1", "userName": username, "userProfileId": "1", "userEmail": ""])
        case "reader/api/0/subscription/list":
            let label = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0.label) })
            return json(["subscriptions": feeds.map { feed in
                ["id": feed.id, "title": feed.title, "url": feed.url, "htmlUrl": feed.htmlUrl, "iconUrl": "",
                 "categories": feed.categories.map { ["id": $0, "label": label[$0] ?? $0] }] as [String: Any]
            }])
        case "reader/api/0/tag/list":
            return json(["tags": [["id": StreamID.starred]] + categories.map { ["id": $0.id, "type": "folder"] }])
        case "reader/api/0/unread-count":
            var counts: [String: Int] = [:]
            for article in articles.values where !article.read {
                for key in streams(of: article) where key != StreamID.starred { counts[key, default: 0] += 1 }
            }
            return json(["max": 1000, "unreadcounts": counts.map { ["id": $0.key, "count": $0.value, "newestItemTimestampUsec": "0"] }])
        case "reader/api/0/stream/items/ids":
            let (page, continuation) = select(stream: one("s") ?? StreamID.readingList, params: params)
            var body: [String: Any] = ["itemRefs": page.map { ["id": $0.id] }]
            if let continuation { body["continuation"] = continuation }
            return json(body)
        case "reader/api/0/stream/items/contents":
            let items = all("i").compactMap(ItemID.shortForm).compactMap { articles[$0] }.map(itemJSON)
            return json(["id": StreamID.readingList, "updated": Int(Date().timeIntervalSince1970), "items": items])
        case let p where p.hasPrefix("reader/api/0/stream/contents"):
            let streamPath = String(p.dropFirst("reader/api/0/stream/contents".count)).trimmingPrefix("/")
            let stream = streamPath.isEmpty ? (one("s") ?? StreamID.readingList) : String(streamPath)
            let (page, continuation) = select(stream: stream, params: params)
            var body: [String: Any] = ["id": stream, "updated": Int(Date().timeIntervalSince1970), "items": page.map(itemJSON)]
            if let continuation { body["continuation"] = continuation }
            return json(body)
        case "reader/api/0/edit-tag":
            guard request.method == .post else { return text(400, "Bad request") }
            guard checkActionToken(one("T")) else { return unauthorized() }
            for id in all("i").compactMap(ItemID.shortForm) {
                guard var article = articles[id] else { continue }
                for tag in all("a") {
                    if tag == StreamID.read { article.read = true }
                    if tag == StreamID.starred { article.starred = true }
                }
                for tag in all("r") {
                    if tag == StreamID.read { article.read = false }
                    if tag == StreamID.starred { article.starred = false }
                }
                articles[id] = article
            }
            return text(200, "OK")
        case "reader/api/0/subscription/quickadd":
            guard checkActionToken(one("T")), let address = one("quickadd"), let url = URL(string: address) else { return text(400, "Bad request") }
            let id = "feed/\(feeds.count + 100)"
            feeds.append(SeedFeed(id: id, title: url.host ?? address, url: address, htmlUrl: address, categories: []))
            return json(["numResults": 1, "query": address, "streamId": id, "streamName": url.host ?? address])
        case "reader/api/0/subscription/edit":
            guard checkActionToken(one("T")), let id = one("s"), let index = feeds.firstIndex(where: { $0.id == id }) else {
                return text(400, "Bad request")
            }
            switch one("ac") {
            case "unsubscribe":
                feeds.remove(at: index)
            default:
                if let title = one("t") { feeds[index].title = title }
                for label in all("a") where !feeds[index].categories.contains(label) {
                    feeds[index].categories.append(label)
                    if !categories.contains(where: { $0.id == label }) {
                        categories.append(SeedCategory(id: label, label: String(label.split(separator: "/").last ?? "")))
                    }
                }
            }
            return text(200, "OK")
        case "reader/api/0/mark-all-as-read":
            guard checkActionToken(one("T")) else { return unauthorized() }
            let stream = one("s") ?? StreamID.readingList
            let ts = UInt64(one("ts") ?? "0") ?? 0
            for (id, article) in articles where streams(of: article).contains(stream) && (ts == 0 || (UInt64(id) ?? 0) <= ts) {
                articles[id]?.read = true
            }
            return text(200, "OK")
        default:
            return text(400, "Bad request")
        }
    }

    // MARK: Helpers

    private func checkActionToken(_ token: String?) -> Bool {
        if rejectNextActionToken {
            rejectNextActionToken = false
            return false
        }
        return token == actionToken
    }

    private func streams(of article: SeedArticle) -> Set<String> {
        var result: Set<String> = [StreamID.readingList, article.feed]
        if let feed = feeds.first(where: { $0.id == article.feed }) { result.formUnion(feed.categories) }
        if article.read { result.insert(StreamID.read) }
        if article.starred { result.insert(StreamID.starred) }
        return result
    }

    private func select(stream: String, params: [(String, String)]) -> ([SeedArticle], String?) {
        func all(_ name: String) -> [String] { params.filter { $0.0 == name }.map(\.1) }
        var items = articles.values.filter { streams(of: $0).contains(stream) }
        for excluded in all("xt") { items.removeAll { streams(of: $0).contains(excluded) } }
        for included in all("it") { items.removeAll { !streams(of: $0).contains(included) } }
        if let ot = all("ot").first.flatMap(Int64.init) { items.removeAll { $0.published < ot } }
        if let nt = all("nt").first.flatMap(Int64.init), nt > 0 { items.removeAll { $0.published > nt } }
        let oldestFirst = all("r").first == "o"
        items.sort { oldestFirst ? (UInt64($0.id)! < UInt64($1.id)!) : (UInt64($0.id)! > UInt64($1.id)!) }
        if let c = all("c").first.flatMap(UInt64.init) {
            items.removeAll { oldestFirst ? UInt64($0.id)! <= c : UInt64($0.id)! >= c }
        }
        let n = all("n").first.flatMap(Int.init) ?? 20
        let page = Array(items.prefix(n))
        return (page, items.count > n ? page.last?.id : nil)
    }

    private func itemJSON(_ article: SeedArticle) -> [String: Any] {
        let feed = feeds.first { $0.id == article.feed }
        var categories = [StreamID.readingList] + (feed?.categories ?? [])
        if article.read { categories.append(StreamID.read) }
        if article.starred { categories.append(StreamID.starred) }
        var item: [String: Any] = [
            "id": ItemID.longForm(article.id) ?? article.id,
            "crawlTimeMsec": String(article.published * 1000),
            "timestampUsec": String(article.published * 1_000_000),
            "published": article.published,
            "title": article.title,
            "canonical": [["href": article.url]],
            "alternate": [["href": article.url]],
            "categories": categories,
            "origin": ["streamId": article.feed, "htmlUrl": feed?.htmlUrl ?? "", "title": feed?.title ?? ""],
            "summary": ["content": article.html],
        ]
        if let author = article.author { item["author"] = author }
        return item
    }

    private func text(_ status: Int, _ body: String) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["content-type": "text/plain; charset=UTF-8"], body: Data(body.utf8))
    }

    private func unauthorized() -> HTTPResponse {
        HTTPResponse(status: 401, headers: ["content-type": "text/plain", "google-bad-token": "true"], body: Data("Unauthorized!".utf8))
    }

    private func json(_ object: Any) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        return HTTPResponse(status: 200, headers: ["content-type": "application/json"], body: data)
    }
}
