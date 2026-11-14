import Foundation

#if canImport(MediaPlayer)
import MediaPlayer
#endif

#if canImport(AVFoundation)
import AVFoundation
#endif

/// Coordinates lock-screen and Control Center Now Playing information and remote media controls.
@MainActor
public final class LIDNowPlayingCoordinator {

    public static let shared = LIDNowPlayingCoordinator()

    private var isConfigured = false

    public init() {}

    /// Configure remote command center targets.
    public func setupRemoteCommands(
        onPlay: @escaping @MainActor () -> Void,
        onPause: @escaping @MainActor () -> Void,
        onTogglePlayPause: @escaping @MainActor () -> Void,
        onSeekTo: @escaping @MainActor (Double) -> Void,
        onSkip: @escaping @MainActor (Double) -> Void
    ) {
        #if canImport(MediaPlayer)
        guard !isConfigured else { return }
        isConfigured = true

        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { _ in
            Task { @MainActor in onPlay() }
            return .success
        }

        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { _ in
            Task { @MainActor in onPause() }
            return .success
        }

        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { _ in
            Task { @MainActor in onTogglePlayPause() }
            return .success
        }

        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.addTarget { event in
            if let posEvent = event as? MPChangePlaybackPositionCommandEvent {
                Task { @MainActor in onSeekTo(posEvent.positionTime) }
                return .success
            }
            return .commandFailed
        }

        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.skipForwardCommand.preferredIntervals = [10.0]
        commandCenter.skipForwardCommand.addTarget { _ in
            Task { @MainActor in onSkip(10.0) }
            return .success
        }

        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.skipBackwardCommand.preferredIntervals = [10.0]
        commandCenter.skipBackwardCommand.addTarget { _ in
            Task { @MainActor in onSkip(-10.0) }
            return .success
        }
        #endif
    }

    /// Update lock screen now playing metadata.
    public func updateNowPlaying(
        title: String,
        duration: Double,
        currentTime: Double,
        playbackRate: Float
    ) {
        #if canImport(MediaPlayer)
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyPlaybackRate: Double(playbackRate)
        ]

        if duration.isFinite && !duration.isNaN && duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }

        if currentTime.isFinite && !currentTime.isNaN && currentTime >= 0 {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        #endif
    }

    /// Clear now playing info when player stops.
    public func clearNowPlaying() {
        #if canImport(MediaPlayer)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        #endif
    }
}
