import Foundation

/// A typed string identifier. The phantom `Kind` keeps article, feed and
/// category ids from being mixed up while they all stay plain strings on disk
/// and on the wire.
public struct Identifier<Kind>: RawRepresentable, Hashable, Comparable, Sendable, Codable,
    CustomStringConvertible, ExpressibleByStringLiteral
{
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { rawValue }
}

public enum ArticleKind {}
public enum FeedKind {}
public enum CategoryKind {}

/// Google Reader short-form item id, e.g. `"1730000000123456"` (decimal).
public typealias ArticleID = Identifier<ArticleKind>
/// Google Reader stream id of a feed, e.g. `"feed/12"`.
public typealias FeedID = Identifier<FeedKind>
/// Google Reader label stream id, e.g. `"user/-/label/Tech"`.
public typealias CategoryID = Identifier<CategoryKind>
