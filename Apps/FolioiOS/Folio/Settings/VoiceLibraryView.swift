import SwiftUI
import FolioCore
import FolioAudio

/// Every installed voice, grouped by language with the reader's own
/// languages first. Tap ▶ to hear a voice, the star to keep it handy, and
/// the row for its settings.
struct VoiceLibraryView: View {
    @Environment(ListenModel.self) private var listen
    @State private var filter = VoiceFilter()
    @State private var showGetMore = false
    @State private var personalVoiceDenied = false

    var body: some View {
        List {
            if !listen.missingDefaults.isEmpty {
                Section {
                    ForEach(listen.missingDefaults.keys.sorted(), id: \.self) { language in
                        Label("Your \(VoiceText.language(language)) voice was removed from this iPhone. Folio uses \(listen.defaultVoice(for: language)?.name ?? "another voice") until you choose one.",
                              systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section {
                NavigationLink {
                    NaturalVoicesView()
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Natural voices")
                            Text(naturalSummary).font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "waveform")
                    }
                }
                .accessibilityIdentifier("natural-voices")
            }

            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        filterMenu(title: filter.language.map(VoiceText.language) ?? "All languages", active: filter.language != nil) {
                            Button("All languages") { filter.language = nil }
                            ForEach(languagesAvailable, id: \.self) { code in
                                Button(VoiceText.language(code)) { filter.language = code }
                            }
                        }
                        filterMenu(title: filter.minimumQuality.map(VoiceText.qualityFilter) ?? "Any quality", active: filter.minimumQuality != nil) {
                            Button("Any quality") { filter.minimumQuality = nil }
                            Button("Enhanced and better") { filter.minimumQuality = .enhanced }
                            Button("Premium only") { filter.minimumQuality = .premium }
                        }
                        filterMenu(title: filter.gender.map(VoiceText.gender) ?? "Any voice", active: filter.gender != nil) {
                            Button("Any voice") { filter.gender = nil }
                            Button("Female") { filter.gender = .female }
                            Button("Male") { filter.gender = .male }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }

            ForEach(listen.voiceSections(filter: filter)) { section in
                Section {
                    ForEach(section.voices) { voice in
                        NavigationLink {
                            VoiceDetailView(voice: voice)
                        } label: {
                            VoiceRow(voice: voice, isDefault: voice.id == section.defaultVoiceID)
                        }
                    }
                } header: {
                    HStack {
                        Text(VoiceText.language(section.id))
                        if section.isPreferred { Text("· in your library").textCase(nil).foregroundStyle(.secondary) }
                    }
                } footer: {
                    if section.isPreferred, section.defaultVoiceID == nil, let automatic = listen.defaultVoice(for: section.id) {
                        Text("Automatic: \(automatic.name). Open a voice to make it the default.")
                    }
                }
            }

            Section {
                Button {
                    showGetMore = true
                } label: {
                    Label("Get better voices", systemImage: "arrow.down.circle")
                }
                Button {
                    Task { personalVoiceDenied = !(await listen.requestPersonalVoice()) }
                } label: {
                    Label("Use my Personal Voice", systemImage: "person.crop.circle.badge.checkmark")
                }
                if personalVoiceDenied {
                    Text("Personal Voice isn't available. Create one in Settings › Accessibility › Personal Voice and allow apps to use it.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } footer: {
                Text("Apple voices and downloaded natural voices run on this iPhone and work offline; server voices need your server. A preview uses exactly the voice you will hear.")
            }
        }
        .navigationTitle("Voices")
        .searchable(text: $filter.query, prompt: "Search voices")
        .overlay {
            if listen.voices.isEmpty { ProgressView() }
        }
        .sheet(isPresented: $showGetMore) { GetMoreVoicesView() }
        .task { await listen.loadVoices() }
        .onDisappear { listen.stopPreview() }
    }

    private var naturalSummary: String {
        let inUse = listen.preferences.voiceByLanguage.filter { listen.isUsable($0.value) }.keys.sorted()
        if !inUse.isEmpty { return "In use for " + inUse.map(VoiceText.language).joined(separator: ", ") }
        if listen.installedModels.isEmpty && listen.serverVoices.isEmpty { return "Download a voice that runs on this iPhone, or connect your server" }
        return "Downloaded. Choose one to use it"
    }

    private var languagesAvailable: [String] {
        let all = Set(listen.voices.map { $0.languageCode.base })
        return listen.preferredLanguages.filter(all.contains) + all.subtracting(listen.preferredLanguages).sorted()
    }

    private func filterMenu(title: String, active: Bool, @ViewBuilder content: () -> some View) -> some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 4) {
                Text(title)
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(active ? Color.white : Color.primary)
            .background(active ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.secondary.opacity(0.12)), in: Capsule())
        }
    }
}

/// One voice: preview button, name, badges, favourite star.
struct VoiceRow: View {
    let voice: SpeechVoice
    let isDefault: Bool
    @Environment(ListenModel.self) private var listen

