import SwiftUI
import FolioCore
import FolioFreshRSS
import FolioFeeds

/// Choosing what to read, for people who have never used a feed reader:
/// starter packs, well-known sources by topic, and any website by address.
/// `start` begins a reading list on this iPhone; `add` adds to the current one.
struct FeedPickerView: View {
    enum Mode { case start, add }

    let mode: Mode
    @Environment(AppModel.self) private var model
    @Environment(\.folioTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    /// In the order they were picked.
    @State private var chosen: [AppModel.NewFeed] = []
    @State private var languages: Set<String> = FeedPickerView.initialLanguages
    @State private var query = ""
    @State private var found: FoundFeed?
    @State private var finding = false
    @State private var findError: String?
    @State private var working = false
    @State private var failed: [String] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if mode == .start { intro }
                    searchField
                    if !query.isEmpty {
                        searchResults
                    } else {
                        languageChips
                        packs
                        ForEach(CatalogFeed.Topic.allCases) { topic in
                            let feeds = catalog.filter { $0.topic == topic }
                            if !feeds.isEmpty { TopicSection(topic: topic, feeds: feeds, row: row) }
                        }
                        Text("Paperwire checks these sites for new stories straight from your iPhone. Some publishers show only a summary, and a few stories need a subscription.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, mode == .start ? 8 : 4)
                .padding(.bottom, 24)
                .foregroundStyle(Color(theme.text))
            }
            .scrollDismissesKeyboard(.interactively)
            .folioScreen(theme)
            .navigationTitle(mode == .start ? "" : "Add sources")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(mode == .start ? "Back" : "Cancel") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) { doneBar }
            .alert("Some sources couldn't be added", isPresented: Binding(get: { !failed.isEmpty }, set: { if !$0 { failed = [] } })) {
                Button("OK") { dismiss() }
            } message: {
                Text(failed.joined(separator: ", "))
            }
        }
        .accessibilityIdentifier("feed-picker")
    }

    // MARK: Parts

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What do you like to read?")
                .font(.system(.largeTitle, design: .serif, weight: .bold))
            Text("Pick a few sources. Paperwire collects their new stories in one calm place and can read every one aloud. You can add any website later.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search, or paste a website", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.webSearch)
                .submitLabel(.search)
                .onSubmit { Task { await find() } }
                .accessibilityIdentifier("feed-search")
            if !query.isEmpty {
                Button { query = ""; found = nil; findError = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(Color(theme.surface), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onChange(of: query) { found = nil; findError = nil }
    }

    @ViewBuilder private var searchResults: some View {
        let needle = query.lowercased()
        let matches = FeedCatalog.feeds.filter {
            $0.title.lowercased().contains(needle) || $0.site.contains(needle) || $0.topic.label.lowercased().contains(needle)
        }
        VStack(alignment: .leading, spacing: 12) {
            if FeedFinder.address(from: query) != nil {
                websiteRow
            }
            if !matches.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(matches.enumerated()), id: \.element.id) { index, feed in
                        if index > 0 { ThemeDivider().padding(.leading, 64) }
                        row(feed)
                    }
                }
                .background(Color(theme.surface), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else if FeedFinder.address(from: query) == nil {
                Text("Nothing by that name in our list. Paste the site's address, like theverge.com, and Paperwire finds its feed.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    /// A site typed or pasted in: look it up, then add what was found.
    @ViewBuilder private var websiteRow: some View {
        HStack(spacing: 12) {
            ThemeArtwork(key: query, symbol: "link")
                .frame(width: 40, height: 40)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                if let found {
                    Text(found.title).font(.headline).lineLimit(1)
                    Text("\(found.feedURL.host ?? "") · \(found.itemCount) \(found.itemCount == 1 ? "story" : "stories") now")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else if let findError {
                    Text(FeedFinder.address(from: query)?.host ?? query).font(.headline).lineLimit(1)
                    Text(findError).font(.caption).foregroundStyle(.orange).lineLimit(2)
                } else {
                    Text("Find the feed on \(FeedFinder.address(from: query)?.host ?? query)").font(.headline).lineLimit(1)
                    Text("Paperwire looks for the site's feed").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if finding {
                ProgressView()
            } else if let found {
                let feed = AppModel.NewFeed(url: found.feedURL, title: found.title, category: nil)
                ToggleMark(isOn: isChosen(feed.url), isFollowed: isFollowed(feed.url)) { toggle(feed) }
            } else {
                Button("Find") { Task { await find() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityIdentifier("find-feed")
            }
        }
        .padding(12)
        .background(Color(theme.surface), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var languageChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(FeedCatalog.languages, id: \.self) { code in
                    let on = languages.contains(code)
                    Button {
                        if on, languages.count > 1 { languages.remove(code) } else { languages.insert(code) }
                    } label: {
                        Text(StationText.languageName(code))
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14).frame(height: 34)
                            .foregroundStyle(on ? Color(theme.background) : Color(theme.text))
                            .background(on ? Color(theme.accent) : Color(theme.surface), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.horizontal, 20)
        }
        .padding(.horizontal, -20)
    }

    private var packs: some View {
        let visible = FeedCatalog.packs.filter { languages.contains($0.language) }
        return VStack(alignment: .leading, spacing: 10) {
            Text("Start with a pack").font(.system(.title3, design: .serif, weight: .bold)).accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(visible) { pack in
                        PackCard(pack: pack, isOn: pack.feedURLs.allSatisfy { isChosen($0) || isFollowed($0) }) { togglePack(pack) }
                    }
                }
                .padding(.horizontal, 20)
            }
            .padding(.horizontal, -20)
            .scrollClipDisabled()
        }
    }

    private var doneBar: some View {
        let count = chosen.count
        let title = mode == .start
            ? (count == 0 ? "Pick a few sources" : "Start reading · \(count) \(count == 1 ? "source" : "sources")")
            : (count == 0 ? "Pick sources to add" : "Add \(count) \(count == 1 ? "source" : "sources")")
        return Button {
            Task { await finish() }
        } label: {
            HStack(spacing: 8) {
                if working { ProgressView().tint(.white) }
                Text(working ? "Collecting stories…" : title).font(.headline)
            }
            .frame(maxWidth: .infinity, minHeight: 52)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .disabled(count == 0 || working)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
        .accessibilityIdentifier("start-reading")
    }

    private func row(_ feed: CatalogFeed) -> some View {
        let new = AppModel.NewFeed(url: feed.url, title: feed.title, category: feed.topic.label)
        return Button { toggle(new) } label: {
            HStack(spacing: 12) {
                ThemeArtwork(key: feed.site, initial: feed.title)
                    .frame(width: 40, height: 40)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(feed.title).font(.headline).lineLimit(1)
                    Text(feed.blurb).font(.caption).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                ToggleMark(isOn: isChosen(feed.url), isFollowed: isFollowed(feed.url))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isFollowed(feed.url))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(feed.title). \(feed.blurb)")
        .accessibilityValue(isFollowed(feed.url) ? "Following" : (isChosen(feed.url) ? "Chosen" : ""))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("feed-\(feed.title)")
    }

    // MARK: Choosing

    private var catalog: [CatalogFeed] { FeedCatalog.feeds(in: languages) }

    private func isChosen(_ url: URL) -> Bool { chosen.contains { $0.url == url } }

    private func isFollowed(_ url: URL) -> Bool { model.followedFeedKeys.contains(AppModel.feedKey(url)) }

    private func toggle(_ feed: AppModel.NewFeed) {
        guard !isFollowed(feed.url) else { return }
        if isChosen(feed.url) { chosen.removeAll { $0.url == feed.url } } else { chosen.append(feed) }
    }

    private func togglePack(_ pack: StarterPack) {
        let feeds = pack.feedURLs.compactMap(FeedCatalog.feed).filter { !isFollowed($0.url) }
        if feeds.allSatisfy({ isChosen($0.url) }) {
            chosen.removeAll { chosenFeed in feeds.contains { $0.url == chosenFeed.url } }
        } else {
            for feed in feeds where !isChosen(feed.url) {
                chosen.append(AppModel.NewFeed(url: feed.url, title: feed.title, category: feed.topic.label))
            }
        }
    }

    private func find() async {
        guard FeedFinder.address(from: query) != nil, !finding else { return }
        finding = true
        findError = nil
        do {
            found = try await FeedFinder(transport: URLSessionTransport(timeout: 15)).find(query)
        } catch {
            findError = error.description
        }
        finding = false
    }

    private func finish() async {
        working = true
        let failures = mode == .start ? await model.startReadingList(with: chosen) : await model.addFeeds(chosen)
        working = false
        if failures.isEmpty { dismiss() } else { failed = failures }
    }

    /// The phone's languages that the catalog has, or English.
    static var initialLanguages: Set<String> {
        let phone = Set(Locale.preferredLanguages.map { LanguageCode($0).base }).intersection(FeedCatalog.languages)
        return phone.isEmpty ? ["en"] : phone.union(["en"])
    }
}

/// The add button on each source: a plus, a tick once chosen, a quiet
/// "Following" for ones already there.
private struct ToggleMark: View {
    let isOn: Bool
    let isFollowed: Bool
    /// nil inside a row that is itself the button.
    var action: (() -> Void)?
    @Environment(\.folioTheme) private var theme

    var body: some View {
        if isFollowed {
            Text("Following").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        } else if let action {
            Button(action: action) { mark }
                .buttonStyle(.plain)
                .accessibilityLabel(isOn ? "Remove" : "Add")
        } else {
            mark
        }
    }

    private var mark: some View {
        Image(systemName: isOn ? "checkmark.circle.fill" : "plus.circle")
            .font(.title2)
            .foregroundStyle(Color(theme.accent))
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 44, height: 44)
    }
}

private struct TopicSection<Row: View>: View {
    let topic: CatalogFeed.Topic
    let feeds: [CatalogFeed]
    let row: (CatalogFeed) -> Row
    @Environment(\.folioTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(topic.label, systemImage: topic.symbol)
                .font(.system(.title3, design: .serif, weight: .bold))
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(Array(feeds.enumerated()), id: \.element.id) { index, feed in
                    if index > 0 { ThemeDivider().padding(.leading, 64) }
                    row(feed)
                }
            }
            .background(Color(theme.surface), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

private struct PackCard: View {
    let pack: StarterPack
    let isOn: Bool
    let toggle: () -> Void
    @Environment(\.folioTheme) private var theme

    var body: some View {
        Button(action: toggle) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: pack.symbol).font(.title3)
                    Spacer()
                    Image(systemName: isOn ? "checkmark.circle.fill" : "plus.circle").font(.title3)
                        .contentTransition(.symbolEffect(.replace))
                }
                Spacer(minLength: 4)
                Text(pack.title).font(.system(.headline, design: .serif, weight: .bold)).lineLimit(1)
                Text(pack.subtitle).font(.caption).lineLimit(2).opacity(0.85)
                Text(pack.feedURLs.compactMap { FeedCatalog.feed($0)?.title }.joined(separator: " · "))
                    .font(.caption2.weight(.semibold)).lineLimit(1).opacity(0.75)
            }
            .foregroundStyle(.white)
            .padding(14)
            .frame(width: 230, height: 150, alignment: .topLeading)
            .background {
                ThemeArtwork(key: pack.id)
                    .overlay(Color.black.opacity(isOn ? 0 : 0.12))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color(theme.accent), lineWidth: isOn ? 3 : 0)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(pack.title) pack. \(pack.subtitle)")
        .accessibilityValue(isOn ? "Chosen" : "")
        .accessibilityIdentifier("pack-\(pack.title)")
    }
}
