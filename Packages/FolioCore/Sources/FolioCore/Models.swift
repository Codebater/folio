import Foundation

public struct Feed: Hashable, Sendable, Codable, Identifiable {
    public var id: FeedID
    public var title: String
    public var siteURL: URL?
    public var feedURL: URL?
    public var iconURL: URL?
    public var categoryIDs: [CategoryID]

    public init(
        id: FeedID, title: String, siteURL: URL? = nil, feedURL: URL? = nil,
        iconURL: URL? = nil, categoryIDs: [CategoryID] = []
    ) {
        self.id = id
        self.title = title
        self.siteURL = siteURL
        self.feedURL = feedURL
        self.iconURL = iconURL
        self.categoryIDs = categoryIDs
    }
}

public struct FeedCategory: Hashable, Sendable, Codable, Identifiable {
    public var id: CategoryID
    public var label: String

    public init(id: CategoryID, label: String) {
        self.id = id
        self.label = label
    }
}

public struct Enclosure: Hashable, Sendable, Codable {
    public var url: URL
    public var mimeType: String?
    public var length: Int?

    public init(url: URL, mimeType: String? = nil, length: Int? = nil) {
        self.url = url
        self.mimeType = mimeType
        self.length = length
    }
}

/// A full article as synced from the server. `contentHTML` is the publisher's
/// HTML exactly as FreshRSS delivered it; FolioReader turns it into a safe
/// document before anything is rendered.
public struct Article: Hashable, Sendable, Codable, Identifiable {
    public var id: ArticleID
    public var feedID: FeedID
    public var title: String
    public var author: String?
    public var url: URL?
    public var contentHTML: String
    public var publishedAt: Date
    public var updatedAt: Date?
    public var crawledAt: Date?
    public var isRead: Bool
    public var isStarred: Bool
    public var enclosures: [Enclosure]

    public init(
        id: ArticleID, feedID: FeedID, title: String, author: String? = nil, url: URL? = nil,
        contentHTML: String, publishedAt: Date, updatedAt: Date? = nil, crawledAt: Date? = nil,
        isRead: Bool = false, isStarred: Bool = false, enclosures: [Enclosure] = []
    ) {
        self.id = id
        self.feedID = feedID
        self.title = title
        self.author = author
        self.url = url
        self.contentHTML = contentHTML
        self.publishedAt = publishedAt
        self.updatedAt = updatedAt
        self.crawledAt = crawledAt
        self.isRead = isRead
        self.isStarred = isStarred
        self.enclosures = enclosures
    }
}

/// The lightweight row model used by lists; it never carries the full HTML.
public struct ArticleSummary: Hashable, Sendable, Identifiable {
    public var id: ArticleID
    public var feedID: FeedID
    public var feedTitle: String
    public var title: String
    public var author: String?
    public var excerpt: String
    public var leadImageURL: URL?
    public var url: URL?
    public var publishedAt: Date
    public var isRead: Bool
    public var isStarred: Bool
    public var isDownloaded: Bool
    public var readingProgress: Double?
    public var wordCount: Int
    public var language: LanguageCode?

    public init(
        id: ArticleID, feedID: FeedID, feedTitle: String, title: String, author: String? = nil,
        excerpt: String = "", leadImageURL: URL? = nil, url: URL? = nil, publishedAt: Date,
        isRead: Bool = false, isStarred: Bool = false, isDownloaded: Bool = false,
        readingProgress: Double? = nil, wordCount: Int = 0, language: LanguageCode? = nil
    ) {
        self.id = id
        self.feedID = feedID
        self.feedTitle = feedTitle
        self.title = title
        self.author = author
        self.excerpt = excerpt
        self.leadImageURL = leadImageURL
        self.url = url
        self.publishedAt = publishedAt
        self.isRead = isRead
        self.isStarred = isStarred
        self.isDownloaded = isDownloaded
        self.readingProgress = readingProgress
        self.wordCount = wordCount
        self.language = language
    }

    /// Minutes at 230 words per minute, never less than one.
    public var estimatedReadingMinutes: Int { max(1, Int((Double(wordCount) / 230).rounded())) }
}

public enum ArticleFilter: String, Hashable, Sendable, Codable, CaseIterable {
    case all, unread, starred, downloaded, inProgress
}

public enum ArticleScope: Hashable, Sendable, Codable {
    case everything
    case feed(FeedID)
    case category(CategoryID)
}

public struct ArticleQuery: Hashable, Sendable {
    public var scope: ArticleScope
    public var filter: ArticleFilter
    public var limit: Int
    /// Keyset pagination: only articles published strictly before this
    /// (date, id) pair. `nil` starts at the newest article.
    public var before: (date: Date, id: ArticleID)?

    public init(scope: ArticleScope = .everything, filter: ArticleFilter = .all, limit: Int = 50,
                before: (date: Date, id: ArticleID)? = nil) {
        self.scope = scope
        self.filter = filter
        self.limit = limit
        self.before = before
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.scope == rhs.scope && lhs.filter == rhs.filter && lhs.limit == rhs.limit
            && lhs.before?.date == rhs.before?.date && lhs.before?.id == rhs.before?.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(scope)
        hasher.combine(filter)
        hasher.combine(limit)
        hasher.combine(before?.date)
        hasher.combine(before?.id)
    }
}

/// Unread totals the Library shows next to feeds and categories.
public struct UnreadCounts: Hashable, Sendable {
    public var total: Int
    public var byFeed: [FeedID: Int]
    public var byCategory: [CategoryID: Int]
    public var starred: Int

    public init(total: Int = 0, byFeed: [FeedID: Int] = [:], byCategory: [CategoryID: Int] = [:], starred: Int = 0) {
        self.total = total
        self.byFeed = byFeed
        self.byCategory = byCategory
        self.starred = starred
    }
}

/// Where a reader stopped inside an article. `blockID` + `offset` (UTF-16
/// units into the block's text) is exact; `progress` (0...1) is the fallback
/// when the article's content changed and the block no longer exists.
public struct ReadingPosition: Hashable, Sendable, Codable {
    public var articleID: ArticleID
    public var blockID: String?
    public var offset: Int
    public var progress: Double
    public var updatedAt: Date

    public init(articleID: ArticleID, blockID: String?, offset: Int = 0, progress: Double, updatedAt: Date) {
        self.articleID = articleID
        self.blockID = blockID
        self.offset = offset
        self.progress = min(max(progress, 0), 1)
        self.updatedAt = updatedAt
    }
}
