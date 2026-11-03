import SwiftUI
import FolioCore
import FolioReader
import FolioAudio
import FolioStorage

/// The immersive reading screen. In paginated mode the left and right edges
/// turn pages. While this article is narrated, tapping a word reads on from
/// the start of its sentence. Otherwise a tap on text marks that sentence and
/// offers to listen from there (tap it again, or the button, to start); a
/// tap beside the text hides or shows the chrome.
struct ReaderView: View {
    let articleID: ArticleID

    @Environment(AppModel.self) private var model
    @Environment(ListenModel.self) private var listen
    @Environment(EntitlementStore.self) private var entitlements
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var loaded: LoadedArticle?
    @State private var html = ""
    @State private var bridge = ReaderBridge()
    @State private var chromeVisible = true
    @State private var showAppearance = false
    @State private var position: ReaderPagePosition?
    @State private var followNarration = true
    @State private var pendingRestore: ReadingPosition?
    @State private var linkToOpen: URL?
    @State private var isStarred = false
    @State private var isDownloading = false
    @State private var lastSavedAt = Date.distantPast
    @State private var fullText: FullTextState = .none
    /// A sentence the reader tapped while nothing was playing.
    @State private var tapStart: TapStart?
    @Environment(\.openURL) private var openURL

    enum FullTextState { case none, loading, unavailable }

    struct TapStart: Equatable {
        var position: SpeechPosition
        var sentence: Range<Int>
        /// The sentence's first words, for the button.
        var preview: String
    }

