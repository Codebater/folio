import Foundation
import Testing
import FolioCore
import FolioReader
@testable import FolioAudio

@Suite("Titles read aloud")
struct TitleNarrationTests {
    let document = ArticleParser.parse(html: "<p>The body starts here.</p>", title: nil)

    private func spokenTitle(_ title: String, source: String? = nil) -> String? {
        let script = SpeechScript.build(document: document, title: title,
                                        options: SpeechScriptOptions(language: .english, sourceName: source))
        return script.segments.first { $0.blockID == SpeechScript.titleBlockID }.map {
            // Titles are closed with a full stop for the voice; compare the words.
            var text = $0.spokenText.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if text.hasSuffix(".") { text.removeLast() }
            return text
        }
    }

    @Test func titlesEndWithAFullStopForTheVoice() {
        let script = SpeechScript.build(document: document, title: "Rising seas", options: SpeechScriptOptions(language: .english))
        #expect(script.segments.first?.spokenText == "Rising seas.")
        let asked = SpeechScript.build(document: document, title: "Is this the end?", options: SpeechScriptOptions(language: .english))
        #expect(asked.segments.first?.spokenText == "Is this the end?")
    }

    @Test func siteNamesInTitlesAreNotRead() {
        #expect(spokenTitle("Why the best pages feel quiet | The Margin", source: "The Margin") == "Why the best pages feel quiet")
        #expect(spokenTitle("The Verge: Apple announces a new iPad", source: "The Verge") == "Apple announces a new iPad")
        #expect(spokenTitle("Rocket lands on a barge – Ars Technica", source: "Ars Technica") == "Rocket lands on a barge")
        // A subtitle that isn't the site stays.
        #expect(spokenTitle("Python 3.14 - What's new", source: "Python Insider") == "Python 3.14 - What's new")
        #expect(spokenTitle("Notes | Margins", source: nil) == "Notes | Margins")
    }

    @Test func formatTagsShoutingAndEmojiAreCleaned() {
        #expect(spokenTitle("[Video] Rocket lands on a barge (Podcast)") == "Rocket lands on a barge")
        #expect(spokenTitle("Election night (live)") == "Election night")
        #expect(spokenTitle("Quiet design (Opinion)") == "Quiet design (Opinion)")  // a real word, kept
        #expect(spokenTitle("BREAKING: EU PASSES NEW AI RULES TODAY") == "Breaking: EU passes NEW AI rules today")
        #expect(spokenTitle("NASA picks a new crew") == "NASA picks a new crew")  // not shouting: left alone
        #expect(spokenTitle("🔥 Hot take: tabs win 🎉") == "Hot take: tabs win")
    }

    @Test func highlightsStillLandOnTheShownTitle() throws {
        let title = "[Video] Rocket lands | Ars Technica"
        let script = SpeechScript.build(document: document, title: title,
                                        options: SpeechScriptOptions(language: .english, sourceName: "Ars Technica"))
        let index = try #require(script.segments.firstIndex { $0.blockID == SpeechScript.titleBlockID })
        let spoken = script.segments[index].spokenText
        let rocket = try #require(spoken.range(of: "Rocket"))
        let start = spoken.utf16.distance(from: spoken.startIndex, to: rocket.lowerBound)
        let shown = script.displayRange(segment: index, spokenRange: start..<(start + 6))
        #expect(shown.blockID == "title")
        #expect(String(title.utf16Slice(shown.range)) == "Rocket")
    }

