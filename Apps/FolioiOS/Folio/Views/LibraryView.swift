import SwiftUI
import FolioCore
import FolioAudio
import FolioReader

struct ArticleListRoute: Hashable {
    var title: String
    var scope: ArticleScope
    var filter: ArticleFilter

    /// Stable key for remembering where the reader left this list.
    var markerKey: String {
        switch scope {
        case .everything: "all"
        case .feed(let id): "feed:\(id.rawValue)"
        case .category(let id): "category:\(id.rawValue)"
        }
    }
}

struct LibraryView: View {
    @Binding var showSettings: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.folioTheme) private var theme

    private var showsCounts: Bool { model.reading.showsCounts }

    var body: some View {
        List {
            ScreenHeader {
                VStack(alignment: .leading, spacing: 2) {
                    ScreenTitle(text: "Library").accessibilityIdentifier("library-title")
                    SyncStatusLabel().font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            } trailing: {
                SettingsToolbarButton(showSettings: $showSettings)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
            .listRowSeparator(.hidden)
            Section {
                smartRow("Unread", "circle.inset.filled", .unread, count: model.unread.total)
                smartRow("Saved", "star", .starred, count: model.unread.starred)
                smartRow("Continue reading", "book", .inProgress, count: nil)
                smartRow("Downloaded", "arrow.down.circle", .downloaded, count: nil)
                smartRow("All articles", "tray.full", .all, count: nil)
            }
            if !model.categories.isEmpty {
                Section("Categories") {
                    ForEach(model.categories) { category in
                        DisclosureGroup {
                            ForEach(model.feeds.filter { $0.categoryIDs.contains(category.id) }) { feed in
                                feedRow(feed)
                            }
                        } label: {
                            NavigationLink(value: ArticleListRoute(title: category.label, scope: .category(category.id), filter: .unread)) {
                                LabeledContent(category.label) { CountBadge(count: showsCounts ? model.unread.byCategory[category.id] : nil) }
                            }
                        }
                        .folioRow(theme)
                    }
                }
            }
            let uncategorized = model.feeds.filter { $0.categoryIDs.isEmpty }
            if !uncategorized.isEmpty {
                Section("Feeds") { ForEach(uncategorized) { feedRow($0) } }
            }
        }
        .listStyle(.insetGrouped)
        .folioScreen(theme)
        .navigationTitle("Library")
        .toolbar(.hidden, for: .navigationBar)
        .softTopEdge()
        .refreshable { await model.sync() }
        .navigationDestination(for: ArticleListRoute.self) { ArticleListView(route: $0) }
        .navigationDestination(for: ArticleID.self) { ReaderView(articleID: $0) }
        .overlay {
            if model.feeds.isEmpty {
                ContentUnavailableView("No feeds yet", systemImage: "dot.radiowaves.up.forward",
                                       description: Text("Feeds you subscribe to in FreshRSS show up here after a sync."))
            }
        }
    }

    private func smartRow(_ title: String, _ icon: String, _ filter: ArticleFilter, count: Int?) -> some View {
        NavigationLink(value: ArticleListRoute(title: title, scope: .everything, filter: filter)) {
            LabeledContent { CountBadge(count: showsCounts ? count : nil) } label: { Label(title, systemImage: icon) }
        }
        .folioRow(theme)
    }

    private func feedRow(_ feed: Feed) -> some View {
        NavigationLink(value: ArticleListRoute(title: feed.title, scope: .feed(feed.id), filter: .unread)) {
            LabeledContent(feed.title) { CountBadge(count: showsCounts ? model.unread.byFeed[feed.id] : nil) }
        }
        .folioRow(theme)
    }
}

private struct CountBadge: View {
    let count: Int?

    var body: some View {
        if let count, count > 0 {
            Text("\(count)").monospacedDigit().foregroundStyle(.secondary)
        }
    }
}

/// Articles for a feed, category or smart list, newest first, with keyset
/// pagination, compact or comfortable rows, configurable swipes, optional
/// mark-read-on-scroll and a "where you left off" marker.
struct ArticleListView: View {
    let route: ArticleListRoute
    @Environment(AppModel.self) private var model
    @Environment(\.folioTheme) private var theme
    @State private var filter: ArticleFilter
    @State private var articles: [ArticleSummary] = []
    @State private var reachedEnd = false
    @State private var marker: ArticleID?
    @State private var visible: Set<Int> = []
    @State private var pendingRead: Set<ArticleID> = []
    @State private var flushTask: Task<Void, Never>?

    init(route: ArticleListRoute) {
        self.route = route
        _filter = State(initialValue: route.filter)
    }

    private var canToggleFilter: Bool { route.filter == .unread || route.filter == .all }
    private var compact: Bool { model.reading.density == .compact }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(Array(articles.enumerated()), id: \.element.id) { index, article in
                    if article.id == marker, index > 0 {
                        LeftOffDivider().id("left-off").listRowBackground(Color(theme.background))
                    }
                    SwipeableArticleRow(article: article, compact: compact)
                        .listRowBackground(Color(theme.background))
                        .listRowSeparatorTint(Color(theme.separator))
                        .onAppear {
                            visible.insert(index)
                            if article.id == articles.last?.id { Task { await loadMore() } }
                        }
                        .onDisappear {
                            visible.remove(index)
                            scrolledPast(index)
                        }
                }
            }
            .listStyle(.plain)
            .folioScreen(theme)
            .navigationTitle(route.title)
            .refreshable { await model.sync() }
            .toolbar {
                if marker != nil, articles.first?.id != marker {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            withAnimation { proxy.scrollTo("left-off", anchor: .top) }
                        } label: {
                            Image(systemName: "bookmark")
                        }
                        .accessibilityLabel("Jump to where you left off")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) { optionsMenu }
            }
        }
        .overlay {
            if articles.isEmpty {
                ContentUnavailableView(filter == .unread ? "Nothing unread" : "No articles", systemImage: "tray")
            }
        }
        .task(id: "\(model.revision)-\(filter)") { await reload() }
        .onDisappear {
            flushReads()
            if let top = visible.min(), top < articles.count { model.setListMarker(articles[top].id, for: route.markerKey) }
        }
    }

    private var optionsMenu: some View {
        Menu {
            if canToggleFilter {
                Picker("Show", selection: $filter) {
                    Text("Unread").tag(ArticleFilter.unread)
                    Text("All").tag(ArticleFilter.all)
                }
            }
            Picker("Rows", selection: Binding(get: { model.reading.density }, set: { model.reading.density = $0 })) {
                Label("Comfortable", systemImage: "rectangle.grid.1x2").tag(ReadingPreferences.Density.comfortable)
                Label("Compact", systemImage: "list.bullet").tag(ReadingPreferences.Density.compact)
            }
            if model.reading.showsCounts {
                Button("Mark all as read", systemImage: "checkmark.circle") {
                    Task { await model.markAllRead(route.scope) }
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel("List options")
    }

    /// A row that disappears while rows after it are still visible has been
    /// scrolled past the top (not off the bottom).
    private func scrolledPast(_ index: Int) {
        guard model.reading.markReadOnScroll, index < articles.count, let top = visible.min(), top > index else { return }
        let article = articles[index]
        guard !article.isRead else { return }
        pendingRead.insert(article.id)
        flushTask?.cancel()
        flushTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            flushReads()
        }
    }

    private func flushReads() {
        guard !pendingRead.isEmpty else { return }
        let ids = Array(pendingRead)
        pendingRead.removeAll()
        Task { await model.setRead(true, ids) }
    }

    /// Smart lists show each story once; a feed's own list shows everything it has.
    private func deduplicated(_ items: [ArticleSummary]) -> [ArticleSummary] {
        guard case .everything = route.scope else { return items }
        return items.filter { !model.duplicates.contains($0.id) }
    }

    private func reload() async {
        let raw = await model.summaries(ArticleQuery(scope: route.scope, filter: filter, limit: 50))
        let loaded = deduplicated(raw)
        if marker == nil { marker = model.listMarker(route.markerKey) }
        articles = loaded
        reachedEnd = raw.count < 50  // judged before hiding copies, so paging goes on
    }

    private func loadMore() async {
        guard !reachedEnd, let last = articles.last, filter != .inProgress else { return }
        let page = await model.summaries(ArticleQuery(scope: route.scope, filter: filter, limit: 50, before: (last.publishedAt, last.id)))
        let more = deduplicated(page)
        reachedEnd = page.count < 50
        articles += more.filter { item in !articles.contains { $0.id == item.id } }
    }
}

private struct LeftOffDivider: View {
    @Environment(\.folioTheme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Color(theme.accent).opacity(0.5)).frame(height: 1)
            Text("WHERE YOU LEFT OFF").font(.caption2.weight(.semibold)).tracking(1).foregroundStyle(Color(theme.accent))
            Rectangle().fill(Color(theme.accent).opacity(0.5)).frame(height: 1)
        }
        .listRowSeparator(.hidden)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Where you left off")
    }
}

