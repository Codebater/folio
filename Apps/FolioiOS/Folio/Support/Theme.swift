import SwiftUI
import FolioReader

/// The reading theme for the whole app, so Today, Library and Listen share
/// the reader's page, ink and accent. Set once in `RootView`.
private struct FolioThemeKey: EnvironmentKey {
    static let defaultValue = ReadingTheme.warmPaper
}

extension EnvironmentValues {
    var folioTheme: ReadingTheme {
        get { self[FolioThemeKey.self] }
        set { self[FolioThemeKey.self] = newValue }
    }
}

extension View {
    /// The theme's page behind a tab screen, its lists and its navigation bar.
    func folioScreen(_ theme: ReadingTheme) -> some View {
        scrollContentBackground(.hidden)
            .background(Color(theme.background).ignoresSafeArea())
            .toolbarBackground(Color(theme.background), for: .navigationBar)
    }

    /// Card colour and hairlines for rows of a grouped list.
    func folioRow(_ theme: ReadingTheme) -> some View {
        listRowBackground(Color(theme.surface)).listRowSeparatorTint(Color(theme.separator))
    }
}

/// A hairline in the theme's separator colour.
struct ThemeDivider: View {
    @Environment(\.folioTheme) private var theme

    var body: some View {
        Rectangle().fill(Color(theme.separator)).frame(height: 0.5).accessibilityHidden(true)
    }
}

/// Generated artwork in the theme's palette: a diagonal gradient with a soft
/// light in one corner, an optional symbol watermark and an optional large
/// initial. Used for stations, sources and articles without an image.
struct ThemeArtwork: View {
    let key: String
    var symbol: String?
    var initial: String?
    @Environment(\.folioTheme) private var theme

    var body: some View {
        let colors = theme.artwork(for: key)
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                LinearGradient(colors: [Color(colors.top), Color(colors.bottom)], startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [.white.opacity(0.28), .clear], center: .topTrailing, startRadius: 0,
                               endRadius: max(proxy.size.width, proxy.size.height) * 0.9)
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: side * 0.62, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.13))
                        .offset(x: proxy.size.width * 0.26, y: -proxy.size.height * 0.16)
                }
                if let initial {
                    Text(String(initial.prefix(1)).uppercased())
                        .font(.system(size: side * 0.46, weight: .semibold, design: .serif))
                        .foregroundStyle(.white.opacity(0.92))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .accessibilityHidden(true)
    }
}
