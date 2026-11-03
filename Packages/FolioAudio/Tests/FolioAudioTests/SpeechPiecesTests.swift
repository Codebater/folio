import Testing
@testable import FolioAudio

@Suite("Supertonic pieces")
struct SpeechPiecesTests {
    @Test func shortTextIsOnePiece() {
        #expect(SpeechPieces.split("The ice drifted north. The ship went with it.")
                == [SpeechPieces.Piece(text: "The ice drifted north. The ship went with it.", joint: nil)])
        #expect(SpeechPieces.split("   ").isEmpty)
    }

    @Test func longSentencesSplitAtCommasThenWordsAndKeepTheirComma() {
        let sentence = "The research vessel drifted with the ice for 389 days, from September 2025 to October 2026, "
            + "measuring its thickness, its temperature and the life underneath it."
        let pieces = SpeechPieces.split(sentence)
        #expect(pieces.allSatisfy { $0.text.count <= SpeechPieces.maxLength })
        #expect(pieces.first == SpeechPieces.Piece(text: "The research vessel drifted with the ice for 389 days,", joint: .comma))
        #expect(pieces.last?.joint == nil)
        #expect(pieces.last?.text.hasSuffix("underneath it.") == true)
        // Nothing is lost: the pieces put back together are the sentence.
        #expect(pieces.map(\.text).joined(separator: " ") == sentence.trimmingCharacters(in: .whitespaces))

        let noCommas = "which suggests that the models used to predict summer melt may need to be adjusted soon enough."
        let words = SpeechPieces.split(noCommas)
        #expect(words.count == 2 && words[0].joint == .word && words.allSatisfy { $0.text.count <= 70 })
    }

    @Test func sentencesAreJoinedWithABreathAndSplitWhenTheyDoNotFit() {
        let text = "Scientists in Norway finished one of the longest records ever kept. "
            + "The early results surprised the team."
        let pieces = SpeechPieces.split(text)
        #expect(pieces.map(\.joint) == [.sentence, nil])
        #expect(SpeechPieces.sentences(in: "He said \"Stop.\" Then he left… Fine!") == ["He said \"Stop.\"", "Then he left…", "Fine!"])
    }

    @Test func joinTrimsEachPiecesPaddingAndAddsThePauseItsJointAsksFor() {
        let sampleRate = 10_000
        let padded = [Float](repeating: 0, count: 4_000) + [Float](repeating: 0.5, count: 1_000) + [Float](repeating: 0, count: 4_000)
        let silent = [Float](repeating: 0, count: 3_000)
        let joined = SpeechPieces.joined([padded, silent, padded], joints: [.comma, .word, nil], sampleRate: sampleRate)
        // 1,000 samples of speech + 20 ms (200) kept on each side, twice; one comma pause (0.10 s);
        // the silent piece and its pause are dropped.
        #expect(joined.count == 2 * 1_400 + 1_000)
        #expect(SpeechPieces.Joint.sentence.pause > SpeechPieces.Joint.comma.pause)
        #expect(SpeechPieces.Joint.comma.pause > SpeechPieces.Joint.word.pause)
    }
}
