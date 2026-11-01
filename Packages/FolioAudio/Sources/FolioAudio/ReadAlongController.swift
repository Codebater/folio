import Foundation
import FolioCore

/// Something cancellable returned by a scheduler.
public protocol ScheduledWork: AnyObject {
    func cancel()
}

/// Time source for the sleep timer, swappable in tests.
@MainActor
public protocol ReadAlongScheduler: AnyObject {
    var now: Date { get }
    func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) -> any ScheduledWork
}

@MainActor
public final class TaskScheduler: ReadAlongScheduler {
    final class Work: ScheduledWork {
        let task: Task<Void, Never>
        init(_ task: Task<Void, Never>) { self.task = task }
        func cancel() { task.cancel() }
    }

    public init() {}
    public var now: Date { Date() }

    public func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) -> any ScheduledWork {
        Work(Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { action() }
        })
    }
}

public enum SleepTimerSetting: Hashable, Sendable {
    case minutes(Int)
    case endOfArticle
}

/// An article waiting to be narrated.
public struct ListenItem: Hashable, Sendable, Codable, Identifiable {
    public var id: ArticleID
    public var title: String
    public var feedTitle: String

    public init(id: ArticleID, title: String, feedTitle: String) {
        self.id = id
        self.title = title
        self.feedTitle = feedTitle
    }
}

public struct ReadAlongState: Equatable, Sendable {
    public enum Status: String, Sendable { case idle, loading, playing, paused, finished }

    public var status: Status = .idle
    public var item: ListenItem?
    public var segmentIndex = 0
    public var segmentCount = 0
    /// The block being spoken and the word inside it.
    public var blockID: String?
    public var wordRange: Range<Int>?
    /// The sentence being read, in block coordinates, when it is known exactly.
    public var sentenceRange: Range<Int>?
    /// `nil` until the engine reports ranges; `.estimated` never drives a
    /// word highlight, only the paragraph tint.
    public var precision: RangePrecision?
    public var progress: Double = 0
    public var rate: SpeechRate = .normal
    public var sleepTimer: SleepTimerSetting?
    public var sleepTimerEndsAt: Date?
    public var upNext: [ListenItem] = []
    public var lastError: String?

    public init() {}
}

/// Drives narration of one article at a time with a queue behind it.
///
/// It turns engine events into UI state (which block and word to highlight,
/// progress), implements tap-to-read, paragraph skipping, speed changes,
/// continuous playback through the queue and the sleep timer. It has no
/// Apple dependencies, so all of it is unit-tested on every platform.
@MainActor
public final class ReadAlongController {
    public typealias ScriptProvider = @MainActor (ListenItem) async -> SpeechScript?

    public private(set) var state = ReadAlongState() {
        didSet { if state != oldValue { onChange?(state) } }
    }
    public var onChange: ((ReadAlongState) -> Void)?
    /// Called when an article was listened to the end (not skipped or stopped).
    public var onItemFinished: ((ListenItem) -> Void)?
    /// When true, finishing an article starts the next one in the queue.
    public var continuousPlayback = true

    public let engine: any SpeechEngine
    private let scheduler: any ReadAlongScheduler
    private let scriptProvider: ScriptProvider
    private var script: SpeechScript?
    private var observation: SpeechObservation?
    private var sleepWork: (any ScheduledWork)?
    private var loadGeneration = 0
    /// Where a restored (not yet loaded) item continues.
    private var resumePosition: SpeechPosition?
    /// When narration was paused, for rewinding a little on resume.
    private var pausedAt: Date?
    /// After a pause this long, resume from the start of the sentence; after
    /// `paragraphRewind`, from the start of the paragraph (podcast apps do
    /// the same, so the listener finds the thread again).
    public var sentenceRewind: TimeInterval = 30
    public var paragraphRewind: TimeInterval = 600