    /// The model to download first, for neural voices not on this iPhone yet.
    private var notDownloaded: NeuralVoiceCatalog.Model? {
        guard let entry = NeuralVoiceCatalog.voice(voice.id), !listen.installedModels.contains(entry.model) else { return nil }
        return entry.model
    }

    var body: some View {
        HStack(spacing: 12) {
            if let model = notDownloaded {
                Button {
                    listen.downloadModel(model)
                } label: {
                    Image(systemName: listen.modelDownloads[model] == .downloading ? "arrow.down.circle.dotted" : "arrow.down.circle")
                        .font(.title2)
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Download \(voice.name)")
            } else {
                Button {
                    listen.preview(voice)
                } label: {
                    Image(systemName: listen.previewingVoiceID == voice.id ? "stop.circle.fill" : "play.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(listen.previewingVoiceID == voice.id ? "Stop preview" : "Preview \(voice.name)")
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(voice.name).font(.body.weight(isDefault ? .semibold : .regular))
                    if isDefault {
                        Text("DEFAULT").font(.caption2.weight(.bold)).foregroundStyle(.tint)
                    }
                }
                HStack(spacing: 6) {
                    QualityBadge(quality: voice.quality, personal: voice.isPersonalVoice)
                    if let region = voice.region { Text(VoiceText.region(region)).font(.caption).foregroundStyle(.secondary) }
                    if voice.gender != .unspecified {
                        Text(VoiceText.gender(voice.gender)).font(.caption).foregroundStyle(.secondary)
                    }
                    if VoiceServer.isServerVoice(voice.id) {
                        Label("Your server", systemImage: "server.rack").labelStyle(.iconOnly).font(.caption2).foregroundStyle(.secondary)
                            .accessibilityLabel("Plays from your voice server")
                    } else {
                        Label("On device", systemImage: "iphone").labelStyle(.iconOnly).font(.caption2).foregroundStyle(.secondary)
                            .accessibilityLabel("Works offline")
                    }
                }
            }
            Spacer(minLength: 0)
            Button {
                listen.toggleFavourite(voice)
            } label: {
                Image(systemName: listen.isFavourite(voice) ? "star.fill" : "star")
                    .foregroundStyle(listen.isFavourite(voice) ? Color.orange : Color.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(listen.isFavourite(voice) ? "Remove from favourites" : "Add to favourites")
        }
        .padding(.vertical, 2)
    }
}

struct QualityBadge: View {
    let quality: SpeechVoice.Quality
    var personal = false

    var body: some View {
        let label = personal ? "Personal" : VoiceText.quality(quality)
        Text(label.uppercased())
            .font(.system(size: 9, weight: .bold))
            .tracking(0.6)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(quality >= .enhanced || personal ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .overlay(Capsule().strokeBorder(quality >= .enhanced || personal ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.secondary.opacity(0.5))))
    }
}

/// Settings for one voice: preview, default, favourite, tuning, feeds.
struct VoiceDetailView: View {
    let voice: SpeechVoice
    @Environment(ListenModel.self) private var listen
    @Environment(AppModel.self) private var model
    @Environment(EntitlementStore.self) private var entitlements
    @State private var showPremium = false

    private var language: String { voice.languageCode.base }
    private var isDefault: Bool { listen.preferences.voiceByLanguage[language] == voice.id }
    private var neuralModel: NeuralVoiceCatalog.Model? { NeuralVoiceCatalog.voice(voice.id)?.model }
    private var isNatural: Bool { neuralModel != nil || VoiceServer.isServerVoice(voice.id) }
    private var needsDownload: Bool { neuralModel.map { !listen.installedModels.contains($0) } ?? false }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(voice.name).font(.system(.largeTitle, design: .serif, weight: .bold))
                    HStack(spacing: 8) {
                        QualityBadge(quality: voice.quality, personal: voice.isPersonalVoice)
                        Text([VoiceText.language(language), voice.region.map(VoiceText.region)].compactMap { $0 }.joined(separator: " · "))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
                if let model = neuralModel, needsDownload {
                    Button {
                        listen.downloadModel(model)
                    } label: {
                        Label(listen.modelDownloads[model] == .downloading ? "Downloading…" : "Download to preview and use",
                              systemImage: "arrow.down.circle")
                    }
                    .disabled(listen.modelDownloads[model] == .downloading)
                }
                if let error = listen.previewError, isNatural {
                    Text(error).font(.footnote).foregroundStyle(.orange)
                }
                Button {
                    listen.preview(voice)
                } label: {
                    Label(listen.previewingVoiceID == voice.id ? "Stop" : "Play a sample",
                          systemImage: listen.previewingVoiceID == voice.id ? "stop.fill" : "play.fill")
                }
                if let sample = listen.currentArticleSample(language: language) {
                    Button {
                        listen.preview(voice, text: sample)
                    } label: {
                        Label("Preview with the article you're listening to", systemImage: "text.quote")
                    }
                }
            }

            Section {
                Button {
                    if isNatural && !isDefault && !listen.neuralVoicesAllowed {
                        showPremium = true
                    } else {
                        listen.setDefaultVoice(isDefault ? nil : voice, for: language)
                    }
                } label: {
                    Label(isDefault ? "Default for \(VoiceText.language(language))" : "Make default for \(VoiceText.language(language))",
                          systemImage: isDefault ? "checkmark.circle.fill" : "circle")
                }
                .accessibilityIdentifier("make-default-voice")
                Toggle("Favourite", isOn: Binding(get: { listen.isFavourite(voice) }, set: { _ in listen.toggleFavourite(voice) }))
            }

            if !isNatural {
            Section {
                if entitlements.isPremium {
                    let tuning = listen.tuning(for: voice)
                    VStack(alignment: .leading) {
                        Text("Pitch \(String(format: "%.2f", tuning.pitch))×")
                        Slider(value: Binding(get: { tuning.pitch }, set: { listen.setTuning(VoiceTuning(pitch: $0, rate: tuning.rate), for: voice) }),
                               in: 0.8...1.2, step: 0.02)
                    }
                    VStack(alignment: .leading) {
                        Text("Speed for this voice \(String(format: "%.2f", tuning.rate))×")
                        Slider(value: Binding(get: { tuning.rate }, set: { listen.setTuning(VoiceTuning(pitch: tuning.pitch, rate: $0), for: voice) }),
                               in: 0.8...1.25, step: 0.05)
                    }
                    if tuning != .neutral {
                        Button("Reset") { listen.setTuning(.neutral, for: voice) }
                    }
                } else {
                    premiumRow("Adjust pitch and speed per voice")
                }
            } header: {
                Text("Tuning")
            } footer: {
                Text("Speed here multiplies your main narration speed. Some voices sound more natural a little slower or lower.")
            }
            }

            Section {
                if entitlements.isPremium {
                    ForEach(model.feeds) { feed in
                        let chosen = listen.preferences.feedVoices[feed.id.rawValue] == voice.id
                        Button {
                            listen.preferences.feedVoices[feed.id.rawValue] = chosen ? nil : voice.id
                        } label: {
                            HStack {
                                Text(feed.title).foregroundStyle(.primary)
                                Spacer()
                                if chosen { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                        }
                    }
                } else {
                    premiumRow("Give each feed its own voice")
                }
            } header: {
                Text("Use for feeds")
            } footer: {
                Text("Articles from these feeds use \(voice.name) for \(VoiceText.language(language)) text.")
            }
        }
        .navigationTitle(voice.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPremium) { PremiumView() }
        .onDisappear { listen.stopPreview() }
    }

    private func premiumRow(_ text: String) -> some View {
        Button {
            showPremium = true
        } label: {
            HStack {
                Text(text).foregroundStyle(.primary)
                Spacer()
                Text("Premium").font(.caption.weight(.semibold)).foregroundStyle(.tint)
            }
        }
    }
}

/// iOS doesn't let apps download system voices, so explain the way there.
struct GetMoreVoicesView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("The best voices on iPhone are free downloads from Apple, marked Enhanced or Premium. They sound far more natural and work offline.")
                }
                Section("How to get them") {
                    step(1, "Open the Settings app.")
                    step(2, "Go to Accessibility › Read & Speak (on older iOS: Spoken Content).")
                    step(3, "Tap Voices, then choose a language, for example English, German, Spanish or Slovak.")
                    step(4, "Tap a voice marked Enhanced or Premium to download it.")
                    step(5, "Come back to Folio. New voices appear in the library automatically.")
                }
                Section {
                    Text("Premium voices are about 100–500 MB each. Downloading over Wi-Fi is best.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Get better voices")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)").font(.headline.monospacedDigit()).foregroundStyle(.tint)
            Text(text)
        }
    }
}

/// How narration flows: segments, pauses, title, languages.
struct ListeningStyleView: View {
    @Environment(ListenModel.self) private var listen
    private let languages = ["en", "de", "es", "sk", "cs"]

