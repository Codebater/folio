import Foundation
import FolioCore
import FolioReader

/// A place in the article, in display coordinates: a block id and a UTF-16
/// offset into that block's text.
public struct SpeechPosition: Hashable, Sendable, Codable {
    public var blockID: String
    public var offset: Int

    public init(blockID: String, offset: Int = 0) {
        self.blockID = blockID
        self.offset = offset
    }
}

/// Text that is spoken but not shown, such as "From Field Notes: ...".
public struct SpeechAnnouncement: Hashable, Sendable, Codable {
    public var text: String
    public var language: LanguageCode?

    public init(_ text: String, language: LanguageCode? = nil) {
        self.text = text
        self.language = language
    }
}

/// One utterance: a whole paragraph, or one sentence in sentence mode.
public struct SpeechSegment: Hashable, Sendable {
    public var index: Int
    public var blockID: String
    /// The part of the block's display text this segment covers.
    public var displayRange: Range<Int>
    /// What the engine is given to read.
    public var spokenText: String
    /// Spoken ↔ display offsets, display side relative to `displayRange.lowerBound`.
    public var map: OffsetMap
    public var language: LanguageCode?
    /// Silence after this segment, in seconds.
    public var pauseAfter: Double
    public var isHeading: Bool
    /// A specific voice for this segment (per-feed voice); nil = by language.
    public var voiceID: String?
    /// The sentences this segment covers, in block coordinates: one in
    /// sentence mode, all of the paragraph's in paragraph mode. They let the
    /// page show the sentence being read.
    public var sentences: [Range<Int>] = []

    public var isAnnouncement: Bool { blockID.hasPrefix(SpeechScript.announcementPrefix) }
}

/// A voice chosen for an article (e.g. per feed). It applies to the segments
/// in its language; other languages still use their own default voice.
public struct PreferredVoice: Hashable, Sendable, Codable {
    public var id: String
    public var languageBase: String

    public init(id: String, languageBase: String) {
        self.id = id
        self.languageBase = languageBase
    }
}

public struct SpeechScriptOptions: Sendable {
    public enum Granularity: String, Sendable, Codable, CaseIterable { case paragraph, sentence }

    public var granularity: Granularity
    public var includeTitle: Bool
    public var paragraphPause: Double
    public var headingPause: Double
    /// Extra pause between sentences in sentence mode.
    public var sentencePause: Double
    /// Overrides the detected language (and turns off per-paragraph switching).
    public var language: LanguageCode?
    /// The language guessed when the article was synced. Weak evidence: it
    /// often comes from a short summary.
    public var detectedLanguage: LanguageCode?
    /// The language the article's feed usually writes in.
    public var feedLanguage: LanguageCode?
    /// Base languages a paragraph may switch to (the languages the reader
    /// actually reads); nil allows any.
    public var switchLanguages: Set<String>?
    public var pronunciation: PronunciationRules
    public var cleanup: SpeechCleanup
    /// Paragraphs in another language than the article are read with that
    /// language's voice and rules (mixed English/German articles, quotes).
    public var switchLanguagePerParagraph: Bool
    public var preferredVoice: PreferredVoice?
    /// The feed's name: removed from titles that repeat it, and said before
    /// the title when `announceSource` is on ("The Margin. Why …").
    public var sourceName: String?
    public var announceSource: Bool
    /// Silence after the title, longer than after a heading, like a breath
    /// before the story starts.
    public var titlePause: Double

