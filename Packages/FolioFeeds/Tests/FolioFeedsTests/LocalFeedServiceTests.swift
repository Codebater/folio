import Foundation
import Testing
import FolioCore
import FolioFreshRSS
import FolioStorage
import FolioSync
@testable import FolioFeeds

/// A clock tests can move forward.
final class TestClock: FolioClock, @unchecked Sendable {
    var now: Date
    init(now: Date) { self.now = now }
}

@Suite("Reading list on this iPhone")
struct LocalFeedServiceTests {
    // 2026-11-03 12:00 UTC
    let now = Date(timeIntervalSince1970: 1_793_707_200)
    let tech = URL(string: "https://tech.example/feed")!
    let news = URL(string: "https://news.example/rss")!

    func transport() -> FakeTransport {
        FakeTransport([
            tech.absoluteString: .ok(Fixtures.rss(title: "Tech", items: [
                ("t1", "Today in tech", "Tue, 03 Nov 2026 09:00:00 GMT"),
                ("t2", "Yesterday in tech", "Mon, 02 Nov 2026 09:00:00 GMT"),
                ("t3", "Last week", "Mon, 26 Oct 2026 09:00:00 GMT"),
            ])),
            news.absoluteString: .ok(Fixtures.rss(title: "News", items: [("n1", "Headline", "Tue, 03 Nov 2026 11:00:00 GMT")])),
        ])
    }

    @Test func newFeedsOpenOnRecentStoriesAndKeepTheirTopics() async throws {
        let service = LocalFeedService(stateURL: nil, transport: transport(), clock: TestClock(now: now))
        _ = try await service.subscribe(feedURL: tech, title: "Tech Daily", category: "Technology")
        _ = try await service.subscribe(feedURL: news, title: nil, category: "News")
        await service.refresh()

        let (feeds, categories) = try await service.subscriptions()
        #expect(feeds.map(\.title) == ["Tech Daily", "news.example"])
        #expect(Set(categories.map(\.label)) == ["Technology", "News"])
        #expect(feeds[0].categoryIDs == [CategoryID(StreamID.label("Technology"))])

        // The story from last week starts out read; the two recent ones don't.
        let unread = try await service.itemIDs(stream: StreamID.readingList, excludeRead: true, newerThan: nil, limit: 100)
        let all = try await service.itemIDs(stream: StreamID.readingList, excludeRead: false, newerThan: nil, limit: 100)
        #expect(all.count == 4 && unread.count == 3)
        let titles = try await service.articles(ids: unread).map(\.title)
        #expect(titles == ["Headline", "Today in tech", "Yesterday in tech"])  // newest first
        let counts = try await service.unreadCounts()
        #expect(counts[StreamID.label("Technology")] == 2)
    }

    @Test func laterFetchesAddOnlyNewStoriesAndKeepState() async throws {
        let transport = transport()
        let clock = TestClock(now: now)
        let service = LocalFeedService(stateURL: nil, transport: transport, clock: clock)
        _ = try await service.subscribe(feedURL: tech, title: nil, category: nil)
        await service.refresh()
        let first = try await service.itemIDs(stream: StreamID.readingList, excludeRead: true, newerThan: nil, limit: 10)
        try await service.setRead(true, ids: [first[0]])
        try await service.setStarred(true, ids: [first[1]])

        // An hour later the feed has one more story, and the old ones again.
        await transport.set(tech.absoluteString, .ok(Fixtures.rss(title: "Tech", items: [
            ("t0", "Breaking tech", "Tue, 03 Nov 2026 12:30:00 GMT"),
            ("t1", "Today in tech (updated)", "Tue, 03 Nov 2026 09:00:00 GMT"),
            ("t2", "Yesterday in tech", "Mon, 02 Nov 2026 09:00:00 GMT"),
        ])))
        clock.now = now.addingTimeInterval(3600)
        await service.refresh()
        let unread = try await service.itemIDs(stream: StreamID.readingList, excludeRead: true, newerThan: nil, limit: 10)
        let articles = try await service.articles(ids: unread)
        #expect(articles.map(\.title) == ["Breaking tech", "Yesterday in tech"])
        let starred = try await service.itemIDs(stream: StreamID.starred, excludeRead: false, newerThan: nil, limit: 10)
        #expect(starred == [first[1]])
        let edited = try await service.articles(ids: [first[0]])
        #expect(edited.first?.title == "Today in tech (updated)" && edited.first?.isRead == true)
        // The second fetch asked whether anything changed.
        #expect(await transport.requests.last?.headers["If-None-Match"] == "\"v1\"")
    }

    @Test func failuresAreKeptPerFeedAndStateSurvivesARestart() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("folio-local-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("feeds.json")
        let transport = transport()
        await transport.set(news.absoluteString, .status(500))
        let service = LocalFeedService(stateURL: file, transport: transport, clock: TestClock(now: now))
        _ = try await service.subscribe(feedURL: tech, title: nil, category: "Technology")
        _ = try await service.subscribe(feedURL: news, title: nil, category: "News")
        await service.refresh()
        let feeds = await service.feeds
        #expect(feeds.first { $0.url == news }?.lastError == "The site answered 500.")
        #expect(feeds.first { $0.url == tech }?.lastError == nil)

        let reopened = LocalFeedService(stateURL: file, transport: transport, clock: TestClock(now: now))
        #expect(try await reopened.itemIDs(stream: StreamID.readingList, excludeRead: false, newerThan: nil, limit: 10).count == 3)
        try await reopened.unsubscribe(LocalFeed.id(for: tech))
        #expect(try await reopened.subscriptions().feeds.map(\.feedURL) == [news])
        #expect(try await reopened.itemIDs(stream: StreamID.readingList, excludeRead: false, newerThan: nil, limit: 10).isEmpty)
    }

    @Test func syncFillsTheStoreLikeAServer() async throws {
        let service = LocalFeedService(stateURL: nil, transport: transport(), clock: TestClock(now: now))
        _ = try await service.subscribe(feedURL: tech, title: "Tech", category: "Technology")
        _ = try await service.subscribe(feedURL: news, title: "News", category: "News")
        let store = try ArticleStore.inMemory(clock: TestClock(now: now))
        let engine = SyncEngine(service: service, store: store, clock: TestClock(now: now))
        let report = try await engine.sync()
        #expect(report.feeds == 2 && report.newArticles == 4)
        #expect(try await store.feeds().map(\.title).sorted() == ["News", "Tech"])
        #expect(try await store.stats().unread == 3)

        // Reading on the phone goes back to the service at the next sync.
        let unread = try await service.itemIDs(stream: StreamID.readingList, excludeRead: true, newerThan: nil, limit: 10)
        try await store.setRead(true, ids: [unread[0]])
        _ = try await engine.sync()
        #expect(try await service.unreadCounts()[StreamID.readingList] == 2)
    }
}
