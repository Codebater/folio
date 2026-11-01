import Foundation
import Testing
@testable import FolioCore

@Suite("Text normalization")
struct TextNormalizationTests {
    @Test func collapsesWhitespaceAndTrims() {
        #expect(TextNormalizer.normalize("  Hello \n\t world  ") == "Hello world")
    }

    @Test func keepsNoBreakSpaceLikeBrowsers() {
        #expect(TextNormalizer.normalize("80\u{00A0}percent") == "80\u{00A0}percent")
    }

    @Test func dropsInvisibleCharacters() {
        #expect(TextNormalizer.normalize("co\u{00AD}op\u{200B}era\u{FEFF}tion") == "cooperation")
    }

    @Test func keepsZeroWidthJoinerForEmoji() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        #expect(TextNormalizer.normalize(family) == family)
    }

    @Test func composesToNFC() {
        let decomposed = "Cafe\u{0301} c\u{030C}aj"  // é, č as base + combining mark
        let normalized = TextNormalizer.normalize(decomposed)
        #expect(normalized == "Café čaj")
        #expect(normalized.utf16Length == 8)
    }

    @Test func countsWords() {
        #expect(TextNormalizer.wordCount("Don't split well-known words, please.") == 5)
        #expect(TextNormalizer.wordCount("日本語のテキスト") == 8)
        #expect(TextNormalizer.wordCount("") == 0)
    }

    @Test func slicesByUTF16WithoutBreakingSurrogates() {
        let text = "a\u{1F600}b"  // emoji is two UTF-16 units at 1..<3
        #expect(text.utf16Slice(0..<1) == "a")
        #expect(text.utf16Slice(1..<3) == "\u{1F600}")
        #expect(text.utf16Slice(2..<3) == "\u{1F600}")  // half a pair widens to the whole scalar
        #expect(text.utf16Slice(3..<4) == "b")
        #expect(text.utf16Slice(4..<9) == "")
    }
}

@Suite("HTML entities")
struct HTMLEntityTests {
    @Test func decodesNamedNumericAndHex() {
        #expect(HTMLText.decodeEntities("Tom &amp; Jerry &lt;3 &#8217;s &#x2014; &eacute;&yuml;") == "Tom & Jerry <3 \u{2019}s \u{2014} éÿ")
    }

    @Test func mapsWindows1252References() {
        #expect(HTMLText.decodeEntities("&#150; &#147;quoted&#148;") == "\u{2013} \u{201C}quoted\u{201D}")
    }

    @Test func leavesUnknownAndBrokenReferencesAlone() {
        #expect(HTMLText.decodeEntities("&notanentity; & alone &;") == "&notanentity; & alone &;")
    }

    @Test func acceptsLegacyReferencesWithoutSemicolon() {
        #expect(HTMLText.decodeEntities("fish &amp chips") == "fish & chips")
        #expect(HTMLText.decodeEntities("&copy2026") == "&copy2026")
    }

    @Test func rejectsInvalidCodePoints() {
        #expect(HTMLText.decodeEntities("&#0;&#xD800;&#x110000;") == "\u{FFFD}\u{FFFD}\u{FFFD}")
    }

    @Test func coversGreekAndSlovakLetters() {
        #expect(HTMLText.decodeEntities("&alpha;&Omega;&scaron;&ccaron;&Lcaron;") == "αΩščĽ")
    }
}

/// Answers what it is told, like a recognizer that is sure of itself.
private struct FixedGuesser: LanguageGuessing {
    var language: LanguageCode
    var confidence: Double
    func guess(_ text: String) -> LanguageGuess? { LanguageGuess(language: language, confidence: confidence) }
}

@Suite("Article language")
struct ArticleLanguageTests {
    let short = Array(repeating: "word", count: 25).joined(separator: " ")
    let long = Array(repeating: "word", count: 200).joined(separator: " ")

    @Test func longTextOverrulesAWrongEarlierGuess() {
        // The bug: an English story guessed as French from its summary.
        let en = FixedGuesser(language: .english, confidence: 0.7)
        #expect(ArticleLanguage.resolve(text: long, guesser: en, feed: nil, fallback: .french) == .english)
        #expect(ArticleLanguage.resolve(text: long, guesser: en, feed: .french, fallback: nil) == .english)
    }

    @Test func shortTextNeedsAStrongGuessToOverruleTheFeed() {
        let unsure = FixedGuesser(language: .french, confidence: 0.75)
        #expect(ArticleLanguage.resolve(text: short, guesser: unsure, feed: .english, fallback: .french) == .english)
        let sure = FixedGuesser(language: .german, confidence: 0.95)
        #expect(ArticleLanguage.resolve(text: short, guesser: sure, feed: .english, fallback: nil) == .german)
        // Without anything known, a fair guess is enough.
        #expect(ArticleLanguage.resolve(text: short, guesser: unsure, feed: nil, fallback: nil) == .french)
    }

