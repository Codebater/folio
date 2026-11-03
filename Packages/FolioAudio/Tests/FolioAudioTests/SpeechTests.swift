import Foundation
import Testing
import FolioCore
import FolioReader
@testable import FolioAudio

@Suite("Offset map")
struct OffsetMapTests {
    @Test func identityMapsOneToOne() {
        let map = OffsetMap.identity(length: 10)
        #expect(map.displayRange(forSpoken: 2..<5) == 2..<5)
        #expect(map.spokenOffset(forDisplay: 7) == 7)
    }

    @Test func replacementsMapToTheWholeOriginalToken() {
        // display: "Use e.g. this"  spoken: "Use for example this"
        var map = OffsetMap()
        map.appendIdentity(length: 4)                          // "Use "
        map.appendReplacement(displayLength: 4, spokenLength: 11)  // "e.g." -> "for example"
        map.appendIdentity(length: 5)                          // " this"
        #expect(map.spokenLength == 20 && map.displayLength == 13)
        #expect(map.displayRange(forSpoken: 0..<3) == 0..<3)    // "Use"
        #expect(map.displayRange(forSpoken: 4..<7) == 4..<8)    // "for" -> "e.g."
        #expect(map.displayRange(forSpoken: 8..<15) == 4..<8)   // "example" -> "e.g."
        #expect(map.displayRange(forSpoken: 16..<20) == 9..<13) // "this"
        #expect(map.spokenOffset(forDisplay: 6) == 4)           // inside "e.g." -> start of "for example"
        #expect(map.spokenOffset(forDisplay: 9) == 16)
    }

    @Test func clampsOutOfRangeInput() {
        let map = OffsetMap.identity(length: 5)
        #expect(map.displayRange(forSpoken: 10..<12) == 4..<5)
        #expect(OffsetMap().displayRange(forSpoken: 0..<1) == 0..<0)
    }
}

@Suite("Pronunciation")
struct PronunciationTests {
    let rules = PronunciationRules()

    func spoken(_ text: String, _ language: LanguageCode) -> String {
        PronunciationRules.apply(rules.edits(for: text, language: language), to: text).spoken
    }

    @Test func expandsPerLanguageAbbreviations() {
        #expect(spoken("Owls, e.g. the barn owl, hunt at night.", .english) == "Owls, for example the barn owl, hunt at night.")
        #expect(spoken("E.g. this one.", .english) == "For example this one.")
        #expect(spoken("Feste Zeiten, z. B. dunkle Vorhänge.", .german) == "Feste Zeiten, zum Beispiel dunkle Vorhänge.")
        #expect(spoken("Frutas, p. ej. naranjas.", .spanish) == "Frutas, por ejemplo naranjas.")
        #expect(spoken("Druhý zdroj, napr. polícia, atď.", .slovak) == "Druhý zdroj, napríklad polícia, a tak ďalej.")
    }

    @Test func keepsSentenceStopAfterExpansion() {
        #expect(spoken("Apples, pears etc. Then more.", .english) == "Apples, pears et cetera. Then more.")
    }

    @Test func doesNotExpandInsideWords() {
        #expect(spoken("The ca. value", .english) == "The ca. value")  // German-only abbreviation
        #expect(spoken("Kopca je tu.", .slovak) == "Kopca je tu.")      // "cca" inside a word
    }

    @Test func readsDottedAcronymsAsWords() {
        #expect(spoken("The U.S. and E.U. agreed.", .english) == "The US and EU agreed.")
        #expect(spoken("Made in the U.S.A.", .english) == "Made in the USA.")
        #expect(spoken("Moved to the U.S. Then home.", .english) == "Moved to the US. Then home.")
    }

    @Test func readsURLsAsHostNames() {
        #expect(spoken("See https://www.example.com/a/b?c=1, then go.", .english) == "See example.com, then go.")
        #expect(spoken("Visit www.margin.example.", .english) == "Visit margin.example.")
    }

