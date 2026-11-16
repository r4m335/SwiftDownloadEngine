import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Source types supported by the LID Native Playback Engine.
public enum LIDPlayerSource: Equatable, Sendable {
    /// Fully downloaded local media file on disk.
    case localFile(url: URL, title: String)
    /// Direct HTTP/HTTPS media URL with custom headers (e.g. cookies, User-Agent, Authorization).
    case networkStream(url: URL, headers: [String: String], title: String)
    /// Adaptive HLS manifest stream (.m3u8) with optional initial variant quality preferences and request context.
    case hlsStream(url: URL, variantPreferences: HLSVariantSelectionPreferences?, title: String, requestContext: BrowserRequestContext? = nil)
    /// MPEG-DASH manifest stream (.mpd) with optional selected representation and request context.
    case dashStream(manifestURL: URL, selectedRepresentationID: String? = nil, title: String, requestContext: BrowserRequestContext? = nil)
    /// Progressive partial download file actively growing on disk.
    case partialDownload(fileURL: URL, totalExpectedBytes: Int64?, title: String)
    /// BitTorrent sequential download stream identified by info-hash and file index.
    case torrentSwarm(infoHash: String, fileIndex: Int, title: String)

    public var title: String {
        switch self {
        case .localFile(_, let title),
             .networkStream(_, _, let title),
             .hlsStream(_, _, let title, _),
             .dashStream(_, _, let title, _),
             .partialDownload(_, _, let title),
             .torrentSwarm(_, _, let title):
            return title
        }
    }

    public var url: URL? {
        switch self {
        case .localFile(let url, _),
             .networkStream(let url, _, _),
             .partialDownload(let url, _, _):
            return url
        case .hlsStream(let url, let variantPreferences, _, _):
            return variantPreferences?.exactURI ?? url
        case .dashStream(let manifestURL, _, _, _):
            return manifestURL
        case .torrentSwarm(let infoHash, let fileIndex, _):
            return URL(string: "lidtorrent://\(infoHash)/\(fileIndex)")
        }
    }

    /// Stable unique media identifier used for history tracking and resume points.
    public var mediaIdentifier: String {
        switch self {
        case .localFile(let url, _):
            return url.standardizedFileURL.path
        case .networkStream(let url, _, _):
            return url.absoluteString
        case .hlsStream(let url, let variantPreferences, _, _):
            if let exact = variantPreferences?.exactURI {
                return exact.absoluteString
            }
            return url.absoluteString
        case .dashStream(let manifestURL, let repID, _, _):
            if let rep = repID, !rep.isEmpty {
                return "\(manifestURL.absoluteString)#\(rep)"
            }
            return manifestURL.absoluteString
        case .partialDownload(let fileURL, _, _):
            return fileURL.standardizedFileURL.path
        case .torrentSwarm(let infoHash, let fileIndex, _):
            return "torrent://\(infoHash.lowercased())/\(fileIndex)"
        }
    }

    public var requestContext: BrowserRequestContext? {
        switch self {
        case .hlsStream(_, _, _, let context):
            return context
        case .dashStream(_, _, _, let context):
            return context
        case .localFile, .networkStream, .partialDownload, .torrentSwarm:
            return nil
        }
    }

    public var isStreaming: Bool {
        switch self {
        case .networkStream, .hlsStream, .dashStream, .torrentSwarm:
            return true
        case .localFile, .partialDownload:
            return false
        }
    }

    /// Factory converting a discovered `WebpageResource` into an appropriate native `LIDPlayerSource`
    /// preserving variant selection preferences, origin authentication cookies, User-Agent, and Referer headers.
    public static func make(from resource: WebpageResource, title: String? = nil) -> LIDPlayerSource? {
        let displayTitle: String
        if let custom = title?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            displayTitle = custom
        } else if !resource.suggestedFilename.isEmpty {
            displayTitle = resource.suggestedFilename
        } else if !resource.title.isEmpty {
            displayTitle = resource.title
        } else {
            displayTitle = "Media Stream"
        }

