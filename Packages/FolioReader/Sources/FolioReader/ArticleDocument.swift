import Foundation
import FolioCore

/// The stable, sanitized representation of an article.
///
/// Every block has an id (`b0`, `b1`, ...) that is used as the element id in
/// the rendered page, as the anchor for reading positions and highlights, and
/// by the speech pipeline. All offsets into `Block.text` are UTF-16 units, the
/// same unit JavaScript and `AVSpeechSynthesizer` use.
public struct ArticleDocument: Hashable, Sendable, Codable {
    public var blocks: [Block]
    public var language: LanguageCode?
    public var wordCount: Int
    public var leadImageURL: URL?
    public var excerpt: String

    public init(blocks: [Block], language: LanguageCode?, wordCount: Int, leadImageURL: URL?, excerpt: String) {
        self.blocks = blocks
        self.language = language
        self.wordCount = wordCount
        self.leadImageURL = leadImageURL
        self.excerpt = excerpt
    }

    public func block(id: String) -> Block? { blocks.first { $0.id == id } }
    public func index(of blockID: String) -> Int? { blocks.firstIndex { $0.id == blockID } }

    /// Blocks the narrator reads, in order.
    public var speakableBlocks: [Block] { blocks.filter(\.isSpeakable) }
}

public struct Block: Hashable, Sendable, Codable, Identifiable {
    public var id: String
    public var kind: BlockKind
    /// Display text with whitespace normalized exactly as rendered. For an
    /// image this is its caption, for an embed its link title.
    public var text: String
    public var spans: [InlineSpan]

    public init(id: String, kind: BlockKind, text: String, spans: [InlineSpan] = []) {
        self.id = id
        self.kind = kind
        self.text = text
        self.spans = spans
    }

    public var isSpeakable: Bool {
        guard !text.isEmpty else { return false }
        switch kind {
        case .paragraph, .heading, .quote, .listItem: return true
        case .preformatted, .image, .rule, .embed, .table: return false
        }
    }

    public var isTextual: Bool {
        switch kind {
        case .paragraph, .heading, .quote, .listItem, .preformatted: true
        default: false
        }
    }
}

public enum BlockKind: Hashable, Sendable, Codable {
    case paragraph
    case heading(level: Int)
    case quote
    case listItem(ordered: Bool, ordinal: Int, depth: Int)
    case preformatted
    case image(ImageInfo)
    case rule
    case embed(url: URL)
    case table(rows: [[String]])
}

public struct ImageInfo: Hashable, Sendable, Codable {
    public var source: URL
    public var alt: String
    public var width: Int?
    public var height: Int?

    public init(source: URL, alt: String = "", width: Int? = nil, height: Int? = nil) {
        self.source = source
        self.alt = alt
        self.width = width
        self.height = height
    }
}

public struct InlineSpan: Hashable, Sendable, Codable {
    public var start: Int
    public var end: Int
    public var style: InlineStyle

    public init(start: Int, end: Int, style: InlineStyle) {
        self.start = start
        self.end = end
        self.style = style
    }
}

public enum InlineStyle: Hashable, Sendable, Codable {
    case emphasis
    case strong
    case code
    case link(URL)
    case superscript
    case `subscript`
    case strikethrough
    case mark
}
