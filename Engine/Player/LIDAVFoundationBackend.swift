import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(AVKit)
import AVKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Native Apple AVFoundation playback backend implementing `LIDMediaEngineProtocol`.
/// Optimized for native HLS adaptive streaming, system Picture-in-Picture (`AVPictureInPictureController`),
/// and custom resource loader integrations (e.g. BitTorrent sequential swarm streaming).
@MainActor
public final class LIDAVFoundationBackend: NSObject, LIDMediaEngineProtocol {

    public let backendType: LIDMediaEngineBackendType = .avFoundation
    public weak var delegate: LIDMediaEngineDelegate?
    public var activeSessionId: String = "IDLE"

    public private(set) var playbackState: LIDPlaybackState = .idle
    public private(set) var currentPositionSeconds: Double = 0.0
    public private(set) var durationSeconds: Double = 0.0
    public private(set) var bufferedDurationSeconds: Double = 0.0

    public var playbackRate: Double = 1.0 {
        didSet {
            #if canImport(AVFoundation)
            if let p = player, p.rate != 0 {
                p.rate = Float(playbackRate)
            }
            #endif
        }
    }

    public var playbackSpeed: LIDPlaybackSpeed {
        get {
            LIDPlaybackSpeed.fromRate(playbackRate)
        }
        set {
            self.playbackRate = newValue.rawValue
        }
    }

    public var volume: Float {
        get {
            #if canImport(AVFoundation)
            return player?.volume ?? 1.0
            #else
            return 1.0
            #endif
        }
        set {
            #if canImport(AVFoundation)
            player?.volume = max(0.0, min(1.0, newValue))
            #endif
        }
    }

    public var isMuted: Bool {
        get {
            #if canImport(AVFoundation)
            return player?.isMuted ?? false
            #else
            return false
            #endif
        }
        set {
            #if canImport(AVFoundation)
            player?.isMuted = newValue
            #endif
        }
    }

    public var supportsPictureInPicture: Bool {
        #if os(iOS) && canImport(AVKit)
        return AVPictureInPictureController.isPictureInPictureSupported()
        #else
        return false
        #endif
    }

    public func setAspectRatio(_ ratio: LIDAspectRatio) {
        // Aspect ratio for AVFoundation is applied directly via AVLayerVideoGravity on AVPlayerLayer
    }

    #if canImport(AVFoundation)
    public private(set) var player: AVPlayer?
    public private(set) var playerItem: AVPlayerItem?
    private var timeObserverToken: Any?
    private var statusObserver: NSKeyValueObservation?
    private var bufferEmptyObserver: NSKeyValueObservation?
    private var likelyToKeepUpObserver: NSKeyValueObservation?
    private var loadedTimeRangesObserver: NSKeyValueObservation?
    private var seekableTimeRangesObserver: NSKeyValueObservation?
    private var torrentStreamAdapter: LIDTorrentStreamAdapter?
    private var dashStreamAdapter: LIDDASHStreamAdapter?
    #endif

    public var torrentEngine: TorrentEngine?
    private var currentLoadedSource: LIDPlayerSource?

    public override init() {
        super.init()
    }

    deinit {
        #if canImport(AVFoundation)
        statusObserver?.invalidate()
        bufferEmptyObserver?.invalidate()
        likelyToKeepUpObserver?.invalidate()
        loadedTimeRangesObserver?.invalidate()
        seekableTimeRangesObserver?.invalidate()
        if let token = timeObserverToken, let p = player {
            p.removeTimeObserver(token)
        }
        #endif
    }

    // MARK: - Playback Control APIs

