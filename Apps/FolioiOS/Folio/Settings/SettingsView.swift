import StoreKit
import SwiftUI
import FolioCore
import FolioAudio
import FolioStorage

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(ListenModel.self) private var listen
    @Environment(EntitlementStore.self) private var entitlements
    @Environment(\.dismiss) private var dismiss
    @State private var showConnect = false
    @State private var showPremium = false
    @State private var showManageSubscription = false
    @State private var confirmSignOut = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    LabeledContent("Connected to", value: model.accountTitle)
                    LabeledContent("Status") { SyncStatusLabel().font(.footnote) }
                    Button("Sync now") { Task { await model.sync() } }
                    if model.isDemo {
                        Button("Connect your FreshRSS server") { showConnect = true }
                    } else {
                        Button("Change server or account") { showConnect = true }
                    }
                    Button("Sign out", role: .destructive) { confirmSignOut = true }
                }

                Section {
                    NavigationLink {
                        ReadingListSettingsView()
                    } label: {
                        SettingsRow(icon: "list.bullet.rectangle", title: "Lists & triage",
                                    subtitle: model.reading.showsCounts ? "Counts · \(model.reading.density == .compact ? "compact" : "comfortable")" : "Calm")
                    }
                    Toggle("Fetch full articles", isOn: Binding(get: { model.reading.fetchFullText },
                                                                set: { model.reading.fetchFullText = $0 }))
                } header: {
                    Text("Reading")
                } footer: {
                    Text("For feeds that send only a summary, Paperwire loads the article from the publisher's page, like Reader view. After a sync: Wi-Fi only.")
                }

                Section {
                    NavigationLink {
                        VoiceLibraryView()
                    } label: {
                        SettingsRow(icon: "person.wave.2", title: "Voices", subtitle: "Choose and preview voices for each language")
                    }
                    .accessibilityIdentifier("voice-library")
                    NavigationLink {
                        NaturalVoicesView()
                    } label: {
                        SettingsRow(icon: "waveform", title: "Natural voices", subtitle: "Voices on this iPhone, your own server, Voice Lab")
                    }
                    NavigationLink {
                        PronunciationSettingsView()
                    } label: {
                        SettingsRow(icon: "character.bubble", title: "Pronunciation & cleanup",
                                    subtitle: "Skip citations and boilerplate, fix words")
                    }
                    NavigationLink {
                        ListeningStyleView()
                    } label: {
                        SettingsRow(icon: "waveform", title: "Listening style", subtitle: "Pauses, sentences, languages")
                    }
                } header: {
                    Text("Listening")
                } footer: {
                    if !listen.missingDefaults.isEmpty {
                        Label("A voice you chose is no longer installed. Open Voices to pick another.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    } else {
                        Text("Narration uses voices on this iPhone and works offline.")
                    }
                }

                Section("Premium") {
                    if entitlements.isPremium {
                        Label(entitlements.state.isFamily ? "Premium for your family is active." : "Premium is active. Thank you!",
                              systemImage: "checkmark.seal.fill")
                        if entitlements.state.canUpgradeToFamily {
                            Button("Share with your family") { showPremium = true }
                        }
                        if entitlements.state.activeProducts.contains(.yearly) {
                            Button("Manage subscription") { showManageSubscription = true }
                        }
                    } else {
                        Button("Paperwire Premium") { showPremium = true }
                    }
                }

                Section("Storage") {
                    NavigationLink {
                        StorageView()
                    } label: {
                        SettingsRow(icon: "internaldrive", title: "Storage", subtitle: "Downloads, image cache, cleanup")
                    }
                }

                Section("About") {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                    Link("Source code", destination: URL(string: "https://github.com/Codebater/folio")!)
                    Text("Paperwire's source code is public under the Functional Source License (FSL-1.1-ALv2); each version becomes Apache 2.0 two years after release. Articles belong to their publishers; Paperwire only shows what your own server syncs.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showConnect) { ConnectServerView() }
            .sheet(isPresented: $showPremium) { PremiumView() }
            .manageSubscriptionsSheet(isPresented: $showManageSubscription)
            .confirmationDialog("Sign out and remove all synced articles from this iPhone?", isPresented: $confirmSignOut,
                                titleVisibility: .visible) {
                Button("Sign out", role: .destructive) {
                    Task {
                        await model.signOut()
                        dismiss()
                    }
                }
            }
        }
    }
}

