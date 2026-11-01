import Foundation
import Testing
import FolioCore
import FolioReader
@testable import FolioAudio

/// Builds Kokoro-like output: BOS, `frames` per phoneme scalar, EOS; 25 ms frames.
private func kokoro(_ phonemes: String, frames: Int32 = 2) -> (durations: [Int32], tokens: Int, seconds: Double) {
    let count = phonemes.unicodeScalars.count
    let durations = [1] + [Int32](repeating: frames, count: count) + [1]
    return (durations, count + 2, Double(durations.reduce(0, +)) * 0.025)
}

@Suite("Neural word timing")
struct WordTimingTests {
    @Test func phonemeWordsMapToSpokenWords() throws {
        let phonemes = "həlˈO wˈɜɹld, əɡˈɛn."
        let output = kokoro(phonemes)
        let words = try #require(KokoroAlignment.wordTimings(
            spokenText: "Hello world, again.", normalizedText: "Hello world, again.", phonemes: phonemes,
            durations: output.durations, tokenCount: output.tokens, audioDuration: output.seconds))
        #expect(words.map(\.range) == [0..<5, 6..<11, 13..<18])
        // "həlˈO" is phonemes 0–4 → tokens 1–5 → frames 1..<11.
        #expect(abs(words[0].start - 0.025) < 1e-9 && abs(words[0].end - 0.275) < 1e-9)
        // "wˈɜɹld," starts at phoneme 6 → frame 1 + 2 × 6.
        #expect(abs(words[1].start - 0.325) < 1e-9)
        #expect(words.allSatisfy { $0.start < $0.end })
        #expect(zip(words, words.dropFirst()).allSatisfy { $0.end <= $1.start })
    }

    @Test func rewrittenWordTakesTheSpanOfItsReading() throws {
        let phonemes = "ɪn twˈɛnti twˈɛnti sˈɪks wi"
        let output = kokoro(phonemes)
        let words = try #require(KokoroAlignment.wordTimings(
            spokenText: "In 2026 we", normalizedText: "In twenty twenty six we", phonemes: phonemes,
            durations: output.durations, tokenCount: output.tokens, audioDuration: output.seconds))
        #expect(words.map(\.range) == [0..<2, 3..<7, 8..<10])
        let year = words[1]
        #expect(abs(year.start - (1 + 2 * 3) * 0.025) < 1e-9)  // "twˈɛnti" starts at phoneme 3
        #expect(year.end > year.start + 0.4)  // spans all three spoken words
    }

    @Test func punctuationRunsJoinThePreviousWord() throws {
        let phonemes = "hˈI — ðˈɛɹ"
        let output = kokoro(phonemes)
        let words = try #require(KokoroAlignment.wordTimings(
            spokenText: "Hi — there", normalizedText: nil, phonemes: phonemes,
            durations: output.durations, tokenCount: output.tokens, audioDuration: output.seconds))
        #expect(words.map(\.range) == [0..<2, 5..<10])
        #expect(abs(words[0].end - words[1].start + 0.05) < 1e-9)  // only the space token between
    }

    @Test func uncertainOutputGivesNoTimings() {
        let phonemes = "həlˈO wˈɜɹld"
        let output = kokoro(phonemes)
        // A scalar dropped as out-of-vocabulary: tokens no longer line up.
        #expect(KokoroAlignment.wordTimings(spokenText: "Hello world", normalizedText: nil, phonemes: phonemes,
                                            durations: output.durations, tokenCount: output.tokens - 1,
                                            audioDuration: output.seconds) == nil)
        // Kokoro heard three words where the text has two.
        #expect(KokoroAlignment.wordTimings(spokenText: "Hello world", normalizedText: "Hello big world", phonemes: phonemes,
                                            durations: output.durations, tokenCount: output.tokens,
                                            audioDuration: output.seconds) == nil)
        // Nothing in common at all.
        #expect(KokoroAlignment.wordTimings(spokenText: "Ahoj světe", normalizedText: "Hello world", phonemes: phonemes,
                                            durations: output.durations, tokenCount: output.tokens,
                                            audioDuration: output.seconds) == nil)
    }

    @Test func alignerKeepsOnlyCertainWords() {
        let spoken = TextWords.words(in: "Dr. Novák met Ms. Lee")
        let heard: [(key: String, start: Double, end: Double)] = [
            ("doctor", 0, 1), ("novak", 1, 2), ("met", 2, 3), ("miss", 3, 4), ("lee", 4, 5),
        ]
        let timed = WordAligner.align(spoken: spoken, heard: heard)
        #expect(timed.map(\.range) == [0..<2, 4..<9, 10..<13, 14..<16, 18..<21])  // "Dr." without its dot
        #expect(timed[1].start == 1)  // diacritics folded: Novák = novak
        let unrelated = WordAligner.align(spoken: TextWords.words(in: "one two three"),
                                          heard: [("x", 0, 1), ("one", 1, 2), ("y", 2, 3), ("z", 3, 4)])
        // "two three" vs "y z": two words on both sides pair up in order.
        #expect(unrelated.map(\.start) == [1, 2, 3])
    }

    @Test func chunksStayShortAndCoverTheText() {
        let sentence = "This sentence is about forty-five characters. "
        let text = String(repeating: sentence, count: 12)
        let chunks = SpeechChunker.chunks(of: text, language: .english, maxLength: 120)
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.count <= 120 })
        let covered = chunks.reduce(0) { $0 + $1.count }
        #expect(covered >= text.trimmingCharacters(in: .whitespaces).utf16.count - chunks.count)
        #expect(SpeechChunker.chunks(of: "Short.", language: .english) == [0..<6])
        let long = String(repeating: "word ", count: 100)
        #expect(SpeechChunker.chunks(of: long, language: .english, maxLength: 60).allSatisfy { $0.count <= 60 })
    }
}

