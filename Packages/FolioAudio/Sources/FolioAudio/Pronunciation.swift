import Foundation
import FolioCore

/// A rewrite of part of the display text for speech.
public struct PronunciationEdit: Hashable, Sendable {
    /// UTF-16 range in the display text.
    public var range: Range<Int>
    public var replacement: String

    public init(range: Range<Int>, replacement: String) {
        self.range = range
        self.replacement = replacement
    }
}

/// A user-defined pronunciation ("SQL" → "sequel"). With `isRegex`, the
/// written side is a regular expression and the spoken side a template
/// that may use $1, $2 (for example "(\\d+) ?km" → "$1 kilometres").
public struct PronunciationEntry: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var written: String
    public var spoken: String
    public var caseSensitive: Bool
    /// `nil` applies to every language.
    public var language: String?
    public var isRegex: Bool

    public init(written: String, spoken: String, caseSensitive: Bool = true, language: String? = nil, isRegex: Bool = false,
                id: UUID = UUID()) {
        self.id = id
        self.written = written
        self.spoken = spoken
        self.caseSensitive = caseSensitive
        self.language = language
        self.isRegex = isRegex
    }

    enum CodingKeys: String, CodingKey { case id, written, spoken, caseSensitive, language, isRegex }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        written = try c.decode(String.self, forKey: .written)
        spoken = try c.decode(String.self, forKey: .spoken)
        caseSensitive = try c.decodeIfPresent(Bool.self, forKey: .caseSensitive) ?? true
        language = try c.decodeIfPresent(String.self, forKey: .language)
        isRegex = try c.decodeIfPresent(Bool.self, forKey: .isRegex) ?? false
    }

    /// Nil if the entry is usable, otherwise why not.
    public var problem: String? {
        if written.isEmpty { return "Enter the written form." }
        guard isRegex else { return nil }
        return (try? NSRegularExpression(pattern: written)) == nil ? "That isn't a valid regular expression." : nil
    }
}

/// Rules that make narration sound natural without changing what is shown:
/// common abbreviations are expanded per language, dotted acronyms
/// ("U.S.") are read as words, URLs are read as their host name, and user
/// dictionary entries apply on top.
public struct PronunciationRules: Sendable {
    public var userEntries: [PronunciationEntry]
    public var readURLsAsHost: Bool
    /// Numbers, dates and times as words outside English (`NumberWording`),
    /// for natural voices that read digits badly. Apple voices don't need it.
    public var spellNumbers: Bool

    public init(userEntries: [PronunciationEntry] = [], readURLsAsHost: Bool = true, spellNumbers: Bool = false) {
        self.userEntries = userEntries
        self.readURLsAsHost = readURLsAsHost
        self.spellNumbers = spellNumbers
    }

    static let abbreviations: [String: [(String, String)]] = [
        "en": [("e.g.", "for example"), ("i.e.", "that is"), ("etc.", "et cetera"), ("vs.", "versus"),
               ("approx.", "approximately")],
        "de": [("z. B.", "zum Beispiel"), ("z.B.", "zum Beispiel"), ("d. h.", "das heißt"), ("d.h.", "das heißt"),
               ("u. a.", "unter anderem"), ("usw.", "und so weiter"), ("bzw.", "beziehungsweise"), ("ca.", "circa"),
               ("Nr.", "Nummer"), ("vgl.", "vergleiche"), ("Mrd.", "Milliarden"), ("Mio.", "Millionen")],
        "es": [("p. ej.", "por ejemplo"), ("etc.", "etcétera"), ("Sr.", "señor"), ("Sra.", "señora"),
               ("aprox.", "aproximadamente"), ("núm.", "número")],
        "sk": [("napr.", "napríklad"), ("tzv.", "takzvaný"), ("atď.", "a tak ďalej"), ("resp.", "respektíve"),
               ("t. j.", "to jest"), ("príp.", "prípadne"), ("č.", "číslo"), ("cca", "cirka")],
        "cs": [("např.", "například"), ("tzv.", "takzvaný"), ("atd.", "a tak dále"), ("resp.", "respektive"),
               ("tj.", "to jest"), ("č.", "číslo"), ("cca", "cirka"), ("mj.", "mimo jiné")],
    ]

