import SwiftUI
import FolioCore
import FolioAudio
import FolioReader

/// Listen is a radio page: what's playing, a Daily Mix, a station for each
/// topic, language and busy source, a station you build yourself, and Up
/// Next. Tapping a station plays it straight away.
struct ListenView: View {
    @Environment(ListenModel.self) private var listen
    @Environment(AppModel.self) private var model
    @Environment(\.folioTheme) private var theme
    @State private var showPremium = false
    @State private var showBuilder = false
    @State private var showQueue = false
    @State private var lineup = RadioLineup()
    @State private var images: [ArticleID: URL] = [:]
    /// A station waiting for "replace what's playing?".
    @State private var pendingStation: RadioStation?
    @State private var startingStationID: String?

    var body: some View {
        ScrollView {
            // Not lazy: the page is short, and UI tests can reach every control.
            VStack(alignment: .leading, spacing: 20) {
                ScreenHeader { ScreenTitle(text: "Listen") } trailing: { optionsMenu }
                if let item = listen.nowPlaying {
                    NowPlayingCard(item: item, showPremium: $showPremium)
                }
                if let mix = lineup.dailyMix {
                    DailyMixCard(station: mix, imageURL: mix.items.lazy.compactMap { images[$0.id] }.first,
                                 isStarting: startingStationID == mix.id) { start(mix) }
                } else if listen.nowPlaying == nil {
                    ContentUnavailableView {
                        Label("Nothing to play yet", systemImage: "headphones")
                    } description: {
                        Text("Stations appear here when you have unread stories. You can also open any article and tap the headphones. Everything plays offline with on-device voices.")
                    }
                }
                // Two small tiles side by side: the news in minutes, and your own station.
                HStack(spacing: 10) {
                    if let headlines = lineup.headlines {
                        HeadlinesCard(station: headlines, isStarting: startingStationID == headlines.id) { start(headlines) }
                    }
                    BuildYourOwnCard { showBuilder = true }
                }
                .fixedSize(horizontal: false, vertical: true)
                if !lineup.topics.isEmpty {
                    StationShelf(title: "Topic stations", subtitle: "One for each of your FreshRSS categories") {
                        ForEach(lineup.topics) { station in
                            StationTile(station: station, isStarting: startingStationID == station.id) { start(station) }
                        }
                    }
                }
                if !lineup.languages.isEmpty {
                    StationShelf(title: "By language", subtitle: "Each story in a voice for its language") {
                        ForEach(lineup.languages) { station in
                            LanguageTile(station: station, isStarting: startingStationID == station.id) { start(station) }
                        }
                    }
                }
                if !lineup.sources.isEmpty {
                    StationShelf(title: "From your sources") {
                        ForEach(lineup.sources) { station in
                            SourceBubble(station: station, isStarting: startingStationID == station.id) { start(station) }
                        }
                    }
                }
                UpNextSection(showQueue: $showQueue)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
            .foregroundStyle(Color(theme.text))
        }
        .folioScreen(theme)
        .navigationTitle("Listen")
        .toolbar(.hidden, for: .navigationBar)
        .statusBarFade(theme)
        .navigationDestination(for: ArticleID.self) { ReaderView(articleID: $0) }
        .sheet(isPresented: $showPremium) { PremiumView() }
        .sheet(isPresented: $showBuilder) { BulletinBuilderView() }
        .sheet(isPresented: $showQueue) { QueueView() }
        .confirmationDialog("Replace what's playing?", isPresented: Binding(
            get: { pendingStation != nil }, set: { if !$0 { pendingStation = nil } }),
            titleVisibility: .visible, presenting: pendingStation
        ) { station in
            Button("Play \(StationText.name(station))") { Task { await play(station) } }
        } message: { _ in
            Text("Up Next is replaced by this station.")
        }
        .task(id: [AnyHashable(model.revision), AnyHashable(listen.preferences.radioFilters), AnyHashable(listen.preferences.rate)]) {
            let result = await listen.lineup()
            lineup = result.lineup
            images = result.images
        }
        .task { await listen.loadVoices() }
    }

    private var optionsMenu: some View {
        Menu {
            Toggle("Play the next article automatically", isOn: Binding(
                get: { listen.preferences.continuousPlayback },
                set: { listen.preferences.continuousPlayback = $0 }))
            Button("Build your own station", systemImage: "slider.horizontal.3") { showBuilder = true }
            if !listen.upNext.isEmpty {
                Button("Edit Up Next", systemImage: "list.bullet") { showQueue = true }
            }
        } label: {
            HeaderButtonLabel(systemImage: "ellipsis")
        }
        .accessibilityLabel("Listen options")
    }

    private func start(_ station: RadioStation) {
        // One station at a time: quick repeated taps would each rebuild the queue.
        guard startingStationID == nil else { return }
        if listen.hasQueue { pendingStation = station } else { Task { await play(station) } }
    }

    private func play(_ station: RadioStation) async {
        startingStationID = station.id
        _ = await listen.play(station)
        startingStationID = nil
    }
}

/// Names and summary lines for stations.
enum StationText {
    static func name(_ station: RadioStation, now: Date = Date()) -> String {
        switch station.kind {
        case .dailyMix: mixName(now: now)
        case .language(let code): languageName(code)
        case .topic, .source, .headlines: station.title
        }
    }

