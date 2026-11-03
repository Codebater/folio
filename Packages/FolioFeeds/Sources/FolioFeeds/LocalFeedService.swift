import Foundation
import FolioCore
import FolioFreshRSS

/// A feed the reader follows without a server.
public struct LocalFeed: Codable, Sendable, Hashable, Identifiable {
    public var id: FeedID
    public var url: URL
    public var title: String
    public var siteURL: URL?
    /// A topic label, like a FreshRSS category ("Technology").
    public var category: String?
    public var lastFetchedAt: Date?
    /// Why the last fetch failed, in words for the reader.
    public var lastError: String?
    var etag: String?
    var lastModified: String?

    public static func id(for url: URL) -> FeedID { FeedID("feed/" + url.absoluteString) }
}

/// Paperwire's reading list on this iPhone, for people without a FreshRSS
/// server. It fetches the feeds itself and answers the sync engine like a
/// Google Reader server would, so lists, full text, stations and narration
/// work exactly as with FreshRSS. Everything stays in one JSON file.
public actor LocalFeedService: ReaderService, RefreshingReaderService, FeedSubscribing {
    struct Item: Codable {
        var article: Article
        /// When this phone first saw it; feeds without dates sort by it.
        var firstSeen: Date
    }

    struct State: Codable {
        var feeds: [LocalFeed] = []
        var items: [String: Item] = [:]
    }

    /// Feeds fetched at once.
    static let parallelFetches = 6
    /// Stories older than this when a feed is added start out read, so a
    /// new reading list opens on today's news, not a backlog.
    static let freshForNewFeeds: TimeInterval = 2 * 86_400
    /// Unread stories a newly added feed brings at most.
    static let unreadForNewFeeds = 30
    /// Stories kept per feed (starred ones are always kept).
    static let keptPerFeed = 150
    /// Read stories older than this are forgotten (the store keeps its own copy).
    static let retention: TimeInterval = 60 * 86_400
    /// A sync within this time of the last one doesn't fetch again.
    static let minimumInterval: TimeInterval = 30

    private let stateURL: URL?
    private let transport: any HTTPTransport
    private let clock: any FolioClock
    private var state: State
    private var lastRefresh: Date?

    /// `stateURL` nil keeps everything in memory (tests).
    public init(stateURL: URL?, transport: any HTTPTransport, clock: any FolioClock = SystemClock()) {
        self.stateURL = stateURL
        self.transport = transport
        self.clock = clock
        if let stateURL, let data = try? Data(contentsOf: stateURL), let saved = try? JSONDecoder().decode(State.self, from: data) {
            state = saved
        } else {
            state = State()
        }
    }

    public var feeds: [LocalFeed] { state.feeds }

    // MARK: Subscribing

    public func subscribe(feedURL: URL, title: String?, category: String?) async throws(GoogleReaderError) -> FeedID {
        let id = LocalFeed.id(for: feedURL)
        if let index = state.feeds.firstIndex(where: { $0.id == id }) {
            if let category { state.feeds[index].category = category }
            if let title, !title.isEmpty { state.feeds[index].title = title }
        } else {
            state.feeds.append(LocalFeed(id: id, url: feedURL, title: title ?? feedURL.host ?? feedURL.absoluteString, category: category))
        }
        save()
        return id
    }

    public func unsubscribe(_ feed: FeedID) async throws(GoogleReaderError) {
        state.feeds.removeAll { $0.id == feed }
        state.items = state.items.filter { $0.value.article.feedID != feed || $0.value.article.isStarred }
        save()
    }

    // MARK: Fetching

    /// Fetches every feed (only what changed, where servers say so) and adds
    /// new stories. A feed that fails keeps its stories and says why.
    public func refresh() async {
        let now = clock.now
        let neverFetched = state.feeds.contains { $0.lastFetchedAt == nil }
        if let lastRefresh, now.timeIntervalSince(lastRefresh) < Self.minimumInterval, !neverFetched { return }
        lastRefresh = now

        let feeds = state.feeds
        var outcomes: [(FeedID, FetchOutcome)] = []
        for start in stride(from: 0, to: feeds.count, by: Self.parallelFetches) {
            let batch = feeds[start..<min(start + Self.parallelFetches, feeds.count)]
            let transport = transport
            await withTaskGroup(of: (FeedID, FetchOutcome).self) { group in
                for feed in batch {
                    group.addTask { (feed.id, await Self.fetch(feed, transport: transport)) }
                }
                for await outcome in group { outcomes.append(outcome) }
            }
        }
        for (id, outcome) in outcomes { apply(outcome, to: id, now: now) }
        prune(now: now)
        save()
    }

    enum FetchOutcome: Sendable {
        case unchanged
        case fetched(ParsedFeed, etag: String?, lastModified: String?)
        case failed(String)
    }

    static func fetch(_ feed: LocalFeed, transport: any HTTPTransport) async -> FetchOutcome {
        var headers = ["Accept": "application/rss+xml, application/atom+xml, application/feed+json, application/xml;q=0.9, */*;q=0.5"]
        if let etag = feed.etag { headers["If-None-Match"] = etag }
        if let lastModified = feed.lastModified { headers["If-Modified-Since"] = lastModified }
        do {
            let response = try await transport.send(HTTPRequest(url: feed.url, headers: headers))
            if response.status == 304 { return .unchanged }
            guard (200..<300).contains(response.status) else { return .failed("The site answered \(response.status).") }
            guard let parsed = try? FeedParser.parse(response.body, url: feed.url) else { return .failed("This address no longer has a feed.") }
            return .fetched(parsed, etag: response.headers["etag"], lastModified: response.headers["last-modified"])
        } catch let error as TransportError {
            return .failed(error.kind == .offline ? "You're offline." : "Couldn't reach the site.")
        } catch {
            return .failed("Couldn't reach the site.")
        }
    }

    private func apply(_ outcome: FetchOutcome, to id: FeedID, now: Date) {
        guard let index = state.feeds.firstIndex(where: { $0.id == id }) else { return }
        let isNew = state.feeds[index].lastFetchedAt == nil
        switch outcome {
        case .unchanged:
            state.feeds[index].lastFetchedAt = now
            state.feeds[index].lastError = nil
        case .failed(let message):
            state.feeds[index].lastError = message
        case .fetched(let parsed, let etag, let lastModified):
            state.feeds[index].lastFetchedAt = now
            state.feeds[index].lastError = nil
            state.feeds[index].etag = etag
            state.feeds[index].lastModified = lastModified
            if state.feeds[index].siteURL == nil { state.feeds[index].siteURL = parsed.siteURL }
            merge(parsed.items, into: state.feeds[index], isNew: isNew, now: now)
        }
    }

    private func merge(_ items: [ParsedItem], into feed: LocalFeed, isNew: Bool, now: Date) {
        var unreadBudget = Self.unreadForNewFeeds
        // Newest first, so a new feed's unread stories are its latest ones.
        let ordered = items.sorted { ($0.published ?? now) > ($1.published ?? now) }
        for item in ordered {
            let id = Self.articleID(feed: feed.url, item: item)
            if var existing = state.items[id.rawValue] {
                // Edited stories keep their read and starred state.
                existing.article.title = item.title.isEmpty ? existing.article.title : item.title
                existing.article.contentHTML = item.html.isEmpty ? existing.article.contentHTML : item.html
                existing.article.updatedAt = item.updated
                state.items[id.rawValue] = existing
                continue
            }
            let published = item.published ?? now
            var isRead = false
            if isNew {
                isRead = now.timeIntervalSince(published) > Self.freshForNewFeeds || unreadBudget <= 0
                if !isRead { unreadBudget -= 1 }
            }
            let article = Article(
                id: id, feedID: feed.id, title: item.title.isEmpty ? "Untitled" : item.title, author: item.author, url: item.url,
                contentHTML: item.html, publishedAt: min(published, now), updatedAt: item.updated, crawledAt: now,
                isRead: isRead, enclosures: item.enclosures)
            state.items[id.rawValue] = Item(article: article, firstSeen: now)
        }
    }

    private func prune(now: Date) {
        let feedIDs = Set(state.feeds.map(\.id))
        var perFeed: [FeedID: [Item]] = [:]
        for item in state.items.values { perFeed[item.article.feedID, default: []].append(item) }
        var kept: [String: Item] = [:]
        for (feed, items) in perFeed {
            let newest = items.sorted { $0.article.publishedAt > $1.article.publishedAt }
            for (rank, item) in newest.enumerated() {
                let article = item.article
                let tooOld = article.isRead && now.timeIntervalSince(article.publishedAt) > Self.retention
                if article.isStarred || (feedIDs.contains(feed) && rank < Self.keptPerFeed && !tooOld) {
                    kept[article.id.rawValue] = item
                }
            }
        }
        state.items = kept
    }

    /// Stable across fetches and phones: the feed address and the story's own id.
    static func articleID(feed: URL, item: ParsedItem) -> ArticleID {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in (feed.absoluteString + "\n" + item.identity).utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
        }
        return ArticleID("l" + String(hash, radix: 16))
    }

    private func save() {
        guard let stateURL else { return }
        do {
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
        } catch {
            // The next save tries again; the store still has every story.
        }
    }

    // MARK: ReaderService

    public func verifyCredentials() async throws(GoogleReaderError) {}

    public func subscriptions() async throws(GoogleReaderError) -> (feeds: [Feed], categories: [FeedCategory]) {
        let feeds = state.feeds.map { feed in
            Feed(id: feed.id, title: feed.title, siteURL: feed.siteURL, feedURL: feed.url,
                 categoryIDs: feed.category.map { [CategoryID(StreamID.label($0))] } ?? [])
        }
        let labels = Set(state.feeds.compactMap(\.category)).sorted()
        return (feeds, labels.map { FeedCategory(id: CategoryID(StreamID.label($0)), label: $0) })
    }

    public func unreadCounts() async throws(GoogleReaderError) -> [String: Int] {
        var counts: [String: Int] = [:]
        for item in state.items.values where !item.article.isRead {
            for stream in streams(of: item.article) { counts[stream, default: 0] += 1 }
        }
        return counts
    }

    public func itemIDs(stream: String, excludeRead: Bool, newerThan: Date?, limit: Int) async throws(GoogleReaderError) -> [ArticleID] {
        Array(select(stream: stream, excludeRead: excludeRead, newerThan: newerThan).prefix(limit).map(\.id))
    }

    public func articles(ids: [ArticleID]) async throws(GoogleReaderError) -> [Article] {
        ids.compactMap { state.items[$0.rawValue]?.article }
    }

    public func streamContents(stream: String, excludeRead: Bool, count: Int, continuation: String?)
        async throws(GoogleReaderError) -> (articles: [Article], continuation: String?) {
        let all = select(stream: stream, excludeRead: excludeRead, newerThan: nil)
        let start = continuation.flatMap(Int.init) ?? 0
        let page = Array(all.dropFirst(start).prefix(count))
        return (page, start + page.count < all.count ? String(start + page.count) : nil)
    }

    public func setRead(_ read: Bool, ids: [ArticleID]) async throws(GoogleReaderError) {
        for id in ids { state.items[id.rawValue]?.article.isRead = read }
        save()
    }

    public func setStarred(_ starred: Bool, ids: [ArticleID]) async throws(GoogleReaderError) {
        for id in ids { state.items[id.rawValue]?.article.isStarred = starred }
        save()
    }

    public func markAllAsRead(stream: String, olderThan: Date) async throws(GoogleReaderError) {
        for (key, item) in state.items where streams(of: item.article).contains(stream) && item.article.publishedAt <= olderThan {
            state.items[key]?.article.isRead = true
        }
        save()
    }

    private func streams(of article: Article) -> Set<String> {
        var result: Set<String> = [StreamID.readingList, article.feedID.rawValue]
        if let label = state.feeds.first(where: { $0.id == article.feedID })?.category { result.insert(StreamID.label(label)) }
        if article.isRead { result.insert(StreamID.read) }
        if article.isStarred { result.insert(StreamID.starred) }
        return result
    }

    private func select(stream: String, excludeRead: Bool, newerThan: Date?) -> [Article] {
        state.items.values.map(\.article)
            .filter { article in
                streams(of: article).contains(stream) && !(excludeRead && article.isRead)
                    && (newerThan.map { article.publishedAt >= $0 } ?? true)
            }
            .sorted { $0.publishedAt != $1.publishedAt ? $0.publishedAt > $1.publishedAt : $0.id.rawValue < $1.id.rawValue }
    }
}
