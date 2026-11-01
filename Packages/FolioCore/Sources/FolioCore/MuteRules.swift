import Foundation

/// Keywords the reader never wants to see. Matching is by whole words,
/// ignoring case and accents, so "AI" mutes "New AI model" but not "said",
/// and "Česko" also mutes "cesko". A term can be several words ("vision pro").
public struct MuteRules: Hashable, Sendable, Codable {
    public var terms: [String]

    public init(terms: [String] = []) {
        self.terms = terms
    }

    public var isEmpty: Bool { patterns.isEmpty }

    /// The first term that matches `text`, if any.
    public func match(_ text: String) -> String? {
        guard !isEmpty else { return nil }
        let words = Self.words(text)
        guard !words.isEmpty else { return nil }
        for (term, pattern) in zip(terms, Self.patterns(terms)) where !pattern.isEmpty && pattern.count <= words.count {
            for start in 0...(words.count - pattern.count) where words[start..<(start + pattern.count)].elementsEqual(pattern) {
                return term
            }
        }
        return nil
    }

    public func matches(_ text: String) -> Bool { match(text) != nil }

    private var patterns: [[String]] { Self.patterns(terms).filter { !$0.isEmpty } }

    static func patterns(_ terms: [String]) -> [[String]] { terms.map(words) }

    static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }
}
