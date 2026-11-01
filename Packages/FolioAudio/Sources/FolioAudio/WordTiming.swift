import Foundation
import FolioCore

/// A word of a segment's spoken text and when it is heard in the audio.
public struct TimedWord: Hashable, Sendable, Codable {
    /// UTF-16 range in the segment's spoken text.
    public var range: Range<Int>
    /// Seconds from the start of the segment's audio.
    public var start: Double
    public var end: Double

    public init(range: Range<Int>, start: Double, end: Double) {
        self.range = range
        self.start = start
        self.end = end
    }

    /// The same word in a longer text and a longer recording.
    public func shifted(characters: Int, seconds: Double) -> TimedWord {
        TimedWord(range: (range.lowerBound + characters)..<(range.upperBound + characters),
                  start: start + seconds, end: end + seconds)
    }
}

/// Words of a text with their UTF-16 ranges and a comparison key.
struct TextWord: Hashable {
    var range: Range<Int>
    /// Lower-cased, diacritics folded, letters and digits only.
    var key: String
}

enum TextWords {
    /// Whitespace-separated words with leading and trailing punctuation
    /// trimmed from their ranges. Tokens without letters or digits are dropped.
    static func words(in text: String) -> [TextWord] {
        var result: [TextWord] = []
        var current: [(scalar: Unicode.Scalar, offset: Int)] = []
        var offset = 0

        func flush() {
            defer { current.removeAll() }
            guard let first = current.firstIndex(where: { isWordScalar($0.scalar) }),
                  let last = current.lastIndex(where: { isWordScalar($0.scalar) })
            else { return }
            let lower = current[first].offset
            let upper = current[last].offset + current[last].scalar.utf16.count
            let raw = String(String.UnicodeScalarView(current[first...last].map(\.scalar)))
            let key = raw.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
                .unicodeScalars.filter(isWordScalar).map(String.init).joined()
            result.append(TextWord(range: lower..<upper, key: key))
        }

        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace {
                flush()
            } else {
                current.append((scalar, offset))
            }
            offset += scalar.utf16.count
        }
        flush()
        return result
    }

    static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isAlphabetic || scalar.properties.numericType != nil
    }
}

/// Word timings for Kokoro output.
///
/// Kokoro predicts how many acoustic frames each phoneme token lasts; the
/// audio is built from exactly those durations. Phonemes come grouped into
/// words by spaces, so each word's start and end follow from the summed
/// durations. Those words belong to Kokoro's normalized text ("$45" becomes
/// "forty five dollars"), which is matched back to our spoken text.
///
/// The result only contains words whose timing is certain. Anything that
/// can't be matched exactly (out-of-vocabulary phonemes, a different word
/// count, words Kokoro rewrote into several) gets no timing, and a segment
/// with no certain word returns nil, so the caller reports the paragraph as
/// `estimated` instead of guessing.
public enum KokoroAlignment {
    public static func wordTimings(
        spokenText: String, normalizedText: String?, phonemes: String,
        durations: [Int32], tokenCount: Int, audioDuration: Double
    ) -> [TimedWord]? {
        let scalars = Array(phonemes.unicodeScalars)
        // One chunk: BOS + one token per phoneme scalar + EOS. Anything else
        // (dropped scalars, several chunks) breaks the token-to-phoneme map.
        guard durations.count == tokenCount, tokenCount == scalars.count + 2, audioDuration > 0 else { return nil }
        let totalFrames = durations.reduce(0) { $0 + Int(max($1, 0)) }
        guard totalFrames > 0 else { return nil }
        let secondsPerFrame = audioDuration / Double(totalFrames)
        var frameStart = [Int](repeating: 0, count: durations.count + 1)
        for (index, frames) in durations.enumerated() { frameStart[index + 1] = frameStart[index] + Int(max(frames, 0)) }

        // Phoneme words: runs of non-space scalars. Runs without letters
        // (punctuation) extend the previous word.
        var groups: [(start: Double, end: Double)] = []
        var runStart: Int?
        func closeRun(at end: Int) {
            guard let start = runStart else { return }
            runStart = nil
            let hasLetters = scalars[start..<end].contains { $0.properties.isAlphabetic }
            let startTime = Double(frameStart[start + 1]) * secondsPerFrame  // token = scalar + 1 (BOS)
            let endTime = Double(frameStart[end + 1]) * secondsPerFrame
            if hasLetters {
                groups.append((startTime, endTime))
            } else if !groups.isEmpty {
                groups[groups.count - 1].end = endTime
            }
        }
        for (index, scalar) in scalars.enumerated() {
            if scalar.properties.isWhitespace { closeRun(at: index) } else if runStart == nil { runStart = index }
        }
        closeRun(at: scalars.count)

        let normalized = TextWords.words(in: normalizedText ?? spokenText)
        guard normalized.count == groups.count, !groups.isEmpty else { return nil }
        let spoken = TextWords.words(in: spokenText)
        let timed = WordAligner.align(spoken: spoken, heard: zip(normalized, groups).map { ($0.key, $1.start, $1.end) })
        return timed.isEmpty ? nil : timed
    }
}

