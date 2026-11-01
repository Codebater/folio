import SwiftUI
import FolioCore
import FolioReader

/// The front page: today's date as a masthead, one lead story, what you
/// were in the middle of, then fresh stories grouped by category.
struct TodayView: View {
    @Binding var showSettings: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.folioTheme) private var theme
    @State private var unread: [ArticleSummary] = []
    @State private var inProgress: [ArticleSummary] = []
    /// Unread articles mentioning a watch word, with the word.
    @State private var watching: [(article: ArticleSummary, term: String)] = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                masthead
                if let problem = model.storageProblem {
                    Label(problem, systemImage: "externaldrive.badge.exclamationmark").font(.footnote).foregroundStyle(.orange)
                }
                if unread.isEmpty && inProgress.isEmpty {
                    ContentUnavailableView {
                        Label("All caught up", systemImage: "checkmark.seal")
                    } description: {
                        Text("New articles appear here after a sync. Your saved and downloaded articles are in the Library.")
                    }
                    .padding(.top, 40)
                } else {
                    if !watching.isEmpty { watchingSection }
                    if let lead = unread.first {
                        NavigationLink(value: lead.id) { LeadStory(article: lead) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("featured-story")
                    }
                    QuickReadCard(unread: unread)
                    if !inProgress.isEmpty { continueReading }
                    ForEach(sections, id: \.title) { section in
                        TodaySection(title: section.title, articles: section.articles)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
            .foregroundStyle(Color(theme.text))
        }
        .folioScreen(theme)
        .refreshable { await model.sync() }
        .navigationDestination(for: ArticleID.self) { ReaderView(articleID: $0) }
        .toolbar { ToolbarItem(placement: .topBarTrailing) { SettingsToolbarButton(showSettings: $showSettings) } }
        .task(id: model.revision) { await reload() }
    }

    private var masthead: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Date().formatted(.dateTime.weekday(.wide)))
                .font(.system(.largeTitle, design: .serif, weight: .bold))
            HStack {
                Text(Date().formatted(.dateTime.month(.wide).day()))
                if model.reading.showsCounts {
                    Text("·")
                    Text("\(model.unread.total) unread")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            SyncStatusLabel().font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
    }

    private var continueReading: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Continue reading")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(inProgress) { article in
                        NavigationLink(value: article.id) { ContinueCard(article: article) }.buttonStyle(.plain)
                    }
                }
            }
            .scrollClipDisabled()
        }
    }

    private var sections: [(title: String, articles: [ArticleSummary])] {
        let rest = unread.dropFirst()
        var byCategory: [String: [ArticleSummary]] = [:]
        var order: [String] = []
        for article in rest {
            let feed = model.feeds.first { $0.id == article.feedID }
            let title = feed?.categoryIDs.first.flatMap { id in model.categories.first { $0.id == id }?.label } ?? "More"
            if byCategory[title] == nil { order.append(title) }
            byCategory[title, default: []].append(article)
        }
        return order.map { ($0, Array(byCategory[$0, default: []].prefix(6))) }
    }

    private var watchingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Watching")
            ForEach(watching, id: \.article.id) { match in
                NavigationLink(value: match.article.id) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(match.term)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Color(theme.accent), in: Capsule())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(match.article.title).font(.system(.subheadline, design: .serif, weight: .semibold)).lineLimit(2)
                            Text(match.article.feedTitle).font(.caption).foregroundStyle(.secondary)
                        }
                        .multilineTextAlignment(.leading)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("watching")
    }

    private func reload() async {
        // One card per story: copies from other feeds are behind its source count.
        let fresh = await model.summaries(ArticleQuery(filter: .unread, limit: 200)).filter { !model.duplicates.contains($0.id) }
        unread = fresh
        inProgress = await model.summaries(ArticleQuery(filter: .inProgress, limit: 10))
        let watch = model.reading.watch
        watching = watch.isEmpty ? [] : Array(fresh.lazy.compactMap { article in
            watch.match(article.title + " " + article.excerpt).map { (article, $0) }
        }.prefix(6))
    }
}