    /// Edits for `text`, sorted and non-overlapping.
    public func edits(for text: String, language: LanguageCode?) -> [PronunciationEdit] {
        let units = Array(text.utf16)
        var edits: [PronunciationEdit] = []

        var dictionary: [(String, String, Bool)] = []
        if let base = language?.base, let list = Self.abbreviations[base] {
            for (written, spoken) in list {
                dictionary.append((written, spoken, true))
                // Sentence-initial capitalised form ("E.g." → "For example").
                if let first = written.first, first.isLowercase {
                    dictionary.append((written.prefix(1).uppercased() + written.dropFirst(), spoken.prefix(1).uppercased() + spoken.dropFirst(), true))
                }
            }
        }
        for entry in userEntries where (entry.language == nil || entry.language == language?.base) && entry.problem == nil {
            if entry.isRegex {
                edits += Self.regexEdits(entry, in: units)
            } else {
                dictionary.append((entry.written, entry.spoken, entry.caseSensitive))
            }
        }
        for (written, spoken, caseSensitive) in dictionary {
            for range in Self.occurrences(of: written, in: units, caseSensitive: caseSensitive) {
                // "etc." at the end of a sentence still has to end the sentence.
                let endsSentence = written.hasSuffix(".") && Self.isSentenceEnd(units, after: range.upperBound, language: language)
                edits.append(PronunciationEdit(range: range, replacement: endsSentence ? spoken + "." : spoken))
            }
        }
        edits += dottedAcronyms(units)
        if readURLsAsHost { edits += urls(units) }
        edits += SymbolWording.edits(for: text, language: language, spellNumbers: spellNumbers)
        if spellNumbers { edits += NumberWording.edits(for: text, language: language) }

        return Self.resolve(edits)
    }

    /// Sorted and non-overlapping: earliest first, and on ties the longer edit wins.
    public static func resolve(_ edits: [PronunciationEdit]) -> [PronunciationEdit] {
        let sorted = edits.sorted {
            $0.range.lowerBound != $1.range.lowerBound ? $0.range.lowerBound < $1.range.lowerBound : $0.range.count > $1.range.count
        }
        var result: [PronunciationEdit] = []
        for edit in sorted where edit.range.lowerBound >= (result.last?.range.upperBound ?? 0) { result.append(edit) }
        return result
    }

    /// What `text` sounds like after these rules (live preview in settings).
    public func spoken(_ text: String, language: LanguageCode?, cleanup: SpeechCleanup = SpeechCleanup()) -> String {
        let all = Self.resolve(edits(for: text, language: language) + cleanup.edits(for: text))
        return Self.apply(all, to: text).spoken
    }

    static func regexEdits(_ entry: PronunciationEntry, in units: [UInt16]) -> [PronunciationEdit] {
        guard let regex = try? NSRegularExpression(pattern: entry.written, options: entry.caseSensitive ? [] : [.caseInsensitive])
        else { return [] }
        let text = String(decoding: units, as: UTF16.self)
        // NSRegularExpression works in UTF-16, Folio's offset unit.
        return regex.matches(in: text, range: NSRange(location: 0, length: units.count)).compactMap { match in
            guard match.range.length > 0 else { return nil }
            let replacement = regex.replacementString(for: match, in: text, offset: 0, template: entry.spoken)
            return PronunciationEdit(range: match.range.location..<(match.range.location + match.range.length), replacement: replacement)
        }
    }

    /// Applies edits and returns the spoken text with its offset map.
    public static func apply(_ edits: [PronunciationEdit], to text: String) -> (spoken: String, map: OffsetMap) {
        let units = Array(text.utf16)
        var spoken: [UInt16] = []
        var map = OffsetMap()
        var cursor = 0
        for edit in edits where edit.range.lowerBound >= cursor && edit.range.upperBound <= units.count {
            spoken += units[cursor..<edit.range.lowerBound]
            map.appendIdentity(length: edit.range.lowerBound - cursor)
            let replacement = Array(edit.replacement.utf16)
            spoken += replacement
            map.appendReplacement(displayLength: edit.range.count, spokenLength: replacement.count)
            cursor = edit.range.upperBound
        }
        spoken += units[cursor...]
        map.appendIdentity(length: units.count - cursor)
        return (String(decoding: spoken, as: UTF16.self), map)
    }

