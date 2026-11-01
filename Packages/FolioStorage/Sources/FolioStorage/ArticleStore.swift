import Foundation
import FolioCore

/// Whether Folio fetched the full article from the publisher's page, for
/// feeds that only send a summary.
public enum FullTextStatus: Int, Sendable {
    case notTried = 0
    case fetched = 1
    /// Blocked, paywalled or no article on the page; not tried again on its own.
    case unavailable = 2
}

/// An article plus what Folio derived from it at sync time.
public struct StoredArticle: Hashable, Sendable {
    public var article: Article
    public var excerpt: String
    public var leadImageURL: URL?
    public var wordCount: Int
    public var language: LanguageCode?
    public var isDownloaded: Bool
    /// The article from the publisher's page, kept beside the feed's summary.
    public var fullHTML: String?
    public var fullTextStatus: FullTextStatus

    public init(article: Article, excerpt: String = "", leadImageURL: URL? = nil, wordCount: Int = 0,
                language: LanguageCode? = nil, isDownloaded: Bool = false, fullHTML: String? = nil,
                fullTextStatus: FullTextStatus = .notTried) {
        self.article = article
        self.excerpt = excerpt
        self.leadImageURL = leadImageURL
        self.wordCount = wordCount
        self.language = language
        self.isDownloaded = isDownloaded
        self.fullHTML = fullHTML
        self.fullTextStatus = fullTextStatus
    }
}

/// A local change not yet confirmed by the server. Only the latest wanted
/// value per article and attribute is kept, so toggling read/unread offline
/// ten times sends one request.
public struct PendingChange: Hashable, Sendable {
    public enum Attribute: String, Sendable, CaseIterable { case read, starred }

    public var articleID: ArticleID
    public var attribute: Attribute
    public var value: Bool

    public init(articleID: ArticleID, attribute: Attribute, value: Bool) {
        self.articleID = articleID
        self.attribute = attribute
        self.value = value
    }
}

public struct Highlight: Hashable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case highlight, bookmark }

    public var id: String
    public var articleID: ArticleID
    public var kind: Kind
    public var blockID: String
    public var start: Int
    public var end: Int
    public var color: String
    public var note: String?
    public var createdAt: Date

    public init(id: String = UUID().uuidString, articleID: ArticleID, kind: Kind = .highlight, blockID: String,
                start: Int, end: Int, color: String = "yellow", note: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.articleID = articleID
        self.kind = kind
        self.blockID = blockID
        self.start = start
        self.end = end
        self.color = color
        self.note = note
        self.createdAt = createdAt
    }
}

public struct StorageStats: Hashable, Sendable {
    public var articles: Int
    public var unread: Int
    public var starred: Int
    public var downloaded: Int
    public var pendingChanges: Int
    /// Size of the SQLite database (pages in use, not counting the WAL).
    public var databaseBytes: Int64
}

