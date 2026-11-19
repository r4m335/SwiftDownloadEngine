import Foundation

// MARK: - HLS Transfer State Enumerations

/// Lifecycle state of a durable HLS parent transfer.
public enum HLSTransferState: String, Codable, Sendable, Equatable {
    /// Transfer has been registered but not yet begun segment downloads.
    case pending
    /// Segment downloads are actively running.
    case downloading
    /// Transfer has been paused by the user.
    case paused
    /// All segments downloaded and final output assembled successfully.
    case completed
    /// Transfer encountered an unrecoverable error.
    case failed
    /// Transfer was explicitly cancelled by the user.
    case cancelled
}
/// State of the media-assembly step for a completed HLS segment download.
public enum HLSAssemblyState: String, Codable, Sendable, Equatable {
    /// Assembly has not begun (segments still downloading).
    case notStarted
    /// Assembly is actively in progress.
    case inProgress
    /// Assembly finished successfully and the output file is valid.
    case completed
    /// Assembly failed. Segments are preserved for potential recovery.
    case failed
}

// MARK: - HLS Transfer Record

/// Durable, credential-free snapshot of an HLS parent transfer.
///
/// Stored as one JSON file per transfer in the HLS metadata subdirectory of the
/// application's persistent download store. Browser authentication headers and
/// cookies are intentionally excluded; those are runtime-only secrets managed
/// separately by `BrowserHeaderFilter` and `KeychainManager`.
public struct HLSTransferRecord: Codable, Sendable, Equatable, Identifiable, SchemaVersioned {
    public static let currentSchemaVersion: Int = 1

    // MARK: Identity

    /// Schema version for persistent storage migrations.
    public var schemaVersion: Int

    /// Stable parent transfer identifier (also matches the DownloadEngine parent download ID).
    public let id: String

    /// The original HLS manifest URL used to initiate this transfer.
    public let manifestURL: URL

    // MARK: Output

    /// User-visible filename for the assembled video output.
    public let outputFilename: String

    /// Final file URL where the assembled video is written.
    public let outputDestinationURL: URL

    /// Temporary directory that holds raw `.part` segment files during download.
    public let segmentDirectoryURL: URL

    // MARK: Segment Tracking

    /// Total number of segments to download (video + audio, no subtitles).
    public let totalSegments: Int

    /// Set of segment `order` indices that have been fully downloaded and written to disk.
    /// Used to skip already-completed segments when resuming after a restart.
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
        self.totalSegments = try container.decode(Int.self, forKey: .totalSegments)
        self.completedSegmentOrders = try container.decode(Set<Int>.self, forKey: .completedSegmentOrders)
        self.state = try container.decode(HLSTransferState.self, forKey: .state)
        self.assemblyState = try container.decode(HLSAssemblyState.self, forKey: .assemblyState)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    // MARK: - Computed Helpers

    /// Number of segments that have completed downloading.
    public var completedSegmentCount: Int { completedSegmentOrders.count }

    /// `true` when every segment has been downloaded (but assembly may not be done yet).
    public var allSegmentsDownloaded: Bool { completedSegmentOrders.count >= totalSegments }

    /// Download fraction, 0.0 – 1.0, based on segment completion (not bytes).
    public var downloadFraction: Double {
        guard totalSegments > 0 else { return 0 }
        return min(1.0, Double(completedSegmentOrders.count) / Double(totalSegments))
    }

    /// `true` when the transfer is in a terminal state (success or failure).
    public var isTerminal: Bool {
        switch state {
        case .completed, .failed, .cancelled: return true
        case .pending, .downloading, .paused: return false
        }
    }

    /// `true` when the transfer can be resumed (paused or downloading state).
    public var isResumable: Bool {
        switch state {
        case .paused, .downloading: return true
        case .pending, .completed, .failed, .cancelled: return false
        }
    }
}
