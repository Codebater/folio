import Foundation
import Testing
import FolioCore
import FolioReader
@testable import FolioAudio

func voice(_ id: String, _ name: String, _ language: String, _ quality: SpeechVoice.Quality = .standard,
           gender: SpeechVoice.Gender = .unspecified, personal: Bool = false) -> SpeechVoice {
    SpeechVoice(id: id, name: name, language: language, quality: quality, engineID: "apple", isPersonalVoice: personal, gender: gender)
}

@Suite("Voice Library")
struct VoiceLibraryTests {
    let voices = [
        voice("en.samantha", "Samantha", "en-US", .enhanced, gender: .female),
        voice("en.daniel", "Daniel", "en-GB", .standard, gender: .male),
        voice("en.zoe", "Zoe", "en-US", .premium, gender: .female),
        voice("de.anna", "Anna", "de-DE", .premium, gender: .female),
        voice("de.markus", "Markus", "de-AT", .standard, gender: .male),
        voice("sk.laura", "Laura", "sk-SK", .enhanced, gender: .female),
        voice("fr.thomas", "Thomas", "fr-FR", .standard, gender: .male),
        voice("en.me", "My Voice", "en-US", .premium, personal: true),
    ]

    @Test func putsYourLanguagesFirstThenTheRest() {
        let sections = VoiceLibrary.sections(voices: voices, preferredLanguages: ["de", "en", "sk", "de"])
        #expect(sections.map(\.id) == ["de", "en", "sk", "fr"])
        #expect(sections.prefix(3).allSatisfy(\.isPreferred) && !sections[3].isPreferred)
    }

    @Test func ordersDefaultThenFavouritesThenQuality() {
        let sections = VoiceLibrary.sections(voices: voices, preferredLanguages: ["en"],
                                             defaults: ["en": "en.daniel"], favourites: ["en.samantha"])
        #expect(sections[0].voices.map(\.id) == ["en.daniel", "en.samantha", "en.me", "en.zoe"])
        #expect(sections[0].defaultVoiceID == "en.daniel")
    }

    @Test func filtersByQueryLanguageQualityAndGender() {
        #expect(VoiceLibrary.sections(voices: voices, filter: VoiceFilter(query: "ann")).flatMap(\.voices).map(\.id) == ["de.anna"])
        #expect(VoiceLibrary.sections(voices: voices, filter: VoiceFilter(language: "de")).map(\.id) == ["de"])
        let premium = VoiceLibrary.sections(voices: voices, filter: VoiceFilter(minimumQuality: .premium)).flatMap(\.voices)
        #expect(Set(premium.map(\.id)) == ["en.zoe", "de.anna", "en.me"])
        let male = VoiceLibrary.sections(voices: voices, filter: VoiceFilter(gender: .male)).flatMap(\.voices)
        #expect(Set(male.map(\.id)) == ["en.daniel", "de.markus", "fr.thomas"])
    }

    @Test func picksTheBestAutomaticVoiceButNeverAPersonalOne() {
        #expect(VoiceLibrary.automaticVoice(for: "en", in: voices)?.id == "en.zoe")
        #expect(VoiceLibrary.automaticVoice(for: "de", region: "AT", in: voices)?.id == "de.anna")  // quality beats region
        #expect(VoiceLibrary.automaticVoice(for: "es", in: voices) == nil)
    }

    @Test func reportsDefaultsThatAreNoLongerInstalled() {
        let missing = VoiceLibrary.missingDefaults(["de": "de.anna", "es": "es.monica"], installed: voices)
        #expect(missing == ["es": "es.monica"])
    }

    @Test func keepsRecentFavouritesFirstWithoutDuplicates() {
        #expect(VoiceLibrary.touch("b", in: ["a", "b", "c"]) == ["b", "a", "c"])
        #expect(VoiceLibrary.touch("z", in: Array(repeating: "x", count: 1) + (1...20).map(String.init), limit: 3) == ["z", "x", "1"])
    }