/// Folio's offline database. Everything the app shows comes from here; sync
/// writes into it. Readable without any server connection.
public actor ArticleStore {
    private let db: SQLiteConnection
    private let clock: any FolioClock

    public static let schemaVersion = 2

    /// Opens (and creates or migrates) the database at `path`. Use
    /// `":memory:"` for a throwaway store.
    public init(path: String, clock: any FolioClock = SystemClock()) throws {
        db = try SQLiteConnection(path: path)
        self.clock = clock
        try Self.migrate(db)
    }

    public static func inMemory(clock: any FolioClock = SystemClock()) throws -> ArticleStore {
        try ArticleStore(path: ":memory:", clock: clock)
    }

    static func migrate(_ db: SQLiteConnection) throws {
        let version = db.userVersion
        guard version < schemaVersion else { return }
        try db.transaction {
            if version < 1 {
                try db.execute("""
                    CREATE TABLE feeds(
                      id TEXT PRIMARY KEY, title TEXT NOT NULL, site_url TEXT, feed_url TEXT, icon_url TEXT);
                    CREATE TABLE categories(id TEXT PRIMARY KEY, label TEXT NOT NULL);
                    CREATE TABLE feed_categories(
                      feed_id TEXT NOT NULL REFERENCES feeds(id) ON DELETE CASCADE,
                      category_id TEXT NOT NULL REFERENCES categories(id) ON DELETE CASCADE,
                      PRIMARY KEY(feed_id, category_id));
                    CREATE TABLE articles(
                      id TEXT PRIMARY KEY, feed_id TEXT NOT NULL, title TEXT NOT NULL, author TEXT, url TEXT,
                      content_html TEXT NOT NULL, excerpt TEXT NOT NULL DEFAULT '', lead_image_url TEXT,
                      word_count INTEGER NOT NULL DEFAULT 0, language TEXT,
                      published_at REAL NOT NULL, updated_at REAL, crawled_at REAL,
                      is_read INTEGER NOT NULL DEFAULT 0, is_starred INTEGER NOT NULL DEFAULT 0,
                      is_downloaded INTEGER NOT NULL DEFAULT 0, enclosures TEXT, fetched_at REAL NOT NULL);
                    CREATE INDEX articles_by_date ON articles(published_at DESC, id DESC);
                    CREATE INDEX articles_by_feed ON articles(feed_id, published_at DESC);
                    CREATE INDEX articles_unread ON articles(is_read, published_at DESC);
                    CREATE INDEX articles_starred ON articles(is_starred) WHERE is_starred = 1;
                    CREATE TABLE pending_changes(
                      article_id TEXT NOT NULL, attribute TEXT NOT NULL, value INTEGER NOT NULL,
                      created_at REAL NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, last_error TEXT,
                      PRIMARY KEY(article_id, attribute));
                    CREATE TABLE reading_positions(
                      article_id TEXT PRIMARY KEY, block_id TEXT, block_offset INTEGER NOT NULL DEFAULT 0,
                      progress REAL NOT NULL, updated_at REAL NOT NULL);
                    CREATE TABLE highlights(
                      id TEXT PRIMARY KEY, article_id TEXT NOT NULL, kind TEXT NOT NULL, block_id TEXT NOT NULL,
                      start_offset INTEGER NOT NULL, end_offset INTEGER NOT NULL, color TEXT NOT NULL, note TEXT,
                      created_at REAL NOT NULL);
                    CREATE INDEX highlights_by_article ON highlights(article_id);
                    CREATE TABLE key_values(key TEXT PRIMARY KEY, value TEXT NOT NULL);
                    """)
            }
            if version < 2 {
                // Full text from the publisher's page, kept apart from the
                // feed's content so a later sync never overwrites it.
                try db.execute("""
                    ALTER TABLE articles ADD COLUMN full_html TEXT;
                    ALTER TABLE articles ADD COLUMN full_status INTEGER NOT NULL DEFAULT 0;
                    ALTER TABLE articles ADD COLUMN full_checked_at REAL;
                    """)
            }
            try db.setUserVersion(schemaVersion)
        }
    }

    // MARK: Subscriptions

    /// Replaces feeds and categories with the server's list. Articles of
    /// feeds that disappeared are removed unless starred or downloaded.
    public func replaceSubscriptions(feeds: [Feed], categories: [FeedCategory]) throws {
        try db.transaction {
            let keep = Set(feeds.map(\.id.rawValue))
            let existing = try db.query("SELECT id FROM feeds") { $0.string(0) ?? "" }
            for gone in existing where !keep.contains(gone) {
                try db.run("DELETE FROM articles WHERE feed_id = ? AND is_starred = 0 AND is_downloaded = 0", [gone])
                try db.run("DELETE FROM feeds WHERE id = ?", [gone])
            }
            try db.runBatch(
                "INSERT INTO categories(id, label) VALUES(?, ?) ON CONFLICT(id) DO UPDATE SET label = excluded.label",
                categories) { [$0.id.rawValue, $0.label] }
            let keepCategories = Set(categories.map(\.id.rawValue))
            for gone in try db.query("SELECT id FROM categories", [], { $0.string(0) ?? "" }) where !keepCategories.contains(gone) {
                try db.run("DELETE FROM categories WHERE id = ?", [gone])
            }
            try db.runBatch("""
                INSERT INTO feeds(id, title, site_url, feed_url, icon_url) VALUES(?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET title = excluded.title, site_url = excluded.site_url,
                  feed_url = excluded.feed_url, icon_url = excluded.icon_url
                """, feeds) { [$0.id.rawValue, $0.title, $0.siteURL, $0.feedURL, $0.iconURL] }
            try db.execute("DELETE FROM feed_categories")
            let links = feeds.flatMap { feed in
                feed.categoryIDs.filter { keepCategories.contains($0.rawValue) }.map { (feed.id.rawValue, $0.rawValue) }
            }
            try db.runBatch("INSERT OR IGNORE INTO feed_categories(feed_id, category_id) VALUES(?, ?)", links) { [$0.0, $0.1] }
        }
    }

    public func feeds() throws -> [Feed] {
        let links = try db.query("SELECT feed_id, category_id FROM feed_categories") { ($0.string(0) ?? "", $0.string(1) ?? "") }
        let byFeed = Dictionary(grouping: links, by: \.0).mapValues { $0.map { CategoryID($0.1) } }
        return try db.query("SELECT id, title, site_url, feed_url, icon_url FROM feeds ORDER BY title COLLATE NOCASE") { row in
            let id = row.string(0) ?? ""
            return Feed(id: FeedID(id), title: row.string(1) ?? id, siteURL: row.url(2), feedURL: row.url(3),
                        iconURL: row.url(4), categoryIDs: byFeed[id] ?? [])
        }
    }

    public func categories() throws -> [FeedCategory] {
        try db.query("SELECT id, label FROM categories ORDER BY label COLLATE NOCASE") {
            FeedCategory(id: CategoryID($0.string(0) ?? ""), label: $0.string(1) ?? "")
        }
    }

    // MARK: Articles

    /// Inserts or updates articles from the server. Read and starred flags
    /// with a pending local change keep the local value.
    public func upsert(_ items: [StoredArticle]) throws {
        guard !items.isEmpty else { return }
        let now = clock.now
        try db.transaction {
            let pending = try pendingLookup()
            try db.runBatch("""
                INSERT INTO articles(id, feed_id, title, author, url, content_html, excerpt, lead_image_url, word_count,
                  language, published_at, updated_at, crawled_at, is_read, is_starred, enclosures, fetched_at)
                VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET feed_id = excluded.feed_id, title = excluded.title, author = excluded.author,
                  url = excluded.url, content_html = excluded.content_html, excerpt = excluded.excerpt,
                  lead_image_url = excluded.lead_image_url,
                  word_count = CASE WHEN articles.full_status = 1 THEN articles.word_count ELSE excluded.word_count END,
                  language = CASE WHEN articles.full_status = 1 AND articles.language IS NOT NULL
                    THEN articles.language ELSE excluded.language END,
                  published_at = excluded.published_at, updated_at = excluded.updated_at, crawled_at = excluded.crawled_at,
                  is_read = excluded.is_read, is_starred = excluded.is_starred, enclosures = excluded.enclosures,
                  fetched_at = excluded.fetched_at
                """, items) { item -> [any SQLiteBindable] in
                let a = item.article
                let read = pending[PendingKey(a.id.rawValue, .read)] ?? a.isRead
                let starred = pending[PendingKey(a.id.rawValue, .starred)] ?? a.isStarred
                let enclosures = a.enclosures.isEmpty ? nil : (try? JSONEncoder().encode(a.enclosures)).map { String(decoding: $0, as: UTF8.self) }
                return [a.id.rawValue, a.feedID.rawValue, a.title, a.author, a.url, a.contentHTML, item.excerpt,
                        item.leadImageURL, item.wordCount, item.language?.rawValue, a.publishedAt, a.updatedAt,
                        a.crawledAt, read, starred, enclosures, now]
            }
        }
    }

    /// Which of `ids` are already stored.
    public func existingIDs(among ids: [ArticleID]) throws -> Set<ArticleID> {
        var found = Set<ArticleID>()
        for chunk in stride(from: 0, to: ids.count, by: 500).map({ ids[$0..<min($0 + 500, ids.count)] }) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let rows = try db.query("SELECT id FROM articles WHERE id IN (\(placeholders))", chunk.map(\.rawValue)) { $0.string(0) ?? "" }
            found.formUnion(rows.map { ArticleID($0) })
        }
        return found
    }

    public func allArticleIDs() throws -> Set<ArticleID> {
        Set(try db.query("SELECT id FROM articles") { ArticleID($0.string(0) ?? "") })
    }

    public func summaries(_ query: ArticleQuery) throws -> [ArticleSummary] {
        var sql = """
            SELECT a.id, a.feed_id, COALESCE(f.title, ''), a.title, a.author, a.excerpt, a.lead_image_url, a.url,
              a.published_at, a.is_read, a.is_starred, a.is_downloaded, rp.progress, a.word_count, a.language
            FROM articles a LEFT JOIN feeds f ON f.id = a.feed_id
            LEFT JOIN reading_positions rp ON rp.article_id = a.id
            WHERE 1 = 1
            """
        var bindings: [any SQLiteBindable] = []
        switch query.scope {
        case .everything: break
        case .feed(let id):
            sql += " AND a.feed_id = ?"
            bindings.append(id.rawValue)
        case .category(let id):
            sql += " AND a.feed_id IN (SELECT feed_id FROM feed_categories WHERE category_id = ?)"
            bindings.append(id.rawValue)
        }
        switch query.filter {
        case .all: break
        case .unread: sql += " AND a.is_read = 0"
        case .starred: sql += " AND a.is_starred = 1"
        case .downloaded: sql += " AND a.is_downloaded = 1"
        case .inProgress: sql += " AND rp.progress > 0.02 AND rp.progress < 0.97"
        }
        if let before = query.before {
            sql += " AND (a.published_at < ? OR (a.published_at = ? AND a.id < ?))"
            bindings += [before.date, before.date, before.id.rawValue]
        }
        sql += query.filter == .inProgress ? " ORDER BY rp.updated_at DESC" : " ORDER BY a.published_at DESC, a.id DESC"
        sql += " LIMIT ?"
        bindings.append(query.limit)
        return try db.query(sql, bindings) { row in
            ArticleSummary(
                id: ArticleID(row.string(0) ?? ""), feedID: FeedID(row.string(1) ?? ""), feedTitle: row.string(2) ?? "",
                title: row.string(3) ?? "", author: row.string(4), excerpt: row.string(5) ?? "", leadImageURL: row.url(6),
                url: row.url(7), publishedAt: row.date(8) ?? .distantPast, isRead: row.bool(9), isStarred: row.bool(10),
                isDownloaded: row.bool(11), readingProgress: row.isNull(12) ? nil : row.double(12), wordCount: row.int(13),
                language: row.string(14).map { LanguageCode($0) })
        }
    }

    public func article(_ id: ArticleID) throws -> StoredArticle? {
        try db.query("""
            SELECT id, feed_id, title, author, url, content_html, published_at, updated_at, crawled_at, is_read,
              is_starred, enclosures, excerpt, lead_image_url, word_count, language, is_downloaded, full_html, full_status
            FROM articles WHERE id = ?
            """, [id.rawValue]) { row in
            let enclosures = row.string(11).flatMap { try? JSONDecoder().decode([Enclosure].self, from: Data($0.utf8)) } ?? []
            let article = Article(
                id: ArticleID(row.string(0) ?? ""), feedID: FeedID(row.string(1) ?? ""), title: row.string(2) ?? "",
                author: row.string(3), url: row.url(4), contentHTML: row.string(5) ?? "", publishedAt: row.date(6) ?? .distantPast,
                updatedAt: row.date(7), crawledAt: row.date(8), isRead: row.bool(9), isStarred: row.bool(10), enclosures: enclosures)
            return StoredArticle(article: article, excerpt: row.string(12) ?? "", leadImageURL: row.url(13),
                                 wordCount: row.int(14), language: row.string(15).map { LanguageCode($0) }, isDownloaded: row.bool(16),
                                 fullHTML: row.string(17), fullTextStatus: FullTextStatus(rawValue: row.int(18)) ?? .notTried)
        }.first
    }

    // MARK: Full text

    /// Stores the article fetched from the publisher's page and its word count.
    /// `language` is guessed on the full text, which beats a guess on the
    /// feed's summary; nil keeps the stored one.
    public func setFullText(_ html: String, wordCount: Int, language: LanguageCode? = nil, for id: ArticleID) throws {
        try db.run("UPDATE articles SET full_html = ?, full_status = 1, full_checked_at = ?, word_count = ?, "
                   + "language = COALESCE(?, language) WHERE id = ?",
                   [html, clock.now, wordCount, language?.rawValue, id.rawValue])
    }

    public func markFullTextUnavailable(_ id: ArticleID) throws {
        try db.run("UPDATE articles SET full_status = 2, full_checked_at = ? WHERE id = ? AND full_status <> 1", [clock.now, id.rawValue])
    }

    /// Lets the reader try again ("Try again" on a failed fetch).
    public func resetFullText(_ id: ArticleID) throws {
        try db.run("UPDATE articles SET full_status = 0, full_checked_at = NULL WHERE id = ? AND full_status = 2", [id.rawValue])
    }

    /// Recent unread articles that look like summaries and haven't been tried,
    /// newest first, for fetching after a sync.
    public func articlesNeedingFullText(publishedAfter date: Date, maxWords: Int, limit: Int) throws -> [(id: ArticleID, url: URL)] {
        try db.query("""
            SELECT id, url FROM articles
            WHERE is_read = 0 AND full_status = 0 AND url IS NOT NULL AND word_count < ? AND published_at >= ?
            ORDER BY published_at DESC LIMIT ?
            """, [maxWords, date, limit]) { row in
            row.url(1).map { (ArticleID(row.string(0) ?? ""), $0) }
        }.compactMap { $0 }
    }

    public func unreadCounts() throws -> UnreadCounts {
        var counts = UnreadCounts()
        for (feed, count) in try db.query("SELECT feed_id, COUNT(*) FROM articles WHERE is_read = 0 GROUP BY feed_id", [], {
            ($0.string(0) ?? "", $0.int(1))
        }) {
            counts.byFeed[FeedID(feed)] = count
            counts.total += count
        }
        for (category, count) in try db.query("""
            SELECT fc.category_id, COUNT(*) FROM articles a JOIN feed_categories fc ON fc.feed_id = a.feed_id
            WHERE a.is_read = 0 GROUP BY fc.category_id
            """, [], { ($0.string(0) ?? "", $0.int(1)) }) {
            counts.byCategory[CategoryID(category)] = count
        }
        counts.starred = try db.query("SELECT COUNT(*) FROM articles WHERE is_starred = 1") { $0.int(0) }.first ?? 0
        return counts
    }

    // MARK: Local state changes

    public func setRead(_ read: Bool, ids: [ArticleID]) throws {
        try setFlag(.read, column: "is_read", value: read, ids: ids)
    }

    public func setStarred(_ starred: Bool, ids: [ArticleID]) throws {
        try setFlag(.starred, column: "is_starred", value: starred, ids: ids)
    }

    private func setFlag(_ attribute: PendingChange.Attribute, column: String, value: Bool, ids: [ArticleID]) throws {
        guard !ids.isEmpty else { return }
        let now = clock.now
        try db.transaction {
            for id in ids {
                try db.run("UPDATE articles SET \(column) = ? WHERE id = ? AND \(column) != ?", [value, id.rawValue, value])
                guard db.changes > 0 else { continue }
                try db.run("""
                    INSERT INTO pending_changes(article_id, attribute, value, created_at) VALUES(?, ?, ?, ?)
                    ON CONFLICT(article_id, attribute) DO UPDATE SET value = excluded.value,
                      created_at = excluded.created_at, attempts = 0, last_error = NULL
                    """, [id.rawValue, attribute.rawValue, value, now])
            }
        }
    }

    /// Marks every unread article in `scope` published before `olderThan` as read.
    @discardableResult
    public func markAllRead(scope: ArticleScope, olderThan: Date) throws -> [ArticleID] {
        var query = ArticleQuery(scope: scope, filter: .unread, limit: 100_000)
        query.before = (olderThan, ArticleID(String(repeating: "9", count: 24)))
        let ids = try summaries(query).map(\.id)
        try setRead(true, ids: ids)
        return ids
    }

    public func pendingChanges(limit: Int = 10_000) throws -> [PendingChange] {
        try db.query("SELECT article_id, attribute, value FROM pending_changes ORDER BY created_at LIMIT ?", [limit]) { row in
            PendingChange(articleID: ArticleID(row.string(0) ?? ""),
                          attribute: PendingChange.Attribute(rawValue: row.string(1) ?? "") ?? .read, value: row.bool(2))
        }
    }

    /// Removes changes the server confirmed. A row whose value flipped again
    /// while the request was in flight stays queued.
    public func clearPending(_ changes: [PendingChange]) throws {
        try db.transaction {
            try db.runBatch("DELETE FROM pending_changes WHERE article_id = ? AND attribute = ? AND value = ?", changes) {
                [$0.articleID.rawValue, $0.attribute.rawValue, $0.value]
            }
        }
    }

    public func recordPendingFailure(_ changes: [PendingChange], error: String) throws {
        try db.transaction {
            try db.runBatch("""
                UPDATE pending_changes SET attempts = attempts + 1, last_error = ?
                WHERE article_id = ? AND attribute = ? AND value = ?
                """, changes) { [error, $0.articleID.rawValue, $0.attribute.rawValue, $0.value] }
        }
    }

    private struct PendingKey: Hashable {
        let id: String
        let attribute: PendingChange.Attribute
        init(_ id: String, _ attribute: PendingChange.Attribute) {
            self.id = id
            self.attribute = attribute
        }
    }

    private func pendingLookup() throws -> [PendingKey: Bool] {
        var result: [PendingKey: Bool] = [:]
        for change in try pendingChanges() { result[PendingKey(change.articleID.rawValue, change.attribute)] = change.value }
        return result
    }

    /// Reconciles read/starred flags with the server's full unread and
    /// starred id sets. Articles with a pending local change are left alone.
    /// When a set was truncated (`...IsComplete == false`), absence from it
    /// proves nothing, so only the positive direction is applied.
    public func applyServerState(unreadIDs: Set<ArticleID>, starredIDs: Set<ArticleID>,
                                 unreadIsComplete: Bool = true, starredIsComplete: Bool = true) throws {
        try db.transaction {
            let pending = try pendingLookup()
            let rows = try db.query("SELECT id, is_read, is_starred FROM articles") { ($0.string(0) ?? "", $0.bool(1), $0.bool(2)) }
            var readUpdates: [(String, Bool)] = []
            var starUpdates: [(String, Bool)] = []
            for (id, isRead, isStarred) in rows {
                let articleID = ArticleID(id)
                let serverUnread = unreadIDs.contains(articleID)
                let serverStarred = starredIDs.contains(articleID)
                if pending[PendingKey(id, .read)] == nil, isRead == serverUnread, serverUnread || unreadIsComplete {
                    readUpdates.append((id, !serverUnread))
                }
                if pending[PendingKey(id, .starred)] == nil, serverStarred != isStarred, serverStarred || starredIsComplete {
                    starUpdates.append((id, serverStarred))
                }
            }
            try db.runBatch("UPDATE articles SET is_read = ? WHERE id = ?", readUpdates) { [$0.1, $0.0] }
            try db.runBatch("UPDATE articles SET is_starred = ? WHERE id = ?", starUpdates) { [$0.1, $0.0] }
        }
    }

    /// How many stored articles use each base language, most common first.
    public func languageCounts() throws -> [(language: String, count: Int)] {
        let rows = try db.query("SELECT language, COUNT(*) FROM articles WHERE language IS NOT NULL GROUP BY language") {
            (String(($0.string(0) ?? "").split(separator: "-").first ?? ""), $0.int(1))
        }
        var totals: [String: Int] = [:]
        for (language, count) in rows where !language.isEmpty { totals[language, default: 0] += count }
        return totals.map { ($0.key, $0.value) }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.language < $1.language }
    }

    /// For each feed, how many stored articles use each base language.
    public func feedLanguageCounts() throws -> [FeedID: [String: Int]] {
        let rows = try db.query("SELECT feed_id, language, COUNT(*) FROM articles WHERE language IS NOT NULL GROUP BY feed_id, language") {
            ($0.string(0) ?? "", String(($0.string(1) ?? "").split(separator: "-").first ?? ""), $0.int(2))
        }
        var counts: [FeedID: [String: Int]] = [:]
        for (feed, language, count) in rows where !feed.isEmpty && !language.isEmpty {
            counts[FeedID(feed), default: [:]][language, default: 0] += count
        }
        return counts
    }

    /// Unread articles whose title matches a mute rule.
    public func unreadArticles(matching rules: MuteRules) throws -> [ArticleID] {
        guard !rules.isEmpty else { return [] }
        return try db.query("SELECT id, title FROM articles WHERE is_read = 0") { ($0.string(0) ?? "", $0.string(1) ?? "") }
            .filter { rules.matches($0.1) }
            .map { ArticleID($0.0) }
    }

    // MARK: Reading positions

    public func readingPosition(for id: ArticleID) throws -> ReadingPosition? {
        try db.query("SELECT block_id, block_offset, progress, updated_at FROM reading_positions WHERE article_id = ?", [id.rawValue]) {
            ReadingPosition(articleID: id, blockID: $0.string(0), offset: $0.int(1), progress: $0.double(2),
                            updatedAt: $0.date(3) ?? .distantPast)
        }.first
    }

    public func saveReadingPosition(_ position: ReadingPosition) throws {
        try db.run("""
            INSERT INTO reading_positions(article_id, block_id, block_offset, progress, updated_at) VALUES(?, ?, ?, ?, ?)
            ON CONFLICT(article_id) DO UPDATE SET block_id = excluded.block_id, block_offset = excluded.block_offset,
              progress = excluded.progress, updated_at = excluded.updated_at
            """, [position.articleID.rawValue, position.blockID, position.offset, position.progress, position.updatedAt])
    }

    // MARK: Highlights and bookmarks

    public func addHighlight(_ highlight: Highlight) throws {
        try db.run("""
            INSERT OR REPLACE INTO highlights(id, article_id, kind, block_id, start_offset, end_offset, color, note, created_at)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [highlight.id, highlight.articleID.rawValue, highlight.kind.rawValue, highlight.blockID, highlight.start,
                  highlight.end, highlight.color, highlight.note, highlight.createdAt])
    }

    public func highlights(for id: ArticleID) throws -> [Highlight] {
        try db.query("""
            SELECT id, kind, block_id, start_offset, end_offset, color, note, created_at FROM highlights
            WHERE article_id = ? ORDER BY created_at
            """, [id.rawValue]) { row in
            Highlight(id: row.string(0) ?? "", articleID: id, kind: Highlight.Kind(rawValue: row.string(1) ?? "") ?? .highlight,
                      blockID: row.string(2) ?? "", start: row.int(3), end: row.int(4), color: row.string(5) ?? "yellow",
                      note: row.string(6), createdAt: row.date(7) ?? .distantPast)
        }
    }

    public func removeHighlight(id: String) throws {
        try db.run("DELETE FROM highlights WHERE id = ?", [id])
    }

    // MARK: Downloads and housekeeping

    public func setDownloaded(_ downloaded: Bool, id: ArticleID) throws {
        try db.run("UPDATE articles SET is_downloaded = ? WHERE id = ?", [downloaded, id.rawValue])
    }

    /// Deletes read articles older than `cutoff` that are neither starred,
    /// downloaded, nor waiting on a pending change. Returns how many.
    @discardableResult
    public func pruneArticles(olderThan cutoff: Date) throws -> Int {
        try db.run("""
            DELETE FROM articles WHERE published_at < ? AND is_read = 1 AND is_starred = 0 AND is_downloaded = 0
              AND id NOT IN (SELECT article_id FROM pending_changes)
            """, [cutoff])
        let removed = db.changes
        try db.run("DELETE FROM reading_positions WHERE article_id NOT IN (SELECT id FROM articles)")
        return removed
    }

    public func stats() throws -> StorageStats {
        let row = try db.query("""
            SELECT COUNT(*), COALESCE(SUM(is_read = 0), 0), COALESCE(SUM(is_starred = 1), 0), COALESCE(SUM(is_downloaded = 1), 0)
            FROM articles
            """) { ($0.int(0), $0.int(1), $0.int(2), $0.int(3)) }.first ?? (0, 0, 0, 0)
        let pending = try db.query("SELECT COUNT(*) FROM pending_changes") { $0.int(0) }.first ?? 0
        let pages = try db.query("PRAGMA page_count") { $0.int64(0) }.first ?? 0
        let pageSize = try db.query("PRAGMA page_size") { $0.int64(0) }.first ?? 0
        return StorageStats(articles: row.0, unread: row.1, starred: row.2, downloaded: row.3, pendingChanges: pending,
                            databaseBytes: pages * pageSize)
    }

    // MARK: Key-value

    public func value(forKey key: String) throws -> String? {
        try db.query("SELECT value FROM key_values WHERE key = ?", [key]) { $0.string(0) }.first ?? nil
    }

    public func setValue(_ value: String?, forKey key: String) throws {
        if let value {
            try db.run("INSERT INTO key_values(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                       [key, value])
        } else {
            try db.run("DELETE FROM key_values WHERE key = ?", [key])
        }
    }

    /// Removes everything (sign-out).
    public func reset() throws {
        try db.transaction {
            try db.execute("""
                DELETE FROM highlights; DELETE FROM reading_positions; DELETE FROM pending_changes;
                DELETE FROM articles; DELETE FROM feed_categories; DELETE FROM feeds; DELETE FROM categories;
                DELETE FROM key_values;
                """)
        }
    }
}