    /// When this many segments are left, the next story in the queue is
    /// prepared (its text fetched and its script built), so stories follow
    /// each other without a silence while it loads.
    public var prepareNextWhenSegmentsLeft = 4
    /// Called with the next story's script once it is prepared, so the app
    /// can render its first sentences ahead.
    public var onNextPrepared: (@MainActor (SpeechScript) -> Void)?
    private var prepared: (id: ArticleID, script: SpeechScript)?
    private var preparing: ArticleID?

    public init(engine: any SpeechEngine, scheduler: any ReadAlongScheduler = TaskScheduler(),
                scriptProvider: @escaping ScriptProvider) {
        self.engine = engine
        self.scheduler = scheduler
        self.scriptProvider = scriptProvider
        observation = engine.addObserver { [weak self] event in self?.handle(event) }
    }

    public var currentScript: SpeechScript? { script }

    // MARK: Loading

    /// Narrates `item`, starting at `position` (tap-to-read) or the top.
    public func play(_ item: ListenItem, from position: SpeechPosition? = nil) async {
        loadGeneration += 1
        let generation = loadGeneration
        engine.stop()
        var next = state
        next.status = .loading
        next.item = item
        next.blockID = nil
        next.wordRange = nil
        next.sentenceRange = nil
        next.lastError = nil
        next.upNext.removeAll { $0.id == item.id }
        state = next
        if let ready = prepared, ready.id == item.id {
            prepared = nil
            start(ready.script, item: item, from: position)
            return
        }
        guard let script = await scriptProvider(item), generation == loadGeneration else { return }
        start(script, item: item, from: position)
    }

    /// Prepares the next story while this one finishes.
    private func prepareNext(segmentsLeft: Int) {
        guard continuousPlayback, segmentsLeft <= prepareNextWhenSegmentsLeft, let next = state.upNext.first,
              prepared?.id != next.id, preparing != next.id
        else { return }
        preparing = next.id
        let provider = scriptProvider
        Task { [weak self] in
            let script = await provider(next)
            guard let self else { return }
            self.preparing = nil
            guard let script, self.state.upNext.first?.id == next.id else { return }
            self.prepared = (next.id, script)
            self.onNextPrepared?(script)
        }
    }

    /// Narrates an already built script (the reader has it at hand).
    public func play(script: SpeechScript, item: ListenItem, from position: SpeechPosition? = nil) {
        loadGeneration += 1
        engine.stop()
        state.upNext.removeAll { $0.id == item.id }
        start(script, item: item, from: position)
    }

    private func start(_ script: SpeechScript, item: ListenItem, from position: SpeechPosition?) {
        self.script = script
        resumePosition = nil
        var next = state
        next.item = item
        next.segmentCount = script.segments.count
        next.segmentIndex = 0
        next.progress = 0
        next.precision = nil
        next.blockID = nil
        next.wordRange = nil
        next.sentenceRange = nil
        next.lastError = nil
        if script.isEmpty {
            next.status = .finished
            next.lastError = "This article has no text to read aloud."
        }
        state = next
        guard !script.isEmpty else { return }
        engine.setRate(state.rate)
        engine.speak(script, from: position)
    }

    // MARK: Transport

    public func pause() {
        engine.pause()
        if engine.state == .paused { pausedAt = scheduler.now }
    }

    public func resume() {
        let pausedFor = pausedAt.map { scheduler.now.timeIntervalSince($0) } ?? 0
        pausedAt = nil
        if engine.state == .paused, let script, pausedFor >= sentenceRewind,
           let target = rewindPosition(in: script, toParagraph: pausedFor >= paragraphRewind)
        {
            engine.speak(script, from: target)
        } else if engine.state == .paused {
            engine.resume()
        } else if let script, state.status == .finished || engine.state == .idle {
            engine.speak(script, from: state.status == .finished ? nil : currentPosition)
        } else if script == nil, let item = state.item {
            // Restored after relaunch or a queue was just built: load it now.
            let position = resumePosition
            Task { @MainActor in await self.play(item, from: position) }
        }
    }

