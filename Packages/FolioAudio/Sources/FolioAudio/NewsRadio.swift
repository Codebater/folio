import Foundation
import FolioCore

/// What goes into a News Radio bulletin.
public struct RadioFilters: Hashable, Sendable, Codable {
    public enum Order: String, Hashable, Sendable, Codable, CaseIterable { case newest, oldest }

    /// Empty sets mean "everything".
    public var feedIDs: Set<FeedID> = []
    public var categoryIDs: Set<CategoryID> = []
    /// Base language codes ("en", "de"). Empty includes articles of unknown language too.
    public var languages: Set<String> = []
    public var minutes = 15
    public var storyLimit = 8
    public var order: Order = .newest
    /// Stories listened to the end are marked read; skipped ones stay unread.
    public var markReadWhenFinished = true
    /// At most this many stories from one source, so a busy feed can't fill
    /// the whole bulletin. nil means no cap.
    public var maxPerFeed: Int?

    public init() {}
}

/// An unread article the planner may choose.
public struct RadioCandidate: Hashable, Sendable {
    public var item: ListenItem
    public var feedID: FeedID
    public var categoryIDs: [CategoryID]
    public var language: LanguageCode?
    public var wordCount: Int
    public var publishedAt: Date

    public init(item: ListenItem, feedID: FeedID, categoryIDs: [CategoryID], language: LanguageCode?, wordCount: Int, publishedAt: Date) {
        self.item = item
        self.feedID = feedID
        self.categoryIDs = categoryIDs
        self.language = language
        self.wordCount = wordCount
        self.publishedAt = publishedAt
    }
}

/// A planned bulletin: an opening, a short spoken introduction before each
/// story (in the story's own language), and a closing. The stories play
/// through the ordinary listening queue; the bulletin only adds the
/// announcements around them.
public struct Bulletin: Hashable, Sendable, Codable {
    public struct Story: Hashable, Sendable, Codable {
        public var item: ListenItem
        public var language: LanguageCode?
        public var introduction: String
        /// Estimate at the planning rate, never shown as an exact time.
        public var estimatedSeconds: Int
    }

    public enum Mode: String, Hashable, Sendable, Codable {
        /// Every story read in full.
        case full
        /// Each story read as its key points, about twenty seconds each.
        case headlines
    }

    public var stories: [Story]
    public var opening: SpeechAnnouncement
    public var closing: SpeechAnnouncement
    public var createdAt: Date
    public var markReadWhenFinished: Bool
    /// nil in bulletins saved before headlines existed: full.
    public var mode: Mode?

    public var isHeadlines: Bool { mode == .headlines }

    public var estimatedSeconds: Int { stories.reduce(0) { $0 + $1.estimatedSeconds } }
    public var items: [ListenItem] { stories.map(\.item) }

    public func contains(_ id: ArticleID) -> Bool { stories.contains { $0.item.id == id } }

    /// Announcements around one story: the opening before the first, its
    /// introduction, and the closing after the last.
    public func announcements(for id: ArticleID) -> (before: [SpeechAnnouncement], after: [SpeechAnnouncement]) {
        guard let index = stories.firstIndex(where: { $0.item.id == id }) else { return ([], []) }
        let story = stories[index]
        var before: [SpeechAnnouncement] = []
        if index == 0 { before.append(opening) }
        before.append(SpeechAnnouncement(story.introduction, language: story.language))
        return (before, index == stories.count - 1 ? [closing] : [])
    }
}

public enum BulletinPlanner {
    /// Words per minute at 1x, for budgeting only.
    static let wordsPerMinute = 165.0
    /// Seconds an introduction takes, roughly.
    static let introductionSeconds = 5

