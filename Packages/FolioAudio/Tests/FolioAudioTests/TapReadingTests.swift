import Foundation
import Testing
import FolioCore
import FolioReader
@testable import FolioAudio

@Suite("Tap to read")
struct TapReadingTests {
    private func offset(of word: String, in text: String) -> Int { (text as NSString).range(of: word).location }

    @Test func aTapStartsAtTheStartOfItsSentence() {
        let text = "A page is mostly the space around the words. Open a well-made book and the first thing you notice is nothing at all."
        #expect(TapReading.start(in: text, at: offset(of: "book", in: text), language: .english) == offset(of: "Open", in: text))
        #expect(TapReading.start(in: text, at: offset(of: "space", in: text), language: .english) == 0)
        // Commas don't matter in a short sentence.
        let short = "First, we went home. Then, after dinner, we read."
        #expect(TapReading.start(in: short, at: offset(of: "read", in: short), language: .english) == offset(of: "Then", in: short))
    }

    @Test func aLongSentenceStartsAtTheClause() {
        let text = "In the early hours before the city wakes up and the trams start running again across the old bridges and the quiet squares, the bakers light their ovens and wait."
        #expect(TapReading.start(in: text, at: offset(of: "ovens", in: text), language: .english) == offset(of: "the bakers", in: text))
        let dashed = "In the early hours before the city wakes up and the trams start running again across the old bridges and the quiet squares — the bakers light their ovens."
        #expect(TapReading.start(in: dashed, at: offset(of: "ovens", in: dashed), language: .english) == offset(of: "the bakers", in: dashed))
        // A hyphen inside a word isn't a clause break.
        let hyphen = "In the early hours before the city wakes up and the trams start running again across the old well-lit bridges and the bakers light their ovens."
        #expect(TapReading.start(in: hyphen, at: offset(of: "ovens", in: hyphen), language: .english) == 0)
    }

    @MainActor @Test func tappingWhilePausedPlaysFromTheTappedSentence() async throws {
        let doc = ArticleParser.parse(html: """
            <p>First paragraph here. It has two sentences.</p>
            <p>The second paragraph starts here. Then a tapped word sits inside this sentence.</p>
            """)
        let script = SpeechScript.build(document: doc, title: nil, options: SpeechScriptOptions(includeTitle: false, language: .english))
        let engine = SimulatedSpeechEngine()
        let controller = ReadAlongController(engine: engine) { _ in script }
        controller.play(script: script, item: ListenItem(id: "a", title: "A", feedTitle: "F"))
        _ = engine.step()
        controller.pause()
        #expect(engine.state == .paused)

        let text = try #require(doc.blocks.first { $0.id == "b1" }).text
        await controller.read(from: SpeechPosition(blockID: "b1", offset: offset(of: "tapped", in: text)), blockText: text)
        #expect(engine.state == .speaking)
        _ = engine.step()
        #expect(controller.state.blockID == "b1")
        #expect(controller.state.wordRange?.lowerBound == offset(of: "Then", in: text))
    }

    @MainActor @Test func aTapAfterARelaunchLoadsTheStoryAndStartsThere() async throws {
        let doc = ArticleParser.parse(html: "<p>One sentence first. And the tapped one comes next.</p>")
        let script = SpeechScript.build(document: doc, title: nil, options: SpeechScriptOptions(includeTitle: false, language: .english))
        let engine = SimulatedSpeechEngine()
        let controller = ReadAlongController(engine: engine) { _ in script }
        // Restored paused, with no script loaded yet.
        controller.restore(current: ListenItem(id: "a", title: "A", feedTitle: "F"), at: nil, upNext: [])
        #expect(controller.currentScript == nil)

        let text = try #require(doc.blocks.first).text
        await controller.read(from: SpeechPosition(blockID: "b0", offset: offset(of: "tapped", in: text)), blockText: text)
        #expect(engine.state == .speaking)
        _ = engine.step()
        #expect(controller.state.wordRange?.lowerBound == offset(of: "And", in: text))
    }

    @Test func scriptsKnowTheirBlocks() {
        let doc = ArticleParser.parse(html: "<p>Hello there, reader.</p>")
        let script = SpeechScript.build(document: doc, title: "Title", options: SpeechScriptOptions(language: .english))
        #expect(script.contains(blockID: "b0") && script.contains(blockID: "title"))
        #expect(!script.contains(blockID: "b7"))  // a block from a longer version of the article
    }
}
