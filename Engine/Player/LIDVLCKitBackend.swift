import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(Combine)
import Combine
#endif

#if canImport(VLCKit)
import VLCKit

/// Concrete VLCKit (libVLC 4.x) playback backend implementing `LIDMediaEngineProtocol`.
/// Delivers universal container and codec demuxing (MPEG-TS, MKV, AVI, WebM, FLV, WMV, etc.)
/// without reliance on Apple AVFoundation container limitations.
@MainActor
public final class LIDVLCKitBackend: NSObject, LIDMediaEngineProtocol, VLCMediaPlayerDelegate {

    public let backendType: LIDMediaEngineBackendType = .vlcKit
    public weak var delegate: LIDMediaEngineDelegate?

    public private(set) var playbackState: LIDPlaybackState = .idle
    public private(set) var currentPositionSeconds: Double = 0.0
    public private(set) var durationSeconds: Double = 0.0
    public private(set) var bufferedDurationSeconds: Double = 0.0

    public var playbackSpeed: LIDPlaybackSpeed = .speed1_00 {
        didSet {
            player.rate = playbackSpeed.rate
        }
    }

    public var volume: Float {
        get {
            guard let audio = player.audio else { return 1.0 }
            return Float(audio.volume) / 100.0
        }
        set {
            let clamped = max(0.0, min(1.0, newValue))
            player.audio?.volume = Int32(clamped * 100.0)
        }
    }

    public var isMuted: Bool {
        get {
            player.audio?.isMuted ?? false
        }
        set {
            player.audio?.isMuted = newValue
        }
    }

    private let player: VLCMediaPlayer
    private var currentLoadedSource: LIDPlayerSource?
    private weak var currentRenderingView: UIView?

    public override init() {
        self.player = VLCMediaPlayer()
        super.init()
        self.player.delegate = self
    }

    // MARK: - Playback Control APIs

    public func load(source: LIDPlayerSource, autoPlay: Bool) {
        stop()
        self.currentLoadedSource = source
        self.playbackState = .loading
        delegate?.engineDidUpdateState(self, state: self.playbackState)

        guard let targetURL = source.url else {
            let error = "Media source provides no valid URL"
            self.playbackState = .failed(error: error)
            delegate?.engineDidFail(self, error: error)
            return
        }

        let media = VLCMedia(url: targetURL)
        // Inject request headers if present
        if let reqContext = source.requestContext {
            if let ua = reqContext.userAgent {
                media.addOptions(["--http-user-agent": ua])
            }
            if let ref = reqContext.referer {
                media.addOptions(["--http-referrer": ref])
            }
        }

        self.player.media = media

        #if canImport(UIKit)
        if let view = currentRenderingView {
            self.player.drawable = view
        }
        #endif

        if autoPlay {
            self.play()
        }
    }

    public func play() {
        guard currentLoadedSource != nil else { return }
        player.play()
        self.playbackState = .playing
        delegate?.engineDidUpdateState(self, state: self.playbackState)
    }

    public func pause() {
        guard currentLoadedSource != nil else { return }
        player.pause()
        self.playbackState = .paused
        delegate?.engineDidUpdateState(self, state: self.playbackState)
    }

    public func stop() {
        player.stop()
        self.currentLoadedSource = nil
        self.currentPositionSeconds = 0.0
        self.durationSeconds = 0.0
        self.bufferedDurationSeconds = 0.0
        self.playbackState = .idle
        delegate?.engineDidUpdateState(self, state: .idle)
    }

    public func seek(to seconds: Double) {
        guard durationSeconds > 0 else {
            player.position = 0.0
            return
        }
        let normalizedPos = max(0.0, min(1.0, seconds / durationSeconds))
        player.position = normalizedPos
        self.currentPositionSeconds = seconds
        delegate?.engineDidUpdateTime(self, currentSeconds: seconds, durationSeconds: durationSeconds)
    }

    // MARK: - Track Management

    public func getAudioTracks() -> [LIDAudioTrack] {
        guard let tracks = player.audioTracks else { return [] }
        return tracks.enumerated().map { (index, track) in
            LIDAudioTrack(
                id: track.trackId,
                displayName: track.trackName.isEmpty ? "Audio Track \(index + 1)" : track.trackName,
                languageCode: nil,
                isDefault: track.isSelected
            )
        }
    }

    public func selectAudioTrack(id: String) {
        guard let tracks = player.audioTracks else { return }
        for track in tracks {
            if track.trackId == id {
                track.isSelectedExclusively = true
                break
            }
        }
    }

    public func getSubtitleTracks() -> [LIDSubtitleTrack] {
        var result: [LIDSubtitleTrack] = [.off]
        guard let tracks = player.textTracks else { return result }
        for (index, track) in tracks.enumerated() {
            result.append(
                LIDSubtitleTrack(
                    id: track.trackId,
                    displayName: track.trackName.isEmpty ? "Subtitle \(index + 1)" : track.trackName,
                    languageCode: nil,
                    isExternal: false
                )
            )
        }
        return result
    }

