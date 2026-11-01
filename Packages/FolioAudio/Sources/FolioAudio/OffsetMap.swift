import Foundation

/// Maps offsets between the text a speech engine reads (`spoken`) and the
/// text on screen (`display`). They differ wherever a pronunciation rule
/// rewrote something ("e.g." → "for example", a URL → its host name).
///
/// The map is a list of pieces. Identity pieces map character for
/// character; replacement pieces map their whole spoken run onto their whole
/// display run, so a word inside an expansion highlights the original token.
/// All offsets are UTF-16 code units.
public struct OffsetMap: Hashable, Sendable {
    struct Piece: Hashable, Sendable {
        var spokenStart: Int
        var spokenLength: Int
        var displayStart: Int
        var displayLength: Int
        var isIdentity: Bool

        var spokenEnd: Int { spokenStart + spokenLength }
        var displayEnd: Int { displayStart + displayLength }
    }

    private(set) var pieces: [Piece] = []
    public private(set) var spokenLength = 0
    public private(set) var displayLength = 0

    public init() {}

    public static func identity(length: Int) -> OffsetMap {
        var map = OffsetMap()
        map.appendIdentity(length: length)
        return map
    }

    public mutating func appendIdentity(length: Int) {
        guard length > 0 else { return }
        if var last = pieces.last, last.isIdentity {
            last.spokenLength += length
            last.displayLength += length
            pieces[pieces.count - 1] = last
        } else {
            pieces.append(Piece(spokenStart: spokenLength, spokenLength: length, displayStart: displayLength,
                                displayLength: length, isIdentity: true))
        }
        spokenLength += length
        displayLength += length
    }

    public mutating func appendReplacement(displayLength replaced: Int, spokenLength spoken: Int) {
        guard replaced > 0 || spoken > 0 else { return }
        pieces.append(Piece(spokenStart: spokenLength, spokenLength: spoken, displayStart: displayLength,
                            displayLength: replaced, isIdentity: false))
        spokenLength += spoken
        displayLength += replaced
    }

    /// The display range covered by a spoken range. Empty input ranges are
    /// treated as one character so a caret position still maps somewhere.
    public func displayRange(forSpoken range: Range<Int>) -> Range<Int> {
        guard !pieces.isEmpty else { return 0..<0 }
        let lo = min(max(range.lowerBound, 0), max(spokenLength - 1, 0))
        let hi = max(min(range.upperBound, spokenLength), lo + 1)

        guard let first = pieces.firstIndex(where: { $0.spokenEnd > lo }) else {
            return displayLength..<displayLength
        }
        let last = pieces.lastIndex(where: { $0.spokenStart < hi }) ?? first

        let a = pieces[first]
        let start = a.isIdentity ? a.displayStart + (lo - a.spokenStart) : a.displayStart
        let b = pieces[max(first, last)]
        let end = b.isIdentity ? b.displayStart + min(hi - b.spokenStart, b.displayLength) : b.displayEnd
        return start..<max(start, end)
    }

    /// The spoken offset where display offset `offset` begins. Offsets inside
    /// a replacement map to the start of its spoken text.
    public func spokenOffset(forDisplay offset: Int) -> Int {
        if offset <= 0 { return 0 }
        guard let piece = pieces.first(where: { $0.displayEnd > offset }) else { return spokenLength }
        return piece.isIdentity ? piece.spokenStart + (offset - piece.displayStart) : piece.spokenStart
    }
}