/// A list row with the swipe actions chosen in Settings.
private struct SwipeableArticleRow: View {
    let article: ArticleSummary
    let compact: Bool
    @Environment(AppModel.self) private var model
    @Environment(ListenModel.self) private var listen

    var body: some View {
        NavigationLink(value: article.id) { ArticleRow(article: article, compact: compact) }
            .swipeActions(edge: .leading) { button(model.reading.leadingSwipe) }
            .swipeActions(edge: .trailing) {
                button(model.reading.trailingSwipe)
                button(model.reading.secondaryTrailingSwipe)
            }
    }

    @ViewBuilder
    private func button(_ action: ReadingPreferences.SwipeAction) -> some View {
        switch action {
        case .toggleRead:
            Button {
                Task { await model.setRead(!article.isRead, [article.id]) }
            } label: {
                Label(article.isRead ? "Unread" : "Read", systemImage: article.isRead ? "circle" : "checkmark.circle")
            }
            .tint(.blue)
        case .toggleSaved:
            Button {
                Task { await model.setStarred(!article.isStarred, [article.id]) }
            } label: {
                Label(article.isStarred ? "Unsave" : "Save", systemImage: article.isStarred ? "star.slash" : "star")
            }
            .tint(.orange)
        case .listenLater:
            Button { listen.enqueue(item) } label: { Label("Listen later", systemImage: "text.badge.plus") }
                .tint(.indigo)
        case .playNext:
            Button { listen.enqueueNext(item) } label: { Label("Play next", systemImage: "text.line.first.and.arrowtriangle.forward") }
                .tint(.purple)
        case .none:
            EmptyView()
        }
    }