    @Test func tinyTextKeepsWhatIsKnown() {
        let sure = FixedGuesser(language: .french, confidence: 0.99)
        #expect(ArticleLanguage.resolve(text: "Le Mans", guesser: sure, feed: .english, fallback: nil) == .english)
        #expect(ArticleLanguage.resolve(text: "Le Mans", guesser: sure, feed: nil, fallback: nil) == nil)
    }

    @Test func linksAndNumbersAreNotWords() {
        // A Hacker News item: twenty "words" before, mostly pieces of links.
        let item = "Article URL: https://github.com/acme/tool Comments URL: https://news.ycombinator.com/item?id=4242 Points: 125 # Comments: 47"
        #expect(ArticleLanguage.prose(item) == "Article URL: Comments URL: Points: Comments:")
        let sure = FixedGuesser(language: .french, confidence: 0.99)
        #expect(ArticleLanguage.resolve(text: item, guesser: sure, feed: nil, fallback: nil) == nil)
        #expect(ArticleLanguage.prose("See example.org/page, mail me@site.io or www.site.com (e.g. U.S. data) in Node.js")
            == "See mail or (e.g. U.S. data) in Node.js")
    }

    @Test func narrationKeepsToTheLanguagesTurnedOn() {
        #expect(ArticleLanguage.narrated(.french, allowed: ["en", "de"]) == .english)
        #expect(ArticleLanguage.narrated(LanguageCode("de-AT"), allowed: ["en", "de"]) == LanguageCode("de-AT"))
        #expect(ArticleLanguage.narrated(nil, allowed: ["de", "en"]) == .german)
        #expect(ArticleLanguage.narrated(.french, allowed: []) == .french)
        #expect(ArticleLanguage.permitted(.french, allowed: ["en"]) == nil)
        #expect(ArticleLanguage.permitted(.english, allowed: ["en"]) == .english)
    }

    @Test func feedsHaveALanguageOnlyWhenMostlyOne() {
        #expect(ArticleLanguage.dominant(["en": 40, "fr": 3]) == .english)
        #expect(ArticleLanguage.dominant(["en": 6, "de": 5]) == nil)  // a bilingual feed
        #expect(ArticleLanguage.dominant(["cs": 3]) == nil)  // too few to tell
    }
}

@Suite("Language guessing")
struct LanguageGuessTests {
    let guesser = StopwordLanguageGuesser()

    @Test(arguments: [
        ("The quick brown fox is not afraid of the dog, and it has been running for hours.", "en"),
        ("Die Stadt ist in der Nacht nicht so still, wie man denkt, und es gibt viel zu tun.", "de"),
        ("El mercado de la ciudad no duerme, y los vendedores llegan antes de que salga el sol.", "es"),
        ("Ranná správa musí byť krátka a presná, preto sa na každú vetu veľmi dbá aj v redakcii.", "sk"),
        ("Ranní zpráva musí být krátká a přesná, proto se na každou větu velmi dbá i v redakci.", "cs"),
    ])
    func guessesLanguage(text: String, expected: String) {
        #expect(guesser.guess(text)?.language.base == expected)
    }

    @Test func refusesTooShortOrUnknownText() {
        #expect(guesser.guess("Hello") == nil)
        #expect(guesser.guess("Lorem ipsum dolor sit amet consectetur adipiscing elit sed do") == nil)
    }

    @Test func normalizesTags() {
        #expect(LanguageCode("en_GB").rawValue == "en-gb")
        #expect(LanguageCode("de-AT").base == "de")
    }
}

@Suite("Identifiers, premium, retry")
struct MiscCoreTests {
    @Test func identifiersEncodeAsPlainStrings() throws {
        let data = try JSONEncoder().encode([ArticleID("123"), ArticleID("456")])
        #expect(String(decoding: data, as: UTF8.self) == #"["123","456"]"#)
        #expect(try JSONDecoder().decode([FeedID].self, from: Data(#"["feed/1"]"#.utf8)) == [FeedID("feed/1")])
    }

    @Test func freeTierAllowsNothingPremium() {
        #expect(!EntitlementState.free.isPremium)
        #expect(!EntitlementState.free.allows(.voiceControls))
        #expect(EntitlementState(activeProducts: [.lifetime]).allows(.voiceControls))
    }

    @Test func familyUpgradeIsOnlyForLifetimeOwners() {
        #expect(EntitlementState(activeProducts: [.lifetime]).canUpgradeToFamily)
        #expect(!EntitlementState(activeProducts: [.yearly]).canUpgradeToFamily)
        #expect(!EntitlementState(activeProducts: [.lifetime, .familyUpgrade]).canUpgradeToFamily)
        // A family member who received only the shared upgrade still has Premium.
        let member = EntitlementState(activeProducts: [.familyUpgrade])
        #expect(member.isPremium && member.isFamily)
    }

