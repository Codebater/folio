import Foundation
import FolioCore

/// What narration leaves out. Listeners of every read-aloud app complain
/// about citation numbers, footnote markers and "Read more" boilerplate being
/// read aloud; these switches remove them from speech only, never from the page.
public struct SpeechCleanup: Hashable, Sendable, Codable {
    /// "[3]", "[12–14]", "¹²" and superscript numbers.
    public var citations: Bool
    /// "*", "†", "‡" right after a word.
    public var footnoteMarkers: Bool
    /// Whole paragraphs such as "The post … appeared first on …", "Read more", "Share this".
    public var boilerplate: Bool
    /// Emoji ("🚀", "👇🏽", flags) are never read out by name.
    public var emoji: Bool
    /// Asides in parentheses and square brackets are left out.
    public var parentheticals: Bool
    /// Image captions (or descriptions) are read, introduced as an image.
    public var captions: Bool
    /// A table or code block is mentioned ("Table skipped.") instead of
    /// passed over in silence, so nothing on the page seems to go missing.
    public var mentionSkipped: Bool
    /// Quotes are introduced and closed in words ("Quote." … "End of quote.").
    /// Off, they are set apart by pauses only.
    public var announceQuotes: Bool

    public init(citations: Bool = true, footnoteMarkers: Bool = true, boilerplate: Bool = true, emoji: Bool = true,
                parentheticals: Bool = false, captions: Bool = false, mentionSkipped: Bool = true, announceQuotes: Bool = false) {
        self.citations = citations
        self.footnoteMarkers = footnoteMarkers
        self.boilerplate = boilerplate
        self.emoji = emoji
        self.parentheticals = parentheticals
        self.captions = captions
        self.mentionSkipped = mentionSkipped
        self.announceQuotes = announceQuotes
    }

    public static let off = SpeechCleanup(citations: false, footnoteMarkers: false, boilerplate: false, emoji: false,
                                          mentionSkipped: false)

    enum CodingKeys: String, CodingKey {
        case citations, footnoteMarkers, boilerplate, emoji, parentheticals, captions, mentionSkipped, announceQuotes
    }

