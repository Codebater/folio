import Foundation

// Wire formats of FreshRSS's Google Reader API. Decoding is lenient: numbers
// that arrive as strings (and the reverse) are accepted, and unknown fields
// are ignored, because servers and versions differ in the details.

public struct SubscriptionListDTO: Decodable, Sendable {
    public var subscriptions: [SubscriptionDTO]
}

public struct SubscriptionDTO: Decodable, Sendable {
    public var id: String
    public var title: String
    public var categories: [CategoryRefDTO]
    public var url: String?
    public var htmlUrl: String?
    public var iconUrl: String?

    enum CodingKeys: String, CodingKey { case id, title, categories, url, htmlUrl, iconUrl }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? id
        categories = try c.decodeIfPresent([CategoryRefDTO].self, forKey: .categories) ?? []
        url = try c.decodeIfPresent(String.self, forKey: .url)
        htmlUrl = try c.decodeIfPresent(String.self, forKey: .htmlUrl)
        iconUrl = try c.decodeIfPresent(String.self, forKey: .iconUrl)
    }
}

public struct CategoryRefDTO: Decodable, Sendable {
    public var id: String
    public var label: String?
}

public struct TagListDTO: Decodable, Sendable {
    public var tags: [TagDTO]
}

public struct TagDTO: Decodable, Sendable {
    public var id: String
    public var type: String?
}

public struct UnreadCountListDTO: Decodable, Sendable {
    public var unreadcounts: [UnreadCountDTO]
}

public struct UnreadCountDTO: Decodable, Sendable {
    public var id: String
    public var count: Int

    enum CodingKeys: String, CodingKey { case id, count }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        count = try c.decodeFlexibleInt(.count) ?? 0
    }
}

public struct ItemRefsDTO: Decodable, Sendable {
    public var itemRefs: [ItemRefDTO]
    public var continuation: String?

    enum CodingKeys: String, CodingKey { case itemRefs, continuation }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        itemRefs = try c.decodeIfPresent([ItemRefDTO].self, forKey: .itemRefs) ?? []
        continuation = try c.decodeFlexibleString(.continuation)
    }
}

public struct ItemRefDTO: Decodable, Sendable {
    public var id: String
}

public struct StreamContentsDTO: Decodable, Sendable {
    public var items: [ItemDTO]
    public var continuation: String?

    enum CodingKeys: String, CodingKey { case items, continuation }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([ItemDTO].self, forKey: .items) ?? []
        continuation = try c.decodeFlexibleString(.continuation)
    }
}

public struct ItemDTO: Decodable, Sendable {
    public struct Link: Decodable, Sendable {
        public var href: String
        public var type: String?
    }

    public struct Text: Decodable, Sendable {
        public var content: String
    }

    public struct Origin: Decodable, Sendable {
        public var streamId: String
        public var title: String?
        public var htmlUrl: String?
    }

    public struct EnclosureDTO: Decodable, Sendable {
        public var href: String
        public var type: String?
        public var length: Int?

        enum CodingKeys: String, CodingKey { case href, type, length }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            href = try c.decode(String.self, forKey: .href)
            type = try c.decodeIfPresent(String.self, forKey: .type)
            length = try c.decodeFlexibleInt(.length)
        }
    }

    public var id: String
    public var title: String?
    public var published: Int64?
    public var updated: Int64?
    public var crawlTimeMsec: Int64?
    public var timestampUsec: Int64?
    public var canonical: [Link]
    public var alternate: [Link]
    public var categories: [String]
    public var origin: Origin?
    public var summary: Text?
    public var content: Text?
    public var author: String?
    public var enclosure: [EnclosureDTO]

    enum CodingKeys: String, CodingKey {
        case id, title, published, updated, crawlTimeMsec, timestampUsec, canonical, alternate, categories,
             origin, summary, content, author, enclosure
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        published = try c.decodeFlexibleInt64(.published)
        updated = try c.decodeFlexibleInt64(.updated)
        crawlTimeMsec = try c.decodeFlexibleInt64(.crawlTimeMsec)
        timestampUsec = try c.decodeFlexibleInt64(.timestampUsec)
        canonical = (try? c.decodeIfPresent([Link].self, forKey: .canonical)) ?? []
        alternate = (try? c.decodeIfPresent([Link].self, forKey: .alternate)) ?? []
        categories = (try? c.decodeIfPresent([String].self, forKey: .categories)) ?? []
        origin = try? c.decodeIfPresent(Origin.self, forKey: .origin)
        summary = try? c.decodeIfPresent(Text.self, forKey: .summary)
        content = try? c.decodeIfPresent(Text.self, forKey: .content)
        author = try? c.decodeIfPresent(String.self, forKey: .author)
        enclosure = (try? c.decodeIfPresent([EnclosureDTO].self, forKey: .enclosure)) ?? []
    }

    public var html: String { content?.content ?? summary?.content ?? "" }
    public var isRead: Bool { categories.contains(StreamID.read) }
    public var isStarred: Bool { categories.contains(StreamID.starred) }
    public var link: String? { canonical.first?.href ?? alternate.first(where: { $0.type == nil || $0.type == "text/html" })?.href }
}

extension KeyedDecodingContainer {
    func decodeFlexibleInt64(_ key: Key) throws -> Int64? {
        if let value = try? decodeIfPresent(Int64.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return Int64(value) }
        if let text = try? decodeIfPresent(String.self, forKey: key) { return Int64(text) }
        return nil
    }

    func decodeFlexibleInt(_ key: Key) throws -> Int? {
        try decodeFlexibleInt64(key).map { Int(clamping: $0) }
    }

    func decodeFlexibleString(_ key: Key) throws -> String? {
        if let text = try? decodeIfPresent(String.self, forKey: key) { return text }
        if let value = try? decodeIfPresent(Int64.self, forKey: key) { return String(value) }
        return nil
    }
}
