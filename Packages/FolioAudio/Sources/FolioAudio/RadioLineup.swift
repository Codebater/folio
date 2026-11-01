import Foundation
import FolioCore

/// A ready-made bulletin, like a radio station: what it covers, the filters
/// behind it and what it would play right now.
public struct RadioStation: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
        /// Unread stories from every source, at most two per source.
        case dailyMix
        /// The day's stories as key points, about twenty seconds each.
        case headlines
        case topic(CategoryID)
        /// A base language code such as "de".
        case language(String)
        case source(FeedID)
    }

    public var kind: Kind
    /// The category label or feed title; the language code for language stations.
    public var title: String
    public var filters: RadioFilters
    public var storyCount: Int
    /// Estimate at the planning rate, never shown as an exact time.
    public var estimatedSeconds: Int
    /// Distinct sources in play order.
    public var sources: [String]
    /// The stories in play order.
    public var items: [ListenItem]

    public var id: String {
        switch kind {
        case .dailyMix: "mix"
        case .headlines: "headlines"
        case .topic(let id): "topic:\(id.rawValue)"
        case .language(let code): "language:\(code)"
        case .source(let id): "source:\(id.rawValue)"
        }
    }
}

/// The stations on the Listen page, planned from the unread articles.
public struct RadioLineup: Hashable, Sendable {
    public var dailyMix: RadioStation?
    public var headlines: RadioStation?
    public var topics: [RadioStation] = []
    /// Only when the unread articles are in more than one language.
    public var languages: [RadioStation] = []
    /// Sources with at least two unread stories, busiest first.
    public var sources: [RadioStation] = []

    public init() {}

    /// Length, story limit, order and mark-read come from `base` (the user's
    /// News Radio settings); each station sets only its own scope. Stations
    /// play `mainLanguage` first, then one section per other language.
    public static func build(
        candidates: [RadioCandidate], categories: [FeedCategory], base: RadioFilters = RadioFilters(),
        rate: Double = 1, now: Date = Date(), maxSources: Int = 10, excluding duplicates: Set<ArticleID> = [],
        mainLanguage: LanguageCode = .english
    ) -> RadioLineup {
        var scope = base
        scope.feedIDs = []
        scope.categoryIDs = []
        scope.languages = []
        scope.maxPerFeed = nil

        func station(_ kind: RadioStation.Kind, _ title: String, _ edit: (inout RadioFilters) -> Void) -> RadioStation? {
            var filters = scope
            edit(&filters)
            // The same news from several feeds plays once.
            guard let plan = BulletinPlanner.build(candidates: candidates, filters: filters, rate: rate, now: now,
                                                   bulletinLanguage: mainLanguage, excluding: duplicates,
                                                   mode: kind == .headlines ? .headlines : .full)
            else { return nil }
            var seen: Set<String> = []
            let sources = plan.stories.map(\.item.feedTitle).filter { seen.insert($0).inserted }
            return RadioStation(kind: kind, title: title, filters: filters, storyCount: plan.stories.count,
                                estimatedSeconds: plan.estimatedSeconds, sources: sources, items: plan.stories.map(\.item))
        }

        var perCategory: [CategoryID: Int] = [:]
        var perLanguage: [String: Int] = [:]
        var perFeed: [FeedID: (title: String, count: Int)] = [:]
        for candidate in candidates where candidate.wordCount > 0 {
            for id in Set(candidate.categoryIDs) { perCategory[id, default: 0] += 1 }
            if let language = candidate.language?.base { perLanguage[language, default: 0] += 1 }
            perFeed[candidate.feedID, default: (candidate.item.feedTitle, 0)].count += 1
        }

        var lineup = RadioLineup()
        lineup.dailyMix = station(.dailyMix, "Daily Mix") { $0.maxPerFeed = 2 }
        lineup.headlines = station(.headlines, "Headlines") {
            $0.maxPerFeed = 2
            $0.storyLimit = 15
            $0.minutes = 10
            $0.markReadWhenFinished = false  // skimming isn't reading
        }
        lineup.topics = categories
            .filter { perCategory[$0.id] != nil }
            .sorted { a, b in
                let (countA, countB) = (perCategory[a.id] ?? 0, perCategory[b.id] ?? 0)
                return countA != countB ? countA > countB : a.label < b.label
            }
            .compactMap { category in station(.topic(category.id), category.label) { $0.categoryIDs = [category.id] } }
        if perLanguage.count > 1 {
            lineup.languages = perLanguage
                .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .compactMap { entry in station(.language(entry.key), entry.key) { $0.languages = [entry.key] } }
        }
        lineup.sources = perFeed
            .filter { $0.value.count >= 2 }
            .sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.value.title < $1.value.title }
            .prefix(maxSources)
            .compactMap { entry in station(.source(entry.key), entry.value.title) { $0.feedIDs = [entry.key] } }
        return lineup
    }
}
