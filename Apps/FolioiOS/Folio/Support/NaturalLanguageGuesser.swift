import FolioCore
import NaturalLanguage

/// Apple's on-device language identification, which knows far more languages
/// than the portable stop-word guesser. Used for sync-time article language
/// and for switching voices per paragraph.
struct NaturalLanguageGuesser: LanguageGuessing {
    /// Base languages to choose from; empty allows every language Apple knows.
    /// Narration limits this to the languages the reader's feeds use, so a
    /// short English paragraph can't come out as Dutch or French.
    var constraints: Set<String> = []
    /// The language the text is expected to be in (the feed's usual one).
    /// It tips short, ambiguous text without overruling clear evidence.
    var hint: LanguageCode?

    func guess(_ text: String) -> LanguageGuess? {
        let recognizer = NLLanguageRecognizer()
        if !constraints.isEmpty {
            recognizer.languageConstraints = constraints.sorted().map { NLLanguage(rawValue: $0) }
        }
        if let hint {
            recognizer.languageHints = [NLLanguage(rawValue: hint.base): 0.6]
        }
        recognizer.processString(String(text.prefix(2000)))
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              language != .undetermined
        else { return nil }
        return LanguageGuess(language: LanguageCode(language.rawValue), confidence: confidence)
    }
}
