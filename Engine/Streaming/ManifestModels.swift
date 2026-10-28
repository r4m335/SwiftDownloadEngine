import Foundation

/// Hard limits applied to manifest inspection and parsing.
public struct ManifestParsingLimits: Sendable, Equatable {
    public let maxBytes: Int
    public let maxElements: Int
    public let maxNestingDepth: Int
    public let maxParsingDuration: TimeInterval

    public init(
        maxBytes: Int = 1_048_576,
        maxElements: Int = 10_000,
        maxNestingDepth: Int = 64,
        maxParsingDuration: TimeInterval = 2.0
    ) {
        self.maxBytes = max(1, maxBytes)
        self.maxElements = max(1, maxElements)
        self.maxNestingDepth = max(1, maxNestingDepth)
        self.maxParsingDuration = max(0.01, maxParsingDuration)
    }

    public static let `default` = ManifestParsingLimits()
}

public enum StreamingManifestKind: String, Codable, Sendable, Equatable {
    case hls
    case dash
    case unknown
    case unsupported
}

public enum ManifestEvidence: String, Codable, Sendable, Equatable {
    case content
    case mimeType
    case urlExtension
    case conflictingMetadata
    case insufficient
}

public struct StreamingManifestClassification: Codable, Sendable, Equatable {
    public let kind: StreamingManifestKind
    public let evidence: ManifestEvidence
    public let reason: String

    public init(kind: StreamingManifestKind, evidence: ManifestEvidence, reason: String) {
        self.kind = kind
        self.evidence = evidence
        self.reason = reason
    }

    public var isManifest: Bool {
        kind == .hls || kind == .dash
    }
}

public enum ManifestParserError: Error, LocalizedError, Codable, Sendable, Equatable {
    case inputTooLarge(limit: Int)
    case parsingTimedOut
    case malformed(reason: String)
    case unsupported(reason: String)
    case invalidURL
    case nestingLimitExceeded(limit: Int)
    case elementLimitExceeded(limit: Int)

    public var errorDescription: String? {
        switch self {
        case .inputTooLarge(let limit):
            return "Manifest exceeds the maximum supported size of \(limit) bytes."
        case .parsingTimedOut:
            return "Manifest parsing exceeded the allowed time limit."
        case .malformed(let reason):
            return "Malformed streaming manifest: \(reason)"
        case .unsupported(let reason):
            return "Unsupported streaming manifest: \(reason)"
        case .invalidURL:
            return "Manifest contains an invalid or unsupported URL."
        case .nestingLimitExceeded(let limit):
            return "Manifest XML nesting exceeds the safety limit of \(limit)."
        case .elementLimitExceeded(let limit):
            return "Manifest XML contains more than the safety limit of \(limit) elements."
        }
    }
}

public enum HLSPlaylistType: String, Codable, Sendable, Equatable {
    case master
    case media
}

public enum HLSPlaylistLifecycle: String, Codable, Sendable, Equatable {
    case vod
    case event
    case live

    public var isFinite: Bool { self == .vod }
}

public struct HLSResolution: Codable, Sendable, Equatable, Hashable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public struct HLSByteRange: Codable, Sendable, Equatable, Hashable {
    public let length: Int64
    public let offset: Int64?

    public init(length: Int64, offset: Int64? = nil) {
        self.length = length
        self.offset = offset
    }
}

public struct HLSEncryption: Codable, Sendable, Equatable {
    public let method: String
    public let keyURL: URL?
    public let iv: String?
    public let keyFormat: String?
    public let keyFormatVersions: String?

    public init(
        method: String,
        keyURL: URL? = nil,
        iv: String? = nil,
        keyFormat: String? = nil,
        keyFormatVersions: String? = nil
    ) {
        self.method = method
        self.keyURL = keyURL
        self.iv = iv
        self.keyFormat = keyFormat
        self.keyFormatVersions = keyFormatVersions
    }

    public var classification: HLSKeyClassification {
        let normalizedMethod = method.uppercased()
        let normalizedFormat = keyFormat?.lowercased() ?? "identity"
        if normalizedMethod == "NONE" { return .clear }
        if normalizedMethod == "AES-128" && normalizedFormat == "identity" { return .aes128 }
        if normalizedMethod == "SAMPLE-AES" || normalizedMethod == "SAMPLE-AES-CTR" {
            return .sampleEncrypted
        }
        return .unsupported
    }
}

public enum HLSKeyClassification: String, Codable, Sendable, Equatable, Hashable {
    case clear
    case aes128
    case sampleEncrypted
    case unsupported
}

public struct HLSInitializationMap: Codable, Sendable, Equatable {
    public let uri: URL
    public let byteRange: HLSByteRange?

    public init(uri: URL, byteRange: HLSByteRange? = nil) {
        self.uri = uri
        self.byteRange = byteRange
    }
}

public struct HLSVariant: Codable, Sendable, Equatable {
    public let uri: URL
    public let bandwidth: Int
    public let averageBandwidth: Int?
    public let resolution: HLSResolution?
    public let codecs: String?
    public let frameRate: Double?
    public let audioGroup: String?
    public let videoGroup: String?
    public let subtitlesGroup: String?

