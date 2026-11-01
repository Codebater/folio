import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import FolioCore
@testable import FolioAudio

/// Replies by path; records what was asked.
private final class FakeServer: @unchecked Sendable {
    var replies: [String: (Int, Data)] = [:]
    private(set) var requests: [URLRequest] = []
    private let lock = NSLock()

    var transport: RemoteSpeechSynthesizer.Transport {
        { [self] request in
            lock.withLock { requests.append(request) }
            let path = request.url?.path ?? ""
            guard let reply = replies.first(where: { path.hasSuffix($0.key) })?.value else { return (Data(), 404) }
            return (reply.1, reply.0)
        }
    }

    func body(_ index: Int) -> [String: Any] {
        lock.withLock { (try? JSONSerialization.jsonObject(with: requests[index].httpBody ?? Data())) as? [String: Any] ?? [:] }
    }
}

/// The shape Kokoro-FastAPI 0.8 returned for this sentence on 2026-11-01 (audio shortened).
private let captioned = """
{"audio":"SUQzBAAAAAAA","audio_format":"audio/mpeg","timestamps":[
{"word":"Hello","start_time":0.0228,"end_time":0.3728},{"word":"world","start_time":0.3728,"end_time":0.9728},
{"word":".","start_time":0.9728,"end_time":1.1103},{"word":"In","start_time":1.1103,"end_time":1.2728},
{"word":"twenty","start_time":1.2728,"end_time":1.5728},{"word":"twenty-six","start_time":1.5728,"end_time":2.1978},
{"word":",","start_time":2.1978,"end_time":2.2478},{"word":"Doctor","start_time":2.2478,"end_time":2.6228},
{"word":"Smith","start_time":2.6228,"end_time":2.8978},{"word":"tested","start_time":2.8978,"end_time":3.2728},
{"word":"it","start_time":3.2728,"end_time":3.6728},{"word":".","start_time":3.6728,"end_time":3.8228}]}
"""

@Suite("Voice server")
struct VoiceServerTests {
    private func temporary() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("folio-server-test-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func addressesNormalize() {
        #expect(VoiceServer.normalizedBase("192.168.0.19:8880")?.absoluteString == "http://192.168.0.19:8880")
        #expect(VoiceServer.normalizedBase("http://voicebox:8880/v1/")?.absoluteString == "http://voicebox:8880")
        #expect(VoiceServer.normalizedBase("https://tts.example.org/v1")?.absoluteString == "https://tts.example.org")
        #expect(VoiceServer.normalizedBase("   ") == nil)
        #expect(VoiceServer.normalizedBase("ftp://host") == nil)
    }

    @Test func kokoroNamesBecomeLibraryVoices() {
        let heart = VoiceServer.voice(serverID: "af_heart")
        #expect(heart.id == "server.af_heart" && heart.name == "Heart" && heart.language == "en-US" && heart.gender == .female)
        let george = VoiceServer.voice(serverID: "bm_george")
        #expect(george.language == "en-GB" && george.gender == .male)
        #expect(VoiceServer.voice(serverID: "ef_dora").language == "es-ES")
        #expect(VoiceServer.voice(serverID: "alloy").name == "alloy")  // not Kokoro naming: kept as is
        #expect(VoiceServer.isServerVoice(heart.id) && !VoiceServer.isServerVoice("neural.kokoro.af_heart"))
    }

