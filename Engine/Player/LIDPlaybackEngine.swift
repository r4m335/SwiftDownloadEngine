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

    #if canImport(AVFoundation)
    public private(set) var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var timeObserverToken: Any?
    private var statusObserver: NSKeyValueObservation?
    private var bufferEmptyObserver: NSKeyValueObservation?
    private var likelyToKeepUpObserver: NSKeyValueObservation?
    private var loadedTimeRangesObserver: NSKeyValueObservation?
    #endif

    private let historyStore: LIDPlaybackHistoryStore
    private var lastRecordedSecond: Int = 0

    public init(historyStore: LIDPlaybackHistoryStore = .shared) {
        self.historyStore = historyStore
        super.init()
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

        #if canImport(AVFoundation)
        let asset: AVURLAsset
        if let url = source.url {
            var options: [String: Any] = [:]
            if case .networkStream(_, let headers, _) = source, !headers.isEmpty {
                options["AVURLAssetHTTPHeaderFieldsKey"] = headers
            }
            asset = AVURLAsset(url: url, options: options)
        } else {
            self.playbackState = .failed(error: "Unsupported media source URL.")
            return
        }

        let item = AVPlayerItem(asset: asset)
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
        #endif
    }

    @MainActor
    public func pause() {
        #if canImport(AVFoundation)
        guard let player = player else { return }
        player.pause()
        playbackState = .paused
        saveCurrentPosition()
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

        NotificationCenter.default.removeObserver(self)

        player?.pause()
        self.player = nil
        self.playerItem = nil
        #endif
        self.playbackState = .idle
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

                    // Resume check
                    if resumeFromHistory, let mediaID = source.url?.absoluteString {
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
    }

    private func setupTimeObserver(for player: AVPlayer, source: LIDPlayerSource) {
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self else { return }
            let sec = time.seconds
            if sec.isFinite && !sec.isNaN {
                self.currentPositionSeconds = sec
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

    private func saveCurrentPosition() {
        guard let source = currentSource, let url = source.url else { return }
        let mediaID = url.absoluteString
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