    @Test func ourVoicesAppearOnlyWhenTheBuildCarriesTheirStyle() {
        // Our Ivy-family styles ship inside the app; a build without the file
        // (a fork, the public CI) doesn't offer the voice at all.
        let without = NeuralVoiceCatalog.speechVoices(installed: [.supertonic])
        #expect(!without.contains { $0.id == "neural.supertonic.orion.en" })
        #expect(without.contains { $0.id == "neural.supertonic.F1.cs" })
        let with = NeuralVoiceCatalog.speechVoices(installed: [.supertonic], bundledStyles: ["orion"])
        #expect(with.filter { $0.id.hasPrefix("neural.supertonic.orion.") }.count == 5)
        #expect(!with.contains { $0.id == "neural.supertonic.atlas.en" })
        // Each speaks Ivy's five languages, and Ivy stays the included voice.
        #expect(NeuralVoiceCatalog.voice("neural.supertonic.atlas.sk")?.tone?.lowDB == 3.5)
        #expect(!NeuralVoiceCatalog.isIncluded("neural.supertonic.orion.en"))
    }

    @Test func voiceRegionsAndSamples() {
        #expect(voice("x", "X", "en-GB").region == "GB")
        #expect(voice("x", "X", "de").region == nil)
        #expect(VoiceSamples.sentence(for: "sk-SK").hasPrefix("Takto znie Paperwire"))
        #expect(VoiceSamples.sentence(for: "ja").hasPrefix("This is how Paperwire sounds"))
        #expect(VoiceTuning(pitch: 3, rate: 0.1) == VoiceTuning(pitch: 1.2, rate: 0.8))
    }
}

@Suite("Regex pronunciation and cleanup")
struct RegexAndCleanupTests {
    @Test func regexRulesUseCaptureGroups() {
        let rules = PronunciationRules(userEntries: [
            PronunciationEntry(written: #"(\d+) ?km\b"#, spoken: "$1 kilometres", isRegex: true),
            PronunciationEntry(written: #"\bv(\d+)\.(\d+)"#, spoken: "version $1 point $2", caseSensitive: false, isRegex: true),
        ])
        #expect(rules.spoken("It is 12 km away, 40km more in V2.5.", language: .english, cleanup: .off)
            == "It is 12 kilometres away, 40 kilometres more in version 2 point 5.")
    }

    @Test func invalidRegexIsReportedAndIgnored() {
        let broken = PronunciationEntry(written: "(unclosed", spoken: "x", isRegex: true)
        #expect(broken.problem != nil)
        #expect(PronunciationRules(userEntries: [broken]).spoken("(unclosed text", language: .english, cleanup: .off) == "(unclosed text")
        #expect(PronunciationEntry(written: "", spoken: "x").problem != nil)
    }

    @Test func oldSavedEntriesStillDecode() throws {
        let json = #"[{"written":"SQL","spoken":"sequel","caseSensitive":true}]"#
        let entries = try JSONDecoder().decode([PronunciationEntry].self, from: Data(json.utf8))
        #expect(entries.first?.isRegex == false && entries.first?.spoken == "sequel")
    }

    @Test func removesCitationsAndFootnoteMarkersFromSpeechOnly() {
        let rules = PronunciationRules()
        #expect(rules.spoken("Owls fly silently [3], as shown [12–14]. See note* and²³.", language: .english)
            == "Owls fly silently, as shown. See note and.")
        #expect(rules.spoken("Owls fly silently [3].", language: .english, cleanup: .off) == "Owls fly silently [3].")
    }

    @Test func recognisesBoilerplateParagraphs() {
        let cleanup = SpeechCleanup()
        #expect(cleanup.isBoilerplate("The post Why pages feel quiet appeared first on The Margin."))
        #expect(cleanup.isBoilerplate("Read more »"))
        #expect(cleanup.isBoilerplate("Weiterlesen"))
        #expect(cleanup.isBoilerplate("Share this:"))
        #expect(!cleanup.isBoilerplate("Read more about the measure in our guide, which explains line length."))
        #expect(!SpeechCleanup.off.isBoilerplate("Read more"))
    }
}

@Suite("Script: cleanup, languages, voices")
struct ScriptOptionsTests {
    @Test func skipsBoilerplateAndSuperscriptCitations() {
        let doc = ArticleParser.parse(html: """
            <p>Owls hunt at night<sup>1</sup> and rest by day.</p><p>Read more</p>
            <p>The post Owls appeared first on Field Notes.</p>
            """)
        let script = SpeechScript.build(document: doc, title: nil, options: SpeechScriptOptions(includeTitle: false, language: .english))
        #expect(script.segments.map(\.spokenText) == ["Owls hunt at night and rest by day."])
        // The highlight still maps onto the real text around the removed number.
        let segment = script.segments[0]
        let and = segment.spokenText.utf16Offset(of: segment.spokenText.range(of: "and")!.lowerBound)
        #expect(doc.blocks[0].text.utf16Slice(script.displayRange(segment: 0, spokenRange: and..<(and + 3)).range) == "and")
    }

