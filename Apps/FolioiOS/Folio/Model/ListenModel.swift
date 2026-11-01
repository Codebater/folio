import AVFoundation
import Foundation
import Observation
import StoreKit
import FolioCore
import FolioAudio
import FolioFreshRSS
import FolioNeural
import Network

/// What the page shows while narrating. Word plus sentence helps people
/// who lose their place (and readers with dyslexia); some prefer less.
enum NarrationHighlightStyle: String, Codable, CaseIterable, Identifiable {
    case wordAndSentence, word, sentence, paragraph
    var id: String { rawValue }
    var showsWord: Bool { self == .wordAndSentence || self == .word }
    var showsSentence: Bool { self == .wordAndSentence || self == .sentence }
    var label: String {
        switch self {
        case .wordAndSentence: "Word and sentence"
        case .word: "Word"
        case .sentence: "Sentence"
        case .paragraph: "Paragraph only"
        }
    }
}

struct ListenPreferences: Codable, Equatable {
    var rate: Double = 1
    var granularity: SpeechScriptOptions.Granularity = .paragraph
    var includeTitle = true
    /// Say the feed's name before the title ("The Margin. Why …").
    var announceSource = true
    var paragraphPause: Double = 0.35
    /// Voice identifier per base language, e.g. "de" → a German voice.
    var voiceByLanguage: [String: String] = [:]
    /// Forced narration language; nil uses the detected one.
    var languageOverride: String?
    var pronunciations: [PronunciationEntry] = []
    var continuousPlayback = true
    var radioFilters = RadioFilters()
    /// Voice ids, most recently used first.
    var favouriteVoiceIDs: [String] = []
    /// Pitch and speed per voice id (Premium).
    var voiceTuning: [String: VoiceTuning] = [:]
    /// Voice id per feed id (Premium).
    var feedVoices: [String: String] = [:]
    var cleanup = SpeechCleanup()
    var switchLanguagePerParagraph = true
    /// The user's own speech server (Kokoro-FastAPI or OpenAI-compatible), if any.
    var voiceServerURL: String?
    /// Its voices, remembered so they show offline.
    var serverVoiceIDs: [String] = []
    var highlightStyle: NarrationHighlightStyle = .wordAndSentence
    /// The user removed the natural voices: Ivy isn't downloaded again by itself.
    var naturalVoicesRemoved = false
    /// The languages narration speaks, main first; nil until the reader
    /// chooses (then the library's own languages are used).
    var readAloudLanguages: [String]?

    init() {}

    // Older saved preferences lack newer keys; fill them with defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ListenPreferences()
        rate = try c.decodeIfPresent(Double.self, forKey: .rate) ?? defaults.rate
        granularity = try c.decodeIfPresent(SpeechScriptOptions.Granularity.self, forKey: .granularity) ?? defaults.granularity
        includeTitle = try c.decodeIfPresent(Bool.self, forKey: .includeTitle) ?? defaults.includeTitle
        announceSource = try c.decodeIfPresent(Bool.self, forKey: .announceSource) ?? defaults.announceSource
        paragraphPause = try c.decodeIfPresent(Double.self, forKey: .paragraphPause) ?? defaults.paragraphPause
        voiceByLanguage = try c.decodeIfPresent([String: String].self, forKey: .voiceByLanguage) ?? [:]
        languageOverride = try c.decodeIfPresent(String.self, forKey: .languageOverride)
        pronunciations = try c.decodeIfPresent([PronunciationEntry].self, forKey: .pronunciations) ?? []
        continuousPlayback = try c.decodeIfPresent(Bool.self, forKey: .continuousPlayback) ?? defaults.continuousPlayback
        radioFilters = try c.decodeIfPresent(RadioFilters.self, forKey: .radioFilters) ?? defaults.radioFilters
        favouriteVoiceIDs = try c.decodeIfPresent([String].self, forKey: .favouriteVoiceIDs) ?? []
        voiceTuning = try c.decodeIfPresent([String: VoiceTuning].self, forKey: .voiceTuning) ?? [:]
        feedVoices = try c.decodeIfPresent([String: String].self, forKey: .feedVoices) ?? [:]
        cleanup = try c.decodeIfPresent(SpeechCleanup.self, forKey: .cleanup) ?? defaults.cleanup
        switchLanguagePerParagraph = try c.decodeIfPresent(Bool.self, forKey: .switchLanguagePerParagraph)
            ?? defaults.switchLanguagePerParagraph
        voiceServerURL = try c.decodeIfPresent(String.self, forKey: .voiceServerURL)
        serverVoiceIDs = try c.decodeIfPresent([String].self, forKey: .serverVoiceIDs) ?? []
        highlightStyle = try c.decodeIfPresent(NarrationHighlightStyle.self, forKey: .highlightStyle) ?? defaults.highlightStyle
        naturalVoicesRemoved = try c.decodeIfPresent(Bool.self, forKey: .naturalVoicesRemoved) ?? false
        readAloudLanguages = try c.decodeIfPresent([String].self, forKey: .readAloudLanguages)
    }
}