    // MARK: Matchers

    /// End of text, or whitespace followed by an uppercase letter.
    /// In German every noun is capitalised, so only the end of the text counts.
    static func isSentenceEnd(_ units: [UInt16], after index: Int, language: LanguageCode? = nil) -> Bool {
        if index >= units.count { return true }
        if language?.base == "de" { return false }
        guard units[index] == 0x20 || units[index] == 0x0A, index + 1 < units.count,
              let next = Unicode.Scalar(units[index + 1]) else { return false }
        return next.properties.isUppercase
    }

    static func isWordUnit(_ unit: UInt16) -> Bool {
        if UTF16.isLeadSurrogate(unit) || UTF16.isTrailSurrogate(unit) { return true }
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return scalar.properties.isAlphabetic || scalar.properties.numericType != nil
    }

    static func occurrences(of needle: String, in units: [UInt16], caseSensitive: Bool) -> [Range<Int>] {
        let pattern = Array((caseSensitive ? needle : needle.lowercased()).utf16)
        guard !pattern.isEmpty, pattern.count <= units.count else { return [] }
        let haystack = caseSensitive ? units : Array(String(decoding: units, as: UTF16.self).lowercased().utf16)
        guard haystack.count == units.count else { return [] }  // lowercasing changed lengths; skip
        var result: [Range<Int>] = []
        var i = 0
        let endsWithLetter = isWordUnit(pattern[pattern.count - 1])
        while i + pattern.count <= haystack.count {
            if haystack[i] == pattern[0], Array(haystack[i..<(i + pattern.count)]) == pattern {
                let before = i == 0 || !isWordUnit(units[i - 1])
                let afterIndex = i + pattern.count
                let after = afterIndex >= units.count || !endsWithLetter || !isWordUnit(units[afterIndex])
                if before && after {
                    result.append(i..<afterIndex)
                    i = afterIndex
                    continue
                }
            }
            i += 1
        }
        return result
    }

    /// "U.S." → "US", "U.S.A." → "USA". The final period is kept when it
    /// also ends the sentence.
    func dottedAcronyms(_ units: [UInt16]) -> [PronunciationEdit] {
        var edits: [PronunciationEdit] = []
        var i = 0
        func isUpper(_ u: UInt16) -> Bool { u >= 0x41 && u <= 0x5A }
        while i < units.count {
            let boundary = i == 0 || !Self.isWordUnit(units[i - 1])
            var j = i
            var letters: [UInt16] = []
            while boundary, j + 1 < units.count, isUpper(units[j]), units[j + 1] == 0x2E {
                letters.append(units[j])
                j += 2
            }
            if letters.count >= 2, j >= units.count || !Self.isWordUnit(units[j]) {
                var spoken = String(decoding: letters, as: UTF16.self)
                // Keep a sentence stop: end of text, or space + capital letter next.
                if j >= units.count || (j + 1 < units.count && units[j] == 0x20 && isUpper(units[j + 1])) { spoken += "." }
                edits.append(PronunciationEdit(range: i..<j, replacement: spoken))
                i = j
            } else {
                i += 1
            }
        }
        return edits
    }

    func urls(_ units: [UInt16]) -> [PronunciationEdit] {
        let text = String(decoding: units, as: UTF16.self)
        var edits: [PronunciationEdit] = []
        var offset = 0
        for token in text.split(separator: " ", omittingEmptySubsequences: false) {
            let length = token.utf16.count
            defer { offset += length + 1 }
            let lower = token.lowercased()
            guard lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("www.") else { continue }
            var core = Substring(token)
            var trailing = 0
            while let last = core.last, ".,;:!?)\"'”’".contains(last) {
                trailing += String(last).utf16.count
                core = core.dropLast()
            }
            let candidate = lower.hasPrefix("www.") ? "https://" + core : String(core)
            guard let host = URL(string: candidate)?.host else { continue }
            let spoken = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            edits.append(PronunciationEdit(range: offset..<(offset + length - trailing), replacement: spoken))
        }
        return edits
    }
}

