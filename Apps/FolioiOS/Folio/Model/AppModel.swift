import Foundation
import Observation
import FolioCore
import FolioFreshRSS
import FolioReader
import FolioAudio
import FolioStorage
import FolioSync
import FolioFeeds

/// An article opened for reading: the stored record plus its parsed document.
struct LoadedArticle: Sendable {
    var stored: StoredArticle
    var document: ArticleDocument
    var feedTitle: String
}

enum SyncStatus: Equatable {
    case idle
    case syncing(String)
    case failed(String)
}

/// The app's composition root. Owns the database, the server connection,
/// sync, the image cache, entitlements and narration, and exposes what the
/// views need. Everything reads from the local store, so the app works
/// offline; sync only fills the store.
@MainActor
@Observable
final class AppModel {
    /// The one model; Siri and Shortcuts reach the app through it.
    static let shared = AppModel()

    private(set) var account: StoredAccount?
    private(set) var syncStatus: SyncStatus = .idle
    private(set) var lastSyncedAt: Date?
    private(set) var feeds: [Feed] = []
    private(set) var categories: [FeedCategory] = []
    private(set) var unread = UnreadCounts()
    /// Bumped whenever stored articles change, so lists know to reload.
    private(set) var revision = 0
    private(set) var storageProblem: String?
    var readerSettings: ReaderSettings {
        didSet { Preferences.save(readerSettings, key: .readerSettings) }
    }
    var reading: ReadingPreferences {
        didSet {
            Preferences.save(reading, key: .readingList)
            if reading.mute != oldValue.mute || reading.muteMarksRead != oldValue.muteMarksRead {
                Task { await applyMuteRules() }
                revision += 1
            }
            if reading.retentionDays != oldValue.retentionDays { configureSync() }
        }
    }
    /// Languages of the library, most common first (for the Voice Library).
    private(set) var libraryLanguages: [String] = []
    /// How many stored articles each language has.
    private(set) var libraryLanguageCounts: [String: Int] = [:]
    /// The language each feed usually writes in (feeds that mix have none).
    @ObservationIgnored private(set) var feedLanguages: [FeedID: LanguageCode] = [:]
    /// Languages the reader actually reads: narration only switches voice
    /// to one of these mid-article.
    @ObservationIgnored private(set) var readingLanguages: Set<String> = []

    let store: ArticleStore
    let imageCache: ImageCache
    let imageHandler: FolioImageSchemeHandler
    let entitlements = EntitlementStore()
    let listen = ListenModel()

    @ObservationIgnored private let credentials: any CredentialStore = KeychainCredentialStore()
    @ObservationIgnored private var syncEngine: SyncEngine?
    /// Adds and removes feeds: the reading list on this iPhone, or FreshRSS.
    @ObservationIgnored private var feedService: (any FeedSubscribing)?
    @ObservationIgnored private var localFeeds: LocalFeedService?
    static let localFeedsFile = ListenModel.folder("LocalFeeds", in: .applicationSupportDirectory).appendingPathComponent("feeds.json")
    @ObservationIgnored private var pushTask: Task<Void, Never>?
    @ObservationIgnored private var documents: [ArticleID: ArticleDocument] = [:]
    /// The same story from several feeds: each member maps to its group, the
    /// most complete article first.
    private(set) var storyGroups: [ArticleID: [ArticleID]] = [:]
    /// Group members after the first; Today, smart lists and stations skip them.
    private(set) var duplicates: Set<ArticleID> = []
    /// Full-text fetches in flight, shared by the reader, narration and prefetch.
    @ObservationIgnored private var fullTextTasks: [ArticleID: Task<Bool, Never>] = [:]
    @ObservationIgnored private let fullTextFetcher = FullTextFetcher()
    /// Articles this short probably came as a summary.
    static let summaryWordLimit = 250
    @ObservationIgnored private var started = false
    @ObservationIgnored private var listMarkers: [String: String] = Preferences.load(.listMarkers) ?? [:]
    let languageGuesser = NaturalLanguageGuesser()

