import Foundation
import FolioCore

public protocol SentenceSegmenting: Sendable {
    /// UTF-16 ranges of the sentences in `text`, trimmed of whitespace.
    func sentences(in text: String, language: LanguageCode?) -> [Range<Int>]
}

/// Rule-based sentence splitting that works everywhere. On Apple platforms
/// the app can swap in an `NLTokenizer`-backed segmenter; this one is the
/// fallback and the reference for tests.
public struct RuleBasedSentenceSegmenter: SentenceSegmenting {
    static let commonAbbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "mt", "vs", "e.g", "i.e", "cf", "fig", "no", "vol", "approx",
        "z.b", "bzw", "usw", "ca", "nr", "vgl", "dr", "hr", "fr",
        "sra", "srta", "ud", "uds", "p.ej", "aprox", "núm",
        "napr", "tzv", "resp", "príp", "č", "str", "atď",
    ]

    public init() {}

    public func sentences(in text: String, language: LanguageCode?) -> [Range<Int>] {
        let units = Array(text.utf16)
        var ranges: [Range<Int>] = []
        var start = 0
        var i = 0

        func isSpace(_ u: UInt16) -> Bool { u == 0x20 || u == 0x0A || u == 0x09 || u == 0xA0 }
        func isTerminal(_ u: UInt16) -> Bool {
            u == 0x2E || u == 0x21 || u == 0x3F || u == 0x2026 || u == 0x3002 || u == 0xFF01 || u == 0xFF1F
        }
        func isCloser(_ u: UInt16) -> Bool {
            [0x22, 0x27, 0x29, 0x5D, 0x201D, 0x2019, 0xBB, 0x201C].contains(u)
        }
        func emit(_ end: Int) {
            var lo = start
            var hi = end
            while lo < hi, isSpace(units[lo]) { lo += 1 }
            while hi > lo, isSpace(units[hi - 1]) { hi -= 1 }
            if hi > lo { ranges.append(lo..<hi) }
            start = end
        }

        while i < units.count {
            let u = units[i]
            if u == 0x0A {  // a line break (from <br>) always ends a sentence
                emit(i + 1)
                i += 1
                continue
            }
            guard isTerminal(u) else {
                i += 1
                continue
            }
            var j = i + 1
            while j < units.count, isTerminal(units[j]) { j += 1 }  // "?!", "..."
            while j < units.count, isCloser(units[j]) { j += 1 }
            let atEnd = j >= units.count
            if !atEnd, !isSpace(units[j]) {  // "3.14", "example.com", "U.S.A"
                i = j
                continue
            }
            if u == 0x2E, !atEnd, isAbbreviation(units, periodAt: i, next: j) {
                i = j
                continue
            }
            // “Stop!” she said. A lowercase word after the mark continues the sentence.
            if !atEnd, Self.nextWordIsLowercase(units, from: j) {
                i = j
                continue
            }
            emit(j)
            i = j
        }
        emit(units.count)
        return ranges
    }

    static func nextWordIsLowercase(_ units: [UInt16], from index: Int) -> Bool {
        var n = index
        while n < units.count, units[n] == 0x20 { n += 1 }
        guard n < units.count, let scalar = Unicode.Scalar(units[n]) else { return false }
        return scalar.properties.isLowercase
    }

    /// True when the period at `periodAt` belongs to an abbreviation or an
    /// initial rather than ending the sentence.
    private func isAbbreviation(_ units: [UInt16], periodAt: Int, next: Int) -> Bool {
        var k = periodAt
        while k > 0, units[k - 1] != 0x20, units[k - 1] != 0x0A { k -= 1 }
        let word = String(decoding: units[k..<periodAt], as: UTF16.self)
        let lowered = word.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "(\"'“‘«"))
        if Self.commonAbbreviations.contains(lowered) { return true }
        // A single capital letter is an initial ("J. R. R. Tolkien").
        if word.count == 1, let c = word.unicodeScalars.first, c.properties.isUppercase { return true }
        // Followed by a lowercase word: almost never a sentence boundary.
        var n = next
        while n < units.count, units[n] == 0x20 { n += 1 }
        if n < units.count, let scalar = Unicode.Scalar(units[n]), scalar.properties.isLowercase { return true }
        return false
    }
}