    public init(
        uri: URL,
        bandwidth: Int,
        averageBandwidth: Int? = nil,
        resolution: HLSResolution? = nil,
        codecs: String? = nil,
        frameRate: Double? = nil,
        audioGroup: String? = nil,
        videoGroup: String? = nil,
        subtitlesGroup: String? = nil
    ) {
        self.uri = uri
        self.bandwidth = bandwidth
        self.averageBandwidth = averageBandwidth
        self.resolution = resolution
        self.codecs = codecs
        self.frameRate = frameRate
        self.audioGroup = audioGroup
        self.videoGroup = videoGroup
        self.subtitlesGroup = subtitlesGroup
    }
}

public struct HLSRendition: Codable, Sendable, Equatable {
    public let type: String
    public let groupID: String
    public let name: String
    public let uri: URL?
    public let language: String?
    public let isDefault: Bool
    public let isAutoSelect: Bool

    public init(
        type: String,
        groupID: String,
        name: String,
        uri: URL? = nil,
        language: String? = nil,
        isDefault: Bool = false,
        isAutoSelect: Bool = false
    ) {
        self.type = type
        self.groupID = groupID
        self.name = name
        self.uri = uri
        self.language = language
        self.isDefault = isDefault
        self.isAutoSelect = isAutoSelect
    }
}

public struct HLSMediaSegment: Codable, Sendable, Equatable {
    public let sequenceNumber: Int64
    public let uri: URL
    public let duration: Double
    public let title: String?
    public let byteRange: HLSByteRange?
    public let initializationMap: HLSInitializationMap?
    public let encryption: HLSEncryption?
    public let isDiscontinuity: Bool
    public let programDateTime: Date?

    public init(
        sequenceNumber: Int64,
        uri: URL,
        duration: Double,
        title: String? = nil,
        byteRange: HLSByteRange? = nil,
        initializationMap: HLSInitializationMap? = nil,
        encryption: HLSEncryption? = nil,
        isDiscontinuity: Bool = false,
        programDateTime: Date? = nil
    ) {
        self.sequenceNumber = sequenceNumber
        self.uri = uri
        self.duration = duration
        self.title = title
        self.byteRange = byteRange
        self.initializationMap = initializationMap
        self.encryption = encryption
        self.isDiscontinuity = isDiscontinuity
        self.programDateTime = programDateTime
    }
}

public struct HLSManifest: Codable, Sendable, Equatable {
    public let url: URL
    public let playlistType: HLSPlaylistType
    public let lifecycle: HLSPlaylistLifecycle
    public let version: Int?
    public let independentSegments: Bool
    public let variants: [HLSVariant]
    public let renditions: [HLSRendition]
    public let segments: [HLSMediaSegment]
    public let encryption: HLSKeyClassification

    public init(
        url: URL,
        playlistType: HLSPlaylistType,
        lifecycle: HLSPlaylistLifecycle,
        version: Int? = nil,
        independentSegments: Bool = false,
        variants: [HLSVariant] = [],
        renditions: [HLSRendition] = [],
        segments: [HLSMediaSegment] = [],
        encryption: HLSKeyClassification = .clear
    ) {
        self.url = url
        self.playlistType = playlistType
        self.lifecycle = lifecycle
        self.version = version
        self.independentSegments = independentSegments
        self.variants = variants
        self.renditions = renditions
        self.segments = segments
        self.encryption = encryption
    }

    /// All renditions with TYPE=SUBTITLES extracted from the manifest.
    public var subtitleRenditions: [HLSRendition] {
        renditions.filter { $0.type.uppercased() == "SUBTITLES" }
    }

    /// All subtitle URIs declared in the manifest.
    public var subtitleURIs: [URL] {
        subtitleRenditions.compactMap { $0.uri }
    }
}

public enum DASHPresentationType: String, Codable, Sendable, Equatable {
    case staticPresentation
    case dynamicPresentation
}

public struct DASHSegmentTimelineEntry: Codable, Sendable, Equatable {
    public let start: Int64?
    public let duration: Int64
    public let repeatCount: Int

    public init(start: Int64? = nil, duration: Int64, repeatCount: Int = 0) {
        self.start = start
        self.duration = duration
        self.repeatCount = repeatCount
    }
}

public struct DASHSegmentTemplate: Codable, Sendable, Equatable {
    public let media: String?
    public let initialization: String?
    public let timescale: Int64
    public let presentationTimeOffset: Int64
    public let startNumber: Int64
    public let duration: Int64?
    public let timeline: [DASHSegmentTimelineEntry]

    public init(
        media: String? = nil,
        initialization: String? = nil,
        timescale: Int64 = 1,
        presentationTimeOffset: Int64 = 0,
        startNumber: Int64 = 1,
        duration: Int64? = nil,
        timeline: [DASHSegmentTimelineEntry] = []
    ) {
        self.media = media
        self.initialization = initialization
        self.timescale = timescale
        self.presentationTimeOffset = presentationTimeOffset
        self.startNumber = startNumber
        self.duration = duration
        self.timeline = timeline
    }
}