    /// UI tests launch with `--ui-reset` (start from nothing) and `--demo`
    /// (open the built-in demo library without the onboarding screen).
    static let isUIReset = ProcessInfo.processInfo.arguments.contains("--ui-reset")
    static let isDemoLaunch = ProcessInfo.processInfo.arguments.contains("--demo")

    init() {
        if Self.isUIReset { Preferences.removeAll() }
        let files = FileManager.default
        let support = (try? files.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? files.temporaryDirectory
        let folder = support.appendingPathComponent("Folio", isDirectory: true)
        try? files.createDirectory(at: folder, withIntermediateDirectories: true)

        var problem: String?
        let opened: ArticleStore
        do {
            opened = try ArticleStore(path: folder.appendingPathComponent("folio.sqlite").path)
        } catch {
            problem = "Couldn't open the article database (\(error)). Articles are kept in memory until the app restarts."
            // An in-memory SQLite database cannot fail to open short of memory exhaustion.
            opened = try! ArticleStore.inMemory()
        }
        store = opened
        storageProblem = problem

        let caches = (try? files.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? files.temporaryDirectory
        imageCache = ImageCache(directory: caches.appendingPathComponent("Folio/Images", isDirectory: true))
        imageHandler = FolioImageSchemeHandler(cache: imageCache)
        var settings: ReaderSettings = Preferences.load(.readerSettings) ?? ReaderSettings()
        // UI tests take screenshots in a fixed theme: `--theme midnight`.
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--theme"), index + 1 < arguments.count,
           let theme = ReadingTheme.builtIn.first(where: { $0.id == arguments[index + 1] })
        {
            settings.theme = theme
            settings.automaticThemes = nil
        }
        readerSettings = settings
        reading = Preferences.load(.readingList) ?? ReadingPreferences()
        account = Preferences.load(.account)
        lastSyncedAt = Preferences.load(.lastSyncedAt)
        listen.attach(to: self)
    }

    func start() async {
        guard !started else { return }
        started = true
        entitlements.start()
        if Self.isUIReset { try? await store.reset() }
        configureSync()
        await refreshMetadata()
        Task { await recheckLanguages() }
        if account == nil && Self.isDemoLaunch {
            await useDemo()
        } else if account != nil {
            await sync()
        }
    }

    // MARK: Accounts

    var isDemo: Bool { account == .demo }

    /// Sources can be added here: on this iPhone, or on the FreshRSS server.
    var canAddFeeds: Bool { account != nil && account != .demo }

    var accountTitle: String {
        switch account {
        case .demo: "Demo library"
        case .server(let config): "\(config.username) · \(config.endpoint.apiBase.host ?? "")"
        case .local: "Reading list on this iPhone"
        case nil: "Not connected"
        }
    }

    private func configureSync() {
        let service: (any ReaderService)?
        switch account {
        case .demo:
            service = GoogleReaderClient(
                endpoint: InMemoryReaderServer.demoEndpoint,
                credentials: Credentials(username: InMemoryReaderServer.demoUsername, apiPassword: InMemoryReaderServer.demoPassword),
                transport: InMemoryReaderServer())
        case .server(let config):
            if let password = try? credentials.password(for: config.credentialKey) {
                service = GoogleReaderClient(endpoint: config.endpoint, credentials: Credentials(username: config.username, apiPassword: password))
            } else {
                service = nil
                syncStatus = .failed("Sign in again to keep syncing. Your downloaded articles are still here.")
            }
        case .local:
            service = LocalFeedService(stateURL: Self.localFeedsFile, transport: URLSessionTransport())
        case nil:
            service = nil
        }
        localFeeds = service as? LocalFeedService
        feedService = account == .demo ? nil : service as? any FeedSubscribing
        var options = SyncOptions()
        options.retention = reading.retentionDays > 0 ? TimeInterval(reading.retentionDays) * 86_400 : 100 * 365 * 86_400
        let processor = ArticleProcessor(languageGuesser: languageGuesser)
        syncEngine = service.map { service in
            SyncEngine(service: service, store: store, processor: processor, options: options, progress: { [weak self] phase in
                Task { @MainActor in self?.syncStatus = .syncing(phase.label) }
            })
        }
    }

    /// Verifies the server and credentials before saving anything.
    func connect(server: String, username: String, password: String) async throws(GoogleReaderError) {
        let endpoint = try ServerEndpoint(userInput: server)
        let client = GoogleReaderClient(endpoint: endpoint, credentials: Credentials(username: username, apiPassword: password))
        try await client.verifyCredentials()

        let config = AccountConfiguration(endpoint: endpoint, username: username)
        if account != .server(config) { await resetLibrary() }
        do {
            try credentials.setPassword(password, for: config.credentialKey)
        } catch {
            throw .malformedResponse("the Keychain refused to store the password")
        }
        account = .server(config)
        Preferences.save(StoredAccount.server(config), key: .account)
        configureSync()
        await sync()
    }

    func useDemo() async {
        if account != .demo { await resetLibrary() }
        account = .demo
        Preferences.save(StoredAccount.demo, key: .account)
        configureSync()
        await sync()
    }

    func signOut() async {
        if case .server(let config) = account { try? credentials.removePassword(for: config.credentialKey) }
        if account == .local { try? FileManager.default.removeItem(at: Self.localFeedsFile) }
        await resetLibrary()
        account = nil
        syncEngine = nil
        syncStatus = .idle
        Preferences.remove(.account)
    }

    /// Starts a reading list on this iPhone with the chosen sources: no
    /// server and no account. Paperwire fetches the feeds itself.
    func startReadingList(with feeds: [NewFeed]) async -> [String] {
        if account != .local {
            await resetLibrary()
            try? FileManager.default.removeItem(at: Self.localFeedsFile)
        }
        account = .local
        Preferences.save(StoredAccount.local, key: .account)
        configureSync()
        return await addFeeds(feeds)
    }

    /// A source to follow: its feed address, name and topic.
    struct NewFeed: Sendable, Hashable {
        var url: URL
        var title: String?
        var category: String?
    }

    /// Follows sources, then syncs so their stories arrive. Returns the
    /// names of any that couldn't be added.
    @discardableResult
    func addFeeds(_ feeds: [NewFeed]) async -> [String] {
        guard let feedService else { return feeds.map { $0.title ?? $0.url.host ?? $0.url.absoluteString } }
        var failed: [String] = []
        for feed in feeds {
            do {
                _ = try await feedService.subscribe(feedURL: feed.url, title: feed.title, category: feed.category)
            } catch {
                failed.append(feed.title ?? feed.url.host ?? feed.url.absoluteString)
            }
        }
        await sync()
        return failed
    }

    func removeFeed(_ id: FeedID) async {
        do {
            try await feedService?.unsubscribe(id)
        } catch {
            syncStatus = .failed("Couldn't remove the source: \(error)")
            return
        }
        await sync()
    }

    /// Sources on this iPhone whose last check failed, and why.
    func feedProblems() async -> [FeedID: String] {
        guard let localFeeds else { return [:] }
        var problems: [FeedID: String] = [:]
        for feed in await localFeeds.feeds { if let error = feed.lastError { problems[feed.id] = error } }
        return problems
    }

    /// Feed addresses already followed, compared without the scheme or a
    /// trailing slash.
    var followedFeedKeys: Set<String> { Set(feeds.compactMap { $0.feedURL.map(Self.feedKey) }) }

    static func feedKey(_ url: URL) -> String {
        var key = url.absoluteString.lowercased()
        for prefix in ["https://", "http://"] where key.hasPrefix(prefix) { key.removeFirst(prefix.count) }
        if key.hasPrefix("www.") { key.removeFirst(4) }
        while key.hasSuffix("/") { key.removeLast() }
        return key
    }

    private func resetLibrary() async {
        listen.stop()
        try? await store.reset()
        documents.removeAll()
        lastSyncedAt = nil
        Preferences.remove(.lastSyncedAt)
        await refreshMetadata()
    }

    // MARK: Sync

    func sync() async {
        guard let syncEngine else { return }
        syncStatus = .syncing("Syncing")
        do {
            let report = try await syncEngine.sync()
            lastSyncedAt = report.finishedAt
            Preferences.save(report.finishedAt, key: .lastSyncedAt)
            syncStatus = .idle
        } catch let error as GoogleReaderError {
            syncStatus = .failed(error.description)
        } catch {
            syncStatus = .failed("Sync failed: \(error)")
        }
        await applyMuteRules()
        await refreshMetadata()
        if reading.fetchFullText { Task { await prefetchFullText() } }
    }

    // MARK: Full text

    /// A summary Folio could replace with the publisher's article.
    func needsFullText(_ stored: StoredArticle) -> Bool {
        guard reading.fetchFullText, stored.fullTextStatus == .notTried, stored.wordCount < Self.summaryWordLimit,
              let url = stored.article.url
        else { return false }
        return FullTextFetcher.isSupported(FullTextFetcher.cleaned(url))
    }

    /// Fetches the full article for a summary, once; callers share the work.
    /// True when the article now has its full text.
    func fullTextTask(_ id: ArticleID, background: Bool = false) -> Task<Bool, Never> {
        if let running = fullTextTasks[id] { return running }
        let task = Task { [weak self] () -> Bool in
            guard let self else { return false }
            defer { self.fullTextTasks[id] = nil }
            return await self.fetchFullText(id, background: background)
        }
        fullTextTasks[id] = task
        return task
    }

    private func fetchFullText(_ id: ArticleID, background: Bool) async -> Bool {
        guard let stored = try? await store.article(id), needsFullText(stored), let link = stored.article.url else {
            return (try? await store.article(id))?.fullTextStatus == .fetched
        }
        let url = FullTextFetcher.cleaned(link)
        let result: FullTextExtractor.Result?
        do {
            result = try await fullTextFetcher.fetch(url, background: background)
        } catch {
            return false  // offline or a timeout: try again another time
        }
        let title = stored.article.title
        let guesser = languageGuesser
        let document = await Task.detached(priority: .utility) {
            result.map { ArticleParser.parse(html: $0.html, baseURL: url, title: title, languageGuesser: guesser) }
        }.value
        // Only worth it when clearly longer than what the feed sent.
        guard let result, let document, document.wordCount >= max(120, Int(Double(stored.wordCount) * 1.5) + 40) else {
            try? await store.markFullTextUnavailable(id)
            return false
        }
        try? await store.setFullText(result.html, wordCount: document.wordCount, language: document.language, for: id)
        documents[id] = document
        if !background { revision += 1 }
        return true
    }

    /// "Try again" after a page couldn't be read.
    func retryFullText(_ id: ArticleID) async -> Bool {
        try? await store.resetFullText(id)
        return await fullTextTask(id).value
    }

    /// Waits for the full article up to `seconds`, so narration reads the
    /// whole story without a long wait; a slow page finishes in the background.
    func fullTextIfReady(_ id: ArticleID, within seconds: Double) async {
        guard let stored = try? await store.article(id), needsFullText(stored) else { return }
        let task = fullTextTask(id)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = await task.value }
            group.addTask { try? await Task.sleep(for: .seconds(seconds)) }
            await group.next()
            group.cancelAll()
        }
    }

