#if canImport(AVFoundation)
import AVFoundation
import FolioCore

/// Narration with the system's on-device voices.
///
/// Each segment (paragraph, or sentence in sentence mode) is one
/// `AVSpeechUtterance`; short utterances avoid the iOS 17.0 bug where long
/// ones stop early, and give natural pauses via `postUtteranceDelay`. Two
/// segments are queued ahead so there is no gap between them.
/// `willSpeakRangeOfSpeechString` reports exactly which UTF-16 range of the
/// utterance is about to be spoken; it is mapped back through the segment's
/// `OffsetMap` to the on-screen text, so these ranges are `engineReported`.
///
/// AVSpeechSynthesizer cannot change rate or voice mid-utterance, so a change
/// restarts the current segment from the last spoken word.
@MainActor
public final class AppleSpeechEngine: NSObject, SpeechEngine {
    public let engineID = "apple"
    public private(set) var state: SpeechPlaybackState = .idle
    /// Preferred voice identifier per base language ("en" → identifier).
    public var preferredVoiceIDs: [String: String] = [:]
    /// Pitch and speed adjustments per voice identifier.
    public var voiceTuning: [String: VoiceTuning] = [:]

    private struct Queued {
        let id: ObjectIdentifier
        let utterance: AVSpeechUtterance
        let segment: Int
        /// Offset of the utterance's first character in the segment's spoken text.
        let base: Int
    }

    private static let lookahead = 2

    private let synthesizer = AVSpeechSynthesizer()
    private let hub = SpeechEventHub()
    private var script: SpeechScript?
    private var selectedVoice: SpeechVoice?
    private var rate: SpeechRate = .normal
    private var queued: [Queued] = []
    private var nextSegmentToQueue = 0
    private var currentSegment: Int?
    private var lastWordOffset = 0
    private var restartOnResume = false

    public override init() {
        super.init()
        synthesizer.delegate = self
        #if os(iOS)
        // The app owns the audio session (playback / spokenAudio) so speech
        // keeps going in the background and on the lock screen.
        synthesizer.usesApplicationAudioSession = true
        #endif
    }

    public var speechProgress: AsyncStream<SpeechEvent> { hub.progressStream }
    public var speechRanges: AsyncStream<SpokenRange> { hub.rangeStream }

    public func addObserver(_ observer: @escaping @MainActor (SpeechEvent) -> Void) -> SpeechObservation {
        hub.addObserver(observer)
    }

    // MARK: Voices

    public func availableVoices() async -> [SpeechVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { !$0.voiceTraits.contains(.isNoveltyVoice) }
            .map(Self.makeVoice)
            .sorted { ($0.language, -$0.quality.rawValue, $0.name) < ($1.language, -$1.quality.rawValue, $1.name) }
    }

    static func makeVoice(_ voice: AVSpeechSynthesisVoice) -> SpeechVoice {
        let quality: SpeechVoice.Quality =
            switch voice.quality {
            case .premium: .premium
            case .enhanced: .enhanced
            default: .standard
            }
        let gender: SpeechVoice.Gender =
            switch voice.gender {
            case .female: .female
            case .male: .male
            default: .unspecified
            }
        return SpeechVoice(id: voice.identifier, name: voice.name, language: voice.language, quality: quality,
                           engineID: "apple", isPersonalVoice: voice.voiceTraits.contains(.isPersonalVoice), gender: gender)
    }

    /// Asks for access to the user's Personal Voice (iOS 17+). Returns true if granted.
    public static func requestPersonalVoiceAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVSpeechSynthesizer.requestPersonalVoiceAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    public func selectVoice(_ voice: SpeechVoice?) {
        selectedVoice = voice
        restartIfActive()
    }

    public func setRate(_ rate: SpeechRate) {
        guard rate != self.rate else { return }
        self.rate = rate
        restartIfActive()
    }

    /// Maps the speed multiplier onto AVSpeechUtterance's 0...1 scale, where
    /// 0.5 is the voice's natural pace. Perceived speed differs per voice; the
    /// curve is a starting point to tune on device.
    static func appleRate(_ rate: SpeechRate) -> Float {
        let normal = Double(AVSpeechUtteranceDefaultSpeechRate)
        let maximum = Double(AVSpeechUtteranceMaximumSpeechRate)
        let minimum = Double(AVSpeechUtteranceMinimumSpeechRate)
        let value = normal + (maximum - normal) * log2(rate.multiplier) / log2(3)
        return Float(min(max(value, minimum), maximum))
    }

