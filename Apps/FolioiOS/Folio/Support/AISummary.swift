import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Article summaries from Apple Intelligence, on the iPhone itself: private,
/// free and offline. Only on iPhones and languages Apple supports; elsewhere
/// Folio keeps its own picked key points.
enum AISummary {
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    /// Three short points in the article's language, or nil.
    static func keyPoints(title: String, text: String) async -> [String]? {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *), isAvailable else { return nil }
        let session = LanguageModelSession(instructions: """
            You summarize news articles for a reader. Answer with exactly three short bullet points in the \
            article's own language, each one sentence, facts only, no introduction.
            """)
        let prompt = "Title: \(title)\n\n\(text.prefix(6000))"
        guard let response = try? await session.respond(to: prompt) else { return nil }
        let points = response.content.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-•*·0123456789. ").union(.whitespaces)) }
            .filter { $0.count > 12 }
        return points.isEmpty ? nil : Array(points.prefix(3))
        #else
        return nil
        #endif
    }
}