    var body: some View {
        @Bindable var listen = listen
        Form {
            Section {
                Picker("Read", selection: $listen.preferences.granularity) {
                    Text("Paragraph by paragraph").tag(SpeechScriptOptions.Granularity.paragraph)
                    Text("Sentence by sentence").tag(SpeechScriptOptions.Granularity.sentence)
                }
                Toggle("Read the title first", isOn: $listen.preferences.includeTitle)
                Toggle("Say the source before the title", isOn: $listen.preferences.announceSource)
                    .disabled(!listen.preferences.includeTitle)
                VStack(alignment: .leading) {
                    Text("Pause between paragraphs: \(String(format: "%.1f", listen.preferences.paragraphPause)) s")
                    Slider(value: $listen.preferences.paragraphPause, in: 0...1.5, step: 0.05)
                }
                Toggle("Play the next article automatically", isOn: $listen.preferences.continuousPlayback)
            } footer: {
                Text("Titles are read without the site's name tacked on, format tags like [Video], capitals or emoji, with a breath before the story. After a pause of more than 30 seconds, Folio picks up at the start of the sentence; after 10 minutes, at the start of the paragraph. Sentence by sentence adds a short breath between sentences.")
            }
            Section {
                Picker("Highlight", selection: $listen.preferences.highlightStyle) {
                    ForEach(NarrationHighlightStyle.allCases) { Text($0.label).tag($0) }
                }
                .accessibilityIdentifier("highlight-style")
            } header: {
                Text("While listening")
            } footer: {
                Text("The sentence being read is shaded and the word is marked on top. With voices that give no word timing, Folio reads sentence by sentence and shows the sentence.")
            }
            Section {
                Picker("Language", selection: $listen.preferences.languageOverride) {
                    Text("Detect automatically").tag(String?.none)
                    ForEach(languages, id: \.self) { Text(VoiceText.language($0)).tag(Optional($0)) }
                }
                Toggle("Switch voices for paragraphs in another language", isOn: $listen.preferences.switchLanguagePerParagraph)
                    .disabled(listen.preferences.languageOverride != nil)
            } header: {
                Text("Languages")
            } footer: {
                Text("Folio reads each article in the language of its own text, guided by the language its feed usually uses. An English article quoting a long German paragraph reads that paragraph with your German voice; short passages and languages none of your feeds use keep the article's voice.")
            }
        }
        .navigationTitle("Listening style")
    }
}

/// Cleanup switches and the pronunciation dictionary (regex-capable).
struct PronunciationSettingsView: View {
    @Environment(ListenModel.self) private var listen
    @Environment(EntitlementStore.self) private var entitlements
    @State private var editing: PronunciationEntry?
    @State private var showPremium = false

