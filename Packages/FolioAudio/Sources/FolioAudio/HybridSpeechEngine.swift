import Foundation
import FolioCore

/// Two engines behind one: each run of consecutive segments goes to the
/// engine its voice belongs to (Apple voices to `primary`, neural voices to
/// `secondary`). Most articles are one run. A mixed English/Czech article
/// with a neural Czech voice plays its English paragraphs with Apple and its
/// Czech ones with the neural voice, and events come out as if one engine
/// read the whole script.
@MainActor
public final class HybridSpeechEngine: SpeechEngine {
    public let engineID = "hybrid"
    public private(set) var state: SpeechPlaybackState = .idle
    public let primary: any SpeechEngine
    public let secondary: any SpeechEngine
    /// True for segments the secondary engine reads.
    public var usesSecondary: @MainActor (SpeechSegment) -> Bool

    struct Run {
        var secondary: Bool
        /// Segment indices in the full script.
        var segments: Range<Int>
        /// The run's segments as a script of their own, indexed from 0.
        var script: SpeechScript
    }

    private let hub = SpeechEventHub()
    private var observations: [SpeechObservation] = []
    private var runs: [Run] = []
    private var script: SpeechScript?
    private var active: Int?
    /// Where narration is, for re-routing after a voice change.
    private var lastPosition: (segment: Int, spokenOffset: Int)?

    public init(primary: any SpeechEngine, secondary: any SpeechEngine,
                usesSecondary: @escaping @MainActor (SpeechSegment) -> Bool) {
        self.primary = primary
        self.secondary = secondary
        self.usesSecondary = usesSecondary
        observations = [
            primary.addObserver { [weak self] in self?.forward($0, fromSecondary: false) },
            secondary.addObserver { [weak self] in self?.forward($0, fromSecondary: true) },
        ]
    }

    public var speechProgress: AsyncStream<SpeechEvent> { hub.progressStream }
    public var speechRanges: AsyncStream<SpokenRange> { hub.rangeStream }

    public func addObserver(_ observer: @escaping @MainActor (SpeechEvent) -> Void) -> SpeechObservation {
        hub.addObserver(observer)
    }

    public func availableVoices() async -> [SpeechVoice] {
        await primary.availableVoices() + secondary.availableVoices()
    }

    /// A voice change can move segments to the other engine (an Apple voice
    /// replaced by a neural one); then narration restarts from the current
    /// word on the right engine, keeping play or pause.
    public func selectVoice(_ voice: SpeechVoice?) {
        guard let script, active != nil else {
            primary.selectVoice(voice)
            secondary.selectVoice(voice)
            return
        }
        let rerouted = Self.runs(of: script, usesSecondary: usesSecondary)
        guard rerouted.map(\.segments) != runs.map(\.segments) || rerouted.map(\.secondary) != runs.map(\.secondary) else {
            activeEngine?.selectVoice(voice)
            return
        }
        primary.selectVoice(voice)
        secondary.selectVoice(voice)
        let wasPaused = state == .paused
        let position = lastPosition.map { script.position(segment: $0.segment, spokenOffset: $0.spokenOffset) }
        speak(script, from: position)
        if wasPaused { pause() }
    }

    public func setRate(_ rate: SpeechRate) {
        primary.setRate(rate)
        secondary.setRate(rate)
    }

    public func speak(_ script: SpeechScript, from position: SpeechPosition?) {
        stopActive()
        self.script = script
        runs = Self.runs(of: script, usesSecondary: usesSecondary)
        guard let start = position.flatMap(script.locate) ?? (script.isEmpty ? nil : (0, 0)),
              let index = runs.firstIndex(where: { $0.segments.contains(start.segment) })
        else {
            setState(.idle)
            hub.emit(.scriptFinished)
            return
        }
        setState(.speaking)
        startRun(index, segment: start.segment, spokenOffset: start.spokenOffset)
    }

    public func pause() {
        guard state == .speaking else { return }
        activeEngine?.pause()
        setState(.paused)
    }

    public func resume() {
        guard state == .paused else { return }
        setState(.speaking)
        activeEngine?.resume()
    }

    public func stop() {
        stopActive()
        script = nil
        runs = []
        setState(.idle)
    }

    public func seek(to position: SpeechPosition) {
        guard let script, let start = script.locate(position),
              let index = runs.firstIndex(where: { $0.segments.contains(start.segment) })
        else { return }
        if index == active, let engine = activeEngine {
            engine.seek(to: subPosition(in: runs[index], segment: start.segment, spokenOffset: start.spokenOffset))
            return
        }
        stopActive()
        startRun(index, segment: start.segment, spokenOffset: start.spokenOffset)
        if state == .paused { activeEngine?.pause() }
    }

    // MARK: Runs

    static func runs(of script: SpeechScript, usesSecondary: @MainActor (SpeechSegment) -> Bool) -> [Run] {
        var runs: [Run] = []
        var start = 0
        while start < script.segments.count {
            let secondary = usesSecondary(script.segments[start])
            var end = start + 1
            while end < script.segments.count && usesSecondary(script.segments[end]) == secondary { end += 1 }
            let segments = script.segments[start..<end].enumerated().map { offset, segment in
                var copy = segment
                copy.index = offset
                return copy
            }
            runs.append(Run(secondary: secondary, segments: start..<end,
                            script: SpeechScript(articleID: script.articleID, language: script.language, segments: segments,
                                                 blockOrder: script.blockOrder)))
            start = end
        }
        return runs
    }

    private var activeEngine: (any SpeechEngine)? {
        active.map { runs[$0].secondary ? secondary : primary }
    }

    private func startRun(_ index: Int, segment: Int, spokenOffset: Int) {
        active = index
        let run = runs[index]
        let engine = run.secondary ? secondary : primary
        let position = segment == run.segments.lowerBound && spokenOffset == 0
            ? nil : subPosition(in: run, segment: segment, spokenOffset: spokenOffset)
        engine.speak(run.script, from: position)
    }

    private func subPosition(in run: Run, segment: Int, spokenOffset: Int) -> SpeechPosition {
        run.script.position(segment: segment - run.segments.lowerBound, spokenOffset: spokenOffset)
    }

    private func stopActive() {
        let engine = activeEngine
        active = nil
        engine?.stop()
    }

    private func forward(_ event: SpeechEvent, fromSecondary: Bool) {
        guard let index = active, runs[index].secondary == fromSecondary else { return }
        let offset = runs[index].segments.lowerBound
        switch event {
        case .segmentStarted(let segment):
            lastPosition = (segment + offset, 0)
            hub.emit(.segmentStarted(segment + offset))
        case .segmentFinished(let segment):
            hub.emit(.segmentFinished(segment + offset))
        case .range(var range):
            range.segment += offset
            lastPosition = (range.segment, range.spokenRange.lowerBound)
            hub.emit(.range(range))
        case .scriptFinished:
            if index + 1 < runs.count {
                startRun(index + 1, segment: runs[index + 1].segments.lowerBound, spokenOffset: 0)
                if state == .paused { activeEngine?.pause() }
            } else {
                active = nil
                script = nil
                setState(.idle)
                hub.emit(.scriptFinished)
            }
        case .stateChanged:
            break  // this engine reports its own state across runs
        case .failed(let message):
            active = nil
            hub.emit(.failed(message))
            setState(.idle)
        }
    }

    private func setState(_ new: SpeechPlaybackState) {
        guard new != state else { return }
        state = new
        hub.emit(.stateChanged(new))
    }
}
