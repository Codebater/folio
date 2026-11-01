import Foundation
import Testing
import FolioCore
import FolioFreshRSS
import FolioReader
import FolioAudio
import FolioStorage
import FolioSync

/// The whole offline path: sync from a server, go offline, open an article
/// from SQLite, render it, build the narration script and "listen" with
/// synchronized highlighting.
@Suite("End to end")
@MainActor
struct EndToEndTests {
    @Test func syncReadAndListenOffline() async throws {
        let server = InMemoryReaderServer()
        let client = GoogleReaderClient(endpoint: InMemoryReaderServer.demoEndpoint,
                                        credentials: Credentials(username: "demo", apiPassword: InMemoryReaderServer.demoPassword),
                                        transport: server)
        let store = try ArticleStore.inMemory()
        _ = try await SyncEngine(service: client, store: store).sync()

        // Disconnect. Everything below must work without the server.
        await server.setOutage(TransportError(kind: .offline, message: "offline"))

        let unread = try await store.summaries(ArticleQuery(filter: .unread))
        #expect(unread.count == 8)
        let summary = try #require(unread.first { $0.title == "Why the best pages feel quiet" })
        let stored = try #require(try await store.article(summary.id))

        let document = ArticleParser.parse(html: stored.article.contentHTML, baseURL: stored.article.url, title: stored.article.title)
        #expect(!document.blocks.contains { $0.text.contains("track(") })  // the article's <script> is gone
        let html = ReaderHTMLRenderer(settings: ReaderSettings(), imageScheme: "folio-image") { "folio-image://i?u=\($0)" }
            .render(document, metadata: ReaderPageMetadata(title: stored.article.title, siteName: summary.feedTitle,
                                                           originalURL: stored.article.url))
        #expect(html.contains("Read the original on margin.example"))
        #expect(!html.contains("<script"))

        let script = SpeechScript.build(document: document, title: stored.article.title, articleID: stored.article.id)
        let engine = SimulatedSpeechEngine()
        let controller = ReadAlongController(engine: engine) { _ in script }
        var highlighted: [String] = []
        controller.onChange = { state in
            guard let blockID = state.blockID, let range = state.wordRange else { return }
            let text = blockID == SpeechScript.titleBlockID ? stored.article.title : document.block(id: blockID)?.text ?? ""
            highlighted.append(String(text.utf16Slice(range)))
        }
        await controller.play(ListenItem(id: summary.id, title: summary.title, feedTitle: summary.feedTitle))
        var steps = 0
        while engine.step() { steps += 1 }
        #expect(controller.state.status == .finished)
        #expect(highlighted.prefix(6) == ["Why", "the", "best", "pages", "feel", "quiet"])
        // Every highlighted word really is in the article text.
        let allText = ([stored.article.title] + document.blocks.map(\.text)).joined(separator: " ")
        #expect(highlighted.allSatisfy { allText.contains($0) })
        #expect(steps > 150)

        // Reading position and offline state changes persist and queue.
        try await store.saveReadingPosition(ReadingPosition(articleID: summary.id, blockID: "b3", offset: 10, progress: 0.4, updatedAt: Date()))
        try await store.setRead(true, ids: [summary.id])
        #expect(try await store.pendingChanges().count == 1)
        let position = try #require(try await store.readingPosition(for: summary.id))
        #expect(ProgressMap(document: document).resolve(position)! == ("b3", 10))
    }

    @Test func everyDemoArticleProducesAConsistentScript() async throws {
        let server = InMemoryReaderServer()
        let client = GoogleReaderClient(endpoint: InMemoryReaderServer.demoEndpoint,
                                        credentials: Credentials(username: "demo", apiPassword: InMemoryReaderServer.demoPassword),
                                        transport: server)
        let store = try ArticleStore.inMemory()
        _ = try await SyncEngine(service: client, store: store).sync()
        var languages = Set<String>()
        for summary in try await store.summaries(ArticleQuery(limit: 100)) {
            if let base = try await store.article(summary.id)?.language?.base { languages.insert(base) }
        }
        #expect(languages == ["en", "de", "es", "sk"])

        for summary in try await store.summaries(ArticleQuery(limit: 100)) {
            let stored = try #require(try await store.article(summary.id))
            let document = ArticleParser.parse(html: stored.article.contentHTML, baseURL: stored.article.url, title: stored.article.title)
            let script = SpeechScript.build(document: document, title: stored.article.title,
                                            options: SpeechScriptOptions(granularity: .sentence))
            #expect(!script.isEmpty, "\(summary.title) has nothing to say")
            for segment in script.segments {
                // Mapping the whole spoken text must land inside the segment's display range.
                let mapped = script.displayRange(segment: segment.index, spokenRange: 0..<segment.spokenText.utf16Length)
                #expect(mapped.blockID == segment.blockID)
                #expect(mapped.range.lowerBound >= segment.displayRange.lowerBound)
                #expect(mapped.range.upperBound <= segment.displayRange.upperBound)
            }
        }
    }

    /// Real HTTP through URLSession against MockServer/mock_freshrss.py.
    /// Runs when FOLIO_MOCK_URL is set, e.g. http://127.0.0.1:8787.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FOLIO_MOCK_URL"] != nil))
    func syncsOverRealHTTP() async throws {
        let base = ProcessInfo.processInfo.environment["FOLIO_MOCK_URL"]!
        let client = GoogleReaderClient(endpoint: try ServerEndpoint(userInput: base),
                                        credentials: Credentials(username: "demo", apiPassword: "folio-demo"))
        try await client.verifyCredentials()
        let store = try ArticleStore.inMemory()
        let report = try await SyncEngine(service: client, store: store).sync()
        #expect(report.feeds == 5)
        #expect(try await store.stats().articles == 10)

        // A local change round-trips to the server and back.
        try await store.setStarred(true, ids: ["1730390400000002"])
        _ = try await SyncEngine(service: client, store: store).sync()
        let starred = try await client.itemIDs(stream: StreamID.starred, excludeRead: false, newerThan: nil, limit: 100)
        #expect(starred.contains("1730390400000002"))
        try await client.setStarred(false, ids: ["1730390400000002"])  // leave the mock as we found it

        let bad = GoogleReaderClient(endpoint: try ServerEndpoint(userInput: base),
                                     credentials: Credentials(username: "demo", apiPassword: "nope"))
        await #expect(throws: GoogleReaderError.invalidCredentials) { try await bad.verifyCredentials() }
    }
}
