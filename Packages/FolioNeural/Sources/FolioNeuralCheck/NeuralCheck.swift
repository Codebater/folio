import Foundation
import FolioAudio
import FolioCore
import FolioNeural

/// Renders a sample paragraph with one of Folio's neural voices, on a Mac
/// (CI), and writes the audio, word timings and a summary line. It checks
/// that the model downloads, runs and gives word timings through the same
/// code the app uses. Speed on a Mac says nothing about an iPhone.
///
///     folio-neural-check <output dir> <models dir> <voice id> [noMetal|cpuOnly|standard]
///
/// One voice per process, so a crash in one model can't hide the others.
@main
struct NeuralCheck {
    static let samples: [String: String] = [
        "neural.kokoro.af_heart": "In 2026, Dr. Smith's team tested three new batteries. The results, published on Tuesday, surprised everyone: each cell lasted twice as long as the old ones.",
        "neural.kokoro.bm_george": "The city council met late on Thursday. Nobody expected the vote to be unanimous, but it was.",
        "neural.kokoro.ef_dora": "El martes, el equipo publicó sus resultados. Las baterías duraron el doble de lo esperado.",
        "neural.paradee.af_heart": "In 2026, Dr. Smith's team tested three new batteries. The results, published on Tuesday, surprised everyone: each cell lasted twice as long as the old ones.",
        "neural.paradee.bm_fable": "The city council met late on Thursday. Nobody expected the vote to be unanimous, but it was.",
        "neural.supertonic.F1.de": "Am Dienstag veröffentlichte das Team seine Ergebnisse. Die Batterien hielten doppelt so lange wie erwartet.",
        "neural.supertonic.M1.cs": "V úterý tým zveřejnil své výsledky. Baterie vydržely dvakrát déle, než se čekalo.",
        "neural.supertonic.F2.sk": "V utorok tím zverejnil svoje výsledky. Batérie vydržali dvakrát dlhšie, ako sa čakalo.",
    ]

    struct Report: Codable {
        var voiceID: String
        var routing: String
        var language: String
        var text: String
        var audioFile: String
        var audioSeconds: Double
        var renderSeconds: Double
        var words: Int
        var timedWords: Int
        var timings: [Timing]?
    }

    struct Timing: Codable {
        var word: String
        var start: Double
        var end: Double
    }

    static func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    static func main() async {
        let arguments = CommandLine.arguments
        guard arguments.count >= 4, let text = samples[arguments[3]], let voice = NeuralVoiceCatalog.voice(arguments[3]) else {
            log("usage: folio-neural-check <output dir> <models dir> <voice id> [routing]\nvoices: \(samples.keys.sorted().joined(separator: ", "))")
            exit(2)
        }
        let output = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let models = URL(fileURLWithPath: arguments[2], isDirectory: true)
        let routing = arguments.count > 4 ? FluidSpeechSynthesizer.KokoroRouting(rawValue: arguments[4]) ?? .noMetal : .noMetal
        let cache = output.appendingPathComponent("cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cache) }
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let synthesizer = FluidSpeechSynthesizer(modelsDirectory: models, cacheDirectory: cache, kokoroRouting: routing)

        log("→ \(voice.id) (\(voice.model.rawValue), routing \(routing.rawValue)): loading the model (downloads on first run)…")
        let loadStart = ProcessInfo.processInfo.systemUptime
        do {
            try await synthesizer.prepare(voice.model)
        } catch {
            finish(failure: "\(voice.id): model failed to load: \(error)", output: output)
        }
        log("  loaded in \(String(format: "%.1f", ProcessInfo.processInfo.systemUptime - loadStart)) s; rendering…")

        let start = ProcessInfo.processInfo.systemUptime
        let speech: SynthesizedSpeech
        do {
            speech = try await synthesizer.synthesize(text: text, language: LanguageCode(voice.language), voiceID: voice.id)
        } catch {
            finish(failure: "\(voice.id): rendering failed: \(error)", output: output)
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - start

        let name = "\(voice.id.replacingOccurrences(of: ".", with: "-"))-\(routing.rawValue).m4a"
        let destination = output.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.copyItem(at: speech.audio, to: destination)
        let utf16 = Array(text.utf16)
        let timings = speech.words?.map { word in
            Timing(word: String(decoding: utf16[word.range], as: UTF16.self), start: word.start, end: word.end)
        }
        let report = Report(voiceID: voice.id, routing: routing.rawValue, language: voice.language, text: text, audioFile: name,
                            audioSeconds: speech.duration, renderSeconds: elapsed,
                            words: text.split(whereSeparator: \.isWhitespace).count,
                            timedWords: speech.words?.count ?? 0, timings: timings)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(report).write(to: output.appendingPathComponent(name.replacingOccurrences(of: ".m4a", with: ".json")))

        var problems: [String] = []
        if let timings {
            if !zip(timings, timings.dropFirst()).allSatisfy({ $0.start <= $1.start }) { problems.append("timings out of order") }
            if !timings.allSatisfy({ $0.start >= 0 && $0.start < $0.end && $0.end <= speech.duration + 0.05 }) {
                problems.append("timings outside the audio")
            }
        } else if voice.model == .kokoro {
            problems.append("Kokoro gave no word timings")
        }
        let line = String(format: "| %@ | %@ | %@ | %.1f | %.1f | %d of %d | %@ |", voice.id, voice.language, routing.rawValue,
                          speech.duration, elapsed, report.timedWords, report.words,
                          problems.isEmpty ? "ok" : problems.joined(separator: "; "))
        appendSummary(line, output: output)
        log("  " + line)
        if let timings { log("  first words: " + timings.prefix(8).map { String(format: "%@ %.2f–%.2f", $0.word, $0.start, $0.end) }.joined(separator: ", ")) }
        exit(problems.isEmpty ? 0 : 1)
    }

    static func appendSummary(_ line: String, output: URL) {
        let url = output.appendingPathComponent("summary.md")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? "| Voice | Language | Routing | Audio s | Render s | Words timed | Result |\n|---|---|---|---|---|---|---|\n"
                .write(to: url, atomically: true, encoding: .utf8)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data((line + "\n").utf8))
            try? handle.close()
        }
    }

    static func finish(failure: String, output: URL) -> Never {
        appendSummary("| \(failure) |", output: output)
        log("FAIL " + failure)
        exit(1)
    }
}
