import Foundation

/// Finds articles from different feeds that report the same story, so a
/// busy morning shows one story with "3 sources" instead of three
/// near-copies, News Radio never plays the same news twice, and reading one
/// can mark the others read.
///
/// Titles carry most of the signal. Words are compared after folding case
/// and accents, common words are ignored, and rare words count for more
/// (two articles sharing "Northflank" and "breach" are far likelier to be
/// the same story than two sharing "new" and "model"). Only articles from
/// different feeds, published within `window` of each other, are compared.
public enum StoryClusters {
    public struct Item: Hashable, Sendable {
        public var id: ArticleID
        public var feedID: FeedID
        public var title: String
        public var excerpt: String
        public var publishedAt: Date

        public init(id: ArticleID, feedID: FeedID, title: String, excerpt: String, publishedAt: Date) {
            self.id = id
            self.feedID = feedID
            self.title = title
            self.excerpt = excerpt
            self.publishedAt = publishedAt
        }
    }

    /// Groups of two or more articles, each in publication order.
    public static func find(_ items: [Item], window: TimeInterval = 36 * 3600, threshold: Double = 0.30) -> [[ArticleID]] {
        guard items.count > 1 else { return [] }
        let titles = items.map { Set(tokens($0.title)) }
        let excerpts = items.map { Set(tokens(String($0.excerpt.prefix(400)))) }
        var frequency: [String: Int] = [:]
        for set in zip(titles, excerpts).map({ $0.union($1) }) { for token in set { frequency[token, default: 0] += 1 } }
        let total = Double(items.count)
        func weight(_ token: String) -> Double { log(1 + total / Double(frequency[token] ?? 1)) }
        func similarity(_ a: Set<String>, _ b: Set<String>) -> Double {
            let shared = a.intersection(b)
            guard !shared.isEmpty else { return 0 }
            let union = a.union(b).reduce(0) { $0 + weight($1) }
            return union == 0 ? 0 : shared.reduce(0) { $0 + weight($1) } / union
        }

        var parent = Array(items.indices)
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i] != i {
                parent[i] = parent[parent[i]]
                i = parent[i]
            }
            return i
        }
        let order = items.indices.sorted { items[$0].publishedAt < items[$1].publishedAt }
        for (position, i) in order.enumerated() {
            for j in order[(position + 1)...] {
                if items[j].publishedAt.timeIntervalSince(items[i].publishedAt) > window { break }
                guard items[i].feedID != items[j].feedID else { continue }
                let sharedTitle = titles[i].intersection(titles[j])
                // At least two shared title words, or one rare one (a name).
                guard sharedTitle.count >= 2 || sharedTitle.contains(where: { weight($0) >= log(1 + total / 2) }) else { continue }
                let score = 0.75 * similarity(titles[i], titles[j]) + 0.25 * similarity(excerpts[i], excerpts[j])
                // One shared word (a name, a CVE number) needs clearly stronger evidence overall.
                if score >= threshold + (sharedTitle.count == 1 ? 0.12 : 0) { parent[root(j)] = root(i) }
            }
        }
        var groups: [Int: [Int]] = [:]
        for i in order { groups[root(i), default: []].append(i) }
        return groups.values.filter { $0.count > 1 }
            .sorted { items[$0[0]].publishedAt > items[$1[0]].publishedAt }
            .map { $0.map { items[$0].id } }
    }

    /// Content words of a text, folded and lightly stemmed (for summaries too).
    public static func keyTokens(_ text: String) -> [String] { tokens(text) }

    static func tokens(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { token in
                guard !stopwords.contains(token) else { return false }
                // Years say nothing about which story it is ("CVE-2026-…", "in 2026").
                if token.count == 4, let year = Int(token), (1900...2099).contains(year) { return false }
                return token.count >= 3 || (token.count >= 2 && token.allSatisfy(\.isNumber))
            }
            .map(stem)
    }

    /// Plurals and possessives meet their singular ("batteries" ~ "battery", "apple's" ~ "apple").
    static func stem(_ token: String) -> String {
        if token.hasSuffix("ies"), token.count > 4 { return String(token.dropLast(3)) + "y" }
        if token.hasSuffix("s"), !token.hasSuffix("ss"), token.count > 4 { return String(token.dropLast()) }
        return token
    }

    static let stopwords: Set<String> = [
        // English function words and headline filler
        "the", "and", "for", "with", "from", "that", "this", "are", "was", "were", "has", "have", "had", "its", "into", "over",
        "after", "about", "than", "but", "not", "you", "your", "our", "their", "they", "will", "would", "can", "could", "how",
        "why", "what", "when", "who", "new", "says", "said", "report", "reports", "update", "updated", "live", "more", "just",
        "now", "today", "week", "first", "out", "off", "all", "one", "two", "get", "gets", "big", "here", "via", "amid",
        "make", "makes", "back", "still", "may", "cve", "might", "should", "being", "been", "also", "some", "most",
        // German
        "der", "die", "das", "und", "mit", "von", "für", "fur", "auf", "ist", "ein", "eine", "einen", "dem", "den", "des",
        "sich", "auch", "nach", "wie", "neue", "neuer", "neues", "bei", "aus", "zum", "zur", "wird", "nicht",
        // Spanish
        "los", "las", "del", "con", "para", "por", "una", "que", "como", "nuevo", "nueva", "sus", "mas",
        // Czech and Slovak
        "pro", "jak", "jako", "ale", "nebo", "kde", "ktery", "ktera", "ktere", "novy", "nova", "nove", "ako", "pre",
        "alebo", "ktory", "ktora", "ktore", "aby",
    ]
}