    /// The language in its own words: Deutsch, Español, Slovenčina.
    static func languageName(_ code: String) -> String {
        let locale = Locale(identifier: code)
        return locale.localizedString(forLanguageCode: code)?.capitalized(with: locale) ?? code.uppercased()
    }

    static func mixName(now: Date) -> String {
        switch Calendar.current.component(.hour, from: now) {
        case 5..<12: "Morning Mix"
        case 12..<17: "Afternoon Mix"
        case 17..<22: "Evening Mix"
        default: "Late Mix"
        }
    }

    static func length(_ station: RadioStation) -> String {
        let minutes = max(1, Int((Double(station.estimatedSeconds) / 60).rounded()))
        return "\(station.storyCount) \(station.storyCount == 1 ? "story" : "stories") · \(minutes) min"
    }

    static func sources(_ station: RadioStation) -> String {
        let names = station.sources
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return "\(names[0]), \(names[1]) and \(names.count - 2) more"
        }
    }
}

/// Cards shrink a little under the finger.
private struct PressableStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(configuration.isPressed && reduceMotion ? 0.8 : 1)
            .animation(.snappy(duration: 0.2), value: configuration.isPressed)
    }
}

/// White play disc used on artwork.
private struct PlayDisc: View {
    var isStarting = false
    var size: CGFloat = 52
    @Environment(\.folioTheme) private var theme

    var body: some View {
        ZStack {
            Circle().fill(.white)
            if isStarting {
                ProgressView().tint(glyph)
            } else {
                Image(systemName: "play.fill")
                    .font(.system(size: size * 0.38, weight: .bold))
                    .foregroundStyle(glyph)
                    .offset(x: size * 0.04)
            }
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
    }

    /// Light accents (dark themes) are too pale on white; use the page instead.
    private var glyph: Color { theme.isDark ? Color(theme.background) : Color(theme.accent) }
}

private struct DailyMixCard: View {
    let station: RadioStation
    let imageURL: URL?
    let isStarting: Bool
    let play: () -> Void

    var body: some View {
        Button(action: play) {
            Color.clear
                .frame(height: 172)
                .frame(maxWidth: .infinity)
                .overlay {
                    if let imageURL {
                        ArticleThumbnail(url: imageURL, fallbackText: station.id, fallbackSymbol: "sparkles")
                    } else {
                        ThemeArtwork(key: station.id, symbol: "sparkles")
                    }
                }
                .overlay {
                    LinearGradient(stops: [.init(color: .black.opacity(0), location: 0.3), .init(color: .black.opacity(0.75), location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                }
                .overlay(alignment: .topLeading) {
                    Text("DAILY MIX")
                        .font(.caption2.weight(.bold)).tracking(1.3)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.black.opacity(0.35), in: Capsule())
                        .padding(12)
                }
                .overlay(alignment: .bottomLeading) {
                    HStack(alignment: .bottom, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(StationText.name(station))
                                .font(.system(.title, design: .serif, weight: .bold))
                                .lineLimit(1).minimumScaleFactor(0.7)
                            Text("\(StationText.length(station)) · \(StationText.sources(station))")
                                .font(.caption.weight(.semibold)).opacity(0.9).lineLimit(1)
                        }
                        .foregroundStyle(.white)
                        Spacer(minLength: 0)
                        PlayDisc(isStarting: isStarting, size: 48)
                    }
                    .padding(16)
                }
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .shadow(color: .black.opacity(0.14), radius: 12, y: 5)
        }
        .buttonStyle(PressableStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Daily Mix, \(StationText.name(station)). \(StationText.length(station)). \(StationText.sources(station))")
        .accessibilityHint("Plays now")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("daily-mix")
    }
}

/// The news in a few minutes: each story as two sentences.
private struct HeadlinesCard: View {
    let station: RadioStation
    let isStarting: Bool
    let play: () -> Void
    @Environment(\.folioTheme) private var theme

    var body: some View {
        Button(action: play) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "newspaper.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Color(theme.accent), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Spacer(minLength: 0)
                    if isStarting {
                        ProgressView()
                    } else {
                        Image(systemName: "play.circle.fill").font(.system(size: 26)).foregroundStyle(Color(theme.accent))
                    }
                }
                Spacer(minLength: 0)
                Text("Headlines").font(.system(.headline, design: .serif, weight: .bold))
                Text(StationText.length(station)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(theme.surface), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Headlines. \(StationText.length(station)), two sentences per story")
        .accessibilityHint("Plays now")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("headlines")
    }
}

private struct StationShelf<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(.title3, design: .serif, weight: .bold)).accessibilityAddTraits(.isHeader)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 10) { content }
                    .padding(.horizontal, 20)
            }
            .padding(.horizontal, -20)  // run to the screen edges
            .scrollClipDisabled()
        }
    }
}