    /// After a sync: full text for the newest unread summaries, three at a
    /// time, on Wi-Fi only, so they read and play offline.
    func prefetchFullText() async {
        let since = Date().addingTimeInterval(-3 * 86_400)
        guard let wanted = try? await store.articlesNeedingFullText(publishedAfter: since, maxWords: Self.summaryWordLimit, limit: 30)
        else { return }
        let ids = wanted.filter { FullTextFetcher.isSupported(FullTextFetcher.cleaned($0.url)) }.map(\.id)
        guard !ids.isEmpty else { return }
        var fetched = 0
        for batch in stride(from: 0, to: ids.count, by: 3).map({ Array(ids[$0..<min($0 + 3, ids.count)]) }) {
            let tasks = batch.map { fullTextTask($0, background: true) }
            for task in tasks {
                if await task.value { fetched += 1 }
            }
        }
        if fetched > 0 { revision += 1 }
    }

    func refreshMetadata() async {
        feeds = (try? await store.feeds()) ?? []
        categories = (try? await store.categories()) ?? []
        unread = (try? await store.unreadCounts()) ?? UnreadCounts()
        let languages = (try? await store.languageCounts()) ?? []
        libraryLanguages = languages.map(\.language)
        libraryLanguageCounts = Dictionary(languages.map { ($0.language, $0.count) }, uniquingKeysWith: +)
        let total = languages.reduce(0) { $0 + $1.count }
        // A few misdetected articles must not make a language "read".
        readingLanguages = Set(languages.filter { $0.count >= 10 || Double($0.count) >= Double(total) * 0.03 }.map(\.language))
        feedLanguages = ((try? await store.feedLanguageCounts()) ?? [:]).compactMapValues { ArticleLanguage.dominant($0) }
        await refreshStoryGroups()
        revision += 1
    }

