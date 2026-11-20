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

    public var isHLS: Bool {
        kind == .hls
    }

    public var isDASH: Bool {
        kind == .dash
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

    public var isFairPlayDRM: Bool {
        let format = keyFormat?.lowercased() ?? ""
        let scheme = keyURL?.scheme?.lowercased() ?? ""
        return format.contains("streamingkeydelivery") || scheme == "skd"
    }

    public var isIdentityKey: Bool {
        let format = keyFormat?.lowercased() ?? "identity"
        return (format == "identity" || format.isEmpty) && !isFairPlayDRM
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

public struct HLSVariant: Codable, Sendable, Equatable, Hashable {
    public let uri: URL
    public let bandwidth: Int
    public let averageBandwidth: Int?
    public let resolution: HLSResolution?
    public let codecs: String?
    public let frameRate: Double?
    public let audioGroup: String?
    public let videoGroup: String?
    public let subtitlesGroup: String?
    public let isIFrameOnly: Bool

    public init(
        uri: URL,
        bandwidth: Int,
        averageBandwidth: Int? = nil,
        resolution: HLSResolution? = nil,
        codecs: String? = nil,
        frameRate: Double? = nil,
        audioGroup: String? = nil,
        videoGroup: String? = nil,
        subtitlesGroup: String? = nil,
        isIFrameOnly: Bool = false
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
        self.isIFrameOnly = isIFrameOnly
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
    public let parts: [HLSPartialSegment]

    public init(
        sequenceNumber: Int64,
        uri: URL,
        duration: Double,
        title: String? = nil,
        byteRange: HLSByteRange? = nil,
        initializationMap: HLSInitializationMap? = nil,
        encryption: HLSEncryption? = nil,
        isDiscontinuity: Bool = false,
        programDateTime: Date? = nil,
        parts: [HLSPartialSegment] = []
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
        self.parts = parts
    }
}

/// Server control directives for Low-Latency HLS (RFC 8216bis Section 4.4.3.8).
public struct HLSServerControl: Codable, Sendable, Equatable {
    public let canBlockReload: Bool
    public let canSkipUntil: Double?
    public let canSkipDateRanges: Bool
    public let holdBack: Double?
    public let partHoldBack: Double?

    public init(
        canBlockReload: Bool = false,
        canSkipUntil: Double? = nil,
        canSkipDateRanges: Bool = false,
        holdBack: Double? = nil,
        partHoldBack: Double? = nil
    ) {
        self.canBlockReload = canBlockReload
        self.canSkipUntil = canSkipUntil
        self.canSkipDateRanges = canSkipDateRanges
        self.holdBack = holdBack
        self.partHoldBack = partHoldBack
    }
}

/// A Low-Latency HLS partial media segment (RFC 8216bis Section 4.4.4.9).
public struct HLSPartialSegment: Codable, Sendable, Equatable {
    public let uri: URL
    public let duration: Double
    public let isIndependent: Bool
    public let byteRange: HLSByteRange?
    public let isGap: Bool

    public init(
        uri: URL,
        duration: Double,
        isIndependent: Bool = false,
        byteRange: HLSByteRange? = nil,
        isGap: Bool = false
    ) {
        self.uri = uri
        self.duration = duration
        self.isIndependent = isIndependent
        self.byteRange = byteRange
        self.isGap = isGap
    }
}

/// Preload hint resource type for Low-Latency HLS (RFC 8216bis Section 4.4.5.3).
public enum HLSPreloadHintType: String, Codable, Sendable, Equatable {
    case part = "PART"
    case map = "MAP"
}

/// A Low-Latency HLS preload hint for upcoming partial segment or initialization map.
public struct HLSPreloadHint: Codable, Sendable, Equatable {
    public let type: HLSPreloadHintType
    public let uri: URL
    public let byteRangeStart: Int64?
    public let byteRangeLength: Int64?

    public init(
        type: HLSPreloadHintType,
        uri: URL,
        byteRangeStart: Int64? = nil,
        byteRangeLength: Int64? = nil
    ) {
        self.type = type
        self.uri = uri
        self.byteRangeStart = byteRangeStart
        self.byteRangeLength = byteRangeLength
    }
}

public struct HLSManifest: Codable, Sendable, Equatable {
    public let url: URL
    public let playlistType: HLSPlaylistType
    public let lifecycle: HLSPlaylistLifecycle
    public let version: Int?
    public let independentSegments: Bool
    public let isIFramesOnly: Bool
    public let serverControl: HLSServerControl?
    public let partTargetDuration: Double?
    public let parts: [HLSPartialSegment]
    public let preloadHints: [HLSPreloadHint]
    public let variants: [HLSVariant]
    public let renditions: [HLSRendition]
    public let segments: [HLSMediaSegment]
    public let encryption: HLSKeyClassification
    public let targetDuration: Double?
    public let hasSynthesizedSegmentsFromParts: Bool

    public init(
        url: URL,
        playlistType: HLSPlaylistType,
        lifecycle: HLSPlaylistLifecycle,
        version: Int? = nil,
        independentSegments: Bool = false,
        isIFramesOnly: Bool = false,
        serverControl: HLSServerControl? = nil,
        partTargetDuration: Double? = nil,
        parts: [HLSPartialSegment] = [],
        preloadHints: [HLSPreloadHint] = [],
        variants: [HLSVariant] = [],
        renditions: [HLSRendition] = [],
        segments: [HLSMediaSegment] = [],
        encryption: HLSKeyClassification = .clear,
        targetDuration: Double? = nil,
        hasSynthesizedSegmentsFromParts: Bool = false
    ) {
        self.url = url
        self.playlistType = playlistType
        self.lifecycle = lifecycle
        self.version = version
        self.independentSegments = independentSegments
        self.isIFramesOnly = isIFramesOnly
        self.serverControl = serverControl
        self.partTargetDuration = partTargetDuration
        self.parts = parts
        self.preloadHints = preloadHints
        self.variants = variants
        self.renditions = renditions
        self.segments = segments
        self.encryption = encryption
        self.targetDuration = targetDuration
        self.hasSynthesizedSegmentsFromParts = hasSynthesizedSegmentsFromParts
    }

    /// Whether this manifest contains Low-Latency HLS tags or partial segments.
    public var isLowLatency: Bool {
        serverControl != nil || partTargetDuration != nil || !parts.isEmpty || !preloadHints.isEmpty
    }

    /// All partial segments that appear after the last completed media segment in the playlist.
    public var trailingParts: [HLSPartialSegment] {
        if hasSynthesizedSegmentsFromParts {
            return parts
        }
        let completedPartCount = segments.reduce(0) { $0 + $1.parts.count }
        guard completedPartCount < parts.count else { return [] }
        return Array(parts.dropFirst(completedPartCount))
    }

    /// All variants representing full video streams (non-I-frame-only).
    public var primaryVariants: [HLSVariant] {
        variants.filter { !$0.isIFrameOnly }
    }

    /// All variants representing trick-play or I-frame-only streams.
    public var iFrameVariants: [HLSVariant] {
        variants.filter(\.isIFrameOnly)
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

public struct DASHSegmentBase: Codable, Sendable, Equatable {
    public let timescale: Int64
    public let presentationTimeOffset: Int64
    public let indexRange: String?
    public let indexRangeExact: Bool
    public let availabilityTimeOffset: Double?
    public let initialization: DASHInitialization?
    public let mediaRange: String?

    public init(
        timescale: Int64 = 1,
        presentationTimeOffset: Int64 = 0,
        indexRange: String? = nil,
        indexRangeExact: Bool = false,
        availabilityTimeOffset: Double? = nil,
        initialization: DASHInitialization? = nil,
        mediaRange: String? = nil
    ) {
        self.timescale = timescale
        self.presentationTimeOffset = presentationTimeOffset
        self.indexRange = indexRange
        self.indexRangeExact = indexRangeExact
        self.availabilityTimeOffset = availabilityTimeOffset
        self.initialization = initialization
        self.mediaRange = mediaRange
    }
}

public struct DASHContentProtection: Codable, Sendable, Equatable {
    public let schemeIdUri: String?
    public let value: String?
    public let defaultKID: String?

    public init(schemeIdUri: String? = nil, value: String? = nil, defaultKID: String? = nil) {
        self.schemeIdUri = schemeIdUri
        self.value = value
        self.defaultKID = defaultKID
    }

    public var isDRM: Bool {
        guard let scheme = schemeIdUri?.lowercased() else {
            return value != nil
        }
        return scheme.contains("edef8ba9-79d6-4ace-a3c8-27dcd51d21ed") || // Widevine
               scheme.contains("9a04f079-9840-4286-ab92-e65be0885f95") || // PlayReady
               scheme.contains("94ce86fb-07ff-4f43-adb8-93d2fa968ca2") || // FairPlay
               scheme.contains("clearkey") ||
               scheme.contains("cenc") ||
               scheme.contains("cbcs")
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
    public let contentProtections: [DASHContentProtection]
    public let baseURL: URL?
    public let segmentTemplate: DASHSegmentTemplate?
    public let segmentList: DASHSegmentList?
    public let segmentBase: DASHSegmentBase?

    public init(
        id: String? = nil,
        bandwidth: Int64? = nil,
        width: Int? = nil,
        height: Int? = nil,
        mimeType: String? = nil,
        codecs: String? = nil,
        hasContentProtection: Bool = false,
        contentProtections: [DASHContentProtection] = [],
        baseURL: URL? = nil,
        segmentTemplate: DASHSegmentTemplate? = nil,
        segmentList: DASHSegmentList? = nil,
        segmentBase: DASHSegmentBase? = nil
    ) {
        self.id = id
        self.bandwidth = bandwidth
        self.width = width
        self.height = height
        self.mimeType = mimeType
        self.codecs = codecs
        self.hasContentProtection = hasContentProtection
        self.contentProtections = contentProtections
        self.baseURL = baseURL
        self.segmentTemplate = segmentTemplate
        self.segmentList = segmentList
        self.segmentBase = segmentBase
    }
}

public struct DASHAdaptationSet: Codable, Sendable, Equatable {
    public let id: String?
    public let contentType: String?
    public let mimeType: String?
    public let codecs: String?
    public let language: String?
    public let hasContentProtection: Bool
    public let contentProtections: [DASHContentProtection]
    public let baseURL: URL?
    public let segmentTemplate: DASHSegmentTemplate?
    public let segmentList: DASHSegmentList?
    public let segmentBase: DASHSegmentBase?
    public let representations: [DASHRepresentation]

    public init(
        id: String? = nil,
        contentType: String? = nil,
        mimeType: String? = nil,
        codecs: String? = nil,
        language: String? = nil,
        hasContentProtection: Bool = false,
        contentProtections: [DASHContentProtection] = [],
        baseURL: URL? = nil,
        segmentTemplate: DASHSegmentTemplate? = nil,
        segmentList: DASHSegmentList? = nil,
        segmentBase: DASHSegmentBase? = nil,
        representations: [DASHRepresentation] = []
    ) {
        self.id = id
        self.contentType = contentType
        self.mimeType = mimeType
        self.codecs = codecs
        self.language = language
        self.hasContentProtection = hasContentProtection
        self.contentProtections = contentProtections
        self.baseURL = baseURL
        self.segmentTemplate = segmentTemplate
        self.segmentList = segmentList
        self.segmentBase = segmentBase
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