private struct StationTile: View {
    let station: RadioStation
    let isStarting: Bool
    let play: () -> Void

    var body: some View {
        Button(action: play) {
            VStack(alignment: .leading, spacing: 5) {
                Color.clear
                    .frame(width: 128, height: 128)
                    .overlay { ThemeArtwork(key: station.id, symbol: "dot.radiowaves.left.and.right") }
                    .overlay(alignment: .bottomLeading) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("RADIO").font(.caption2.weight(.bold)).tracking(1.1).opacity(0.8)
                            Text(station.title)
                                .font(.system(.headline, design: .serif, weight: .bold))
                                .lineLimit(2).minimumScaleFactor(0.75)
                                .multilineTextAlignment(.leading)
                        }
                        .foregroundStyle(.white)
                        .padding(10)
                    }
                    .overlay(alignment: .topTrailing) {
                        if isStarting { ProgressView().tint(.white).padding(10) }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                Text(StationText.length(station))
                    .font(.caption2).foregroundStyle(.secondary)
                    .frame(width: 128, alignment: .leading)
            }
        }
        .buttonStyle(PressableStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(station.title) station. \(StationText.length(station))")
        .accessibilityHint("Plays now")
        .accessibilityAddTraits(.isButton)
    }
}

private struct LanguageTile: View {
    let station: RadioStation
    let isStarting: Bool
    let play: () -> Void

    var body: some View {
        Button(action: play) {
            Color.clear
                .frame(width: 156, height: 76)
                .overlay { ThemeArtwork(key: station.id, symbol: "character.bubble") }
                .overlay(alignment: .leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(StationText.languageName(station.title))
                            .font(.system(.title3, design: .serif, weight: .bold))
                            .lineLimit(1).minimumScaleFactor(0.7)
                        Text(StationText.length(station)).font(.caption2.weight(.semibold)).opacity(0.9)
                    }
                    .foregroundStyle(.white)
                    .padding(12)
                }
                .overlay(alignment: .topTrailing) {
                    if isStarting { ProgressView().tint(.white).padding(10) }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(StationText.languageName(station.title)) station. \(StationText.length(station))")
        .accessibilityHint("Plays now")
        .accessibilityAddTraits(.isButton)
    }
}

private struct SourceBubble: View {
    let station: RadioStation
    let isStarting: Bool
    let play: () -> Void

    var body: some View {
        Button(action: play) {
            VStack(spacing: 5) {
                ThemeArtwork(key: station.title, initial: station.title)
                    .frame(width: 64, height: 64)
                    .clipShape(Circle())
                    .overlay { if isStarting { ProgressView().tint(.white) } }
                    .shadow(color: .black.opacity(0.1), radius: 5, y: 2)
                Text(station.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2).multilineTextAlignment(.center)
                Text(StationText.length(station)).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(width: 90)
        }
        .buttonStyle(PressableStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(station.title) station. \(StationText.length(station))")
        .accessibilityHint("Plays now")
        .accessibilityAddTraits(.isButton)
    }
}

private struct BuildYourOwnCard: View {
    let open: () -> Void
    @Environment(\.folioTheme) private var theme

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "slider.horizontal.3")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color(theme.accent))
                        .frame(width: 30, height: 30)
                        .background(Color(theme.accent).opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                Text("Your station").font(.system(.headline, design: .serif, weight: .bold))
                Text("Length, topics, sources").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(theme.surface), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .accessibilityIdentifier("build-bulletin")
    }
}

private struct UpNextSection: View {
    @Binding var showQueue: Bool
    @Environment(ListenModel.self) private var listen
    @Environment(\.folioTheme) private var theme

