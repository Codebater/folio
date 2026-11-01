import Foundation
import Testing
import FolioCore
@testable import FolioStorage

struct FixedClock: FolioClock {
    var now: Date
}

func article(_ id: String, feed: String = "feed/1", daysAgo: Double = 0, read: Bool = false, starred: Bool = false,
             now: Date = Date(timeIntervalSince1970: 1_761_900_000)) -> StoredArticle {
    StoredArticle(
        article: Article(id: ArticleID(id), feedID: FeedID(feed), title: "Article \(id)", contentHTML: "<p>Body \(id)</p>",
                         publishedAt: now.addingTimeInterval(-daysAgo * 86_400), isRead: read, isStarred: starred),
        excerpt: "Body \(id)", wordCount: 230)
}

@Suite("Article store")
struct ArticleStoreTests {
    let now = Date(timeIntervalSince1970: 1_761_900_000)

    func makeStore() async throws -> ArticleStore {
        let store = try ArticleStore.inMemory(clock: FixedClock(now: now))
        try await store.replaceSubscriptions(
            feeds: [Feed(id: "feed/1", title: "One", categoryIDs: ["user/-/label/A"]),
                    Feed(id: "feed/2", title: "Two", categoryIDs: ["user/-/label/B"])],
            categories: [FeedCategory(id: "user/-/label/A", label: "A"), FeedCategory(id: "user/-/label/B", label: "B")])
        return store
    }

    @Test func persistsAcrossReopen() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("folio-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("folio.sqlite").path
        do {
            let store = try ArticleStore(path: path)
            try await store.replaceSubscriptions(feeds: [Feed(id: "feed/1", title: "One")], categories: [])
            try await store.upsert([article("1")])
            try await store.saveReadingPosition(ReadingPosition(articleID: "1", blockID: "b3", offset: 12, progress: 0.4, updatedAt: now))
        }
        let reopened = try ArticleStore(path: path)
        #expect(try await reopened.article("1")?.article.title == "Article 1")
        #expect(try await reopened.readingPosition(for: "1")?.blockID == "b3")
    }

    @Test func queriesByScopeFilterAndPage() async throws {
        let store = try await makeStore()
        try await store.upsert([
            article("1", daysAgo: 3), article("2", daysAgo: 2, read: true), article("3", feed: "feed/2", daysAgo: 1, starred: true),
            article("4", feed: "feed/2", daysAgo: 0),
        ])
        #expect(try await store.summaries(ArticleQuery()).map(\.id.rawValue) == ["4", "3", "2", "1"])
        #expect(try await store.summaries(ArticleQuery(filter: .unread)).map(\.id.rawValue) == ["4", "3", "1"])
        #expect(try await store.summaries(ArticleQuery(filter: .starred)).map(\.id.rawValue) == ["3"])
        #expect(try await store.summaries(ArticleQuery(scope: .feed("feed/1"))).map(\.id.rawValue) == ["2", "1"])
        #expect(try await store.summaries(ArticleQuery(scope: .category("user/-/label/B"))).map(\.id.rawValue) == ["4", "3"])

        let firstPage = try await store.summaries(ArticleQuery(limit: 2))
        let last = try #require(firstPage.last)
        let secondPage = try await store.summaries(ArticleQuery(limit: 2, before: (last.publishedAt, last.id)))
        #expect(firstPage.map(\.id.rawValue) + secondPage.map(\.id.rawValue) == ["4", "3", "2", "1"])
        #expect(firstPage.first?.feedTitle == "Two")
        #expect(firstPage.first?.estimatedReadingMinutes == 1)
    }

    @Test func countsUnreadPerFeedAndCategory() async throws {
        let store = try await makeStore()
        try await store.upsert([article("1"), article("2", read: true), article("3", feed: "feed/2", starred: true)])
        let counts = try await store.unreadCounts()
        #expect(counts.total == 2)
        #expect(counts.byFeed["feed/1"] == 1)
        #expect(counts.byCategory["user/-/label/B"] == 1)
        #expect(counts.starred == 1)
    }

