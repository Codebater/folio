import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import FolioCore

/// The user's own speech server, like BookOrbit's text-to-speech providers:
/// Kokoro-FastAPI, or any server with an OpenAI-compatible
/// `/v1/audio/speech`. Folio never runs one. Text goes only to the address
/// the user entered, and the server's owner pays for it.
public enum VoiceServer {
    public static let prefix = "server."
    public static let engineID = "server"

    public static func isServerVoice(_ id: String) -> Bool { id.hasPrefix(prefix) }

    /// "spark:8880", "http://host:8880/v1/" → "http://host:8880". BookOrbit
    /// addresses end in /v1, so both forms work.
    public static func normalizedBase(_ text: String) -> URL? {
        var address = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return nil }
        if !address.contains("://") { address = "http://" + address }
        while address.hasSuffix("/") { address.removeLast() }
        if address.hasSuffix("/v1") { address.removeLast(3) }
        guard let url = URL(string: address), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host != nil
        else { return nil }
        return url
    }

    /// Kokoro voice names start with a language letter and a gender letter:
    /// `af_heart` is American English, female.
    static let kokoroLanguages: [Character: String] = [
        "a": "en-US", "b": "en-GB", "e": "es-ES", "f": "fr-FR", "h": "hi-IN", "i": "it-IT", "j": "ja-JP", "p": "pt-BR",
        "z": "zh-CN",
    ]

    /// Kokoro's pronunciation pipeline for the text's language. Sent with
    /// every request, so the text decides how words sound, not the voice:
    /// English through the Spanish pipeline is unintelligible, while English
    /// read by a Spanish voice is merely accented. Nil for languages Kokoro
    /// has no pipeline for.
    public static func kokoroLangCode(for language: LanguageCode?, voice: String) -> String? {
        switch language?.base {
        case "en": voice.hasPrefix("b") ? "b" : "a"
        case "es": "e"
        case "fr": "f"
        case "hi": "h"
        case "it": "i"
        case "ja": "j"
        case "pt": "p"
        case "zh": "z"
        default: nil
        }
    }

    /// A Voice Library entry for a voice on the server.
    public static func voice(serverID: String) -> SpeechVoice {
        let parts = serverID.split(separator: "_", maxSplits: 1)
        var language = "en-US"
        var gender = SpeechVoice.Gender.unspecified
        var name = serverID
        if parts.count == 2, parts[0].count == 2, let code = kokoroLanguages[parts[0].first!] {
            language = code
            gender = parts[0].last == "f" ? .female : (parts[0].last == "m" ? .male : .unspecified)
            name = parts[1].replacingOccurrences(of: "_", with: " ").capitalized
        }
        return SpeechVoice(id: prefix + serverID, name: name, language: language, quality: .neural, engineID: engineID,
                           gender: gender)
    }
}

public enum VoiceServerError: LocalizedError, Equatable {
    case unreachable(String)
    case http(Int, String)
    case badResponse

    public var errorDescription: String? {
        switch self {
        case .unreachable(let host): "Your voice server at \(host) didn't answer."
        case .http(let code, let body): "Your voice server answered with error \(code)\(body.isEmpty ? "" : ": \(body)")."
        case .badResponse: "Your voice server sent something Folio couldn't read."
        }
    }
}