/// Words every 0.5 s; `timed: false` simulates a voice without word timing.
private struct FakeSynthesizer: SpeechSynthesizing {
    var timed = true
    var failsFor: String?

    func synthesize(text: String, language: LanguageCode?, voiceID: String) async throws -> SynthesizedSpeech {
        if let failsFor, text.contains(failsFor) { throw TimedSpeechError.noVoice(language: "xx") }
        let words = TextWords.words(in: text).enumerated().map { index, word in
            TimedWord(range: word.range, start: Double(index) * 0.5, end: Double(index) * 0.5 + 0.4)
        }
        return SynthesizedSpeech(audio: URL(fileURLWithPath: "/fake/\(voiceID)/\(text.hashValue).m4a"),
                                 duration: Double(words.count) * 0.5, words: timed ? words : nil)
    }
}

@MainActor
private final class FakeOutput: SpeechAudioOutput {
    var playing: URL?
    var time = 0.0
    /// Tests set the clip length before letting it finish.
    var duration = Double.infinity
    var rate = 1.0
    var isPaused = false
    var starts: [Double] = []
    var durations: [URL: Double] = [:]

    func play(_ audio: URL, from seconds: Double, rate: Double) throws {
        playing = audio
        time = seconds
        self.rate = rate
        isPaused = false
        starts.append(seconds)
    }
    func pause() { isPaused = true }
    func resume() { isPaused = false }
    func stop() { playing = nil }
    func setRate(_ rate: Double) { self.rate = rate }
    var currentTime: Double? { playing == nil ? nil : time }
    var isFinished: Bool { playing != nil && time >= duration }
}

@MainActor
@Suite("Timed narration")
struct TimedSpeechEngineTests {
    let document = ArticleParser.parse(html: "<p>One two three.</p><p>Four five.</p>", title: nil)
    var script: SpeechScript { SpeechScript.build(document: document, title: nil, options: SpeechScriptOptions(includeTitle: false)) }

    final class Clock: @unchecked Sendable { var now = 0.0 }

    private func settle() async { for _ in 0..<30 { await Task.yield() } }

    private func makeEngine(timed: Bool = true, failsFor: String? = nil)
        -> (TimedSpeechEngine, FakeOutput, Clock, Recorder)
    {
        let output = FakeOutput()
        let clock = Clock()
        let engine = TimedSpeechEngine(synthesizer: FakeSynthesizer(timed: timed, failsFor: failsFor), output: output,
                                       runsOnTimer: false, clock: { clock.now })
        engine.voiceForSegment = { _ in "neural.kokoro.af_heart" }
        let recorder = Recorder()
        recorder.observation = engine.addObserver { recorder.events.append($0) }
        return (engine, output, clock, recorder)
    }

    final class Recorder {
        var events: [SpeechEvent] = []
        var observation: SpeechObservation?
        var ranges: [SpokenRange] { events.compactMap { if case .range(let r) = $0 { r } else { nil } } }
    }

