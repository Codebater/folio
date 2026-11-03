import SwiftUI
import FolioCore

/// The sources the reader follows, by topic: add more (popular ones or any
/// website), see which can't be reached, swipe to unfollow.
struct SourcesView: View {
    @Environment(AppModel.self) private var model
    @State private var showPicker = false
    @State private var problems: [FeedID: String] = [:]
    @State private var unfollowing: Feed?

    var body: some View {
        List {
            Section {
                Button {
                    showPicker = true
                } label: {
                    Label("Add sources", systemImage: "plus.circle.fill")
                }
                .accessibilityIdentifier("add-sources")
            } footer: {
                Text(model.account == .local
                     ? "Paperwire checks these sites for new stories from your iPhone each time it syncs."
                     : "Sources you add here are added to your FreshRSS server too.")
            }
            ForEach(groups, id: \.label) { group in
                Section(group.label) {
                    ForEach(group.feeds) { feed in
                        HStack(spacing: 12) {
                            ThemeArtwork(key: feed.siteURL?.host ?? feed.title, initial: feed.title)
                                .frame(width: 34, height: 34)
                                .clipShape(Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                Text(feed.title).lineLimit(1)
                                if let problem = problems[feed.id] {
                                    Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                                } else if let host = feed.siteURL?.host ?? feed.feedURL?.host {
                                    Text(host).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .swipeActions {
                            Button("Unfollow", role: .destructive) { unfollowing = feed }
                        }
                    }
                }
            }
        }
        .navigationTitle("Sources")
        .overlay {
            if model.feeds.isEmpty {
                ContentUnavailableView("No sources yet", systemImage: "dot.radiowaves.up.forward",
                                       description: Text("Add a few and their new stories appear in Today."))
            }
        }
        .sheet(isPresented: $showPicker) { FeedPickerView(mode: .add) }
        .confirmationDialog("Unfollow \(unfollowing?.title ?? "")?", isPresented: Binding(
            get: { unfollowing != nil }, set: { if !$0 { unfollowing = nil } }), titleVisibility: .visible, presenting: unfollowing
        ) { feed in
            Button("Unfollow", role: .destructive) { Task { await model.removeFeed(feed.id) } }
        } message: { _ in
            Text("Its stories leave your library, except ones you starred.")
        }
        .task(id: model.revision) { problems = await model.feedProblems() }
    }

    private var groups: [(label: String, feeds: [Feed])] {
        let labels = Dictionary(uniqueKeysWithValues: model.categories.map { ($0.id, $0.label) })
        let grouped = Dictionary(grouping: model.feeds) { feed in feed.categoryIDs.compactMap { labels[$0] }.first ?? "Other" }
        return grouped
            .map { (label: $0.key, feeds: $0.value.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }) }
            .sorted { $0.label == "Other" ? false : ($1.label == "Other" ? true : $0.label < $1.label) }
    }
}