    private let visibleCount = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Up Next")
                    .font(.system(.title3, design: .serif, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("up-next-header")
                if !listen.upNext.isEmpty {
                    Text("\(listen.upNext.count)").font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    Button("Edit") { showQueue = true }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color(theme.accent))
                }
            }
            if listen.upNext.isEmpty {
                Text("Start a station, or swipe an article left in any list and choose Listen later.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(listen.upNext.prefix(visibleCount).enumerated()), id: \.element.id) { index, item in
                        if index > 0 { ThemeDivider().padding(.leading, 52) }
                        UpNextRow(item: item)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .background(Color(theme.surface), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                if listen.upNext.count > visibleCount {
                    Button("Show all \(listen.upNext.count)") { showQueue = true }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color(theme.accent))
                }
            }
        }
    }
}

private struct UpNextRow: View {
    let item: ListenItem
    @Environment(ListenModel.self) private var listen

    var body: some View {
        Button {
            Task { await listen.play(item) }
        } label: {
            HStack(spacing: 12) {
                ThemeArtwork(key: item.feedTitle, initial: item.feedTitle)
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(.subheadline, design: .serif, weight: .semibold))
                        .lineLimit(2).multilineTextAlignment(.leading)
                    Text(item.feedTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Play now", systemImage: "play") { Task { await listen.play(item) } }
            Button("Remove from Up Next", systemImage: "minus.circle", role: .destructive) { listen.removeFromQueue(item.id) }
        }
        .accessibilityHint("Plays now")
    }
}

/// Reorder and remove queued stories.
private struct QueueView: View {
    @Environment(ListenModel.self) private var listen
    @Environment(\.folioTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(listen.upNext) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.system(.body, design: .serif)).lineLimit(2)
                            Text(item.feedTitle).font(.caption).foregroundStyle(.secondary)
                        }
                        .folioRow(theme)
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { listen.upNext[$0].id }
                        for id in ids { listen.removeFromQueue(id) }
                    }
                    .onMove { listen.moveInQueue(from: $0, to: $1) }
                }
                Section {
                    Toggle("Play the next article automatically", isOn: Binding(
                        get: { listen.preferences.continuousPlayback },
                        set: { listen.preferences.continuousPlayback = $0 }))
                        .folioRow(theme)
                }
            }
            .folioScreen(theme)
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Up Next")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .overlay {
                if listen.upNext.isEmpty { ContentUnavailableView("Up Next is empty", systemImage: "list.bullet") }
            }
        }
    }
}