    /// Puts items in place without playing, e.g. after relaunch or when a
    /// bulletin was built. `resume()` starts the current item at `position`.
    public func restore(current: ListenItem?, at position: SpeechPosition?, upNext: [ListenItem]) {
        loadGeneration += 1
        engine.stop()
        script = nil
        resumePosition = position
        var next = ReadAlongState()
        next.rate = state.rate
        next.sleepTimer = state.sleepTimer
        next.sleepTimerEndsAt = state.sleepTimerEndsAt
        next.item = current
        next.upNext = upNext.filter { $0.id != current?.id }
        next.status = current == nil ? .idle : .paused
        next.blockID = position?.blockID
        state = next
    }

    public func togglePlayPause() {
        engine.state == .speaking ? pause() : resume()
    }

    public func stop() {
        pausedAt = nil
        loadGeneration += 1
        engine.stop()
        cancelSleepTimer()
        script = nil
        state = ReadAlongState().with { $0.rate = state.rate; $0.upNext = state.upNext }
    }

    /// Tap-to-read: continue from a block (and offset) the reader tapped.
    public func start(at position: SpeechPosition) {
        guard let script else { return }
        if engine.state == .idle { engine.speak(script, from: position) } else { engine.seek(to: position) }
    }

    /// Jumps by whole paragraphs (segments in sentence mode). Skipping back
    /// within the first few words restarts the current one instead.
    /// The start of the current sentence (or paragraph), for resuming after a long pause.
    func rewindPosition(in script: SpeechScript, toParagraph: Bool) -> SpeechPosition? {
        let index = state.segmentIndex
        guard index < script.segments.count, state.blockID?.hasPrefix(SpeechScript.announcementPrefix) != true else { return nil }
        let segment = script.segments[index]
        guard !toParagraph, let word = state.wordRange else { return script.position(segment: index, spokenOffset: 0) }
        let spoken = segment.map.spokenOffset(forDisplay: max(0, word.lowerBound - segment.displayRange.lowerBound))
        let start = RuleBasedSentenceSegmenter().sentences(in: segment.spokenText, language: segment.language)
            .last { $0.lowerBound <= spoken }?.lowerBound ?? 0
        return script.position(segment: index, spokenOffset: start)
    }

    /// Jumps to the next heading, or back to the start of this section (and
    /// on to the previous one when already there). Returns false when there
    /// is no section to go to.
    @discardableResult
    public func skipSection(by direction: Int) -> Bool {
        guard let script, !script.isEmpty else { return false }
        let current = state.segmentIndex
        let headings = script.segments.indices.filter { script.segments[$0].isHeading && !script.segments[$0].isAnnouncement }
        let target = direction > 0 ? headings.first { $0 > current } : (headings.last { $0 < current } ?? (current > 0 ? 0 : nil))
        guard let target else { return false }
        let segment = script.segments[target]
        let position = SpeechPosition(blockID: segment.blockID, offset: segment.displayRange.lowerBound)
        if engine.state == .idle { engine.speak(script, from: position) } else { engine.seek(to: position) }
        return true
    }

    public func skip(by delta: Int) {
        guard let script, !script.isEmpty else { return }
        var target = state.segmentIndex + delta
        if delta < 0, let word = state.wordRange, word.lowerBound > 30 { target = state.segmentIndex }
        target = min(max(target, 0), script.segments.count - 1)
        let segment = script.segments[target]
        let position = SpeechPosition(blockID: segment.blockID, offset: segment.displayRange.lowerBound)
        if engine.state == .idle { engine.speak(script, from: position) } else { engine.seek(to: position) }
    }

    public func setRate(_ rate: SpeechRate) {
        state.rate = rate
        engine.setRate(rate)
    }

    public func selectVoice(_ voice: SpeechVoice?) { engine.selectVoice(voice) }

    /// Where narration is now, for resuming and for saving.
    public var currentPosition: SpeechPosition? {
        if script == nil { return resumePosition }
        guard let blockID = state.blockID, !blockID.hasPrefix(SpeechScript.announcementPrefix) else { return nil }
        return SpeechPosition(blockID: blockID, offset: state.wordRange?.lowerBound ?? 0)
    }

    // MARK: Queue

