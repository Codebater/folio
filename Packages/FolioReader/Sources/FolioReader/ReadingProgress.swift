import Foundation
import FolioCore

/// Converts between an exact position (block + UTF-16 offset) and a 0...1
/// progress value, weighting blocks by how much there is to read.
///
/// The web view reports the block at the top of the screen; storage keeps
/// both forms so a position survives the article's content being updated.
public struct ProgressMap: Sendable {
    /// Images count as this many characters so a photo essay still shows
    /// progress as you scroll past pictures.
    public static let imageWeight = 240

    private let ids: [String]
    private let starts: [Int]
    private let weights: [Int]
    public let total: Int

    public init(document: ArticleDocument) {
        var ids: [String] = []
        var starts: [Int] = []
        var weights: [Int] = []
        var running = 0
        for block in document.blocks {
            let weight: Int
            switch block.kind {
            case .image: weight = Self.imageWeight
            case .rule: weight = 0
            case .embed: weight = 40
            default: weight = block.text.utf16Length
            }
            ids.append(block.id)
            starts.append(running)
            weights.append(weight)
            running += weight
        }
        self.ids = ids
        self.starts = starts
        self.weights = weights
        total = running
    }

    public func progress(blockID: String, offset: Int = 0) -> Double {
        guard total > 0, let index = ids.firstIndex(of: blockID) else { return 0 }
        let within = min(max(offset, 0), weights[index])
        return min(1, Double(starts[index] + within) / Double(total))
    }

    /// The block and offset at `progress`. Lands on the block that contains
    /// that point; offsets inside images and rules are 0.
    public func position(at progress: Double) -> (blockID: String, offset: Int)? {
        guard !ids.isEmpty else { return nil }
        guard total > 0 else { return (ids[0], 0) }
        let target = Int((min(max(progress, 0), 1) * Double(total)).rounded(.down))
        var low = 0
        var high = ids.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= target { low = mid } else { high = mid - 1 }
        }
        // Skip zero-weight blocks that share a start with the next block.
        var index = low
        while index < ids.count - 1, weights[index] == 0 { index += 1 }
        return (ids[index], min(target - starts[index], max(0, weights[index] - 1)))
    }

    /// Restores a saved position: the exact block if it still exists,
    /// otherwise the stored progress fraction.
    public func resolve(_ position: ReadingPosition) -> (blockID: String, offset: Int)? {
        if let blockID = position.blockID, ids.contains(blockID) { return (blockID, position.offset) }
        return self.position(at: position.progress)
    }
}
