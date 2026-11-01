import Foundation

/// Evens out rendered narration: every engine and voice at one loudness, and
/// the model's own silence at the ends trimmed, so Folio's pauses between
/// segments are the only pauses. Without it a switch from one voice to
/// another jumps in volume, and some models leave half a second of air.
public enum AudioPolish {
    /// Speech level, about −20 dBFS RMS: audiobook narration sits between
    /// −23 and −18 dB (ACX).
    public static let targetRMS: Float = 0.1
    /// Peaks stay below about −1 dBFS.
    public static let peakLimit: Float = 0.89
    /// Frames quieter than this (about −45 dBFS) are pauses, not speech.
    public static let speechThreshold: Float = 0.005
    /// Samples quieter than this (about −40 dBFS) at the ends are trimmed.
    public static let trimThreshold: Float = 0.01

    /// Scales speech to the target level, measured over the frames that
    /// hold speech (pauses would make it too loud), never letting peaks clip.
    public static func normalized(_ samples: [Float], sampleRate: Int) -> [Float] {
        let frame = max(1, sampleRate / 50)  // 20 ms
        var energy: Float = 0
        var counted = 0
        var peak: Float = 0
        var start = 0
        while start < samples.count {
            let end = min(start + frame, samples.count)
            var sum: Float = 0
            for i in start..<end {
                sum += samples[i] * samples[i]
                peak = max(peak, abs(samples[i]))
            }
            if (sum / Float(end - start)).squareRoot() > speechThreshold {
                energy += sum
                counted += end - start
            }
            start = end
        }
        guard counted > 0, peak > 0 else { return samples }
        let rms = (energy / Float(counted)).squareRoot()
        let gain = min(targetRMS / rms, peakLimit / peak)
        guard abs(gain - 1) > 0.01 else { return samples }
        return samples.map { $0 * gain }
    }

    /// Trims leading and trailing silence down to `keep` seconds. Returns the
    /// samples and the seconds removed from the start, which word timings
    /// move back by.
    public static func trimmed(_ samples: [Float], sampleRate: Int, keep: Double = 0.04) -> (samples: [Float], removedFromStart: Double) {
        guard let first = samples.firstIndex(where: { abs($0) > trimThreshold }),
              let last = samples.lastIndex(where: { abs($0) > trimThreshold })
        else { return (samples, 0) }
        let margin = Int(keep * Double(sampleRate))
        let lower = max(0, first - margin)
        let upper = min(samples.count, last + 1 + margin)
        return (Array(samples[lower..<upper]), Double(lower) / Double(sampleRate))
    }

    /// Short fades at both ends, so a clip never starts or stops on a
    /// non-zero sample (an audible click). 6 ms is far below what the ear
    /// hears as a fade.
    public static func faded(_ samples: [Float], sampleRate: Int, milliseconds: Double = 6) -> [Float] {
        let length = min(samples.count / 2, Int(Double(sampleRate) * milliseconds / 1000))
        guard length > 1 else { return samples }
        var out = samples
        for i in 0..<length {
            let gain = Float(i) / Float(length)
            out[i] *= gain
            out[out.count - 1 - i] *= gain
        }
        return out
    }

    /// Word timings after `trimmed`: moved back and kept inside the audio.
    public static func moved(_ words: [TimedWord], back seconds: Double, duration: Double) -> [TimedWord] {
        words.map { word in
            let start = min(max(0, word.start - seconds), duration)
            return TimedWord(range: word.range, start: start, end: min(max(start, word.end - seconds), duration))
        }
    }
}