    public init(granularity: Granularity = .paragraph, includeTitle: Bool = true, paragraphPause: Double = 0.35,
                headingPause: Double = 0.6, sentencePause: Double = 0.12, language: LanguageCode? = nil,
                pronunciation: PronunciationRules = PronunciationRules(), cleanup: SpeechCleanup = SpeechCleanup(),
                switchLanguagePerParagraph: Bool = true, preferredVoice: PreferredVoice? = nil,
                sourceName: String? = nil, announceSource: Bool = false, titlePause: Double = 0.9,
                detectedLanguage: LanguageCode? = nil, feedLanguage: LanguageCode? = nil, switchLanguages: Set<String>? = nil) {
        self.granularity = granularity
        self.includeTitle = includeTitle
        self.paragraphPause = paragraphPause
        self.headingPause = headingPause
        self.sentencePause = sentencePause
        self.language = language
        self.pronunciation = pronunciation
        self.cleanup = cleanup
        self.switchLanguagePerParagraph = switchLanguagePerParagraph
        self.preferredVoice = preferredVoice
        self.sourceName = sourceName
        self.announceSource = announceSource
        self.titlePause = titlePause
        self.detectedLanguage = detectedLanguage
        self.feedLanguage = feedLanguage
        self.switchLanguages = switchLanguages
    }
}

/// Everything an engine needs to narrate one article, plus the mapping back
/// to the page. Built once per article (and rebuilt when options change).
public struct SpeechScript: Sendable {
    /// The article title is addressable like a block, matching the renderer.
    public static let titleBlockID = "title"
    /// Spoken-only segments (bulletin openings, story introductions) use
    /// block ids with this prefix. They exist in no page, so nothing is
    /// highlighted while they play.
    public static let announcementPrefix = "announcement-"
    /// A paragraph is read in another language than the article only when it
    /// has at least this many words and the guess is at least this sure.
    /// Short paragraphs full of names are easily mistaken for another language.
    public static let minimumSwitchWords = 20
    public static let minimumSwitchConfidence = 0.8
    /// Languages too close to tell apart paragraph by paragraph (Czech and
    /// Slovak): an article never switches between them.
    static func closeRelatives(_ a: LanguageCode?, _ b: LanguageCode?) -> Bool {
        let family: Set<String> = ["cs", "sk"]
        guard let a = a?.base, let b = b?.base else { return false }
        return family.contains(a) && family.contains(b)
    }

    /// Silence around a quote, longer than between paragraphs.
    static let quotePause = 0.7

    public let articleID: ArticleID?
    public let language: LanguageCode?
    public let segments: [SpeechSegment]
    /// Every block id in document order (title first), speakable or not, so a
    /// tap on an image can start at the next spoken paragraph.
    let blockOrder: [String]
    private let cumulative: [Int]

    public init(articleID: ArticleID?, language: LanguageCode?, segments: [SpeechSegment], blockOrder: [String]) {
        self.articleID = articleID
        self.language = language
        self.segments = segments
        self.blockOrder = blockOrder
        var running = 0
        var cumulative: [Int] = []
        for segment in segments {
            cumulative.append(running)
            running += segment.spokenText.utf16Length
        }
        self.cumulative = cumulative + [running]
    }