        if resource.isStreamingManifest {
            let ext = resource.url.pathExtension.lowercased()
            let mime = resource.mimeType?.lowercased() ?? ""
            if ext == "mpd" || mime.contains("dash") {
                return .dashStream(
                    manifestURL: resource.url,
                    selectedRepresentationID: resource.dashVideoRepresentationID,
                    title: displayTitle,
                    requestContext: resource.requestContext
                )
            } else {
                return .hlsStream(
                    url: resource.url,
                    variantPreferences: resource.hlsVariantPreferences,
                    title: displayTitle,
                    requestContext: resource.requestContext
                )
            }
        }

        if resource.resourceType == .video || resource.resourceType == .audio {
            let headers = resource.requestContext?.effectiveHeaders(for: resource.url) ?? [:]
            return .networkStream(url: resource.url, headers: headers, title: displayTitle)
        }

        return nil
    }
}

/// Dynamic playback error reporting categorized issues with actionable diagnostics.
public enum LIDPlaybackError: LocalizedError, Equatable, Sendable {
    case unsupportedSourceURL(String)
    case avFoundationUnavailable
    case drmProtectedDASHUnsupported(details: String)
    case dashManifestInvalid(String)
    case torrentNotFound(String)
    case torrentFileNotFound(infoHash: String, fileIndex: Int)
    case torrentStreamingTimeout(infoHash: String, pieceIndex: Int)
    case assetLoadingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSourceURL(let msg):
            return "Unsupported media source: \(msg)"
        case .avFoundationUnavailable:
            return "AVFoundation is not available on this platform."
        case .drmProtectedDASHUnsupported(let details):
            return "DRM-protected DASH stream is unsupported (Widevine/PlayReady detected): \(details)"
        case .dashManifestInvalid(let reason):
            return "Invalid DASH manifest: \(reason)"
        case .torrentNotFound(let hash):
            return "Torrent transfer not found for info-hash: \(hash)"
        case .torrentFileNotFound(let hash, let idx):
            return "Torrent file index \(idx) not found in torrent \(hash)."
        case .torrentStreamingTimeout(let hash, let piece):
            return "Torrent streaming timed out waiting for piece \(piece) in torrent \(hash)."
        case .assetLoadingFailed(let msg):
            return "Asset loading failed: \(msg)"
        }
    }
}

/// Contextual metadata for live streams, DVR windowing, DRM, and BitTorrent swarms.
public struct LIDStreamContextInfo: Equatable, Sendable {
    public var isLive: Bool
    public var isDVRSeekable: Bool
    public var dvrWindowDurationSeconds: Double
    public var currentBitrate: Int64?
    public var resolution: String?
    public var swarmDownloadSpeed: Double?
    public var swarmUploadSpeed: Double?
    public var swarmConnectedPeers: Int?
    public var swarmActiveSeeds: Int?
    public var swarmProgressFraction: Double?
    public var drmProtectionDetected: Bool
    public var drmScheme: String?

    public init(
        isLive: Bool = false,
        isDVRSeekable: Bool = false,
        dvrWindowDurationSeconds: Double = 0.0,
        currentBitrate: Int64? = nil,
        resolution: String? = nil,
        swarmDownloadSpeed: Double? = nil,
        swarmUploadSpeed: Double? = nil,
        swarmConnectedPeers: Int? = nil,
        swarmActiveSeeds: Int? = nil,
        swarmProgressFraction: Double? = nil,
        drmProtectionDetected: Bool = false,
        drmScheme: String? = nil
    ) {
        self.isLive = isLive
        self.isDVRSeekable = isDVRSeekable
        self.dvrWindowDurationSeconds = dvrWindowDurationSeconds
        self.currentBitrate = currentBitrate
        self.resolution = resolution
        self.swarmDownloadSpeed = swarmDownloadSpeed
        self.swarmUploadSpeed = swarmUploadSpeed
        self.swarmConnectedPeers = swarmConnectedPeers
        self.swarmActiveSeeds = swarmActiveSeeds
        self.swarmProgressFraction = swarmProgressFraction
        self.drmProtectionDetected = drmProtectionDetected
        self.drmScheme = drmScheme
    }