    @Test func coalescesPendingChanges() async throws {
        let store = try await makeStore()
        try await store.upsert([article("1"), article("2")])
        try await store.setRead(true, ids: ["1", "2"])
        try await store.setRead(false, ids: ["1"])
        try await store.setRead(true, ids: ["1"])
        try await store.setStarred(true, ids: ["2"])
        let pending = try await store.pendingChanges()
        #expect(Set(pending) == [
            PendingChange(articleID: "1", attribute: .read, value: true), PendingChange(articleID: "2", attribute: .read, value: true),
            PendingChange(articleID: "2", attribute: .starred, value: true),
        ])
        // Re-setting the current value does not queue anything new.
        try await store.setStarred(true, ids: ["2"])
        #expect(try await store.pendingChanges().count == 3)
    }

    @Test func confirmedChangesClearOnlyIfUnchanged() async throws {
        let store = try await makeStore()
        try await store.upsert([article("1")])
        try await store.setRead(true, ids: ["1"])
        let inFlight = try await store.pendingChanges()
        try await store.setRead(false, ids: ["1"])  // user flips back while the request is in flight
        try await store.clearPending(inFlight)
        #expect(try await store.pendingChanges() == [PendingChange(articleID: "1", attribute: .read, value: false)])
    }

    @Test func localChangesWinOverServerState() async throws {
        let store = try await makeStore()
        try await store.upsert([article("1"), article("2"), article("3")])
        try await store.setRead(true, ids: ["1"])  // offline: read locally, not yet pushed
        // Server still thinks 1 is unread; 2 was read elsewhere; 3 starred elsewhere.
        try await store.applyServerState(unreadIDs: ["1", "3"], starredIDs: ["3"])
        let byID = Dictionary(uniqueKeysWithValues: try await store.summaries(ArticleQuery()).map { ($0.id.rawValue, $0) })
        #expect(byID["1"]?.isRead == true)
        #expect(byID["2"]?.isRead == true)
        #expect(byID["3"]?.isRead == false && byID["3"]?.isStarred == true)

        // A re-download of article 1 with server flags also keeps the local value.
        try await store.upsert([article("1", read: false)])
        #expect(try await store.article("1")?.article.isRead == true)
    }

    @Test func truncatedUnreadSetNeverMarksRead() async throws {
        let store = try await makeStore()
        try await store.upsert([article("1"), article("2")])
        try await store.applyServerState(unreadIDs: ["1"], starredIDs: [], unreadIsComplete: false)
        #expect(try await store.article("2")?.article.isRead == false)
    }

    @Test func removesFeedsButKeepsStarredArticles() async throws {
        let store = try await makeStore()
        try await store.upsert([article("1", feed: "feed/2"), article("2", feed: "feed/2", starred: true)])
        try await store.replaceSubscriptions(feeds: [Feed(id: "feed/1", title: "One")], categories: [])
        #expect(try await store.feeds().map(\.id.rawValue) == ["feed/1"])
        #expect(try await store.allArticleIDs() == ["2"])
        #expect(try await store.categories().isEmpty)
    }

    @Test func prunesOnlyDisposableArticles() async throws {
        let store = try await makeStore()
        try await store.upsert([
            article("old-read", daysAgo: 60, read: true), article("old-unread", daysAgo: 60),
            article("old-starred", daysAgo: 60, read: true, starred: true), article("new-read", daysAgo: 1, read: true),
            article("old-downloaded", daysAgo: 60, read: true), article("old-pending", daysAgo: 60, read: false),
        ])
        try await store.setDownloaded(true, id: "old-downloaded")
        try await store.setRead(true, ids: ["old-pending"])
        let removed = try await store.pruneArticles(olderThan: now.addingTimeInterval(-30 * 86_400))
        #expect(removed == 1)
        #expect(try await store.allArticleIDs() == ["old-unread", "old-starred", "new-read", "old-downloaded", "old-pending"])
    }

    @Test func savesPositionsHighlightsAndKeys() async throws {
        let store = try await makeStore()
        try await store.upsert([article("1")])
        try await store.saveReadingPosition(ReadingPosition(articleID: "1", blockID: "b2", offset: 5, progress: 0.5, updatedAt: now))
        try await store.saveReadingPosition(ReadingPosition(articleID: "1", blockID: "b4", offset: 0, progress: 0.7, updatedAt: now))
        #expect(try await store.readingPosition(for: "1")?.blockID == "b4")
        #expect(try await store.summaries(ArticleQuery(filter: .inProgress)).map(\.id.rawValue) == ["1"])

        let highlight = Highlight(articleID: "1", blockID: "b2", start: 3, end: 9, note: "Nice")
        try await store.addHighlight(highlight)
        try await store.addHighlight(Highlight(articleID: "1", kind: .bookmark, blockID: "b5", start: 0, end: 0))
        #expect(try await store.highlights(for: "1").count == 2)
        try await store.removeHighlight(id: highlight.id)
        #expect(try await store.highlights(for: "1").map(\.kind) == [.bookmark])

        try await store.setValue("x", forKey: "k")
        #expect(try await store.value(forKey: "k") == "x")
        try await store.setValue(nil, forKey: "k")
        #expect(try await store.value(forKey: "k") == nil)
    }

    @Test func handlesUnicodeAndLargeContent() async throws {
        let store = try await makeStore()
        var item = article("1")
        item.article.title = "Ako sa rodí ranná správa — 日本 \u{1F600}"
        item.article.contentHTML = String(repeating: "<p>Žluťoučký kůň úpěl ďábelské ódy.</p>", count: 5000)
        try await store.upsert([item])
        let loaded = try #require(try await store.article("1"))
        #expect(loaded.article.title == item.article.title)
        #expect(loaded.article.contentHTML == item.article.contentHTML)
    }

    @Test func findsUnreadArticlesMatchingMuteRules() async throws {
        let store = try await makeStore()
        var crypto = article("1")
        crypto.article.title = "Crypto prices crash again"
        var other = article("2")
        other.article.title = "A quiet morning"
        var readCrypto = article("3", read: true)
        readCrypto.article.title = "More crypto news"
        try await store.upsert([crypto, other, readCrypto])
        #expect(try await store.unreadArticles(matching: MuteRules(terms: ["crypto"])) == ["1"])
        #expect(try await store.unreadArticles(matching: MuteRules()).isEmpty)
        #expect(try await store.stats().databaseBytes > 0)
    }

    @Test func countsLanguages() async throws {
        let store = try await makeStore()
        var a = article("1"); a.language = LanguageCode("de-AT")
        var b = article("2"); b.language = .german
        var c = article("3"); c.language = .english
        try await store.upsert([a, b, c, article("4")])
        let counts = try await store.languageCounts()
        #expect(counts.map(\.language) == ["de", "en"])
        #expect(counts.first?.count == 2)
    }

    @Test func markAllReadQueuesEveryArticle() async throws {
        let store = try await makeStore()
        try await store.upsert([article("1", daysAgo: 2), article("2", daysAgo: 1), article("3", feed: "feed/2")])
        let marked = try await store.markAllRead(scope: .feed("feed/1"), olderThan: now)
        #expect(Set(marked) == ["1", "2"])
        #expect(try await store.stats().pendingChanges == 2)
        #expect(try await store.stats().unread == 1)
    }
}

