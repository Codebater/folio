import Foundation
import Testing
import FolioCore
import FolioFreshRSS
import FolioStorage
@testable import FolioSync

final class PhaseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var phases: [SyncPhase] = []
    func record(_ phase: SyncPhase) { lock.withLock { phases.append(phase) } }
    var all: [SyncPhase] { lock.withLock { phases } }
}

@Suite("Sync engine")
struct SyncEngineTests {
    let fast = SyncOptions(retry: RetryPolicy(maxAttempts: 2, baseDelay: .milliseconds(1)))

    func setUp() throws -> (InMemoryReaderServer, GoogleReaderClient, ArticleStore) {
        let server = InMemoryReaderServer()
        let client = GoogleReaderClient(endpoint: InMemoryReaderServer.demoEndpoint,
                                        credentials: Credentials(username: "demo", apiPassword: InMemoryReaderServer.demoPassword),
                                        transport: server)
        return (server, client, try ArticleStore.inMemory())
    }

    @Test func firstSyncDownloadsEverythingAndDerivesMetadata() async throws {
        let (_, client, store) = try setUp()
        let recorder = PhaseRecorder()
        let engine = SyncEngine(service: client, store: store, options: fast, progress: recorder.record)
        let report = try await engine.sync()
        #expect(report.feeds == 5)
        #expect(report.newArticles == 10)
        #expect(recorder.all.first == .pushingChanges && recorder.all.last == .finished)

        let stats = try await store.stats()
        #expect(stats.articles == 10 && stats.unread == 8 && stats.starred == 2)
        let german = try #require(try await store.article("1730390400000005"))
        #expect(german.language == .german)
        #expect(german.wordCount > 50)
        let quiet = try #require(try await store.article("1730390400000001"))
        #expect(quiet.leadImageURL?.scheme == "data")
        #expect(quiet.excerpt.hasPrefix("Open a well-made book"))
    }

    @Test func secondSyncOnlyFetchesNewArticles() async throws {
        let (server, client, store) = try setUp()
        let engine = SyncEngine(service: client, store: store, options: fast)
        _ = try await engine.sync()
        let before = await server.requestLog.count
        await server.publish(id: "1761999999000001", feed: "feed/2", title: "Fresh", html: "<p>Brand new.</p>", published: Date())
        let report = try await engine.sync()
        #expect(report.newArticles == 1)
        let contentsRequests = await server.requestLog.dropFirst(before).filter { $0.url.path.hasSuffix("stream/items/contents") }
        #expect(contentsRequests.count == 1)
        #expect(try await store.article("1761999999000001")?.article.title == "Fresh")
    }

    @Test func offlineChangesArePushedOnNextSync() async throws {
        let (server, client, store) = try setUp()
        let engine = SyncEngine(service: client, store: store, options: fast)
        _ = try await engine.sync()

        // Go offline, read and star locally.
        await server.setOutage(TransportError(kind: .offline, message: "offline"))
        try await store.setRead(true, ids: ["1730390400000003"])
        try await store.setStarred(true, ids: ["1730390400000003"])
        await #expect(throws: GoogleReaderError.self) { try await engine.sync() }
        #expect(try await store.pendingChanges().count == 2)
        #expect(try await store.article("1730390400000003")?.article.isRead == true)  // still readable offline

        // Back online: the queue drains and the server agrees.
        await server.setOutage(nil)
        let report = try await engine.sync()
        #expect(report.pushedChanges == 2)
        #expect(try await store.pendingChanges().isEmpty)
        #expect(await server.isRead("1730390400000003") == true)
        #expect(await server.isStarred("1730390400000003") == true)
    }

    @Test func serverSideChangesReachTheStore() async throws {
        let (server, client, store) = try setUp()
        let engine = SyncEngine(service: client, store: store, options: fast)
        _ = try await engine.sync()
        // Another device marks an article read on the server.
        try await client.setRead(true, ids: ["1730390400000006"])
        #expect(await server.isRead("1730390400000006") == true)
        _ = try await engine.sync()
        #expect(try await store.article("1730390400000006")?.article.isRead == true)
    }

    @Test func authenticationFailureStopsSyncAndKeepsQueue() async throws {
        let server = InMemoryReaderServer()
        let good = GoogleReaderClient(endpoint: InMemoryReaderServer.demoEndpoint,
                                      credentials: Credentials(username: "demo", apiPassword: InMemoryReaderServer.demoPassword),
                                      transport: server)
        let store = try ArticleStore.inMemory()
        _ = try await SyncEngine(service: good, store: store, options: fast).sync()
        try await store.setRead(true, ids: ["1730390400000007"])

        let revoked = GoogleReaderClient(endpoint: InMemoryReaderServer.demoEndpoint,
                                         credentials: Credentials(username: "demo", apiPassword: "changed"), transport: server)
        await #expect(throws: GoogleReaderError.invalidCredentials) {
            try await SyncEngine(service: revoked, store: store, options: fast).sync()
        }
        #expect(try await store.pendingChanges().count == 1)
    }

    @Test func concurrentCallersShareOneRun() async throws {
        let (server, client, store) = try setUp()
        let engine = SyncEngine(service: client, store: store, options: fast)
        async let a = engine.sync()
        async let b = engine.sync()
        let (ra, rb) = try await (a, b)
        #expect(ra == rb)
        let logins = await server.requestLog.filter { $0.url.path.hasSuffix("ClientLogin") }.count
        #expect(logins == 1)
    }

    @Test func processorFallsBackToEnclosureImage() {
        let article = Article(id: "1", feedID: "feed/1", title: "Podcast", contentHTML: "<p>Words only.</p>",
                              publishedAt: Date(), enclosures: [Enclosure(url: URL(string: "https://x/cover.jpg")!, mimeType: "image/jpeg")])
        #expect(ArticleProcessor().process(article).leadImageURL?.absoluteString == "https://x/cover.jpg")
    }
}
