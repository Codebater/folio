import SwiftUI
import FolioCore
import FolioAudio

/// The languages Paperwire speaks, each with its own voice. English, German,
/// Spanish, Slovak and Czech are always read in their own language; others
/// only when turned on. A story in a language narration doesn't speak is
/// read in the main language, and stations play one language section at a time.
struct LanguagesSettingsView: View {
    @Environment(ListenModel.self) private var listen
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var listen = listen
        let enabled = listen.activeLanguages
        let main = listen.readAloudLanguages.first ?? "en"
        List {
            Section {
                ForEach(rows, id: \.self) { code in
                    Toggle(isOn: isOn(code)) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(StationText.languageName(code))
                                if code == main {
                                    Text("Main").font(.caption2.weight(.bold)).foregroundStyle(.tint)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(.tint.opacity(0.12), in: Capsule())
                                }
                            }
                            Text(detail(code)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    // One language always stays on, and the tuned ones are always spoken.
                    .disabled(listen.readAloudLanguages == [code] || Self.alwaysSpoken.contains(code))
                    .accessibilityIdentifier("read-aloud-\(code)")
                }
            } header: {
                Text("Read aloud in")
            } footer: {
                Text("English, German, Spanish, Slovak and Czech are always read in their own language: Paperwire recognises the language from the article's text before it starts. Other languages are read only when they're on. A story in any other language, or one it can't place, is read in \(VoiceText.language(main)). Turning a language off doesn't hide its articles.")
            }

            if enabled.count > 1 {
                Section {
                    Picker("Main language", selection: mainLanguage) {
                        ForEach(enabled, id: \.self) { Text(StationText.languageName($0)).tag($0) }
                    }
                } footer: {
                    Text("Stations start in your main language. Each other language follows as its own section, announced in that language, so the voice only changes between sections.")
                }
            }

            Section {
                ForEach(enabled, id: \.self) { code in
                    NavigationLink {
                        VoiceLibraryView(language: code)
                    } label: {
                        LabeledContent(StationText.languageName(code), value: listen.narratingVoice(for: code)?.name ?? "Automatic")
                    }
                }
            } header: {
                Text("Voice for each language")
            }

            Section {
                Toggle("Switch voices for long passages in another language", isOn: $listen.preferences.switchLanguagePerParagraph)
                    .disabled(listen.preferences.languageOverride != nil || enabled.count < 2)
                Picker("Read every article as", selection: $listen.preferences.languageOverride) {
                    Text("Its own language").tag(String?.none)
                    ForEach(enabled, id: \.self) { Text(StationText.languageName($0)).tag(Optional($0)) }
                }
            } header: {
                Text("Inside an article")
            } footer: {
                Text("An English article quoting a long German paragraph can read it with your German voice. Short passages keep the article's voice, and stations never switch voice inside a story.")
            }

            if listen.preferences.readAloudLanguages != nil {
                Section {
                    Button("Choose automatically") { listen.preferences.readAloudLanguages = nil }
                } footer: {
                    Text("Automatic uses the languages most of your articles are in.")
                }
            }
        }
        .navigationTitle("Languages")
        .task { await listen.loadVoices() }
    }

    /// The languages on, then the library's (most articles first), then the
    /// phone's and the ones Paperwire has phrases for.
    private var rows: [String] {
        let device = Locale.preferredLanguages.map { LanguageCode($0).base }
        let candidates = listen.readAloudLanguages + model.libraryLanguages + device + LanguageCode.tuned.map(\.base)
        return candidates.reduce(into: [String]()) { if !$1.isEmpty && !$0.contains($1) { $0.append($1) } }
    }

    static let alwaysSpoken = Set(LanguageCode.tuned.map(\.base))

    private func detail(_ code: String) -> String {
        let count = model.libraryLanguageCounts[code] ?? 0
        let articles = count == 0 ? "No articles yet" : "\(count) \(count == 1 ? "article" : "articles")"
        guard listen.spokenLanguages.contains(code), let voice = listen.narratingVoice(for: code) else { return articles }
        return "\(articles) · \(voice.name)"
    }

    private func isOn(_ code: String) -> Binding<Bool> {
        Binding(
            get: { listen.spokenLanguages.contains(code) },
            set: { on in
                var languages = listen.readAloudLanguages
                if on, !languages.contains(code) { languages.append(code) }
                if !on { languages.removeAll { $0 == code } }
                guard !languages.isEmpty else { return }
                listen.preferences.readAloudLanguages = languages
                if !on, listen.preferences.languageOverride == code { listen.preferences.languageOverride = nil }
            })
    }

    private var mainLanguage: Binding<String> {
        Binding(
            get: { listen.readAloudLanguages.first ?? "en" },
            set: { code in
                listen.preferences.readAloudLanguages = [code] + listen.readAloudLanguages.filter { $0 != code }
            })
    }
}
