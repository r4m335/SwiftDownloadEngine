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

/// Discrete stages of the media reconstruction and assembly pipeline.
public enum MediaAssemblyState: String, Codable, Sendable, Equatable {
    /// All required segments exist on disk and have passed pre-assembly validation.
    case segmentsDownloaded
    /// Bytes have been combined or muxed into a target container file.
    case assemblyCompleted
    /// Container syntax, box hierarchy/packet structure, and media tracks have been verified.
    case outputValidated
    /// Output failed post-assembly validation and was quarantined.
    case validationFailed
}

/// Metadata recorded when failed assembly or muxing inputs are quarantined.
public struct MediaQuarantineRecord: Codable, Sendable, Equatable {
    public let timestamp: String
    public let reason: String
    public let destinationURL: String
    public let container: String
    public let expectedTrackKinds: [String]
    public let quarantinedFiles: [String]
    public let validationDetails: String?

    public init(
        timestamp: String,
        reason: String,
        destinationURL: String,
        container: String,
        expectedTrackKinds: [String],
        quarantinedFiles: [String],
        validationDetails: String? = nil
    ) {
        self.timestamp = timestamp
        self.reason = reason
        self.destinationURL = destinationURL
        self.container = container
        self.expectedTrackKinds = expectedTrackKinds
        self.quarantinedFiles = quarantinedFiles
        self.validationDetails = validationDetails
    }
}

public struct MediaAssemblyValidationReport: Codable, Sendable, Equatable {
    public let container: MediaAssemblyContainer
    public let trackCount: Int
    public let mediaSegmentCount: Int
    public let totalInputBytes: Int64?
    public let isReadyForAssembly: Bool
    public let isStructurallyValid: Bool
    public let isPlayableConfirmed: Bool?
    public let validationDetails: String?
    public let state: MediaAssemblyState

    public init(
        container: MediaAssemblyContainer,
        trackCount: Int,
        mediaSegmentCount: Int,
        totalInputBytes: Int64?,
        isReadyForAssembly: Bool = true,
        isStructurallyValid: Bool = true,
        isPlayableConfirmed: Bool? = nil,
        validationDetails: String? = nil,
        state: MediaAssemblyState = .assemblyCompleted
    ) {
        self.container = container
        self.trackCount = trackCount
        self.mediaSegmentCount = mediaSegmentCount
        self.totalInputBytes = totalInputBytes
        self.isReadyForAssembly = isReadyForAssembly
        self.isStructurallyValid = isStructurallyValid
        self.isPlayableConfirmed = isPlayableConfirmed
        self.validationDetails = validationDetails
        self.state = state
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
    case muxingUnavailable
    case muxingFailed
    case assetWriterFailed(reason: String)
    case videoTrackNotFound
    case audioTrackNotFound
    case readerInitializationFailed(reason: String)
    case writerInitializationFailed(reason: String)
    case sampleBufferAppendFailed(reason: String)
    case invalidPresentationTimestamp(reason: String)
    case mediaAssemblyTimedOut
    case finalValidationFailed(reason: String)
    case unplayableOutput(reason: String)
    case noMediaTracksIdentified
    case incompleteMultiTrackAssembly(expectedTracks: Int, availableTracks: Int)
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
            return "This reconstruction path cannot combine the requested media tracks."
        case .muxingUnavailable:
            return "This platform does not provide the media muxing support required for separate tracks."
        case .muxingFailed:
            return "Separate media tracks could not be muxed into a validated output."
        case .assetWriterFailed(let reason):
            return "Separate media tracks could not be muxed into a validated output: \(reason)"
        case .videoTrackNotFound:
            return "Video track not found in source media."
        case .audioTrackNotFound:
            return "Audio track not found in source media."
        case .readerInitializationFailed(let reason):
            return "AVAssetReader initialization failed: \(reason)"
        case .writerInitializationFailed(let reason):
            return "AVAssetWriter initialization failed: \(reason)"
        case .sampleBufferAppendFailed(let reason):
            return "Sample buffer append failed: \(reason)"
        case .invalidPresentationTimestamp(let reason):
            return "Invalid presentation timestamp: \(reason)"
        case .mediaAssemblyTimedOut:
            return "Media assembly timed out."
        case .finalValidationFailed(let reason):
            return "Final media validation failed: \(reason)"
        case .unplayableOutput(let reason):
            return "Output media cannot be played: \(reason)"
        case .noMediaTracksIdentified:
            return "No valid video or audio media tracks were identified in the output file."
        case .incompleteMultiTrackAssembly(let expected, let available):
            return "Multi-track assembly was incomplete: expected \(expected) tracks, but only \(available) tracks were produced."
        case .invalidMediaData(let container):
            return "Downloaded media does not contain a valid \(container.rawValue) structure."
        case .fileOperationFailed:
            return "Media assembly could not safely create or publish the output file."
        }
    }
}