    /// Read aloud until the reader chooses in Settings › Languages: the
    /// languages they clearly read, most common first, or the phone's
    /// language before anything is synced.
    var automaticReadAloudLanguages: [String] {
        let read = libraryLanguages.filter(readingLanguages.contains)
        if !read.isEmpty { return read }
        return [libraryLanguages.first ?? LanguageCode(Locale.preferredLanguages.first ?? "en").base]
    }

    /// Guesses made before links stopped counting as words are made again,
    /// once. Hacker News items ("Article URL: https://… Points: 125") came
    /// out French, which made the whole feed French and its stories start
    /// in a French voice.
    private func recheckLanguages() async {
        let key = "folio.languageRules"
        guard UserDefaults.standard.integer(forKey: key) < 2 else { return }
        let store = store
        let guesser = languageGuesser
        let changes = await Task.detached(priority: .utility) { () -> [ArticleID: LanguageCode?] in
            var changes: [ArticleID: LanguageCode?] = [:]
            for row in (try? await store.feedTextLanguages()) ?? [] {
                let language = ArticleParser.parse(html: row.html, title: row.title, languageGuesser: guesser).language
                if language?.base != row.language.base { changes.updateValue(language, forKey: row.id) }
            }
            return changes
        }.value
        if !changes.isEmpty {
            try? await store.setLanguages(changes)
            documents.removeAll()
            await refreshMetadata()
        }
        UserDefaults.standard.set(2, forKey: key)
    }