    @Test func switchesLanguagePerParagraph() {
        var doc = ArticleParser.parse(html: """
            <p>The interview took place in Berlin, and the mayor answered every question in German.</p>
            <p>Die Stadt ist in der Nacht nicht so still, wie man denkt, und es gibt viel zu tun für alle.</p>
            <p>Short one.</p>
            """)
        doc.language = .english  // an English article quoting a German paragraph
        let script = SpeechScript.build(document: doc, title: nil, options: SpeechScriptOptions(includeTitle: false))
        #expect(script.segments.map { $0.language?.base } == ["en", "de", "en"])
        // A forced language turns switching off.
        let forced = SpeechScript.build(document: doc, title: nil, options: SpeechScriptOptions(includeTitle: false, language: .english))
        #expect(forced.segments.allSatisfy { $0.language == .english })
        let off = SpeechScript.build(document: doc, title: nil,
                                     options: SpeechScriptOptions(includeTitle: false, switchLanguagePerParagraph: false))
        #expect(off.segments.allSatisfy { $0.language?.base == "en" })
    }

    @Test func wrongSyncGuessDoesNotPickAForeignVoice() {
        // The reported bug: an English story stored as French was read with a
        // French voice. Its own text decides now.
        let doc = ArticleParser.parse(html: """
            <p>The company said on Tuesday that the update would reach every phone by the end of the month.</p>
            <p>Engineers have been testing the new version for weeks, and the results were better than they had hoped.</p>
            <p>It is the first time that the team has shipped a release of this size without a delay of any kind.</p>
            <p>Customers who want it earlier can join the beta, which opens to the public later this week.</p>
            """, title: "Update arrives")
        let script = SpeechScript.build(document: doc, title: "Update arrives",
                                        options: SpeechScriptOptions(detectedLanguage: .french))
        #expect(script.language?.base == "en")
        #expect(script.segments.allSatisfy { $0.language?.base == "en" })
    }

    @Test func shortOrUnreadLanguagesDoNotSwitchTheVoice() {
        var doc = ArticleParser.parse(html: """
            <p>The interview took place in Berlin, and the mayor answered every question in German.</p>
            <p>She has been in office for six years, and the city has changed a lot in that time.</p>
            <p>Die Stadt ist nicht so still, wie man denkt, und es gibt viel zu tun.</p>
            <p>Die Stadt ist in der Nacht nicht so still, wie man denkt, und es gibt viel zu tun für alle.</p>
            <p>When the interview was over, she walked back to her office and went on with the work of the day.</p>
            """)
        doc.language = .english
        // Fourteen German words are too few to change voice; twenty are enough.
        let script = SpeechScript.build(document: doc, title: nil, options: SpeechScriptOptions(includeTitle: false))
        #expect(script.segments.map { $0.language?.base } == ["en", "en", "en", "de", "en"])
        // A language the reader doesn't read never takes over mid-article.
        let englishOnly = SpeechScript.build(document: doc, title: nil,
                                             options: SpeechScriptOptions(includeTitle: false, switchLanguages: ["en"]))
        #expect(englishOnly.segments.allSatisfy { $0.language?.base == "en" })
    }

    @Test func preferredVoiceAppliesOnlyToItsLanguage() {
        var doc = ArticleParser.parse(html: """
            <p>The interview took place in Berlin, and the mayor answered every question in German.</p>
            <p>Die Stadt ist in der Nacht nicht so still, wie man denkt, und es gibt viel zu tun für alle.</p>
            """)
        doc.language = .english
        let options = SpeechScriptOptions(includeTitle: false, preferredVoice: PreferredVoice(id: "en.zoe", languageBase: "en"))
        let script = SpeechScript.build(document: doc, title: nil, options: options)
        #expect(script.segments.map(\.voiceID) == ["en.zoe", nil])
    }
}