    @Test func appliesUserDictionary() {
        let custom = PronunciationRules(userEntries: [PronunciationEntry(written: "SQL", spoken: "sequel"),
                                                      PronunciationEntry(written: "nginx", spoken: "engine x", caseSensitive: false)])
        let text = "Run SQL behind NGINX."
        #expect(PronunciationRules.apply(custom.edits(for: text, language: .english), to: text).spoken == "Run sequel behind engine x.")
    }
}

@Suite("Sentences")
struct SentenceTests {
    let segmenter = RuleBasedSentenceSegmenter()

    func split(_ text: String, _ language: LanguageCode = .english) -> [String] {
        segmenter.sentences(in: text, language: language).map { String(text.utf16Slice($0)) }
    }

    @Test func splitsOnTerminalPunctuation() {
        #expect(split("One. Two! Three? Four") == ["One.", "Two!", "Three?", "Four"])
    }

    @Test func respectsAbbreviationsDecimalsAndInitials() {
        #expect(split("Dr. Smith paid 3.50 dollars. J. R. R. Tolkien wrote it. Done.") ==
            ["Dr. Smith paid 3.50 dollars.", "J. R. R. Tolkien wrote it.", "Done."])
        #expect(split("Visit example.com today. Then rest.") == ["Visit example.com today.", "Then rest."])
    }

    @Test func handlesQuotesEllipsesAndBreaks() {
        #expect(split("\u{201C}Stop!\u{201D} she said. Wait... What?!") == ["\u{201C}Stop!\u{201D} she said.", "Wait...", "What?!"])
        #expect(split("Line one\nLine two") == ["Line one", "Line two"])
    }

    @Test func handlesSpanishAndSlovak() {
        #expect(split("¿El secreto? Según ella, «la gente viene a conversar».", .spanish) ==
            ["¿El secreto?", "Según ella, «la gente viene a conversar»."])
        #expect(split("Overiť, napr. u polície. Potom zverejniť.", .slovak) == ["Overiť, napr. u polície.", "Potom zverejniť."])
    }
}

@Suite("Speech script")
struct SpeechScriptTests {
    let document = ArticleParser.parse(html: """
        <h2>Owls</h2><p>Owls hunt at night, e.g. in winter.</p>
        <img src="https://x/owl.jpg"><p>Emoji \u{1F989} owl. Second sentence here.</p>
        <pre>code is skipped</pre><p>Last one.</p>
        """, title: "Quiet wings")

    @Test func buildsParagraphSegmentsWithTitleAndSkipsCode() {
        let script = SpeechScript.build(document: document, title: "Quiet wings", options: SpeechScriptOptions(language: .english))
        #expect(script.segments.map(\.blockID) == ["title", "b0", "b1", "b3", "announcement-cue-b4-code", "b5"])
        #expect(script.segments[4].spokenText == "Code skipped." && script.segments[4].isAnnouncement)
        #expect(script.segments[0].isHeading && script.segments[1].isHeading)
        #expect(script.segments[2].spokenText == "Owls hunt at night, for example in winter.")
        #expect(script.segments[1].pauseAfter > script.segments[2].pauseAfter)
    }

    @Test func mapsSpokenWordsBackToDisplayText() throws {
        let script = SpeechScript.build(document: document, title: nil, options: SpeechScriptOptions(language: .english))
        let segment = try #require(script.segments.first { $0.blockID == "b1" })
        let text = try #require(document.block(id: "b1")).text
        func highlight(_ word: String) -> String {
            let spoken = segment.spokenText
            let range = spoken.range(of: word)!
            let lo = spoken.utf16Offset(of: range.lowerBound)
            let hi = spoken.utf16Offset(of: range.upperBound)
            return String(text.utf16Slice(script.displayRange(segment: segment.index, spokenRange: lo..<hi).range))
        }
        #expect(highlight("night,") == "night,")
        #expect(highlight("example") == "e.g.")   // the expansion highlights the original token
        #expect(highlight("winter.") == "winter.")
    }