    /// Picks unread stories that match the filters and fit the time budget.
    /// Stories longer than the remaining time are skipped, never truncated,
    /// so a short story further down can still fill the gap.
    public static func build(
        candidates: [RadioCandidate], filters: RadioFilters, rate: Double = 1, now: Date = Date(),
        bulletinLanguage: LanguageCode = .english, excluding: Set<ArticleID> = [], mode: Bulletin.Mode = .full
    ) -> Bulletin? {
        // A headline is about two sentences whatever the article's length.
        func seconds(_ candidate: RadioCandidate) -> Int {
            mode == .headlines ? estimate(words: 40, rate: rate) : estimate(words: candidate.wordCount, rate: rate)
        }
        var pool = candidates.filter { candidate in
            guard !excluding.contains(candidate.item.id), candidate.wordCount > 0 else { return false }
            if !filters.feedIDs.isEmpty && !filters.feedIDs.contains(candidate.feedID) { return false }
            if !filters.categoryIDs.isEmpty && filters.categoryIDs.isDisjoint(with: candidate.categoryIDs) { return false }
            if !filters.languages.isEmpty {
                guard let base = candidate.language?.base, filters.languages.contains(base) else { return false }
            }
            return true
        }
        pool.sort { a, b in
            a.publishedAt != b.publishedAt
                ? (filters.order == .newest ? a.publishedAt > b.publishedAt : a.publishedAt < b.publishedAt)
                : a.item.id.rawValue < b.item.id.rawValue
        }

        let budget = max(1, filters.minutes) * 60
        var used = 0
        var chosen: [RadioCandidate] = []
        var perFeed: [FeedID: Int] = [:]
        for candidate in pool where chosen.count < max(1, filters.storyLimit) {
            if let cap = filters.maxPerFeed, perFeed[candidate.feedID, default: 0] >= cap { continue }
            let length = seconds(candidate)
            if used + length > budget { continue }
            chosen.append(candidate)
            used += length
            perFeed[candidate.feedID, default: 0] += 1
        }
        guard !chosen.isEmpty else { return nil }

        let stories = chosen.enumerated().map { index, candidate in
            Bulletin.Story(
                item: candidate.item, language: candidate.language,
                introduction: Phrases.introduction(feed: candidate.item.feedTitle, title: candidate.item.title,
                                                   isFirst: index == 0, language: candidate.language ?? bulletinLanguage),
                estimatedSeconds: seconds(candidate))
        }
        let sources = Set(chosen.map(\.feedID)).count
        let minutes = max(1, Int((Double(used) / 60).rounded()))
        return Bulletin(
            stories: stories,
            opening: SpeechAnnouncement(Phrases.opening(stories: stories.count, sources: sources, minutes: minutes, now: now,
                                                        language: bulletinLanguage), language: bulletinLanguage),
            closing: SpeechAnnouncement(Phrases.closing(language: bulletinLanguage), language: bulletinLanguage),
            createdAt: now, markReadWhenFinished: filters.markReadWhenFinished, mode: mode)
    }

    static func estimate(words: Int, rate: Double) -> Int {
        Int((Double(words) / (wordsPerMinute * max(rate, 0.25)) * 60).rounded(.up)) + introductionSeconds
    }

    /// Spoken phrases for the four tuned languages; anything else uses English.
    enum Phrases {
        static func opening(stories: Int, sources: Int, minutes: Int, now: Date, language: LanguageCode) -> String {
            let hour = Calendar(identifier: .gregorian).component(.hour, from: now)
            switch language.base {
            case "de":
                let greeting = hour < 11 ? "Guten Morgen." : (hour < 18 ? "Guten Tag." : "Guten Abend.")
                return "\(greeting) Ihr Paperwire-Überblick: \(stories) \(stories == 1 ? "Geschichte" : "Geschichten") aus \(sources) \(sources == 1 ? "Quelle" : "Quellen"), etwa \(minutes) Minuten."
            case "es":
                let greeting = hour < 12 ? "Buenos días." : (hour < 20 ? "Buenas tardes." : "Buenas noches.")
                return "\(greeting) Este es tu boletín de Paperwire: \(stories) \(stories == 1 ? "historia" : "historias") de \(sources) \(sources == 1 ? "fuente" : "fuentes"), unos \(minutes) minutos."
            case "sk":
                let greeting = hour < 10 ? "Dobré ráno." : (hour < 18 ? "Dobrý deň." : "Dobrý večer.")
                return "\(greeting) Toto je váš prehľad Paperwire: \(stories) \(slovakCount(stories, "príbeh", "príbehy", "príbehov")) z \(sources) \(slovakCount(sources, "zdroja", "zdrojov", "zdrojov")), asi \(minutes) \(slovakCount(minutes, "minúta", "minúty", "minút"))."
            default:
                let greeting = hour < 12 ? "Good morning." : (hour < 18 ? "Good afternoon." : "Good evening.")
                return "\(greeting) This is your Paperwire bulletin: \(stories) \(stories == 1 ? "story" : "stories") from \(sources) \(sources == 1 ? "source" : "sources"), about \(minutes) \(minutes == 1 ? "minute" : "minutes")."
            }
        }

        static func introduction(feed: String, title: String, isFirst: Bool, language: LanguageCode) -> String {
            switch language.base {
            case "de": return isFirst ? "Zuerst, von \(feed): \(title)." : "Als Nächstes, von \(feed): \(title)."
            case "es": return isFirst ? "Primero, de \(feed): \(title)." : "A continuación, de \(feed): \(title)."
            case "sk": return isFirst ? "Najprv \(feed): \(title)." : "Ďalej \(feed): \(title)."
            default: return isFirst ? "First, from \(feed): \(title)." : "Next, from \(feed): \(title)."
            }
        }

        static func closing(language: LanguageCode) -> String {
            switch language.base {
            case "de": return "Das war Ihr Überblick. Danke fürs Zuhören."
            case "es": return "Eso es todo por ahora. Gracias por escuchar."
            case "sk": return "To je na teraz všetko. Ďakujeme, že ste počúvali."
            default: return "That's the bulletin. Thanks for listening."
            }
        }

        /// Slovak plural forms: 1, 2–4, 5+ (with "z" the genitive is used: 1 zdroja, 2+ zdrojov).
        static func slovakCount(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
            n == 1 ? one : ((2...4).contains(n) ? few : many)
        }
    }
}