/// What survives a relaunch: the queue, where narration stopped, and the
/// bulletin it belongs to. It always comes back paused.
struct SavedListening: Codable {
    var current: ListenItem?
    var position: SpeechPosition?
    var upNext: [ListenItem]
    var bulletin: Bulletin?
}

/// What the reader should highlight right now.
struct NarrationHighlight: Equatable {
    var articleID: ArticleID
    var blockID: String
    var wordRange: Range<Int>?
    var sentenceRange: Range<Int>?
}

/// Narration for the whole app: one controller, one engine, one queue, plus
/// News Radio bulletins, background audio and lock-screen controls.
@MainActor
@Observable
final class ListenModel {
    /// Changes on every spoken word: only small views (progress, play
    /// button) should read it. Everything else reads the mirrors below.
    private(set) var state = ReadAlongState()
    /// What's loaded, updated only when it changes.
    private(set) var nowPlaying: ListenItem?
    private(set) var upNext: [ListenItem] = []
    /// The voice reading the current article, and the voices to switch to.
    private(set) var activeVoice: SpeechVoice?
    private(set) var voiceChoices: [SpeechVoice] = []
    private(set) var voices: [SpeechVoice] = []
    /// The bulletin whose stories are in the queue, if any.
    private(set) var bulletin: Bulletin?
    /// Where each block of the current article starts, for the player's
    /// line. Updated when the script changes, not per word.
    private(set) var marks: [SpeechMark] = []
    @ObservationIgnored private var marksKey: String?
    var preferences = ListenPreferences() {
        didSet {
            Preferences.save(preferences, key: .listenPreferences)
            engine.preferredVoiceIDs = preferences.voiceByLanguage
            engine.voiceTuning = app?.entitlements.isPremium == true ? preferences.voiceTuning : [:]
            controller?.continuousPlayback = preferences.continuousPlayback
        }
    }
    /// The voice whose sample is playing in the Voice Library.
    private(set) var previewingVoiceID: String?

    @ObservationIgnored let engine = AppleSpeechEngine()
    /// Neural voices (Voice Lab): rendered on this iPhone, played with word timing.
    @ObservationIgnored let neuralModels = NeuralModelStore(directory: ListenModel.folder("NeuralModels", in: .applicationSupportDirectory))
    @ObservationIgnored let neuralSynthesizer = FluidSpeechSynthesizer(
        modelsDirectory: ListenModel.folder("NeuralModels", in: .applicationSupportDirectory),
        cacheDirectory: ListenModel.folder("Narration", in: .cachesDirectory),
        kokoroCrashMarker: ListenModel.kokoroCrashMarker)
    nonisolated static let kokoroCrashMarker = folder("NeuralModels", in: .applicationSupportDirectory)
        .appendingPathComponent(".kokoro-busy")
    /// Kokoro took the app down on this iPhone last time and was switched off.
    private(set) var kokoroCrashed = false
    @ObservationIgnored private(set) var neural: TimedSpeechEngine!
    /// Neural voices on the device and voices from the user's server, by id prefix.
    @ObservationIgnored private(set) var synthesizers: RoutingSynthesizer!
    @ObservationIgnored private let serverKeys = KeychainCredentialStore(service: "com.codebater.folio.voiceserver")
    /// Voices offered by the user's server.
    private(set) var serverVoices: [SpeechVoice] = []
    private(set) var voiceServerStatus: VoiceServerStatus = .notSet
    /// Apple voices and neural voices behind one engine; each run of
    /// paragraphs goes to the engine of its voice.
    @ObservationIgnored private(set) var narration: HybridSpeechEngine!
    @ObservationIgnored private let neuralPreview = ClipOutput()
    @ObservationIgnored private var neuralPreviewTask: Task<Void, Never>?
    /// Downloaded neural models.
    private(set) var installedModels: Set<NeuralVoiceCatalog.Model> = []
    /// Models downloading now, or why a download failed.
    private(set) var modelDownloads: [NeuralVoiceCatalog.Model: ModelDownload] = [:]
    /// TestFlight and debug builds use neural voices without Premium, so they
    /// can be tested before the App Store products exist.
    private(set) var isTestBuild = false
    /// Why the last neural preview failed, shown in the Voice Library.
    private(set) var previewError: String?
    @ObservationIgnored private(set) var controller: ReadAlongController!
    @ObservationIgnored private let session = PlaybackSession()
    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var lastSavedAt = Date.distantPast
    @ObservationIgnored private let previewer = VoicePreviewer()
    @ObservationIgnored private var voicesObserver: NSObjectProtocol?
    /// Waits for Wi-Fi before Ivy's first download.
    @ObservationIgnored private var ivyNetwork: NWPathMonitor?