struct SectionHeader: View {
    let title: String
    @Environment(\.folioTheme) private var theme

    var body: some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(1.2)
            .foregroundStyle(Color(theme.accent))
            .accessibilityAddTraits(.isHeader)
    }
}

private struct LeadStory: View {
    let article: ArticleSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ArticleThumbnail(url: article.leadImageURL, fallbackText: article.feedTitle)
                .aspectRatio(16 / 10, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            Text(article.feedTitle.uppercased())
                .font(.caption.weight(.semibold)).tracking(1).foregroundStyle(.secondary)
            Text(article.title)
                .font(.system(.title, design: .serif, weight: .bold))
                .multilineTextAlignment(.leading)
            if !article.excerpt.isEmpty {
                Text(article.excerpt).font(.system(.body, design: .serif)).foregroundStyle(.secondary).lineLimit(3)
            }
            Text("\(Format.relative(article.publishedAt)) · \(Format.readingTime(article.estimatedReadingMinutes))")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the article")
    }
}

private struct ContinueCard: View {
    let article: ArticleSummary
    @Environment(\.folioTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(article.title)
                .font(.system(.headline, design: .serif))
                .lineLimit(3)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            ProgressView(value: article.readingProgress ?? 0).tint(Color(theme.accent))
            Text(article.feedTitle).font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 220, height: 130, alignment: .topLeading)
        .background(Color(theme.surface), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityValue("\(Int((article.readingProgress ?? 0) * 100)) percent read")
    }
}

private struct TodaySection: View {
    let title: String
    let articles: [ArticleSummary]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: title)
            ForEach(articles) { article in
                NavigationLink(value: article.id) { ArticleRow(article: article) }.buttonStyle(.plain)
                if article.id != articles.last?.id { ThemeDivider() }
            }
        }
    }
}

/// "Got a few minutes?": unread articles that fit the time, one per source,
/// newest first, so a coffee or a commute gets a complete little read.
private struct QuickReadCard: View {
    let unread: [ArticleSummary]
    @State private var minutes = 10
    @Environment(\.folioTheme) private var theme

    private var picks: [ArticleSummary] { QuickRead.pick(from: unread, minutes: minutes) }

    var body: some View {
        let chosen = picks
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Got a few minutes?").font(.system(.title3, design: .serif, weight: .bold))
                Spacer()
                Picker("Minutes", selection: $minutes) {
                    Text("5").tag(5)
                    Text("10").tag(10)
                    Text("20").tag(20)
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
                .accessibilityLabel("Minutes to read")
            }
            if chosen.isEmpty {
                Text("Nothing unread fits right now.").font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(chosen) { article in
                    NavigationLink(value: article.id) {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(article.title).font(.system(.subheadline, design: .serif, weight: .semibold)).lineLimit(2)
                                Text(article.feedTitle).font(.caption).foregroundStyle(.secondary)
                            }
                            .multilineTextAlignment(.leading)
                            Spacer(minLength: 8)
                            Text("\(article.estimatedReadingMinutes) min").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                Text("\(chosen.reduce(0) { $0 + $1.estimatedReadingMinutes }) minutes of reading from \(Set(chosen.map(\.feedID)).count) sources")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(Color(theme.surface), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("quick-read")
    }
}

enum QuickRead {
    /// Newest first, one article per feed, nothing longer than the time left.
    static func pick(from unread: [ArticleSummary], minutes: Int) -> [ArticleSummary] {
        var left = minutes
        var feeds: Set<FeedID> = []
        var picked: [ArticleSummary] = []
        for article in unread where !feeds.contains(article.feedID) && article.wordCount >= 120 {
            let length = max(1, article.estimatedReadingMinutes)
            guard length <= left else { continue }
            picked.append(article)
            feeds.insert(article.feedID)
            left -= length
            if left <= 1 || picked.count == 4 { break }
        }
        return picked
    }
}