/// The player card: the headline, a line through the article, the
/// transport and a row of small controls. Only its small parts (line, play
/// button, sleep chip, story count, error) read the per-word state; the
/// rest stays put while words go by, which keeps scrolling and tapping
/// smooth during narration.
private struct NowPlayingCard: View {
    let item: ListenItem
    @Binding var showPremium: Bool
    @Environment(\.folioTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ThemeArtwork(key: item.feedTitle, initial: item.feedTitle)
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    NowPlayingKicker(feed: item.feedTitle)
                    Text(item.title)
                        .font(.system(.title3, design: .serif, weight: .bold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("now-playing-title")
                }
                Spacer(minLength: 0)
                CloseNarrationButton()
            }
            ArticleLine()
            TransportControls(showPremium: $showPremium)
            HStack(spacing: 8) {
                VoiceChip()
                SleepMenu()
                Spacer(minLength: 0)
                NavigationLink(value: item.id) {
                    ChipLabel(title: "Read along", systemImage: "text.viewfinder")
                }
                .buttonStyle(.plain)
                .layoutPriority(1)
            }
            PlaybackErrorLabel()
        }
        .padding(16)
        .background(Color(theme.surface), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

/// "NACHTSCHICHT · 2 OF 6": the source, and the story's place in a station.
private struct NowPlayingKicker: View {
    let feed: String
    @Environment(ListenModel.self) private var listen
    @Environment(\.folioTheme) private var theme

    var body: some View {
        let position = listen.bulletinPosition
        Text((position.map { "\(feed) · \($0.index) of \($0.count)" } ?? feed).uppercased())
            .font(.caption2.weight(.bold)).tracking(1.1)
            .foregroundStyle(Color(theme.accent))
            .lineLimit(1)
            .accessibilityLabel(position.map { "\(feed), story \($0.index) of \($0.count)" } ?? feed)
    }
}

/// A line through the article with a mark where each paragraph starts,
/// taller at headings: the article's shape, and how far in you are. Drag
/// along it to jump to a paragraph.
private struct ArticleLine: View {
    @Environment(ListenModel.self) private var listen
    @Environment(\.folioTheme) private var theme
    /// The paragraph under the finger.
    @State private var target: SpeechMark?
    /// The paragraph just jumped to, shown until narration gets there.
    @State private var landing: SpeechMark?

    /// Past this many, marks would run together: the line goes plain.
    private let maximumMarks = 90

    var body: some View {
        let marks = listen.marks
        let position = shownPosition
        let knob: CGFloat = target == nil ? 9 : 15
        VStack(spacing: 5) {
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .leading) {
                    Canvas { context, size in draw(marks, at: position, in: &context, size: size) }
                    Circle()
                        .fill(Color(theme.accent))
                        .frame(width: knob, height: knob)
                        .offset(x: width * position - knob / 2)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard width > 0 else { return }
                        target = marks.mark(at: value.location.x / width)
                    }
                    .onEnded { _ in
                        if let target {
                            landing = target
                            listen.seek(to: target)
                        }
                        target = nil
                    })
            }
            .frame(height: 18)
            .animation(.snappy(duration: 0.2), value: target == nil)
            .sensoryFeedback(.selection, trigger: target?.segment) { old, new in old != nil && new != nil }
            HStack {
                Text(stage)
                Spacer()
                Text(timeLeft)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .onChange(of: listen.state.segmentIndex) { _, index in
            if index == landing?.segment { landing = nil }
        }
        .task(id: landing?.segment) {
            // A jump that never arrives (narration stopped) mustn't pin the line.
            guard landing != nil else { return }
            try? await Task.sleep(for: .seconds(2))
            landing = nil
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Position in the article")
        .accessibilityValue([stage, timeLeft].filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: listen.skip(by: 1)
            case .decrement: listen.skip(by: -1)
            @unknown default: break
            }
        }
    }

    private var shownPosition: Double {
        if let target { return target.fraction }
        if let landing, landing.segment != listen.state.segmentIndex { return landing.fraction }
        return min(max(listen.state.progress, 0), 1)
    }

    private var stage: String {
        if let target { return paragraphLabel(target.segment) }
        if listen.state.status == .loading { return "Preparing…" }
        if listen.isAnnouncing { return "Introduction" }
        return paragraphLabel(listen.state.segmentIndex)
    }

    private func paragraphLabel(_ segment: Int) -> String {
        if let paragraph = listen.marks.paragraph(containing: segment) {
            return "Paragraph \(paragraph.index) of \(paragraph.count)"
        }
        return listen.marks.first?.isTitle == true ? "Headline" : ""
    }

    /// An estimate (characters at the current speed), and said so.
    private var timeLeft: String {
        guard listen.state.status != .loading, let seconds = listen.remainingTime(fromSegment: target?.segment) else { return "" }
        let minutes = Int((seconds / 60).rounded())
        return minutes < 1 ? "Under a minute left" : "About \(minutes) min left"
    }

    private func draw(_ marks: [SpeechMark], at position: Double, in context: inout GraphicsContext, size: CGSize) {
        let accent = Color(theme.accent)
        let rule = Color(theme.text).opacity(0.16)
        let middle = size.height / 2
        if marks.count > 1, marks.count <= maximumMarks {
            for mark in marks where mark.fraction > 0.004 {  // none at the very start
                let height: CGFloat = mark.isHeading ? 14 : 8
                let x = (size.width * mark.fraction).rounded() - 0.5
                context.fill(Path(CGRect(x: x, y: middle - height / 2, width: 1, height: height)),
                             with: .color(mark.fraction <= position ? accent.opacity(0.6) : Color(theme.text).opacity(0.26)))
            }
        }
        context.fill(Path(roundedRect: CGRect(x: 0, y: middle - 1, width: size.width, height: 2), cornerRadius: 1), with: .color(rule))
        context.fill(Path(roundedRect: CGRect(x: 0, y: middle - 1.5, width: size.width * position, height: 3), cornerRadius: 1.5),
                     with: .color(accent))
    }
}

/// Speed, a paragraph back, play, a paragraph on, the next story. Play
/// stays in the middle whatever is queued.
private struct TransportControls: View {
    @Binding var showPremium: Bool
    @Environment(ListenModel.self) private var listen
    @Environment(\.folioTheme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            RateMenu(showPremium: $showPremium).frame(maxWidth: .infinity)
            SkipButton(direction: -1).frame(maxWidth: .infinity)
            PlayPauseButton().frame(maxWidth: .infinity)
            SkipButton(direction: 1).frame(maxWidth: .infinity)
            Button { Task { await listen.nextStory() } } label: {
                Image(systemName: "forward.fill")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .disabled(listen.upNext.isEmpty)
            .opacity(listen.upNext.isEmpty ? 0.3 : 1)
            .accessibilityLabel("Next story")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color(theme.accent))
    }
}

private struct PlayPauseButton: View {
    @Environment(ListenModel.self) private var listen
    @Environment(\.folioTheme) private var theme