    @Test func headlineFirstThenTheBylineWithABreathAfter() throws {
        var options = SpeechScriptOptions(language: .english, sourceName: "The Margin", announceSource: true)
        let script = SpeechScript.build(document: document, title: "Why pages feel quiet", options: options)
        #expect(script.segments.map(\.blockID).prefix(3) == ["title", "announcement-source", "b0"])
        #expect(script.segments[0].pauseAfter == 0.3)
        #expect(script.segments[1].spokenText == "The Margin." && script.segments[1].pauseAfter == 0.6)  // newsreaders stay under 0.7 s
        #expect(script.segments[1].isAnnouncement)  // nothing on the page is highlighted for it
        options.authorName = "By Mara Ellison"
        #expect(SpeechScript.build(document: document, title: "Why pages feel quiet", options: options)
            .segments[1].spokenText == "The Margin, by Mara Ellison.")
        options.authorName = "editor@margin.example"  // not a name: left out
        #expect(SpeechScript.build(document: document, title: "Why pages feel quiet", options: options)
            .segments[1].spokenText == "The Margin.")
        // Off, or without a title (bulletins introduce stories themselves): no source line.
        #expect(SpeechScript.build(document: document, title: "Why pages feel quiet",
                                   options: SpeechScriptOptions(language: .english, sourceName: "The Margin"))
            .segments.first?.blockID == "title")
        #expect(SpeechScript.build(document: document, title: "Why pages feel quiet",
                                   options: SpeechScriptOptions(includeTitle: false, language: .english, sourceName: "The Margin",
                                                                announceSource: true))
            .segments.first?.blockID == "b0")
    }
}

@Suite("Resuming and sections")
@MainActor
struct ResumeAndSectionTests {
    let item = ListenItem(id: "a1", title: "Story", feedTitle: "Feed")

    private func words(of controller: ReadAlongController, in document: ArticleDocument) -> () -> String? {
        { [controller] in
            guard let block = controller.state.blockID, let range = controller.state.wordRange,
                  let text = document.block(id: block)?.text
            else { return nil }
            return String(text.utf16Slice(range))
        }
    }

    @Test func longPausesRewindToTheSentenceOrParagraph() {
        let document = ArticleParser.parse(html: "<p>First sentence here. Second one now.</p><p>Next paragraph.</p>", title: nil)
        let script = SpeechScript.build(document: document, title: nil, options: SpeechScriptOptions(includeTitle: false))
        func run(pause seconds: TimeInterval) -> String? {
            let engine = SimulatedSpeechEngine()
            let scheduler = ManualScheduler()
            let controller = ReadAlongController(engine: engine, scheduler: scheduler) { _ in nil }
            let word = words(of: controller, in: document)
            controller.play(script: script, item: item)
            for _ in 0..<5 { engine.step() }  // … "Second" "one"
            #expect(word() == "one")
            controller.pause()
            scheduler.advance(by: seconds)
            controller.resume()
            engine.step()
            return word()
        }
        #expect(run(pause: 5) == "now.")  // a short pause just continues
        #expect(run(pause: 45) == "Second")  // back to the start of the sentence
        #expect(run(pause: 900) == "First")  // back to the start of the paragraph
    }

    @Test func sectionsSkipByHeading() {
        let document = ArticleParser.parse(
            html: "<h2>Intro</h2><p>Alpha beta.</p><h2>Middle</h2><p>Gamma delta.</p><p>Epsilon.</p><h2>End</h2><p>Omega.</p>",
            title: nil)
        let script = SpeechScript.build(document: document, title: nil, options: SpeechScriptOptions(includeTitle: false))
        let engine = SimulatedSpeechEngine()
        let controller = ReadAlongController(engine: engine, scheduler: ManualScheduler()) { _ in nil }
        let word = words(of: controller, in: document)
        controller.play(script: script, item: item)
        engine.step()
        #expect(controller.skipSection(by: 1))
        engine.step()
        #expect(word() == "Middle")
        engine.step(); engine.step(); engine.step()  // "Gamma" "delta." "Epsilon."
        #expect(word() == "Epsilon.")
        #expect(controller.skipSection(by: -1))  // back to the start of this section
        engine.step()
        #expect(word() == "Middle")
        #expect(controller.skipSection(by: -1))  // and on to the previous one
        engine.step()
        #expect(word() == "Intro")
        #expect(controller.skipSection(by: 1) && controller.skipSection(by: 1))  // Middle, then End
        engine.step()
        #expect(word() == "End")
        #expect(controller.skipSection(by: 1) == false)  // no heading after "End"
    }
}
