#if os(iOS)
import AVFoundation
import MediaPlayer

/// Background audio, interruptions and lock-screen controls for narration.
///
/// The audio session uses `.playback` with the `.spokenAudio` mode, which
/// tells iOS this is speech (podcasts and audiobooks pause for it, and it
/// pauses for navigation prompts). Requires `UIBackgroundModes: audio`.
@MainActor
public final class PlaybackSession {
    public struct Commands {
        public var play: @MainActor () -> Void
        public var pause: @MainActor () -> Void
        public var togglePlayPause: @MainActor () -> Void
        public var nextParagraph: @MainActor () -> Void
        public var previousParagraph: @MainActor () -> Void
        public var changeRate: @MainActor (Float) -> Void

        public init(play: @escaping @MainActor () -> Void, pause: @escaping @MainActor () -> Void,
                    togglePlayPause: @escaping @MainActor () -> Void, nextParagraph: @escaping @MainActor () -> Void,
                    previousParagraph: @escaping @MainActor () -> Void, changeRate: @escaping @MainActor (Float) -> Void) {
            self.play = play
            self.pause = pause
            self.togglePlayPause = togglePlayPause
            self.nextParagraph = nextParagraph
            self.previousParagraph = previousParagraph
            self.changeRate = changeRate
        }
    }

    /// Called when another app or a call interrupts us (`true`) or the
    /// interruption ends with the system suggesting we resume (`false`).
    public var onInterruption: ((_ began: Bool) -> Void)?
    /// Headphones unplugged or Bluetooth disconnected: pause, like Music does.
    public var onOutputLost: (() -> Void)?

    private var observers: [NSObjectProtocol] = []
    private var isActive = false

    public init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init)
            MainActor.assumeIsolated {
                switch type {
                case .began: self?.onInterruption?(true)
                case .ended: if options?.contains(.shouldResume) == true { self?.onInterruption?(false) }
                default: break
                }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
            MainActor.assumeIsolated {
                if reason == .oldDeviceUnavailable { self?.onOutputLost?() }
            }
        })
    }

    public func activate() throws {
        guard !isActive else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
        try session.setActive(true)
        isActive = true
    }

    public func deactivate() {
        guard isActive else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isActive = false
    }

    public func installCommands(_ commands: Commands) {
        let center = MPRemoteCommandCenter.shared()
        func bind(_ command: MPRemoteCommand, _ action: @escaping @MainActor () -> Void) {
            command.removeTarget(nil)
            command.isEnabled = true
            command.addTarget { _ in
                MainActor.assumeIsolated { action() }
                return .success
            }
        }
        bind(center.playCommand, commands.play)
        bind(center.pauseCommand, commands.pause)
        bind(center.togglePlayPauseCommand, commands.togglePlayPause)
        // Narration has no fixed timeline; next/previous track step paragraphs.
        bind(center.nextTrackCommand, commands.nextParagraph)
        bind(center.previousTrackCommand, commands.previousParagraph)
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
        center.changePlaybackPositionCommand.isEnabled = false

        let rate = center.changePlaybackRateCommand
        rate.removeTarget(nil)
        rate.supportedPlaybackRates = [0.75, 1, 1.25, 1.5, 2]
        rate.isEnabled = true
        let changeRate = commands.changeRate
        rate.addTarget { event in
            guard let event = event as? MPChangePlaybackRateCommandEvent else { return .commandFailed }
            let value = event.playbackRate
            MainActor.assumeIsolated { changeRate(value) }
            return .success
        }
    }

    /// Lock screen / Control Center metadata. Elapsed and duration are
    /// estimates from the script length and rate; they are only shown as a
    /// progress bar, never as exact times in Folio's own UI.
    public func updateNowPlaying(title: String, feed: String, elapsed: TimeInterval, duration: TimeInterval,
                                 rate: Double, isPlaying: Bool) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: feed,
            MPMediaItemPropertyAlbumTitle: "Paperwire",
            MPMediaItemPropertyPlaybackDuration: max(duration, 1),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: min(max(elapsed, 0), max(duration, 1)),
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? rate : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        info[MPNowPlayingInfoPropertyIsLiveStream] = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }

    public func clearNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }
}
#endif