    @Test func reportsWordsAsTheClockPassesThem() async {
        let (engine, output, clock, recorder) = makeEngine()
        engine.speak(script, from: nil)
        await settle()
        #expect(output.playing != nil)
        output.duration = 1.5  // "One two three." = 3 words
        engine.tick()
        #expect(recorder.ranges.map(\.spokenRange) == [0..<3])  // first word at 0 s
        output.time = 0.6
        engine.tick()
        #expect(recorder.ranges.map(\.spokenRange) == [0..<3, 4..<7])
        #expect(recorder.ranges.allSatisfy { $0.precision == .engineReported })
        output.time = 1.5
        engine.tick()  // finished → pause after the paragraph
        #expect(recorder.events.contains(.segmentFinished(0)))
        clock.now = 1
        engine.tick()
        await settle()
        output.duration = 1.0
        output.time = 0
        engine.tick()
        #expect(recorder.events.contains(.segmentStarted(1)))
        output.time = 1.0
        engine.tick()
        clock.now = 2
        engine.tick()
        #expect(recorder.events.last == .scriptFinished)
        #expect(engine.state == .idle)
    }

    @Test func voiceWithoutTimingTintsTheParagraphOnly() async {
        let (engine, _, _, recorder) = makeEngine(timed: false)
        engine.speak(script, from: nil)
        await settle()
        engine.tick()
        #expect(recorder.ranges.count == 1)
        #expect(recorder.ranges[0].precision == .estimated)
        #expect(recorder.ranges[0].spokenRange == 0..<14)
    }

    @Test func startsFromTheTappedWord() async {
        let (engine, output, _, _) = makeEngine()
        engine.speak(script, from: SpeechPosition(blockID: "b0", offset: 8))  // "three"
        await settle()
        #expect(output.starts == [1.0])
    }

    @Test func pauseAndSeekKeepTheEnginePaused() async {
        let (engine, output, _, _) = makeEngine()
        engine.speak(script, from: nil)
        await settle()
        engine.pause()
        #expect(engine.state == .paused && output.isPaused)
        engine.seek(to: SpeechPosition(blockID: "b1", offset: 0))
        await settle()
        #expect(engine.state == .paused)
        #expect(output.playing == nil)  // nothing starts while paused
        engine.resume()
        #expect(output.playing != nil && engine.state == .speaking)
    }

    @Test func failureIsReportedNotHidden() async {
        let (engine, _, _, recorder) = makeEngine(failsFor: "One")
        engine.speak(script, from: nil)
        await settle()
        #expect(recorder.events.contains { if case .failed = $0 { true } else { false } })
        #expect(engine.state == .idle)
    }

    @Test func rateChangesReachTheOutputWithoutRestarting() async {
        let (engine, output, _, _) = makeEngine()
        engine.speak(script, from: nil)
        await settle()
        engine.setRate(SpeechRate(1.5))
        #expect(output.rate == 1.5)
        #expect(output.starts.count == 1)
    }
}

@MainActor
@Suite("Hybrid narration")
struct HybridSpeechEngineTests {
    let document = ArticleParser.parse(html: "<p>One two.</p><p>Tři čtyři.</p><p>Five six.</p>", title: nil)

    @Test func runsSwitchEnginesAndKeepSegmentNumbers() {
        let apple = SimulatedSpeechEngine()
        let neural = SimulatedSpeechEngine()
        let script = SpeechScript.build(document: document, title: nil, options: SpeechScriptOptions(includeTitle: false))
        let hybrid = HybridSpeechEngine(primary: apple, secondary: neural) { $0.blockID == "b1" }
        var events: [SpeechEvent] = []
        let observation = hybrid.addObserver { events.append($0) }
        defer { observation.cancel() }

        #expect(HybridSpeechEngine.runs(of: script, usesSecondary: hybrid.usesSecondary).map(\.segments) == [0..<1, 1..<2, 2..<3])
        hybrid.speak(script, from: nil)
        #expect(apple.state == .speaking && neural.state == .idle)
        while apple.step() {}
        #expect(neural.state == .speaking)  // second run started on the other engine
        while neural.step() {}
        while apple.step() {}
        let ranges = events.compactMap { if case .range(let r) = $0 { r } else { nil } }
        #expect(ranges.map(\.segment) == [0, 0, 1, 1, 2, 2])
        #expect(ranges.map(\.blockID) == ["b0", "b0", "b1", "b1", "b2", "b2"])
        #expect(events.filter { $0 == .scriptFinished }.count == 1)
        #expect(events.last == .scriptFinished)
        #expect(hybrid.state == .idle)
    }

    @Test func seekingIntoAnotherRunSwitchesEngines() {
        let apple = SimulatedSpeechEngine()
        let neural = SimulatedSpeechEngine()
        let script = SpeechScript.build(document: document, title: nil, options: SpeechScriptOptions(includeTitle: false))
        let hybrid = HybridSpeechEngine(primary: apple, secondary: neural) { $0.blockID == "b1" }
        hybrid.speak(script, from: nil)
        hybrid.pause()
        hybrid.seek(to: SpeechPosition(blockID: "b1", offset: 4))
        #expect(apple.state == .idle)
        #expect(neural.state == .paused)
        hybrid.resume()
        #expect(neural.state == .speaking)
    }
}