    /// A spoken summary for Siri: the unread count and the three newest stories.
    func whatsNew() async -> String {
        let latest = await summaries(ArticleQuery(filter: .unread, limit: 40)).filter { !duplicates.contains($0.id) }.prefix(3)
        guard unread.total > 0, !latest.isEmpty else { return "You're all caught up." }
        let names = latest.map { "\($0.title), from \($0.feedTitle)" }.joined(separator: ". ")
        return "You have \(unread.total) unread \(unread.total == 1 ? "story" : "stories"). The latest: \(names)."
    }

    /// Groups the last four days of unread articles that tell the same story.
    func refreshStoryGroups() async {
        let since = Date().addingTimeInterval(-4 * 86_400)
        let recent = await summaries(ArticleQuery(filter: .unread, limit: 600)).filter { $0.publishedAt >= since }
        let items = recent.map {
            StoryClusters.Item(id: $0.id, feedID: $0.feedID, title: $0.title, excerpt: $0.excerpt, publishedAt: $0.publishedAt)
        }
        let words = Dictionary(recent.map { ($0.id, $0.wordCount) }, uniquingKeysWith: { first, _ in first })
        let groups = await Task.detached(priority: .utility) { StoryClusters.find(items) }.value
        var map: [ArticleID: [ArticleID]] = [:]
        var copies: Set<ArticleID> = []
        for group in groups {
            // The fullest version leads; ties go to the earliest.
            let ordered = group.enumerated().sorted {
                let (a, b) = (words[$0.element] ?? 0, words[$1.element] ?? 0)
                return a != b ? a > b : $0.offset < $1.offset
            }.map(\.element)
            for id in ordered { map[id] = ordered }
            copies.formUnion(ordered.dropFirst())
        }
        storyGroups = map
        duplicates = copies
    }