    var body: some View {
        let playing = listen.state.status == .playing
        Button { listen.togglePlayPause() } label: {
            Image(systemName: playing ? "pause.fill" : "play.fill")
                .font(.system(size: 21, weight: .bold))
                .contentTransition(.symbolEffect(.replace))
                .offset(x: playing ? 0 : 2)
                // Light accents (dark themes) need a dark glyph.
                .foregroundStyle(theme.isDark ? Color(theme.background) : Color.white)
                .frame(width: 54, height: 54)
                .background(Circle().fill(Color(theme.accent)))
                .shadow(color: Color(theme.accent).opacity(0.3), radius: 8, y: 3)
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(playing ? "Pause" : "Play")
        .accessibilityIdentifier("listen-play-pause")
    }
}

/// Tap: a paragraph back or forward. Hold: the previous or next section
/// (heading), with a tick you can feel.
private struct SkipButton: View {
    let direction: Int
    @Environment(ListenModel.self) private var listen
    @State private var sections = 0
    @State private var misses = 0

    var body: some View {
        Image(systemName: direction < 0 ? "backward.end.fill" : "forward.end.fill")
            .font(.title3)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .onTapGesture { listen.skip(by: direction) }
            .onLongPressGesture(minimumDuration: 0.45) {
                if listen.skipSection(by: direction) { sections += 1 } else { misses += 1 }
            }
            .sensoryFeedback(.selection, trigger: sections)
            .sensoryFeedback(.warning, trigger: misses)
            .accessibilityElement()
            .accessibilityLabel(direction < 0 ? "Previous paragraph" : "Next paragraph")
            .accessibilityHint("Hold to jump to the \(direction < 0 ? "previous" : "next") section")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { listen.skip(by: direction) }
            .accessibilityAction(named: direction < 0 ? "Previous section" : "Next section") { _ = listen.skipSection(by: direction) }
    }
}

/// Stops narration and clears the player, so reading can start anywhere.
private struct CloseNarrationButton: View {
    @Environment(ListenModel.self) private var listen

    var body: some View {
        Button {
            withAnimation(.snappy) { listen.stop() }
        } label: {
            Image(systemName: "xmark")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(.quaternary, in: Circle())
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, -4)
        .padding(.trailing, -4)
        .accessibilityLabel("Stop and close")
        .accessibilityIdentifier("close-narration")
    }
}

/// The small rounded controls under the player; icon only without a title.
private struct ChipLabel: View {
    var title: String?
    let systemImage: String
    @Environment(\.folioTheme) private var theme

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
            if let title { Text(title).lineLimit(1) }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(Color(theme.accent))
        .padding(.horizontal, title == nil ? 0 : 11)
        .frame(minWidth: 30, minHeight: 30)
        .background(Color(theme.accent).opacity(0.12), in: Capsule())
        .contentShape(Capsule())
    }
}

private struct RateMenu: View {
    @Binding var showPremium: Bool
    @Environment(ListenModel.self) private var listen
    @Environment(EntitlementStore.self) private var entitlements
    @Environment(\.folioTheme) private var theme

    var body: some View {
        let current = SpeechRate(listen.preferences.rate)
        Menu {
            ForEach(SpeechRate.presets, id: \.self) { rate in
                Button {
                    if rate > SpeechRate.freeMaximum && !entitlements.isPremium { showPremium = true } else { listen.setRate(rate.multiplier) }
                } label: {
                    if rate == current { Label(rate.label, systemImage: "checkmark") } else { Text(rate.label) }
                }
            }
        } label: {
            Text(current.label)
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(Color(theme.accent))
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(Color(theme.accent).opacity(0.12), in: Capsule())
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Speed \(current.label)")
    }
}

/// The voice reading this article; picking another makes it the default for
/// the language and continues from the current word.
private struct VoiceChip: View {
    @Environment(ListenModel.self) private var listen

