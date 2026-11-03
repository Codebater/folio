import AVFoundation
import FolioAudio

/// Plays rendered segments through AVAudioEngine. A time-pitch unit changes
/// speed without changing the voice's pitch, so one cached file serves every
/// speed. The player's own sample clock gives the media time that word
/// highlights follow.
///
/// Room: neural clips end in digital silence, and the joins between them
/// sound cut off. A small room (reverb, a few percent wet) lets every word
/// ring out across the join, and a faint room tone fills the gaps, about
/// 68 dB under the voice. Each voice can also bring its studio tone (EQ).
@MainActor
public final class ClipOutput: SpeechAudioOutput {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let tone = AVAudioUnitEQ(numberOfBands: 3)
    private let reverb = AVAudioUnitReverb()
    private let roomTone = AVAudioPlayerNode()
    private var file: AVAudioFile?
    private var connectedFormat: AVAudioFormat?
    private var startFrame: AVAudioFramePosition = 0
    private var finished = false
    /// Bumped per clip, so a stopped clip's completion can't end the next one.
    private var clip = 0

    /// Reverb mix when the room is on: about -24 dB under the voice, the level
    /// chosen by ear against the big models (folio-notes, 2026-11-03).
    static let roomWetPercent: Float = 6
    /// Room tone level: neural clips are polished to about -20 dBFS speech,
    /// so -88 dBFS sits 68 dB under the voice.
    static let roomToneDBFS: Float = -88

    /// Room on or off (Listening style). Off plays the clips dry, as before.
    public var room = true {
        didSet { applyRoom() }
    }

    public init() {
        engine.attach(player)
        engine.attach(timePitch)
        engine.attach(tone)
        engine.attach(reverb)
        engine.attach(roomTone)
        reverb.loadFactoryPreset(.smallRoom)
        let bands = tone.bands
        bands[0].filterType = .lowShelf
        bands[0].frequency = 140
        bands[1].filterType = .parametric
        bands[1].frequency = 450
        bands[1].bandwidth = 1
        bands[2].filterType = .highShelf
        bands[2].frequency = 7_000
        setTone(nil)
        let toneFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        engine.connect(roomTone, to: engine.mainMixerNode, format: toneFormat)
        roomTone.volume = powf(10, Self.roomToneDBFS / 20)
        applyRoom()
    }

    /// The voice of the next clip: its tone, if it has one.
    public func prepare(voiceID: String) {
        setTone(NeuralVoiceCatalog.voice(voiceID)?.tone)
    }

    private func setTone(_ value: NeuralVoiceCatalog.Tone?) {
        let bands = tone.bands
        bands[0].gain = value?.lowDB ?? 0
        bands[1].gain = value?.midDB ?? 0
        bands[2].gain = value?.airDB ?? 0
        for band in bands { band.bypass = band.gain == 0 }
    }

    private func applyRoom() {
        reverb.wetDryMix = room ? Self.roomWetPercent : 0
        reverb.bypass = !room
        if !room { roomTone.stop() }
    }

    public func play(_ audio: URL, from seconds: Double, rate: Double) throws {
        stopClip()
        let file = try AVAudioFile(forReading: audio)
        let format = file.processingFormat
        if connectedFormat != format {
            // Kokoro renders at 24 kHz, Supertonic at 44.1 kHz.
            engine.disconnectNodeOutput(player)
            engine.disconnectNodeOutput(timePitch)
            engine.disconnectNodeOutput(tone)
            engine.disconnectNodeOutput(reverb)
            engine.connect(player, to: timePitch, format: format)
            engine.connect(timePitch, to: tone, format: format)
            engine.connect(tone, to: reverb, format: format)
            engine.connect(reverb, to: engine.mainMixerNode, format: format)
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
        startRoomTone()
    }

    public func pause() {
        player.pause()
        roomTone.pause()
    }

    public func resume() {
        if !engine.isRunning { try? engine.start() }
        player.play()
        startRoomTone()
    }

    /// Ends narration: the clip, and the room tone with it.
    public func stop() {
        stopClip()
        roomTone.stop()
    }

    /// Ends the current clip only. The reverb keeps ringing and the room tone
    /// keeps playing, so the next clip joins without a cut.
    private func stopClip() {
        clip += 1
        player.stop()
        file = nil
        finished = false
    }

    private func startRoomTone() {
        guard room, !roomTone.isPlaying, let buffer = Self.roomToneBuffer else { return }
        roomTone.scheduleBuffer(buffer, at: nil, options: .loops)
        roomTone.play()
    }

    /// Four seconds of soft noise, rolled off like a quiet room, unit RMS.
    /// Generated once; the player's volume sets its level.
    static let roomToneBuffer: AVAudioPCMBuffer? = {
        let sampleRate = 44_100.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleRate * 4)),
              let data = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = buffer.frameCapacity
        var generator = SystemRandomNumberGenerator()
        // Brown-ish noise: a leaky integrator of white noise, then a gentle
        // one-pole low-pass, so it sounds like a room and not like hiss.
        var walk: Float = 0, smooth: Float = 0, energy: Float = 0
        let count = Int(buffer.frameLength)
        for i in 0..<count {
            let white = Float.random(in: -1...1, using: &generator)
            walk = 0.98 * walk + 0.2 * white
            smooth += 0.3 * (walk - smooth)
            data[i] = smooth
            energy += smooth * smooth
        }
        let rms = (energy / Float(count)).squareRoot()
        // Crossfade the last 50 ms into the first and drop them, so the loop
        // runs on from where the tail left off and can't click.
        let fade = 2_205
        for i in 0..<fade {
            let w = Float(i) / Float(fade)
            data[i] = data[i] * w + data[count - fade + i] * (1 - w)
        }
        buffer.frameLength = AVAudioFrameCount(count - fade)
        for i in 0..<(count - fade) { data[i] /= max(rms, 1e-6) }
        return buffer
    }()

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