    public static func build(
        document: ArticleDocument, title: String?, articleID: ArticleID? = nil,
        options: SpeechScriptOptions = SpeechScriptOptions(),
        segmenter: any SentenceSegmenting = RuleBasedSentenceSegmenter(),
        languageGuesser: (any LanguageGuessing)? = StopwordLanguageGuesser(),
        announcementsBefore: [SpeechAnnouncement] = [],
        announcementsAfter: [SpeechAnnouncement] = []
    ) -> SpeechScript {
        let sample = String(document.blocks.filter(\.isSpeakable).map(\.text).joined(separator: " ").prefix(3000))
        let language = options.language ?? ArticleLanguage.resolve(
            text: sample, guesser: languageGuesser, feed: options.feedLanguage,
            fallback: options.detectedLanguage ?? document.language)
        var segments: [SpeechSegment] = []
        var order: [String] = []

        /// `blockEdits` are in block coordinates; they are clipped to the range.
        func add(blockID: String, text: String, range: Range<Int>, pause: Double, heading: Bool, language: LanguageCode?,
                 blockEdits: [PronunciationEdit] = [], voiceID: String? = nil, sentences: [Range<Int>]? = nil) {
            let slice = String(text.utf16Slice(range))
            let local = blockEdits
                .filter { $0.range.lowerBound >= range.lowerBound && $0.range.upperBound <= range.upperBound }
                .map { PronunciationEdit(range: ($0.range.lowerBound - range.lowerBound)..<($0.range.upperBound - range.lowerBound),
                                         replacement: $0.replacement) }
            let edits = PronunciationRules.resolve(
                options.pronunciation.edits(for: slice, language: language) + options.cleanup.edits(for: slice) + local)
            let (spoken, map) = PronunciationRules.apply(edits, to: slice)
            guard spoken.contains(where: { $0.isLetter || $0.isNumber }) else { return }
            let voice = voiceID ?? options.preferredVoice.flatMap { $0.languageBase == language?.base ? $0.id : nil }
            segments.append(SpeechSegment(index: segments.count, blockID: blockID, displayRange: range, spokenText: spoken,
                                          map: map, language: language, pauseAfter: pause, isHeading: heading, voiceID: voice,
                                          sentences: sentences ?? [range]))
        }

        /// Spoken-only words between blocks ("Table skipped."), never highlighted.
        func addCue(_ cue: SpokenCue, after blockID: String, detail: String = "") {
            let id = announcementPrefix + "cue-" + blockID + "-" + cue.rawValue
            order.append(id)
            let text = TextNormalizer.normalize(cue.text(language: language) + (detail.isEmpty ? "" : " " + detail))
            add(blockID: id, text: text, range: 0..<text.utf16Length, pause: options.paragraphPause, heading: false, language: language)
        }

        /// A longer breath before something set apart, such as a quote.
        func breathe(_ seconds: Double) {
            guard let last = segments.indices.last else { return }
            segments[last].pauseAfter = max(segments[last].pauseAfter, seconds)
        }

        func blockLanguage(_ text: String) -> LanguageCode? {
            guard options.language == nil, options.switchLanguagePerParagraph, let languageGuesser,
                  TextNormalizer.wordCount(text) >= minimumSwitchWords,
                  let guess = languageGuesser.guess(text), guess.confidence >= minimumSwitchConfidence,
                  guess.language.base != language?.base,
                  options.switchLanguages?.contains(guess.language.base) ?? true,
                  !Self.closeRelatives(guess.language, language)
            else { return language }
            return guess.language
        }

        func addBlock(id: String, text: String, isHeading: Bool, spans: [InlineSpan] = [], ordinal: Int? = nil) {
            let blockPause = isHeading ? options.headingPause : options.paragraphPause
            let blockLang = isHeading ? language : blockLanguage(text)
            let superscripts = spans.filter { $0.style == .superscript }.map { InlineSpanInfo(range: $0.start..<$0.end) }
            var blockEdits = options.cleanup.edits(forSpans: superscripts, in: text)
            // Numbered list items say their number, as the page shows it.
            if let ordinal { blockEdits.insert(PronunciationEdit(range: 0..<0, replacement: "\(ordinal). "), at: 0) }
            let sentences = isHeading ? [0..<text.utf16Length] : segmenter.sentences(in: text, language: blockLang)
            switch options.granularity {
            case .paragraph:
                add(blockID: id, text: text, range: 0..<text.utf16Length, pause: blockPause, heading: isHeading,
                    language: blockLang, blockEdits: blockEdits, sentences: sentences)
            case .sentence:
                for (i, range) in sentences.enumerated() {
                    add(blockID: id, text: text, range: range, pause: i == sentences.count - 1 ? blockPause : options.sentencePause,
                        heading: isHeading, language: blockLang, blockEdits: blockEdits)
                }
            }
        }

        func addAnnouncement(_ announcement: SpeechAnnouncement, number: Int) {
            let id = announcementPrefix + String(number)
            order.append(id)
            let text = TextNormalizer.normalize(announcement.text)
            add(blockID: id, text: text, range: 0..<text.utf16Length, pause: options.headingPause, heading: false,
                language: announcement.language ?? language)
        }

        for (i, announcement) in announcementsBefore.enumerated() { addAnnouncement(announcement, number: i) }
        if options.includeTitle, let title, !title.isEmpty {
            if options.announceSource, let source = options.sourceName.map(TextNormalizer.normalize), !source.isEmpty {
                let id = announcementPrefix + "source"
                order.append(id)
                add(blockID: id, text: source, range: 0..<source.utf16Length, pause: 0.3, heading: false, language: language)
            }
            order.append(titleBlockID)
            let text = TextNormalizer.normalize(title)
            add(blockID: titleBlockID, text: text, range: 0..<text.utf16Length, pause: options.titlePause, heading: true,
                language: language, blockEdits: TitleCleaner.edits(for: text, source: options.sourceName))
        } else {
            order.append(titleBlockID)
        }
        var inQuote = false
        var lastSkipped: SpokenCue?
        func closeQuote(after blockID: String) {
            guard inQuote else { return }
            inQuote = false
            if options.cleanup.announceQuotes { addCue(.endQuote, after: blockID) }
            breathe(quotePause)
        }
        var previousID = titleBlockID
        for block in document.blocks {
            order.append(block.id)
            let isQuote: Bool
            if case .quote = block.kind { isQuote = true } else { isQuote = false }
            if !isQuote { closeQuote(after: previousID) }
            defer { previousID = block.id }
            switch block.kind {
            case .table where options.cleanup.mentionSkipped, .preformatted where options.cleanup.mentionSkipped && !block.text.isEmpty:
                let cue: SpokenCue
                if case .table = block.kind { cue = .table } else { cue = .code }
                // Three code blocks in a row are mentioned once.
                if lastSkipped != cue { addCue(cue, after: block.id) }
                lastSkipped = cue
                continue
            case .image(let info) where options.cleanup.captions:
                let caption = block.text.isEmpty ? info.alt : block.text
                if caption.contains(where: \.isLetter) { addCue(.image, after: block.id, detail: caption) }
                continue
            default:
                break
            }
            guard block.isSpeakable, !options.cleanup.isBoilerplate(block.text) else { continue }
            lastSkipped = nil
            if isQuote && !inQuote {
                inQuote = true
                breathe(quotePause)
                if options.cleanup.announceQuotes { addCue(.quote, after: block.id) }
            }
            switch block.kind {
            case .heading:
                addBlock(id: block.id, text: block.text, isHeading: true, spans: block.spans)
            case .listItem(let ordered, let ordinal, _) where ordered:
                addBlock(id: block.id, text: block.text, isHeading: false, spans: block.spans, ordinal: ordinal)
            default:
                addBlock(id: block.id, text: block.text, isHeading: false, spans: block.spans)
            }
        }
        closeQuote(after: previousID)
        for (j, announcement) in announcementsAfter.enumerated() {
            addAnnouncement(announcement, number: announcementsBefore.count + j)
        }
        return SpeechScript(articleID: articleID, language: language, segments: segments, blockOrder: order)
    }