    public static let empty = LIDStreamContextInfo()
}

/// Dynamic playback state of the LID Native Playback Engine.
public enum LIDPlaybackState: Equatable, Sendable {
    case idle
    case loading
    case buffering(progress: Double?)
    case playing
    case paused
    case seeking(targetSeconds: Double)
    case failed(error: String)
    case ended

    public var isPlaying: Bool {
        if case .playing = self { return true }
        return false
    }

    public var isPaused: Bool {
        if case .paused = self { return true }
        return false
    }

    public var isBuffering: Bool {
        if case .buffering = self { return true }
        return false
    }

    public var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    public var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    public var isEnded: Bool {
        if case .ended = self { return true }
        return false
    }

    public var errorMessage: String? {
        if case .failed(let err) = self { return err }
        return nil
    }
}

/// Metadata extracted from active media asset.
public struct LIDMediaMetadata: Equatable, Sendable {
    public let title: String
    public let durationSeconds: Double
    public let naturalWidth: Double?
    public let naturalHeight: Double?
    public let videoCodec: String?
    public let audioCodec: String?
    public let estimatedBitrate: Int64?
    public let isLiveStream: Bool
    public let audioTrackNames: [String]
    public let subtitleTrackNames: [String]

    public init(
        title: String,
        durationSeconds: Double = 0.0,
        naturalWidth: Double? = nil,
        naturalHeight: Double? = nil,
        videoCodec: String? = nil,
        audioCodec: String? = nil,
        estimatedBitrate: Int64? = nil,
        isLiveStream: Bool = false,
        audioTrackNames: [String] = [],
        subtitleTrackNames: [String] = []
    ) {
        self.title = title
        self.durationSeconds = durationSeconds
        self.naturalWidth = naturalWidth
        self.naturalHeight = naturalHeight
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.estimatedBitrate = estimatedBitrate
        self.isLiveStream = isLiveStream
        self.audioTrackNames = audioTrackNames
        self.subtitleTrackNames = subtitleTrackNames
    }

    public static let empty = LIDMediaMetadata(title: "")
}

/// Playback speed factors supported by the player with audio pitch correction.
public enum LIDPlaybackSpeed: Double, CaseIterable, Sendable {
    case speed0_25 = 0.25
    case speed0_50 = 0.50
    case speed0_75 = 0.75
    case speed1_00 = 1.00
    case speed1_25 = 1.25
    case speed1_50 = 1.50
    case speed2_00 = 2.00
    case speed4_00 = 4.00

    public var label: String {
        switch self {
        case .speed0_25: return "0.25×"
        case .speed0_50: return "0.5×"
        case .speed0_75: return "0.75×"
        case .speed1_00: return "1.0×"
        case .speed1_25: return "1.25×"
        case .speed1_50: return "1.5×"
        case .speed2_00: return "2.0×"
        case .speed4_00: return "4.0×"
        }
    }

    public var rate: Float {
        Float(rawValue)
    }

    /// Finds the closest discrete preset corresponding to an arbitrary numeric playback rate.
    public static func fromRate(_ rate: Double) -> LIDPlaybackSpeed {
        let sorted = allCases.sorted { abs($0.rawValue - rate) < abs($1.rawValue - rate) }
        return sorted.first ?? .speed1_00
    }
}

/// Video aspect ratio display modes.
public enum LIDAspectRatio: String, CaseIterable, Sendable, Codable {
    case original = "Original"
    case fit16x9 = "16:9"
    case fit4x3 = "4:3"
    case fill = "Fill"
    case stretch = "Stretch"

