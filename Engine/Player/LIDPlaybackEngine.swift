import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(Combine)
import Combine
#endif

/// Unified media playback controller coordinating multi-backend decoding and playback.
/// Automatically routes local files and universal containers (MPEG-TS, MKV, AVI, WebM, etc.)
/// to `LIDVLCKitBackend` (libVLC), while routing native HLS manifests and swarm streams
/// to `LIDAVFoundationBackend`.
@MainActor
public final class LIDPlaybackEngine: NSObject, ObservableObject, LIDMediaEngineDelegate {

    public static let shared = LIDPlaybackEngine()

    @Published public private(set) var activeBackendType: LIDMediaEngineBackendType = .vlcKit
    @Published public private(set) var playbackState: LIDPlaybackState = .idle
    @Published public private(set) var currentPositionSeconds: Double = 0.0
    @Published public private(set) var durationSeconds: Double = 0.0
    @Published public private(set) var bufferedDurationSeconds: Double = 0.0
    @Published public private(set) var playbackSpeed: LIDPlaybackSpeed = .speed1_00
    @Published public private(set) var metadata: LIDMediaMetadata = .empty
    @Published public private(set) var volume: Float = 1.0
    @Published public private(set) var isMuted: Bool = false
    @Published public private(set) var currentSource: LIDPlayerSource? = nil
    @Published public private(set) var streamContext: LIDStreamContextInfo = .empty

    #if canImport(AVFoundation)
    @Published public private(set) var player: AVPlayer? = nil
    #endif

    /// Dedicated VLCKit backend handling universal container demuxing and codec decoding.
    public let vlcBackend: LIDVLCKitBackend
    /// Native Apple AVFoundation backend handling HLS, PiP, and swarm streaming.
    public let avBackend: LIDAVFoundationBackend

    /// Track manager handling audio tracks, subtitles, and external cue rendering.
    public let trackManager: LIDTrackManager

    /// Optional reference to the BitTorrent engine for sequential swarm streaming.
    public var torrentEngine: TorrentEngine? {
        didSet {
            avBackend.torrentEngine = torrentEngine
        }
    }

    private let historyStore: LIDPlaybackHistoryStore
    private var lastRecordedSecond: Int = 0