    public func load(source: LIDPlayerSource, autoPlay: Bool) {
        stop()
        self.currentLoadedSource = source
        self.playbackState = .loading
        delegate?.engineDidUpdateState(self, state: self.playbackState)

        #if canImport(AVFoundation)
        let asset: AVURLAsset
        switch source {
        case .torrentSwarm(let infoHash, let fileIndex, _):
            guard let engine = torrentEngine else {
                let error = "TorrentEngine is not configured for swarm playback"
                self.playbackState = .failed(error: error)
                delegate?.engineDidFail(self, error: error)
                return
            }
            let adapter = LIDTorrentStreamAdapter(infoHash: infoHash, fileIndex: fileIndex, torrentEngine: engine)
            self.torrentStreamAdapter = adapter
            let customURL = adapter.customSchemeURL
            asset = AVURLAsset(url: customURL)
            asset.resourceLoader.setDelegate(adapter, queue: adapter.dispatchQueue)

        case .hlsStream(let url, let variantPreferences, _, let requestContext):
            let targetURL = variantPreferences?.exactURI ?? url
            var options: [String: Any] = [:]
            if let headers = requestContext?.effectiveHeaders(for: targetURL), !headers.isEmpty {
                options["AVURLAssetHTTPHeaderFieldsKey"] = headers
            }
            asset = AVURLAsset(url: targetURL, options: options)

        case .networkStream(let url, let headers, _):
            var options: [String: Any] = [:]
            if !headers.isEmpty {
                options["AVURLAssetHTTPHeaderFieldsKey"] = headers
            }
            asset = AVURLAsset(url: url, options: options)

        case .dashStream(let manifestURL, let repID, _, let requestContext):
            let adapter = LIDDASHStreamAdapter(manifestURL: manifestURL, selectedRepresentationID: repID, requestContext: requestContext)
            self.dashStreamAdapter = adapter
            let customURL = adapter.customSchemeURL
            asset = AVURLAsset(url: customURL)
            asset.resourceLoader.setDelegate(adapter, queue: adapter.dispatchQueue)

        default:
            guard let url = source.url else {
                let error = "Source has no valid URL"
                self.playbackState = .failed(error: error)
                delegate?.engineDidFail(self, error: error)
                return
            }
            asset = AVURLAsset(url: url)
        }

        let item = AVPlayerItem(asset: asset)
        self.playerItem = item

        if let existingPlayer = self.player {
            existingPlayer.replaceCurrentItem(with: item)
        } else {
            let newPlayer = AVPlayer(playerItem: item)
            self.player = newPlayer
        }

        setupItemObservers(item: item, source: source)
        setupTimeObserver()

        if autoPlay {
            self.play()
        }
        #endif
    }

    public func play() {
        #if canImport(AVFoundation)
        guard let p = player else { return }
        p.play()
        p.rate = Float(playbackRate)
        self.playbackState = .playing
        delegate?.engineDidUpdateState(self, state: self.playbackState)
        #endif
    }

    public func pause() {
        #if canImport(AVFoundation)
        guard let p = player else { return }
        p.pause()
        self.playbackState = .paused
        delegate?.engineDidUpdateState(self, state: self.playbackState)
        #endif
    }

    public func stop() {
        #if canImport(AVFoundation)
        if let token = timeObserverToken, let p = player {
            p.removeTimeObserver(token)
            timeObserverToken = nil
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

        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        playerItem = nil
        torrentStreamAdapter = nil
        dashStreamAdapter = nil
        #endif

        self.currentLoadedSource = nil
        self.currentPositionSeconds = 0.0
        self.durationSeconds = 0.0
        self.bufferedDurationSeconds = 0.0
        self.playbackState = .idle
        delegate?.engineDidUpdateState(self, state: .idle)
    }

    public func seek(to seconds: Double) {
        #if canImport(AVFoundation)
        guard let p = player else { return }
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        p.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            guard let self = self, finished else { return }
            self.currentPositionSeconds = seconds
            self.delegate?.engineDidUpdateTime(self, currentSeconds: seconds, durationSeconds: self.durationSeconds)
        }
        #endif
    }

    // MARK: - Track Management

