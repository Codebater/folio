import SwiftUI
import FolioCore
import FolioReader

enum AppTab: Hashable { case today, library, listen }

/// Three tabs keep the app calm: Today (editorial front page), Library
/// (feeds, categories, saved) and Listen (narration queue). Settings opens
/// as a sheet from each tab's toolbar; the reader is pushed full-screen.
/// The whole app wears the reading theme, so every tab matches the page.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(ListenModel.self) private var listen
    @Environment(\.colorScheme) private var colorScheme
    @State private var tab: AppTab = .today
    @State private var showSettings = false

    private var theme: ReadingTheme { model.effectiveReaderSettings(systemIsDark: colorScheme == .dark).theme }

    /// A fixed theme sets light or dark for the app; automatic themes follow
    /// the system (forcing it there would pin the scheme and stop following).
    private var colorSchemeOverride: ColorScheme? {
        model.readerSettings.automaticThemes == nil ? (theme.isDark ? .dark : .light) : nil
    }

    var body: some View {
        Group {
            if model.account == nil {
                OnboardingView()
            } else {
                TabView(selection: $tab) {
                    NavigationStack { TodayView(showSettings: $showSettings) }
                        .tabItem { Label("Today", systemImage: "newspaper") }
                        .tag(AppTab.today)
                    NavigationStack { LibraryView(showSettings: $showSettings) }
                        .tabItem { Label("Library", systemImage: "books.vertical") }
                        .tag(AppTab.library)
                    NavigationStack { ListenView() }
                        .tabItem { Label("Listen", systemImage: "headphones") }
                        .tag(AppTab.listen)
                }
                .toolbarBackground(Color(theme.background), for: .tabBar)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if listen.nowPlaying != nil && tab != .listen {
                        MiniPlayer { tab = .listen }
                            .padding(.horizontal, 12)
                            .padding(.bottom, 54)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.snappy, value: listen.nowPlaying?.id)
                .sheet(isPresented: $showSettings) { SettingsView() }
            }
        }
        .environment(\.folioTheme, theme)
        .tint(Color(theme.accent))
        .preferredColorScheme(colorSchemeOverride)
    }
}

/// Settings button shared by the tab headers.
struct SettingsToolbarButton: View {
    @Binding var showSettings: Bool

    var body: some View {
        Button {
            showSettings = true
        } label: {
            HeaderButtonLabel(systemImage: "person.crop.circle")
        }
        .buttonStyle(.borderless)  // in a list row, only the button is tappable
        .accessibilityLabel("Settings")
    }
}

/// The top of a tab. It scrolls away with the page, so no sticky bar takes
/// room at the top of the phone.
struct ScreenHeader<Title: View, Trailing: View>: View {
    @ViewBuilder var title: Title
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            title
            Spacer(minLength: 8)
            trailing
        }
        .padding(.top, 4)
    }
}

/// A tab's name, set like the weekday on Today.
struct ScreenTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(.title2, weight: .heavy))
            .accessibilityAddTraits(.isHeader)
    }
}

/// A round icon for buttons in a screen header.
struct HeaderButtonLabel: View {
    let systemImage: String
    @Environment(\.folioTheme) private var theme

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(Color(theme.accent))
            .frame(width: 36, height: 36)
            .background(Color(theme.surface), in: Circle())
            .contentShape(Circle())
    }
}

extension View {
    /// Content scrolling under the status bar fades softly (iOS 26), now
    /// that no navigation bar sits there.
    @ViewBuilder func softTopEdge() -> some View {
        if #available(iOS 26.0, *) {
            self.scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self
        }
    }
}

/// Sync status line used under list titles.
struct SyncStatusLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.syncStatus {
        case .syncing(let phase):
            Label(phase, systemImage: "arrow.triangle.2.circlepath").symbolEffect(.pulse)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        case .idle:
            if let last = model.lastSyncedAt {
                Text("Updated \(Format.relative(last))")
            } else {
                Text("Pull down to sync")
            }
        }
    }
}