    func attach(to app: AppModel) {
        self.app = app
        // Loaded here rather than in init so `--ui-reset` has cleared them first.
        preferences = Preferences.load(.listenPreferences) ?? ListenPreferences()
        if FileManager.default.fileExists(atPath: Self.kokoroCrashMarker.path) {
            // The app ended while Kokoro was working: switch it off here, visibly.
            try? FileManager.default.removeItem(at: Self.kokoroCrashMarker)
            neuralModels.markNotInstalled(.kokoro)
            kokoroCrashed = true
            for (language, id) in preferences.voiceByLanguage where NeuralVoiceCatalog.voice(id)?.model == .kokoro {
                preferences.voiceByLanguage[language] = nil
            }
        }
        installedModels = neuralModels.installed
        prepareIvy()
        synthesizers = RoutingSynthesizer([NeuralVoiceCatalog.prefix: neuralSynthesizer])
        if let address = preferences.voiceServerURL, let base = VoiceServer.normalizedBase(address) {
            serverVoices = preferences.serverVoiceIDs.map(VoiceServer.voice(serverID:))
            voiceServerStatus = .connected(serverVoices.count)
            let remote = makeRemote(base: base, apiKey: try? serverKeys.password(for: base.absoluteString))
            let routing = synthesizers!
            Task { await routing.set(remote, for: VoiceServer.prefix) }
        }
        neural = TimedSpeechEngine(synthesizer: synthesizers, output: ClipOutput())
        neural.voices = NeuralVoiceCatalog.speechVoices(installed: installedModels)
        neural.voiceForSegment = { [weak self] in self?.neuralVoiceID(for: $0) }
        // Short sentences (sentence-by-sentence voices) need more rendered
        // ahead, so a long sentence can't make playback wait.
        neural.lookahead = 4
        narration = HybridSpeechEngine(primary: engine, secondary: neural) { [weak self] in self?.neuralVoiceID(for: $0) != nil }
        Task { [weak self] in
            let testBuild = await Self.detectTestBuild()
            self?.isTestBuild = testBuild
            self?.refreshActiveVoice()
        }
        controller = ReadAlongController(engine: narration) { [weak app] item in
            await app?.speechScript(for: item.id)
        }
        controller.continuousPlayback = preferences.continuousPlayback
        controller.onNextPrepared = { [weak self] script in self?.renderAhead(script) }
        controller.pauseBetweenStories = 2
        controller.setRate(SpeechRate(preferences.rate))
        engine.preferredVoiceIDs = preferences.voiceByLanguage
        controller.onChange = { [weak self] state in self?.stateChanged(state) }
        controller.onItemFinished = { [weak self] item in self?.itemFinished(item) }
        session.onInterruption = { [weak self] began in
            if began { self?.controller.pause() } else { self?.controller.resume() }
        }
        session.onOutputLost = { [weak self] in self?.controller.pause() }
        session.installCommands(PlaybackSession.Commands(
            play: { [weak self] in self?.resume() },
            pause: { [weak self] in self?.pause() },
            togglePlayPause: { [weak self] in self?.togglePlayPause() },
            nextParagraph: { [weak self] in self?.controller.skip(by: 1) },
            previousParagraph: { [weak self] in self?.controller.skip(by: -1) },
            changeRate: { [weak self] rate in self?.setRate(Double(rate)) }))

        previewer.onChange = { [weak self] id in self?.previewingVoiceID = id }
        // New voices downloaded in iOS Settings show up without a relaunch.
        voicesObserver = NotificationCenter.default.addObserver(
            forName: AVSpeechSynthesizer.availableVoicesDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await self.loadVoices()
            }
        }

