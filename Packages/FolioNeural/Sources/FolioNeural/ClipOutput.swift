import AVFoundation
import FolioAudio

/// Plays rendered segments through AVAudioEngine. A time-pitch unit changes
/// speed without changing the voice's pitch, so one cached file serves every
/// speed. The player's own sample clock gives the media time that word
/// highlights follow.
@MainActor
public final class ClipOutput: SpeechAudioOutput {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private var file: AVAudioFile?
    private var connectedFormat: AVAudioFormat?
    private var startFrame: AVAudioFramePosition = 0
    private var finished = false
    /// Bumped per clip, so a stopped clip's completion can't end the next one.
    private var clip = 0

    public init() {
        engine.attach(player)
        engine.attach(timePitch)
    }

    public func play(_ audio: URL, from seconds: Double, rate: Double) throws {
        stop()
        let file = try AVAudioFile(forReading: audio)
        let format = file.processingFormat
        if connectedFormat != format {
            // Kokoro renders at 24 kHz, Supertonic at 44.1 kHz.
            engine.disconnectNodeOutput(player)
            engine.disconnectNodeOutput(timePitch)
            engine.connect(player, to: timePitch, format: format)
            engine.connect(timePitch, to: engine.mainMixerNode, format: format)
            connectedFormat = format
        }
        timePitch.rate = Float(rate)
        let start = min(AVAudioFramePosition(max(0, seconds) * format.sampleRate), file.length)
        self.file = file
        startFrame = start
        finished = false
        clip += 1
        let current = clip
        let frames = AVAudioFrameCount(file.length - start)
        guard frames > 0 else {
            finished = true
            return
        }
        if !engine.isRunning { try engine.start() }
        player.scheduleSegment(file, startingFrame: start, frameCount: frames, at: nil,
                               completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.clip == current else { return }
                self.finished = true
            }
        }
        player.play()
    }

    public func pause() {
        player.pause()
    }

    public func resume() {
        if !engine.isRunning { try? engine.start() }
        player.play()
    }

    public func stop() {
        clip += 1
        player.stop()
        file = nil
        finished = false
    }

    public func setRate(_ rate: Double) {
        timePitch.rate = Float(rate)
    }

    public var currentTime: Double? {
        guard let file else { return nil }
        let sampleRate = file.processingFormat.sampleRate
        if finished { return Double(file.length) / sampleRate }
        guard let nodeTime = player.lastRenderTime, let playerTime = player.playerTime(forNodeTime: nodeTime) else {
            return Double(startFrame) / sampleRate
        }
        return Double(startFrame + max(playerTime.sampleTime, 0)) / sampleRate
    }

    public var isFinished: Bool { file != nil && finished }
}
