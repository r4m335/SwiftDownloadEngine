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
    public nonisolated(unsafe) static var activeSessionIdForLogging: String = "IDLE"

    @Published public private(set) var activeBackendType: LIDMediaEngineBackendType = .vlcKit
    @Published public private(set) var playbackState: LIDPlaybackState = .idle
    @Published public private(set) var currentPositionSeconds: Double = 0.0
    @Published public private(set) var durationSeconds: Double = 0.0
    @Published public private(set) var bufferedDurationSeconds: Double = 0.0
    @Published public private(set) var playbackRate: Double = 1.0
    @Published public private(set) var playbackSpeed: LIDPlaybackSpeed = .speed1_00
    private var lastNonZeroPlaybackRate: Double = 1.0
    private var isTemporarySpeedBoostActive: Bool = false
    private var speedBeforeTemporaryBoost: Double = 1.0
    @Published public private(set) var aspectRatio: LIDAspectRatio = .original
    @Published public private(set) var metadata: LIDMediaMetadata = .empty
    @Published public private(set) var volume: Float = 1.0
    @Published public private(set) var isMuted: Bool = false
    @Published public private(set) var currentSource: LIDPlayerSource? = nil
    @Published public private(set) var streamContext: LIDStreamContextInfo = .empty

    public var activeBackend: LIDMediaEngineProtocol {
        switch activeBackendType {
        case .vlcKit: return vlcBackend
        case .avFoundation: return avBackend
        }
    }

    public var supportsPictureInPicture: Bool {
        activeBackend.supportsPictureInPicture
    }

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
    private var loadingWatchdogTimer: Timer? = nil
    private var renderingWatchdogTimer: Timer? = nil
    public private(set) var currentSessionId: String = "IDLE"

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

    /// Configures or updates the underlying BitTorrent engine for swarm playback.
    public func configure(torrentEngine: TorrentEngine) {
        self.torrentEngine = torrentEngine
        self.avBackend.torrentEngine = torrentEngine
    }

    // MARK: - Backend Routing

    #if canImport(VLCKit)
    public static let isVLCKitAvailable: Bool = true
    #else
    public static let isVLCKitAvailable: Bool = false
    #endif

    public static func isNativeSupportedExtension(_ ext: String) -> Bool {
        let lower = ext.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
        return ["mp4", "m4v", "mov", "mp3", "m4a", "aac", "wav", "flac", "caf", "aiff", "alac", "m3u8"].contains(lower)
    }

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
    public static func targetAudioSessionCategory(enableBackgroundAudio: Bool) -> AVAudioSession.Category {
        enableBackgroundAudio ? .playback : .ambient
    }

    public static func configureAudioSession(enableBackgroundAudio: Bool = true) {
        do {
            let session = AVAudioSession.sharedInstance()
            let category = targetAudioSessionCategory(enableBackgroundAudio: enableBackgroundAudio)
            try session.setCategory(category, mode: .moviePlayback)
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

    /// Validates that the file contains valid MPEG-2 Transport Stream sync markers (0x47),
    /// accounting for optional prepended ID3 metadata tags (common in HLS-derived TS streams)
    /// and standard 188-byte packet strides.
    nonisolated public static func validateTSHeader(url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096), !data.isEmpty else { return false }

        // 1. Direct standard MPEG-TS sync byte at offset 0
        if data.first == 0x47 {
            return true
        }

        // 2. Check for ID3v2 metadata header prepended to TS stream (bytes "ID3")
        if data.count >= 10, data[0] == 0x49, data[1] == 0x44, data[2] == 0x33 {
            let sizeBytes = data[6..<10]
            // Synchsafe integer (7 bits per byte)
            let tagSize = (Int(sizeBytes[sizeBytes.startIndex]) << 21)
                | (Int(sizeBytes[sizeBytes.startIndex + 1]) << 14)
                | (Int(sizeBytes[sizeBytes.startIndex + 2]) << 7)
                | Int(sizeBytes[sizeBytes.startIndex + 3])
            let tsOffset = 10 + tagSize

            if tsOffset < data.count && data[tsOffset] == 0x47 {
                return true
            }
            if let _ = try? handle.seek(toOffset: UInt64(tsOffset)),
               let tsData = try? handle.read(upToCount: 1),
               tsData.first == 0x47 {
                return true
            }
        }

        // 3. Scan for sync byte pattern with standard 188-byte packet stride
        let maxSearch = min(data.count, 1024)
        for offset in 0..<maxSearch {
            if data[offset] == 0x47 {
                let nextOffset = offset + 188
                if nextOffset < data.count && data[nextOffset] == 0x47 {
                    return true
                }
            }
        }

        return false
    }

    // MARK: - Playback Control APIs

    @MainActor
    public func load(source: LIDPlayerSource, autoPlay: Bool = true, resumeFromHistory: Bool = true, sessionId: String? = nil) {
        stop()
        let sid = sessionId ?? String(UUID().uuidString.prefix(8).uppercased())
        self.currentSessionId = sid
        Self.activeSessionIdForLogging = sid
        vlcBackend.activeSessionId = sid
        avBackend.activeSessionId = sid

        PipelineLogger.shared.logPlayer(
            session: sid,
            category: "PlayerLifecycle",
            message: "Loading source '\(source.title)' (format=\(source.url?.pathExtension ?? "stream"), autoPlay=\(autoPlay))"
        )

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
                let err = "Media file does not exist on disk: \(url.lastPathComponent)"
                self.playbackState = .failed(error: err)
                PipelineLogger.shared.logPlayer(session: sid, category: "PlayerError", message: err)
                return
            }

            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? Int64, size == 0 {
                let err = "Media file is empty (0 bytes): \(url.lastPathComponent)"
                self.playbackState = .failed(error: err)
                PipelineLogger.shared.logPlayer(session: sid, category: "PlayerError", message: err)
                return
            }

            if url.pathExtension.lowercased() == "ts" {
                if !Self.validateTSHeader(url: url) {
                    let err = "File is not a valid MPEG-2 Transport Stream (missing 0x47 sync header)."
                    self.playbackState = .failed(error: err)
                    PipelineLogger.shared.logPlayer(session: sid, category: "PlayerError", message: err)
                    return
                }
            }
        }

        #if os(iOS) && canImport(AVFoundation)
        if autoPlay {
            Self.configureAudioSession(enableBackgroundAudio: LIDPlayerSettingsStore.shared.settings.enableBackgroundAudio)
        }
        #endif

        let selected = selectBackend(for: source)
        self.activeBackendType = selected
        PipelineLogger.shared.logPlayer(
            session: sid,
            category: "PlayerBackend",
            message: "Selected backend: \(selected)"
        )

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

        startLoadingWatchdog()
    }

    @MainActor
    public func play() {
        PipelineLogger.shared.logPlayer(session: currentSessionId, category: "PlayerEngine", message: "play() triggered")
        #if os(iOS) && canImport(AVFoundation)
        Self.configureAudioSession(enableBackgroundAudio: LIDPlayerSettingsStore.shared.settings.enableBackgroundAudio)
        #endif
        if playbackRate == 0.0 {
            let restored = lastNonZeroPlaybackRate > 0 ? lastNonZeroPlaybackRate : 1.0
            setPlaybackRate(restored)
        }
        switch activeBackendType {
        case .vlcKit:
            vlcBackend.play()
        case .avFoundation:
            avBackend.play()
        }
        self.playbackState = .playing
        startRenderingWatchdog()
        updateNowPlaying()
    }

    @MainActor
    public func pause() {
        PipelineLogger.shared.logPlayer(session: currentSessionId, category: "PlayerEngine", message: "pause() triggered at \(currentPositionSeconds)s")
        if isTemporarySpeedBoostActive {
            cancelTemporarySpeedBoost()
        }
        switch activeBackendType {
        case .vlcKit:
            vlcBackend.pause()
        case .avFoundation:
            avBackend.pause()
        }
        self.playbackState = .paused
        cancelRenderingWatchdog()
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
        PipelineLogger.shared.logPlayer(session: currentSessionId, category: "PlayerEngine", message: "stop() triggered")
        if isTemporarySpeedBoostActive {
            cancelTemporarySpeedBoost()
        }
        cancelLoadingWatchdog()
        cancelRenderingWatchdog()
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
        PipelineLogger.shared.logPlayer(
            session: currentSessionId,
            category: "PlayerEngine",
            message: "seek(to: \(String(format: "%.1f", target))s)"
        )
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
    public func setPlaybackRate(_ rate: Double) {
        let clamped = max(0.0, min(2.0, rate))
        PipelineLogger.shared.logPlayer(
            session: currentSessionId,
            category: "PlayerEngine",
            message: "setPlaybackRate(\(String(format: "%.2f", clamped))x)"
        )
        self.playbackRate = clamped
        if clamped > 0.0 {
            self.lastNonZeroPlaybackRate = clamped
            self.playbackSpeed = LIDPlaybackSpeed.fromRate(clamped)
            vlcBackend.playbackRate = clamped
            avBackend.playbackRate = clamped
            if playbackState == .paused {
                play()
            }
        } else {
            // Treat 0.0x as paused playback while preserving active speed
            vlcBackend.playbackRate = 0.0
            avBackend.playbackRate = 0.0
            if playbackState == .playing {
                pause()
            }
        }
        updateNowPlaying()
    }

    @MainActor
    public func setPlaybackSpeed(_ speed: LIDPlaybackSpeed) {
        setPlaybackRate(speed.rawValue)
    }

    @MainActor
    public func startTemporarySpeedBoost(rate: Double = 2.0) {
        guard !isTemporarySpeedBoostActive else { return }
        isTemporarySpeedBoostActive = true
        speedBeforeTemporaryBoost = playbackRate > 0 ? playbackRate : (lastNonZeroPlaybackRate > 0 ? lastNonZeroPlaybackRate : 1.0)
        let boostRate = min(2.0, max(0.25, rate))
        PipelineLogger.shared.logPlayer(
            session: currentSessionId,
            category: "PlayerEngine",
            message: "Temporary speed boost started: \(speedBeforeTemporaryBoost)x -> \(boostRate)x"
        )
        vlcBackend.playbackRate = boostRate
        avBackend.playbackRate = boostRate
        self.playbackRate = boostRate
        if playbackState == .paused {
            play()
        }
    }

    @MainActor
    public func cancelTemporarySpeedBoost() {
        guard isTemporarySpeedBoostActive else { return }
        isTemporarySpeedBoostActive = false
        let restored = speedBeforeTemporaryBoost
        PipelineLogger.shared.logPlayer(
            session: currentSessionId,
            category: "PlayerEngine",
            message: "Temporary speed boost cancelled: restoring \(restored)x"
        )
        self.playbackRate = restored
        self.playbackSpeed = LIDPlaybackSpeed.fromRate(restored)
        vlcBackend.playbackRate = restored
        avBackend.playbackRate = restored
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

    @MainActor
    public func setAspectRatio(_ ratio: LIDAspectRatio) {
        self.aspectRatio = ratio
        activeBackend.setAspectRatio(ratio)
    }

    @MainActor
    public func replay() {
        seek(to: 0.0)
        play()
    }

    // MARK: - Track Management Coordination

    @MainActor
    public func refreshTracks() {
        let audios = activeBackend.getAudioTracks()
        let subs = activeBackend.getSubtitleTracks()
        trackManager.updateAvailableTracks(audioTracks: audios, subtitleTracks: subs)
        if let source = currentSource {
            let mediaID = source.mediaIdentifier
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let record = await self.historyStore.playbackRecord(mediaIdentifier: mediaID)
                self.trackManager.applyPreferences(
                    settings: LIDPlayerSettingsStore.shared.settings,
                    historyRecord: record
                )
            }
        }
    }

    @MainActor
    public func selectAudioTrack(_ track: LIDAudioTrack) {
        trackManager.selectAudioTrack(track)
        activeBackend.selectAudioTrack(id: track.id)
        if let source = currentSource, LIDPlayerSettingsStore.shared.settings.rememberAudioTrack {
            let mediaID = source.mediaIdentifier
            Task {
                await historyStore.recordSelectedTracks(mediaIdentifier: mediaID, audioTrackId: track.id, subtitleTrackId: nil)
            }
        }
    }

    @MainActor
    public func selectSubtitleTrack(_ track: LIDSubtitleTrack) {
        trackManager.selectSubtitleTrack(track)
        if !track.isExternal {
            activeBackend.selectSubtitleTrack(id: track.id)
        }
        if let source = currentSource, LIDPlayerSettingsStore.shared.settings.rememberSubtitleTrack {
            let mediaID = source.mediaIdentifier
            Task {
                await historyStore.recordSelectedTracks(mediaIdentifier: mediaID, audioTrackId: nil, subtitleTrackId: track.id)
            }
        }
    }

    @MainActor
    public func addExternalSubtitle(url: URL, displayName: String? = nil, autoSelect: Bool = true) {
        trackManager.addExternalSubtitle(url: url, displayName: displayName, autoSelect: autoSelect)
        activeBackend.addExternalSubtitle(url: url)
        trackManager.updatePosition(currentPositionSeconds)
    }

    public var subtitleDelay: Double {
        trackManager.subtitleDelay
    }

    @MainActor
    public func setSubtitleDelay(seconds: Double) {
        trackManager.subtitleDelay = seconds
        vlcBackend.setSubtitleDelay(seconds: seconds)
        avBackend.setSubtitleDelay(seconds: seconds)
        trackManager.updatePosition(currentPositionSeconds)
    }

    @MainActor
    public func adjustSubtitleDelay(by delta: Double) {
        setSubtitleDelay(seconds: trackManager.subtitleDelay + delta)
    }

    // MARK: - Anonymous Subtitle Discovery & Search

    @MainActor
    public func searchSubtitles(query: SubtitleSearchQuery) async -> [SubtitleSearchResult] {
        return await LIDSubtitleSearchManager.shared.search(query: query)
    }

    @MainActor
    public func downloadAndApplySubtitle(result: SubtitleSearchResult, forMediaTitle: String) async throws -> LIDSubtitleTrack {
        let data = try await LIDSubtitleSearchManager.shared.download(result: result)
        let localURL = try await LIDSubtitleStore.shared.saveSubtitle(
            data: data,
            mediaTitle: forMediaTitle,
            languageCode: result.languageCode,
            releaseName: result.releaseName,
            format: result.format
        )
        addExternalSubtitle(url: localURL, displayName: result.displayTitle)
        let trackId = "external_\(localURL.lastPathComponent)"
        let appliedTrack = trackManager.availableSubtitleTracks.first(where: { $0.id == trackId })
            ?? LIDSubtitleTrack(id: trackId, displayName: result.displayTitle, languageCode: result.languageCode, isExternal: true, externalURL: localURL)
        return appliedTrack
    }

    @MainActor
    public func listDownloadedSubtitles(for mediaTitle: String) async -> [LIDSubtitleTrack] {
        return await LIDSubtitleStore.shared.listDownloadedSubtitles(for: mediaTitle)
    }

    @MainActor
    public func deleteDownloadedSubtitle(url: URL) async throws {
        try await LIDSubtitleStore.shared.deleteSubtitle(at: url)
        trackManager.removeExternalSubtitle(url: url)
    }

    // MARK: - LIDMediaEngineDelegate Implementation

    public func engineDidUpdateState(_ engine: LIDMediaEngineProtocol, state: LIDPlaybackState) {
        guard engine.backendType == self.activeBackendType else { return }
        self.playbackState = state
        if state.isPlaying || state.isPaused || state.isFailed {
            cancelLoadingWatchdog()
        }
        if state == .playing {
            refreshTracks()
        }
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
        PipelineLogger.shared.logPlayer(
            session: currentSessionId,
            category: "PlayerError",
            message: "Engine failed: \(error)"
        )
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

    private func startLoadingWatchdog() {
        cancelLoadingWatchdog()
        loadingWatchdogTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if self.playbackState.isLoading {
                    let err = "Playback initialization timed out. The media format or codec could not be decoded."
                    self.playbackState = .failed(error: err)
                    PipelineLogger.shared.logPlayer(
                        session: self.currentSessionId,
                        category: "PlayerError",
                        message: err
                    )
                    self.stop()
                }
            }
        }
    }

    private func cancelLoadingWatchdog() {
        loadingWatchdogTimer?.invalidate()
        loadingWatchdogTimer = nil
    }

    private func startRenderingWatchdog() {
        cancelRenderingWatchdog()
        var lastPosition: Double = -1.0

        renderingWatchdogTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, self.playbackState.isPlaying else { return }
                let currentPos = self.currentPositionSeconds
                let isAdvancing = (currentPos - lastPosition) > 0.4
                lastPosition = currentPos

                switch self.activeBackendType {
                case .vlcKit:
                    let vTracks = self.vlcBackend.videoTrackCount
                    let hasDrawable = self.vlcBackend.hasAttachedDrawable
                    if isAdvancing && (!hasDrawable || vTracks == 0) {
                        PipelineLogger.shared.logPlayer(
                            session: self.currentSessionId,
                            category: "VideoRenderer",
                            message: "[RenderingWatchdog] WARNING: Audio advancing (pos=\(String(format: "%.1f", currentPos))s) but VLC video anomaly! hasDrawable=\(hasDrawable), videoTracks=\(vTracks)"
                        )
                    }
                case .avFoundation:
                    #if canImport(AVFoundation)
                    if isAdvancing, let item = self.avBackend.playerItem {
                        let size = item.presentationSize
                        if size == .zero && item.tracks.contains(where: { $0.assetTrack?.mediaType == .video }) {
                            PipelineLogger.shared.logPlayer(
                                session: self.currentSessionId,
                                category: "VideoRenderer",
                                message: "[RenderingWatchdog] WARNING: Audio advancing (pos=\(String(format: "%.1f", currentPos))s) but AVPlayerItem presentationSize is zero!"
                            )
                        }
                    }
                    #endif
                }
            }
        }
    }

    private func cancelRenderingWatchdog() {
        renderingWatchdogTimer?.invalidate()
        renderingWatchdogTimer = nil
    }

    private func saveCurrentPosition() {
        guard let source = currentSource else { return }
        let mediaID = source.mediaIdentifier
        let title = source.title
        let pos = currentPositionSeconds
        let dur = durationSeconds
        let audioId = trackManager.selectedAudioTrack?.id
        let subId = trackManager.selectedSubtitleTrack.id
        Task {
            await historyStore.recordPosition(
                mediaIdentifier: mediaID,
                title: title,
                positionSeconds: pos,
                durationSeconds: dur,
                selectedAudioTrackId: audioId,
                selectedSubtitleTrackId: subId
            )
        }
    }
}

/// Unified playback controller alias consumed by the player interface.
public typealias LIDPlaybackController = LIDPlaybackEngine