    private var item: ListenItem { ListenItem(id: article.id, title: article.title, feedTitle: article.feedTitle) }
}

struct ArticleRow: View {
    let article: ArticleSummary
    var compact = false
    @Environment(AppModel.self) private var model
    @Environment(\.folioTheme) private var theme

    private var showsUnreadDot: Bool { !article.isRead && model.reading.showsCounts }
    /// How many feeds carry this story (1 when only this one).
    private var sources: Int { model.storyGroups[article.id]?.count ?? 1 }

    private var sourcesBadge: some View {
        Label("\(sources) sources", systemImage: "square.stack.3d.up")
            .labelStyle(.titleAndIcon)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color(theme.accent))
            .accessibilityLabel("Reported by \(sources) of your feeds")
    }

    var body: some View {
        Group {
            if compact { compactBody } else { comfortableBody }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(article.isRead ? "" : "Unread. ")\(article.title), \(article.feedTitle)")
    }

    /// Title and source on one or two lines: fast triage of many feeds.
    private var compactBody: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(Color(theme.accent)).frame(width: 6, height: 6).opacity(showsUnreadDot ? 1 : 0)
            VStack(alignment: .leading, spacing: 2) {
                Text(article.title)
                    .font(.system(.subheadline, design: .serif, weight: article.isRead ? .regular : .semibold))
                    .foregroundStyle(article.isRead ? .secondary : .primary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text("\(article.feedTitle) · \(Format.relative(article.publishedAt))")
                        .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    if sources > 1 { sourcesBadge }
                }
            }
            Spacer(minLength: 0)
            if article.isStarred { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.orange) }
        }
        .padding(.vertical, 2)
    }

    private var comfortableBody: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    if showsUnreadDot {
                        Circle().fill(Color(theme.accent)).frame(width: 7, height: 7).accessibilityHidden(true)
                    }
                    Text(article.feedTitle).font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                    if article.isStarred { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.orange) }
                    if article.isDownloaded { Image(systemName: "arrow.down.circle.fill").font(.caption2).foregroundStyle(.secondary) }
                    if sources > 1 { sourcesBadge }
                }
                Text(article.title)
                    .font(.system(.headline, design: .serif))
                    .foregroundStyle(article.isRead ? .secondary : .primary)
                    .lineLimit(3)
                if !article.excerpt.isEmpty {
                    Text(article.excerpt).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
                Text("\(Format.relative(article.publishedAt)) · \(Format.readingTime(article.estimatedReadingMinutes))")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            if article.leadImageURL != nil {
                ArticleThumbnail(url: article.leadImageURL, fallbackText: article.feedTitle)
                    .frame(width: 76, height: 76)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(.vertical, 6)
    }
}
