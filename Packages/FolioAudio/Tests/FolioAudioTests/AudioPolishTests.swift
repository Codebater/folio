import Foundation
import Testing
@testable import FolioAudio

@Suite("Audio polish")
struct AudioPolishTests {
    let rate = 24_000

    /// A tone at `amplitude` for `seconds`.
    private func tone(_ amplitude: Float, seconds: Double) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { amplitude * sin(Float($0) * 2 * .pi * 220 / Float(rate)) }
    }

    private func rms(_ samples: [Float]) -> Float {
        (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }

    @Test func quietAndLoudVoicesEndUpAtOneLevel() {
        let quiet = AudioPolish.normalized(tone(0.03, seconds: 1), sampleRate: rate)
        let loud = AudioPolish.normalized(tone(0.5, seconds: 1), sampleRate: rate)
        #expect(abs(rms(quiet) - AudioPolish.targetRMS) < 0.005)
        #expect(abs(rms(loud) - AudioPolish.targetRMS) < 0.005)
        // Pauses don't count: a clip that's half silence is not made louder.
        let paused = AudioPolish.normalized(tone(0.03, seconds: 1) + [Float](repeating: 0, count: rate), sampleRate: rate)
        #expect(abs(paused.prefix(rate).map { abs($0) }.max()! - quiet.map { abs($0) }.max()!) < 0.01)
    }

    @Test func peaksNeverClip() {
        // Speech with one sharp peak: the gain stops at the peak limit.
        var samples = tone(0.02, seconds: 1)
        samples[100] = 0.8
        let out = AudioPolish.normalized(samples, sampleRate: rate)
        #expect(out.map { abs($0) }.max()! <= AudioPolish.peakLimit + 0.0001)
    }

    @Test func silenceAtTheEndsIsTrimmedAndTimingsFollow() {
        let samples = [Float](repeating: 0, count: rate / 2) + tone(0.2, seconds: 1) + [Float](repeating: 0, count: rate)
        let (trimmed, removed) = AudioPolish.trimmed(samples, sampleRate: rate)
        #expect(abs(removed - 0.46) < 0.01)  // half a second, minus the 40 ms kept
        #expect(abs(Double(trimmed.count) / Double(rate) - 1.08) < 0.01)
        let words = AudioPolish.moved([TimedWord(range: 0..<5, start: 0.5, end: 0.9), TimedWord(range: 6..<9, start: 1.4, end: 1.6)],
                                      back: removed, duration: 1.08)
        #expect(abs(words[0].start - 0.04) < 0.01 && abs(words[1].end - 1.08) < 0.01)
        // All silence stays as it is.
        #expect(AudioPolish.trimmed([Float](repeating: 0, count: 100), sampleRate: rate).samples.count == 100)
    }
}

@Suite("Chunking long sentences")
struct ChunkingTests {
    @Test func longSentencesBreakAtClausesBeforeSpaces() {
        let text = "The council, which had argued about the budget for most of the autumn and well into the winter months; "
            + "finally agreed on a plan that nobody had expected and almost everybody seemed to like in the end"
        let chunks = SpeechChunker.chunks(of: text, language: .english, maxLength: 140)
        let pieces = chunks.map { String(text.utf16Slice($0)) }
        #expect(pieces.first?.hasSuffix("winter months; ") == true || pieces.first?.hasSuffix("winter months;") == true)
        #expect(pieces.joined().replacingOccurrences(of: " ", with: "") == text.replacingOccurrences(of: " ", with: ""))
    }
}
