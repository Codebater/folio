import Foundation
import FolioCore

/// The operations sync needs from a Google Reader–compatible server.
/// `GoogleReaderClient` is the real implementation; tests use fakes.
public protocol ReaderService: Sendable {
    func verifyCredentials() async throws(GoogleReaderError)
    func subscriptions() async throws(GoogleReaderError) -> (feeds: [Feed], categories: [FeedCategory])
    func unreadCounts() async throws(GoogleReaderError) -> [String: Int]
    /// Item ids (short form) in a stream, following continuations up to `limit`.
    func itemIDs(stream: String, excludeRead: Bool, newerThan: Date?, limit: Int) async throws(GoogleReaderError) -> [ArticleID]
    func articles(ids: [ArticleID]) async throws(GoogleReaderError) -> [Article]
    func streamContents(stream: String, excludeRead: Bool, count: Int, continuation: String?)
        async throws(GoogleReaderError) -> (articles: [Article], continuation: String?)
    func setRead(_ read: Bool, ids: [ArticleID]) async throws(GoogleReaderError)
    func setStarred(_ starred: Bool, ids: [ArticleID]) async throws(GoogleReaderError)
    func markAllAsRead(stream: String, olderThan: Date) async throws(GoogleReaderError)
}

/// Adding and removing feeds, for services that let the app do it.
public protocol FeedSubscribing: Sendable {
    /// Follows the feed at `feedURL`, filed under `category` (a topic label).
    func subscribe(feedURL: URL, title: String?, category: String?) async throws(GoogleReaderError) -> FeedID
    func unsubscribe(_ feed: FeedID) async throws(GoogleReaderError)
}

/// A service that fetches its feeds itself, on this device, instead of
/// asking a server. Sync lets it fetch before asking for anything.
public protocol RefreshingReaderService: ReaderService {
    func refresh() async
}

