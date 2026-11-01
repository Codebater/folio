import Foundation

/// A place on the player's progress line where the title, a heading or a
/// paragraph starts.
public struct SpeechMark: Equatable, Sendable {
    /// The first segment of the block.
    public var segment: Int
    /// How far into the script it starts, 0...1.
    public var fraction: Double
    public var isHeading: Bool
    public var isTitle: Bool

    public init(segment: Int, fraction: Double, isHeading: Bool = false, isTitle: Bool = false) {
        self.segment = segment
        self.fraction = fraction
        self.isHeading = isHeading
        self.isTitle = isTitle
    }
}

extension SpeechScript {
    /// One mark where each block starts, for a progress line that shows the
    /// article's shape. Spoken-only announcements get none: they aren't on
    /// the page, so there is nothing to jump to.
    public var marks: [SpeechMark] {
        var result: [SpeechMark] = []
        var previous: String?
        for (index, segment) in segments.enumerated() where !segment.isAnnouncement {
            if segment.blockID != previous {
                result.append(SpeechMark(segment: index, fraction: progress(segment: index, spokenOffset: 0),
                                         isHeading: segment.isHeading && segment.blockID != Self.titleBlockID,
                                         isTitle: segment.blockID == Self.titleBlockID))
            }
            previous = segment.blockID
        }
        return result
    }
}

extension Array where Element == SpeechMark {
    /// The block a drag along the line lands on: the last one starting at or
    /// before `fraction`, or the first when the finger is before them all.
    public func mark(at fraction: Double) -> SpeechMark? {
        last { $0.fraction <= fraction + 1e-9 } ?? first
    }

    /// "Paragraph 3 of 12" for the block containing `segment`. Headings count
    /// as paragraphs; the title doesn't, and gives nil.
    public func paragraph(containing segment: Int) -> (index: Int, count: Int)? {
        let body = filter { !$0.isTitle }
        guard let current = last(where: { $0.segment <= segment }), !current.isTitle,
              let index = body.lastIndex(where: { $0.segment <= segment }) else { return nil }
        return (index + 1, body.count)
    }
}