@Suite("Full text storage")
struct FullTextStorageTests {
    let now = Date(timeIntervalSince1970: 1_761_900_000)

    private func summary(_ id: String, words: Int, daysAgo: Double = 0, read: Bool = false) -> StoredArticle {
        StoredArticle(
            article: Article(id: ArticleID(id), feedID: "feed/1", title: "Article \(id)", url: URL(string: "https://example.com/\(id)"),
                             contentHTML: "<p>Short summary \(id).</p>", publishedAt: now.addingTimeInterval(-daysAgo * 86_400),
                             isRead: read),
            excerpt: "Short summary \(id).", wordCount: words)
    }

    @Test func fullTextIsKeptBesideTheSummaryAndSurvivesSync() async throws {
        let store = try ArticleStore.inMemory(clock: FixedClock(now: now))
        try await store.upsert([summary("1", words: 30)])
        try await store.setFullText("<p>The whole article.</p>", wordCount: 900, for: "1")
        var stored = try #require(try await store.article("1"))
        #expect(stored.fullHTML == "<p>The whole article.</p>" && stored.fullTextStatus == .fetched && stored.wordCount == 900)
        #expect(stored.article.contentHTML == "<p>Short summary 1.</p>")  // the feed's version stays
        // The next sync brings the summary again: full text and its word count stay.
        try await store.upsert([summary("1", words: 30)])
        stored = try #require(try await store.article("1"))
        #expect(stored.fullHTML != nil && stored.wordCount == 900)
    }