    @Test func muteRulesMatchWholeWordsIgnoringCaseAndAccents() {
        let rules = MuteRules(terms: ["AI", "Vision Pro", "Česko", "  "])
        #expect(rules.match("New AI model beats benchmark") == "AI")
        #expect(rules.match("He said it was fine") == nil)
        #expect(rules.match("Apple's vision-pro sales") == "Vision Pro")
        #expect(rules.match("Vision and pro audio") == nil)
        #expect(rules.match("Volby: CESKO rozhodlo") == "Česko")
        #expect(MuteRules().isEmpty && MuteRules(terms: [" "]).isEmpty)
    }

    struct Flaky: RetryClassifiable { var isTransient: Bool }

    final class Counter: @unchecked Sendable {
        var value = 0
    }

    @Test func retriesTransientErrorsOnly() async throws {
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: .milliseconds(1))
        let counter = Counter()
        let result = try await policy.run(sleep: { _ in }) {
            counter.value += 1
            if counter.value < 3 { throw Flaky(isTransient: true) }
            return "ok"
        }
        #expect(result == "ok")
        #expect(counter.value == 3)

        let permanent = Counter()
        await #expect(throws: Flaky.self) {
            try await policy.run(sleep: { _ in }) {
                permanent.value += 1
                throw Flaky(isTransient: false)
            }
        }
        #expect(permanent.value == 1)
    }

    @Test func backoffIsCapped() {
        let policy = RetryPolicy(maxAttempts: 10, baseDelay: .milliseconds(500), maxDelay: .seconds(4))
        #expect(policy.delayCeiling(afterAttempt: 1) == .milliseconds(500))
        #expect(policy.delayCeiling(afterAttempt: 3) == .seconds(2))
        #expect(policy.delayCeiling(afterAttempt: 9) == .seconds(4))
    }
}

@Suite("Same story, several sources")
struct StoryClusterTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(_ id: String, _ feed: String, _ title: String, hours: Double = 0, excerpt: String = "") -> StoryClusters.Item {
        StoryClusters.Item(id: ArticleID(id), feedID: FeedID(feed), title: title, excerpt: excerpt,
                           publishedAt: start.addingTimeInterval(hours * 3600))
    }

    /// Background so word rarity behaves like a real day of feeds.
    private var background: [StoryClusters.Item] {
        [
            ("b1", "Python 3.15 security releases are out"), ("b2", "Scientists discover how trees straighten themselves"),
            ("b3", "Salesforce reportedly buys defense startup Rune"), ("b4", "How do you take a picture of a black hole?"),
            ("b5", "Digital minimalism"), ("b6", "Zest's AI agent books restaurant reservations over text"),
            ("b7", "Coles marks steepest fall since 2020"), ("b8", "The federated code forge"),
            ("b9", "Leaking secrets from air-gap computers with radio signals from RAM"),
        ].enumerated().map { index, entry in item(entry.0, "bg\(index)", entry.1, hours: Double(index)) }
    }

    @Test func theSameNewsFromSeveralOutletsBecomesOneStory() {
        let items = background + [
            item("hn", "hackernews", "Backdoor in Claude Code for VS Code extension on the Cursor Marketplace", hours: 1),
            item("thn", "thehackernews", "Official Claude Code Extension on Cursor Marketplace Trojanized with Persistent SSH Backdoor", hours: 2),
            item("bc", "bleeping", "Malicious Claude Code extension on Cursor planted SSH backdoors", hours: 3),
        ]
        let groups = StoryClusters.find(items)
        #expect(groups.count == 1)
        #expect(Set(groups.first ?? []) == ["hn", "thn", "bc"])
        #expect(groups.first?.first == "hn")  // in publication order
    }

    @Test func sharedGenericWordsAreNotEnough() {
        let items = background + [item("gap", "lobsters", "Defending the patch gap against automated attackers", hours: 2)]
        #expect(StoryClusters.find(items).isEmpty)
    }

    @Test func onlyDifferentFeedsAndCloseInTime() {
        let sameFeed = background + [item("a", "bbc", "Binance hit by $6.3bn hack", hours: 1),
                                     item("b", "bbc", "Binance hit by $6.3bn hack", hours: 2)]
        #expect(StoryClusters.find(sameFeed).isEmpty)
        let daysApart = background + [item("a", "bbc", "Binance hit by $6.3bn hack", hours: 1),
                                      item("b", "wired", "Binance hit by $6.3bn hack", hours: 80)]
        #expect(StoryClusters.find(daysApart).isEmpty)
        let close = background + [item("a", "bbc", "Binance hit by $6.3bn hack", hours: 1),
                                  item("b", "wired", "Binance's $6.3bn hacks explained", hours: 5)]
        #expect(StoryClusters.find(close).count == 1)  // possessive and plural still match
    }
}
