import Foundation
import FolioCore

/// A silent engine that "speaks" word by word. Used by tests (driven with
/// `step()`), SwiftUI previews and the desktop browser demo (driven by a
/// timer). Its ranges are exact for its own pacing, so they are reported as
/// `engineReported` like a real engine's.
@MainActor
public final class SimulatedSpeechEngine: SpeechEngine {
    public let engineID = "simulated"
    public private(set) var state: SpeechPlaybackState = .idle
    public private(set) var rate: SpeechRate = .normal
    public private(set) var selectedVoice: SpeechVoice?
    /// Words per minute at 1x when running on a timer.
    public var wordsPerMinute: Double = 180
    /// When false, nothing happens until `step()` is called.
    public var runsOnTimer: Bool

    let hub = SpeechEventHub()
    private var script: SpeechScript?
    private var segment = 0
    private var words: [Range<Int>] = []
    private var wordIndex = 0
    private var timer: Task<Void, Never>?

    public init(runsOnTimer: Bool = false) { self.runsOnTimer = runsOnTimer }

    public var speechProgress: AsyncStream<SpeechEvent> { hub.progressStream }
    public var speechRanges: AsyncStream<SpokenRange> { hub.rangeStream }

    public func addObserver(_ observer: @escaping @MainActor (SpeechEvent) -> Void) -> SpeechObservation {
        hub.addObserver(observer)
    }

    public func availableVoices() async -> [SpeechVoice] {
        [
            SpeechVoice(id: "sim.en", name: "Simulated English", language: "en-US", quality: .standard, engineID: engineID),
            SpeechVoice(id: "sim.de", name: "Simulated German", language: "de-DE", quality: .standard, engineID: engineID),
        ]
    }

    public func selectVoice(_ voice: SpeechVoice?) { selectedVoice = voice }
    public func setRate(_ rate: SpeechRate) { self.rate = rate }

    public func speak(_ script: SpeechScript, from position: SpeechPosition?) {
        stopTimer()
        self.script = script
        let start = position.flatMap(script.locate) ?? (script.isEmpty ? nil : (0, 0))
        guard let start else {
            setState(.idle)
            hub.emit(.scriptFinished)
            return
        }
        setState(.speaking)
        begin(segment: start.segment, at: start.spokenOffset)
        startTimerIfNeeded()
    }

    public func pause() {
        guard state == .speaking else { return }
        stopTimer()
        setState(.paused)
    }

    public func resume() {
        guard state == .paused else { return }
        setState(.speaking)
        startTimerIfNeeded()
    }

    public func stop() {
        stopTimer()
        script = nil
        setState(.idle)
    }

    public func seek(to position: SpeechPosition) {
        guard let script else { return }
        let wasPaused = state == .paused
        speak(script, from: position)
        if wasPaused { pause() }
    }

    /// Speaks the next word. Returns false when the script is finished.
    @discardableResult
    public func step() -> Bool {
        guard state == .speaking, let script else { return false }
        if wordIndex < words.count {
            let spoken = words[wordIndex]
            wordIndex += 1
            let display = script.displayRange(segment: segment, spokenRange: spoken)
            hub.emit(.range(SpokenRange(segment: segment, blockID: display.blockID, displayRange: display.range,
                                        spokenRange: spoken, precision: .engineReported)))
            return true
        }
        hub.emit(.segmentFinished(segment))
        if segment + 1 < script.segments.count {
            begin(segment: segment + 1, at: 0)
            return step()
        }
        stopTimer()
        self.script = nil
        setState(.idle)
        hub.emit(.scriptFinished)
        return false
    }

    private func begin(segment index: Int, at offset: Int) {
        guard let script else { return }
        segment = index
        let text = script.segments[index].spokenText
        words = Self.wordRanges(in: text).filter { $0.upperBound > offset }
        wordIndex = 0
        hub.emit(.segmentStarted(index))
    }

    static func wordRanges(in text: String) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start: Int?
        var offset = 0
        for scalar in text.unicodeScalars {
            let width = scalar.utf16.count
            if scalar.properties.isWhitespace {
                if let s = start { ranges.append(s..<offset) }
                start = nil
            } else if start == nil {
                start = offset
            }
            offset += width
        }
        if let s = start { ranges.append(s..<offset) }
        return ranges
    }

    private func setState(_ new: SpeechPlaybackState) {
        guard new != state else { return }
        state = new
        hub.emit(.stateChanged(new))
    }

    private func startTimerIfNeeded() {
        guard runsOnTimer, timer == nil else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                let interval = 60 / ((self?.wordsPerMinute ?? 180) * (self?.rate.multiplier ?? 1))
                try? await Task.sleep(for: .seconds(interval))
                guard let self, !Task.isCancelled, self.step() else { break }
            }
        }
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }
}
