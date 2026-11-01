import Foundation

/// Text clean-up shared by the HTML parser, the speech pipeline and plain
/// strings such as titles.
///
/// Offsets everywhere in Folio are UTF-16 code units. That is what
/// `NSString`, `AVSpeechSynthesizer` ranges and JavaScript strings all count,
/// so a range computed here lines up with the web view and the speech engine
/// without conversion.
public enum TextNormalizer {
    /// Invisible characters that only get in the way of reading and speech:
    /// soft hyphen, zero-width space, BOM / zero-width no-break space, word
    /// joiner and the object replacement character. ZWJ and ZWNJ stay because
    /// emoji sequences and several scripts need them.
    public static func isDroppable(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00AD, 0x200B, 0xFEFF, 0x2060, 0xFFFC: return true
        case 0x0000...0x0008, 0x000B, 0x000E...0x001F, 0x007F: return true  // C0 controls except tab/LF/FF/CR
        default: return false
        }
    }

    /// Whitespace that HTML collapses. A no-break space is deliberately not
    /// in this set, matching browsers.
    public static func isCollapsibleWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x20, 0x09, 0x0A, 0x0C, 0x0D, 0x2028, 0x2029: return true
        default: return false
        }
    }

    /// NFC, invisible characters dropped, whitespace runs collapsed to one
    /// space, ends trimmed.
    public static func normalize(_ text: some StringProtocol) -> String {
        let composed = String(text).precomposedStringWithCanonicalMapping
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in composed.unicodeScalars {
            if isDroppable(scalar) { continue }
            if isCollapsibleWhitespace(scalar) {
                pendingSpace = !out.isEmpty
                continue
            }
            if pendingSpace {
                out.append(" ")
                pendingSpace = false
            }
            out.append(scalar)
        }
        return String(out)
    }

    /// Number of words, counting CJK ideographs and kana one per character so
    /// reading-time estimates stay sane for languages without spaces.
    public static func wordCount(_ text: some StringProtocol) -> Int {
        var count = 0
        var inWord = false
        for scalar in String(text).unicodeScalars {
            if isCJK(scalar) {
                count += 1
                inWord = false
            } else if scalar.properties.isAlphabetic || scalar.properties.numericType != nil {
                if !inWord {
                    count += 1
                    inWord = true
                }
            } else if scalar == "'" || scalar == "\u{2019}" || scalar == "-" {
                continue  // don't split "don't" or "well-known"
            } else {
                inWord = false
            }
        }
        return count
    }

    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F: return true
        default: return false
        }
    }
}

extension String {
    /// Length in UTF-16 code units, Folio's offset unit.
    @inlinable public var utf16Length: Int { utf16.count }

    /// Substring addressed by UTF-16 offsets. Offsets that split a surrogate
    /// pair are moved outwards so the result is always valid.
    public func utf16Slice(_ range: Range<Int>) -> Substring {
        let lower = max(0, range.lowerBound)
        let upper = max(lower, range.upperBound)
        var offset = 0
        var start: String.Index?
        var end: String.Index?
        var i = unicodeScalars.startIndex
        while i < unicodeScalars.endIndex {
            let width = unicodeScalars[i].utf16.count
            if start == nil && offset + width > lower { start = i }
            if offset >= upper {
                end = i
                break
            }
            offset += width
            i = unicodeScalars.index(after: i)
        }
        let s = start ?? endIndex
        return self[s..<max(s, end ?? endIndex)]
    }

    /// UTF-16 offset of a string index.
    public func utf16Offset(of index: String.Index) -> Int {
        utf16.distance(from: utf16.startIndex, to: index)
    }
}
