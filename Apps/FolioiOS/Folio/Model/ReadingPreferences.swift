import Foundation
import FolioCore

/// How lists look and behave. Every option here answers a complaint about
/// competing readers (from a review of their recent App Store reviews).
struct ReadingPreferences: Codable, Equatable {
    enum UnreadStyle: String, Codable, CaseIterable {
        /// Badges, unread counts and "mark all as read" for inbox-zero people.
        case counts
        /// No badges or counters; a "where you left off" marker instead.
        case calm
    }

    enum Density: String, Codable, CaseIterable { case comfortable, compact }

    enum SwipeAction: String, Codable, CaseIterable, Identifiable {
        case toggleRead, toggleSaved, listenLater, playNext, none
        var id: String { rawValue }

        var title: String {
            switch self {
            case .toggleRead: "Read / Unread"
            case .toggleSaved: "Save / Unsave"
            case .listenLater: "Listen later"
            case .playNext: "Play next"
            case .none: "Nothing"
            }
        }
    }

    var unreadStyle: UnreadStyle = .counts
    var density: Density = .comfortable
    /// Articles scrolled past the top of a list are marked read.
    var markReadOnScroll = false
    var leadingSwipe: SwipeAction = .toggleRead
    var trailingSwipe: SwipeAction = .toggleSaved
    var secondaryTrailingSwipe: SwipeAction = .listenLater
    var mute = MuteRules()
    /// Muted articles are also marked read (and synced), so counts stay honest.
    var muteMarksRead = true
    /// Read, unsaved, not-downloaded articles older than this are removed. 0 = never.
    var retentionDays = 45
    /// For feeds that only send a summary, fetch the article from the
    /// publisher's page (on this iPhone, like Reader view).
    var fetchFullText = true
    /// Words and names to watch for (the opposite of muting): matches lead Today.
    var watch = MuteRules()
    /// Reading one version of a story marks its copies from other feeds read.
    var markDuplicatesRead = true
    /// A "Key points" box at the top of longer articles.
    var showKeyPoints = true

    var showsCounts: Bool { unreadStyle == .counts }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ReadingPreferences()
        unreadStyle = try c.decodeIfPresent(UnreadStyle.self, forKey: .unreadStyle) ?? d.unreadStyle
        density = try c.decodeIfPresent(Density.self, forKey: .density) ?? d.density
        markReadOnScroll = try c.decodeIfPresent(Bool.self, forKey: .markReadOnScroll) ?? d.markReadOnScroll
        leadingSwipe = try c.decodeIfPresent(SwipeAction.self, forKey: .leadingSwipe) ?? d.leadingSwipe
        trailingSwipe = try c.decodeIfPresent(SwipeAction.self, forKey: .trailingSwipe) ?? d.trailingSwipe
        secondaryTrailingSwipe = try c.decodeIfPresent(SwipeAction.self, forKey: .secondaryTrailingSwipe) ?? d.secondaryTrailingSwipe
        mute = try c.decodeIfPresent(MuteRules.self, forKey: .mute) ?? d.mute
        muteMarksRead = try c.decodeIfPresent(Bool.self, forKey: .muteMarksRead) ?? d.muteMarksRead
        retentionDays = try c.decodeIfPresent(Int.self, forKey: .retentionDays) ?? d.retentionDays
        fetchFullText = try c.decodeIfPresent(Bool.self, forKey: .fetchFullText) ?? d.fetchFullText
        watch = try c.decodeIfPresent(MuteRules.self, forKey: .watch) ?? d.watch
        markDuplicatesRead = try c.decodeIfPresent(Bool.self, forKey: .markDuplicatesRead) ?? d.markDuplicatesRead
        showKeyPoints = try c.decodeIfPresent(Bool.self, forKey: .showKeyPoints) ?? d.showKeyPoints
    }
}
