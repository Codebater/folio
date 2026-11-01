import Foundation
import Testing
import FolioCore
import FolioReader
@testable import FolioAudio

func candidate(_ id: String, feed: String = "feed/1", feedTitle: String = "Field Notes", category: String = "user/-/label/Science",
               language: LanguageCode? = .english, words: Int = 330, hoursAgo: Double = 1) -> RadioCandidate {
    RadioCandidate(item: ListenItem(id: ArticleID(id), title: "Story \(id)", feedTitle: feedTitle), feedID: FeedID(feed),
                   categoryIDs: [CategoryID(category)], language: language, wordCount: words,
                   publishedAt: Date(timeIntervalSince1970: 1_800_000_000 - hoursAgo * 3600))
}

@Suite("News Radio planner")
struct BulletinPlannerTests {
    let morning = Date(timeIntervalSince1970: TimeInterval(Int(1_800_000_000) / 86_400 * 86_400 + 8 * 3600))  // 08:00 UTC

    @Test func picksNewestFirstWithinLimits() throws {
        var filters = RadioFilters()
        filters.storyLimit = 2
        let bulletin = try #require(BulletinPlanner.build(
            candidates: [candidate("a", hoursAgo: 3), candidate("b", hoursAgo: 1), candidate("c", hoursAgo: 2)], filters: filters))
        #expect(bulletin.items.map(\.id.rawValue) == ["b", "c"])
        filters.order = .oldest
        #expect(BulletinPlanner.build(candidates: [candidate("a", hoursAgo: 3), candidate("b", hoursAgo: 1)], filters: filters)?
            .items.map(\.id.rawValue) == ["a", "b"])
    }

    @Test func skipsStoriesThatDontFitInsteadOfTruncating() throws {
        var filters = RadioFilters()
        filters.minutes = 6  // 360 s
        // 330 words = 120 s + 5 s intro; 1650 words = 605 s, too long; 165 words = 65 s.
        let bulletin = try #require(BulletinPlanner.build(candidates: [
            candidate("short1", words: 330, hoursAgo: 1), candidate("long", words: 1650, hoursAgo: 2),
            candidate("short2", words: 330, hoursAgo: 3), candidate("tiny", words: 165, hoursAgo: 4),
        ], filters: filters))
        #expect(bulletin.items.map(\.id.rawValue) == ["short1", "short2", "tiny"])
        #expect(bulletin.estimatedSeconds == 315)
        // Faster speech fits more.
        filters.minutes = 3
        #expect(BulletinPlanner.build(candidates: [candidate("x", words: 660)], filters: filters) == nil)
        #expect(BulletinPlanner.build(candidates: [candidate("x", words: 660)], filters: filters, rate: 2) != nil)
    }

    @Test func filtersBySourceCategoryAndLanguage() {
        let pool = [
            candidate("en", feed: "feed/1", category: "user/-/label/Science", language: .english),
            candidate("de", feed: "feed/2", feedTitle: "Nachtschicht", category: "user/-/label/World", language: .german),
            candidate("unknown", feed: "feed/2", category: "user/-/label/World", language: nil),
        ]
        var filters = RadioFilters()
        filters.languages = ["de"]
        #expect(BulletinPlanner.build(candidates: pool, filters: filters)?.items.map(\.id.rawValue) == ["de"])
        filters = RadioFilters()
        filters.categoryIDs = ["user/-/label/World"]
        #expect(Set(BulletinPlanner.build(candidates: pool, filters: filters)?.items.map(\.id.rawValue) ?? []) == ["de", "unknown"])
        filters.feedIDs = ["feed/1"]
        #expect(BulletinPlanner.build(candidates: pool, filters: filters) == nil)  // sets intersect
        #expect(BulletinPlanner.build(candidates: pool, filters: RadioFilters(), excluding: ["en", "de", "unknown"]) == nil)
    }

    @Test func introducesEachStoryInItsOwnLanguage() throws {
        let bulletin = try #require(BulletinPlanner.build(candidates: [
            candidate("en", feedTitle: "Field Notes", language: .english, hoursAgo: 1),
            candidate("de", feed: "feed/2", feedTitle: "Nachtschicht", language: .german, hoursAgo: 2),
            candidate("es", feed: "feed/3", feedTitle: "La Brújula", language: .spanish, hoursAgo: 3),
            candidate("sk", feed: "feed/4", feedTitle: "Horizont", language: .slovak, hoursAgo: 4),
        ], filters: RadioFilters(), now: morning))
        #expect(bulletin.stories.map(\.introduction) == [
            "First, from Field Notes: Story en.", "Als Nächstes, von Nachtschicht: Story de.",
            "A continuación, de La Brújula: Story es.", "Ďalej Horizont: Story sk.",
        ])
        #expect(bulletin.opening.text.hasPrefix("Good morning. This is your Paperwire bulletin: 4 stories from 4 sources"))
        // Opens in the first story's language, closes in the last one's.
        #expect(bulletin.closing.text == "To je na teraz všetko. Ďakujeme, že ste počúvali.")
    }

    @Test func localizesOpeningsWithPlurals() {
        typealias P = BulletinPlanner.Phrases
        #expect(P.opening(stories: 1, sources: 1, minutes: 1, now: morning, language: .slovak)
            == "Dobré ráno. Toto je váš prehľad Paperwire: 1 príbeh z 1 zdroja, asi 1 minúta.")
        #expect(P.opening(stories: 3, sources: 2, minutes: 12, now: morning, language: .slovak)
            == "Dobré ráno. Toto je váš prehľad Paperwire: 3 príbehy z 2 zdrojov, asi 12 minút.")
        #expect(P.opening(stories: 2, sources: 2, minutes: 9, now: morning.addingTimeInterval(11 * 3600), language: .german)
            == "Guten Abend. Ihr Paperwire-Überblick: 2 Geschichten aus 2 Quellen, etwa 9 Minuten.")
    }

    @Test func placesOpeningIntroductionsAndClosing() throws {
        let bulletin = try #require(BulletinPlanner.build(
            candidates: [candidate("a", hoursAgo: 1), candidate("b", hoursAgo: 2)], filters: RadioFilters()))
        let first = bulletin.announcements(for: "a")
        #expect(first.before.count == 2 && first.after.isEmpty)
        let last = bulletin.announcements(for: "b")
        #expect(last.before.map(\.text) == [bulletin.stories[1].introduction])
        #expect(last.after == [bulletin.closing])
        #expect(bulletin.announcements(for: "zzz").before.isEmpty)
    }
}

