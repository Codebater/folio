import Foundation
import FolioCore

/// Spoken-only clean-up of article titles. Feeds append the site's name
/// ("… | The Verge"), tag titles ("[Video]"), shout in capitals and add
/// emoji; none of that is worth hearing. Everything here is an edit on the
/// display text, so the offset map still puts highlights on the right words.
public enum TitleCleaner {
    static let separators = [" | ", " – ", " — ", " - ", " · ", " :: ", " // "]

    /// Tags that describe the format, not the story, in our languages.
    static let tags: Set<String> = [
        "video", "videos", "videa", "foto", "fotos", "photo", "photos", "fotogalerie", "gallery", "podcast", "audio",
        "live", "en vivo", "en directo", "nazivo", "updated", "update", "aktualisiert", "aktualizovano", "aktualizovane",
        "sponsored", "anzeige", "reklama", "watch", "pdf", "listen",
    ]

    public static func edits(for title: String, source: String?) -> [PronunciationEdit] {
        let units = Array(title.utf16)
        var edits: [PronunciationEdit] = []
        edits += siteName(in: title, units: units, source: source)
        edits += formatTags(in: title)
        edits += shouting(in: title)
        edits += emoji(in: title)
        return edits
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    /// "Title | Site" or "Site: Title" where Site is the feed's name.
    static func siteName(in title: String, units: [UInt16], source: String?) -> [PronunciationEdit] {
        guard let source, case let name = fold(source), name.count >= 2 else { return [] }
        func matches(_ part: String) -> Bool {
            let folded = fold(part)
            return folded.count >= 2 && (folded == name || name.contains(folded) || folded.contains(name))
                && folded.split(separator: " ").count <= 6
        }
        func words(_ part: String) -> Int { part.split(whereSeparator: \.isWhitespace).count }
        for separator in separators {
            if let range = title.range(of: separator, options: .backwards) {
                let head = String(title[..<range.lowerBound]), tail = String(title[range.upperBound...])
                if matches(tail), words(head) >= 2 {
                    return [PronunciationEdit(range: head.utf16.count..<units.count, replacement: "")]
                }
            }
            if let range = title.range(of: separator) {
                let head = String(title[..<range.lowerBound]), tail = String(title[range.upperBound...])
                if matches(head), words(tail) >= 2 {
                    return [PronunciationEdit(range: 0..<(head.utf16.count + separator.utf16.count), replacement: "")]
                }
            }
        }
        if let colon = title.range(of: ": ") {
            let head = String(title[..<colon.lowerBound]), tail = String(title[colon.upperBound...])
            if matches(head), words(tail) >= 2 {
                return [PronunciationEdit(range: 0..<(head.utf16.count + 2), replacement: "")]
            }
        }
        return []
    }

    /// "[Video]", "(Podcast)" and the like, anywhere in the title.
    static func formatTags(in title: String) -> [PronunciationEdit] {
        var edits: [PronunciationEdit] = []
        var offset = 0
        var open: (offset: Int, closer: Character)?
        var inner = ""
        for character in title {
            let width = character.utf16.count
            if let current = open {
                if character == current.closer {
                    if tags.contains(fold(inner)) {
                        edits.append(PronunciationEdit(range: current.offset..<(offset + width), replacement: ""))
                    }
                    open = nil
                } else {
                    inner.append(character)
                }
            } else if character == "[" || character == "(" {
                open = (offset, character == "[" ? "]" : ")")
                inner = ""
            }
            offset += width
        }
        return edits
    }

    /// An all-capitals title is read as a normal sentence. Short words stay
    /// as they are, so acronyms (EU, NASA, AI) keep their reading.
    static func shouting(in title: String) -> [PronunciationEdit] {
        let letters = title.unicodeScalars.filter { $0.properties.isAlphabetic }
        let upper = letters.filter { $0.properties.isUppercase }
        guard letters.count >= 12, Double(upper.count) / Double(letters.count) >= 0.8,
              title.split(whereSeparator: \.isWhitespace).count >= 3
        else { return [] }
        var edits: [PronunciationEdit] = []
        var offset = 0
        var isFirstWord = true
        for word in title.split(separator: " ", omittingEmptySubsequences: false) {
            let text = String(word)
            let wordLetters = text.filter(\.isLetter)
            if wordLetters.count >= 4, wordLetters.allSatisfy(\.isUppercase) {
                let lowered = text.lowercased()
                let replacement = isFirstWord ? lowered.prefix(1).uppercased() + lowered.dropFirst() : lowered
                edits.append(PronunciationEdit(range: offset..<(offset + text.utf16.count), replacement: replacement))
            }
            if !wordLetters.isEmpty { isFirstWord = false }
            offset += text.utf16.count + 1
        }
        return edits
    }

    /// Emoji are read out by name ("fire, fire"); in a title they're noise.
    static func emoji(in title: String) -> [PronunciationEdit] {
        var edits: [PronunciationEdit] = []
        var offset = 0
        for character in title {
            let width = character.utf16.count
            if character.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value >= 0x1F000) }) {
                edits.append(PronunciationEdit(range: offset..<(offset + width), replacement: ""))
            }
            offset += width
        }
        return edits
    }
}