    // Saved settings from earlier builds lack the newer switches.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SpeechCleanup()
        citations = try c.decodeIfPresent(Bool.self, forKey: .citations) ?? d.citations
        footnoteMarkers = try c.decodeIfPresent(Bool.self, forKey: .footnoteMarkers) ?? d.footnoteMarkers
        boilerplate = try c.decodeIfPresent(Bool.self, forKey: .boilerplate) ?? d.boilerplate
        emoji = try c.decodeIfPresent(Bool.self, forKey: .emoji) ?? d.emoji
        parentheticals = try c.decodeIfPresent(Bool.self, forKey: .parentheticals) ?? d.parentheticals
        captions = try c.decodeIfPresent(Bool.self, forKey: .captions) ?? d.captions
        mentionSkipped = try c.decodeIfPresent(Bool.self, forKey: .mentionSkipped) ?? d.mentionSkipped
        announceQuotes = try c.decodeIfPresent(Bool.self, forKey: .announceQuotes) ?? d.announceQuotes
    }

    // Compiled once; NSRegularExpression is immutable and safe to share.
    static let citationPattern = try! NSRegularExpression(
        pattern: "\\s?\\[(?:\\d{1,3}|[a-z])(?:\\s*[-–,]\\s*\\d{1,3})*\\]|[\\u00B9\\u00B2\\u00B3\\u2070\\u2074-\\u2079]+")
    static let footnotePattern = try! NSRegularExpression(pattern: "(?<=[\\p{L}\\p{N}.,;:)])[*\\u2020\\u2021]+")
    static let emojiPattern = try! NSRegularExpression(
        pattern: "\\s?(?:[\\p{Extended_Pictographic}\\x{1F1E6}-\\x{1F1FF}][\\x{FE0F}\\x{200D}\\x{1F3FB}-\\x{1F3FF}\\x{1F1E6}-\\x{1F1FF}\\p{Extended_Pictographic}]*)+")
    static let parentheticalPattern = try! NSRegularExpression(pattern: "\\s?[(\\[][^()\\[\\]]{1,160}[)\\]]")
    // Phrasing: a dash or a bracket marks an aside, which a narrator sets off
    // with short pauses. Neural voices read raw dashes and brackets as
    // nothing and run the clauses together; a comma gives the pause.
    static let dashPattern = try! NSRegularExpression(pattern: "\\s*\\u2014\\s*|\\s+[\\u2013-]\\s+")
    static let asidePattern = try! NSRegularExpression(pattern: "\\s?\\(([^()]{1,160})\\)(\\s*[.,;:!?])?")
    static let boilerplatePatterns: [NSRegularExpression] = [
        "^the post .+ appeared first on .+$",
        "^(this (article|post|story) (was )?(originally )?(appeared|published|posted) (first )?(on|in|at) .+)$",
        "^(read more|continue reading|read the (full|rest of the) (story|article|post)|weiterlesen|mehr lesen|leer más|seguir leyendo|čítať (viac|ďalej)|číst (dál|více))\\W*$",
        "^(share( this)?|related( posts| articles| stories)?|you (may|might) also like|subscribe( to (our|the) newsletter)?|follow us( on .+)?)\\W*$",
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    /// Speech-only removals inside a piece of text, plus phrasing (dashes and
    /// brackets as pauses) for body text; titles and headings have their own cleanup.
    public func edits(for text: String, phrasing: Bool = true) -> [PronunciationEdit] {
        let range = NSRange(location: 0, length: text.utf16.count)
        var edits: [PronunciationEdit] = []
        if citations {
            edits += Self.citationPattern.matches(in: text, range: range).map(Self.removal)
        }
        if footnoteMarkers {
            edits += Self.footnotePattern.matches(in: text, range: range).map(Self.removal)
        }
        if emoji {
            edits += Self.emojiPattern.matches(in: text, range: range).map(Self.removal)
        }
        if parentheticals {
            edits += Self.parentheticalPattern.matches(in: text, range: range).map(Self.removal)
        } else if phrasing {
            edits += Self.asides(in: text, range: range)
        }
        guard phrasing else { return edits }
        edits += Self.dashPattern.matches(in: text, range: range).compactMap { match in
            // A dash that ends the text or a sentence needs no pause of its own.
            let after = match.range.location + match.range.length
            let units = Array(text.utf16)
            if after >= units.count || [0x2E, 0x21, 0x3F, 0x2C].contains(units[after]) { return Self.removal(match) }
            return PronunciationEdit(range: match.range.location..<after, replacement: ", ")
        }
        return edits
    }

    /// "The CEO (who joined in 2019) said yes." → "The CEO, who joined in
    /// 2019, said yes." Brackets before punctuation only open with a comma.
    static func asides(in text: String, range: NSRange) -> [PronunciationEdit] {
        asidePattern.matches(in: text, range: range).flatMap { match -> [PronunciationEdit] in
            let inner = match.range(at: 1)
            guard inner.location != NSNotFound else { return [] }
            let open = match.range.location..<inner.location
            let closeStart = inner.location + inner.length
            let closesBeforePunctuation = match.range(at: 2).location != NSNotFound
            return [PronunciationEdit(range: open, replacement: ", "),
                    PronunciationEdit(range: closeStart..<(closeStart + 1), replacement: closesBeforePunctuation ? "" : ",")]
        }
    }

    /// Superscript spans that only hold reference numbers ("1", "2,3", "[4]").
    public func edits(forSpans spans: [InlineSpanInfo], in text: String) -> [PronunciationEdit] {
        guard citations else { return [] }
        return spans.compactMap { span in
            let content = String(text.utf16Slice(span.range)).trimmingCharacters(in: .whitespaces)
            guard !content.isEmpty, content.allSatisfy({ $0.isNumber || ",-–[]".contains($0) }) else { return nil }
            return PronunciationEdit(range: span.range, replacement: "")
        }
    }

    /// True for paragraphs that are publisher boilerplate, not content.
    public func isBoilerplate(_ text: String) -> Bool {
        guard boilerplate else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 200 else { return false }
        let range = NSRange(location: 0, length: trimmed.utf16.count)
        return Self.boilerplatePatterns.contains { $0.firstMatch(in: trimmed, range: range) != nil }
    }

    static func removal(_ match: NSTextCheckingResult) -> PronunciationEdit {
        PronunciationEdit(range: match.range.location..<(match.range.location + match.range.length), replacement: "")
    }
}

/// The part of an inline span the cleanup needs, decoupled from FolioReader.
public struct InlineSpanInfo: Hashable, Sendable {
    public var range: Range<Int>
    public init(range: Range<Int>) { self.range = range }
}