    var body: some View {
        @Bindable var listen = listen
        Form {
            Section {
                Toggle("Skip citation numbers", isOn: $listen.preferences.cleanup.citations)
                Toggle("Skip footnote marks", isOn: $listen.preferences.cleanup.footnoteMarkers)
                Toggle("Skip \"Read more\" and similar", isOn: $listen.preferences.cleanup.boilerplate)
                Toggle("Skip emoji", isOn: $listen.preferences.cleanup.emoji)
                Toggle("Skip text in brackets", isOn: $listen.preferences.cleanup.parentheticals)
            } header: {
                Text("Leave out")
            } footer: {
                Text("Only narration changes; the article text stays as published. For example \"[12]\", \"¹\" and \"The post … appeared first on …\" are not read aloud.")
            }

            Section {
                Toggle("Read image captions", isOn: $listen.preferences.cleanup.captions)
                Toggle("Say when a table or code is skipped", isOn: $listen.preferences.cleanup.mentionSkipped)
                Toggle("Say \"quote\" around quotes", isOn: $listen.preferences.cleanup.announceQuotes)
            } header: {
                Text("Signposts")
            } footer: {
                Text("Quotes always get a pause before and after. Numbered lists are read with their numbers.")
            }

            Section {
                Text("Common abbreviations are read in full in English, German, Spanish, Slovak and Czech (e.g., z. B., p. ej., napr., např.), dotted acronyms like U.S. are read as words, and links are read as the site name.")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: {
                Text("Built in")
            }

            Section {
                ForEach(listen.preferences.pronunciations) { entry in
                    Button {
                        if entitlements.isPremium { editing = entry } else { showPremium = true }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.written).font(entry.isRegex ? .body.monospaced() : .body).foregroundStyle(.primary)
                                Text("→ \(entry.spoken)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if entry.isRegex { Text("REGEX").font(.caption2.weight(.bold)).foregroundStyle(.tint) }
                            if let language = entry.language { Text(language.uppercased()).font(.caption2).foregroundStyle(.secondary) }
                        }
                    }
                }
                .onDelete { listen.preferences.pronunciations.remove(atOffsets: $0) }
                Button {
                    if entitlements.isPremium { editing = PronunciationEntry(written: "", spoken: "") } else { showPremium = true }
                } label: {
                    Label("Add a pronunciation", systemImage: "plus")
                }
            } header: {
                Text("Your pronunciations")
            } footer: {
                Text(entitlements.isPremium
                     ? "Plain words or regular expressions with $1-style groups, per language or for all."
                     : "Your own pronunciations, including regular expressions, are part of Premium.")
            }
        }
        .navigationTitle("Pronunciation")
        .sheet(item: $editing) { entry in PronunciationEditor(entry: entry) }
        .sheet(isPresented: $showPremium) { PremiumView() }
    }
}

/// Edit one rule and hear the result straight away.
struct PronunciationEditor: View {
    @Environment(ListenModel.self) private var listen
    @Environment(\.dismiss) private var dismiss
    @State var entry: PronunciationEntry
    @State private var sample = ""