    public var isEmpty: Bool { segments.isEmpty }

    /// The sentence being read: exact when the engine reports words, or when
    /// the segment is a single sentence. Never guessed from elapsed time.
    public func sentence(segment index: Int, word: Range<Int>?) -> Range<Int>? {
        guard segments.indices.contains(index) else { return nil }
        let sentences = segments[index].sentences
        if let word, let match = sentences.first(where: { $0.contains(word.lowerBound) }) { return match }
        return sentences.count == 1 ? sentences[0] : nil
    }
    public var totalSpokenLength: Int { cumulative.last ?? 0 }

    /// Segment and spoken offset where narration starting at `position`
    /// should begin, snapped back to the start of the word. Positions in
    /// blocks with nothing to say move forward to the next spoken segment.
    public func locate(_ position: SpeechPosition) -> (segment: Int, spokenOffset: Int)? {
        guard !segments.isEmpty else { return nil }
        let candidates = segments.filter { $0.blockID == position.blockID }
        if !candidates.isEmpty {
            let segment = candidates.last { $0.displayRange.lowerBound <= position.offset } ?? candidates[0]
            let local = max(0, position.offset - segment.displayRange.lowerBound)
            let spoken = min(segment.map.spokenOffset(forDisplay: local), segment.spokenText.utf16Length)
            return (segment.index, Self.wordStart(in: segment.spokenText, before: spoken))
        }
        guard let blockIndex = blockOrder.firstIndex(of: position.blockID) else { return (0, 0) }
        // A tap on a table or code starts at the next paragraph, not at its "skipped" cue.
        for id in blockOrder[(blockIndex + 1)...] where !id.hasPrefix(Self.announcementPrefix + "cue-") {
            if let next = segments.first(where: { $0.blockID == id }) { return (next.index, 0) }
        }
        return nil
    }