    /// The voice narration will use for a language right now (for the UI's
    /// voice chip, and to tell the user when a chosen voice is missing).
    public func resolvedVoice(for language: LanguageCode?) -> SpeechVoice? {
        voice(for: language).map(Self.makeVoice)
    }

    private func voice(for language: LanguageCode?) -> AVSpeechSynthesisVoice? {
        let base = language?.base ?? Locale.current.language.languageCode?.identifier ?? "en"
        if let selected = selectedVoice, language == nil || selected.languageCode.base == base,
           let voice = AVSpeechSynthesisVoice(identifier: selected.id)
        {
            return voice
        }
        if let id = preferredVoiceIDs[base], let voice = AVSpeechSynthesisVoice(identifier: id) { return voice }
        return Self.bestVoice(forLanguage: base)
    }

    /// Highest-quality installed voice for a language, preferring the user's
    /// region ("en-GB" in the UK). Personal and novelty voices are only used
    /// when picked explicitly.
    static func bestVoice(forLanguage base: String) -> AVSpeechSynthesisVoice? {
        let region = Locale.current.region?.identifier.uppercased()
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter {
            LanguageCode($0.language).base == base && !$0.voiceTraits.contains(.isNoveltyVoice)
                && !$0.voiceTraits.contains(.isPersonalVoice)
        }
        func score(_ voice: AVSpeechSynthesisVoice) -> Int {
            let quality = voice.quality == .premium ? 20 : (voice.quality == .enhanced ? 10 : 0)
            let regional = region.map { voice.language.uppercased().hasSuffix("-\($0)") } == true ? 1 : 0
            return quality + regional
        }
        // Never `AVSpeechSynthesisVoice(language:)`: on iOS 26 it ignores the
        // voice the user chose in Settings (FB20271264). Pick by identifier.
        return candidates.max { score($0) < score($1) }
            ?? AVSpeechSynthesisVoice.speechVoices().first { LanguageCode($0.language).base == base }
    }

    // MARK: Playback

    public func speak(_ script: SpeechScript, from position: SpeechPosition?) {
        cancelUtterances()
        self.script = script
        restartOnResume = false
        let start = position.flatMap(script.locate) ?? (script.isEmpty ? nil : (0, 0))
        guard let start else {
            setState(.idle)
            hub.emit(.scriptFinished)
            return
        }
        nextSegmentToQueue = start.segment
        enqueueNext(startingAt: start.spokenOffset)
        fillQueue()
        setState(.speaking)
    }

    public func pause() {
        guard state == .speaking else { return }
        synthesizer.pauseSpeaking(at: .word)
        setState(.paused)
    }

    public func resume() {
        guard state == .paused else { return }
        if restartOnResume, let script, let segment = currentSegment {
            speak(script, from: script.position(segment: segment, spokenOffset: lastWordOffset))
        } else {
            synthesizer.continueSpeaking()
            setState(.speaking)
        }
    }

    public func stop() {
        cancelUtterances()
        script = nil
        setState(.idle)
    }

    public func seek(to position: SpeechPosition) {
        guard let script else { return }
        let wasPaused = state == .paused
        speak(script, from: position)
        if wasPaused { pause() }
    }

    private func restartIfActive() {
        guard let script, let segment = currentSegment else { return }
        switch state {
        case .speaking: speak(script, from: script.position(segment: segment, spokenOffset: lastWordOffset))
        case .paused: restartOnResume = true
        case .idle: break
        }
    }

    private func enqueueNext(startingAt offset: Int = 0) {
        guard let script, nextSegmentToQueue < script.segments.count else { return }
        let segment = script.segments[nextSegmentToQueue]
        let length = segment.spokenText.utf16Length
        let text = String(segment.spokenText.utf16Slice(min(offset, length)..<length))
        let utterance = AVSpeechUtterance(string: text)
        let chosen = segment.voiceID.flatMap(AVSpeechSynthesisVoice.init(identifier:)) ?? voice(for: segment.language)
        utterance.voice = chosen
        let tuning = chosen.flatMap { voiceTuning[$0.identifier] } ?? .neutral
        utterance.rate = Self.appleRate(SpeechRate(rate.multiplier * tuning.rate))
        utterance.pitchMultiplier = Float(tuning.pitch)
        // Pauses shrink with speed like a fast talker's do, never below 150 ms.
        utterance.postUtteranceDelay = max(0.15, segment.pauseAfter / rate.multiplier)
        utterance.prefersAssistiveTechnologySettings = false
        queued.append(Queued(id: ObjectIdentifier(utterance), utterance: utterance, segment: segment.index, base: offset))
        nextSegmentToQueue += 1
        synthesizer.speak(utterance)
    }