/// Money, ranges and signs written the way news sites write them, said the
/// way a newsreader says them. Neural voices read raw symbols badly ("$4.5bn"
/// as "four point five b n dollars"); Apple voices read the result just as
/// well. Languages without wording keep the text as written.
enum SymbolWording {
    struct Wording {
        var magnitudes: [String: String]
        var currencies: [String: String]
        /// Spanish says "millones de dólares"; "mil dólares" has no "de".
        var currencyJoiner: [String: String] = [:]
        var range: String
        var plus: String
    }

    static let wordings: [String: Wording] = [
        "en": Wording(magnitudes: ["bn": "billion", "billion": "billion", "m": "million", "mn": "million", "million": "million",
                                   "k": "thousand", "tn": "trillion", "trillion": "trillion"],
                      currencies: ["$": "dollars", "US$": "US dollars", "€": "euros", "£": "pounds"], range: "to", plus: "plus"),
        "de": Wording(magnitudes: ["bn": "Milliarden", "billion": "Milliarden", "m": "Millionen", "mn": "Millionen",
                                   "million": "Millionen", "k": "Tausend", "tn": "Billionen", "trillion": "Billionen"],
                      currencies: ["$": "Dollar", "US$": "US-Dollar", "€": "Euro", "£": "Pfund"], range: "bis", plus: "plus"),
        "es": Wording(magnitudes: ["bn": "mil millones", "billion": "mil millones", "m": "millones", "mn": "millones",
                                   "million": "millones", "k": "mil", "tn": "billones", "trillion": "billones"],
                      currencies: ["$": "dólares", "US$": "dólares estadounidenses", "€": "euros", "£": "libras"],
                      currencyJoiner: ["mil millones": " de", "millones": " de", "billones": " de"], range: "a", plus: "más"),
        "cs": Wording(magnitudes: [:], currencies: [:], range: "až", plus: "plus"),
        "sk": Wording(magnitudes: [:], currencies: [:], range: "až", plus: "plus"),
    ]

    // "$4.5bn", "€3 million", "US$200m", "£1.2tn".
    static let money = try! NSRegularExpression(
        pattern: "(US\\$|[$€£])\\s?(\\d+(?:[.,]\\d+)?)\\s?(bn|billion|mn|million|m|k|tn|trillion)\\b", options: [.caseInsensitive])
    // "2020–2024", "10—12": an en or em dash between numbers.
    static let range = try! NSRegularExpression(pattern: "(?<=\\d)\\s?[\\u2013\\u2014]\\s?(?=\\d)")
    // "+5 %", "+420 777": a sign before a number, not "C++5".
    static let plus = try! NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}+])\\+(?=\\d)")
    // "#WWDC" → "WWDC"; "C#" and "#1" stay.
    static let hashtag = try! NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}&#])#(?=\\p{L})")

    static func edits(for text: String, language: LanguageCode?, spellNumbers: Bool = false) -> [PronunciationEdit] {
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        func edit(_ r: NSRange, _ replacement: String) -> PronunciationEdit {
            PronunciationEdit(range: r.location..<(r.location + r.length), replacement: replacement)
        }
        var edits = hashtag.matches(in: text, range: whole).map { edit($0.range, "") }
        guard let wording = language.flatMap({ wordings[$0.base] }) else { return edits }
        for match in money.matches(in: text, range: whole) {
            let symbol = ns.substring(with: match.range(at: 1)).uppercased()
            let suffix = ns.substring(with: match.range(at: 3)).lowercased()
            guard let magnitude = wording.magnitudes[suffix], let currency = wording.currencies[symbol] else { continue }
            var amount = ns.substring(with: match.range(at: 2))
            if spellNumbers, let base = language?.base, let speller = NumberWording.spellers[base],
               let number = NumberWording.parse(amount), let words = speller.number(number, nextIsWord: true) {
                amount = words
            }
            edits.append(edit(match.range, "\(amount) \(magnitude)\(wording.currencyJoiner[magnitude] ?? "") \(currency)"))
        }
        edits += range.matches(in: text, range: whole).map { edit($0.range, " \(wording.range) ") }
        edits += plus.matches(in: text, range: whole).map { edit($0.range, "\(wording.plus) ") }
        return edits
    }
}
