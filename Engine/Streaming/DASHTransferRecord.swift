import Foundation

// MARK: - DASH Transfer Record

/// Durable, credential-free snapshot of a DASH parent transfer.
///
/// Stored as one JSON file per transfer in the DASH metadata subdirectory of the
/// application's persistent download store. Browser authentication headers and
/// cookies are intentionally excluded; those are runtime-only secrets managed
/// separately by `BrowserHeaderFilter` and `KeychainManager`.
public struct DASHTransferRecord: Codable, Sendable, Equatable, Identifiable, SchemaVersioned {
    public static let currentSchemaVersion: Int = 1

    // MARK: Identity

    /// Schema version for persistent storage migrations.
    public var schemaVersion: Int

    /// Stable parent transfer identifier (also matches the DownloadEngine parent download ID).
    public let id: String

    /// The original DASH MPD manifest URL used to initiate this transfer.
    public let manifestURL: URL

    // MARK: Output

    /// User-visible filename for the assembled video or subtitle output.
    public let outputFilename: String

    /// Final file URL where the assembled media is written.
    public let outputDestinationURL: URL

    /// Temporary directory that holds raw `.part` segment files during download.
    public let segmentDirectoryURL: URL

    // MARK: Representation Identifiers

    /// Selected video representation ID in the MPD manifest (if any).
    public let videoRepresentationID: String?

    /// Selected audio representation ID in the MPD manifest (if any).
    public let audioRepresentationID: String?

    /// Selected text representation ID in the MPD manifest (if any).
    public let textRepresentationID: String?

    /// Whether this is a standalone text/subtitle track (e.g. VTT or TTML).
    public let isTextOnly: Bool

    /// Whether the text track is TTML format (rather than WebVTT).
    public let isTTML: Bool

    // MARK: Segment Tracking

    /// Total number of segments to download (video + audio + text).
    public let totalSegments: Int

    /// Set of segment `order` indices that have been fully downloaded and written to disk.
    public var completedSegmentOrders: Set<Int>

    // MARK: State

    /// High-level transfer lifecycle state.
    public var state: HLSTransferState

    /// State of the post-download media assembly step.
    public var assemblyState: HLSAssemblyState

    // MARK: Timestamps

    /// Wall-clock date when this record was first created.
    public let createdAt: Date

    /// Wall-clock date of the most recent mutation to this record.
    public var updatedAt: Date

    // MARK: - Initializer

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        id: String,
        manifestURL: URL,
        outputFilename: String,
        outputDestinationURL: URL,
        segmentDirectoryURL: URL,
        videoRepresentationID: String? = nil,
        audioRepresentationID: String? = nil,
        textRepresentationID: String? = nil,
        isTextOnly: Bool = false,
        isTTML: Bool = false,
        totalSegments: Int,
        completedSegmentOrders: Set<Int> = [],
        state: HLSTransferState = .downloading,
        assemblyState: HLSAssemblyState = .notStarted,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.manifestURL = manifestURL
        self.outputFilename = outputFilename
        self.outputDestinationURL = outputDestinationURL
        self.segmentDirectoryURL = segmentDirectoryURL
        self.videoRepresentationID = videoRepresentationID
        self.audioRepresentationID = audioRepresentationID
        self.textRepresentationID = textRepresentationID
        self.isTextOnly = isTextOnly
        self.isTTML = isTTML
        self.totalSegments = totalSegments
        self.completedSegmentOrders = completedSegmentOrders
        self.state = state
        self.assemblyState = assemblyState
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id
        case manifestURL
        case outputFilename
        case outputDestinationURL
        case segmentDirectoryURL
        case videoRepresentationID
        case audioRepresentationID
        case textRepresentationID
        case isTextOnly
        case isTTML
        case totalSegments
        case completedSegmentOrders
        case state
        case assemblyState
        case createdAt
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        self.id = try container.decode(String.self, forKey: .id)
        self.manifestURL = try container.decode(URL.self, forKey: .manifestURL)
        self.outputFilename = try container.decode(String.self, forKey: .outputFilename)
        self.outputDestinationURL = try container.decode(URL.self, forKey: .outputDestinationURL)
        self.segmentDirectoryURL = try container.decode(URL.self, forKey: .segmentDirectoryURL)
        self.videoRepresentationID = try container.decodeIfPresent(String.self, forKey: .videoRepresentationID)
        self.audioRepresentationID = try container.decodeIfPresent(String.self, forKey: .audioRepresentationID)
        self.textRepresentationID = try container.decodeIfPresent(String.self, forKey: .textRepresentationID)
        self.isTextOnly = try container.decodeIfPresent(Bool.self, forKey: .isTextOnly) ?? false
        self.isTTML = try container.decodeIfPresent(Bool.self, forKey: .isTTML) ?? false
        self.totalSegments = try container.decode(Int.self, forKey: .totalSegments)
        self.completedSegmentOrders = try container.decode(Set<Int>.self, forKey: .completedSegmentOrders)
        self.state = try container.decode(HLSTransferState.self, forKey: .state)
        self.assemblyState = try container.decode(HLSAssemblyState.self, forKey: .assemblyState)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    // MARK: - Computed Helpers

    public var completedSegmentCount: Int { completedSegmentOrders.count }
    public var allSegmentsDownloaded: Bool { completedSegmentOrders.count >= totalSegments }

    public var downloadFraction: Double {
        guard totalSegments > 0 else { return 0 }
        return min(1.0, Double(completedSegmentOrders.count) / Double(totalSegments))
    }

    public var isTerminal: Bool {
        switch state {
        case .completed, .failed, .cancelled: return true
        case .pending, .downloading, .paused: return false
        }
    }

    public var isResumable: Bool {
        switch state {
        case .paused, .downloading: return true
        case .pending, .completed, .failed, .cancelled: return false
        }
    }
}
