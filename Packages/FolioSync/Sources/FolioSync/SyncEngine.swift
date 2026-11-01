import Foundation
import FolioCore
import FolioFreshRSS
import FolioReader
import FolioStorage

public struct SyncOptions: Sendable {
    /// How far back the first sync reaches for read articles.
    public var initialHistory: TimeInterval
    /// Upper bound on unread ids fetched per sync.
    public var maxUnread: Int
    public var maxStarred: Int
    /// Upper bound on recent (read or unread) ids per sync.
    public var maxRecent: Int
    /// Read, unstarred, not-downloaded articles older than this are pruned.
    public var retention: TimeInterval
    public var retry: RetryPolicy

    public init(initialHistory: TimeInterval = 14 * 86_400, maxUnread: Int = 3000, maxStarred: Int = 2000,
                maxRecent: Int = 1000, retention: TimeInterval = 45 * 86_400, retry: RetryPolicy = RetryPolicy()) {
        self.initialHistory = initialHistory
        self.maxUnread = maxUnread
        self.maxStarred = maxStarred
        self.maxRecent = maxRecent
        self.retention = retention
        self.retry = retry
    }
}

public enum SyncPhase: Sendable, Equatable {
    case pushingChanges
    case subscriptions
    case listingArticles
    case downloading(done: Int, total: Int)
    case reconciling
    case finished
}

public struct SyncReport: Sendable, Equatable {
    public var pushedChanges: Int
    public var newArticles: Int
    public var feeds: Int
    public var finishedAt: Date
}

/// Parses article HTML once at sync time so lists can show excerpts, lead
/// images and reading time without parsing on scroll.
public struct ArticleProcessor: Sendable {
    public var languageGuesser: any LanguageGuessing

    public init(languageGuesser: any LanguageGuessing = StopwordLanguageGuesser()) {
        self.languageGuesser = languageGuesser
    }

    public func process(_ article: Article) -> StoredArticle {
        let document = ArticleParser.parse(html: article.contentHTML, baseURL: article.url, title: article.title,
                                           languageGuesser: languageGuesser)
        let enclosureImage = article.enclosures.first { $0.mimeType?.hasPrefix("image/") == true }?.url
        return StoredArticle(article: article, excerpt: document.excerpt, leadImageURL: document.leadImageURL ?? enclosureImage,
                             wordCount: document.wordCount, language: document.language)
    }
}

/// Two-way sync between a Google Reader server and the local store.
///
/// The order follows NetNewsWire's proven Reader API flow: push queued
/// local changes, refresh subscriptions, fetch id lists (unread, starred,
/// recent), download only missing articles in batches, then reconcile
/// read/starred flags. Local changes that are still queued always win.
public actor SyncEngine {
    public static let lastSyncKey = "sync.lastSuccessAt"

    private let service: any ReaderService
    private let store: ArticleStore
    private let processor: ArticleProcessor
    private let options: SyncOptions
    private let clock: any FolioClock
    private let progress: (@Sendable (SyncPhase) -> Void)?
    private var running: Task<SyncReport, Error>?

    public init(service: any ReaderService, store: ArticleStore, processor: ArticleProcessor = ArticleProcessor(),
                options: SyncOptions = SyncOptions(), clock: any FolioClock = SystemClock(),
                progress: (@Sendable (SyncPhase) -> Void)? = nil) {
        self.service = service
        self.store = store
        self.processor = processor
        self.options = options
        self.clock = clock
        self.progress = progress
    }

    public var isSyncing: Bool { running != nil }

    /// Runs a full sync. Concurrent callers share the same run.
    public func sync() async throws -> SyncReport {
        if let running { return try await running.value }
        let task = Task { try await performSync() }
        running = task
        defer { running = nil }
        return try await task.value
    }

    /// Sends queued read/starred changes. Returns how many were confirmed.
    @discardableResult
    public func pushPendingChanges() async throws -> Int {
        let pending = try await store.pendingChanges()
        guard !pending.isEmpty else { return 0 }
        var confirmed = 0
        let groups = Dictionary(grouping: pending) { "\($0.attribute.rawValue)=\($0.value)" }
        for (_, changes) in groups.sorted(by: { $0.key < $1.key }) {
            guard let first = changes.first else { continue }
            let ids = changes.map(\.articleID)
            do {
                try await options.retry.run {
                    switch first.attribute {
                    case .read: try await self.service.setRead(first.value, ids: ids)
                    case .starred: try await self.service.setStarred(first.value, ids: ids)
                    }
                }
                try await store.clearPending(changes)
                confirmed += changes.count
            } catch let error as GoogleReaderError {
                try await store.recordPendingFailure(changes, error: error.description)
                throw error
            }
        }
        return confirmed
    }

    private func performSync() async throws -> SyncReport {
        let started = clock.now
        progress?(.pushingChanges)
        let pushed = try await pushPendingChanges()

        progress?(.subscriptions)
        let (feeds, categories) = try await withRetry { try await self.service.subscriptions() }
        try await store.replaceSubscriptions(feeds: feeds, categories: categories)

        progress?(.listingArticles)
        let lastSync = try await store.value(forKey: Self.lastSyncKey).flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
        // Overlap a day so clock skew between phone and server can't drop items.
        let since = lastSync.map { $0.addingTimeInterval(-86_400) } ?? started.addingTimeInterval(-options.initialHistory)
        let unread = try await withRetry {
            try await self.service.itemIDs(stream: StreamID.readingList, excludeRead: true, newerThan: nil, limit: self.options.maxUnread)
        }
        let starred = try await withRetry {
            try await self.service.itemIDs(stream: StreamID.starred, excludeRead: false, newerThan: nil, limit: self.options.maxStarred)
        }
        let recent = try await withRetry {
            try await self.service.itemIDs(stream: StreamID.readingList, excludeRead: false, newerThan: since, limit: self.options.maxRecent)
        }

        var wanted: [ArticleID] = []
        var seen = Set<ArticleID>()
        for id in unread + starred + recent where seen.insert(id).inserted { wanted.append(id) }
        let existing = try await store.existingIDs(among: wanted)
        let missing = wanted.filter { !existing.contains($0) }

        var downloaded = 0
        progress?(.downloading(done: 0, total: missing.count))
        for start in stride(from: 0, to: missing.count, by: GoogleReaderClient.contentsBatchSize) {
            let batch = Array(missing[start..<min(start + GoogleReaderClient.contentsBatchSize, missing.count)])
            let articles = try await withRetry { try await self.service.articles(ids: batch) }
            try await store.upsert(articles.map(processor.process))
            downloaded += articles.count
            progress?(.downloading(done: min(start + batch.count, missing.count), total: missing.count))
        }

        progress?(.reconciling)
        try await store.applyServerState(
            unreadIDs: Set(unread), starredIDs: Set(starred),
            unreadIsComplete: unread.count < options.maxUnread, starredIsComplete: starred.count < options.maxStarred)
        try await store.pruneArticles(olderThan: started.addingTimeInterval(-options.retention))
        try await store.setValue(String(started.timeIntervalSince1970), forKey: Self.lastSyncKey)

        progress?(.finished)
        return SyncReport(pushedChanges: pushed, newArticles: downloaded, feeds: feeds.count, finishedAt: clock.now)
    }

    private func withRetry<T: Sendable>(_ operation: @Sendable @escaping () async throws -> T) async throws -> T {
        try await options.retry.run(operation)
    }
}
