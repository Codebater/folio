import Foundation

/// Supertonic on the iPhone reads at most 70 characters per call (FluidAudio's
/// cap for its fixed 128-token Core ML window) and pads every call with about
/// 0.4 s of silence at both ends. Left to FluidAudio, a long sentence is split
/// and two paddings meet as a near-second pause in the middle of the sentence.
/// Paperwire splits the text the same way itself, trims each piece and joins
/// the pieces with the pause the text asks for.
public enum SpeechPieces {
    /// How the text goes on after a piece.
    public enum Joint: String, Sendable, Equatable {
        case sentence, comma, word

        /// Silence between two pieces, in seconds: a short breath after a
        /// sentence, less at a comma, almost none inside a phrase.
        public var pause: Double {
            switch self {
            case .sentence: 0.18
            case .comma: 0.10
            case .word: 0.03
            }
        }
    }

    public struct Piece: Sendable, Equatable {
        public var text: String
        /// nil for the last piece.
        public var joint: Joint?

        public init(text: String, joint: Joint?) {
            self.text = text
            self.joint = joint
        }
    }

    /// FluidAudio's `Supertonic3Constants.maxChunkLengthLatin` (0.18.0).
    public static let maxLength = 70

    /// Pieces of at most `maxLength` characters: whole sentences where they
    /// fit, else comma parts, else words (FluidAudio's order). A piece cut at a
    /// comma keeps its comma, so the voice doesn't close the phrase.
    public static func split(_ text: String, maxLength: Int = maxLength) -> [Piece] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard trimmed.count > maxLength else { return [Piece(text: trimmed, joint: nil)] }
        var pieces: [Piece] = []
        var current = ""
        var currentJoint: Joint?
        for atom in atoms(trimmed, maxLength: maxLength) {
            guard !current.isEmpty else {
                current = atom.text
                currentJoint = atom.next
                continue
            }
            let separator = currentJoint == .comma ? ", " : " "
            if current.count + separator.count + atom.text.count <= maxLength {
                current += separator + atom.text
            } else {
                pieces.append(Piece(text: currentJoint == .comma ? current + "," : current, joint: currentJoint))
                current = atom.text
            }
            currentJoint = atom.next
        }
        pieces.append(Piece(text: current, joint: nil))
        return pieces
    }

    /// The smallest units to pack, each with the joint to the next one.
    private static func atoms(_ text: String, maxLength: Int) -> [(text: String, next: Joint?)] {
        let sentences = sentences(in: text)
        var atoms: [(text: String, next: Joint?)] = []
        for (i, sentence) in sentences.enumerated() {
            let afterSentence: Joint? = i < sentences.count - 1 ? .sentence : nil
            guard sentence.count > maxLength else {
                atoms.append((sentence, afterSentence))
                continue
            }
            let parts = sentence.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            for (j, part) in parts.enumerated() {
                let afterPart: Joint? = j < parts.count - 1 ? .comma : afterSentence
                guard part.count > maxLength else {
                    atoms.append((part, afterPart))
                    continue
                }
                let words = part.split(separator: " ").map(String.init)
                for (k, word) in words.enumerated() {
                    atoms.append((word, k < words.count - 1 ? .word : afterPart))
                }
            }
        }
        return atoms
    }

    /// Splits after ., !, ? or … followed by whitespace (closing quotes stay with their sentence).
    static func sentences(in text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var ended = false
        for character in text {
            if character.isWhitespace, ended {
                if !current.isEmpty { result.append(current) }
                current = ""
                ended = false
                continue
            }
            if current.isEmpty, character.isWhitespace { continue }
            current.append(character)
            if ".!?…".contains(character) {
                ended = true
            } else if !"\"'”’»)]".contains(character) {
                ended = false
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// Joins rendered pieces: each one's padding trimmed to 20 ms, faded over
    /// 5 ms, then the pause its joint asks for. Silent pieces are dropped.
    public static func joined(_ audio: [[Float]], joints: [Joint?], sampleRate: Int) -> [Float] {
        var out: [Float] = []
        for (i, samples) in audio.enumerated() {
            guard samples.contains(where: { abs($0) > AudioPolish.trimThreshold }) else { continue }
            let piece = AudioPolish.trimmed(samples, sampleRate: sampleRate, keep: 0.02).samples
            out += AudioPolish.faded(piece, sampleRate: sampleRate, milliseconds: 5)
            if i < audio.count - 1, i < joints.count, let joint = joints[i] {
                out += [Float](repeating: 0, count: Int(joint.pause * Double(sampleRate)))
            }
        }
        return out
    }
}
