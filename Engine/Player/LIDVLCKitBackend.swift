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
    public var activeSessionId: String = "IDLE"

    public var videoTrackCount: Int {
        player.videoTracks.count
    }

    public var hasAttachedDrawable: Bool {
        #if canImport(UIKit)
        return currentRenderingView != nil && player.drawable != nil
        #else
        return true
        #endif
    }

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

    public var supportsPictureInPicture: Bool {
        // VLCKit on iOS renders to a drawable UIView and does not use AVPictureInPictureController
        return false
    }

    public func setAspectRatio(_ ratio: LIDAspectRatio) {
        #if canImport(VLCKit)
        switch ratio {
        case .original:
            player.videoAspectRatio = nil
            player.videoFitMode = .smaller
        case .fit16x9:
            player.videoAspectRatio = "16:9"
            player.videoFitMode = .smaller
        case .fit4x3:
            player.videoAspectRatio = "4:3"
            player.videoFitMode = .smaller
        case .fill:
            player.videoAspectRatio = nil
            player.videoFitMode = .larger
        case .stretch:
            player.videoAspectRatio = nil
            player.videoFitMode = .width
        }
        #endif
    }

    private let player: VLCMediaPlayer
    private var currentLoadedSource: LIDPlayerSource?
    private weak var currentRenderingView: UIView?
    private var pendingResumePositionSeconds: Double? = nil

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

        guard let media = VLCMedia(url: targetURL) else {
            let error = "Failed to create VLCMedia for \(targetURL.lastPathComponent)"
            self.playbackState = .failed(error: error)
            delegate?.engineDidFail(self, error: error)
            return
        }

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
            if (self.player.drawable as? UIView) !== view {
                self.player.drawable = view
            }
            PipelineLogger.shared.logPlayer(
                session: activeSessionId,
                category: "VideoRenderer",
                message: "VLCKit drawable verified in load() with view [\(Unmanaged.passUnretained(view).toOpaque())]"
            )
        }
        #endif

        if autoPlay {
            self.play()
        }
    }

    public func play() {
        guard currentLoadedSource != nil else { return }
        #if canImport(UIKit)
        if let view = currentRenderingView, self.player.drawable == nil {
            self.player.drawable = view
            PipelineLogger.shared.logPlayer(
                session: activeSessionId,
                category: "VideoRenderer",
                message: "VLCKit drawable re-attached before play() with view [\(Unmanaged.passUnretained(view).toOpaque())]"
            )
        }
        #endif
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
        let tracks = player.audioTracks
        return tracks.enumerated().map { (index, track) in
            LIDAudioTrack(
                id: track.trackId,
                displayName: track.trackName.isEmpty ? "Audio Track \(index + 1)" : track.trackName,
                languageCode: track.language,
                isDefault: track.isSelected
            )
        }
    }

    public func selectAudioTrack(id: String) {
        let tracks = player.audioTracks
        for track in tracks {
            if track.trackId == id {
                track.isSelectedExclusively = true
                break
            }
        }
    }

    public func getSubtitleTracks() -> [LIDSubtitleTrack] {
        var result: [LIDSubtitleTrack] = [.off]
        let tracks = player.textTracks
        for (index, track) in tracks.enumerated() {
            result.append(
                LIDSubtitleTrack(
                    id: track.trackId,
                    displayName: track.trackName.isEmpty ? "Subtitle \(index + 1)" : track.trackName,
                    languageCode: track.language,
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
        let tracks = player.textTracks
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

    public func addExternalSubtitle(url: URL) {
        #if canImport(VLCKit)
        let slave = VLCMediaSlave(url: url, type: .subtitle, priority: 1)
        player.media?.addSlave(slave)
        #endif
    }

    // MARK: - Rendering Presentation

    #if canImport(UIKit)
    public func attachRenderingView(_ view: UIView) {
        if self.currentRenderingView === view && self.player.drawable != nil {
            return
        }
        self.currentRenderingView = view
        self.player.drawable = view
        PipelineLogger.shared.logPlayer(
            session: activeSessionId,
            category: "VideoRenderer",
            message: "VLCKit drawable attached to view [\(Unmanaged.passUnretained(view).toOpaque())]"
        )
    }

    public func detachRenderingView() {
        PipelineLogger.shared.logPlayer(
            session: activeSessionId,
            category: "VideoRenderer",
            message: "VLCKit drawable detached"
        )
        self.currentRenderingView = nil
        self.player.drawable = nil
    }
    #endif

    // MARK: - VLCMediaPlayerDelegate Callbacks

    nonisolated public func mediaPlayerStateChanged(_ newState: VLCMediaPlayerState) {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            PipelineLogger.shared.logPlayer(
                session: self.activeSessionId,
                category: "PlayerBackend",
                message: "VLCKit state changed -> \(newState.rawValue)"
            )
            switch newState {
            case .opening:
                self.playbackState = .loading
            case .playing:
                self.playbackState = .playing
                #if canImport(UIKit)
                if self.player.drawable == nil, let view = self.currentRenderingView {
                    self.player.drawable = view
                    PipelineLogger.shared.logPlayer(
                        session: self.activeSessionId,
                        category: "VideoRenderer",
                        message: "VLCKit drawable restored on state .playing with view [\(Unmanaged.passUnretained(view).toOpaque())]"
                    )
                }
                #endif
                let vTracks = self.player.videoTracks.count
                let vSize = self.player.videoSize
                PipelineLogger.shared.logPlayer(
                    session: self.activeSessionId,
                    category: "VideoRenderer",
                    message: "VLCKit rendering active: videoTracks=\(vTracks), size=\(Int(vSize.width))x\(Int(vSize.height)), drawableAttached=\(self.hasAttachedDrawable)"
                )
                if vTracks <= 0 {
                    PipelineLogger.shared.logPlayer(
                        session: self.activeSessionId,
                        category: "VideoRenderer",
                        message: "Notice: VLCKit playing before video track metadata was parsed; scheduling delayed track check..."
                    )
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        guard let self = self, self.playbackState.isPlaying else { return }
                        let delayedVTracks = self.player.videoTracks.count
                        let delayedVSize = self.player.videoSize
                        PipelineLogger.shared.logPlayer(
                            session: self.activeSessionId,
                            category: "VideoRenderer",
                            message: "VLCKit delayed track check (+500ms): videoTracks=\(delayedVTracks), size=\(Int(delayedVSize.width))x\(Int(delayedVSize.height)), drawableAttached=\(self.hasAttachedDrawable)"
                        )
                    }
                }
                if let resume = self.pendingResumePositionSeconds, resume > 0 {
                    self.pendingResumePositionSeconds = nil
                    self.seek(to: resume)
                }
            case .paused:
                self.playbackState = .paused
            case .stopped, .stopping:
                self.playbackState = .ended
            case .error:
                let error = "libVLC reported playback error"
                self.playbackState = .failed(error: error)
                PipelineLogger.shared.logPlayer(
                    session: self.activeSessionId,
                    category: "PlayerError",
                    message: "libVLC reported playback error: \(error)"
                )
                self.delegate?.engineDidFail(self, error: error)
            case .nothingSpecial:
                break
            @unknown default:
                break
            }
            self.delegate?.engineDidUpdateState(self, state: self.playbackState)
        }
    }

    nonisolated public func mediaPlayerTimeChanged(_ aNotification: Notification) {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            if let time = self.player.time.value?.doubleValue {
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
            if progress < 1.0 && self.playbackState != .playing {
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
    public var activeSessionId: String = "IDLE"
    public var videoTrackCount: Int { 1 }
    public var hasAttachedDrawable: Bool { true }

    public private(set) var playbackState: LIDPlaybackState = .idle
    public private(set) var currentPositionSeconds: Double = 0.0
    public private(set) var durationSeconds: Double = 0.0
    public private(set) var bufferedDurationSeconds: Double = 0.0
    public var playbackSpeed: LIDPlaybackSpeed = .speed1_00
    public var volume: Float = 1.0
    public var isMuted: Bool = false
    public var supportsPictureInPicture: Bool { false }
    public func setAspectRatio(_ ratio: LIDAspectRatio) {}

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
    public func addExternalSubtitle(url: URL) {}

    #if canImport(UIKit)
    public func attachRenderingView(_ view: UIView) {}
    public func detachRenderingView() {}
    #endif
}

#endif