/// Speech from the user's server. Word timings come from Kokoro-FastAPI's
/// `/dev/captioned_speech` and are matched to the spoken text with the same
/// rules as on-device Kokoro (only certain matches). Servers without that
/// endpoint fall back to `/v1/audio/speech` and get paragraph tinting.
/// Rendered audio is cached on the device, so a paragraph is fetched once.
public actor RemoteSpeechSynthesizer: SpeechSynthesizing {
    /// Sends a request; returns the body and HTTP status.
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, Int)

    public let base: URL
    private let apiKey: String?
    private let cache: SpeechAudioCache
    private let scratch: URL
    private let transport: Transport
    /// Audio length for files the server sent; the app measures with AVAudioFile.
    private let measure: @Sendable (URL) -> Double?
    private var captionsUnsupported = false

    public init(base: URL, apiKey: String?, cache: SpeechAudioCache,
                scratch: URL = FileManager.default.temporaryDirectory.appendingPathComponent("folio-server", isDirectory: true),
                transport: @escaping Transport = RemoteSpeechSynthesizer.urlSession,
                measure: @escaping @Sendable (URL) -> Double? = { _ in nil }) {
        self.base = base
        self.apiKey = (apiKey?.isEmpty ?? true) ? nil : apiKey
        self.cache = cache
        self.scratch = scratch
        self.transport = transport
        self.measure = measure
    }

    /// Voice ids the server offers ("af_heart", …).
    public func voices() async throws -> [String] {
        let (data, status) = try await send(path: "v1/audio/voices", body: nil)
        guard status == 200 else { throw VoiceServerError.http(status, Self.snippet(data)) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let list = json["voices"] as? [Any]
        else { throw VoiceServerError.badResponse }
        // Kokoro-FastAPI sends either names or {"id", "name"} objects, depending on version.
        return list.compactMap { ($0 as? String) ?? (($0 as? [String: Any])?["id"] as? String) }
    }

    public func synthesize(text: String, language: LanguageCode?, voiceID: String) async throws -> SynthesizedSpeech {
        let voice = String(voiceID.dropFirst(VoiceServer.prefix.count))
        let langCode = VoiceServer.kokoroLangCode(for: language, voice: voice)
        let key = SpeechAudioCache.key(engine: "server:\(base.absoluteString):\(langCode ?? "-")", voiceID: voice, text: text)
        if let cached = await cache.lookup(key: key, text: text) { return cached }

        var audio: Data
        var format = "audio/mpeg"
        var words: [TimedWord]?
        var lastEnd: Double?
        var request: [String: Any] = ["model": "kokoro", "input": text, "voice": voice, "response_format": "mp3", "stream": false]
        if let langCode { request["lang_code"] = langCode }
        if !captionsUnsupported {
            let (data, status) = try await send(path: "dev/captioned_speech", body: request)
            if status == 200 {
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let encoded = json["audio"] as? String, let decoded = Data(base64Encoded: encoded)
                else { throw VoiceServerError.badResponse }
                audio = decoded
                format = json["audio_format"] as? String ?? format
                let stamps = (json["timestamps"] as? [[String: Any]]) ?? []
                let heard: [(key: String, start: Double, end: Double)] = stamps.compactMap { stamp in
                    guard let word = stamp["word"] as? String, let start = Self.number(stamp["start_time"]),
                          let end = Self.number(stamp["end_time"]), let key = TextWords.words(in: word).first?.key, !key.isEmpty
                    else { return nil }
                    return (key, start, end)
                }
                lastEnd = heard.last?.end
                let aligned = WordAligner.align(spoken: TextWords.words(in: text), heard: heard)
                words = aligned.isEmpty ? nil : aligned
                return try await store(audio, format: format, key: key, text: text, words: words, lastEnd: lastEnd)
            }
            guard [404, 405, 501].contains(status) else { throw VoiceServerError.http(status, Self.snippet(data)) }
            captionsUnsupported = true  // not Kokoro-FastAPI: plain speech from now on
        }
        var plain = request
        plain["lang_code"] = nil  // plain OpenAI-style servers may reject unknown fields
        plain.removeValue(forKey: "stream")
        let (data, status) = try await send(path: "v1/audio/speech", body: plain)
        guard status == 200 else { throw VoiceServerError.http(status, Self.snippet(data)) }
        audio = data
        return try await store(audio, format: format, key: key, text: text, words: nil, lastEnd: nil)
    }

    private func store(_ audio: Data, format: String, key: String, text: String, words: [TimedWord]?,
                       lastEnd: Double?) async throws -> SynthesizedSpeech {
        guard !audio.isEmpty else { throw VoiceServerError.badResponse }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let ext = format.contains("wav") ? "wav" : (format.contains("aac") || format.contains("mp4") ? "m4a" : "mp3")
        let file = scratch.appendingPathComponent(UUID().uuidString + "." + ext)
        try audio.write(to: file)
        let duration = measure(file) ?? lastEnd.map { $0 + 0.2 } ?? 0
        return try await cache.store(key: key, text: text, audio: file, duration: duration, words: words)
    }

    private func send(path: String, body: [String: Any]?) async throws -> (Data, Int) {
        var request = URLRequest(url: base.appendingPathComponent(path), timeoutInterval: 60)
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        if let apiKey { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        do {
            return try await transport(request)
        } catch {
            throw VoiceServerError.unreachable(base.host ?? base.absoluteString)
        }
    }

    static func number(_ value: Any?) -> Double? {
        (value as? Double) ?? (value as? Int).map(Double.init) ?? (value as? NSNumber)?.doubleValue
    }

    static func snippet(_ data: Data) -> String {
        String(String(decoding: data.prefix(160), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public static let urlSession: Transport = { request in
        try await withCheckedThrowingContinuation { continuation in
            URLSession.shared.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (data ?? Data(), (response as? HTTPURLResponse)?.statusCode ?? 0))
                }
            }.resume()
        }
    }
}

/// Sends each voice to its own synthesizer by id prefix (`neural.`, `server.`).
public actor RoutingSynthesizer: SpeechSynthesizing {
    private var routes: [String: any SpeechSynthesizing]

    public init(_ routes: [String: any SpeechSynthesizing] = [:]) { self.routes = routes }

    public func set(_ synthesizer: (any SpeechSynthesizing)?, for prefix: String) { routes[prefix] = synthesizer }

    public func synthesize(text: String, language: LanguageCode?, voiceID: String) async throws -> SynthesizedSpeech {
        guard let route = routes.first(where: { voiceID.hasPrefix($0.key) })?.value else {
            throw TimedSpeechError.noVoice(language: language?.base)
        }
        return try await route.synthesize(text: text, language: language, voiceID: voiceID)
    }
}
