import Foundation
import FolioCore

/// One segment rendered to audio by a neural voice.
public struct SynthesizedSpeech: Sendable, Hashable {
    public var audio: URL
    public var duration: Double
    /// nil when the voice reports no word timing.
    public var words: [TimedWord]?

    public init(audio: URL, duration: Double, words: [TimedWord]?) {
        self.audio = audio
        self.duration = duration
        self.words = words
    }
}

/// Renders text to audio. Implementations: Kokoro and Supertonic through
/// FluidAudio on iOS (`FluidSpeechSynthesizer`), fakes in tests.
public protocol SpeechSynthesizing: Sendable {
    func synthesize(text: String, language: LanguageCode?, voiceID: String) async throws -> SynthesizedSpeech
}

/// Plays one rendered segment at a time.
@MainActor
public protocol SpeechAudioOutput: AnyObject {
    /// Replaces whatever is playing with `audio`, starting at `seconds`.
    func play(_ audio: URL, from seconds: Double, rate: Double) throws
    func pause()
    func resume()
    func stop()
    /// Changes speed without changing pitch, while playing.
    func setRate(_ rate: Double)
    /// Seconds into the current clip (media time, independent of speed); nil when nothing is loaded.
    var currentTime: Double? { get }
    /// True once the current clip has played to its end.
    var isFinished: Bool { get }
}

/// Narration from pre-rendered audio with word timings.
///
/// Each segment is rendered by a `SpeechSynthesizing` voice (two segments
/// ahead), played by a `SpeechAudioOutput`, and its words are reported as
/// the playback clock passes their start. Only timings the voice reported
/// become word ranges (`engineReported`). A voice without timings gets one
/// `estimated` range for the whole segment, which the reader shows as a
/// paragraph tint, never as a word.
@MainActor
public final class TimedSpeechEngine: SpeechEngine {
    public let engineID: String
    public private(set) var state: SpeechPlaybackState = .idle
    /// The voice for a segment. Segments without one fail with a clear message.
    public var voiceForSegment: @MainActor (SpeechSegment) -> String? = { $0.voiceID }
    /// What `availableVoices()` returns.
    public var voices: [SpeechVoice] = []
    /// Segments rendered ahead of the one playing.
    public var lookahead = 2
    /// When false, nothing advances until `tick()` is called (tests).
    public let runsOnTimer: Bool

    private enum Phase: Equatable {
        case idle
        /// Waiting for the current segment's audio; play from this spoken offset.
        case waiting(offset: Int)
        case playing
        /// Silence after a segment, until this clock time.
        case gap(until: Double)
    }

    private let synthesizer: any SpeechSynthesizing
    private let output: any SpeechAudioOutput
    private let clock: () -> Double
    private let hub = SpeechEventHub()
    private var script: SpeechScript?
    /// Bumped whenever rendering results from before become meaningless.
    private var generation = 0
    private var rendered: [Int: Result<SynthesizedSpeech, any Error>] = [:]
    private var requested: Set<Int> = []
    private var segment = 0
    private var phase: Phase = .idle
    private var current: SynthesizedSpeech?
    private var nextWord = 0
    private var lastSpokenOffset = 0
    private var gapRemainingWhilePaused: Double?
    private var selectedVoiceID: String?
    private var rate: SpeechRate = .normal
    private var timer: Task<Void, Never>?

    public init(engineID: String = "neural", synthesizer: any SpeechSynthesizing, output: any SpeechAudioOutput,
                runsOnTimer: Bool = true, clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.engineID = engineID
        self.synthesizer = synthesizer
        self.output = output
        self.runsOnTimer = runsOnTimer
        self.clock = clock
    }

    public var speechProgress: AsyncStream<SpeechEvent> { hub.progressStream }
    public var speechRanges: AsyncStream<SpokenRange> { hub.rangeStream }

    public func addObserver(_ observer: @escaping @MainActor (SpeechEvent) -> Void) -> SpeechObservation {
        hub.addObserver(observer)
    }

    public func availableVoices() async -> [SpeechVoice] { voices }

    /// Also called with nil when voice preferences changed: narration in
    /// progress re-renders from the last spoken word.
    public func selectVoice(_ voice: SpeechVoice?) {
        selectedVoiceID = voice?.id
        guard script != nil, phase != .idle else { return }
        // Re-render from the last spoken word with the new voice.
        generation += 1
        rendered = [:]
        requested = []
        output.stop()
        begin(segment: segment, at: lastSpokenOffset)
    }

    public func setRate(_ rate: SpeechRate) {
        self.rate = rate
        output.setRate(rate.multiplier)
    }

    public func speak(_ script: SpeechScript, from position: SpeechPosition?) {
        reset()
        self.script = script
        guard let start = position.flatMap(script.locate) ?? (script.isEmpty ? nil : (0, 0)) else {
            setState(.idle)
            hub.emit(.scriptFinished)
            return
        }
        setState(.speaking)
        begin(segment: start.segment, at: start.spokenOffset)
        startTimer()
    }

    public func pause() {
        guard state == .speaking else { return }
        if case .gap(let until) = phase { gapRemainingWhilePaused = max(0, until - clock()) }
        output.pause()
        setState(.paused)
    }

    public func resume() {
        guard state == .paused else { return }
        setState(.speaking)
        if let remaining = gapRemainingWhilePaused {
            phase = .gap(until: clock() + remaining)
            gapRemainingWhilePaused = nil
        } else if phase == .playing {
            output.resume()
        }
        tick()
    }

    public func stop() {
        reset()
        setState(.idle)
    }