    @Test func surrogatePairsKeepOffsetsAligned() throws {
        let script = SpeechScript.build(document: document, title: nil, options: SpeechScriptOptions(language: .english))
        let segment = try #require(script.segments.first { $0.blockID == "b3" })
        let spoken = segment.spokenText
        let owl = spoken.range(of: "owl.")!
        let lo = spoken.utf16Offset(of: owl.lowerBound)
        let display = script.displayRange(segment: segment.index, spokenRange: lo..<(lo + 4))
        #expect(document.block(id: "b3")!.text.utf16Slice(display.range) == "owl.")
        #expect(display.range.lowerBound == 9)  // "Emoji " (6) + 🦉 (2) + " " (1)
    }

    @Test func sentenceModeSplitsBlocksAndKeepsBlockPauseAtTheEnd() {
        let options = SpeechScriptOptions(granularity: .sentence, includeTitle: false, language: .english)
        let doc = ArticleParser.parse(html: "<p>The first sentence is long enough to stand. The second one is long as well.</p>", title: nil)
        let script = SpeechScript.build(document: doc, title: nil, options: options)
        #expect(script.segments.map(\.spokenText) == ["The first sentence is long enough to stand.", "The second one is long as well."])
        #expect(script.segments[1].displayRange.lowerBound > 0)
        #expect(script.segments[0].pauseAfter == options.sentencePause && script.segments[1].pauseAfter == options.paragraphPause)
        // A very short sentence rides with its neighbour, and emoji aren't read.
        let b3 = SpeechScript.build(document: document, title: nil, options: options).segments.filter { $0.blockID == "b3" }
        #expect(b3.map(\.spokenText) == ["Emoji owl. Second sentence here."])
    }

    @Test func naturalVoicesPackNeighbouringSentencesThatFitTogether() {
        // Groups stay as they are without a limit; with one, neighbours share a
        // segment while together they fit, and a sentence that doesn't starts the next.
        let sentences = [0..<30, 31..<55, 56..<120]
        #expect(SpeechScript.sentenceGroups(sentences, packUpTo: nil) == sentences)
        #expect(SpeechScript.sentenceGroups(sentences, packUpTo: 64) == [0..<55, 56..<120])
        var options = SpeechScriptOptions(granularity: .sentence, includeTitle: false, language: .english)
        options.packSentences = 64
        let doc = ArticleParser.parse(html: "<p>The ice drifted north all winter. The ship drifted with it. "
            + "Then the long measurement campaign began and lasted well over a year.</p>", title: nil)
        let script = SpeechScript.build(document: doc, title: nil, options: options)
        #expect(script.segments.map(\.spokenText) == ["The ice drifted north all winter. The ship drifted with it.",
                                                       "Then the long measurement campaign began and lasted well over a year."])
        #expect(script.segments[0].pauseAfter == options.sentencePause)
        #expect(script.segments[1].pauseAfter == options.paragraphPause)
    }

    @Test func locatesTapPositionsAtWordStarts() throws {
        let script = SpeechScript.build(document: document, title: "Quiet wings", options: SpeechScriptOptions(language: .english))
        let text = document.block(id: "b1")!.text
        let tap = text.utf16Offset(of: text.range(of: "ght")!.lowerBound)  // middle of "night"
        let located = try #require(script.locate(SpeechPosition(blockID: "b1", offset: tap)))
        #expect(script.segments[located.segment].blockID == "b1")
        #expect(script.segments[located.segment].spokenText.utf16Slice(located.spokenOffset..<(located.spokenOffset + 5)) == "night")
        // A tap on the image starts at the next spoken paragraph.
        let fromImage = try #require(script.locate(SpeechPosition(blockID: "b2")))
        #expect(script.segments[fromImage.segment].blockID == "b3")
        // A tap on the last code block has nothing after it except "Last one."
        #expect(script.segments[script.locate(SpeechPosition(blockID: "b4"))!.segment].blockID == "b5")
    }

    @Test func progressAndDurationAreMonotonic() {
        let script = SpeechScript.build(document: document, title: "Quiet wings")
        var last = -1.0
        for segment in script.segments {
            let p = script.progress(segment: segment.index, spokenOffset: 0)
            #expect(p > last)
            last = p
        }
        #expect(script.progress(segment: script.segments.count - 1, spokenOffset: 10_000) == 1)
        #expect(script.estimatedDuration(rate: 2) < script.estimatedDuration(rate: 1))
    }
}