/// Matches words someone heard (with times) to the words of our text.
enum WordAligner {
    /// Identical words match in order (longest common subsequence). Between
    /// two matches, a single spoken word that was read as one or more other
    /// words ("2026" read as "twenty twenty six") takes their whole span, and
    /// short gaps (up to three words) with the same number of words on both
    /// sides pair up in order. Without a single identical word nothing is
    /// timed: the texts can't be trusted to be the same. Everything else
    /// stays untimed.
    static func align(spoken: [TextWord], heard: [(key: String, start: Double, end: Double)]) -> [TimedWord] {
        let n = spoken.count, m = heard.count
        guard n > 0, m > 0 else { return [] }
        var table = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = !spoken[i].key.isEmpty && spoken[i].key == heard[j].key
                    ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0, j = 0
        while i < n && j < m {
            if !spoken[i].key.isEmpty && spoken[i].key == heard[j].key {
                pairs.append((i, j))
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }

        guard !pairs.isEmpty else { return [] }

        var result: [TimedWord] = []
        func fillGap(spokenRange: Range<Int>, heardRange: Range<Int>) {
            guard !spokenRange.isEmpty, !heardRange.isEmpty else { return }
            if spokenRange.count == 1 {
                result.append(TimedWord(range: spoken[spokenRange.lowerBound].range,
                                        start: heard[heardRange.lowerBound].start, end: heard[heardRange.upperBound - 1].end))
            } else if spokenRange.count == heardRange.count && spokenRange.count <= 3 {
                for (s, h) in zip(spokenRange, heardRange) {
                    result.append(TimedWord(range: spoken[s].range, start: heard[h].start, end: heard[h].end))
                }
            }
        }
        var previous = (-1, -1)
        for (s, h) in pairs {
            fillGap(spokenRange: (previous.0 + 1)..<s, heardRange: (previous.1 + 1)..<h)
            result.append(TimedWord(range: spoken[s].range, start: heard[h].start, end: heard[h].end))
            previous = (s, h)
        }
        fillGap(spokenRange: (previous.0 + 1)..<n, heardRange: (previous.1 + 1)..<m)
        return result.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }
}

/// Splits long segments into pieces a neural model can take in one go,
/// at sentence boundaries where possible.
public enum SpeechChunker {
    public static func chunks(of text: String, language: LanguageCode?, maxLength: Int = 280,
                              segmenter: SentenceSegmenting = RuleBasedSentenceSegmenter()) -> [Range<Int>] {
        let length = text.utf16.count
        guard length > maxLength else { return length == 0 ? [] : [0..<length] }
        var chunks: [Range<Int>] = []
        var current: Range<Int>?
        for sentence in segmenter.sentences(in: text, language: language) {
            if let open = current, sentence.upperBound - open.lowerBound <= maxLength {
                current = open.lowerBound..<sentence.upperBound
            } else {
                if let open = current { chunks.append(open) }
                current = sentence
            }
        }
        if let open = current { chunks.append(open) }
        if chunks.isEmpty { chunks = [0..<length] }
        // A single sentence longer than the limit is split at spaces.
        return chunks.flatMap { splitAtSpaces($0, in: text, maxLength: maxLength) }
    }

    /// The latest space in `window` that follows one of `marks`.
    static func clauseBreak(in units: [UInt16], window: ClosedRange<Int>, after marks: Set<UInt16>) -> Int? {
        var i = min(window.upperBound, units.count - 1)
        while i > window.lowerBound {
            if units[i] == 0x20, marks.contains(units[i - 1]) { return i }
            i -= 1
        }
        return nil
    }

    static func splitAtSpaces(_ range: Range<Int>, in text: String, maxLength: Int) -> [Range<Int>] {
        guard range.count > maxLength else { return [range] }
        let units = Array(text.utf16)
        var pieces: [Range<Int>] = []
        var start = range.lowerBound
        while range.upperBound - start > maxLength {
            // Kokoro's own order: after ";" or ":", then after "," or a dash,
            // then any space; a cut mid-clause sounds like a stumble.
            let window = (start + maxLength / 2)...(start + maxLength)
            var cut = clauseBreak(in: units, window: window, after: [0x3B, 0x3A])
                ?? clauseBreak(in: units, window: window, after: [0x2C, 0x2013, 0x2014])
                ?? start + maxLength
            if cut == start + maxLength {
                while cut > start + maxLength / 2 && units[cut] != 0x20 { cut -= 1 }
                if cut <= start + maxLength / 2 { cut = start + maxLength }
            }
            if (0xDC00...0xDFFF).contains(units[cut]) { cut -= 1 }  // never split a surrogate pair
            pieces.append(start..<cut)
            start = cut
            while start < range.upperBound && units[start] == 0x20 { start += 1 }
        }
        if start < range.upperBound { pieces.append(start..<range.upperBound) }
        return pieces
    }
}