    private var settings: ReaderSettings { model.effectiveReaderSettings(systemIsDark: colorScheme == .dark) }
    private var narratingHere: Bool { listen.isNarrating(articleID) }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(settings.theme.background).ignoresSafeArea()
            if loaded != nil {
                ReaderWebView(html: html, bridge: bridge, imageHandler: model.imageHandler, onEvent: handle,
                              onLink: { linkToOpen = $0 })
                    .ignoresSafeArea()
                    .accessibilityLabel(loaded?.stored.article.title ?? "Article")
            } else {
                ProgressView().tint(Color(settings.theme.secondaryText))
            }
            if narratingHere && !followNarration {
                Button {
                    followNarration = true
                    if let highlight = listen.highlight { bridge.highlight(blockID: highlight.blockID, range: highlight.wordRange, sentence: highlight.sentenceRange, follow: true) }
                } label: {
                    Label("Back to narration", systemImage: "text.line.first.and.arrowtriangle.forward")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.thinMaterial, in: Capsule())
                }
                .padding(.bottom, chromeVisible ? 70 : 24)
                .transition(.opacity)
            }
            if let tapStart, !narratingHere {
                Button {
                    startListening(from: tapStart.position)
                } label: {
                    Label {
                        Text("Listen from “\(tapStart.preview)”").lineLimit(1)
                    } icon: {
                        Image(systemName: "play.fill")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(settings.theme.isDark ? Color(settings.theme.background) : .white)
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .background(Color(settings.theme.accent), in: Capsule())
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, chromeVisible ? 70 : 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityIdentifier("listen-from-tap")
            }
            if settings.layout == .paginated, let position, position.pages > 1, !chromeVisible {
                Text("\(position.page + 1) / \(position.pages)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Color(settings.theme.secondaryText))
                    .padding(.bottom, 6)
                    .accessibilityLabel("Page \(position.page + 1) of \(position.pages)")
            }
        }
        .overlay(alignment: .top) {
            if fullText != .none, chromeVisible {
                FullTextBanner(state: fullText, retry: retryFullText, openOriginal: { linkToOpen = loaded?.stored.article.url })
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay {
            if let loaded, FullTextFetcher.isVideo(loaded.stored.article.url), loaded.document.wordCount < 40,
               let url = loaded.stored.article.url
            {
                VideoCard(title: loaded.stored.article.title, source: loaded.feedTitle) { openURL(url) }
            }
        }
        .animation(.snappy, value: fullText)
        .animation(reduceMotion ? nil : .snappy, value: tapStart)
        .task(id: tapStart) {
            // The offer fades after a while; the marked sentence with it.
            guard tapStart != nil else { return }
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            dismissTapStart()
        }
        .navigationTitle(loaded?.feedTitle ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(chromeVisible ? .visible : .hidden, for: .navigationBar)
        .toolbar(chromeVisible ? .visible : .hidden, for: .bottomBar)
        .toolbar(.hidden, for: .tabBar)
        .statusBarHidden(!chromeVisible)
        .toolbarBackground(Color(settings.theme.background), for: .navigationBar, .bottomBar)
        .toolbarColorScheme(settings.theme.isDark ? .dark : .light, for: .navigationBar, .bottomBar)
        .toolbar { toolbarContent }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: chromeVisible)
        .sheet(isPresented: $showAppearance) { AppearanceSheet().presentationDetents([.medium, .large]) }
        .sheet(item: $linkToOpen) { SafariView(url: $0).ignoresSafeArea() }
        .task(id: articleID) { await load() }
        .onChange(of: settings) { _, new in bridge.apply(new) }
        .onChange(of: listen.highlight) { _, highlight in
            guard let highlight, highlight.articleID == articleID else {
                if !narratingHere { bridge.clearHighlight() }
                return
            }
            bridge.highlight(blockID: highlight.blockID, range: highlight.wordRange, sentence: highlight.sentenceRange, follow: followNarration)
        }
        .onDisappear { savePosition(force: true) }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                isStarred.toggle()
                Task { await model.setStarred(isStarred, [articleID]) }
            } label: {
                Image(systemName: isStarred ? "star.fill" : "star")
            }
            .accessibilityLabel(isStarred ? "Remove from saved" : "Save")
            Menu {
                if let url = loaded?.stored.article.url {
                    ShareLink(item: url)
                    Button("Open original", systemImage: "safari") { linkToOpen = url }
                }
                Button(loaded?.stored.isDownloaded == true ? "Downloaded" : "Download for offline", systemImage: "arrow.down.circle") {
                    Task { await download() }
                }
                .disabled(loaded?.stored.isDownloaded == true || isDownloading)
                Button("Mark as unread", systemImage: "circle") {
                    Task { await model.setRead(false, [articleID]) }
                }
                if let item = listItem {
                    Button("Listen later", systemImage: "text.badge.plus") { listen.enqueue(item) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("More")
        }
        ToolbarItemGroup(placement: .bottomBar) {
            Button {
                showAppearance = true
            } label: {
                Image(systemName: "textformat.size")
            }
            .accessibilityLabel("Appearance")
            Spacer()
            if let position {
                ProgressView(value: position.progress)
                    .frame(width: 120)
                    .tint(Color(settings.theme.accent))
                    .accessibilityLabel("Reading progress")
                    .accessibilityValue("\(Int(position.progress * 100)) percent")
            }
            Spacer()
            listenControl
        }
    }

    @ViewBuilder
    private var listenControl: some View {
        if narratingHere {
            Button {
                listen.togglePlayPause()
            } label: {
                Image(systemName: listen.state.status == .playing ? "pause.circle.fill" : "play.circle.fill").font(.title2)
            }
            .accessibilityLabel(listen.state.status == .playing ? "Pause narration" : "Resume narration")
        } else {
            Menu {
                Button("Listen from the beginning", systemImage: "play") { startListening(fromHere: false) }
                if position?.blockID != nil && (position?.progress ?? 0) > 0.02 {
                    Button("Listen from here", systemImage: "text.line.first.and.arrowtriangle.forward") { startListening(fromHere: true) }
                }
            } label: {
                Image(systemName: "headphones.circle.fill").font(.title2)
            } primaryAction: {
                if let tapStart { startListening(from: tapStart.position) } else { startListening(fromHere: (position?.progress ?? 0) > 0.02) }
            }
            .accessibilityLabel("Listen")
            .accessibilityHint("Reads the article aloud and highlights each word")
        }
    }

    private var listItem: ListenItem? {
        loaded.map { ListenItem(id: articleID, title: $0.stored.article.title, feedTitle: $0.feedTitle) }
    }

    // MARK: Actions

    private func load() async {
        guard let article = await model.load(articleID) else { return }
        loaded = article
        isStarred = article.stored.article.isStarred
        pendingRestore = await model.readingPosition(articleID)
        html = render(article)
        if !article.stored.article.isRead { await model.setRead(true, [articleID]) }
        if model.needsFullText(article.stored) {
            fullText = .loading
            await finishFullText(model.fullTextTask(articleID).value)
        } else if article.stored.fullTextStatus == .unavailable, article.stored.wordCount < AppModel.summaryWordLimit {
            fullText = .unavailable
        }
        await summarizeWithAppleIntelligence()
    }

    /// On iPhones with Apple Intelligence, a written summary replaces the
    /// picked sentences, if the reader hasn't started scrolling yet.
    private func summarizeWithAppleIntelligence() async {
        guard model.reading.showKeyPoints, AISummary.isAvailable, let article = loaded, article.document.wordCount >= 350 else { return }
        let text = article.document.blocks.compactMap { block -> String? in
            if case .paragraph = block.kind { return block.text }
            return nil
        }.joined(separator: "\n")
        guard let points = await AISummary.keyPoints(title: article.stored.article.title, text: text),
              loaded?.stored.article.id == article.stored.article.id, (position?.progress ?? 0) < 0.02
        else { return }
        html = render(article, points: points, pointsLabel: "Summary · Apple Intelligence")
    }

    /// Swaps the summary for the full article once it's there.
    private func finishFullText(_ fetched: Bool) async {
        if fetched, let updated = await model.load(articleID) {
            loaded = updated
            html = render(updated)
            fullText = .none
        } else {
            fullText = .unavailable
        }
    }

    private func retryFullText() {
        fullText = .loading
        Task { await finishFullText(await model.retryFullText(articleID)) }
    }

    /// Key points for longer articles, picked on the device.
    private func keyPoints(_ article: LoadedArticle) -> [String] {
        guard model.reading.showKeyPoints, article.document.wordCount >= 350 else { return [] }
        return KeyPoints.sentences(document: article.document, title: article.stored.article.title,
                                   language: article.document.language ?? article.stored.language)
    }

    private func render(_ article: LoadedArticle, points: [String]? = nil, pointsLabel: String = "Key points") -> String {
        let a = article.stored.article
        let meta = ReaderPageMetadata(
            title: a.title, siteName: article.feedTitle, author: a.author,
            dateText: a.publishedAt.formatted(date: .abbreviated, time: .omitted),
            readingTimeText: Format.readingTime(max(1, article.document.wordCount / 230)), originalURL: a.url,
            keyPoints: points ?? keyPoints(article), keyPointsLabel: pointsLabel)
        let renderer = ReaderHTMLRenderer(settings: settings, imageScheme: FolioImageSchemeHandler.scheme,
                                          imageURLRewriter: { ImageCache.schemeURL(for: $0) })
        return renderer.render(article.document, metadata: meta)
    }

    private func handle(_ event: ReaderEvent) {
        switch event {
        case .ready(let page):
            position = page
            if let saved = pendingRestore, let document = loaded?.document,
               let target = ProgressMap(document: document).resolve(saved), saved.progress > 0.01 {
                bridge.scroll(to: target.blockID, offset: target.offset)
            }
            pendingRestore = nil
            if narratingHere, let highlight = listen.highlight {
                bridge.highlight(blockID: highlight.blockID, range: highlight.wordRange, sentence: highlight.sentenceRange, follow: true)
            }
        case .position(let page):
            position = page
            savePosition(force: false)
        case .tap(let blockID, let offset, let zone):
            if settings.layout == .paginated && zone != "center" {
                zone == "left" ? bridge.previousPage() : bridge.nextPage()
            } else if narratingHere, let blockID {
                followNarration = true
                let tap = SpeechPosition(blockID: blockID, offset: offset)
                Task { await listen.read(from: tap, blockText: blockText(blockID)) }
            } else if let blockID, let start = tapStart(blockID: blockID, offset: offset) {
                if tapStart?.position == start.position {
                    startListening(from: start.position)  // the same sentence again: go
                } else {
                    tapStart = start
                    bridge.highlight(blockID: blockID, range: nil, sentence: start.sentence, follow: false)
                }
            } else {
                dismissTapStart()
                chromeVisible.toggle()
            }
        case .userScroll:
            if narratingHere { followNarration = false } else { dismissTapStart() }
        }
    }

    private func blockText(_ blockID: String) -> String? {
        if blockID == SpeechScript.titleBlockID { return loaded?.stored.article.title }
        return loaded?.document.blocks.first { $0.id == blockID }?.text
    }

    /// The sentence (or long sentence's clause) a tap on text would read from.
    private func tapStart(blockID: String, offset: Int) -> TapStart? {
        guard let loaded, let text = blockText(blockID), !text.isEmpty else { return nil }
        if blockID != SpeechScript.titleBlockID, loaded.document.blocks.first(where: { $0.id == blockID })?.isSpeakable != true { return nil }
        let language = loaded.document.language ?? loaded.stored.language
        let start = TapReading.start(in: text, at: offset, language: language)
        let sentence = TapReading.sentence(in: text, at: offset, language: language) ?? (start..<text.utf16Length)
        let words = String(text.utf16Slice(start..<text.utf16Length)).split(whereSeparator: \.isWhitespace)
        let preview = words.prefix(5).joined(separator: " ") + (words.count > 5 ? "…" : "")
        return TapStart(position: SpeechPosition(blockID: blockID, offset: start),
                        sentence: max(sentence.lowerBound, start)..<sentence.upperBound, preview: preview)
    }

    private func dismissTapStart() {
        guard tapStart != nil else { return }
        tapStart = nil
        if !narratingHere { bridge.clearHighlight() }
    }

    private func startListening(from position: SpeechPosition) {
        guard let item = listItem else { return }
        followNarration = true
        tapStart = nil
        Task { await listen.play(item, from: position) }
    }

    private func startListening(fromHere: Bool) {
        guard let item = listItem else { return }
        followNarration = true
        let start = fromHere ? position?.blockID.map { SpeechPosition(blockID: $0, offset: position?.offset ?? 0) } : nil
        Task { await listen.play(item, from: start) }
    }

    private func download() async {
        isDownloading = true
        await model.download(articleID)
        loaded = await model.load(articleID)
        isDownloading = false
    }

    private func savePosition(force: Bool) {
        guard let position, let blockID = position.blockID, force || Date().timeIntervalSince(lastSavedAt) > 3 else { return }
        lastSavedAt = Date()
        let saved = ReadingPosition(articleID: articleID, blockID: blockID == "title" ? nil : blockID, offset: position.offset,
                                    progress: position.progress, updatedAt: Date())
        Task { await model.saveReadingPosition(saved) }
    }
}

/// Shown while Folio loads the full article, or when only the feed's summary is available.
private struct FullTextBanner: View {
    let state: ReaderView.FullTextState
    let retry: () -> Void
    let openOriginal: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if state == .loading {
                ProgressView().controlSize(.small)
                Text("Getting the full article…").font(.footnote.weight(.semibold))
            } else {
                Image(systemName: "doc.plaintext").font(.footnote)
                Text("The feed sent only a summary").font(.footnote.weight(.semibold))
                Button("Original", action: openOriginal).font(.footnote.weight(.semibold))
                Button("Try again", action: retry).font(.footnote)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("full-text-banner")
    }
}

/// Video items (YouTube channels in FreshRSS) have no text to read.
private struct VideoCard: View {
    let title: String
    let source: String
    let watch: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "play.rectangle.fill").font(.system(size: 44)).foregroundStyle(.tint)
            Text("A video from \(source)").font(.headline)
            Text(title).font(.system(.title3, design: .serif, weight: .semibold)).multilineTextAlignment(.center)
            Button("Watch", systemImage: "play.fill", action: watch)
                .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(maxWidth: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding()
    }
}