    public func getAudioTracks() -> [LIDAudioTrack] {
        #if canImport(AVFoundation)
        guard let item = playerItem,
              let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .audible) else {
            return []
        }
        return group.options.enumerated().map { (index, option) in
            LIDAudioTrack(
                id: option.locale?.identifier ?? "\(index)",
                displayName: option.displayName,
                languageCode: option.locale?.languageCode,
                isDefault: group.defaultOption == option
            )
        }
        #else
        return []
        #endif
    }

    public func selectAudioTrack(id: String) {
        #if canImport(AVFoundation)
        guard let item = playerItem,
              let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .audible) else { return }
        if let option = group.options.first(where: { ($0.locale?.identifier ?? "") == id }) {
            item.select(option, in: group)
        }
        #endif
    }

    public func getSubtitleTracks() -> [LIDSubtitleTrack] {
        var tracks: [LIDSubtitleTrack] = [.off]
        #if canImport(AVFoundation)
        guard let item = playerItem,
              let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .legible) else {
            return tracks
        }
        for (index, option) in group.options.enumerated() {
            tracks.append(
                LIDSubtitleTrack(
                    id: option.locale?.identifier ?? "\(index)",
                    displayName: option.displayName,
                    languageCode: option.locale?.languageCode,
                    isExternal: false
                )
            )
        }
        #endif
        return tracks
    }

    public func selectSubtitleTrack(id: String) {
        #if canImport(AVFoundation)
        guard let item = playerItem,
              let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .legible) else { return }
        if id == "off" || id == LIDSubtitleTrack.off.id {
            item.select(nil, in: group)
        } else if let option = group.options.first(where: { ($0.locale?.identifier ?? "") == id }) {
            item.select(option, in: group)
        }
        #endif
    }

    public func setSubtitleDelay(seconds: Double) {
        // AVPlayer applies subtitle timing directly from sample buffers
    }

    public func addExternalSubtitle(url: URL) {
        // External subtitles for AVFoundation are synchronized and rendered via LIDTrackManager cue overlay
    }

    // MARK: - Rendering Presentation

    #if canImport(UIKit)
    public func attachRenderingView(_ view: UIView) {
        // LIDPlayerLayerView / LIDNativePlayerLayerView binds directly to playerLayer.player
    }

    public func detachRenderingView() {
    }
    #endif

    // MARK: - AVPlayer Observers

    #if canImport(AVFoundation)
    private func setupTimeObserver() {
        guard let p = player else { return }
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserverToken = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self else { return }
            let seconds = time.seconds
            if !seconds.isNaN && !seconds.isInfinite {
                self.currentPositionSeconds = seconds
                self.delegate?.engineDidUpdateTime(self, currentSeconds: seconds, durationSeconds: self.durationSeconds)
            }
        }
    }

    private func setupItemObservers(item: AVPlayerItem, source: LIDPlayerSource) {
        statusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] observedItem, _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                PipelineLogger.shared.logPlayer(
                    session: self.activeSessionId,
                    category: "VideoRenderer",
                    message: "AVPlayerItem status -> \(observedItem.status.rawValue), error: \(observedItem.error?.localizedDescription ?? "none"), size: \(Int(observedItem.presentationSize.width))x\(Int(observedItem.presentationSize.height))"
                )
                switch observedItem.status {
                case .readyToPlay:
                    let rawDuration = observedItem.duration.seconds
                    let isLive = observedItem.duration.isIndefinite
                    self.durationSeconds = (rawDuration.isNaN || isLive) ? 0.0 : rawDuration
                    self.playbackState = .playing
                    self.delegate?.engineDidUpdateState(self, state: self.playbackState)
                    self.delegate?.engineDidUpdateTime(self, currentSeconds: self.currentPositionSeconds, durationSeconds: self.durationSeconds)
                case .failed:
                    let err = observedItem.error?.localizedDescription ?? "Playback failed"
                    self.playbackState = .failed(error: err)
                    PipelineLogger.shared.logPlayer(
                        session: self.activeSessionId,
                        category: "PlayerError",
                        message: "AVPlayerItem failed with error: \(err)"
                    )
                    self.delegate?.engineDidFail(self, error: err)
                case .unknown:
                    break
                @unknown default:
                    break
                }
            }
        }

        bufferEmptyObserver = item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] observedItem, _ in
            Task { @MainActor [weak self] in
                guard let self = self, observedItem.isPlaybackBufferEmpty else { return }
                self.playbackState = .buffering(progress: 0.0)
                self.delegate?.engineDidUpdateState(self, state: self.playbackState)
            }
        }

        likelyToKeepUpObserver = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] observedItem, _ in
            Task { @MainActor [weak self] in
                guard let self = self, observedItem.isPlaybackLikelyToKeepUp else { return }
                if case .buffering = self.playbackState {
                    self.playbackState = .playing
                    self.delegate?.engineDidUpdateState(self, state: self.playbackState)
                }
            }
        }

        loadedTimeRangesObserver = item.observe(\.loadedTimeRanges, options: [.new]) { [weak self] observedItem, _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if let range = observedItem.loadedTimeRanges.first?.timeRangeValue {
                    self.bufferedDurationSeconds = range.end.seconds
                    self.delegate?.engineDidUpdateBuffering(self, bufferedSeconds: self.bufferedDurationSeconds)
                }
            }
        }
    }
    #endif
}