@Suite("Narration audio cache")
struct SpeechAudioCacheTests {
    @Test func storesLooksUpAndPrunes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("folio-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = SpeechAudioCache(directory: directory, maxBytes: 2_500)
        let key = SpeechAudioCache.key(engine: "kokoro-1", voiceID: "af_heart", text: "Hello")
        #expect(key == SpeechAudioCache.key(engine: "kokoro-1", voiceID: "af_heart", text: "Hello"))
        #expect(key != SpeechAudioCache.key(engine: "kokoro-1", voiceID: "af_bella", text: "Hello"))

        func audioFile(_ bytes: Int) throws -> URL {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
            try Data(repeating: 7, count: bytes).write(to: url)
            return url
        }
        let words = [TimedWord(range: 0..<5, start: 0, end: 0.4)]
        try await cache.store(key: key, text: "Hello", audio: try audioFile(1_000), duration: 0.5, words: words)
        let hit = await cache.lookup(key: key, text: "Hello")
        #expect(hit?.words == words && hit?.duration == 0.5)
        #expect(await cache.lookup(key: key, text: "Hello!") == nil)  // same key, different text: never the wrong audio

        try await Task.sleep(for: .milliseconds(20))
        let second = SpeechAudioCache.key(engine: "kokoro-1", voiceID: "af_heart", text: "World")
        try await cache.store(key: second, text: "World", audio: try audioFile(1_000), duration: 0.5, words: nil)
        try await Task.sleep(for: .milliseconds(20))
        let third = SpeechAudioCache.key(engine: "kokoro-1", voiceID: "af_heart", text: "Again")
        try await cache.store(key: third, text: "Again", audio: try audioFile(1_000), duration: 0.5, words: nil)
        #expect(await cache.totalBytes() <= 2_500)
        #expect(await cache.lookup(key: key, text: "Hello") == nil)  // oldest went first
        #expect(await cache.lookup(key: third, text: "Again") != nil)
    }

    @Test func catalogIdsRoundTrip() {
        let voices = NeuralVoiceCatalog.speechVoices(installed: [.kokoro])
        #expect(voices.allSatisfy { NeuralVoiceCatalog.isNeural($0.id) && $0.quality == .neural })
        #expect(Set(voices.map(\.id)).count == voices.count)
        for language in ["en", "es", "de", "cs", "sk"] {
            #expect(voices.contains { $0.languageCode.base == language }, "no neural voice for \(language)")
        }
        #expect(voices.first { $0.id == "neural.kokoro.af_heart" }?.isInstalled == true)
        #expect(voices.first { $0.id == "neural.supertonic.F1.cs" }?.isInstalled == false)
        #expect(NeuralVoiceCatalog.voice("neural.supertonic.M1.sk")?.modelVoice == "M1")
    }
}

@MainActor
@Suite("Hybrid voice changes")
struct HybridRerouteTests {
    final class Routing { var neural: Set<String> = [] }

    @Test func choosingANeuralVoiceMovesNarrationToItFromTheCurrentWord() {
        let apple = SimulatedSpeechEngine()
        let neural = SimulatedSpeechEngine()
        let routing = Routing()
        let document = ArticleParser.parse(html: "<p>One two three four.</p><p>Five six.</p>", title: nil)
        let script = SpeechScript.build(document: document, title: nil, options: SpeechScriptOptions(includeTitle: false))
        let hybrid = HybridSpeechEngine(primary: apple, secondary: neural) { routing.neural.contains($0.blockID) }
        var ranges: [SpokenRange] = []
        let observation = hybrid.addObserver { if case .range(let r) = $0 { ranges.append(r) } }
        defer { observation.cancel() }

        hybrid.speak(script, from: nil)
        apple.step()
        apple.step()  // "One two" spoken by Apple
        hybrid.pause()
        routing.neural = ["b0", "b1"]
        hybrid.selectVoice(nil)
        #expect(apple.state == .idle)
        #expect(neural.state == .paused)  // kept paused
        hybrid.resume()
        neural.step()
        #expect(ranges.last?.spokenRange == 4..<7)  // continues at "two", the last spoken word
        // A change that moves nothing leaves the engine alone.
        hybrid.selectVoice(nil)
        #expect(neural.state == .speaking)
    }
}
