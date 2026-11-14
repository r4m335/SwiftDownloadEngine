import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(Combine)
import Combine
#endif

/// Native media playback engine managing AVFoundation player lifecycle, buffering,
/// time observation, position persistence, and stream/file playback.
@MainActor
public final class LIDPlaybackEngine: NSObject, ObservableObject {

    public static let shared = LIDPlaybackEngine()

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

    /// Track manager handling audio tracks, subtitles, and external cue rendering.
    public let trackManager: LIDTrackManager

    /// Optional reference to the BitTorrent engine for sequential swarm streaming.
    public var torrentEngine: TorrentEngine?

    #if canImport(AVFoundation)
    public private(set) var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var timeObserverToken: Any?
    private var statusObserver: NSKeyValueObservation?
    private var bufferEmptyObserver: NSKeyValueObservation?
    private var likelyToKeepUpObserver: NSKeyValueObservation?
    private var loadedTimeRangesObserver: NSKeyValueObservation?
    private var seekableTimeRangesObserver: NSKeyValueObservation?
    private var torrentStreamAdapter: LIDTorrentStreamAdapter?
    private var dashStreamAdapter: LIDDASHStreamAdapter?
    #endif

    private var swarmStatusTask: Task<Void, Never>?
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
        super.init()

        LIDNowPlayingCoordinator.shared.setupRemoteCommands(
            onPlay: { [weak self] in self?.play() },
            onPause: { [weak self] in self?.pause() },
            onTogglePlayPause: { [weak self] in self?.togglePlayPause() },
            onSeekTo: { [weak self] target in self?.seek(to: target) },
            onSkip: { [weak self] delta in self?.seekBy(offsetSeconds: delta) }
        )
    }

    deinit {
        #if canImport(AVFoundation)
        if let token = timeObserverToken, let player = player {
            player.removeTimeObserver(token)
        }
        statusObserver?.invalidate()
        bufferEmptyObserver?.invalidate()
        likelyToKeepUpObserver?.invalidate()
        loadedTimeRangesObserver?.invalidate()
        NotificationCenter.default.removeObserver(self)
        player?.pause()
        #endif
    }

    // MARK: - Playback Control APIs

    /// Configures the shared BitTorrent engine instance for swarm streaming.
    public func configure(torrentEngine: TorrentEngine) {
        self.torrentEngine = torrentEngine
    }

    /// Loads and prepares a media source for playback.
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

        #if canImport(AVFoundation)
        let asset: AVURLAsset
        var options: [String: Any] = [:]

        switch source {
        case .networkStream(let url, let headers, _):
            if !headers.isEmpty {
                options["AVURLAssetHTTPHeaderFieldsKey"] = headers
            }
            asset = AVURLAsset(url: url, options: options)

        case .hlsStream(let url, let variantPreferences, _, let requestContext):
            var targetURL = url
            if let exact = variantPreferences?.exactURI {
                targetURL = exact
            }
            if let headers = requestContext?.effectiveHeaders(for: targetURL), !headers.isEmpty {
                options["AVURLAssetHTTPHeaderFieldsKey"] = headers
            }
            asset = AVURLAsset(url: targetURL, options: options)

        case .dashStream(let manifestURL, let repID, _, let requestContext):
            let adapter = LIDDASHStreamAdapter(
                manifestURL: manifestURL,
                selectedRepresentationID: repID,
                requestContext: requestContext
            )
            self.dashStreamAdapter = adapter
            asset = AVURLAsset(url: adapter.customSchemeURL, options: options)
            asset.resourceLoader.setDelegate(adapter, queue: adapter.dispatchQueue)

        case .torrentSwarm(let infoHash, let fileIndex, _):
            let adapter = LIDTorrentStreamAdapter(
                infoHash: infoHash,
                fileIndex: fileIndex,
                torrentEngine: torrentEngine
            )
            self.torrentStreamAdapter = adapter
            asset = AVURLAsset(url: adapter.customSchemeURL, options: options)
            asset.resourceLoader.setDelegate(adapter, queue: adapter.dispatchQueue)
            startSwarmMonitoring(infoHash: infoHash)

        case .localFile(let url, _), .partialDownload(let url, _, _):
            asset = AVURLAsset(url: url, options: options)
        }

        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .spectral

        // Apply HLS variant preferences on the AVPlayerItem if specified
        if case .hlsStream(_, let prefs, _, _) = source {
            if let maxBw = prefs?.maximumBandwidth {
                item.preferredPeakBitRate = Double(maxBw)
            }
            if prefs?.maximumWidth != nil || prefs?.maximumHeight != nil {
                let w = CGFloat(prefs?.maximumWidth ?? 1920)
                let h = CGFloat(prefs?.maximumHeight ?? 1080)
                item.preferredMaximumResolution = CGSize(width: w, height: h)
            }
        }

        self.playerItem = item

        let avPlayer = AVPlayer(playerItem: item)
        avPlayer.actionAtItemEnd = .pause
        self.player = avPlayer

        setupItemObservers(for: item, source: source, autoPlay: autoPlay, resumeFromHistory: resumeFromHistory)
        setupTimeObserver(for: avPlayer, source: source)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerItemDidReachEnd(_:)),
            name: .AVPlayerItemDidPlayToEndTime,
            object: item
        )
        #else
        self.playbackState = .failed(error: "AVFoundation is not available on this platform.")
        #endif
    }

    @MainActor
    public func play() {
        #if canImport(AVFoundation)
        guard let player = player else { return }
        player.rate = Float(playbackSpeed.rawValue)
        playbackState = .playing
        if let source = currentSource {
            LIDNowPlayingCoordinator.shared.updateNowPlaying(
                title: source.title,
                duration: durationSeconds,
                currentTime: currentPositionSeconds,
                playbackRate: Float(playbackSpeed.rawValue)
            )
        }
        #endif
    }

    @MainActor
    public func pause() {
        #if canImport(AVFoundation)
        guard let player = player else { return }
        player.pause()
        playbackState = .paused
        saveCurrentPosition()
        if let source = currentSource {
            LIDNowPlayingCoordinator.shared.updateNowPlaying(
                title: source.title,
                duration: durationSeconds,
                currentTime: currentPositionSeconds,
                playbackRate: 0.0
            )
        }
        #endif
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
    public func seek(to seconds: Double, completion: (@MainActor @Sendable (Bool) -> Void)? = nil) {
        let target = max(0.0, min(seconds, durationSeconds > 0 ? durationSeconds : seconds))
        #if canImport(AVFoundation)
        guard let player = player else {
            completion?(false)
            return
        }
        let previousState = playbackState
        playbackState = .seeking(targetSeconds: target)
        currentPositionSeconds = target

        let cmTime = CMTime(seconds: target, preferredTimescale: 600)
        player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if previousState.isPlaying {
                    player.rate = Float(self.playbackSpeed.rawValue)
                    self.playbackState = .playing
                } else {
                    self.playbackState = .paused
                }
                self.saveCurrentPosition()
                completion?(finished)
            }
        }
        #else
        currentPositionSeconds = target
        completion?(true)
        #endif
    }

    @MainActor
    public func seekBy(offsetSeconds: Double) {
        seek(to: currentPositionSeconds + offsetSeconds)
    }

    @MainActor
    public func setPlaybackSpeed(_ speed: LIDPlaybackSpeed) {
        self.playbackSpeed = speed
        #if canImport(AVFoundation)
        if playbackState.isPlaying {
            player?.rate = Float(speed.rawValue)
        }
        #endif
    }

    @MainActor
    public func setVolume(_ newVolume: Float) {
        let clamped = max(0.0, min(newVolume, 1.0))
        self.volume = clamped
        #if canImport(AVFoundation)
        player?.volume = clamped
        #endif
    }

    @MainActor
    public func toggleMute() {
        self.isMuted.toggle()
        #if canImport(AVFoundation)
        player?.isMuted = self.isMuted
        #endif
    }

    @MainActor
    public func stop() {
        saveCurrentPosition()
        LIDNowPlayingCoordinator.shared.clearNowPlaying()
        trackManager.reset()
        swarmStatusTask?.cancel()
        swarmStatusTask = nil
        #if canImport(AVFoundation)
        if let token = timeObserverToken, let player = player {
            player.removeTimeObserver(token)
            self.timeObserverToken = nil
        }
        statusObserver?.invalidate()
        statusObserver = nil
        bufferEmptyObserver?.invalidate()
        bufferEmptyObserver = nil
        likelyToKeepUpObserver?.invalidate()
        likelyToKeepUpObserver = nil
        loadedTimeRangesObserver?.invalidate()
        loadedTimeRangesObserver = nil
        seekableTimeRangesObserver?.invalidate()
        seekableTimeRangesObserver = nil

        torrentStreamAdapter = nil
        dashStreamAdapter = nil

        NotificationCenter.default.removeObserver(self)

        player?.pause()
        self.player = nil
        self.playerItem = nil
        #endif
        self.playbackState = .idle
        self.streamContext = .empty
        self.currentSource = nil
    }

    // MARK: - Internal Observers & Helpers

    #if canImport(AVFoundation)
    private func setupItemObservers(
        for item: AVPlayerItem,
        source: LIDPlayerSource,
        autoPlay: Bool,
        resumeFromHistory: Bool
    ) {
        statusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] observedItem, _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                switch observedItem.status {
                case .readyToPlay:
                    let rawDur = observedItem.duration.seconds
                    let dur = (rawDur.isFinite && !rawDur.isNaN && rawDur > 0) ? rawDur : 0.0
                    self.durationSeconds = dur
                    self.extractMetadata(from: observedItem, title: source.title)
                    self.trackManager.populateTracks(from: observedItem)

                    let isLive = observedItem.duration.isIndefinite
                    self.streamContext.isLive = isLive
                    if isLive, let range = observedItem.seekableTimeRanges.first?.timeRangeValue {
                        let dvrSec = range.duration.seconds
                        if dvrSec.isFinite && !dvrSec.isNaN {
                            self.streamContext.isDVRSeekable = dvrSec > 5.0
                            self.streamContext.dvrWindowDurationSeconds = dvrSec
                        }
                    }

                    // Resume check
                    if resumeFromHistory {
                        let mediaID = source.mediaIdentifier
                        if let resumeSec = await self.historyStore.resumePosition(mediaIdentifier: mediaID),
                           resumeSec < dur {
                            self.seek(to: resumeSec) { [weak self] _ in
                                if autoPlay { self?.play() }
                            }
                            return
                        }
                    }

                    if autoPlay {
                        self.play()
                    } else {
                        self.playbackState = .paused
                    }

                case .failed:
                    let msg = observedItem.error?.localizedDescription ?? "Playback failed."
                    self.playbackState = .failed(error: msg)

                case .unknown:
                    break
                @unknown default:
                    break
                }
            }
        }

        bufferEmptyObserver = item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] observedItem, _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if observedItem.isPlaybackBufferEmpty && self.playbackState != .ended {
                    self.playbackState = .buffering(progress: nil)
                }
            }
        }

        likelyToKeepUpObserver = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] observedItem, _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if observedItem.isPlaybackLikelyToKeepUp && self.playbackState.isBuffering {
                    self.play()
                }
            }
        }

        loadedTimeRangesObserver = item.observe(\.loadedTimeRanges, options: [.new]) { [weak self] observedItem, _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if let range = observedItem.loadedTimeRanges.first?.timeRangeValue {
                    let buffered = range.start.seconds + range.duration.seconds
                    if buffered.isFinite && !buffered.isNaN {
                        self.bufferedDurationSeconds = buffered
                    }
                }
            }
        }

        seekableTimeRangesObserver = item.observe(\.seekableTimeRanges, options: [.initial, .new]) { [weak self] observedItem, _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if let range = observedItem.seekableTimeRanges.first?.timeRangeValue {
                    let dvrSec = range.duration.seconds
                    if dvrSec.isFinite && !dvrSec.isNaN && dvrSec > 0 {
                        self.streamContext.isDVRSeekable = dvrSec > 5.0
                        self.streamContext.dvrWindowDurationSeconds = dvrSec
                    }
                }
            }
        }
    }

    private func setupTimeObserver(for player: AVPlayer, source: LIDPlayerSource) {
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self else { return }
            let sec = time.seconds
            if sec.isFinite && !sec.isNaN {
                self.currentPositionSeconds = sec
                self.trackManager.updatePosition(sec)
                let intSec = Int(sec)
                // Periodically persist progress every 5 seconds
                if intSec > 0 && intSec % 5 == 0 && intSec != self.lastRecordedSecond {
                    self.lastRecordedSecond = intSec
                    self.saveCurrentPosition()
                }
            }
        }
    }

    private func extractMetadata(from item: AVPlayerItem, title: String) {
        let tracks = item.asset.tracks
        let videoTrack = tracks.first(where: { $0.mediaType == .video })
        let naturalSize = videoTrack?.naturalSize
        let isLive = item.duration.isIndefinite

        self.metadata = LIDMediaMetadata(
            title: title,
            durationSeconds: self.durationSeconds,
            naturalWidth: naturalSize?.width != nil ? Double(naturalSize!.width) : nil,
            naturalHeight: naturalSize?.height != nil ? Double(naturalSize!.height) : nil,
            videoCodec: nil,
            audioCodec: nil,
            estimatedBitrate: videoTrack.map { Int64($0.estimatedDataRate) },
            isLiveStream: isLive,
            audioTrackNames: tracks.filter { $0.mediaType == .audio }.map { $0.languageCode ?? "Audio Track" },
            subtitleTrackNames: tracks.filter { $0.mediaType == .subtitle }.map { $0.languageCode ?? "Subtitle" }
        )
    }

    @objc private func playerItemDidReachEnd(_ notification: Notification) {
        Task { @MainActor in
            self.playbackState = .ended
            self.saveCurrentPosition()
        }
    }
    #endif

    private func startSwarmMonitoring(infoHash: String) {
        swarmStatusTask?.cancel()
        swarmStatusTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self = self, let engine = self.torrentEngine else { break }
                if let task = await engine.task(for: infoHash) {
                    await MainActor.run {
                        self.streamContext.swarmDownloadSpeed = task.progress.downloadBytesPerSecond
                        self.streamContext.swarmUploadSpeed = task.progress.uploadBytesPerSecond
                        self.streamContext.swarmConnectedPeers = task.progress.connectedPeers
                        self.streamContext.swarmActiveSeeds = task.progress.activeSeeds
                        self.streamContext.swarmProgressFraction = task.progress.progressFraction
                    }
                }
            }
        }
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
