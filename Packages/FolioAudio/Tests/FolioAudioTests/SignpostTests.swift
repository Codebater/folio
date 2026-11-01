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
        // A quote is a paragraph like any other: no long pause around it. Cues are never highlighted.
        #expect(script.segments[3].pauseAfter == 0.35 && script.segments[4].pauseAfter == 0.35)
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
        #expect(spoken(script) == ["Image: The launch at dawn.", "1. Open the app.", "2. Pick a voice."])
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
        let longer = ArticleParser.parse(html: "<p>The first sentence is long enough to stand. The second one is long as well.</p>", title: nil)
        let sentences = SpeechScript.build(document: longer, title: nil,
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

    @Test func dashesAndBracketsBecomeNarratorPauses() {
        let rules = PronunciationRules()
        #expect(rules.spoken("The plan — if it works — saves a year.", language: .english) == "The plan, if it works, saves a year.")
        #expect(rules.spoken("Apple – the company – said no.", language: .english) == "Apple, the company, said no.")
        #expect(rules.spoken("He waited — and then left.", language: .english) == "He waited, and then left.")
        #expect(rules.spoken("It ended there —.", language: .english) == "It ended there.")
        #expect(rules.spoken("The CEO (who joined in 2019) said yes.", language: .english) == "The CEO, who joined in 2019, said yes.")
        #expect(rules.spoken("It rose (again).", language: .english) == "It rose, again.")
        // Ranges and hyphenated words are left alone.
        #expect(rules.spoken("From 2019–2021, a well-known case.", language: .english) == "From 2019 to 2021, a well-known case.")
    }

    @Test func emojiAndBracketsLeaveTheSpokenText() {
        let rules = PronunciationRules()
        #expect(rules.spoken("Big news 🎉🎉 today 👍🏽 for 🇩🇪 fans", language: .english) == "Big news today for fans")
        let brackets = SpeechCleanup(parentheticals: true)
        #expect(rules.spoken("The CEO (who joined in 2019) said yes.", language: .english, cleanup: brackets) == "The CEO said yes.")
        #expect(rules.spoken("The CEO (who joined in 2019) said yes.", language: .english) == "The CEO, who joined in 2019, said yes.")
    }
}

@Suite("Ivy and station language")
struct IvyAndStationLanguageTests {
    @Test func ivyIsIncludedInHerFiveLanguages() {
        for base in ["en", "de", "es", "cs", "sk"] {
            let id = NeuralVoiceCatalog.includedVoiceID(for: base)
            #expect(id == "neural.supertonic.F1.\(base)")
            #expect(NeuralVoiceCatalog.isIncluded(id!))
        }
        #expect(NeuralVoiceCatalog.includedVoiceID(for: "fr") == nil)
        #expect(!NeuralVoiceCatalog.isIncluded("neural.supertonic.F2.en"))
        #expect(!NeuralVoiceCatalog.isIncluded("neural.kokoro.af_heart"))
    }

    @Test func unknownLanguageFallsBackToTheLibrarysNotThePhones() {
        let doc = ArticleParser.parse(html: "<p>Ok.</p>", title: nil)
        let script = SpeechScript.build(document: doc, title: "Hi", options: SpeechScriptOptions(defaultLanguage: .english),
                                        languageGuesser: nil)
        #expect(script.language == .english)
        #expect(script.segments.allSatisfy { $0.language == .english })
    }

    private func story(_ id: String, _ language: LanguageCode?) -> RadioCandidate {
        RadioCandidate(item: ListenItem(id: ArticleID(id), title: "Story \(id)", feedTitle: "Feed \(id)"), feedID: FeedID("feed/\(id)"),
                       categoryIDs: [], language: language, wordCount: 300, publishedAt: Date(timeIntervalSince1970: 1_761_900_000))
    }

    @Test func stationsOpenInTheStoriesLanguageNotThePhones() throws {
        // A Spanish phone, English news: the first words are English.
        let english = try #require(BulletinPlanner.build(candidates: [story("1", .english), story("2", .english), story("3", .german)],
                                                         filters: RadioFilters(), bulletinLanguage: .spanish))
        #expect(english.opening.language == .english && english.opening.text.contains("Paperwire bulletin"))
        #expect(english.closing.language == .german)  // the last story is German
        // Czech news opens in Czech, with Czech plurals.
        let czech = try #require(BulletinPlanner.build(candidates: [story("4", .czech), story("5", .czech)], filters: RadioFilters(),
                                                       now: Date(timeIntervalSince1970: 1_761_900_000), bulletinLanguage: .english))
        #expect(czech.opening.language == .czech && czech.opening.text.contains("přehled Paperwire: 2 příběhy z 2 zdrojů"))
        #expect(czech.stories[0].introduction.hasPrefix("Nejprve Feed"))
        // Nothing known: the given language.
        let unknown = try #require(BulletinPlanner.build(candidates: [story("6", nil)], filters: RadioFilters(), bulletinLanguage: .german))
        #expect(unknown.opening.language == .german)
    }
}

@Suite("Seamless stories")
struct SeamlessStoryTests {
    @Test @MainActor func theNextStoryIsPreparedBeforeThisOneEnds() async {
        let engine = SimulatedSpeechEngine()
        let long = SpeechScript.build(document: ArticleParser.parse(html: "<p>One.</p><p>Two.</p><p>Three.</p><p>Four.</p><p>Five.</p><p>Six.</p>"),
                                      title: nil, options: SpeechScriptOptions(includeTitle: false, language: .english))
        let short = SpeechScript.build(document: ArticleParser.parse(html: "<p>Next story.</p>"), title: nil,
                                       options: SpeechScriptOptions(includeTitle: false, language: .english))
        var requests: [String] = []
        let controller = ReadAlongController(engine: engine) { item in
            requests.append(item.id.rawValue)
            return item.id == "b" ? short : long
        }
        var preparedSegments: Int?
        controller.onNextPrepared = { preparedSegments = $0.segments.count }
        controller.play(script: long, item: ListenItem(id: "a", title: "A", feedTitle: "F"))
        controller.enqueue(ListenItem(id: "b", title: "B", feedTitle: "F"))
        // Early on, nothing is fetched yet.
        engine.step()
        #expect(requests.isEmpty)
        // Four segments before the end, the next story is prepared...
        while controller.state.segmentIndex < 2 && engine.step() {}
        for _ in 0..<20 where preparedSegments == nil { await Task.yield() }
        #expect(requests == ["b"] && preparedSegments == 1)
        // ...and used when it starts, without asking again.
        while engine.step() {}
        for _ in 0..<20 where controller.state.item?.id != "b" { await Task.yield() }
        #expect(controller.state.item?.id == "b")
        #expect(requests == ["b"])
    }
}
