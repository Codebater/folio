import Foundation
import FolioCore

public struct SpeechVoice: Hashable, Sendable, Codable, Identifiable {
    public enum Gender: String, Sendable, Codable, CaseIterable { case female, male, unspecified }

    public enum Quality: Int, Sendable, Codable, Comparable {
        case standard = 0, enhanced = 1, premium = 2, neural = 3
        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var id: String
    public var name: String
    /// BCP-47, e.g. "en-US".
    public var language: String
    public var quality: Quality
    public var engineID: String
    public var isPersonalVoice: Bool
    /// False for voices that must be downloaded first.
    public var isInstalled: Bool
    public var gender: Gender
    /// Download size for voices that aren't installed yet.
    public var downloadBytes: Int64?

    public init(id: String, name: String, language: String, quality: Quality, engineID: String,
                isPersonalVoice: Bool = false, isInstalled: Bool = true, gender: Gender = .unspecified,
                downloadBytes: Int64? = nil) {
        self.id = id
        self.name = name
        self.language = language
        self.quality = quality
        self.engineID = engineID
        self.isPersonalVoice = isPersonalVoice
        self.isInstalled = isInstalled
        self.gender = gender
        self.downloadBytes = downloadBytes
    }

    public var languageCode: LanguageCode { LanguageCode(language) }

    /// Region subtag in upper case ("GB" for "en-GB"), if any.
    public var region: String? {
        let parts = language.replacingOccurrences(of: "_", with: "-").split(separator: "-")
        return parts.count > 1 ? parts.last.map { $0.uppercased() } : nil
    }
}

/// Per-voice adjustments on top of the global speed.
public struct VoiceTuning: Hashable, Sendable, Codable {
    /// 0.8...1.2, 1 = the voice's natural pitch.
    public var pitch: Double
    /// 0.8...1.25, multiplied with the global speed.
    public var rate: Double

    public init(pitch: Double = 1, rate: Double = 1) {
        self.pitch = min(max(pitch, 0.8), 1.2)
        self.rate = min(max(rate, 0.8), 1.25)
    }

    public static let neutral = VoiceTuning()
}

/// Speaking speed as a multiple of a voice's natural pace.
public struct SpeechRate: Hashable, Sendable, Codable, Comparable {
    public var multiplier: Double

    public init(_ multiplier: Double) { self.multiplier = min(max(multiplier, 0.5), 3) }

    public static let normal = SpeechRate(1)
    public static let presets: [SpeechRate] = [0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3].map(SpeechRate.init)
    /// Above this needs Premium.
    public static let freeMaximum = SpeechRate(2)

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.multiplier < rhs.multiplier }

    public var label: String {
        let text = multiplier == multiplier.rounded() ? String(Int(multiplier)) : String(format: "%g", multiplier)
        return text + "\u{00D7}"
    }
}

public enum SpeechPlaybackState: String, Sendable, Equatable {
    case idle, speaking, paused
}

/// How a highlight range was obtained. Only `engineReported` ranges are word
/// timings; anything else must not be presented as exact word alignment.
public enum RangePrecision: String, Sendable, Equatable {
    /// The engine said it is about to speak exactly this range.
    case engineReported
    /// Derived from timing estimates (e.g. a neural voice without alignment).
    case estimated
}

public struct SpokenRange: Hashable, Sendable {
    public var segment: Int
    public var blockID: String
    /// Block-relative display range to highlight.
    public var displayRange: Range<Int>
    /// Segment-relative range in the spoken text.
    public var spokenRange: Range<Int>
    public var precision: RangePrecision

    public init(segment: Int, blockID: String, displayRange: Range<Int>, spokenRange: Range<Int>, precision: RangePrecision) {
        self.segment = segment
        self.blockID = blockID
        self.displayRange = displayRange
        self.spokenRange = spokenRange
        self.precision = precision
    }
}

public enum SpeechEvent: Hashable, Sendable {
    case segmentStarted(Int)
    case range(SpokenRange)
    case segmentFinished(Int)
    case scriptFinished
    case stateChanged(SpeechPlaybackState)
    case failed(String)
}

/// The narration engine contract. Implementations:
/// - `AppleSpeechEngine` (AVSpeechSynthesizer, offline, exact word ranges)
/// - `SimulatedSpeechEngine` (tests, previews, desktop demo)
/// - later: a downloadable neural engine and a self-hosted remote engine.
///
/// Engines own utterance mechanics (queueing, restarting a segment when the
/// rate or voice changes mid-sentence); `ReadAlongController` owns queues,
/// sleep timers and UI state.
@MainActor
public protocol SpeechEngine: AnyObject {
    var engineID: String { get }
    var state: SpeechPlaybackState { get }

    /// Segment, state and completion events. Each access is a new subscription.
    var speechProgress: AsyncStream<SpeechEvent> { get }
    /// Highlight ranges as they are spoken. Each access is a new subscription.
    var speechRanges: AsyncStream<SpokenRange> { get }
    /// Synchronous observation for controllers that must not miss or reorder events.
    func addObserver(_ observer: @escaping @MainActor (SpeechEvent) -> Void) -> SpeechObservation

    func availableVoices() async -> [SpeechVoice]
    /// `nil` picks the best installed voice for each segment's language.
    func selectVoice(_ voice: SpeechVoice?)
    func setRate(_ rate: SpeechRate)

    func speak(_ script: SpeechScript, from position: SpeechPosition?)
    func pause()
    func resume()
    func stop()
    func seek(to position: SpeechPosition)
}

/// Keeps an observer registered until cancelled or released.
@MainActor
public final class SpeechObservation {
    private let remove: @MainActor @Sendable () -> Void
    private var isCancelled = false

    init(_ remove: @escaping @MainActor @Sendable () -> Void) { self.remove = remove }

    public func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        remove()
    }

    deinit {
        guard !isCancelled else { return }
        let remove = self.remove
        Task { @MainActor in remove() }
    }
}

/// Fan-out helper engines use to deliver events to observers and streams.
@MainActor
public final class SpeechEventHub {
    private var observers: [UUID: @MainActor (SpeechEvent) -> Void] = [:]
    private var progressContinuations: [UUID: AsyncStream<SpeechEvent>.Continuation] = [:]
    private var rangeContinuations: [UUID: AsyncStream<SpokenRange>.Continuation] = [:]

    public init() {}

    public func emit(_ event: SpeechEvent) {
        for observer in observers.values { observer(event) }
        if case .range(let range) = event {
            for continuation in rangeContinuations.values { continuation.yield(range) }
        } else {
            for continuation in progressContinuations.values { continuation.yield(event) }
        }
    }

    public func addObserver(_ observer: @escaping @MainActor (SpeechEvent) -> Void) -> SpeechObservation {
        let id = UUID()
        observers[id] = observer
        return SpeechObservation { [weak self] in _ = self?.observers.removeValue(forKey: id) }
    }

    public var progressStream: AsyncStream<SpeechEvent> {
        let (stream, continuation) = AsyncStream<SpeechEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
        let id = UUID()
        progressContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.progressContinuations.removeValue(forKey: id) }
        }
        return stream
    }

    public var rangeStream: AsyncStream<SpokenRange> {
        let (stream, continuation) = AsyncStream<SpokenRange>.makeStream(bufferingPolicy: .bufferingNewest(8))
        let id = UUID()
        rangeContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.rangeContinuations.removeValue(forKey: id) }
        }
        return stream
    }
}
