import Foundation

/// A BCP-47 language tag reduced to what voice selection needs.
public struct LanguageCode: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    /// Accepts "en", "en-US", "en_GB", "EN" and keeps the full tag lowercased
    /// with a hyphen; `base` gives the primary subtag.
    public init(_ tag: String) {
        rawValue = tag.replacingOccurrences(of: "_", with: "-").lowercased()
    }

    public var base: String { String(rawValue.split(separator: "-").first ?? "") }
    public var description: String { rawValue }

    public static let english = LanguageCode("en")
    public static let german = LanguageCode("de")
    public static let spanish = LanguageCode("es")
    public static let slovak = LanguageCode("sk")
    public static let czech = LanguageCode("cs")
    public static let french = LanguageCode("fr")

    /// Languages Folio tunes pronunciation rules and voice defaults for.
    public static let tuned: [LanguageCode] = [.english, .german, .spanish, .slovak]
}

/// Decides which language an article is read in. A guess from a two-line
/// feed summary is weak evidence: short English text full of names can look
/// French, and reading English with a French voice is unintelligible. Long
/// text decides on its own; shorter text needs a confident guess to overrule
/// what is already known (the feed's usual language, or an earlier guess).
public enum ArticleLanguage {
    /// Words a guess needs before it counts at all.
    public static let minimumWords = 12
    /// Words from which the article's own text outweighs everything else.
    public static let decisiveWords = 40

    /// - Parameters:
    ///   - text: the article's own text (the full text when it was fetched).
    ///   - feed: the language the feed usually writes in, if it has one.
    ///   - fallback: an earlier guess, used when nothing better is known.
    public static func resolve(text: String, guesser: (any LanguageGuessing)?, feed: LanguageCode?,
                               fallback: LanguageCode?) -> LanguageCode? {
        let prior = feed ?? fallback
        let words = TextNormalizer.wordCount(text)
        if let guesser, words >= minimumWords, let guess = guesser.guess(text) {
            if guess.language.base == prior?.base { return prior }
            let needed = words >= decisiveWords ? 0.6 : (prior == nil ? 0.5 : 0.9)
            if guess.confidence >= needed { return guess.language }
        }
        return prior
    }

    /// The language a feed writes in: at least 70 % of its articles with a
    /// known language, and at least five of them. Mixed feeds have none.
    public static func dominant(_ counts: [String: Int], minimumArticles: Int = 5, share: Double = 0.7) -> LanguageCode? {
        let total = counts.values.reduce(0, +)
        guard total >= minimumArticles,
              let best = counts.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }),
              Double(best.value) >= Double(total) * share
        else { return nil }
        return LanguageCode(best.key)
    }
}

public struct LanguageGuess: Hashable, Sendable {
    public var language: LanguageCode
    /// 0...1, share of the best language's hits among all hits.
    public var confidence: Double

    public init(language: LanguageCode, confidence: Double) {
        self.language = language
        self.confidence = confidence
    }
}

public protocol LanguageGuessing: Sendable {
    func guess(_ text: String) -> LanguageGuess?
}

/// Small, dependency-free language guesser for the languages Folio narrates.
/// It counts very common function words plus a few letters unique to one
/// language. On Apple platforms the app prefers `NLLanguageRecognizer` and
/// falls back to this; the user can always override per article or feed.
public struct StopwordLanguageGuesser: LanguageGuessing {
    struct Profile: Sendable {
        let language: LanguageCode
        let words: Set<String>
        let letters: Set<Character>
    }

    let profiles: [Profile]
    let minimumTokens: Int

    public init(minimumTokens: Int = 6) {
        self.minimumTokens = minimumTokens
        profiles = [
            Profile(language: .english, words: [
                "the", "and", "of", "to", "is", "in", "that", "it", "was", "for", "on", "are", "with", "as",
                "this", "be", "at", "by", "have", "from", "or", "an", "but", "not", "they", "which", "you",
                "we", "his", "her", "their", "has", "been", "will", "would", "there", "what", "about",
            ], letters: []),
            Profile(language: .german, words: [
                "der", "die", "das", "und", "ist", "nicht", "ein", "eine", "zu", "den", "von", "mit", "sich",
                "des", "auf", "für", "im", "dem", "auch", "es", "an", "werden", "aus", "er", "hat", "dass",
                "sie", "nach", "wird", "bei", "einer", "um", "noch", "wie", "über", "so", "zum", "wir", "ich",
            ], letters: ["ß", "ä", "ö", "ü"]),
            Profile(language: .spanish, words: [
                "el", "la", "de", "que", "y", "en", "los", "se", "del", "las", "un", "por", "con", "no", "una",
                "su", "para", "es", "al", "lo", "como", "más", "pero", "sus", "le", "ya", "o", "este", "sí",
                "porque", "esta", "entre", "cuando", "muy", "sin", "sobre", "también", "fue", "hay",
            ], letters: ["ñ", "¿", "¡"]),
            Profile(language: .slovak, words: [
                "a", "je", "sa", "na", "v", "že", "to", "s", "z", "ako", "ale", "po", "aj", "sú", "by", "do",
                "som", "nie", "alebo", "ktorý", "ktorá", "ktoré", "pre", "už", "len", "tak", "ich", "bol",
                "bola", "bolo", "keď", "však", "pri", "od", "si", "ešte", "môže", "veľmi", "tiež",
            ], letters: ["ä", "ô", "ľ", "ĺ", "ŕ"]),
            Profile(language: .czech, words: [
                "a", "je", "se", "na", "v", "že", "to", "s", "z", "jako", "ale", "po", "i", "jsou", "by", "do",
                "jsem", "ne", "nebo", "který", "která", "které", "pro", "už", "jen", "tak", "jejich", "byl",
                "byla", "bylo", "když", "však", "při", "od", "si", "ještě", "může", "velmi", "také",
            ], letters: ["ř", "ů", "ě"]),
            Profile(language: .french, words: [
                "le", "la", "les", "de", "des", "et", "est", "un", "une", "du", "que", "qui", "dans", "en",
                "pour", "pas", "au", "sur", "ce", "il", "elle", "avec", "plus", "mais", "nous", "vous", "sont",
            ], letters: ["ç", "œ", "è", "ê", "à"]),
        ]
    }

    public func guess(_ text: String) -> LanguageGuess? {
        let lowered = text.lowercased()
        let tokens = lowered.split { !$0.isLetter }.prefix(400)
        guard tokens.count >= minimumTokens else { return nil }

        var scores: [Double] = Array(repeating: 0, count: profiles.count)
        for token in tokens {
            let word = String(token)
            for (i, profile) in profiles.enumerated() where profile.words.contains(word) {
                scores[i] += 1
            }
        }
        // Letters unique to a language are strong evidence; count each
        // occurrence, capped so a single name can't decide the outcome.
        for (i, profile) in profiles.enumerated() where !profile.letters.isEmpty {
            let hits = lowered.reduce(0) { $0 + (profile.letters.contains($1) ? 1 : 0) }
            scores[i] += min(Double(hits) * 0.5, Double(tokens.count) * 0.15)
        }

        let total = scores.reduce(0, +)
        guard total > 0, let best = scores.indices.max(by: { scores[$0] < scores[$1] }) else { return nil }
        let confidence = scores[best] / total
        // Hits must make up a meaningful share of the text, otherwise this is
        // a language we have no profile for.
        guard scores[best] >= max(2, Double(tokens.count) * 0.15) else { return nil }
        return LanguageGuess(language: profiles[best].language, confidence: confidence)
    }
}
