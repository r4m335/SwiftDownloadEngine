import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Identifies the underlying decoding and rendering engine powering media playback.
public enum LIDMediaEngineBackendType: String, Sendable, CaseIterable, Codable {
    /// VideoLAN VLCKit (libVLC) multi-format decoding engine.
    case vlcKit = "VLCKit"
    /// Apple AVFoundation hardware-accelerated playback engine.
    case avFoundation = "AVFoundation"

    public var displayName: String {
        switch self {
        case .vlcKit:
            return "VLCKit (libVLC)"
        case .avFoundation:
            return "AVFoundation (Native)"
        }
    }
}

/// Delegate protocol used by concrete media engine backends to dispatch normalized events
/// to the unified playback controller.
@MainActor
public protocol LIDMediaEngineDelegate: AnyObject {
    /// Dispatched when the engine's playback state changes.
    func engineDidUpdateState(_ engine: LIDMediaEngineProtocol, state: LIDPlaybackState)
    /// Dispatched periodically as media playback advances.
    func engineDidUpdateTime(_ engine: LIDMediaEngineProtocol, currentSeconds: Double, durationSeconds: Double)
    /// Dispatched when buffering progress or loaded time ranges update.
    func engineDidUpdateBuffering(_ engine: LIDMediaEngineProtocol, bufferedSeconds: Double)
    /// Dispatched when stream/media metadata is parsed.
    func engineDidUpdateMetadata(_ engine: LIDMediaEngineProtocol, metadata: LIDMediaMetadata)
    /// Dispatched when the engine encounters an unrecoverable failure.
    func engineDidFail(_ engine: LIDMediaEngineProtocol, error: String)
}

/// Abstract media engine protocol defining standard playback operations, track selection,
/// seeking, and rendering layer management across heterogeneous backends (VLCKit & AVFoundation).
@MainActor
public protocol LIDMediaEngineProtocol: AnyObject {
    /// Identifies whether this backend is VLCKit or AVFoundation.
    var backendType: LIDMediaEngineBackendType { get }

    /// Event delegate receiving normalized playback updates.
    var delegate: LIDMediaEngineDelegate? { get set }

    /// Current normalized playback state.
    var playbackState: LIDPlaybackState { get }

    /// Current playback position in seconds.
    var currentPositionSeconds: Double { get }

    /// Total media duration in seconds (or 0 for indefinite/live streams).
    var durationSeconds: Double { get }

    /// Total buffered media duration in seconds.
    var bufferedDurationSeconds: Double { get }

    /// Playback rate / speed.
    var playbackSpeed: LIDPlaybackSpeed { get set }

    /// Audio volume in the range [0.0, 1.0].
    var volume: Float { get set }

    /// Mute state.
    var isMuted: Bool { get set }

    /// Indicates whether the active backend natively supports Picture-in-Picture.
    var supportsPictureInPicture: Bool { get }

    /// Sets the video aspect ratio mode (e.g. original, 16:9, 4:3, fill, stretch).
    func setAspectRatio(_ ratio: LIDAspectRatio)

    /// Loads a media source into the engine.
    func load(source: LIDPlayerSource, autoPlay: Bool)

    /// Resumes or starts playback.
    func play()

    /// Pauses playback.
    func pause()

    /// Halts playback and unloads the media pipeline.
    func stop()

    /// Seeks to the specified position in seconds.
    func seek(to seconds: Double)

    // MARK: - Track Management

    /// Returns all embedded and external audio tracks discovered by this backend.
    func getAudioTracks() -> [LIDAudioTrack]

    /// Selects an audio track by its identifier.
    func selectAudioTrack(id: String)

    /// Returns all embedded and external subtitle tracks discovered by this backend.
    func getSubtitleTracks() -> [LIDSubtitleTrack]

    /// Selects a subtitle track by its identifier.
    func selectSubtitleTrack(id: String)

    /// Adjusts subtitle synchronization offset in seconds.
    func setSubtitleDelay(seconds: Double)

    /// Registers an external subtitle file (SRT, VTT) with the media engine.
    func addExternalSubtitle(url: URL)

    // MARK: - Rendering Presentation

    #if canImport(UIKit)
    /// Attaches the native rendering view to the backend's video output pipeline.
    func attachRenderingView(_ view: UIView)

    /// Detaches the rendering view when tearing down or switching backends.
    func detachRenderingView()
    #endif
}