/// Icon tile, title and one-line subtitle, like iOS Settings.
struct SettingsRow: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body.weight(.medium))
                .foregroundStyle(.tint)
                .frame(width: 32, height: 32)
                .background(.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Counts or calm, density, swipes, mark-read-on-scroll and muted keywords.
struct ReadingListSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var newTerm = ""
    @State private var newWatch = ""

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                ForEach(model.reading.watch.terms, id: \.self) { term in
                    Label(term, systemImage: "eye")
                }
                .onDelete { model.reading.watch.terms.remove(atOffsets: $0) }
                HStack {
                    TextField("A name, company or topic", text: $newWatch)
                        .onSubmit(addWatch)
                    Button("Add", action: addWatch).disabled(newWatch.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .accessibilityIdentifier("add-watch-word")
            } header: {
                Text("Watch words")
            } footer: {
                Text("New articles that mention these lead Today, whichever feed they come from. Handy for your company, competitors, a job hunt or anything you follow.")
            }

            Section {
                Toggle("Reading one marks the others read", isOn: $model.reading.markDuplicatesRead)
                Toggle("Key points at the top of longer articles", isOn: $model.reading.showKeyPoints)
            } header: {
                Text("Save time")
            } footer: {
                Text("When BBC, Wired and Ars Technica report the same news, Today shows it once with the number of sources, and stations play it once.")
            }

            Section {
                Picker("Unread", selection: $model.reading.unreadStyle) {
                    Text("Counts").tag(ReadingPreferences.UnreadStyle.counts)
                    Text("Calm").tag(ReadingPreferences.UnreadStyle.calm)
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(model.reading.showsCounts
                     ? "Unread counts, unread dots and \"Mark all as read\" for working through every feed."
                     : "No counters or badges. Lists remember where you left off, so there is nothing to keep up with.")
            }

            Section("Lists") {
                Picker("Rows", selection: $model.reading.density) {
                    Text("Comfortable").tag(ReadingPreferences.Density.comfortable)
                    Text("Compact").tag(ReadingPreferences.Density.compact)
                }
                Toggle("Mark as read when scrolled past", isOn: $model.reading.markReadOnScroll)
            }

            Section {
                Picker("Swipe right", selection: $model.reading.leadingSwipe) { swipeOptions }
                Picker("Swipe left", selection: $model.reading.trailingSwipe) { swipeOptions }
                Picker("Swipe left, second", selection: $model.reading.secondaryTrailingSwipe) { swipeOptions }
            } header: {
                Text("Swipe actions")
            }

            Section {
                ForEach(model.reading.mute.terms, id: \.self) { term in
                    Text(term)
                }
                .onDelete { model.reading.mute.terms.remove(atOffsets: $0) }
                HStack {
                    TextField("Add a word or phrase", text: $newTerm)
                        .textInputAutocapitalization(.never)
                        .onSubmit(add)
                    Button("Add", action: add).disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Toggle("Also mark muted articles as read", isOn: $model.reading.muteMarksRead)
            } header: {
                Text("Muted words")
            } footer: {
                Text("Articles whose title contains a muted word (whole words, any case or accent) are hidden. Marking them read keeps your server and counts in step.")
            }
        }
        .navigationTitle("Lists & triage")
    }

    private var swipeOptions: some View {
        ForEach(ReadingPreferences.SwipeAction.allCases) { action in Text(action.title).tag(action) }
    }

    private func addWatch() {
        let term = newWatch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, !model.reading.watch.terms.contains(term) else { return }
        model.reading.watch.terms.append(term)
        newWatch = ""
    }

    private func add() {
        let term = newTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, !model.reading.mute.terms.contains(term) else { return }
        model.reading.mute.terms.append(term)
        newTerm = ""
    }
}

/// What Folio keeps on this iPhone, and how to clean it up.
struct StorageView: View {
    @Environment(AppModel.self) private var model
    @State private var stats: StorageStats?
    @State private var imageBytes: Int64 = 0
    @State private var cleanupMessage: String?

    var body: some View {
        @Bindable var model = model
        Form {
            Section("On this iPhone") {
                if let stats {
                    LabeledContent("Articles", value: "\(stats.articles)")
                    LabeledContent("Downloaded for offline", value: "\(stats.downloaded)")
                    LabeledContent("Database", value: Format.bytes(stats.databaseBytes))
                    LabeledContent("Changes waiting to sync", value: "\(stats.pendingChanges)")
                }
                LabeledContent("Image cache", value: Format.bytes(imageBytes))
            }
            Section {
                Picker("Keep read articles", selection: $model.reading.retentionDays) {
                    Text("1 week").tag(7)
                    Text("1 month").tag(30)
                    Text("45 days").tag(45)
                    Text("3 months").tag(90)
                    Text("Forever").tag(0)
                }
                Button("Clean up now") {
                    Task {
                        let removed = await model.pruneNow()
                        cleanupMessage = removed == 1 ? "Removed 1 article." : "Removed \(removed) articles."
                        await refresh()
                    }
                }
                .disabled(model.reading.retentionDays == 0)
                if let cleanupMessage { Text(cleanupMessage).font(.footnote).foregroundStyle(.secondary) }
            } footer: {
                Text("Saved, downloaded and unread articles are never removed.")
            }
            Section {
                Button("Clear image cache", role: .destructive) {
                    Task {
                        await model.imageCache.clear()
                        await refresh()
                    }
                }
            } footer: {
                Text("Images of downloaded articles are fetched again when you open them online.")
            }
        }
        .navigationTitle("Storage")
        .task { await refresh() }
    }

    private func refresh() async {
        stats = try? await model.store.stats()
        imageBytes = await model.imageCache.totalBytes()
    }
}