    private var language: String { entry.language ?? "en" }
    private var result: String {
        PronunciationRules(userEntries: [entry]).spoken(sample, language: LanguageCode(language), cleanup: .off)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(entry.isRegex ? "Pattern, e.g. (\\d+) ?km" : "Written, e.g. SQL", text: $entry.written)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(entry.isRegex ? .body.monospaced() : .body)
                    TextField(entry.isRegex ? "Say, e.g. $1 kilometres" : "Say, e.g. sequel", text: $entry.spoken)
                        .textInputAutocapitalization(.never)
                    Toggle("Regular expression", isOn: $entry.isRegex)
                    Toggle("Match case", isOn: $entry.caseSensitive)
                    Picker("Language", selection: $entry.language) {
                        Text("All languages").tag(String?.none)
                        ForEach(["en", "de", "es", "sk", "cs"], id: \.self) { Text(VoiceText.language($0)).tag(Optional($0)) }
                    }
                    if let problem = entry.problem, !entry.written.isEmpty {
                        Text(problem).font(.footnote).foregroundStyle(.red)
                    }
                }
                Section {
                    TextField("Type a test sentence", text: $sample, axis: .vertical)
                    if !sample.isEmpty {
                        Text(result).foregroundStyle(.secondary)
                        Button {
                            if let voice = listen.defaultVoice(for: language) { listen.preview(voice, text: result) }
                        } label: {
                            Label("Hear it", systemImage: "play.fill")
                        }
                    }
                } header: {
                    Text("Try it")
                }
            }
            .navigationTitle(entry.written.isEmpty ? "New pronunciation" : entry.written)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let index = listen.preferences.pronunciations.firstIndex(where: { $0.id == entry.id }) {
                            listen.preferences.pronunciations[index] = entry
                        } else {
                            listen.preferences.pronunciations.append(entry)
                        }
                        dismiss()
                    }
                    .disabled(entry.problem != nil || entry.spoken.isEmpty && !entry.isRegex)
                }
            }
            .onAppear { if sample.isEmpty { sample = entry.isRegex ? "" : entry.written } }
            .onDisappear { listen.stopPreview() }
        }
    }
}

/// Localized names for languages, regions, qualities and genders.
enum VoiceText {
    static func language(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code)?.capitalized ?? code.uppercased()
    }

    static func region(_ code: String) -> String {
        Locale.current.localizedString(forRegionCode: code) ?? code
    }

    static func quality(_ quality: SpeechVoice.Quality) -> String {
        switch quality {
        case .standard: "Standard"
        case .enhanced: "Enhanced"
        case .premium: "Premium"
        case .neural: "Neural"
        }
    }

    static func qualityFilter(_ quality: SpeechVoice.Quality) -> String {
        quality == .premium ? "Premium only" : "Enhanced+"
    }

    static func gender(_ gender: SpeechVoice.Gender) -> String {
        switch gender {
        case .female: "Female"
        case .male: "Male"
        case .unspecified: "Any"
        }
    }
}
