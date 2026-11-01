import Foundation
import FolioCore

enum ArticleMapper {
    static func article(from item: ItemDTO) -> Article? {
        guard let short = ItemID.shortForm(item.id), let origin = item.origin else { return nil }
        let published: Date =
            if let seconds = item.published, seconds > 0 {
                Date(timeIntervalSince1970: TimeInterval(seconds))
            } else if let usec = item.timestampUsec {
                Date(timeIntervalSince1970: TimeInterval(usec) / 1_000_000)
            } else if let msec = item.crawlTimeMsec {
                Date(timeIntervalSince1970: TimeInterval(msec) / 1000)
            } else {
                Date(timeIntervalSince1970: 0)
            }
        let rawTitle = item.title.map { TextNormalizer.normalize(HTMLText.decodeEntities($0)) } ?? ""
        let author = item.author.map { TextNormalizer.normalize(HTMLText.decodeEntities($0)) }
        return Article(
            id: ArticleID(short),
            feedID: FeedID(origin.streamId),
            title: rawTitle.isEmpty ? "Untitled" : rawTitle,
            author: (author?.isEmpty ?? true) ? nil : author,
            url: item.link.flatMap(URL.init(string:)),
            contentHTML: item.html,
            publishedAt: published,
            updatedAt: item.updated.flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil },
            crawledAt: item.crawlTimeMsec.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) },
            isRead: item.isRead,
            isStarred: item.isStarred,
            enclosures: item.enclosure.compactMap { e in
                URL(string: e.href).map { Enclosure(url: $0, mimeType: e.type, length: e.length) }
            })
    }
}