@Suite("News Radio playback")
@MainActor
struct RadioPlaybackTests {
    let document = ArticleParser.parse(html: "<p>Die Stadt schläft nie.</p>")

    func script(for bulletin: Bulletin, _ id: ArticleID) -> SpeechScript {
        let (before, after) = bulletin.announcements(for: id)
        return SpeechScript.build(document: document, title: "Titel", articleID: id,
                                  options: SpeechScriptOptions(includeTitle: false, language: .german),
                                  announcementsBefore: before, announcementsAfter: after)
    }

    @Test func announcementsAreSpokenInTheirLanguageButNeverHighlighted() throws {
        let bulletin = try #require(BulletinPlanner.build(
            candidates: [candidate("de", feedTitle: "Nachtschicht", language: .german)], filters: RadioFilters(),
            bulletinLanguage: .english))
        let s = script(for: bulletin, "de")
        #expect(s.segments.map(\.blockID) == ["announcement-0", "announcement-1", "b0", "announcement-2"])
        // A German-only station opens and closes in German, whatever the phone's language.
        #expect(s.segments.map { $0.language?.base } == ["de", "de", "de", "de"])
        #expect(s.segments.filter(\.isAnnouncement).count == 3)

        let engine = SimulatedSpeechEngine()
        let controller = ReadAlongController(engine: engine) { _ in s }
        controller.play(script: s, item: bulletin.stories[0].item)
        var highlightedBlocks = Set<String>()
        controller.onChange = { state in if let block = state.blockID, state.wordRange != nil { highlightedBlocks.insert(block) } }
        while engine.step() {}
        // The page only ever sees ranges for real blocks; announcement ids exist in no page.
        #expect(highlightedBlocks.contains("b0"))
        #expect(controller.currentPosition == nil || !controller.currentPosition!.blockID.hasPrefix("announcement-"))
    }

    @Test func restoredQueueLoadsLazilyAndResumesAtTheSavedWord() async {
        let engine = SimulatedSpeechEngine()
        var requested: [ArticleID] = []
        let controller = ReadAlongController(engine: engine) { item in
            requested.append(item.id)
            return SpeechScript.build(document: ArticleParser.parse(html: "<p>One two three four.</p>"), title: nil,
                                      options: SpeechScriptOptions(includeTitle: false))
        }
        let a = ListenItem(id: "a", title: "A", feedTitle: "F")
        let b = ListenItem(id: "b", title: "B", feedTitle: "F")
        controller.restore(current: a, at: SpeechPosition(blockID: "b0", offset: 8), upNext: [a, b])
        #expect(controller.state.status == .paused)
        #expect(controller.state.upNext == [b])  // the current item is not duplicated
        #expect(requested.isEmpty)               // nothing loads until play
        #expect(engine.state == .idle)

        controller.resume()
        for _ in 0..<20 where engine.state != .speaking { await Task.yield() }
        // The current story loads first; the next one is prepared while it plays.
        #expect(requested.first == "a")
        engine.step()
        #expect(controller.state.wordRange == 8..<13)  // "three"
    }

    @Test func onlyStoriesHeardToTheEndCountAsFinished() async {
        let engine = SimulatedSpeechEngine()
        let short = SpeechScript.build(document: ArticleParser.parse(html: "<p>Short.</p>"), title: nil,
                                       options: SpeechScriptOptions(includeTitle: false))
        let controller = ReadAlongController(engine: engine) { _ in short }
        var finished: [ArticleID] = []
        controller.onItemFinished = { finished.append($0.id) }
        let a = ListenItem(id: "a", title: "A", feedTitle: "F")
        let b = ListenItem(id: "b", title: "B", feedTitle: "F")
        let c = ListenItem(id: "c", title: "C", feedTitle: "F")

        controller.play(script: short, item: a)
        controller.enqueue(b)
        controller.enqueue(c)
        await controller.playNext()  // skip a before it finished
        #expect(controller.state.item?.id == "b")
        while engine.step() {}       // b plays to the end
        for _ in 0..<20 where controller.state.item?.id != "c" { await Task.yield() }
        #expect(finished == ["b"])
        #expect(controller.state.item?.id == "c")
    }
}

