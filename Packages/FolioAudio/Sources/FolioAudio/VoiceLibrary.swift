import Foundation
import FolioCore

/// Narrowing the Voice Library.
public struct VoiceFilter: Hashable, Sendable {
    public var query: String
    /// Base language code ("de"), or nil for all.
    public var language: String?
    public var minimumQuality: SpeechVoice.Quality?
    public var gender: SpeechVoice.Gender?
    public var installedOnly: Bool

    public init(query: String = "", language: String? = nil, minimumQuality: SpeechVoice.Quality? = nil,
                gender: SpeechVoice.Gender? = nil, installedOnly: Bool = false) {
        self.query = query
        self.language = language
        self.minimumQuality = minimumQuality
        self.gender = gender
        self.installedOnly = installedOnly
    }

    public func accepts(_ voice: SpeechVoice) -> Bool {
        if let language, voice.languageCode.base != language { return false }
        if let minimumQuality, voice.quality < minimumQuality { return false }
        if let gender, voice.gender != gender { return false }
        if installedOnly && !voice.isInstalled { return false }
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            let haystack = "\(voice.name) \(voice.language)".folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            return haystack.contains(q.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil))
        }
        return true
    }
}

public struct VoiceSection: Hashable, Sendable, Identifiable {
    /// Base language code.
    public var id: String
    public var voices: [SpeechVoice]
    public var defaultVoiceID: String?
    /// True when it is one of the reader's own languages.
    public var isPreferred: Bool
}

/// Organises voices the way the Voice Library shows them: the reader's own
/// languages first, inside each the default voice, then favourites (most
/// recently used first), then by quality and name.
public enum VoiceLibrary {
    public static func sections(
        voices: [SpeechVoice], filter: VoiceFilter = VoiceFilter(), preferredLanguages: [String] = [],
        defaults: [String: String] = [:], favourites: [String] = []
    ) -> [VoiceSection] {
        let accepted = voices.filter(filter.accepts)
        let grouped = Dictionary(grouping: accepted) { $0.languageCode.base }
        let favouriteRank = Dictionary(favourites.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let preferred = preferredLanguages.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }

        func sorted(_ list: [SpeechVoice], defaultID: String?) -> [SpeechVoice] {
            list.sorted { a, b in
                let da = a.id == defaultID, db = b.id == defaultID
                if da != db { return da }
                let fa = favouriteRank[a.id], fb = favouriteRank[b.id]
                if (fa != nil) != (fb != nil) { return fa != nil }
                if let fa, let fb, fa != fb { return fa < fb }
                if a.quality != b.quality { return a.quality > b.quality }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }

        let order = preferred.filter { grouped[$0] != nil } + grouped.keys.filter { !preferred.contains($0) }.sorted()
        return order.map { language in
            VoiceSection(id: language, voices: sorted(grouped[language] ?? [], defaultID: defaults[language]),
                         defaultVoiceID: defaults[language], isPreferred: preferred.contains(language))
        }
    }

    /// Defaults that point at voices which are no longer installed, so the
    /// app can say so instead of silently falling back.
    public static func missingDefaults(_ defaults: [String: String], installed voices: [SpeechVoice]) -> [String: String] {
        let ids = Set(voices.map(\.id))
        return defaults.filter { !ids.contains($0.value) }
    }

    /// The voice Folio uses for a language without an explicit default:
    /// highest quality, preferring the given region.
    public static func automaticVoice(for language: String, region: String? = nil, in voices: [SpeechVoice]) -> SpeechVoice? {
        // Neural voices are only used when chosen, never picked automatically.
        voices.filter { $0.languageCode.base == language && !$0.isPersonalVoice && $0.isInstalled
            && $0.engineID != NeuralVoiceCatalog.engineID }
            .max { a, b in
                if a.quality != b.quality { return a.quality < b.quality }
                let ra = a.region == region, rb = b.region == region
                if ra != rb { return !ra }
                return a.name > b.name
            }
    }

    /// Moves a voice to the front of the favourites (most recent first).
    public static func touch(_ id: String, in favourites: [String], limit: Int = 12) -> [String] {
        Array(([id] + favourites.filter { $0 != id }).prefix(limit))
    }
}

/// Short sentences for previewing a voice in its own language.
public enum VoiceSamples {
    public static func sentence(for language: String) -> String {
        switch LanguageCode(language).base {
        case "de": "So klingt Paperwire, wenn es dir deine Artikel vorliest."
        case "es": "Así suena Paperwire cuando te lee tus artículos."
        case "sk": "Takto znie Paperwire, keď vám číta vaše články."
        case "cs": "Takhle zní Paperwire, když vám čte vaše články."
        case "fr": "Voici comment Paperwire vous lit vos articles."
        case "it": "Ecco come Paperwire ti legge i tuoi articoli."
        case "pt": "É assim que o Paperwire lê os seus artigos."
        case "nl": "Zo klinkt Paperwire als het je artikelen voorleest."
        case "pl": "Tak brzmi Paperwire, gdy czyta ci twoje artykuły."
        default: "This is how Paperwire sounds when it reads your articles aloud."
        }
    }
}