    /// Keeps rendered audio; a paused engine stays paused at the new position.
    public func seek(to position: SpeechPosition) {
        guard let script, let start = script.locate(position) else { return }
        output.stop()
        gapRemainingWhilePaused = nil
        begin(segment: start.segment, at: start.spokenOffset)
    }

    /// Advances playback: starts audio that has arrived, reports words the
    /// clock has passed, and moves on after each segment's pause.
    public func tick() {
        guard state == .speaking, let script else { return }
        switch phase {
        case .idle:
            return
        case .waiting(let offset):
            guard let result = rendered[segment] else { return }
            switch result {
            case .failure(let error):
                fail((error as? LocalizedError)?.errorDescription ?? "The voice couldn't read this paragraph (\(error)).")
            case .success(let speech):
                start(speech, at: offset, in: script)
            }
        case .playing:
            reportWords(in: script)
            if output.isFinished {
                hub.emit(.segmentFinished(segment))
                rendered[segment] = nil
                current = nil
                phase = .gap(until: clock() + script.segments[segment].pauseAfter / rate.multiplier)
                tick()
            }
        case .gap(let until):
            guard clock() >= until else { return }
            if segment + 1 < script.segments.count {
                begin(segment: segment + 1, at: 0)
            } else {
                finish()
            }
        }
    }

    // MARK: Internals

    private func begin(segment index: Int, at offset: Int) {
        segment = index
        lastSpokenOffset = offset
        phase = .waiting(offset: offset)
        hub.emit(.segmentStarted(index))
        requestAudio(from: index)
        tick()
    }

    private func start(_ speech: SynthesizedSpeech, at offset: Int, in script: SpeechScript) {
        let text = script.segments[segment].spokenText
        var startTime = 0.0
        nextWord = 0
        if offset > 0 {
            if let words = speech.words, let index = words.firstIndex(where: { $0.range.upperBound > offset }) {
                nextWord = index
                startTime = words[index].start
            } else if speech.words == nil {
                startTime = speech.duration * Double(offset) / Double(max(text.utf16Length, 1))
            }
        }
        do {
            try output.play(speech.audio, from: startTime, rate: rate.multiplier)
        } catch {
            fail("Couldn't play the narration audio (\(error.localizedDescription)).")
            return
        }
        current = speech
        phase = .playing
        if speech.words == nil {
            let spoken = 0..<text.utf16Length
            let display = script.displayRange(segment: segment, spokenRange: spoken)
            hub.emit(.range(SpokenRange(segment: segment, blockID: display.blockID, displayRange: display.range,
                                        spokenRange: spoken, precision: .estimated)))
        }
        requestAudio(from: segment)
    }

    private func reportWords(in script: SpeechScript) {
        guard let words = current?.words, let time = output.currentTime else { return }
        while nextWord < words.count && words[nextWord].start <= time + 0.02 {
            let word = words[nextWord]
            nextWord += 1
            lastSpokenOffset = word.range.lowerBound
            let display = script.displayRange(segment: segment, spokenRange: word.range)
            hub.emit(.range(SpokenRange(segment: segment, blockID: display.blockID, displayRange: display.range,
                                        spokenRange: word.range, precision: .engineReported)))
        }
    }

    private func requestAudio(from index: Int) {
        guard let script else { return }
        let last = min(index + lookahead, script.segments.count - 1)
        guard index <= last else { return }
        for i in index...last where !requested.contains(i) {
            requested.insert(i)
            let target = script.segments[i]
            guard let voiceID = voice(for: target) else {
                rendered[i] = .failure(TimedSpeechError.noVoice(language: target.language?.base))
                continue
            }
            let generation = self.generation
            let synthesizer = self.synthesizer
            Task { [weak self] in
                let result: Result<SynthesizedSpeech, any Error>
                do {
                    result = .success(try await synthesizer.synthesize(text: target.spokenText, language: target.language,
                                                                       voiceID: voiceID))
                } catch {
                    result = .failure(error)
                }
                guard let self, self.generation == generation else { return }
                self.rendered[i] = result
                self.tick()
            }
        }
    }

    private func voice(for segment: SpeechSegment) -> String? {
        if let selected = selectedVoiceID, let voice = voices.first(where: { $0.id == selected }),
           voice.languageCode.base == (segment.language?.base ?? voice.languageCode.base)
        {
            return selected
        }
        return voiceForSegment(segment)
    }

    private func finish() {
        output.stop()
        script = nil
        phase = .idle
        current = nil
        stopTimer()
        setState(.idle)
        hub.emit(.scriptFinished)
    }

    private func fail(_ message: String) {
        reset()
        hub.emit(.failed(message))
        setState(.idle)
    }

    private func reset() {
        generation += 1
        output.stop()
        script = nil
        phase = .idle
        current = nil
        rendered = [:]
        requested = []
        gapRemainingWhilePaused = nil
        stopTimer()
    }

    private func setState(_ new: SpeechPlaybackState) {
        guard new != state else { return }
        state = new
        hub.emit(.stateChanged(new))
    }

    private func startTimer() {
        guard runsOnTimer, timer == nil else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(40))
                guard let self, !Task.isCancelled else { break }
                self.tick()
            }
        }
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }
}

public enum TimedSpeechError: LocalizedError, Equatable {
    case noVoice(language: String?)

    public var errorDescription: String? {
        switch self {
        case .noVoice(let language):
            "No neural voice is set up for \(language.map { "the language \"\($0)\"" } ?? "this paragraph's language")."
        }
    }
}