@Suite("Radio stations")
struct RadioLineupTests {
    let science = FeedCategory(id: CategoryID("user/-/label/Science"), label: "Science")
    let design = FeedCategory(id: CategoryID("user/-/label/Design"), label: "Design")
    let empty = FeedCategory(id: CategoryID("user/-/label/Empty"), label: "Empty")

    var pool: [RadioCandidate] {
        [candidate("s1", hoursAgo: 1), candidate("s2", hoursAgo: 2), candidate("s3", hoursAgo: 3),
         candidate("d1", feed: "feed/2", feedTitle: "Form", category: "user/-/label/Design", language: LanguageCode("de"), hoursAgo: 4),
         candidate("d2", feed: "feed/3", feedTitle: "Grid", category: "user/-/label/Design", hoursAgo: 5)]
    }

    @Test func dailyMixCapsEachSource() throws {
        let mix = try #require(RadioLineup.build(candidates: pool, categories: [science, design, empty]).dailyMix)
        #expect(mix.items.map(\.id.rawValue) == ["s1", "s2", "d1", "d2"])
        #expect(mix.sources == ["Field Notes", "Form", "Grid"])
        #expect(mix.storyCount == 4 && mix.estimatedSeconds == 500)
        #expect(mix.id == "mix")
    }

    @Test func stationsPerTopicLanguageAndSource() {
        let lineup = RadioLineup.build(candidates: pool, categories: [design, science, empty])
        #expect(lineup.topics.map(\.title) == ["Science", "Design"])  // busiest first; empty categories skipped
        #expect(lineup.topics.first?.items.count == 3)
        #expect(lineup.topics.allSatisfy { $0.filters.maxPerFeed == nil })
        #expect(lineup.languages.map(\.title) == ["en", "de"])
        #expect(lineup.languages.last?.items.map(\.id.rawValue) == ["d1"])
        #expect(lineup.sources.map(\.title) == ["Field Notes"])  // only sources with two or more stories
        #expect(Set((lineup.topics + lineup.languages + lineup.sources).map(\.id)).count == 5)
    }