    @Test func fullTextLanguageWinsAndFeedsCountLanguages() async throws {
        let store = try ArticleStore.inMemory(clock: FixedClock(now: now))
        var guessedFrench = summary("1", words: 30)
        guessedFrench.language = .french  // guessed from a two-line summary
        var english = summary("2", words: 30)
        english.language = LanguageCode("en-US")
        try await store.upsert([guessedFrench, english])
        try await store.setFullText("<p>The whole article.</p>", wordCount: 900, language: .english, for: "1")
        #expect(try await store.article("1")?.language == .english)
        // The next sync's summary guess doesn't undo it.
        try await store.upsert([guessedFrench])
        #expect(try await store.article("1")?.language == .english)
        #expect(try await store.feedLanguageCounts() == ["feed/1": ["en": 2]])
    }

    @Test func unavailablePagesAreNotRetriedUntilAsked() async throws {
        let store = try ArticleStore.inMemory(clock: FixedClock(now: now))
        try await store.upsert([summary("1", words: 30), summary("2", words: 40, daysAgo: 1), summary("3", words: 900),
                                summary("4", words: 20, read: true), summary("5", words: 20, daysAgo: 9)])
        let week = now.addingTimeInterval(-3 * 86_400)
        #expect(try await store.articlesNeedingFullText(publishedAfter: week, maxWords: 250, limit: 10).map(\.id.rawValue) == ["1", "2"])
        try await store.markFullTextUnavailable("1")
        #expect(try await store.article("1")?.fullTextStatus == .unavailable)
        #expect(try await store.articlesNeedingFullText(publishedAfter: week, maxWords: 250, limit: 10).map(\.id.rawValue) == ["2"])
        try await store.resetFullText("1")
        #expect(try await store.article("1")?.fullTextStatus == .notTried)
        // A fetched article is never marked unavailable afterwards.
        try await store.setFullText("<p>x</p>", wordCount: 500, for: "2")
        try await store.markFullTextUnavailable("2")
        #expect(try await store.article("2")?.fullTextStatus == .fetched)
    }

    @Test func databasesFromEarlierBuildsUpgrade() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("folio-migrate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("folio.sqlite").path
        do {
            let store = try ArticleStore(path: path)
            try await store.upsert([summary("1", words: 30)])
        }
        // Turn it back into a version 1 database, as on phones with build 10.
        do {
            let db = try SQLiteConnection(path: path)
            try db.execute("""
                ALTER TABLE articles DROP COLUMN full_html;
                ALTER TABLE articles DROP COLUMN full_status;
                ALTER TABLE articles DROP COLUMN full_checked_at;
                """)
            try db.setUserVersion(1)
        }
        let upgraded = try ArticleStore(path: path)
        let stored = try #require(try await upgraded.article("1"))
        #expect(stored.article.title == "Article 1" && stored.fullTextStatus == .notTried)
        try await upgraded.setFullText("<p>Full.</p>", wordCount: 400, for: "1")
        #expect(try await upgraded.article("1")?.fullTextStatus == .fetched)
    }
}