@MainActor
final class ManualScheduler: ReadAlongScheduler {
    final class Work: ScheduledWork {
        var cancelled = false
        func cancel() { cancelled = true }
    }

    var now = Date(timeIntervalSince1970: 0)
    private var jobs: [(at: Date, work: Work, action: @MainActor () -> Void)] = []

    func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) -> any ScheduledWork {
        let work = Work()
        jobs.append((now.addingTimeInterval(seconds), work, action))
        return work
    }

    func advance(by seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
        let due = jobs.filter { $0.at <= now && !$0.work.cancelled }
        jobs.removeAll { $0.at <= now }
        for job in due { job.action() }
    }
}

@Suite("Read-along controller")
@MainActor
struct ReadAlongControllerTests {
    let document = ArticleParser.parse(html: "<p>One two three.</p><p>Four five.</p><p>Six.</p>", title: nil)
    var script: SpeechScript { SpeechScript.build(document: document, title: nil, options: SpeechScriptOptions(includeTitle: false)) }
    let item = ListenItem(id: "a1", title: "Numbers", feedTitle: "Feed")

    func makeController(_ engine: SimulatedSpeechEngine, scheduler: ManualScheduler = ManualScheduler(),
                        scripts: [ArticleID: SpeechScript] = [:]) -> ReadAlongController {
        ReadAlongController(engine: engine, scheduler: scheduler) { scripts[$0.id] }
    }

    @Test func highlightsEachWordInOrder() {
        let engine = SimulatedSpeechEngine()
        let controller = makeController(engine)
        var words: [String] = []
        controller.onChange = { state in
            if let block = state.blockID, let range = state.wordRange, let text = self.document.block(id: block)?.text {
                let word = String(text.utf16Slice(range))
                if words.last != word { words.append(word) }
            }
        }
        controller.play(script: script, item: item)
        #expect(controller.state.status == .playing)
        while engine.step() {}
        #expect(words == ["One", "two", "three.", "Four", "five.", "Six."])
        #expect(controller.state.status == .finished)
        #expect(controller.state.progress == 1)
        #expect(controller.state.precision == .engineReported)
    }

    @Test func tapToReadJumpsToTheTappedWord() {
        let engine = SimulatedSpeechEngine()
        let controller = makeController(engine)
        controller.play(script: script, item: item)
        engine.step()
        controller.start(at: SpeechPosition(blockID: "b1", offset: 5))  // inside "five."
        engine.step()
        #expect(controller.state.blockID == "b1")
        #expect(controller.state.wordRange == 5..<10)
    }

    @Test func skipsByParagraphAndRestartsCurrentWhenDeepIn() {
        let engine = SimulatedSpeechEngine()
        let controller = makeController(engine)
        controller.play(script: script, item: item)
        engine.step()
        controller.skip(by: 1)
        engine.step()
        #expect(controller.state.blockID == "b1" && controller.state.wordRange == 0..<4)
        controller.skip(by: -1)
        engine.step()
        #expect(controller.state.blockID == "b0")
        controller.skip(by: 10)
        engine.step()
        #expect(controller.state.blockID == "b2")
    }

    @Test func pauseResumeAndRate() {
        let engine = SimulatedSpeechEngine()
        let controller = makeController(engine)
        controller.play(script: script, item: item)
        controller.togglePlayPause()
        #expect(controller.state.status == .paused)
        #expect(!engine.step())  // paused engines don't advance
        controller.togglePlayPause()
        #expect(controller.state.status == .playing)
        controller.setRate(SpeechRate(1.5))
        #expect(engine.rate == SpeechRate(1.5) && controller.state.rate == SpeechRate(1.5))
        #expect(SpeechRate(9).multiplier == 3)
    }

