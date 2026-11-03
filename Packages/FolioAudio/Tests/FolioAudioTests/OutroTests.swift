import Testing
import FolioCore
import FolioReader
@testable import FolioAudio

@Suite("Article outro")
struct OutroTests {
    @Test func saysWhereItWasFromAndWhatIsNextInTheArticlesLanguage() {
        let outro = SpeechOutro(source: "The Margin", nextTitle: "Why pages feel quiet | Field Notes", nextSource: "Field Notes")
        #expect(outro.text(language: .english) == "That was an article from The Margin. Coming up next: Why pages feel quiet.")
        #expect(outro.text(language: .german) == "Das war ein Artikel von The Margin. Als Nächstes: Why pages feel quiet.")
        #expect(outro.text(language: .slovak) == "To bol článok zo zdroja The Margin. Nasleduje: Why pages feel quiet.")
        #expect(SpeechOutro(source: "Denník N").text(language: .slovak) == "To bol článok zo zdroja Denník N.")
        #expect(SpeechOutro(source: nil, nextTitle: "Das Wetter").text(language: .german) == "Als Nächstes: Das Wetter.")
        #expect(SpeechOutro(source: nil).text(language: .english) == nil)
        // No English words in a voice for another language.
        #expect(outro.text(language: .french) == nil)
    }

    @Test func comesAfterTheLastParagraphAsAnAnnouncement() {
        let doc = ArticleParser.parse(html: "<p>Der Rat hat den Haushalt beschlossen.</p>")
        var options = SpeechScriptOptions(includeTitle: false, language: .german)
        options.outro = SpeechOutro(source: "Tagesschau", nextTitle: "Das Wetter")
        let script = SpeechScript.build(document: doc, title: nil, options: options,
                                        announcementsAfter: [SpeechAnnouncement("Danke.")])
        #expect(script.segments.map(\.spokenText).suffix(2) == ["Das war ein Artikel von Tagesschau. Als Nächstes: Das Wetter.", "Danke."])
        let outro = script.segments[script.segments.count - 2]
        #expect(outro.isAnnouncement && outro.language == .german)
    }
}
