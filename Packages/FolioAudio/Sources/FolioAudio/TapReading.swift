import Foundation
import FolioCore

/// Where narration starts when the reader taps a word: at the start of the
/// tapped sentence, so it's heard whole, or at the start of its clause when
/// the sentence runs long before the word. Starting at the tapped word
/// itself drops the listener mid-thought.
public enum TapReading {
    /// Words before the tapped one past which a sentence starts at the
    /// clause instead.
    public static let longLead = 18

    /// `sentences` are ranges in the block (UTF-16), `offset` is the tap.
    /// Without `text` the clause can't be found and the sentence start wins.
    public static func start(sentences: [Range<Int>], text: String?, offset: Int) -> Int {
        guard let sentence = sentences.last(where: { $0.lowerBound <= offset }) ?? sentences.first else { return offset }
        let start = sentence.lowerBound
        guard let text else { return start }
        let units = Array(text.utf16)
        let upper = min(offset, units.count)
        guard start < upper,
              TextNormalizer.wordCount(String(decoding: units[start..<upper], as: UTF16.self)) > longLead
        else { return start }
        // The last clause break before the word: ", " "; " ": " or a spaced dash.
        var i = upper - 1
        while i > start + 1 {
            if isSpace(units[i]), isClauseMark(units[i - 1], before: i - 1, in: units) {
                var begin = i
                while begin < upper, isSpace(units[begin]) { begin += 1 }
                return begin
            }
            i -= 1
        }
        return start
    }

    /// The same, for text that isn't in a narration script yet (nothing is
    /// playing): its sentences are found here.
    public static func start(in text: String, at offset: Int, language: LanguageCode?) -> Int {
        start(sentences: RuleBasedSentenceSegmenter().sentences(in: text, language: language), text: text, offset: offset)
    }

    /// The sentence a tap falls in, for marking it on the page.
    public static func sentence(in text: String, at offset: Int, language: LanguageCode?) -> Range<Int>? {
        let sentences = RuleBasedSentenceSegmenter().sentences(in: text, language: language)
        return sentences.last { $0.lowerBound <= offset } ?? sentences.first
    }

    private static func isSpace(_ unit: UTF16.CodeUnit) -> Bool { unit == 0x20 || unit == 0xA0 || unit == 0x0A || unit == 0x09 }

    private static func isClauseMark(_ unit: UTF16.CodeUnit, before index: Int, in units: [UTF16.CodeUnit]) -> Bool {
        switch unit {
        case 0x2C, 0x3B, 0x3A: return true  // , ; :
        case 0x2013, 0x2014: return index > 0 && isSpace(units[index - 1])  // – — between spaces
        default: return false
        }
    }
}

extension SpeechScript {
    /// Whether the script knows this block (it reads it, or skips it in order).
    public func contains(blockID: String) -> Bool { blockOrder.contains(blockID) }

    /// Where to start for a tap at `position`. `blockText`, the block's text
    /// on the page, lets a long sentence start at its clause.
    public func readingStart(forTap position: SpeechPosition, blockText: String? = nil) -> SpeechPosition {
        let sentences = segments.filter { $0.blockID == position.blockID }.flatMap(\.sentences).sorted { $0.lowerBound < $1.lowerBound }
        guard !sentences.isEmpty else { return position }
        return SpeechPosition(blockID: position.blockID, offset: TapReading.start(sentences: sentences, text: blockText, offset: position.offset))
    }
}