/// Google Reader API client for FreshRSS (and other compatible servers).
///
/// Auth flow: `accounts/ClientLogin` trades username + API password for an
/// `Auth` token sent as `Authorization: GoogleLogin auth=<token>`. Write calls
/// also need the short-lived action token `T` from `reader/api/0/token`.
/// Both are cached in memory only; a 401 triggers one fresh login.
public actor GoogleReaderClient: ReaderService, FeedSubscribing {
    public let endpoint: ServerEndpoint
    private let credentials: Credentials
    private let transport: HTTPTransport
    private var authToken: String?
    private var actionToken: String?

    /// Ids per `stream/items/contents` request; FreshRSS handles more, but
    /// small batches keep responses and memory modest on a phone.
    public static let contentsBatchSize = 100
    /// Ids per `edit-tag` request.
    public static let editBatchSize = 250

    public init(endpoint: ServerEndpoint, credentials: Credentials, transport: HTTPTransport = URLSessionTransport()) {
        self.endpoint = endpoint
        self.credentials = credentials
        self.transport = transport
    }

    // MARK: Auth

    public func verifyCredentials() async throws(GoogleReaderError) {
        authToken = nil
        actionToken = nil
        _ = try await login()
        _ = try await get("reader/api/0/user-info")
    }

    private func login() async throws(GoogleReaderError) -> String {
        if let authToken { return authToken }
        var form = FormBody()
        form.append("Email", credentials.username)
        form.append("Passwd", credentials.apiPassword)
        let request = HTTPRequest(
            method: .post, url: endpoint.url("accounts/ClientLogin"),
            headers: ["Content-Type": "application/x-www-form-urlencoded"], body: form.encoded)
        let response = try await send(request)
        switch response.status {
        case 200: break
        case 401, 403: throw .invalidCredentials
        // FreshRSS answers 503 when API access is switched off.
        case 404, 503: throw .apiNotFound
        default: throw .server(status: response.status, message: response.text)
        }
        guard let token = Self.parseClientLogin(response.text) else {
            throw .malformedResponse("ClientLogin without Auth=")
        }
        authToken = token
        return token
    }

    static func parseClientLogin(_ body: String) -> String? {
        for line in body.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Auth=") {
                let token = String(trimmed.dropFirst(5))
                return token.isEmpty ? nil : token
            }
        }
        return nil
    }

    private func writeToken() async throws(GoogleReaderError) -> String {
        if let actionToken { return actionToken }
        let response = try await get("reader/api/0/token")
        let token = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw .malformedResponse("empty action token") }
        actionToken = token
        return token
    }

    // MARK: Reads

    public func subscriptions() async throws(GoogleReaderError) -> (feeds: [Feed], categories: [FeedCategory]) {
        let subs: SubscriptionListDTO = try await decode(get("reader/api/0/subscription/list"))
        let tags: TagListDTO = try await decode(get("reader/api/0/tag/list"))
        return Self.map(subscriptions: subs.subscriptions, tags: tags.tags)
    }

    static func map(subscriptions: [SubscriptionDTO], tags: [TagDTO]) -> (feeds: [Feed], categories: [FeedCategory]) {
        var categories: [CategoryID: FeedCategory] = [:]
        for tag in tags where tag.id.contains("/label/") && (tag.type == nil || tag.type == "folder") {
            let id = CategoryID(tag.id)
            categories[id] = FeedCategory(id: id, label: Self.label(fromStreamID: tag.id))
        }
        let feeds = subscriptions.map { sub -> Feed in
            let categoryIDs = sub.categories.map { ref -> CategoryID in
                let id = CategoryID(ref.id)
                if categories[id] == nil {
                    categories[id] = FeedCategory(id: id, label: ref.label ?? Self.label(fromStreamID: ref.id))
                }
                return id
            }
            return Feed(
                id: FeedID(sub.id), title: TextNormalizer.normalize(HTMLText.decodeEntities(sub.title)),
                siteURL: sub.htmlUrl.flatMap(URL.init(string:)), feedURL: sub.url.flatMap(URL.init(string:)),
                iconURL: sub.iconUrl.flatMap(URL.init(string:)), categoryIDs: categoryIDs)
        }
        return (feeds, categories.values.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending })
    }

    static func label(fromStreamID id: String) -> String {
        guard let range = id.range(of: "/label/") else { return id }
        return String(id[range.upperBound...])
    }

    public func unreadCounts() async throws(GoogleReaderError) -> [String: Int] {
        let dto: UnreadCountListDTO = try await decode(get("reader/api/0/unread-count"))
        return Dictionary(dto.unreadcounts.map { ($0.id, $0.count) }, uniquingKeysWith: { a, _ in a })
    }

    public func itemIDs(stream: String, excludeRead: Bool, newerThan: Date?, limit: Int) async throws(GoogleReaderError) -> [ArticleID] {
        var ids: [ArticleID] = []
        var seen = Set<String>()
        var continuation: String?
        repeat {
            var query = [URLQueryItem(name: "s", value: stream), URLQueryItem(name: "n", value: String(min(1000, limit - ids.count)))]
            if excludeRead { query.append(URLQueryItem(name: "xt", value: StreamID.read)) }
            if let newerThan { query.append(URLQueryItem(name: "ot", value: String(Int64(newerThan.timeIntervalSince1970)))) }
            if let continuation { query.append(URLQueryItem(name: "c", value: continuation)) }
            let dto: ItemRefsDTO = try await decode(get("reader/api/0/stream/items/ids", query: query))
            for ref in dto.itemRefs {
                guard let short = ItemID.shortForm(ref.id), seen.insert(short).inserted else { continue }
                ids.append(ArticleID(short))
            }
            // Stop if the server repeats a continuation or sends nothing new.
            if dto.itemRefs.isEmpty || dto.continuation == continuation { break }
            continuation = dto.continuation
        } while continuation != nil && ids.count < limit
        return ids
    }

    public func articles(ids: [ArticleID]) async throws(GoogleReaderError) -> [Article] {
        var result: [Article] = []
        for batch in ids.chunked(into: Self.contentsBatchSize) {
            var form = FormBody()
            for id in batch { form.append("i", id.rawValue) }
            let response = try await post("reader/api/0/stream/items/contents", form: form, needsActionToken: false)
            let dto: StreamContentsDTO = try decode(response)
            result.append(contentsOf: dto.items.compactMap(ArticleMapper.article(from:)))
        }
        return result
    }

    public func streamContents(stream: String, excludeRead: Bool, count: Int, continuation: String?)
        async throws(GoogleReaderError) -> (articles: [Article], continuation: String?)
    {
        var query = [URLQueryItem(name: "n", value: String(count))]
        if excludeRead { query.append(URLQueryItem(name: "xt", value: StreamID.read)) }
        if let continuation { query.append(URLQueryItem(name: "c", value: continuation)) }
        let encoded = stream.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? stream
        let dto: StreamContentsDTO = try await decode(get("reader/api/0/stream/contents/" + encoded, query: query))
        return (dto.items.compactMap(ArticleMapper.article(from:)), dto.continuation)
    }

    // MARK: Writes

    public func setRead(_ read: Bool, ids: [ArticleID]) async throws(GoogleReaderError) {
        try await editTag(ids: ids, add: read ? StreamID.read : nil, remove: read ? nil : StreamID.read)
    }

    public func setStarred(_ starred: Bool, ids: [ArticleID]) async throws(GoogleReaderError) {
        try await editTag(ids: ids, add: starred ? StreamID.starred : nil, remove: starred ? nil : StreamID.starred)
    }

    func editTag(ids: [ArticleID], add: String?, remove: String?) async throws(GoogleReaderError) {
        for batch in ids.chunked(into: Self.editBatchSize) {
            var form = FormBody()
            for id in batch { form.append("i", id.rawValue) }
            if let add { form.append("a", add) }
            if let remove { form.append("r", remove) }
            let response = try await post("reader/api/0/edit-tag", form: form, needsActionToken: true)
            guard response.text.trimmingCharacters(in: .whitespacesAndNewlines) == "OK" else {
                throw .malformedResponse("edit-tag answered \(response.text.prefix(60))")
            }
        }
    }

    public func markAllAsRead(stream: String, olderThan: Date) async throws(GoogleReaderError) {
        var form = FormBody()
        form.append("s", stream)
        form.append("ts", String(Int64(olderThan.timeIntervalSince1970 * 1_000_000)))
        _ = try await post("reader/api/0/mark-all-as-read", form: form, needsActionToken: true)
    }

    // MARK: Subscriptions

    /// FreshRSS fetches the feed itself when it's added.
    public func subscribe(feedURL: URL, title: String?, category: String?) async throws(GoogleReaderError) -> FeedID {
        var form = FormBody()
        form.append("quickadd", feedURL.absoluteString)
        let response = try await post("reader/api/0/subscription/quickadd", form: form, needsActionToken: true)
        guard let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let stream = json["streamId"] as? String, !stream.isEmpty
        else { throw .malformedResponse("the server couldn't add this feed") }
        if title != nil || category != nil {
            var edit = FormBody()
            edit.append("ac", "edit")
            edit.append("s", stream)
            if let title { edit.append("t", title) }
            if let category { edit.append("a", StreamID.label(category)) }
            _ = try await post("reader/api/0/subscription/edit", form: edit, needsActionToken: true)
        }
        return FeedID(stream)
    }

    public func unsubscribe(_ feed: FeedID) async throws(GoogleReaderError) {
        var form = FormBody()
        form.append("ac", "unsubscribe")
        form.append("s", feed.rawValue)
        _ = try await post("reader/api/0/subscription/edit", form: form, needsActionToken: true)
    }

    // MARK: Plumbing

    private func get(_ path: String, query: [URLQueryItem] = []) async throws(GoogleReaderError) -> HTTPResponse {
        try await authorized { token throws(GoogleReaderError) in
            HTTPRequest(method: .get, url: self.endpoint.url(path, query: query), headers: ["Authorization": "GoogleLogin auth=\(token)"])
        }
    }

    private func post(_ path: String, form: FormBody, needsActionToken: Bool) async throws(GoogleReaderError) -> HTTPResponse {
        var attemptedFreshActionToken = false
        while true {
            var body = form
            if needsActionToken { body.append("T", try await writeToken()) }
            let response = try await authorized { token throws(GoogleReaderError) in
                HTTPRequest(
                    method: .post, url: self.endpoint.url(path),
                    headers: ["Authorization": "GoogleLogin auth=\(token)", "Content-Type": "application/x-www-form-urlencoded"],
                    body: body.encoded)
            } acceptStatus: { status in
                // FreshRSS rejects a stale action token with 401 + "Bad token"
                // on some versions and 400 on others; retry those once with a
                // new token before giving up.
                needsActionToken && !attemptedFreshActionToken && (status == 400 || status == 401)
            }
            if needsActionToken && !attemptedFreshActionToken && (response.status == 400 || response.status == 401) {
                attemptedFreshActionToken = true
                actionToken = nil
                continue
            }
            return response
        }
    }

    /// Sends a request with the auth header, logging in first if needed and
    /// once more if the server says the session expired.
    private func authorized(
        _ build: (String) throws(GoogleReaderError) -> HTTPRequest,
        acceptStatus: (Int) -> Bool = { _ in false }
    ) async throws(GoogleReaderError) -> HTTPResponse {
        var retriedLogin = false
        while true {
            let token = try await login()
            let response = try await send(try build(token))
            if acceptStatus(response.status) { return response }
            switch response.status {
            case 200..<300:
                return response
            case 401 where !retriedLogin:
                retriedLogin = true
                authToken = nil
                actionToken = nil
            case 401, 403:
                throw .unauthorized
            case 404:
                throw .apiNotFound
            default:
                throw .server(status: response.status, message: response.text)
            }
        }
    }

    private func send(_ request: HTTPRequest) async throws(GoogleReaderError) -> HTTPResponse {
        do {
            return try await transport.send(request)
        } catch let error as TransportError {
            throw .transport(error)
        } catch {
            throw .transport(TransportError(kind: .other, message: String(describing: error)))
        }
    }

    private func decode<T: Decodable>(_ response: HTTPResponse) throws(GoogleReaderError) -> T {
        do {
            return try JSONDecoder().decode(T.self, from: response.body)
        } catch {
            throw .malformedResponse("\(T.self): \(error)")
        }
    }
}

extension Array {
    func chunked(into size: Int) -> [ArraySlice<Element>] {
        stride(from: 0, to: count, by: size).map { self[$0..<Swift.min($0 + size, count)] }
    }
}
