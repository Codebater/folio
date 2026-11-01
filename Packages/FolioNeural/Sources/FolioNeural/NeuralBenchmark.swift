import Foundation
import FolioAudio
import FolioCore
#if os(iOS)
import os
#endif

/// Which neural models are on this device, and how much room they take.
public struct NeuralModelStore: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public func isInstalled(_ model: NeuralVoiceCatalog.Model) -> Bool {
        FileManager.default.fileExists(atPath: marker(model).path)
    }

    public var installed: Set<NeuralVoiceCatalog.Model> {
        Set(NeuralVoiceCatalog.Model.allCases.filter(isInstalled))
    }

    public func markInstalled(_ model: NeuralVoiceCatalog.Model) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: marker(model))
    }

    /// Marks a model as not ready (its files stay, so getting it back is quick).
    public func markNotInstalled(_ model: NeuralVoiceCatalog.Model) {
        try? FileManager.default.removeItem(at: marker(model))
    }

    /// Removes every downloaded model (they share some files).
    public func removeAll() throws {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    public func bytesOnDisk() -> Int64 {
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    private func marker(_ model: NeuralVoiceCatalog.Model) -> URL {
        directory.appendingPathComponent(".installed-\(model.rawValue)")
    }
}

/// Measures a neural voice on this device: load time, render speed per
/// paragraph, word-timing coverage and memory headroom. Always renders
/// afresh (its own empty cache), so the numbers are real synthesis.
public enum NeuralBenchmark {
    public struct Paragraph: Sendable, Codable {
        public var characters: Int
        public var words: Int
        public var timedWords: Int
        public var audioSeconds: Double
        public var renderSeconds: Double
        /// Render time ÷ audio time; below 1 keeps up with playback.
        public var realTimeFactor: Double { audioSeconds > 0 ? renderSeconds / audioSeconds : .infinity }
    }

    public struct Result: Sendable, Codable {
        public var voiceID: String
        public var loadSeconds: Double
        public var paragraphs: [Paragraph]
        /// Lowest memory headroom before iOS would end the app (iOS only).
        public var lowestHeadroomMB: Double?

        public var report: String {
            var lines = ["Voice \(voiceID)", String(format: "Model load: %.2f s", loadSeconds)]
            for (index, p) in paragraphs.enumerated() {
                lines.append(String(format: "¶%d: %d chars, %.1f s audio in %.2f s (RTF %.3f), %d/%d words timed",
                                    index + 1, p.characters, p.audioSeconds, p.renderSeconds, p.realTimeFactor,
                                    p.timedWords, p.words))
            }
            if let lowestHeadroomMB { lines.append(String(format: "Lowest memory headroom: %.0f MB", lowestHeadroomMB)) }
            return lines.joined(separator: "\n")
        }
    }

    public static func run(voiceID: String, texts: [String], modelsDirectory: URL, kokoroCrashMarker: URL? = nil) async throws -> Result {
        guard let voice = NeuralVoiceCatalog.voice(voiceID) else { throw NeuralVoiceError.unknownVoice(voiceID) }
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("folio-bench-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) }
        let synthesizer = FluidSpeechSynthesizer(modelsDirectory: modelsDirectory, cacheDirectory: cache,
                                                 kokoroCrashMarker: kokoroCrashMarker)
        var headroom = availableMemoryMB()

        let loadStart = ProcessInfo.processInfo.systemUptime
        try await synthesizer.prepare(voice.model)
        let loadSeconds = ProcessInfo.processInfo.systemUptime - loadStart
        headroom = minimum(headroom, availableMemoryMB())

        var paragraphs: [Paragraph] = []
        for text in texts {
            let start = ProcessInfo.processInfo.systemUptime
            let speech = try await synthesizer.synthesize(text: text, language: LanguageCode(voice.language), voiceID: voiceID)
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            headroom = minimum(headroom, availableMemoryMB())
            paragraphs.append(Paragraph(characters: text.count, words: text.split(whereSeparator: \.isWhitespace).count,
                                        timedWords: speech.words?.count ?? 0, audioSeconds: speech.duration,
                                        renderSeconds: elapsed))
        }
        await synthesizer.unload()
        return Result(voiceID: voiceID, loadSeconds: loadSeconds, paragraphs: paragraphs, lowestHeadroomMB: headroom)
    }

    public static func availableMemoryMB() -> Double? {
        #if os(iOS)
        return Double(os_proc_available_memory()) / 1_048_576
        #else
        return nil
        #endif
    }

    private static func minimum(_ a: Double?, _ b: Double?) -> Double? {
        switch (a, b) {
        case let (a?, b?): min(a, b)
        default: a ?? b
        }
    }
}
