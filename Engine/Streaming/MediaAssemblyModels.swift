import Foundation

/// Media containers supported by the current validated assembly boundary.
public enum MediaAssemblyContainer: String, Codable, Sendable, Equatable {
    case mpegTS
    case fragmentedMP4
}

public enum MediaAssemblyTrackKind: String, Codable, Sendable, Equatable {
    case video
    case audio
}

public enum MediaAssemblySourceLifecycle: String, Codable, Sendable, Equatable {
    case vod
    case live
}

/// Encryption state carried from the validated transfer plan.
///
/// Only clear content is accepted by the 7F.4.1 input contract. The other
/// cases remain explicit so future implementations cannot silently treat
/// encrypted media as ordinary media.
public enum MediaAssemblyEncryption: String, Codable, Sendable, Equatable {
    case clear
    case aes128
    case sampleEncrypted
    case drm
    case unknown
}

public enum MediaAssemblySegmentRole: String, Codable, Sendable, Equatable {
    case initialization
    case media
}

/// Optional metadata needed by a later container-aware assembler.
public struct MediaAssemblyTrackMetadata: Codable, Sendable, Equatable {
    public let codec: String?
    public let timescale: Int64?
    public let duration: TimeInterval?
    public let language: String?
    public let sampleRate: Int?
    public let channelCount: Int?
    public let pixelWidth: Int?
    public let pixelHeight: Int?