    /// Muted articles are hidden everywhere and, if chosen, marked read so
    /// the server and the counts agree.
    func applyMuteRules() async {
        guard reading.muteMarksRead, !reading.mute.isEmpty,
              let ids = try? await store.unreadArticles(matching: reading.mute), !ids.isEmpty
        else { return }
        await setRead(true, ids)
    }

    // MARK: Lists

    /// The article a list was scrolled to when the reader last left it.
    func listMarker(_ key: String) -> ArticleID? { listMarkers[key].map { ArticleID($0) } }

    func setListMarker(_ id: ArticleID?, for key: String) {
        listMarkers[key] = id?.rawValue
        Preferences.save(listMarkers, key: .listMarkers)
    }

    @discardableResult
    func pruneNow() async -> Int {
        guard reading.retentionDays > 0 else { return 0 }
        let removed = (try? await store.pruneArticles(olderThan: Date().addingTimeInterval(-TimeInterval(reading.retentionDays) * 86_400))) ?? 0
        await refreshMetadata()
        return removed
    }

    /// Sends queued read/starred changes shortly after the user makes them.
    /// Offline, they stay queued and go out with the next sync.
    private func schedulePush() {
        pushTask?.cancel()
        let engine = syncEngine
        pushTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            _ = try? await engine?.pushPendingChanges()
        }
    }

    // MARK: Articles

    func summaries(_ query: ArticleQuery) async -> [ArticleSummary] {
        let rows = (try? await store.summaries(query)) ?? []
        let mute = reading.mute
        return mute.isEmpty ? rows : rows.filter { !mute.matches($0.title) }
    }

    func feedTitle(_ id: FeedID) -> String { feeds.first { $0.id == id }?.title ?? "" }

    func load(_ id: ArticleID) async -> LoadedArticle? {
        guard let stored = try? await store.article(id) else { return nil }
        let document: ArticleDocument
        if let cached = documents[id] {
            document = cached
        } else {
            let article = stored.article
            let html = stored.fullHTML ?? article.contentHTML
            let guesser = languageGuesser
            document = await Task.detached(priority: .userInitiated) {
                ArticleParser.parse(html: html, baseURL: article.url, title: article.title, languageGuesser: guesser)
            }.value
            if documents.count > 20 { documents.removeAll() }
            documents[id] = document
        }
        return LoadedArticle(stored: stored, document: document, feedTitle: feedTitle(stored.article.feedID))
    }

    func setRead(_ read: Bool, _ ids: [ArticleID]) async {
        var ids = ids
        if read, reading.markDuplicatesRead {
            ids = Array(Set(ids + ids.flatMap { storyGroups[$0] ?? [] }))
        }
        try? await store.setRead(read, ids: ids)
        unread = (try? await store.unreadCounts()) ?? unread
        revision += 1
        schedulePush()
    }

    func setStarred(_ starred: Bool, _ ids: [ArticleID]) async {
        try? await store.setStarred(starred, ids: ids)
        unread = (try? await store.unreadCounts()) ?? unread
        revision += 1
        schedulePush()
    }

    func markAllRead(_ scope: ArticleScope) async {
        _ = try? await store.markAllRead(scope: scope, olderThan: Date())
        unread = (try? await store.unreadCounts()) ?? unread
        revision += 1
        schedulePush()
    }

    /// Makes an article fully available offline, images included.
    func download(_ id: ArticleID) async {
        _ = await fullTextTask(id).value  // offline copies are the whole article when Folio can get it
        guard let loaded = await load(id) else { return }
        let images = loaded.document.blocks.compactMap { block -> URL? in
            if case .image(let info) = block.kind, info.source.scheme != "data" { return info.source }
            return nil
        }
        _ = await imageCache.prefetch(images + [loaded.stored.leadImageURL].compactMap { $0 })
        try? await store.setDownloaded(true, id: id)
        revision += 1
    }

    func readingPosition(_ id: ArticleID) async -> ReadingPosition? {
        try? await store.readingPosition(for: id)
    }

    func saveReadingPosition(_ position: ReadingPosition) async {
        try? await store.saveReadingPosition(position)
    }

    /// The narration script for an article, honouring the listening settings.
    /// Bulletin stories get their spoken introduction (which already names the
    /// title) and, for the first and last story, the opening and closing.
    func speechScript(for id: ArticleID) async -> SpeechScript? {
        if let bulletin = listen.bulletin, bulletin.isHeadlines, bulletin.contains(id) {
            return await headlineScript(for: id, bulletin: bulletin)
        }
        await fullTextIfReady(id, within: 6)
        guard let loaded = await load(id) else { return nil }
        let feedID = loaded.stored.article.feedID
        var options = listen.scriptOptions(detected: loaded.stored.language)
        options.feedLanguage = feedLanguages[feedID]
        options.switchLanguages = narrationLanguages
        options.sourceName = feeds.first { $0.id == feedID }?.title
        options.authorName = loaded.stored.article.author
        if entitlements.isPremium, let voiceID = listen.preferences.feedVoices[loaded.stored.article.feedID.rawValue],
           let voice = listen.voices.first(where: { $0.id == voiceID })
        {
            options.preferredVoice = PreferredVoice(id: voice.id, languageBase: voice.languageCode.base)
        }
        let bulletin = listen.bulletin
        if let story = bulletin?.stories.first(where: { $0.item.id == id }) {
            options.includeTitle = false
            // Stations play one language per section: a story is read in its
            // section's language unless its own text clearly says otherwise,
            // and its voice never changes halfway through.
            options.feedLanguage = story.language ?? options.feedLanguage
            options.switchLanguagePerParagraph = false
        }
        let (before, after) = bulletin?.announcements(for: id) ?? ([], [])
        let guesser = narrationGuesser(feedID: feedID)
        var script = SpeechScript.build(document: loaded.document, title: loaded.stored.article.title, articleID: id,
                                        options: options, languageGuesser: guesser,
                                        announcementsBefore: before, announcementsAfter: after)
        if options.granularity == .paragraph, listen.voiceLacksWordTimings(for: script.language) {
            options.granularity = .sentence
            script = SpeechScript.build(document: loaded.document, title: loaded.stored.article.title, articleID: id,
                                        options: options, languageGuesser: guesser,
                                        announcementsBefore: before, announcementsAfter: after)
        }
        return script
    }

    /// Languages narration may use: the ones the reader has turned on, and
    /// a language they force in Settings › Languages.
    private var narrationLanguages: Set<String> {
        var languages = Set(listen.readAloudLanguages)
        if let forced = listen.preferences.languageOverride { languages.insert(LanguageCode(forced).base) }
        return languages
    }

    /// Language identification for narration: only the languages that are
    /// on can come out, tipped towards the feed's usual one.
    private func narrationGuesser(feedID: FeedID) -> NaturalLanguageGuesser {
        NaturalLanguageGuesser(constraints: narrationLanguages,
                               hint: ArticleLanguage.permitted(feedLanguages[feedID], allowed: listen.readAloudLanguages))
    }

    /// The language an article is read in, from its own text where possible.
    /// `prior` (a station section's language) stands in for the feed's.
    func articleLanguage(_ loaded: LoadedArticle, prior: LanguageCode? = nil) -> LanguageCode? {
        let feedID = loaded.stored.article.feedID
        let allowed = listen.readAloudLanguages
        let sample = loaded.document.blocks.filter(\.isSpeakable).map(\.text).joined(separator: " ").prefix(3000)
        let resolved = ArticleLanguage.resolve(
            text: String(sample), guesser: narrationGuesser(feedID: feedID),
            feed: ArticleLanguage.permitted(prior ?? feedLanguages[feedID], allowed: allowed),
            fallback: ArticleLanguage.permitted(loaded.stored.language ?? loaded.document.language, allowed: allowed))
        return ArticleLanguage.narrated(resolved, allowed: allowed)
    }

    /// The language to plan a station with, before the article's text is
    /// loaded: a long article's own guess, otherwise its feed's usual one,
    /// otherwise the main language. Only languages that are on.
    func plannedLanguage(feedID: FeedID, guess: LanguageCode?, wordCount: Int) -> LanguageCode? {
        let allowed = listen.readAloudLanguages
        let guess = ArticleLanguage.permitted(guess, allowed: allowed)
        if wordCount >= ArticleLanguage.decisiveWords, let guess { return guess }
        return ArticleLanguage.narrated(ArticleLanguage.permitted(feedLanguages[feedID], allowed: allowed) ?? guess, allowed: allowed)
    }

    /// A story read as a headline: its introduction, then two sentences. For
    /// feeds that send a summary, that summary is an editor's headline and is
    /// used first; otherwise the article's key points.
    private func headlineScript(for id: ArticleID, bulletin: Bulletin) async -> SpeechScript? {
        guard let loaded = await load(id) else { return nil }
        let stored = loaded.stored
        let story = bulletin.stories.first { $0.item.id == id }
        let language = listen.preferences.languageOverride.map { LanguageCode($0) } ?? articleLanguage(loaded, prior: story?.language)
        var text = ""
        if stored.fullHTML != nil {
            let feedVersion = ArticleParser.parse(html: stored.article.contentHTML, baseURL: stored.article.url, title: stored.article.title)
            if (10...90).contains(feedVersion.wordCount) {
                text = KeyPoints.sentences(document: feedVersion, title: stored.article.title, language: language, count: 2)
                    .joined(separator: " ")
            }
        }
        if text.isEmpty { text = KeyPoints.headline(document: loaded.document, title: stored.article.title, language: language) }
        var options = listen.scriptOptions(detected: language)
        options.language = language  // two sentences: no switching
        options.includeTitle = false
        let (before, after) = bulletin.announcements(for: id)
        let summary = text.isEmpty ? [] : [SpeechAnnouncement(text, language: language)]
        return SpeechScript.build(document: ArticleParser.parse(html: ""), title: nil, articleID: id, options: options,
                                  languageGuesser: languageGuesser, announcementsBefore: before + summary, announcementsAfter: after)
    }

    /// Unread stories News Radio can choose from.
    func radioCandidates() async -> [RadioCandidate] { await radioPool().candidates }

    /// Radio candidates plus each story's lead image, for station artwork.
    func radioPool() async -> (candidates: [RadioCandidate], images: [ArticleID: URL]) {
        let categories = Dictionary(uniqueKeysWithValues: feeds.map { ($0.id, $0.categoryIDs) })
        let unread = await summaries(ArticleQuery(filter: .unread, limit: 400))
        let candidates = unread.map { summary in
            RadioCandidate(item: ListenItem(id: summary.id, title: summary.title, feedTitle: summary.feedTitle),
                           feedID: summary.feedID, categoryIDs: categories[summary.feedID] ?? [],
                           language: plannedLanguage(feedID: summary.feedID, guess: summary.language, wordCount: summary.wordCount),
                           wordCount: summary.wordCount, publishedAt: summary.publishedAt)
        }
        var images: [ArticleID: URL] = [:]
        for summary in unread { images[summary.id] = summary.leadImageURL }
        return (candidates, images)
    }

    /// Reader settings with Premium-only choices removed for free users.
    func effectiveReaderSettings(systemIsDark: Bool) -> ReaderSettings {
        var settings = entitlements.state.isPremium ? readerSettings : readerSettings.restrictedToFree()
        settings.theme = settings.effectiveTheme(systemIsDark: systemIsDark)
        return settings
    }
}

extension SyncPhase {
    var label: String {
        switch self {
        case .pushingChanges: "Sending changes"
        case .subscriptions: "Updating feeds"
        case .listingArticles: "Checking for articles"
        case .downloading(let done, let total): total == 0 ? "Up to date" : "Downloading \(done) of \(total)"
        case .reconciling: "Updating read status"
        case .finished: "Done"
        }
    }
}
