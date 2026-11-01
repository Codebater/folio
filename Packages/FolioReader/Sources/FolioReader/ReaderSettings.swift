import Foundation
import FolioCore

/// A colour as `#RRGGBB` so themes stay portable and Codable.
public struct ThemeColor: Hashable, Sendable, Codable, CustomStringConvertible {
    public var hex: String

    public init(_ hex: String) {
        let trimmed = hex.trimmingCharacters(in: .whitespaces).uppercased()
        self.hex = trimmed.hasPrefix("#") ? trimmed : "#" + trimmed
    }

    public var rgb: (red: Double, green: Double, blue: Double) {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }

    /// WCAG relative luminance.
    public var luminance: Double {
        func channel(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let (r, g, b) = rgb
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    public func contrast(with other: ThemeColor) -> Double {
        let (a, b) = (luminance, other.luminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    public var description: String { hex }

    public init(red: Double, green: Double, blue: Double) {
        func byte(_ c: Double) -> Int { Int((min(max(c, 0), 1) * 255).rounded()) }
        self.init(String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue)))
    }

    /// Hue, saturation and brightness in 0...1 (hue wraps).
    public init(hue: Double, saturation: Double, brightness: Double) {
        let h = (hue.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) * 6
        let chroma = brightness * saturation
        let x = chroma * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let m = brightness - chroma
        let (r, g, b): (Double, Double, Double)
        switch Int(h) {
        case 0: (r, g, b) = (chroma, x, 0)
        case 1: (r, g, b) = (x, chroma, 0)
        case 2: (r, g, b) = (0, chroma, x)
        case 3: (r, g, b) = (0, x, chroma)
        case 4: (r, g, b) = (x, 0, chroma)
        default: (r, g, b) = (chroma, 0, x)
        }
        self.init(red: r + m, green: g + m, blue: b + m)
    }

    /// Hue in 0..<1; 0 for greys.
    public var hue: Double {
        let (r, g, b) = rgb
        let maxC = max(r, g, b), delta = maxC - min(r, g, b)
        guard delta > 0 else { return 0 }
        let sector: Double
        if maxC == r {
            sector = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
        } else if maxC == g {
            sector = (b - r) / delta + 2
        } else {
            sector = (r - g) / delta + 4
        }
        return ((sector / 6) + 1).truncatingRemainder(dividingBy: 1)
    }

    /// This colour moved `fraction` of the way towards `other`.
    public func mixed(with other: ThemeColor, _ fraction: Double) -> ThemeColor {
        let (a, b) = (rgb, other.rgb)
        return ThemeColor(red: a.red + (b.red - a.red) * fraction, green: a.green + (b.green - a.green) * fraction,
                          blue: a.blue + (b.blue - a.blue) * fraction)
    }
}

public struct ReadingTheme: Hashable, Sendable, Codable, Identifiable {
    public var id: String
    public var name: String
    public var background: ThemeColor
    public var text: ThemeColor
    public var secondaryText: ThemeColor
    public var accent: ThemeColor
    /// Background behind the word being spoken.
    public var spokenWord: ThemeColor
    /// Tint behind the paragraph being spoken.
    public var spokenBlock: ThemeColor
    public var isDark: Bool

    public init(id: String, name: String, background: ThemeColor, text: ThemeColor, secondaryText: ThemeColor,
                accent: ThemeColor, spokenWord: ThemeColor, spokenBlock: ThemeColor, isDark: Bool) {
        self.id = id
        self.name = name
        self.background = background
        self.text = text
        self.secondaryText = secondaryText
        self.accent = accent
        self.spokenWord = spokenWord
        self.spokenBlock = spokenBlock
        self.isDark = isDark
    }

    /// A bright cream page, like a good paperback in daylight.
    public static let warmPaper = ReadingTheme(
        id: "warm-paper", name: "Warm Paper", background: ThemeColor("#FCF8F0"), text: ThemeColor("#2B2420"),
        secondaryText: ThemeColor("#76685B"), accent: ThemeColor("#9A4B1C"), spokenWord: ThemeColor("#F7D78C"),
        spokenBlock: ThemeColor("#F5EDDD"), isDark: false)
    public static let classicWhite = ReadingTheme(
        id: "classic-white", name: "Classic White", background: ThemeColor("#FFFFFF"), text: ThemeColor("#1C1C1E"),
        secondaryText: ThemeColor("#6C6C70"), accent: ThemeColor("#0A58CA"), spokenWord: ThemeColor("#FFE58A"),
        spokenBlock: ThemeColor("#F2F4F7"), isDark: false)
    public static let midnight = ReadingTheme(
        id: "midnight", name: "Midnight", background: ThemeColor("#15171C"), text: ThemeColor("#D9D4CA"),
        secondaryText: ThemeColor("#8E8A83"), accent: ThemeColor("#E0A458"), spokenWord: ThemeColor("#5B4A22"),
        spokenBlock: ThemeColor("#252A35"), isDark: true)
    public static let oledBlack = ReadingTheme(
        id: "oled-black", name: "OLED Black", background: ThemeColor("#000000"), text: ThemeColor("#C9C5BE"),
        secondaryText: ThemeColor("#7D7973"), accent: ThemeColor("#D69A4E"), spokenWord: ThemeColor("#4A3B17"),
        spokenBlock: ThemeColor("#17171A"), isDark: true)

    public static let builtIn: [ReadingTheme] = [.warmPaper, .classicWhite, .midnight, .oledBlack]

    public var isCustom: Bool { !Self.builtIn.contains { $0.id == id } }

    /// Cards and grouped rows in the app: the page nudged towards the ink.
    public var surface: ThemeColor { background.mixed(with: text, isDark ? 0.09 : 0.05) }
    /// Hairlines between rows.
    public var separator: ThemeColor { background.mixed(with: text, 0.14) }

    /// Two gradient stops for generated artwork (radio stations, covers of
    /// articles without an image). Stable per key, and in step with the
    /// accent: twelve hues spaced around the accent's, muted to suit the
    /// page. White text is readable on the bottom stop.
    public func artwork(for key: String) -> (top: ThemeColor, bottom: ThemeColor) {
        // FNV-1a, then a finalizer so similar names land on different hues.
        var hash: UInt32 = 2_166_136_261
        for byte in key.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        hash ^= hash >> 16
        hash &*= 0x85EB_CA6B
        hash ^= hash >> 13
        hash &*= 0xC2B2_AE35
        hash ^= hash >> 16
        let hue = accent.hue + Double(hash % 12) / 12
        let saturation = isDark ? 0.42 : 0.5
        return (ThemeColor(hue: hue, saturation: saturation, brightness: isDark ? 0.56 : 0.66),
                ThemeColor(hue: hue + 0.03, saturation: saturation + 0.08, brightness: isDark ? 0.34 : 0.42))
    }
}

public enum FontChoice: String, Hashable, Sendable, Codable, CaseIterable {
    case newYork, systemSans, charter, iowan, georgia, avenir

    public var displayName: String {
        switch self {
        case .newYork: "New York"
        case .systemSans: "San Francisco"
        case .charter: "Charter"
        case .iowan: "Iowan Old Style"
        case .georgia: "Georgia"
        case .avenir: "Avenir Next"
        }
    }

    /// CSS stack. `ui-serif` / `ui-sans-serif` resolve to New York and SF
    /// in WebKit; the others are fonts that ship with iOS.
    public var cssStack: String {
        switch self {
        case .newYork: "ui-serif, 'New York', Georgia, serif"
        case .systemSans: "ui-sans-serif, -apple-system, 'Helvetica Neue', sans-serif"
        case .charter: "Charter, 'Bitstream Charter', ui-serif, serif"
        case .iowan: "'Iowan Old Style', 'Palatino', ui-serif, serif"
        case .georgia: "Georgia, ui-serif, serif"
        case .avenir: "'Avenir Next', Avenir, ui-sans-serif, sans-serif"
        }
    }

    public var isSerif: Bool { self != .systemSans && self != .avenir }
}

public enum LayoutMode: String, Hashable, Sendable, Codable, CaseIterable {
    case scroll, paginated
}

public struct Typography: Hashable, Sendable, Codable {
    public var font: FontChoice
    /// Body size in CSS px (= points on iOS).
    public var fontSize: Double
    /// Line height as a multiple of the font size.
    public var lineHeight: Double
    /// Side margin in points.
    public var margin: Double
    public var justify: Bool
    public var hyphenate: Bool
    /// Extra letter spacing in em (Premium).
    public var letterSpacing: Double

    public init(font: FontChoice = .newYork, fontSize: Double = 19, lineHeight: Double = 1.55, margin: Double = 24,
                justify: Bool = false, hyphenate: Bool = true, letterSpacing: Double = 0) {
        self.font = font
        self.fontSize = fontSize
        self.lineHeight = lineHeight
        self.margin = margin
        self.justify = justify
        self.hyphenate = hyphenate
        self.letterSpacing = letterSpacing
    }

    public static let fontSizeRange: ClosedRange<Double> = 14...32
    public static let lineHeightRange: ClosedRange<Double> = 1.2...2.0
    public static let marginRange: ClosedRange<Double> = 12...56

    public func clamped() -> Typography {
        var copy = self
        copy.fontSize = min(max(fontSize, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
        copy.lineHeight = min(max(lineHeight, Self.lineHeightRange.lowerBound), Self.lineHeightRange.upperBound)
        copy.margin = min(max(margin, Self.marginRange.lowerBound), Self.marginRange.upperBound)
        copy.letterSpacing = min(max(letterSpacing, -0.02), 0.08)
        return copy
    }
}

public struct ReaderSettings: Hashable, Sendable, Codable {
    public var theme: ReadingTheme
    public var typography: Typography
    public var layout: LayoutMode
    /// Follow the system light/dark setting with these two themes.
    public var automaticThemes: (light: String, dark: String)?

    public init(theme: ReadingTheme = .warmPaper, typography: Typography = Typography(), layout: LayoutMode = .scroll,
                automaticThemes: (light: String, dark: String)? = ("warm-paper", "midnight")) {
        self.theme = theme
        self.typography = typography
        self.layout = layout
        self.automaticThemes = automaticThemes
    }

    /// Settings that need Premium: custom colours and letter spacing. Every
    /// typeface is free: paywalled font choice is one of the most resented
    /// things in competing readers.
    public var requiresPremium: Bool {
        theme.isCustom || typography.letterSpacing != 0
    }

    /// The settings with Premium-only choices replaced by free defaults.
    public func restrictedToFree() -> ReaderSettings {
        var copy = self
        if copy.theme.isCustom { copy.theme = copy.theme.isDark ? .midnight : .warmPaper }
        copy.typography.letterSpacing = 0
        return copy
    }

    enum CodingKeys: String, CodingKey { case theme, typography, layout, automaticLight, automaticDark }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        theme = try c.decode(ReadingTheme.self, forKey: .theme)
        typography = try c.decode(Typography.self, forKey: .typography)
        layout = try c.decode(LayoutMode.self, forKey: .layout)
        if let light = try c.decodeIfPresent(String.self, forKey: .automaticLight),
           let dark = try c.decodeIfPresent(String.self, forKey: .automaticDark)
        {
            automaticThemes = (light, dark)
        } else {
            automaticThemes = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(theme, forKey: .theme)
        try c.encode(typography, forKey: .typography)
        try c.encode(layout, forKey: .layout)
        try c.encodeIfPresent(automaticThemes?.light, forKey: .automaticLight)
        try c.encodeIfPresent(automaticThemes?.dark, forKey: .automaticDark)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.theme == rhs.theme && lhs.typography == rhs.typography && lhs.layout == rhs.layout
            && lhs.automaticThemes?.light == rhs.automaticThemes?.light && lhs.automaticThemes?.dark == rhs.automaticThemes?.dark
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(theme)
        hasher.combine(typography)
        hasher.combine(layout)
        hasher.combine(automaticThemes?.light)
        hasher.combine(automaticThemes?.dark)
    }

    /// The theme to use given the system appearance.
    public func effectiveTheme(systemIsDark: Bool, customThemes: [ReadingTheme] = []) -> ReadingTheme {
        // A saved built-in theme always uses its current palette.
        guard let automaticThemes else { return ReadingTheme.builtIn.first { $0.id == theme.id } ?? theme }
        let id = systemIsDark ? automaticThemes.dark : automaticThemes.light
        return (ReadingTheme.builtIn + customThemes).first { $0.id == id } ?? theme
    }
}