    var body: some View {
        let active = listen.activeVoice
        let language = active?.languageCode.base ?? "en"
        Menu {
            ForEach(listen.voiceChoices) { voice in
                Button {
                    listen.setDefaultVoice(voice, for: language)
                } label: {
                    if voice.id == active?.id {
                        Label("\(voice.name) · \(VoiceText.quality(voice.quality))", systemImage: "checkmark")
                    } else {
                        Text("\(voice.name) · \(VoiceText.quality(voice.quality))")
                    }
                }
            }
        } label: {
            ChipLabel(title: active?.name ?? "Voice", systemImage: active?.quality == .neural ? "waveform" : "person.wave.2")
        }
        .accessibilityLabel("Voice: \(active?.name ?? "automatic")")
    }
}

/// A moon while off; the time it stops while on.
private struct SleepMenu: View {
    @Environment(ListenModel.self) private var listen

    var body: some View {
        Menu {
            Button("Off") { listen.setSleepTimer(nil) }
            ForEach([5, 15, 30, 45, 60], id: \.self) { minutes in
                Button("\(minutes) minutes") { listen.setSleepTimer(.minutes(minutes)) }
            }
            Button("End of article") { listen.setSleepTimer(.endOfArticle) }
        } label: {
            if let ends = listen.state.sleepTimerEndsAt {
                ChipLabel(title: ends.formatted(date: .omitted, time: .shortened), systemImage: "moon.zzz.fill")
            } else if listen.state.sleepTimer == .endOfArticle {
                ChipLabel(title: "End of article", systemImage: "moon.zzz.fill")
            } else {
                ChipLabel(systemImage: "moon.zzz")
            }
        }
        .fixedSize()
        .accessibilityLabel(sleepDescription)
    }

    private var sleepDescription: String {
        if let ends = listen.state.sleepTimerEndsAt { return "Sleep timer, stops at \(ends.formatted(date: .omitted, time: .shortened))" }
        if listen.state.sleepTimer == .endOfArticle { return "Sleep timer, stops at the end of the article" }
        return "Sleep timer, off"
    }
}

private struct PlaybackErrorLabel: View {
    @Environment(ListenModel.self) private var listen