    public init(
        codec: String? = nil,
        timescale: Int64? = nil,
        duration: TimeInterval? = nil,
        language: String? = nil,
        sampleRate: Int? = nil,
        channelCount: Int? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil
    ) {
        self.codec = codec
        self.timescale = timescale
        self.duration = duration
        self.language = language
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// A downloaded local file that is ready for assembly validation.
///
/// The descriptor deliberately contains a local file URL only. Remote URLs,
/// request headers, cookies, and signed query parameters belong to the transfer
/// planner/execution boundary and are not persisted in assembly state.
public struct MediaAssemblySegment: Codable, Sendable, Equatable {
    public let fileURL: URL
    public let role: MediaAssemblySegmentRole
    public let order: Int
    public let expectedByteCount: Int64?
    public let actualByteCount: Int64?
    public let isComplete: Bool

    public init(
        fileURL: URL,
        role: MediaAssemblySegmentRole = .media,
        order: Int,
        expectedByteCount: Int64? = nil,
        actualByteCount: Int64? = nil,
        isComplete: Bool = true
    ) {
        self.fileURL = fileURL
        self.role = role
        self.order = order
        self.expectedByteCount = expectedByteCount
        self.actualByteCount = actualByteCount
        self.isComplete = isComplete
    }
}

public struct MediaAssemblyTrack: Codable, Sendable, Equatable {
    public let kind: MediaAssemblyTrackKind
    public let container: MediaAssemblyContainer
    public let metadata: MediaAssemblyTrackMetadata
    public let initializationSegment: MediaAssemblySegment?
    public let mediaSegments: [MediaAssemblySegment]
    public let encryption: MediaAssemblyEncryption

    public init(
        kind: MediaAssemblyTrackKind,
        container: MediaAssemblyContainer,
        metadata: MediaAssemblyTrackMetadata = MediaAssemblyTrackMetadata(),
        initializationSegment: MediaAssemblySegment? = nil,
        mediaSegments: [MediaAssemblySegment],
        encryption: MediaAssemblyEncryption = .clear
    ) {
        self.kind = kind
        self.container = container
        self.metadata = metadata
        self.initializationSegment = initializationSegment
        self.mediaSegments = mediaSegments
        self.encryption = encryption
    }
}

public struct MediaAssemblyRequest: Codable, Sendable, Equatable {
    public let sourceLifecycle: MediaAssemblySourceLifecycle
    public let container: MediaAssemblyContainer
    public let encryption: MediaAssemblyEncryption
    public let tracks: [MediaAssemblyTrack]
    public let destinationURL: URL
    public let temporaryDirectoryURL: URL

    public init(
        sourceLifecycle: MediaAssemblySourceLifecycle = .vod,
        container: MediaAssemblyContainer,
        encryption: MediaAssemblyEncryption = .clear,
        tracks: [MediaAssemblyTrack],
        destinationURL: URL,
        temporaryDirectoryURL: URL? = nil
    ) {
        self.sourceLifecycle = sourceLifecycle
        self.container = container
        self.encryption = encryption
        self.tracks = tracks
        self.destinationURL = destinationURL
        self.temporaryDirectoryURL = temporaryDirectoryURL
            ?? destinationURL.deletingLastPathComponent()
                .appendingPathComponent(".media-assembly", isDirectory: true)
    }
}

public struct MediaAssemblyValidationReport: Codable, Sendable, Equatable {
    public let container: MediaAssemblyContainer
    public let trackCount: Int
    public let mediaSegmentCount: Int
    public let totalInputBytes: Int64?
    public let isReadyForAssembly: Bool

    public init(
        container: MediaAssemblyContainer,
        trackCount: Int,
        mediaSegmentCount: Int,
        totalInputBytes: Int64?,
        isReadyForAssembly: Bool = true
    ) {
        self.container = container
        self.trackCount = trackCount
        self.mediaSegmentCount = mediaSegmentCount
        self.totalInputBytes = totalInputBytes
        self.isReadyForAssembly = isReadyForAssembly
    }
}

/// A successful result is constructible only after the assembler has published
/// and validated the final output. The model intentionally contains no
/// download state or browser credentials.
public struct MediaAssemblyOutput: Codable, Sendable, Equatable {
    public let destinationURL: URL
    public let container: MediaAssemblyContainer
    public let trackCount: Int
    public let byteCount: Int64
    public let validation: MediaAssemblyValidationReport

    public init(
        destinationURL: URL,
        container: MediaAssemblyContainer,
        trackCount: Int,
        byteCount: Int64,
        validation: MediaAssemblyValidationReport
    ) {
        self.destinationURL = destinationURL
        self.container = container
        self.trackCount = trackCount
        self.byteCount = byteCount
        self.validation = validation
    }
}

public enum MediaAssemblyError: Error, LocalizedError, Equatable, Sendable {
    case liveSourceNotSupported
    case encryptedMediaNotSupported(MediaAssemblyEncryption)
    case noTracks
    case duplicateTrack(MediaAssemblyTrackKind)
    case unsupportedContainer(MediaAssemblyContainer)
    case mixedTrackContainers
    case invalidDestinationURL
    case invalidTemporaryDirectoryURL
    case invalidTrackMetadata(MediaAssemblyTrackKind)
    case missingInitializationSegment(MediaAssemblyTrackKind)
    case noMediaSegments(MediaAssemblyTrackKind)
    case invalidSegmentRole(MediaAssemblyTrackKind)
    case invalidSegmentOrder(MediaAssemblyTrackKind)
    case incompleteSegment(MediaAssemblyTrackKind, order: Int)
    case invalidSegmentSize(MediaAssemblyTrackKind, order: Int)
    case invalidSegmentFileURL(MediaAssemblyTrackKind, order: Int)
    case multipleTracksNotSupported
    case invalidMediaData(MediaAssemblyContainer)
    case fileOperationFailed

    public var errorDescription: String? {
        switch self {
        case .liveSourceNotSupported:
            return "Live media assembly is not supported; only finite VOD inputs are accepted."
        case .encryptedMediaNotSupported(let encryption):
            return "Media encryption is not supported by the current assembler: \(encryption.rawValue)."
        case .noTracks:
            return "Media assembly requires at least one audio or video track."
        case .duplicateTrack(let kind):
            return "Media assembly contains more than one \(kind.rawValue) track."
        case .unsupportedContainer(let container):
            return "Media container is not supported: \(container.rawValue)."
        case .mixedTrackContainers:
            return "All tracks in an assembly request must use the requested container."
        case .invalidDestinationURL:
            return "Media output destination must be a local file URL."
        case .invalidTemporaryDirectoryURL:
            return "Media assembly temporary storage must be a local file URL."
        case .invalidTrackMetadata(let kind):
            return "Media track metadata is invalid for the \(kind.rawValue) track."
        case .missingInitializationSegment(let kind):
            return "The fragmented MP4 \(kind.rawValue) track is missing its initialization segment."
        case .noMediaSegments(let kind):
            return "Media assembly requires at least one segment for the \(kind.rawValue) track."
        case .invalidSegmentRole(let kind):
            return "A \(kind.rawValue) track contains a segment with an invalid role."
        case .invalidSegmentOrder(let kind):
            return "Media segments for the \(kind.rawValue) track are not contiguous and ordered."
        case .incompleteSegment(let kind, let order):
            return "The \(kind.rawValue) segment at order \(order) is incomplete."
        case .invalidSegmentSize(let kind, let order):
            return "The \(kind.rawValue) segment at order \(order) has invalid or mismatched size metadata."
        case .invalidSegmentFileURL(let kind, let order):
            return "The \(kind.rawValue) segment at order \(order) does not identify a local file."
        case .multipleTracksNotSupported:
            return "This reconstruction path supports one compatible media track at a time."
        case .invalidMediaData(let container):
            return "Downloaded media does not contain a valid \(container.rawValue) structure."
        case .fileOperationFailed:
            return "Media assembly could not safely create or publish the output file."
        }
    }
}