    /// The display position of a spoken offset in a segment.
    public func position(segment index: Int, spokenOffset: Int) -> SpeechPosition {
        let segment = segments[index]
        let display = segment.map.displayRange(forSpoken: spokenOffset..<(spokenOffset + 1))
        return SpeechPosition(blockID: segment.blockID, offset: segment.displayRange.lowerBound + display.lowerBound)
    }

    /// Maps an engine-reported range (segment-local, spoken text) to the
    /// block-relative display range to highlight.
    public func displayRange(segment index: Int, spokenRange: Range<Int>) -> (blockID: String, range: Range<Int>) {
        let segment = segments[index]
        let local = segment.map.displayRange(forSpoken: spokenRange)
        let base = segment.displayRange.lowerBound
        let upper = min(base + local.upperBound, segment.displayRange.upperBound)
        return (segment.blockID, (base + local.lowerBound)..<max(base + local.lowerBound, upper))
    }

    /// 0...1 through the whole script.
    public func progress(segment index: Int, spokenOffset: Int) -> Double {
        guard totalSpokenLength > 0, index < segments.count else { return index >= segments.count ? 1 : 0 }
        return min(1, Double(cumulative[index] + min(spokenOffset, segments[index].spokenText.utf16Length)) / Double(totalSpokenLength))
    }

    /// Rough duration at a speaking rate, for the lock screen and sleep timer.
    /// Based on ~15 characters per second at 1x; labelled as an estimate in UI.
    public func estimatedDuration(rate: Double, fromSegment index: Int = 0) -> TimeInterval {
        let remaining = totalSpokenLength - (index < cumulative.count ? cumulative[index] : totalSpokenLength)
        let pauses = segments.dropFirst(index).reduce(0) { $0 + $1.pauseAfter }
        return Double(remaining) / (15 * max(rate, 0.25)) + pauses
    }

    static func wordStart(in text: String, before offset: Int) -> Int {
        let units = Array(text.utf16)
        var i = min(offset, units.count)
        while i > 0, let scalar = Unicode.Scalar(units[i - 1]), !scalar.properties.isWhitespace { i -= 1 }
        return i
    }
}

/// Short spoken signposts for what narration passes over or sets apart.
public enum SpokenCue: String, Sendable, CaseIterable {
    case image, quote, endQuote, table, code

    /// In the article's language; languages without phrases use English.
    public func text(language: LanguageCode?) -> String {
        switch (language?.base ?? "en", self) {
        case ("de", .image): "Bild:"
        case ("de", .quote): "Zitat."
        case ("de", .endQuote): "Zitat Ende."
        case ("de", .table): "Tabelle übersprungen."
        case ("de", .code): "Code übersprungen."
        case ("es", .image): "Imagen:"
        case ("es", .quote): "Cita."
        case ("es", .endQuote): "Fin de la cita."
        case ("es", .table): "Tabla omitida."
        case ("es", .code): "Código omitido."
        case ("sk", .image): "Obrázok:"
        case ("sk", .quote): "Citát."
        case ("sk", .endQuote): "Koniec citátu."
        case ("sk", .table): "Tabuľka vynechaná."
        case ("sk", .code): "Kód vynechaný."
        case ("cs", .image): "Obrázek:"
        case ("cs", .quote): "Citace."
        case ("cs", .endQuote): "Konec citace."
        case ("cs", .table): "Tabulka vynechána."
        case ("cs", .code): "Kód vynechán."
        case (_, .image): "Image:"
        case (_, .quote): "Quote."
        case (_, .endQuote): "End of quote."
        case (_, .table): "Table skipped."
        case (_, .code): "Code skipped."
        }
    }
}
