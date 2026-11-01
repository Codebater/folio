import Foundation
import FolioCore
import FolioReader

/// The few sentences that carry an article, picked on the device: a "Key
/// points" box at the top of long articles, and what the Headlines station
/// reads for each story.
///
/// News is written lead first, so early sentences get a head start; on top
/// of that a sentence scores for words the article keeps coming back to and
/// for words it shares with the title. Picture credits, bylines, sign-up
/// prompts and fragments never qualify. The chosen sentences keep their
/// order in the article.
public enum KeyPoints {
    public static func sentences(document: ArticleDocument, title: String?, language: LanguageCode?, count: Int = 3,
                                 segmenter: SentenceSegmenting = RuleBasedSentenceSegmenter()) -> [String] {
        var candidates: [(text: String, position: Int, paragraph: Int)] = []
        var paragraphIndex = 0
        for block in document.blocks {
            guard case .paragraph = block.kind else { continue }
            defer { paragraphIndex += 1 }
            guard paragraphIndex < 30 else { break }
            for range in segmenter.sentences(in: block.text, language: language) {
                let sentence = String(block.text.utf16Slice(range)).trimmingCharacters(in: .whitespacesAndNewlines)
                guard isWorthReading(sentence) else { continue }
                candidates.append((sentence, candidates.count, paragraphIndex))
            }
        }
        guard candidates.count > count else { return candidates.map(\.text) }

        let tokenized = candidates.map { StoryClusters.keyTokens($0.text) }
        var frequency: [String: Int] = [:]
        for tokens in tokenized { for token in Set(tokens) { frequency[token, default: 0] += 1 } }
        let titleTokens = Set(StoryClusters.keyTokens(title ?? ""))

        let scored = candidates.indices.map { index -> (Int, Double) in
            let tokens = tokenized[index]
            let centrality = tokens.reduce(0.0) { $0 + Double(frequency[$1, default: 1] - 1) } / max(1, sqrt(Double(tokens.count)))
            let titleOverlap = Double(Set(tokens).intersection(titleTokens).count) * 1.5
            let lead = 3.0 / (1 + Double(candidates[index].position) * 0.35) + (candidates[index].paragraph == 0 ? 1 : 0)
            return (index, centrality + titleOverlap + lead)
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(count).map(\.0).sorted().map { candidates[$0].text }
    }

    /// Two sentences, for reading one story as a headline.
    public static func headline(document: ArticleDocument, title: String?, language: LanguageCode?) -> String {
        sentences(document: document, title: title, language: language, count: 2).joined(separator: " ")
    }

    static let noise = [
        "image source", "image caption", "credit:", "photo:", "photograph:", "read more", "subscribe", "sign up",
        "advertisement", "follow us", "click here", "newsletter", "all rights reserved", "getty images", "share this",
        "related:", "watch:", "listen:", "copyright",
    ]

    static func isWorthReading(_ sentence: String) -> Bool {
        let words = sentence.split(whereSeparator: \.isWhitespace)
        guard (6...48).contains(words.count), sentence.last != ":" else { return false }
        let lower = sentence.lowercased()
        if noise.contains(where: lower.hasPrefix) || lower.contains("©") { return false }
        if lower.hasPrefix("by "), words.count < 10 { return false }  // a byline
        let letters = sentence.filter(\.isLetter)
        return !letters.isEmpty && Double(letters.filter(\.isUppercase).count) / Double(letters.count) < 0.6
    }
}