public struct DASHInitialization: Codable, Sendable, Equatable {
    public let sourceURL: URL?
    public let range: String?

    public init(sourceURL: URL? = nil, range: String? = nil) {
        self.sourceURL = sourceURL
        self.range = range
    }
}

public struct DASHSegmentURL: Codable, Sendable, Equatable {
    public let mediaURL: URL?
    public let mediaRange: String?
    public let indexURL: URL?
    public let indexRange: String?

    public init(
        mediaURL: URL? = nil,
        mediaRange: String? = nil,
        indexURL: URL? = nil,
        indexRange: String? = nil
    ) {
        self.mediaURL = mediaURL
        self.mediaRange = mediaRange
        self.indexURL = indexURL
        self.indexRange = indexRange
    }
}

public struct DASHSegmentList: Codable, Sendable, Equatable {
    public let timescale: Int64
    public let duration: Int64?
    public let startNumber: Int64
    public let initialization: DASHInitialization?
    public let segmentURLs: [DASHSegmentURL]

    public init(
        timescale: Int64 = 1,
        duration: Int64? = nil,
        startNumber: Int64 = 1,
        initialization: DASHInitialization? = nil,
        segmentURLs: [DASHSegmentURL] = []
    ) {
        self.timescale = timescale
        self.duration = duration
        self.startNumber = startNumber
        self.initialization = initialization
        self.segmentURLs = segmentURLs
    }
}

public struct DASHRepresentation: Codable, Sendable, Equatable {
    public let id: String?
    public let bandwidth: Int64?
    public let width: Int?
    public let height: Int?
    public let mimeType: String?
    public let codecs: String?
    public let hasContentProtection: Bool
    public let baseURL: URL?
    public let segmentTemplate: DASHSegmentTemplate?
    public let segmentList: DASHSegmentList?

    public init(
        id: String? = nil,
        bandwidth: Int64? = nil,
        width: Int? = nil,
        height: Int? = nil,
        mimeType: String? = nil,
        codecs: String? = nil,
        hasContentProtection: Bool = false,
        baseURL: URL? = nil,
        segmentTemplate: DASHSegmentTemplate? = nil,
        segmentList: DASHSegmentList? = nil
    ) {
        self.id = id
        self.bandwidth = bandwidth
        self.width = width
        self.height = height
        self.mimeType = mimeType
        self.codecs = codecs
        self.hasContentProtection = hasContentProtection
        self.baseURL = baseURL
        self.segmentTemplate = segmentTemplate
        self.segmentList = segmentList
    }
}

public struct DASHAdaptationSet: Codable, Sendable, Equatable {
    public let id: String?
    public let contentType: String?
    public let mimeType: String?
    public let codecs: String?
    public let language: String?
    public let hasContentProtection: Bool
    public let baseURL: URL?
    public let segmentTemplate: DASHSegmentTemplate?
    public let segmentList: DASHSegmentList?
    public let representations: [DASHRepresentation]

    public init(
        id: String? = nil,
        contentType: String? = nil,
        mimeType: String? = nil,
        codecs: String? = nil,
        language: String? = nil,
        hasContentProtection: Bool = false,
        baseURL: URL? = nil,
        segmentTemplate: DASHSegmentTemplate? = nil,
        segmentList: DASHSegmentList? = nil,
        representations: [DASHRepresentation] = []
    ) {
        self.id = id
        self.contentType = contentType
        self.mimeType = mimeType
        self.codecs = codecs
        self.language = language
        self.hasContentProtection = hasContentProtection
        self.baseURL = baseURL
        self.segmentTemplate = segmentTemplate
        self.segmentList = segmentList
        self.representations = representations
    }
}

public struct DASHPeriod: Codable, Sendable, Equatable {
    public let id: String?
    public let start: Double?
    public let duration: Double?
    public let baseURL: URL?
    public let adaptationSets: [DASHAdaptationSet]

    public init(
        id: String? = nil,
        start: Double? = nil,
        duration: Double? = nil,
        baseURL: URL? = nil,
        adaptationSets: [DASHAdaptationSet] = []
    ) {
        self.id = id
        self.start = start
        self.duration = duration
        self.baseURL = baseURL
        self.adaptationSets = adaptationSets
    }
}

public struct DASHManifest: Codable, Sendable, Equatable {
    public let url: URL
    public let presentationType: DASHPresentationType
    public let profiles: String?
    public let mediaPresentationDuration: Double?
    public let minBufferTime: Double?
    public let baseURL: URL?
    public let periods: [DASHPeriod]

    public init(
        url: URL,
        presentationType: DASHPresentationType,
        profiles: String? = nil,
        mediaPresentationDuration: Double? = nil,
        minBufferTime: Double? = nil,
        baseURL: URL? = nil,
        periods: [DASHPeriod] = []
    ) {
        self.url = url
        self.presentationType = presentationType
        self.profiles = profiles
        self.mediaPresentationDuration = mediaPresentationDuration
        self.minBufferTime = minBufferTime
        self.baseURL = baseURL
        self.periods = periods
    }

    public var isFinite: Bool {
        presentationType == .staticPresentation
    }
}