    var body: some View {
        if let error = listen.state.lastError {
            Text(error).font(.footnote).foregroundStyle(.orange)
        }
    }
}

/// Choose what goes into a bulletin. The preview updates as filters change.
struct BulletinBuilderView: View {
    @Environment(ListenModel.self) private var listen
    @Environment(AppModel.self) private var model
    @Environment(\.folioTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var preview: Bulletin?
    @State private var confirmReplace = false

    private let languages: [(code: String, name: String)] = [("en", "English"), ("de", "German"), ("es", "Spanish"), ("sk", "Slovak")]

    var body: some View {
        @Bindable var listen = listen
        NavigationStack {
            Form {
                Section("Length") {
                    Stepper("About \(listen.preferences.radioFilters.minutes) minutes",
                            value: $listen.preferences.radioFilters.minutes, in: 5...90, step: 5)
                    Stepper("Up to \(listen.preferences.radioFilters.storyLimit) stories",
                            value: $listen.preferences.radioFilters.storyLimit, in: 1...30)
                    Picker("Order", selection: $listen.preferences.radioFilters.order) {
                        Text("Newest first").tag(RadioFilters.Order.newest)
                        Text("Oldest first").tag(RadioFilters.Order.oldest)
                    }
                }
                .folioRow(theme)
                Section {
                    ForEach(languages, id: \.code) { language in
                        Toggle(language.name, isOn: setBinding(\.languages, language.code))
                    }
                } header: {
                    Text("Languages")
                } footer: {
                    Text("Nothing selected means every language.")
                }
                .folioRow(theme)
                if !model.categories.isEmpty {
                    Section("Categories") {
                        ForEach(model.categories) { category in
                            Toggle(category.label, isOn: setBinding(\.categoryIDs, category.id))
                        }
                    }
                    .folioRow(theme)
                }
                if !model.feeds.isEmpty {
                    Section("Sources") {
                        ForEach(model.feeds) { feed in
                            Toggle(feed.title, isOn: setBinding(\.feedIDs, feed.id))
                        }
                    }
                    .folioRow(theme)
                }
                Section {
                    Toggle("Mark stories read when finished", isOn: $listen.preferences.radioFilters.markReadWhenFinished)
                } footer: {
                    Text("Length, story limit, order and this setting also shape the ready-made stations.")
                }
                .folioRow(theme)
                Section {
                    if let preview {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(preview.stories.count) \(preview.stories.count == 1 ? "story" : "stories") · about \(max(1, preview.estimatedSeconds / 60)) min")
                                .font(.headline)
                            ForEach(preview.stories, id: \.item.id) { story in
                                Text("\(story.item.feedTitle) · \(story.item.title)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    } else {
                        Text("No unread stories match these filters.").foregroundStyle(.secondary)
                    }
                    Button("Create bulletin") {
                        if listen.hasQueue { confirmReplace = true } else { Task { await create() } }
                    }
                    .disabled(preview == nil)
                    .accessibilityIdentifier("confirm-build-bulletin")
                } footer: {
                    Text("Times are estimates at your current speed.")
                }
                .folioRow(theme)
            }
            .folioScreen(theme)
            .navigationTitle("News Radio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .confirmationDialog("Replace what's in the queue with this bulletin?", isPresented: $confirmReplace, titleVisibility: .visible) {
                Button("Replace queue", role: .destructive) { Task { await create() } }
            }
            .task(id: listen.preferences.radioFilters) { preview = await listen.previewBulletin() }
        }
    }

    private func create() async {
        if await listen.buildBulletin() { dismiss() } else { preview = nil }
    }

    private func setBinding<T: Hashable>(_ path: WritableKeyPath<RadioFilters, Set<T>>, _ value: T) -> Binding<Bool> {
        Binding(
            get: { listen.preferences.radioFilters[keyPath: path].contains(value) },
            set: { on in
                if on { listen.preferences.radioFilters[keyPath: path].insert(value) } else {
                    listen.preferences.radioFilters[keyPath: path].remove(value)
                }
            })
    }
}

/// Compact player above the tab bar while something is loaded. Tap opens
/// Listen. Hold it and the play button turns into a red close button: tap
/// that to stop and clear narration, so the next read can start anywhere;
/// tap anywhere else (or wait a few seconds) to keep listening.
struct MiniPlayer: View {
    var open: () -> Void
    @Environment(ListenModel.self) private var listen
    @Environment(\.folioTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var closing = false
    @State private var revert: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 12) {
            if let item = listen.nowPlaying {
                ThemeArtwork(key: item.feedTitle, initial: item.feedTitle)
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .opacity(closing ? 0.5 : 1)
            }
            Group {
                if closing {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Stop and close?").font(.subheadline.weight(.semibold))
                        Text("Tap anywhere else to keep listening").font(.caption2).foregroundStyle(.secondary)
                    }
                    .transition(.opacity)
                } else {
                    MiniPlayerProgress().transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            MiniPlayerButton(closing: closing, close: close)
        }
        .foregroundStyle(Color(theme.text))
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.red.opacity(closing ? 0.10 : 0)))
        }
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(closing ? Color.red.opacity(0.45) : Color(theme.separator), lineWidth: closing ? 1 : 0.5))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .scaleEffect(closing && !reduceMotion ? 0.98 : 1)
        .contentShape(Rectangle())
        .onTapGesture {
            if closing { setClosing(false) } else { open() }
        }
        .onLongPressGesture(minimumDuration: 0.4) { setClosing(true) }
        .sensoryFeedback(.impact(weight: .medium), trigger: closing) { _, isClosing in isClosing }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mini-player")
        .accessibilityAction(named: "Open player", open)
        .accessibilityAction(named: "Stop and close", close)
        .onDisappear { revert?.cancel() }
    }

    private func setClosing(_ value: Bool) {
        revert?.cancel()
        withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.35, bounce: 0.25)) { closing = value }
        guard value else { return }
        revert = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            setClosing(false)
        }
    }

    private func close() {
        revert?.cancel()
        closing = false
        withAnimation(.snappy) { listen.stop() }
    }
}

/// Title and progress: the only part of the mini player that changes per word.
private struct MiniPlayerProgress: View {
    @Environment(ListenModel.self) private var listen
    @Environment(\.folioTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(listen.nowPlaying?.title ?? "").font(.subheadline.weight(.semibold)).lineLimit(1)
            ProgressView(value: listen.state.progress).tint(Color(theme.accent))
        }
    }
}

private struct MiniPlayerButton: View {
    let closing: Bool
    let close: () -> Void
    @Environment(ListenModel.self) private var listen
    @Environment(\.folioTheme) private var theme

    var body: some View {
        let playing = listen.state.status == .playing
        Button {
            if closing { close() } else { listen.togglePlayPause() }
        } label: {
            Image(systemName: closing ? "xmark" : (playing ? "pause.fill" : "play.fill"))
                .font(.title3.weight(closing ? .bold : .regular))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(closing ? Color.white : Color(theme.text))
                .frame(width: 38, height: 38)
                .background(Circle().fill(closing ? Color.red : Color.clear))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(closing ? "Stop and close" : (playing ? "Pause" : "Play"))
        .accessibilityIdentifier("mini-player-button")
    }
}