    private func fillQueue() {
        while let script, queued.count <= Self.lookahead, nextSegmentToQueue < script.segments.count {
            enqueueNext()
        }
    }

    private func cancelUtterances() {
        queued.removeAll()
        currentSegment = nil
        if synthesizer.isSpeaking || synthesizer.isPaused { synthesizer.stopSpeaking(at: .immediate) }
    }

    private func setState(_ new: SpeechPlaybackState) {
        guard new != state else { return }
        state = new
        hub.emit(.stateChanged(new))
    }

    // MARK: Delegate events (delivered on the main actor, in order)

    fileprivate func didStart(_ id: ObjectIdentifier) {
        guard let entry = queued.first(where: { $0.id == id }) else { return }
        currentSegment = entry.segment
        lastWordOffset = entry.base
        hub.emit(.segmentStarted(entry.segment))
    }

    fileprivate func willSpeak(_ id: ObjectIdentifier, location: Int, length: Int) {
        guard let script, let entry = queued.first(where: { $0.id == id }), location != NSNotFound else { return }
        let spoken = (entry.base + location)..<(entry.base + location + max(length, 1))
        lastWordOffset = spoken.lowerBound
        let display = script.displayRange(segment: entry.segment, spokenRange: spoken)
        hub.emit(.range(SpokenRange(segment: entry.segment, blockID: display.blockID, displayRange: display.range,
                                    spokenRange: spoken, precision: .engineReported)))
    }

    fileprivate func didFinish(_ id: ObjectIdentifier) {
        guard let index = queued.firstIndex(where: { $0.id == id }) else { return }
        let entry = queued.remove(at: index)
        hub.emit(.segmentFinished(entry.segment))
        fillQueue()
        if queued.isEmpty, let script, nextSegmentToQueue >= script.segments.count {
            self.script = nil
            currentSegment = nil
            setState(.idle)
            hub.emit(.scriptFinished)
        }
    }
}

extension AppleSpeechEngine: AVSpeechSynthesizerDelegate {
    // AVSpeechSynthesizer calls its delegate on an arbitrary queue. Events
    // are hopped to the main actor through the main queue, which keeps their
    // order (didStart before willSpeak before didFinish).
    nonisolated private func deliver(_ work: @escaping @MainActor @Sendable (AppleSpeechEngine) -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { work(self) }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { work(self) } }
        }
    }

    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        deliver { $0.didStart(id) }
    }

    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange,
                                              utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        let location = characterRange.location
        let length = characterRange.length
        deliver { $0.willSpeak(id, location: location, length: length) }
    }

    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        deliver { $0.didFinish(id) }
    }
}
#endif

#if canImport(AVFoundation)
/// Plays short voice samples in Settings with its own synthesizer, so a
/// preview never disturbs (or loses the place of) the narration queue. The
/// preview uses the same engine as playback, so it sounds exactly the same.
@MainActor
public final class VoicePreviewer: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    public private(set) var playingVoiceID: String?
    public var onChange: ((String?) -> Void)?

    public override init() {
        super.init()
        synthesizer.delegate = self
        #if os(iOS)
        synthesizer.usesApplicationAudioSession = true
        #endif
    }

    public func play(voiceID: String, text: String, tuning: VoiceTuning = .neutral, rate: SpeechRate = .normal) {
        stop()
        guard let voice = AVSpeechSynthesisVoice(identifier: voiceID) else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AppleSpeechEngine.appleRate(SpeechRate(rate.multiplier * tuning.rate))
        utterance.pitchMultiplier = Float(tuning.pitch)
        playingVoiceID = voiceID
        onChange?(voiceID)
        synthesizer.speak(utterance)
    }

    public func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        if playingVoiceID != nil {
            playingVoiceID = nil
            onChange?(nil)
        }
    }

    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.finished() } }
    }

    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.finished() } }
    }

    private func finished() {
        guard !synthesizer.isSpeaking, playingVoiceID != nil else { return }
        playingVoiceID = nil
        onChange?(nil)
    }
}
#endif