    public init(
        historyStore: LIDPlaybackHistoryStore = .shared,
        trackManager: LIDTrackManager? = nil,
        torrentEngine: TorrentEngine? = nil
    ) {
        self.historyStore = historyStore
        self.trackManager = trackManager ?? LIDTrackManager()
        self.torrentEngine = torrentEngine

        let vlc = LIDVLCKitBackend()
        let av = LIDAVFoundationBackend()
        av.torrentEngine = torrentEngine

        self.vlcBackend = vlc
        self.avBackend = av

        super.init()

        vlc.delegate = self
        av.delegate = self

        LIDNowPlayingCoordinator.shared.setupRemoteCommands(
            onPlay: { [weak self] in self?.play() },
            onPause: { [weak self] in self?.pause() },
            onTogglePlayPause: { [weak self] in self?.togglePlayPause() },
            onSeekTo: { [weak self] target in self?.seek(to: target) },
            onSkip: { [weak self] delta in self?.seekBy(offsetSeconds: delta) }
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Backend Routing

    /// Determines the optimal playback backend for a given media source based on container,
    /// stream protocol, and platform capabilities.
    public func selectBackend(for source: LIDPlayerSource) -> LIDMediaEngineBackendType {
        switch source {
        case .localFile, .partialDownload:
            // Route all local media to VLCKit by default for universal container and codec decoding.
            return .vlcKit
        case .hlsStream, .torrentSwarm:
            // Preserve native HLS adaptive bitrate streaming and BitTorrent AVAssetResourceLoader integration.
            return .avFoundation
        case .dashStream, .networkStream:
            // Direct network streams and DASH manifests route through VLCKit's demuxer.
            return .vlcKit
        }
    }

    // MARK: - Audio Session Control

    #if os(iOS) && canImport(AVFoundation)
    public static func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playback,
                mode: .moviePlayback,
                options: [.allowAirPlay, .allowBluetooth]
            )
            try session.setActive(true)
        } catch {
            PipelineLogger.shared.log("[LIDPlaybackEngine] Audio session configuration notice: \(error.localizedDescription)")
        }
    }

    public static func deactivateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            PipelineLogger.shared.log("[LIDPlaybackEngine] Audio session deactivation notice: \(error.localizedDescription)")
        }
    }
    #endif

    // MARK: - Container Header Validation

    /// Validates that the file begins with the standard MPEG-TS sync byte (0x47).
    nonisolated public static func validateTSHeader(url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 188), !data.isEmpty else { return false }
        return data.first == 0x47
    }

    // MARK: - Playback Control APIs

    @MainActor
    public func load(source: LIDPlayerSource, autoPlay: Bool = true, resumeFromHistory: Bool = true) {
        stop()
        self.currentSource = source
        self.playbackState = .loading
        self.currentPositionSeconds = 0.0
        self.durationSeconds = 0.0
        self.bufferedDurationSeconds = 0.0
        self.metadata = LIDMediaMetadata(title: source.title)
        self.streamContext = LIDStreamContextInfo(isLive: false)
        self.trackManager.reset()

        // Validate local file existence and container header
        if case .localFile(let url, _) = source {
            guard FileManager.default.fileExists(atPath: url.path) else {
                self.playbackState = .failed(error: "Media file does not exist on disk: \(url.lastPathComponent)")
                return
            }

            if url.pathExtension.lowercased() == "ts" {
                if !Self.validateTSHeader(url: url) {
                    self.playbackState = .failed(error: "File is not a valid MPEG-2 Transport Stream (missing 0x47 sync header).")
                    return
                }
            }
        }

        #if os(iOS) && canImport(AVFoundation)
        if autoPlay {
            Self.configureAudioSession()
        }
        #endif

        let selected = selectBackend(for: source)
        self.activeBackendType = selected

        switch selected {
        case .vlcKit:
            #if canImport(AVFoundation)
            self.player = nil
            #endif
            vlcBackend.load(source: source, autoPlay: autoPlay)

        case .avFoundation:
            avBackend.load(source: source, autoPlay: autoPlay)
            #if canImport(AVFoundation)
            self.player = avBackend.player
            #endif
        }

        // Auto-resume from history position if recorded
        if resumeFromHistory {
            let mediaID = source.mediaIdentifier
            Task { [weak self] in
                guard let self = self else { return }
                if let resumeSec = await self.historyStore.resumePosition(mediaIdentifier: mediaID),
                   resumeSec > 0 {
                    self.seek(to: resumeSec)
                }
            }
        }
    }

    @MainActor
    public func play() {
        #if os(iOS) && canImport(AVFoundation)
        Self.configureAudioSession()
        #endif
        switch activeBackendType {
        case .vlcKit:
            vlcBackend.play()
        case .avFoundation:
            avBackend.play()
        }
        self.playbackState = .playing
        updateNowPlaying()
    }

    @MainActor
    public func pause() {
        switch activeBackendType {
        case .vlcKit:
            vlcBackend.pause()
        case .avFoundation:
            avBackend.pause()
        }
        self.playbackState = .paused
        saveCurrentPosition()
        updateNowPlaying()
    }

    @MainActor
    public func togglePlayPause() {
        if playbackState.isPlaying {
            pause()
        } else {
            play()
        }
    }

    @MainActor
    public func stop() {
        saveCurrentPosition()
        LIDNowPlayingCoordinator.shared.clearNowPlaying()
        trackManager.reset()

        #if os(iOS) && canImport(AVFoundation)
        Self.deactivateAudioSession()
        #endif

        vlcBackend.stop()
        avBackend.stop()

        #if canImport(AVFoundation)
        self.player = nil
        #endif

        self.playbackState = .idle
        self.currentPositionSeconds = 0.0
        self.durationSeconds = 0.0
        self.bufferedDurationSeconds = 0.0
        self.streamContext = .empty
        self.currentSource = nil
    }

    @MainActor
    public func seek(to seconds: Double) {
        let target = max(0.0, min(seconds, durationSeconds > 0 ? durationSeconds : seconds))
        self.currentPositionSeconds = target
        switch activeBackendType {
        case .vlcKit:
            vlcBackend.seek(to: target)
        case .avFoundation:
            avBackend.seek(to: target)
        }
        saveCurrentPosition()
        updateNowPlaying()
    }

    @MainActor
    public func seekBy(offsetSeconds: Double) {
        seek(to: currentPositionSeconds + offsetSeconds)
    }

    @MainActor
    public func setPlaybackSpeed(_ speed: LIDPlaybackSpeed) {
        self.playbackSpeed = speed
        vlcBackend.playbackSpeed = speed
        avBackend.playbackSpeed = speed
        updateNowPlaying()
    }

    @MainActor
    public func setVolume(_ newVolume: Float) {
        let clamped = max(0.0, min(newVolume, 1.0))
        self.volume = clamped
        vlcBackend.volume = clamped
        avBackend.volume = clamped
    }

    @MainActor
    public func toggleMute() {
        self.isMuted.toggle()
        vlcBackend.isMuted = self.isMuted
        avBackend.isMuted = self.isMuted
    }

    // MARK: - LIDMediaEngineDelegate Implementation

    public func engineDidUpdateState(_ engine: LIDMediaEngineProtocol, state: LIDPlaybackState) {
        guard engine.backendType == self.activeBackendType else { return }
        self.playbackState = state
        updateNowPlaying()
    }

    public func engineDidUpdateTime(_ engine: LIDMediaEngineProtocol, currentSeconds: Double, durationSeconds: Double) {
        guard engine.backendType == self.activeBackendType else { return }
        self.currentPositionSeconds = currentSeconds
        if durationSeconds > 0 {
            self.durationSeconds = durationSeconds
        }
        self.trackManager.updatePosition(currentSeconds)

        let intSec = Int(currentSeconds)
        if intSec > 0 && intSec % 5 == 0 && intSec != self.lastRecordedSecond {
            self.lastRecordedSecond = intSec
            self.saveCurrentPosition()
        }
        updateNowPlaying()
    }

    public func engineDidUpdateBuffering(_ engine: LIDMediaEngineProtocol, bufferedSeconds: Double) {
        guard engine.backendType == self.activeBackendType else { return }
        self.bufferedDurationSeconds = bufferedSeconds
    }

    public func engineDidUpdateMetadata(_ engine: LIDMediaEngineProtocol, metadata: LIDMediaMetadata) {
        guard engine.backendType == self.activeBackendType else { return }
        self.metadata = metadata
        updateNowPlaying()
    }

    public func engineDidFail(_ engine: LIDMediaEngineProtocol, error: String) {
        guard engine.backendType == self.activeBackendType else { return }
        self.playbackState = .failed(error: error)
    }

    // MARK: - Internal Helpers

    private func updateNowPlaying() {
        guard let source = currentSource else { return }
        let rate: Float = playbackState.isPlaying ? Float(playbackSpeed.rawValue) : 0.0
        LIDNowPlayingCoordinator.shared.updateNowPlaying(
            title: source.title,
            duration: durationSeconds,
            currentTime: currentPositionSeconds,
            playbackRate: rate
        )
    }

    private func saveCurrentPosition() {
        guard let source = currentSource else { return }
        let mediaID = source.mediaIdentifier
        let title = source.title
        let pos = currentPositionSeconds
        let dur = durationSeconds
        Task {
            await historyStore.recordPosition(
                mediaIdentifier: mediaID,
                title: title,
                positionSeconds: pos,
                durationSeconds: dur
            )
        }
    }
}

/// Unified playback controller alias consumed by the player interface.
public typealias LIDPlaybackController = LIDPlaybackEngine