    @Test func listsVoicesInEitherShape() async throws {
        let server = FakeServer()
        let base = try #require(URL(string: "http://spark:8880"))
        let synthesizer = RemoteSpeechSynthesizer(base: base, apiKey: "secret", cache: SpeechAudioCache(directory: temporary()),
                                                  transport: server.transport)
        server.replies["/v1/audio/voices"] = (200, Data(#"{"voices":[{"id":"af_heart","name":"af_heart"},{"id":"ef_dora"}]}"#.utf8))
        #expect(try await synthesizer.voices() == ["af_heart", "ef_dora"])
        server.replies["/v1/audio/voices"] = (200, Data(#"{"voices":["am_adam","bf_emma"]}"#.utf8))
        #expect(try await synthesizer.voices() == ["am_adam", "bf_emma"])
        #expect(server.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
    }

    @Test func captionedSpeechGivesCertainWordTimings() async throws {
        let server = FakeServer()
        server.replies["/dev/captioned_speech"] = (200, Data(captioned.utf8))
        let directory = temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let synthesizer = RemoteSpeechSynthesizer(base: try #require(URL(string: "http://spark:8880")), apiKey: nil,
                                                  cache: SpeechAudioCache(directory: directory), transport: server.transport)
        let text = "Hello world. In 2026, Doctor Smith tested it."
        let speech = try await synthesizer.synthesize(text: text, language: .english, voiceID: "server.af_heart")
        let words = try #require(speech.words)
        let utf16 = Array(text.utf16)
        let spoken = words.map { String(decoding: utf16[$0.range], as: UTF16.self) }
        #expect(spoken == ["Hello", "world", "In", "2026", "Doctor", "Smith", "tested", "it"])
        // "2026" was read as "twenty twenty-six" and takes that whole span.
        let year = words[3]
        #expect(abs(year.start - 1.2728) < 1e-6 && abs(year.end - 2.1978) < 1e-6)
        #expect(abs(speech.duration - 3.8728) < 1e-6)  // last word + 0.2 s when the file can't be measured
        #expect(server.body(0)["voice"] as? String == "af_heart")
        #expect(server.body(0)["input"] as? String == text)
        #expect(server.body(0)["lang_code"] as? String == "a")  // the text's pronunciation rules, not the voice's
        #expect(VoiceServer.kokoroLangCode(for: .spanish, voice: "af_heart") == "e")
        #expect(VoiceServer.kokoroLangCode(for: .english, voice: "bm_george") == "b")
        #expect(VoiceServer.kokoroLangCode(for: .czech, voice: "af_heart") == nil)

        // The second request for the same text comes from the cache.
        _ = try await synthesizer.synthesize(text: text, language: .english, voiceID: "server.af_heart")
        #expect(server.requests.count == 1)
    }

    @Test func plainServersFallBackToSpeechWithoutTimings() async throws {
        let server = FakeServer()
        server.replies["/v1/audio/speech"] = (200, Data([0x49, 0x44, 0x33, 0x04]))
        let directory = temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let synthesizer = RemoteSpeechSynthesizer(base: try #require(URL(string: "http://tts.local")), apiKey: nil,
                                                  cache: SpeechAudioCache(directory: directory), transport: server.transport)
        let speech = try await synthesizer.synthesize(text: "Hello there.", language: .english, voiceID: "server.alloy")
        #expect(speech.words == nil)
        #expect(server.requests.map { $0.url?.path } == ["/dev/captioned_speech", "/v1/audio/speech"])
        _ = try await synthesizer.synthesize(text: "Another one.", language: .english, voiceID: "server.alloy")
        #expect(server.requests.last?.url?.path == "/v1/audio/speech")  // captions not asked again
        #expect(server.requests.count == 3)
    }

    @Test func errorsAreReportedPlainly() async throws {
        let server = FakeServer()
        server.replies["/dev/captioned_speech"] = (500, Data("voice not found".utf8))
        let synthesizer = RemoteSpeechSynthesizer(base: try #require(URL(string: "http://spark:8880")), apiKey: nil,
                                                  cache: SpeechAudioCache(directory: temporary()), transport: server.transport)
        await #expect(throws: VoiceServerError.http(500, "voice not found")) {
            _ = try await synthesizer.synthesize(text: "Hi.", language: nil, voiceID: "server.xx_none")
        }
        let offline = RemoteSpeechSynthesizer(base: try #require(URL(string: "http://spark:8880")), apiKey: nil,
                                              cache: SpeechAudioCache(directory: temporary()),
                                              transport: { _ in throw URLError(.cannotConnectToHost) })
        await #expect(throws: VoiceServerError.unreachable("spark")) { _ = try await offline.voices() }
    }

    @Test func routingPicksTheSynthesizerByPrefix() async throws {
        let server = FakeServer()
        server.replies["/v1/audio/speech"] = (200, Data([1, 2, 3]))
        server.replies["/dev/captioned_speech"] = (404, Data())
        let directory = temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let remote = RemoteSpeechSynthesizer(base: try #require(URL(string: "http://tts.local")), apiKey: nil,
                                             cache: SpeechAudioCache(directory: directory), transport: server.transport)
        let routing = RoutingSynthesizer([VoiceServer.prefix: remote])
        _ = try await routing.synthesize(text: "Hello.", language: .english, voiceID: "server.alloy")
        await #expect(throws: TimedSpeechError.noVoice(language: "en")) {
            _ = try await routing.synthesize(text: "Hello.", language: .english, voiceID: "neural.kokoro.af_heart")
        }
        await routing.set(nil, for: VoiceServer.prefix)
        await #expect(throws: TimedSpeechError.self) {
            _ = try await routing.synthesize(text: "Hello.", language: .english, voiceID: "server.alloy")
        }
    }
}
