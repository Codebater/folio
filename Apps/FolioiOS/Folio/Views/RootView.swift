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

/// Settings button shared by the tab toolbars.
struct SettingsToolbarButton: View {
    @Binding var showSettings: Bool

    var body: some View {
        Button {
            showSettings = true
        } label: {
            Image(systemName: "person.crop.circle")
        }
        .accessibilityLabel("Settings")
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
