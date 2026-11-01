import AVFoundation
import Foundation
import FluidAudio
import FolioAudio
import FolioCore

/// Kokoro (English, Spanish; word timing), Supertonic-3 (Czech, Slovak,
/// German and more) and Paradee-8M (English, CPU only) on this device,
/// through FluidAudio. Every clip is trimmed and brought to one loudness.
///
/// Models download on first use into `modelsDirectory` and run on the CPU
/// and Neural Engine only: iOS refuses GPU work in the background, and
/// narration has to keep going with the screen locked. Rendered segments are
/// cached as AAC, so a paragraph is synthesized once and replays at any speed.
public actor FluidSpeechSynthesizer: SpeechSynthesizing {
    /// Part of every cache key: a new model or runtime renders afresh.
    public static let engineVersion = "fluidaudio-0.18.0-r2"

    /// Where Kokoro's stages run. The app uses `.noMetal`; the others exist
    /// for diagnosis on machines where that route fails.
    public enum KokoroRouting: String, Sendable, CaseIterable {
        /// CPU and Neural Engine; noise and tail on the CPU. Safe in the background.
        case noMetal
        case cpuOnly
        /// FluidAudio's default for the OS (may use the GPU).
        case standard
        /// The newer hybrid runtime (iOS 18, macOS 15; English only; uses the GPU).
        case v3
    }

    public let modelsDirectory: URL
    public let cache: SpeechAudioCache
    public let kokoroRouting: KokoroRouting
    /// Exists only while Kokoro is working. Core ML crashes in Kokoro can't
    /// be caught, so the app checks for a leftover marker at launch and
    /// switches Kokoro off on a device where it took the app down.
    public let kokoroCrashMarker: URL?
    private let scratch: URL
    private var kokoro: [KokoroAneVariant: KokoroAneManager] = [:]
    private var supertonic: Supertonic3Manager?
    private var styles: [String: Supertonic3VoiceStyle] = [:]
    private var paradee: ParadeeManager?

    public init(modelsDirectory: URL, cacheDirectory: URL, kokoroRouting: KokoroRouting = .noMetal,
                kokoroCrashMarker: URL? = nil) {
        self.modelsDirectory = modelsDirectory
        self.kokoroRouting = kokoroRouting
        self.kokoroCrashMarker = kokoroCrashMarker
        self.cache = SpeechAudioCache(directory: cacheDirectory)
        self.scratch = FileManager.default.temporaryDirectory.appendingPathComponent("folio-neural", isDirectory: true)
    }

    public func synthesize(text: String, language: LanguageCode?, voiceID: String) async throws -> SynthesizedSpeech {
        guard let voice = NeuralVoiceCatalog.voice(voiceID) else { throw NeuralVoiceError.unknownVoice(voiceID) }
        let key = SpeechAudioCache.key(engine: Self.engineVersion, voiceID: voiceID, text: text)
        if let cached = await cache.lookup(key: key, text: text) { return cached }
        let rendered = Self.polished(try await render(text: text, voice: voice))
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let file = scratch.appendingPathComponent(UUID().uuidString + ".m4a")
        try AudioFiles.writeAAC(rendered.samples, sampleRate: rendered.sampleRate, to: file)
        return try await cache.store(key: key, text: text, audio: file,
                                     duration: Double(rendered.samples.count) / Double(rendered.sampleRate),
                                     words: rendered.words)
    }

    /// Downloads and loads a model so its voices can play offline.
    public func prepare(_ model: NeuralVoiceCatalog.Model) async throws {
        switch model {
        case .kokoro:
            markKokoroBusy(true)
            defer { markKokoroBusy(false) }
            _ = try await kokoroManager(.english)
            _ = try await kokoroManager(.spanish)
        case .supertonic:
            _ = try await supertonicManager()
            for voice in NeuralVoiceCatalog.all where voice.model == .supertonic { _ = try await style(voice.modelVoice) }
        case .paradee:
            let manager = try await paradeeManager()
            // The British voices fetch their own lexicon on first use.
            _ = try await manager.phonemes(for: "Ready.", voice: .bmFable)
        }
    }

    /// Frees memory; models stay on disk.
    public func unload() async {
        for manager in kokoro.values { await manager.cleanup() }
        kokoro = [:]
        await supertonic?.cleanup()
        supertonic = nil
        await paradee?.cleanup()
        paradee = nil
    }

    // MARK: Rendering

    struct Rendered {
        var samples: [Float]
        var sampleRate: Int
        var words: [TimedWord]?
    }

    func render(text: String, voice: NeuralVoiceCatalog.Voice) async throws -> Rendered {
        switch voice.model {
        case .kokoro:
            let variant: KokoroAneVariant = voice.language.hasPrefix("es") ? .spanish : .english
            markKokoroBusy(true)
            defer { markKokoroBusy(false) }
            let manager = try await kokoroManager(variant)
            var samples: [Float] = []
            var words: [TimedWord] = []
            var sampleRate = 24_000
            // Short pieces keep each call within Kokoro's single-chunk limit,
            // which word timing depends on.
            for chunk in SpeechChunker.chunks(of: text, language: LanguageCode(voice.language)) {
                try Task.checkCancellation()
                let piece = Self.substring(text, chunk)
                guard piece.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
                let result = try await manager.synthesizeDetailed(text: piece, voice: voice.modelVoice)
                sampleRate = result.sampleRate
                let offset = Double(samples.count) / Double(sampleRate)
                if let timed = KokoroAlignment.wordTimings(
                    spokenText: piece, normalizedText: result.normalizedText, phonemes: result.phonemes,
                    durations: result.predictedDurations, tokenCount: result.inputIds.count,
                    audioDuration: result.durationSeconds)
                {
                    words += timed.map { $0.shifted(characters: chunk.lowerBound, seconds: offset) }
                }
                samples += result.samples
            }
            return Rendered(samples: samples, sampleRate: sampleRate, words: words.isEmpty ? nil : words)
        case .supertonic:
            let manager = try await supertonicManager()
            let style = try await style(voice.modelVoice)
            let result = try await manager.synthesize(text: text, language: LanguageCode(voice.language).base, style: style)
            return Rendered(samples: result.samples, sampleRate: Supertonic3Constants.sampleRate, words: nil)
        case .paradee:
            let manager = try await paradeeManager()
            guard let paradeeVoice = ParadeeVoice(rawValue: voice.modelVoice) else { throw NeuralVoiceError.unknownVoice(voice.id) }
            let samples = try await manager.synthesize(text: text, voice: paradeeVoice)
            return Rendered(samples: samples, sampleRate: manager.sampleRate, words: nil)
        }
    }

    /// Trimmed ends and one loudness for every engine; word timings follow the trim.
    static func polished(_ rendered: Rendered) -> Rendered {
        let (samples, removed) = AudioPolish.trimmed(rendered.samples, sampleRate: rendered.sampleRate)
        let duration = Double(samples.count) / Double(rendered.sampleRate)
        return Rendered(samples: AudioPolish.normalized(samples, sampleRate: rendered.sampleRate), sampleRate: rendered.sampleRate,
                        words: rendered.words.map { AudioPolish.moved($0, back: removed, duration: duration) })
    }

    private func markKokoroBusy(_ busy: Bool) {
        guard let marker = kokoroCrashMarker else { return }
        if busy {
            try? FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data().write(to: marker)
        } else {
            try? FileManager.default.removeItem(at: marker)
        }
    }

    private func kokoroManager(_ variant: KokoroAneVariant) async throws -> KokoroAneManager {
        if let manager = kokoro[variant] { return manager }
        // Legacy runtime: iOS 17+ and Spanish (v3 needs iOS 18 and is English only).
        let manager: KokoroAneManager
        switch kokoroRouting {
        case .noMetal: manager = KokoroAneManager(variant: variant, directory: modelsDirectory, computeUnits: .aneTailCpu)
        case .cpuOnly: manager = KokoroAneManager(variant: variant, directory: modelsDirectory, computeUnits: .cpuOnly)
        case .standard: manager = KokoroAneManager(variant: variant, directory: modelsDirectory)
        case .v3:
            manager = KokoroAneManager(variant: variant, directory: modelsDirectory,
                                       version: variant == .english ? .v3 : .legacy)
        }
        try await manager.initialize()
        kokoro[variant] = manager
        return manager
    }

    private func supertonicManager() async throws -> Supertonic3Manager {
        if let supertonic { return supertonic }
        let manager = Supertonic3Manager(directory: modelsDirectory, computeUnits: .cpuAndNeuralEngine,
                                         vectorEstimator: .aneBucketed(.int4))
        try await manager.initialize()
        supertonic = manager
        return manager
    }

    private func paradeeManager() async throws -> ParadeeManager {
        if let paradee { return paradee }
        let manager = ParadeeManager(directory: modelsDirectory)  // v1.2, int8, CPU only
        try await manager.initialize()
        paradee = manager
        return manager
    }

    private func style(_ name: String) async throws -> Supertonic3VoiceStyle {
        if let style = styles[name] { return style }
        guard let voice = Supertonic3Voice(rawValue: name) else { throw NeuralVoiceError.unknownVoice(name) }
        let style = try await Supertonic3ResourceDownloader.loadVoiceStyle(voice, directory: modelsDirectory)
        styles[name] = style
        return style
    }

    static func substring(_ text: String, _ range: Range<Int>) -> String {
        let utf16 = text.utf16
        let lower = utf16.index(utf16.startIndex, offsetBy: range.lowerBound)
        let upper = utf16.index(lower, offsetBy: range.count)
        return String(text[lower..<upper])
    }
}

public enum NeuralVoiceError: LocalizedError, Equatable {
    case unknownVoice(String)

    public var errorDescription: String? {
        switch self {
        case .unknownVoice(let id): "Unknown neural voice \(id)."
        }
    }
}

enum AudioFiles {
    /// Mono float samples to an AAC file (about 4 KB a second of speech).
    static func writeAAC(_ samples: [Float], sampleRate: Int, to url: URL) throws {
        let samples = samples.isEmpty ? [Float](repeating: 0, count: sampleRate / 10) : samples
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(samples.count, 1)))
        else { throw CocoaError(.fileWriteUnknown) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { source in
                channel.update(from: source.baseAddress!, count: samples.count)
            }
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Double(sampleRate),
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 48_000,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }
}
