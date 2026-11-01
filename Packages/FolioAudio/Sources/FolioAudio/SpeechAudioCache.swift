import Foundation
import FolioCore

/// Rendered narration on disk, for this user on this device only. Never
/// shared between users: the audio is a reading of a publisher's article.
///
/// An entry is keyed by everything that changes the sound (engine version,
/// voice, exact text) and stores the text itself, so a hash collision can
/// never play the wrong words. Least recently used entries go first when the
/// cache grows past its limit.
public actor SpeechAudioCache {
    struct Entry: Codable {
        var text: String
        var audioFile: String
        var duration: Double
        var words: [TimedWord]?
    }

    public let directory: URL
    public var maxBytes: Int64

    public init(directory: URL, maxBytes: Int64 = 600_000_000) {
        self.directory = directory
        self.maxBytes = maxBytes
    }

    /// Stable across launches and platforms (FNV-1a, 64 bit).
    public static func key(engine: String, voiceID: String, text: String) -> String {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in "\(engine)\u{1F}\(voiceID)\u{1F}\(text)".utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
    }

    public func lookup(key: String, text: String) -> SynthesizedSpeech? {
        let meta = metaURL(key)
        guard let data = try? Data(contentsOf: meta), let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.text == text
        else { return nil }
        let audio = directory.appendingPathComponent(entry.audioFile)
        guard FileManager.default.fileExists(atPath: audio.path) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: meta.path)
        return SynthesizedSpeech(audio: audio, duration: entry.duration, words: entry.words)
    }

    /// Moves `audio` (a finished file) into the cache.
    @discardableResult
    public func store(key: String, text: String, audio: URL, duration: Double, words: [TimedWord]?) throws -> SynthesizedSpeech {
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = key + (audio.pathExtension.isEmpty ? "" : "." + audio.pathExtension)
        let destination = directory.appendingPathComponent(name)
        try? files.removeItem(at: destination)
        try files.moveItem(at: audio, to: destination)
        let entry = Entry(text: text, audioFile: name, duration: duration, words: words)
        try JSONEncoder().encode(entry).write(to: metaURL(key), options: .atomic)
        prune()
        return SynthesizedSpeech(audio: destination, duration: duration, words: words)
    }

    public func totalBytes() -> Int64 {
        files().reduce(0) { $0 + $1.size }
    }

    public func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Removes least recently used entries until the cache fits `maxBytes`.
    public func prune() {
        var total = totalBytes()
        guard total > maxBytes else { return }
        let metas = files().filter { $0.url.pathExtension == "json" }.sorted { $0.modified < $1.modified }
        for meta in metas where total > maxBytes {
            let key = meta.url.deletingPathExtension().lastPathComponent
            for file in files() where file.url.deletingPathExtension().lastPathComponent == key {
                try? FileManager.default.removeItem(at: file.url)
                total -= file.size
            }
        }
    }

    private func metaURL(_ key: String) -> URL { directory.appendingPathComponent(key + ".json") }

    private func files() -> [(url: URL, size: Int64, modified: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return (url, Int64(values?.fileSize ?? 0), values?.contentModificationDate ?? .distantPast)
        }
    }
}

/// The downloadable neural voices Folio offers. Ids are
/// `neural.kokoro.<voice>` and `neural.supertonic.<style>.<language>`.
public enum NeuralVoiceCatalog {
    public static let engineID = "neural"
    public static let prefix = "neural."

    public enum Model: String, Sendable, CaseIterable {
        /// Kokoro-82M (Apache-2.0): English and Spanish, with word timing.
        case kokoro
        /// Supertonic-3 (OpenRAIL-M): all five languages, no word timing.
        case supertonic
        /// Paradee-8M (Apache-2.0): Kokoro distilled to 8M parameters, English
        /// only, an 11 MB download that runs on the CPU (safe with the screen
        /// locked, clear of the Neural Engine bugs). No word timing.
        case paradee

        /// Gives word-by-word timing; the others are shown sentence by sentence.
        public var hasWordTimings: Bool { self == .kokoro }
    }

    public struct Voice: Hashable, Sendable {
        public var id: String
        public var model: Model
        /// The model's own voice name ("af_heart", "F1").
        public var modelVoice: String
        public var language: String
        public var name: String
        public var gender: SpeechVoice.Gender
    }

    public static func isNeural(_ id: String) -> Bool { id.hasPrefix(prefix) }

    public static let all: [Voice] = {
        let kokoro: [(String, String, String, SpeechVoice.Gender)] = [
            ("af_heart", "Heart", "en-US", .female), ("af_bella", "Bella", "en-US", .female),
            ("am_michael", "Michael", "en-US", .male), ("bf_emma", "Emma", "en-GB", .female),
            ("bm_george", "George", "en-GB", .male), ("ef_dora", "Dora", "es-ES", .female),
            ("em_alex", "Alex", "es-ES", .male),
        ]
        let styles: [(String, String, SpeechVoice.Gender)] = [
            ("F1", "Ivy", .female), ("F2", "Nora", .female), ("M1", "Leo", .male), ("M2", "Max", .male),
        ]
        let supertonicLanguages = ["cs-CZ", "sk-SK", "de-DE", "en-US", "es-ES"]
        let paradee: [(String, String, String, SpeechVoice.Gender)] = [
            ("af_heart", "Heart Lite", "en-US", .female), ("am_puck", "Puck", "en-US", .male),
            ("bf_isabella", "Isabella", "en-GB", .female), ("bm_fable", "Fable", "en-GB", .male),
        ]
        return kokoro.map { Voice(id: prefix + "kokoro." + $0.0, model: .kokoro, modelVoice: $0.0, language: $0.2, name: $0.1, gender: $0.3) }
            + supertonicLanguages.flatMap { language in
                styles.map { style in
                    Voice(id: "\(prefix)supertonic.\(style.0).\(LanguageCode(language).base)", model: .supertonic,
                          modelVoice: style.0, language: language, name: style.1, gender: style.2)
                }
            }
            + paradee.map { Voice(id: prefix + "paradee." + $0.0, model: .paradee, modelVoice: $0.0, language: $0.2, name: $0.1, gender: $0.3) }
    }()

    public static func voice(_ id: String) -> Voice? { all.first { $0.id == id } }

    /// Voice Library entries; `installed` says which models are downloaded.
    public static func speechVoices(installed: Set<Model>) -> [SpeechVoice] {
        all.map { voice in
            SpeechVoice(id: voice.id, name: voice.name, language: voice.language, quality: .neural, engineID: engineID,
                        isInstalled: installed.contains(voice.model), gender: voice.gender)
        }
    }
}