    public var displayName: String { rawValue }
}

/// Playback history and resume record persisted across app restarts.
public struct LIDPlaybackRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String { mediaIdentifier }
    public let mediaIdentifier: String
    public let title: String
    public let lastPositionSeconds: Double
    public let durationSeconds: Double
    public let lastPlayedAt: Date
    public let isCompleted: Bool

    public var progressFraction: Double {
        guard durationSeconds > 0 else { return 0 }
        return min(max(lastPositionSeconds / durationSeconds, 0.0), 1.0)
    }

    public init(
        mediaIdentifier: String,
        title: String,
        lastPositionSeconds: Double,
        durationSeconds: Double,
        lastPlayedAt: Date = Date(),
        isCompleted: Bool = false
    ) {
        self.mediaIdentifier = mediaIdentifier
        self.title = title
        self.lastPositionSeconds = lastPositionSeconds
        self.durationSeconds = durationSeconds
        self.lastPlayedAt = lastPlayedAt
        self.isCompleted = isCompleted
    }
}

extension URL {
    /// Determines whether the URL refers to a playable audio or video file based on extension.
    public var isPlayableMedia: Bool {
        let ext = pathExtension.lowercased()
        return isVideoMedia || isAudioMedia || ext == "m3u8"
    }

    /// Whether this URL points to a video container format.
    public var isVideoMedia: Bool {
        let ext = pathExtension.lowercased()
        return ["mp4", "m4v", "mov", "mkv", "webm", "avi", "3gp", "ts", "m3u8", "flv", "wmv", "asf", "mpg", "mpeg", "vob", "ogv"].contains(ext)
    }

    /// Whether this URL points to an audio container format.
    public var isAudioMedia: Bool {
        let ext = pathExtension.lowercased()
        return ["mp3", "m4a", "aac", "wav", "flac", "ogg", "opus", "wma", "aiff"].contains(ext)
    }
}

/// Category of playable media in the player library.
public enum LIDMediaType: String, Codable, CaseIterable, Sendable {
    case all = "All"
    case video = "Video"
    case audio = "Audio"
}

/// Item representing a discovered media file in the user's library.
public struct LIDMediaItem: Identifiable, Equatable, Hashable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public var title: String
    public let fileSize: Int64
    public let mediaType: LIDMediaType
    public let dateAdded: Date
    public var durationSeconds: Double?
    public var resolution: String?
    public var videoCodec: String?
    public var audioCodec: String?
    public var isFavorite: Bool
    public var lastPositionSeconds: Double
    public var progressFraction: Double
    public var isCompleted: Bool

    public init(
        url: URL,
        title: String? = nil,
        fileSize: Int64 = 0,
        mediaType: LIDMediaType = .video,
        dateAdded: Date = Date(),
        durationSeconds: Double? = nil,
        resolution: String? = nil,
        videoCodec: String? = nil,
        audioCodec: String? = nil,
        isFavorite: Bool = false,
        lastPositionSeconds: Double = 0.0,
        progressFraction: Double = 0.0,
        isCompleted: Bool = false
    ) {
        self.url = url
        self.title = title ?? url.deletingPathExtension().lastPathComponent
        self.fileSize = fileSize
        self.mediaType = mediaType
        self.dateAdded = dateAdded
        self.durationSeconds = durationSeconds
        self.resolution = resolution
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.isFavorite = isFavorite
        self.lastPositionSeconds = lastPositionSeconds
        self.progressFraction = progressFraction
        self.isCompleted = isCompleted
    }
}

/// User-created playlist of media files.
public struct LIDPlaylist: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var itemPaths: [String]
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        itemPaths: [String] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.itemPaths = itemPaths
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Playback repetition mode for playlists and queue.
public enum LIDRepeatMode: String, CaseIterable, Sendable {
    case off = "Off"
    case all = "Repeat All"
    case one = "Repeat One"
}
