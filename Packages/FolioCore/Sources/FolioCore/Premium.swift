import Foundation

/// The App Store products. Prices are set in App Store Connect; the values
/// here are only the launch hypothesis shown before StoreKit answers.
public enum PremiumProduct: String, CaseIterable, Sendable, Codable {
    case yearly = "com.codebater.folio.premium.yearly"
    case lifetime = "com.codebater.folio.premium.lifetime"
    /// Same unlock as `lifetime`, configured with Family Sharing enabled in
    /// App Store Connect. Family Sharing cannot be turned off once enabled.
    case familyLifetime = "com.codebater.folio.premium.family"
    /// For Lifetime owners: turns their purchase into a family one. Family
    /// Sharing is enabled on this product, so family members receive it and
    /// with it Premium. Only offered to people who own `lifetime`.
    case familyUpgrade = "com.codebater.folio.premium.familyupgrade"

    public var fallbackDisplayPrice: String {
        switch self {
        case .yearly: "$6.99"
        case .lifetime: "$24.99"
        case .familyLifetime: "$39.99"
        case .familyUpgrade: "$14.99"
        }
    }

    public var isSubscription: Bool { self == .yearly }
}

/// Whether this build sells Premium. Off for 1.0: in-app purchases need the
/// Paid Apps Agreement in App Store Connect, which isn't active yet. While
/// it's off the app shows no Premium screen and hides the extras (they stay
/// locked, not free), so 1.0 is a plain free app. Turn it on for 1.1, with
/// the products submitted alongside.
public enum PremiumStore {
    public static let isOnSale = false
}

/// What Premium unlocks. Everything not listed here is free, including
/// FreshRSS sync, unlimited feeds, the standard reader, offline articles,
/// Apple voices with read-along highlighting, bookmarks and self-hosting.
public enum PremiumFeature: String, CaseIterable, Sendable, Codable {
    /// Custom theme colours and the extra typefaces.
    case advancedTypography
    /// Sentence-level highlight styles, auto-advance tuning, highlight colours.
    case advancedReadAlong
    /// Pronunciation dictionary, per-language voices, pause tuning, speeds above 2x.
    case voiceControls
    /// Smart queues ("all unread in Tech"), queue across feeds, play next.
    case listeningQueue
    /// Cached narration audio and bulk downloads (needs a neural engine).
    case offlineAudio
    /// Reading and listening statistics.
    case readingStatistics
}

public struct EntitlementState: Hashable, Sendable, Codable {
    public var activeProducts: Set<PremiumProduct>
    /// Expiry of the yearly subscription, if that is what grants Premium.
    public var subscriptionExpiresAt: Date?

    public init(activeProducts: Set<PremiumProduct> = [], subscriptionExpiresAt: Date? = nil) {
        self.activeProducts = activeProducts
        self.subscriptionExpiresAt = subscriptionExpiresAt
    }

    public static let free = EntitlementState()

    public var isPremium: Bool { !activeProducts.isEmpty }

    /// Premium shared with the family (bought as family, or upgraded).
    public var isFamily: Bool { activeProducts.contains(.familyLifetime) || activeProducts.contains(.familyUpgrade) }

    /// The Family upgrade is offered only to Lifetime owners without family.
    public var canUpgradeToFamily: Bool { activeProducts.contains(.lifetime) && !isFamily }

    public func allows(_ feature: PremiumFeature) -> Bool { isPremium }
}