    public func enqueue(_ item: ListenItem) {
        guard item.id != state.item?.id, !state.upNext.contains(where: { $0.id == item.id }) else { return }
        state.upNext.append(item)
    }

    public func enqueueNext(_ item: ListenItem) {
        state.upNext.removeAll { $0.id == item.id }
        guard item.id != state.item?.id else { return }
        state.upNext.insert(item, at: 0)
    }

    public func removeFromQueue(_ id: ArticleID) { state.upNext.removeAll { $0.id == id } }

    public func moveInQueue(from source: IndexSet, to destination: Int) {
        var items = state.upNext
        let moving = source.sorted().map { items[$0] }
        for index in source.sorted(by: >) { items.remove(at: index) }
        let adjusted = destination - source.filter { $0 < destination }.count
        items.insert(contentsOf: moving, at: min(max(adjusted, 0), items.count))
        state.upNext = items
    }

    public func playNext() async {
        guard let next = state.upNext.first else {
            stop()
            return
        }
        await play(next)
    }

    // MARK: Sleep timer

    public func setSleepTimer(_ setting: SleepTimerSetting?) {
        cancelSleepTimer()
        state.sleepTimer = setting
        if case .minutes(let minutes) = setting {
            let seconds = TimeInterval(minutes * 60)
            state.sleepTimerEndsAt = scheduler.now.addingTimeInterval(seconds)
            sleepWork = scheduler.schedule(after: seconds) { [weak self] in
                guard let self else { return }
                self.pause()
                self.state.sleepTimer = nil
                self.state.sleepTimerEndsAt = nil
            }
        }
    }

    private func cancelSleepTimer() {
        sleepWork?.cancel()
        sleepWork = nil
        state.sleepTimer = nil
        state.sleepTimerEndsAt = nil
    }

    // MARK: Engine events

    private func handle(_ event: SpeechEvent) {
        guard let script else { return }
        // Build the next state in one go so observers never see a new block
        // paired with the previous block's word range.
        var next = state
        var followUp: (@MainActor () -> Void)?
        var followUpFinished: (() -> Void)?
        switch event {
        case .segmentStarted(let index):
            guard index < script.segments.count else { return }
            prepareNext(segmentsLeft: script.segments.count - index)
            next.segmentIndex = index
            next.blockID = script.segments[index].blockID
            next.wordRange = nil
            next.sentenceRange = script.sentence(segment: index, word: nil)
            next.progress = script.progress(segment: index, spokenOffset: 0)
        case .range(let range):
            next.segmentIndex = range.segment
            next.blockID = range.blockID
            next.precision = range.precision
            // Estimated ranges only move the paragraph tint, never a word highlight.
            next.wordRange = range.precision == .engineReported ? range.displayRange : nil
            next.sentenceRange = script.sentence(segment: range.segment, word: next.wordRange)
            next.progress = script.progress(segment: range.segment, spokenOffset: range.spokenRange.lowerBound)
        case .segmentFinished:
            return
        case .stateChanged(let engineState):
            switch engineState {
            case .speaking: next.status = .playing
            case .paused: next.status = .paused
            case .idle: if next.status != .finished && next.status != .loading { next.status = .idle }
            }
        case .scriptFinished:
            next.status = .finished
            next.progress = 1
            next.wordRange = nil
            next.sentenceRange = nil
            if let item = next.item {
                let finished = onItemFinished
                followUpFinished = { finished?(item) }
            }
            if next.sleepTimer == .endOfArticle {
                sleepWork?.cancel()
                sleepWork = nil
                next.sleepTimer = nil
                next.sleepTimerEndsAt = nil
            } else if continuousPlayback, let upcoming = next.upNext.first {
                followUp = { [weak self] in Task { @MainActor in await self?.play(upcoming) } }
            }
        case .failed(let message):
            next.lastError = message
            next.status = .idle
        }
        state = next
        followUpFinished?()
        followUp?()
    }
}

extension ReadAlongState {
    func with(_ change: (inout ReadAlongState) -> Void) -> ReadAlongState {
        var copy = self
        change(&copy)
        return copy
    }
}