    @Test func noLanguageStationsForOneLanguageAndNoMixWithoutStories() {
        #expect(RadioLineup.build(candidates: pool.filter { $0.language == .english }, categories: [science]).languages.isEmpty)
        #expect(RadioLineup.build(candidates: [], categories: [science]).dailyMix == nil)
    }

    @Test func stationsKeepTheUsersLengthButNotTheirScope() {
        var base = RadioFilters()
        base.storyLimit = 2
        base.feedIDs = [FeedID("feed/3")]
        let mix = RadioLineup.build(candidates: pool, categories: [science], base: base).dailyMix
        #expect(mix?.items.count == 2)
        #expect(mix?.filters.feedIDs.isEmpty == true)
    }
}

@Suite("Headlines and key points")
struct HeadlinesTests {
    @Test func keyPointsPreferTheLeadAndTheStorysOwnWords() {
        let html = """
        <p>Image source, Reuters</p>
        <p>Binance is trying to recover $6.3bn stolen in a hack that investigators link to North Korea. The exchange says customer funds are safe.</p>
        <p>The theft took about twenty minutes, according to people familiar with the investigation. Hackers used a compromised laptop.</p>
        <p>Sign up for our newsletter to get the news every morning.</p>
        <p>Analysts expect the hack to renew calls for stricter rules on crypto exchanges in Europe and the United States.</p>
        <p>The company's shares fell. Some traders said the weather in Lisbon was lovely this week, which had nothing to do with it.</p>
        """
        let document = ArticleParser.parse(html: html, title: nil)
        let points = KeyPoints.sentences(document: document, title: "Binance hit by $6.3bn hack", language: .english)
        #expect(points.count == 3)
        #expect(points.first?.hasPrefix("Binance is trying to recover") == true)
        #expect(!points.contains { $0.contains("newsletter") || $0.contains("Image source") })
        #expect(!points.contains { $0.contains("Lisbon") })
        let headline = KeyPoints.headline(document: document, title: "Binance hit by $6.3bn hack", language: .english)
        #expect(headline.split(separator: " ").count < 60)
    }

    @Test func headlinesStationPlansShortStoriesAndSkipsDuplicates() throws {
        let candidates = (1...20).map { index in
            candidate("h\(index)", feed: "feed/\(index % 7)", feedTitle: "Feed \(index % 7)", words: 1500, hoursAgo: Double(index))
        }
        let lineup = RadioLineup.build(candidates: candidates, categories: [], excluding: ["h1", "h2"])
        let headlines = try #require(lineup.headlines)
        #expect(headlines.storyCount == 14)  // two per source across seven sources
        #expect(!headlines.items.contains { ["h1", "h2"].contains($0.id.rawValue) })
        #expect(headlines.estimatedSeconds < 6 * 60)  // full stories would take an hour
        #expect(headlines.filters.markReadWhenFinished == false)
        #expect(lineup.dailyMix?.items.contains { $0.id == "h1" } == false)
        let bulletin = try #require(BulletinPlanner.build(candidates: candidates, filters: headlines.filters, mode: .headlines))
        #expect(bulletin.isHeadlines)
    }

    @Test func oldBulletinsWithoutAModeStillDecode() throws {
        let bulletin = try #require(BulletinPlanner.build(candidates: [candidate("a")], filters: RadioFilters()))
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(bulletin)) as! [String: Any]
        json.removeValue(forKey: "mode")
        let decoded = try JSONDecoder().decode(Bulletin.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(!decoded.isHeadlines && decoded.stories.count == 1)
    }
}