    @Test func continuousPlaybackAdvancesThroughTheQueue() async {
        let engine = SimulatedSpeechEngine()
        let next = ListenItem(id: "a2", title: "Next", feedTitle: "Feed")
        let nextScript = SpeechScript.build(document: ArticleParser.parse(html: "<p>Hello again.</p>"), title: nil,
                                            options: SpeechScriptOptions(includeTitle: false))
        let controller = makeController(engine, scripts: ["a2": nextScript])
        controller.play(script: script, item: item)
        controller.enqueue(next)
        controller.enqueue(next)  // no duplicates
        #expect(controller.state.upNext.count == 1)
        while engine.step() {}
        // The next article loads asynchronously.
        for _ in 0..<20 where controller.state.item?.id != "a2" { await Task.yield() }
        #expect(controller.state.item?.id == "a2")
        #expect(controller.state.upNext.isEmpty)
        engine.step()
        #expect(controller.state.wordRange == 0..<5)
    }

    @Test func sleepTimerPausesAfterMinutes() {
        let engine = SimulatedSpeechEngine()
        let scheduler = ManualScheduler()
        let controller = makeController(engine, scheduler: scheduler)
        controller.play(script: script, item: item)
        controller.setSleepTimer(.minutes(15))
        #expect(controller.state.sleepTimerEndsAt == Date(timeIntervalSince1970: 900))
        scheduler.advance(by: 899)
        #expect(controller.state.status == .playing)
        scheduler.advance(by: 1)
        #expect(controller.state.status == .paused)
        #expect(controller.state.sleepTimer == nil)
    }

    @Test func sleepTimerAtEndOfArticleStopsTheQueue() {
        let engine = SimulatedSpeechEngine()
        let controller = makeController(engine)
        controller.play(script: script, item: item)
        controller.enqueue(ListenItem(id: "a2", title: "Next", feedTitle: "Feed"))
        controller.setSleepTimer(.endOfArticle)
        while engine.step() {}
        #expect(controller.state.status == .finished)
        #expect(controller.state.item?.id == "a1")
        #expect(controller.state.upNext.count == 1)
    }

    @Test func estimatedRangesNeverBecomeWordHighlights() {
        let engine = SimulatedSpeechEngine()
        let controller = makeController(engine)
        controller.play(script: script, item: item)
        // Hand-deliver an estimated range the way a neural engine without alignment would.
        let range = SpokenRange(segment: 0, blockID: "b0", displayRange: 4..<7, spokenRange: 4..<7, precision: .estimated)
        engineEmit(engine, .range(range))
        #expect(controller.state.blockID == "b0")
        #expect(controller.state.wordRange == nil)
        #expect(controller.state.precision == .estimated)
    }

    @Test func queueCanBeReordered() {
        let controller = makeController(SimulatedSpeechEngine())
        for id in ["x", "y", "z"] { controller.enqueue(ListenItem(id: ArticleID(id), title: id, feedTitle: "")) }
        controller.moveInQueue(from: [2], to: 0)
        #expect(controller.state.upNext.map(\.id.rawValue) == ["z", "x", "y"])
        controller.enqueueNext(ListenItem(id: "y", title: "y", feedTitle: ""))
        #expect(controller.state.upNext.map(\.id.rawValue) == ["y", "z", "x"])
        controller.removeFromQueue("z")
        #expect(controller.state.upNext.map(\.id.rawValue) == ["y", "x"])
    }

    @Test func emptyArticleReportsInsteadOfHanging() {
        let controller = makeController(SimulatedSpeechEngine())
        let empty = SpeechScript.build(document: ArticleParser.parse(html: "<img src='https://x/a.jpg'>"), title: nil,
                                       options: SpeechScriptOptions(includeTitle: false))
        controller.play(script: empty, item: item)
        #expect(controller.state.status == .finished)
        #expect(controller.state.lastError != nil)
    }

    /// Delivers an event through the engine's public observer path.
    private func engineEmit(_ engine: SimulatedSpeechEngine, _ event: SpeechEvent) {
        engine.hub.emit(event)
    }
}
