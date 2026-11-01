import Foundation
import Testing
import FolioCore
import FolioReader
@testable import FolioAudio

/// A recognizer that is sure everything is French, the way short English
/// text full of links and names fooled the real one.
private struct FrenchGuesser: LanguageGuessing {
    func guess(_ text: String) -> LanguageGuess? { LanguageGuess(language: .french, confidence: 0.95) }
}

@Suite("Languages read aloud")
struct ReadAloudLanguageTests {
    @Test func aHackerNewsItemGetsNoLanguageFromItsLinks() {
        let html = """
            <p>Article URL: <a href="https://github.com/acme/tool">https://github.com/acme/tool</a></p>
            <p>Comments URL: <a href="https://news.ycombinator.com/item?id=4242">https://news.ycombinator.com/item?id=4242</a></p>
            <p>Points: 125</p><p># Comments: 47</p>
            """
        let document = ArticleParser.parse(html: html, title: "Show HN: A tool", languageGuesser: FrenchGuesser())
        #expect(document.language == nil)
    }

    @Test func aLanguageThatIsOffIsNeverSpoken() {
        let long = ArticleParser.parse(html: "<p>" + Array(repeating: "Les mots sont ici.", count: 30).joined(separator: " ") + "</p>")
        var options = SpeechScriptOptions(language: nil, feedLanguage: .french, defaultLanguage: .english)
        options.readAloudLanguages = ["en", "de"]
        let script = SpeechScript.build(document: long, title: "Show HN: A tool", options: options, languageGuesser: FrenchGuesser())
        #expect(script.language == .english)
        #expect(script.segments.allSatisfy { $0.language?.base == "en" })
        // With French turned on, the same article is French.
        options.readAloudLanguages = ["en", "fr"]
        #expect(SpeechScript.build(document: long, title: nil, options: options, languageGuesser: FrenchGuesser()).language == .french)
    }

    @Test func paragraphsSwitchOnlyToLanguagesThatAreOn() {
        let english = Array(repeating: "The council met again on Tuesday to talk about the budget.", count: 6).joined(separator: " ")
        let other = Array(repeating: "Le conseil s'est réuni mardi pour parler du budget de la ville.", count: 3).joined(separator: " ")
        let doc = ArticleParser.parse(html: "<p>\(english)</p><p>\(other)</p>")
        var options = SpeechScriptOptions(includeTitle: false, language: nil)
        options.readAloudLanguages = ["en"]
        // The article itself is English (main language); the French paragraph stays English.
        let script = SpeechScript.build(document: doc, title: nil, options: options, languageGuesser: FrenchGuesser())
        #expect(script.segments.allSatisfy { $0.language?.base == "en" })
    }
}