        if let saved: SavedListening = Preferences.load(.listening), saved.current != nil || !saved.upNext.isEmpty {
            bulletin = saved.bulletin
            controller.restore(current: saved.current ?? saved.upNext.first, at: saved.position, upNext: saved.upNext)
        }
    }

    /// The languages narration speaks, main first: the reader's choice in
    /// Settings › Languages, or the library's well-established languages.
    var readAloudLanguages: [String] {
        if let chosen = preferences.readAloudLanguages, !chosen.isEmpty { return chosen }
        return app?.automaticReadAloudLanguages ?? ["en"]
    }

    /// Stations start in it, and anything in a language that's off is read in it.
    var mainLanguage: LanguageCode { LanguageCode(readAloudLanguages.first ?? "en") }

    /// `detected` is the sync-time guess; the script checks it against the
    /// article's own text. Only the user's override forces a language.
    func scriptOptions(detected: LanguageCode?) -> SpeechScriptOptions {
        var options = SpeechScriptOptions(
            granularity: preferences.granularity, includeTitle: preferences.includeTitle,
            paragraphPause: preferences.paragraphPause, language: preferences.languageOverride.map { LanguageCode($0) },
            pronunciation: PronunciationRules(userEntries: app?.entitlements.isPremium == true ? preferences.pronunciations : []),
            cleanup: preferences.cleanup,
            switchLanguagePerParagraph: preferences.languageOverride == nil && preferences.switchLanguagePerParagraph,
            announceSource: preferences.announceSource, detectedLanguage: detected,
            defaultLanguage: mainLanguage)
        options.readAloudLanguages = readAloudLanguages
        return options
    }

    var highlight: NarrationHighlight? {
        guard let item = state.item, let block = state.blockID, state.status == .playing || state.status == .paused else { return nil }
        let style = preferences.highlightStyle
        return NarrationHighlight(articleID: item.id, blockID: block, wordRange: style.showsWord ? state.wordRange : nil,
                                  sentenceRange: style.showsSentence ? state.sentenceRange : nil)
    }

    var isActive: Bool { state.item != nil && state.status != .idle }

    func isNarrating(_ id: ArticleID) -> Bool {
        state.item?.id == id && (state.status == .playing || state.status == .paused || state.status == .loading)
    }

    /// "Story 2 of 6" while a bulletin plays.
    var bulletinPosition: (index: Int, count: Int)? {
        guard let bulletin, let id = state.item?.id, let index = bulletin.stories.firstIndex(where: { $0.item.id == id }) else { return nil }
        return (index + 1, bulletin.stories.count)
    }

    var isAnnouncing: Bool { state.blockID?.hasPrefix(SpeechScript.announcementPrefix) == true }

    /// About how long is left of this article at the current speed, from
    /// `segment` (the one being read when nil).
    func remainingTime(fromSegment segment: Int? = nil) -> TimeInterval? {
        guard state.item != nil, let script = controller?.currentScript else { return nil }
        return script.estimatedDuration(rate: state.rate.multiplier, fromSegment: segment ?? state.segmentIndex)
    }

    /// Jumps to the start of a block, keeping play or pause as it was.
    func seek(to mark: SpeechMark) {
        guard let script = controller?.currentScript, mark.segment < script.segments.count else { return }
        start(at: script.position(segment: mark.segment, spokenOffset: 0))
    }

    // MARK: Transport

    func play(_ item: ListenItem, from position: SpeechPosition? = nil) async {
        activateSession()
        await controller.play(item, from: position)
    }

    func togglePlayPause() {
        if narration.state == .speaking { pause() } else { resume() }
    }

    func resume() {
        activateSession()
        controller.resume()
    }

    func pause() {
        controller.pause()
        save(force: true)
    }

    func stop() {
        controller?.stop()
        bulletin = nil
        session.clearNowPlaying()
        session.deactivate()
        Preferences.remove(.listening)
    }

    func start(at position: SpeechPosition) {
        activateSession()
        controller.start(at: position)
    }

    func skip(by delta: Int) { controller.skip(by: delta) }

    /// Next heading, or back to the start of this section. False when there's none.
    @discardableResult
    func skipSection(by direction: Int) -> Bool { controller.skipSection(by: direction) }

    /// Next story without marking the current one read.
    func nextStory() async { await controller.playNext() }

    func setRate(_ rate: Double) {
        let allowed = app?.entitlements.isPremium == true ? rate : min(rate, SpeechRate.freeMaximum.multiplier)
        preferences.rate = allowed
        controller.setRate(SpeechRate(allowed))
    }

    func setSleepTimer(_ setting: SleepTimerSetting?) { controller.setSleepTimer(setting) }

    func enqueue(_ item: ListenItem) { controller.enqueue(item) }
    func enqueueNext(_ item: ListenItem) { controller.enqueueNext(item) }
    func removeFromQueue(_ id: ArticleID) { controller.removeFromQueue(id) }
    func moveInQueue(from source: IndexSet, to destination: Int) { controller.moveInQueue(from: source, to: destination) }

    // MARK: News Radio

    /// Plans a bulletin from unread articles and puts it in the queue,
    /// paused, replacing what was queued. Returns false if nothing matched.
    func buildBulletin() async -> Bool { await queueBulletin(filters: preferences.radioFilters) }

    /// Plays a station straight away, replacing the queue.
    func play(_ station: RadioStation) async -> Bool {
        guard await queueBulletin(filters: station.filters, mode: station.kind == .headlines ? .headlines : .full) else { return false }
        resume()
        return true
    }

    /// The stations for the Listen page, with lead images for their artwork.
    func lineup() async -> (lineup: RadioLineup, images: [ArticleID: URL]) {
        guard let app else { return (RadioLineup(), [:]) }
        let pool = await app.radioPool()
        let lineup = RadioLineup.build(candidates: pool.candidates, categories: app.categories,
                                       base: preferences.radioFilters, rate: preferences.rate, excluding: app.duplicates,
                                       mainLanguage: mainLanguage)
        return (lineup, pool.images)
    }

    /// Siri, Shortcuts and automations ("when my AirPods connect, play my Daily Mix").
    func playDailyMix() async -> Bool {
        guard let mix = await lineup().lineup.dailyMix else { return false }
        return await play(mix)
    }

    func playHeadlines() async -> Bool {
        guard let headlines = await lineup().lineup.headlines else { return false }
        return await play(headlines)
    }

    private func queueBulletin(filters: RadioFilters, mode: Bulletin.Mode = .full) async -> Bool {
        guard let app else { return false }
        let candidates = await app.radioCandidates()
        guard let planned = BulletinPlanner.build(candidates: candidates, filters: filters, rate: preferences.rate,
                                                  bulletinLanguage: mainLanguage, excluding: app.duplicates, mode: mode)
        else { return false }
        bulletin = planned
        controller.restore(current: planned.items.first, at: nil, upNext: Array(planned.items.dropFirst()))
        save(force: true)
        return true
    }

    func previewBulletin() async -> Bulletin? {
        guard let app else { return nil }
        return BulletinPlanner.build(candidates: await app.radioCandidates(), filters: preferences.radioFilters, rate: preferences.rate,
                                     bulletinLanguage: mainLanguage)
    }

    var hasQueue: Bool { state.item != nil || !state.upNext.isEmpty }

    /// Apple's installed voices plus the neural voices whose model is
    /// downloaded (the Neural voices section offers the downloads).
    func loadVoices() async {
        voices = await engine.availableVoices() + NeuralVoiceCatalog.speechVoices(installed: installedModels).filter(\.isInstalled)
            + serverVoices
        refreshActiveVoice()
    }

    func voices(for language: String) -> [SpeechVoice] {
        voices.filter { $0.languageCode.base == language }
    }

    // MARK: Voice Library

    /// The reader's own languages: the ones read aloud, what the library is
    /// written in, then the device languages.
    var preferredLanguages: [String] {
        let device = Locale.preferredLanguages.map { LanguageCode($0).base }
        return (readAloudLanguages + (app?.libraryLanguages ?? []) + device).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    }

    /// The voice that reads a language, the same one narration picks: the
    /// chosen one, Ivy, or the engine's choice.
    func narratingVoice(for language: String) -> SpeechVoice? {
        if let id = chosenVoiceID(for: language), isUsable(id), let voice = voices.first(where: { $0.id == id }) { return voice }
        return engine.resolvedVoice(for: LanguageCode(language))
    }

    func voiceSections(filter: VoiceFilter) -> [VoiceSection] {
        VoiceLibrary.sections(voices: voices, filter: filter, preferredLanguages: preferredLanguages,
                              defaults: preferences.voiceByLanguage, favourites: preferences.favouriteVoiceIDs)
    }

    /// Chosen voices that are no longer installed (language → voice id).
    var missingDefaults: [String: String] {
        voices.isEmpty ? [:] : VoiceLibrary.missingDefaults(preferences.voiceByLanguage, installed: voices)
    }

    func defaultVoice(for language: String) -> SpeechVoice? {
        if let id = preferences.voiceByLanguage[language], let voice = voices.first(where: { $0.id == id }) { return voice }
        let region = Locale.current.region?.identifier
        return VoiceLibrary.automaticVoice(for: language, region: region, in: voices)
    }

    func setDefaultVoice(_ voice: SpeechVoice?, for language: String) {
        preferences.voiceByLanguage[language] = voice?.id
        if let voice { preferences.favouriteVoiceIDs = VoiceLibrary.touch(voice.id, in: preferences.favouriteVoiceIDs) }
        // Narration in progress continues from the current word in the new voice.
        if state.status == .playing || state.status == .paused { controller.selectVoice(nil) }
        refreshActiveVoice()
    }

    func isFavourite(_ voice: SpeechVoice) -> Bool { preferences.favouriteVoiceIDs.contains(voice.id) }

    func toggleFavourite(_ voice: SpeechVoice) {
        if isFavourite(voice) {
            preferences.favouriteVoiceIDs.removeAll { $0 == voice.id }
        } else {
            preferences.favouriteVoiceIDs = VoiceLibrary.touch(voice.id, in: preferences.favouriteVoiceIDs)
        }
    }

    func tuning(for voice: SpeechVoice) -> VoiceTuning { preferences.voiceTuning[voice.id] ?? .neutral }

    func setTuning(_ tuning: VoiceTuning, for voice: SpeechVoice) {
        preferences.voiceTuning[voice.id] = tuning == .neutral ? nil : tuning
    }

    /// Plays a sample (or `text`) in a voice. Narration pauses first, so the
    /// two never talk over each other.
    func preview(_ voice: SpeechVoice, text: String? = nil) {
        if NeuralVoiceCatalog.isNeural(voice.id) || VoiceServer.isServerVoice(voice.id) {
            previewNeural(voice, text: text ?? VoiceSamples.sentence(for: voice.language))
            return
        }
        if neuralPreviewTask != nil { stopPreview() }
        if previewingVoiceID == voice.id {
            previewer.stop()
            return
        }
        if narration.state == .speaking { pause() }
        try? session.activate()
        previewer.play(voiceID: voice.id, text: text ?? VoiceSamples.sentence(for: voice.language), tuning: tuning(for: voice),
                       rate: SpeechRate(preferences.rate))
    }

    func stopPreview() {
        previewer.stop()
        neuralPreviewTask?.cancel()
        neuralPreviewTask = nil
        neuralPreview.stop()
        if let id = previewingVoiceID, NeuralVoiceCatalog.isNeural(id) || VoiceServer.isServerVoice(id) { previewingVoiceID = nil }
    }

    /// A sentence from the article being narrated, for "preview with this article".
    func currentArticleSample(language: String) -> String? {
        controller.currentScript?.segments.first { !$0.isAnnouncement && $0.language?.base == language }
            .map { String($0.spokenText.prefix(220)) }
    }

    /// The voice narration uses right now for the current article's language.
    var currentVoice: SpeechVoice? {
        guard state.item != nil else { return nil }
        let base = controller.currentScript?.language?.base ?? "en"
        if let id = chosenVoiceID(for: base), isUsable(id) {
            return voices.first { $0.id == id }
        }
        return engine.resolvedVoice(for: controller.currentScript?.language)
    }

    /// Recomputes `activeVoice` and `voiceChoices`. Cheap enough to call on
    /// changes, too slow to compute on every spoken word (it asks iOS for
    /// its voices and sorts them).
    func refreshActiveVoice() {
        let voice = currentVoice
        if voice != activeVoice { activeVoice = voice }
        let language = controller?.currentScript?.language?.base ?? voice?.languageCode.base ?? "en"
        let choices = (voiceSections(filter: VoiceFilter(language: language)).first?.voices ?? []).filter(\.isInstalled)
        if choices != voiceChoices { voiceChoices = choices }
    }

    func requestPersonalVoice() async -> Bool {
        let granted = await AppleSpeechEngine.requestPersonalVoiceAccess()
        await loadVoices()
        return granted
    }

    // MARK: Private

    // MARK: Neural voices

    enum ModelDownload: Equatable {
        case downloading
        case failed(String)
    }

    /// Neural voices narrate for Premium, and in test builds.
    var neuralVoicesAllowed: Bool { app?.entitlements.isPremium == true || isTestBuild }

    /// The neural voice for a segment, if it should get one: the feed's or
    /// the language's chosen voice, downloaded, and allowed. Anything else
    /// is read by Apple's voices.
    func neuralVoiceID(for segment: SpeechSegment) -> String? {
        let base = segment.language?.base ?? controller?.currentScript?.language?.base ?? "en"
        guard let id = segment.voiceID ?? chosenVoiceID(for: base), isUsable(id) else { return nil }
        return id
    }

    /// Renders the next story's first sentences while this one finishes, so
    /// a natural voice starts it without a pause. They land in the audio
    /// cache, where narration finds them.
    private func renderAhead(_ script: SpeechScript) {
        guard let synthesizer = synthesizers else { return }
        let pieces = script.segments.prefix(3).compactMap { segment in
            neuralVoiceID(for: segment).map { (text: segment.spokenText, language: segment.language, voice: $0) }
        }
        guard !pieces.isEmpty else { return }
        Task.detached(priority: .utility) {
            for piece in pieces {
                _ = try? await synthesizer.synthesize(text: piece.text, language: piece.language, voiceID: piece.voice)
            }
        }
    }

    /// The voice for a language: the one the user chose (Apple or natural),
    /// otherwise Ivy once she's on the device, otherwise nil (Apple's best).
    func chosenVoiceID(for base: String) -> String? {
        if let id = preferences.voiceByLanguage[base] { return id }
        guard let ivy = NeuralVoiceCatalog.includedVoiceID(for: base), isUsable(ivy) else { return nil }
        return ivy
    }

    /// Ivy downloads by herself on the first launch, on Wi-Fi only, so the
    /// first article is already read in her voice. Once she's there her
    /// model is loaded early, so the first word comes quickly. Removed
    /// voices stay removed until the user downloads them again.
    private func prepareIvy() {
        if installedModels.contains(NeuralVoiceCatalog.includedModel) {
            let synthesizer = neuralSynthesizer
            Task.detached(priority: .utility) { try? await synthesizer.prepare(NeuralVoiceCatalog.includedModel) }
            return
        }
        guard !preferences.naturalVoicesRemoved, !AppModel.isUIReset, !AppModel.isDemoLaunch, ivyNetwork == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied, !path.isExpensive, !path.isConstrained else { return }
            Task { @MainActor [weak self] in
                guard let self, let network = self.ivyNetwork else { return }
                network.cancel()
                self.ivyNetwork = nil
                if !self.installedModels.contains(NeuralVoiceCatalog.includedModel) { self.downloadModel(NeuralVoiceCatalog.includedModel) }
            }
        }
        ivyNetwork = monitor
        monitor.start(queue: DispatchQueue(label: "paperwire.ivy-network"))
    }

    /// True when a language is read by a neural voice that reports no word
    /// timings (Supertonic, Paradee). Narration then goes sentence by
    /// sentence, so the page can show exactly which sentence is being read.
    func voiceLacksWordTimings(for language: LanguageCode?) -> Bool {
        guard let id = chosenVoiceID(for: language?.base ?? "en"), isUsable(id),
              let voice = NeuralVoiceCatalog.voice(id) else { return false }
        return !voice.model.hasWordTimings
    }

    /// A neural or server voice narration may use right now.
    func isUsable(_ id: String) -> Bool {
        guard neuralVoicesAllowed || NeuralVoiceCatalog.isIncluded(id) else { return false }
        if let voice = NeuralVoiceCatalog.voice(id) { return installedModels.contains(voice.model) }
        if VoiceServer.isServerVoice(id) { return serverVoices.contains { $0.id == id } }
        return false
    }

    /// Makes one neural voice the default for every language it speaks
    /// (a Supertonic voice speaks all five), so one choice covers everything.
    func useNeuralVoice(_ modelVoice: String, model: NeuralVoiceCatalog.Model) {
        for voice in NeuralVoiceCatalog.all where voice.model == model && voice.modelVoice == modelVoice {
            preferences.voiceByLanguage[LanguageCode(voice.language).base] = voice.id
        }
        preferences.favouriteVoiceIDs = VoiceLibrary.touch(NeuralVoiceCatalog.all.first {
            $0.model == model && $0.modelVoice == modelVoice
        }?.id ?? "", in: preferences.favouriteVoiceIDs)
        if state.status == .playing || state.status == .paused { controller.selectVoice(nil) }
        refreshActiveVoice()
    }

    /// Languages this neural voice reads, chosen or (Ivy) by default.
    func languages(using modelVoice: String, model: NeuralVoiceCatalog.Model) -> [String] {
        NeuralVoiceCatalog.all.filter { $0.model == model && $0.modelVoice == modelVoice }
            .filter { chosenVoiceID(for: LanguageCode($0.language).base) == $0.id }
            .map { LanguageCode($0.language).base }
    }

    // MARK: Voice server

    enum VoiceServerStatus: Equatable {
        case notSet
        case connecting
        case connected(Int)
        case failed(String)
    }

    /// Connects to the user's speech server, lists its voices and remembers it.
    func connectVoiceServer(address: String, apiKey: String) async {
        guard let base = VoiceServer.normalizedBase(address) else {
            voiceServerStatus = .failed("That doesn't look like a server address. Try http://192.168.0.19:8880")
            return
        }
        voiceServerStatus = .connecting
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let remote = makeRemote(base: base, apiKey: key)
        do {
            let ids = try await remote.voices()
            guard !ids.isEmpty else {
                voiceServerStatus = .failed("The server answered but offers no voices.")
                return
            }
            if key.isEmpty { try? serverKeys.removePassword(for: base.absoluteString) } else {
                try? serverKeys.setPassword(key, for: base.absoluteString)
            }
            preferences.voiceServerURL = base.absoluteString
            preferences.serverVoiceIDs = ids
            serverVoices = ids.map(VoiceServer.voice(serverID:))
            await synthesizers.set(remote, for: VoiceServer.prefix)
            voiceServerStatus = .connected(ids.count)
            await loadVoices()
        } catch {
            voiceServerStatus = .failed(error.localizedDescription)
        }
    }

    func removeVoiceServer() async {
        if let address = preferences.voiceServerURL { try? serverKeys.removePassword(for: address) }
        preferences.voiceServerURL = nil
        preferences.serverVoiceIDs = []
        for (language, id) in preferences.voiceByLanguage where VoiceServer.isServerVoice(id) {
            preferences.voiceByLanguage[language] = nil
        }
        for (feed, id) in preferences.feedVoices where VoiceServer.isServerVoice(id) { preferences.feedVoices[feed] = nil }
        serverVoices = []
        await synthesizers.set(nil, for: VoiceServer.prefix)
        voiceServerStatus = .notSet
        await loadVoices()
    }

    private func makeRemote(base: URL, apiKey: String?) -> RemoteSpeechSynthesizer {
        RemoteSpeechSynthesizer(base: base, apiKey: apiKey,
                                cache: SpeechAudioCache(directory: Self.folder("ServerNarration", in: .cachesDirectory)),
                                measure: { url in
                                    guard let file = try? AVAudioFile(forReading: url) else { return nil }
                                    return Double(file.length) / file.processingFormat.sampleRate
                                })
    }

    func downloadModel(_ model: NeuralVoiceCatalog.Model) {
        guard modelDownloads[model] != .downloading else { return }
        modelDownloads[model] = .downloading
        preferences.naturalVoicesRemoved = false
        let synthesizer = neuralSynthesizer
        let store = neuralModels
        Task { [weak self] in
            do {
                try await synthesizer.prepare(model)
                try store.markInstalled(model)
                guard let self else { return }
                if model == .kokoro { self.kokoroCrashed = false }
                self.modelDownloads[model] = nil
                self.installedModels.insert(model)
                self.neural.voices = NeuralVoiceCatalog.speechVoices(installed: self.installedModels)
                await self.loadVoices()
            } catch {
                self?.modelDownloads[model] = .failed(error.localizedDescription)
            }
        }
    }

    /// Deletes downloaded models and rendered audio; chosen neural voices go back to automatic.
    func removeNeuralVoices() async {
        stopPreview()
        if narration.state != .idle,
           controller.currentScript?.segments.contains(where: { neuralVoiceID(for: $0) != nil }) == true
        {
            pause()
        }
        await neuralSynthesizer.unload()
        try? neuralModels.removeAll()
        await neuralSynthesizer.cache.removeAll()
        installedModels = []
        neural.voices = NeuralVoiceCatalog.speechVoices(installed: [])
        for (language, id) in preferences.voiceByLanguage where NeuralVoiceCatalog.isNeural(id) {
            preferences.voiceByLanguage[language] = nil
        }
        for (feed, id) in preferences.feedVoices where NeuralVoiceCatalog.isNeural(id) {
            preferences.feedVoices[feed] = nil
        }
        preferences.naturalVoicesRemoved = true
        await loadVoices()
    }

    /// Models plus rendered narration, in bytes.
    func neuralBytesOnDisk() async -> Int64 {
        let store = neuralModels
        let models = await Task.detached { store.bytesOnDisk() }.value
        return models + (await neuralSynthesizer.cache.totalBytes())
    }

    /// Measures a neural voice on this iPhone (Voice Lab). Narration pauses
    /// and the app's loaded models are freed first, so memory isn't doubled.
    func benchmark(voiceID: String) async throws -> NeuralBenchmark.Result {
        stopPreview()
        if narration.state == .speaking { pause() }
        await neuralSynthesizer.unload()
        return try await NeuralBenchmark.run(voiceID: voiceID, texts: VoiceLabSamples.paragraphs(for: voiceID),
                                             modelsDirectory: neuralModels.directory, kokoroCrashMarker: Self.kokoroCrashMarker)
    }

    private func previewNeural(_ voice: SpeechVoice, text: String) {
        if previewingVoiceID == voice.id {
            stopPreview()
            return
        }
        guard isUsable(voice.id) || NeuralVoiceCatalog.voice(voice.id).map({ installedModels.contains($0.model) }) == true
        else { return }
        if narration.state == .speaking { pause() }
        previewer.stop()
        neuralPreviewTask?.cancel()
        neuralPreview.stop()
        previewingVoiceID = voice.id
        previewError = nil
        try? session.activate()
        let synthesizer = synthesizers!
        let rate = preferences.rate
        neuralPreviewTask = Task { [weak self] in
            do {
                let speech = try await synthesizer.synthesize(text: text, language: voice.languageCode, voiceID: voice.id)
                guard let self, !Task.isCancelled else { return }
                try self.neuralPreview.play(speech.audio, from: 0, rate: rate)
                while !self.neuralPreview.isFinished { try await Task.sleep(for: .milliseconds(150)) }
            } catch {
                guard !Task.isCancelled else { return }
                self?.previewError = "The neural voice couldn't play this sample (\(error.localizedDescription))."
            }
            guard let self, !Task.isCancelled else { return }
            self.neuralPreview.stop()
            self.neuralPreviewTask = nil
            if self.previewingVoiceID == voice.id { self.previewingVoiceID = nil }
        }
    }

    nonisolated static func folder(_ name: String, in base: FileManager.SearchPathDirectory) -> URL {
        let root = (try? FileManager.default.url(for: base, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return root.appendingPathComponent("Folio/\(name)", isDirectory: true)
    }

    private static func detectTestBuild() async -> Bool {
        #if DEBUG
        return true
        #else
        if Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt" { return true }  // TestFlight
        guard let result = try? await AppTransaction.shared, case .verified(let transaction) = result else { return false }
        return transaction.environment != .production
        #endif
    }

    private func activateSession() {
        try? session.activate()
    }

    private func itemFinished(_ item: ListenItem) {
        guard let bulletin, bulletin.markReadWhenFinished, bulletin.contains(item.id) else { return }
        Task { await app?.setRead(true, [item.id]) }
    }

    private func stateChanged(_ new: ReadAlongState) {
        let itemChanged = new.item?.id != state.item?.id
        let queueChanged = itemChanged || new.upNext != state.upNext || new.status != state.status
        state = new
        if new.item != nowPlaying { nowPlaying = new.item }
        if new.upNext != upNext { upNext = new.upNext }
        if itemChanged { refreshActiveVoice() }
        if new.status == .finished && new.upNext.isEmpty { bulletin = nil }
        save(force: queueChanged)
        guard let item = new.item, let script = controller.currentScript else {
            if new.item == nil {
                session.clearNowPlaying()
                if !marks.isEmpty { marks = [] }
                marksKey = nil
            }
            return
        }
        let key = "\(item.id)#\(script.segments.count)"
        if key != marksKey {
            marksKey = key
            marks = script.marks
        }
        let total = script.estimatedDuration(rate: new.rate.multiplier)
        session.updateNowPlaying(title: item.title, feed: item.feedTitle, elapsed: total * new.progress, duration: total,
                                 rate: new.rate.multiplier, isPlaying: new.status == .playing)
        if new.status == .finished && new.upNext.isEmpty { session.deactivate() }
    }

    /// Saves the queue at most every few seconds while words advance, and
    /// immediately when the queue or play state changes.
    private func save(force: Bool) {
        guard force || Date().timeIntervalSince(lastSavedAt) > 3 else { return }
        lastSavedAt = Date()
        guard let controller, hasQueue, !(state.status == .finished && state.upNext.isEmpty) else {
            Preferences.remove(.listening)
            return
        }
        Preferences.save(SavedListening(current: state.item, position: controller.currentPosition, upNext: state.upNext,
                                        bulletin: bulletin), key: .listening)
    }
}
