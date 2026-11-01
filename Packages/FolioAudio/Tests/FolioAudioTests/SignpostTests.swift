import Foundation
import Testing
import FolioCore
import FolioReader
@testable import FolioAudio

@Suite("Signposts and sentences")
struct SignpostTests {
    private func spoken(_ script: SpeechScript) -> [String] {
        script.segments.map { $0.spokenText.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
    }

    @Test func tablesAndCodeAreMentionedOnceAndQuotesBreathe() {
        let doc = ArticleParser.parse(html: """
            <p>Here are the numbers.</p>
            <table><tr><td>A</td><td>1</td></tr></table>
            <pre>let x = 1</pre><pre>let y = 2</pre>
            <p>As one engineer put it:</p>
            <blockquote><p>It just works.</p></blockquote>
            <p>That was all.</p>
            """, title: nil)
        let script = SpeechScript.build(document: doc, title: nil, options: SpeechScriptOptions(includeTitle: false, language: .english))
        #expect(spoken(script) == ["Here are the numbers.", "Table skipped.", "Code skipped.", "As one engineer put it:",
                                   "It just works.", "That was all."])
        // A breath before and after the quote; cues are never highlighted.
        #expect(script.segments[3].pauseAfter >= 0.7 && script.segments[4].pauseAfter >= 0.7)
        #expect(script.segments[1].isAnnouncement && script.segments[2].isAnnouncement)

        var cleanup = SpeechCleanup(mentionSkipped: false, announceQuotes: true)
        cleanup.captions = false
        let quiet = SpeechScript.build(document: doc, title: nil,
                                       options: SpeechScriptOptions(includeTitle: false, language: .german, cleanup: cleanup))
        #expect(spoken(quiet) == ["Here are the numbers.", "As one engineer put it:", "Zitat.", "It just works.", "Zitat Ende.",
                                  "That was all."])
    }

    @Test func captionsNumbersAndEmoji() {
        let doc = ArticleParser.parse(html: """
            <figure><img src="https://example.com/a.jpg" alt="A red rocket"><figcaption>The launch at dawn.</figcaption></figure>
            <ol><li>Open the app 🚀</li><li>Pick a voice</li></ol>
            """, title: nil)
        let script = SpeechScript.build(document: doc, title: nil,
                                        options: SpeechScriptOptions(includeTitle: false, language: .english,
                                                                     cleanup: SpeechCleanup(captions: true)))
        #expect(spoken(script) == ["Image: The launch at dawn.", "1. Open the app", "2. Pick a voice"])
        // The number is spoken, not shown: highlights still land on the item's words.
        let item = script.segments[1]
        let open = item.spokenText.utf16Offset(of: item.spokenText.range(of: "Open")!.lowerBound)
        #expect(doc.blocks[1].text.utf16Slice(script.displayRange(segment: 1, spokenRange: open..<(open + 4)).range) == "Open")
    }

    @Test func theSentenceBeingReadIsKnownExactly() {
        let doc = ArticleParser.parse(html: "<p>First sentence here. Second one follows.</p>", title: nil)
        let paragraph = SpeechScript.build(document: doc, title: nil, options: SpeechScriptOptions(includeTitle: false, language: .english))
        // A paragraph segment knows its sentences; without a word it can't tell which.
        #expect(paragraph.segments[0].sentences.count == 2)
        #expect(paragraph.sentence(segment: 0, word: nil) == nil)
        let second = paragraph.segments[0].sentences[1]
        #expect(paragraph.sentence(segment: 0, word: second.lowerBound..<(second.lowerBound + 6)) == second)
        // Sentence by sentence, each segment is its own sentence.
        let sentences = SpeechScript.build(document: doc, title: nil,
                                           options: SpeechScriptOptions(granularity: .sentence, includeTitle: false, language: .english))
        #expect(sentences.sentence(segment: 1, word: nil) == sentences.segments[1].displayRange)
    }

    @Test func moneyRangesAndSignsAreSaidLikeANewsreader() {
        let rules = PronunciationRules()
        #expect(rules.spoken("Apple paid $4.5bn for it, up from US$200m.", language: .english)
                == "Apple paid 4.5 billion dollars for it, up from 200 million US dollars.")
        #expect(rules.spoken("Revenue rose +5% in 2020–2024. #WWDC in C#", language: .english)
                == "Revenue rose plus 5% in 2020 to 2024. WWDC in C#")
        #expect(rules.spoken("Der Deal kostet 3,2 Mrd. Euro von 2019–2021, z. B. Berlin.", language: .german)
                == "Der Deal kostet 3,2 Milliarden Euro von 2019 bis 2021, zum Beispiel Berlin.")
        #expect(rules.spoken("Ein Plus von €3m.", language: .german) == "Ein Plus von 3 Millionen Euro.")
        #expect(rules.spoken("Una inversión de $3m y otra de €40k.", language: .spanish)
                == "Una inversión de 3 millones de dólares y otra de 40 mil euros.")
        #expect(rules.spoken("V rokoch 2019–2021 to bolo €5 mil.", language: .slovak) == "V rokoch 2019 až 2021 to bolo €5 mil.")
        // "€5 more" is not "five million".
        #expect(rules.spoken("It costs €5 more.", language: .english) == "It costs €5 more.")
    }

    @Test func emojiAndBracketsLeaveTheSpokenText() {
        let rules = PronunciationRules()
        #expect(rules.spoken("Big news 🎉🎉 today 👍🏽 for 🇩🇪 fans", language: .english) == "Big news today for fans")
        let brackets = SpeechCleanup(parentheticals: true)
        #expect(rules.spoken("The CEO (who joined in 2019) said yes.", language: .english, cleanup: brackets) == "The CEO said yes.")
        #expect(rules.spoken("The CEO (who joined in 2019) said yes.", language: .english) == "The CEO (who joined in 2019) said yes.")
    }
}