    public func selectSubtitleTrack(id: String) {
        if id == "off" || id == LIDSubtitleTrack.off.id {
            player.deselectAllTextTracks()
            return
        }
        guard let tracks = player.textTracks else { return }
        for track in tracks {
            if track.trackId == id {
                player.selectTextTracks([track])
                break
            }
        }
    }

    public func setSubtitleDelay(seconds: Double) {
        // VLCKit delay is expressed in microseconds
        let microSeconds = Int(seconds * 1_000_000)
        player.currentVideoSubTitleDelay = microSeconds
    }

    // MARK: - Rendering Presentation

    #if canImport(UIKit)
    public func attachRenderingView(_ view: UIView) {
        self.currentRenderingView = view
        self.player.drawable = view
    }

    public func detachRenderingView() {
        self.currentRenderingView = nil
        self.player.drawable = nil
    }
    #endif

    // MARK: - VLCMediaPlayerDelegate Callbacks

    nonisolated public func mediaPlayerStateChanged(_ aNotification: Notification) {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            switch self.player.state {
            case .opening:
                self.playbackState = .loading
            case .buffering:
                self.playbackState = .buffering(progress: 0.5)
            case .playing:
                self.playbackState = .playing
            case .paused:
                self.playbackState = .paused
            case .stopped:
                self.playbackState = .ended
            case .error:
                let error = "libVLC reported playback error"
                self.playbackState = .failed(error: error)
                self.delegate?.engineDidFail(self, error: error)
            @unknown default:
                break
            }
            self.delegate?.engineDidUpdateState(self, state: self.playbackState)
        }
    }

    nonisolated public func mediaPlayerTimeChanged(_ aNotification: Notification) {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            if let time = self.player.time?.value?.doubleValue {
                self.currentPositionSeconds = time / 1000.0
                self.delegate?.engineDidUpdateTime(self, currentSeconds: self.currentPositionSeconds, durationSeconds: self.durationSeconds)
            }
        }
    }

    nonisolated public func mediaPlayerLengthChanged(_ length: Int64) {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.durationSeconds = Double(length) / 1000.0
            self.delegate?.engineDidUpdateTime(self, currentSeconds: self.currentPositionSeconds, durationSeconds: self.durationSeconds)
        }
    }

    nonisolated public func mediaPlayerBufferingChanged(_ progress: Float) {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.bufferedDurationSeconds = self.durationSeconds * Double(progress)
            self.delegate?.engineDidUpdateBuffering(self, bufferedSeconds: self.bufferedDurationSeconds)
            if self.player.state == .buffering {
                self.playbackState = .buffering(progress: Double(progress))
                self.delegate?.engineDidUpdateState(self, state: self.playbackState)
            }
        }
    }
}

#else

/// Stub implementation of `LIDVLCKitBackend` active when `VLCKit` framework is not linked.
/// Ensures compilation and test execution on macOS, Linux, and development environments
/// while preserving the exact `LIDMediaEngineProtocol` contract.
@MainActor
public final class LIDVLCKitBackend: NSObject, LIDMediaEngineProtocol {

    public let backendType: LIDMediaEngineBackendType = .vlcKit
    public weak var delegate: LIDMediaEngineDelegate?

    public private(set) var playbackState: LIDPlaybackState = .idle
    public private(set) var currentPositionSeconds: Double = 0.0
    public private(set) var durationSeconds: Double = 0.0
    public private(set) var bufferedDurationSeconds: Double = 0.0
    public var playbackSpeed: LIDPlaybackSpeed = .speed1_00
    public var volume: Float = 1.0
    public var isMuted: Bool = false

    private var currentLoadedSource: LIDPlayerSource?

    public override init() {
        super.init()
    }

    public func load(source: LIDPlayerSource, autoPlay: Bool) {
        self.currentLoadedSource = source
        self.playbackState = .loading
        delegate?.engineDidUpdateState(self, state: self.playbackState)
        if autoPlay {
            self.play()
        }
    }

    public func play() {
        guard currentLoadedSource != nil else { return }
        self.playbackState = .playing
        delegate?.engineDidUpdateState(self, state: self.playbackState)
    }

    public func pause() {
        guard currentLoadedSource != nil else { return }
        self.playbackState = .paused
        delegate?.engineDidUpdateState(self, state: self.playbackState)
    }

    public func stop() {
        self.currentLoadedSource = nil
        self.playbackState = .idle
        delegate?.engineDidUpdateState(self, state: .idle)
    }

    public func seek(to seconds: Double) {
        self.currentPositionSeconds = seconds
        delegate?.engineDidUpdateTime(self, currentSeconds: seconds, durationSeconds: durationSeconds)
    }

    public func getAudioTracks() -> [LIDAudioTrack] { [] }
    public func selectAudioTrack(id: String) {}
    public func getSubtitleTracks() -> [LIDSubtitleTrack] { [.off] }
    public func selectSubtitleTrack(id: String) {}
    public func setSubtitleDelay(seconds: Double) {}

    #if canImport(UIKit)
    public func attachRenderingView(_ view: UIView) {}
    public func detachRenderingView() {}
    #endif
}

#endif
