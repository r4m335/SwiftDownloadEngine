import Foundation

/// Lifecycle state for a torrent managed by the torrent subsystem.
public enum TorrentState: String, Codable, Sendable {
    case queued
    case checking
    case downloading
    case finished
    case seeding
    case paused
    case error
    case removed
}

/// Priority scheduling order for queued torrents.
public enum TorrentPriority: Int, Codable, Comparable, CaseIterable, Sendable {
    case low = 1
    case normal = 2
    case high = 3

    public static func < (lhs: TorrentPriority, rhs: TorrentPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Immutable UI-facing progress snapshot for a torrent task.
public struct TorrentProgress: Codable, Equatable, Sendable {
    public let bytesDownloaded: Int64
    public let totalBytes: Int64
    public let downloadBytesPerSecond: Double
    public let uploadBytesPerSecond: Double
    public let connectedPeers: Int
    public let activeSeeds: Int
    public let progressFraction: Double

    public init(
        bytesDownloaded: Int64 = 0,
        totalBytes: Int64 = 0,
        downloadBytesPerSecond: Double = 0,
        uploadBytesPerSecond: Double = 0,
        connectedPeers: Int = 0,
        activeSeeds: Int = 0,
        progressFraction: Double = 0
    ) {
        self.bytesDownloaded = max(0, bytesDownloaded)
        self.totalBytes = max(0, totalBytes)
        self.downloadBytesPerSecond = max(0, downloadBytesPerSecond)
        self.uploadBytesPerSecond = max(0, uploadBytesPerSecond)
        self.connectedPeers = max(0, connectedPeers)
        self.activeSeeds = max(0, activeSeeds)
        self.progressFraction = min(1, max(0, progressFraction))
    }
}

/// Persistent identity and user-visible state for one torrent.
public struct TorrentTask: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let source: String
    public var name: String
    public let savePath: URL
    public var state: TorrentState
    public var progress: TorrentProgress
    public var errorMessage: String?
    public let createdAt: Date
    public let infoHash: String
    public var priority: TorrentPriority
    public var isExplicitlyPaused: Bool

    public init(
        id: UUID = UUID(),
        source: String,
        name: String,
        savePath: URL,
        state: TorrentState = .queued,
        progress: TorrentProgress = TorrentProgress(),
        errorMessage: String? = nil,
        createdAt: Date = Date(),
        infoHash: String = "",
        priority: TorrentPriority = .normal,
        isExplicitlyPaused: Bool = false
    ) {
        self.id = id
        self.source = source
        self.name = name
        self.savePath = savePath
        self.state = state
        self.progress = progress
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.infoHash = infoHash.lowercased()
        self.priority = priority
        self.isExplicitlyPaused = isExplicitlyPaused
    }
}

/// Durable persisted metadata for a torrent download in the manifest.
public struct TorrentRecord: Identifiable, Codable, Equatable, Sendable {
    public static let currentSchemaVersion: Int = 1

    public let id: UUID
    public let infoHash: String
    public let source: String
    public var name: String
    public let savePath: URL
    public let createdAt: Date
    public var updatedAt: Date
    public var state: TorrentState
    public var progress: TorrentProgress
    public var priority: TorrentPriority
    public var sequenceIndex: Int64
    public var isExplicitlyPaused: Bool
    public var seedRatioLimit: Double?
    public var fastResumeFileName: String?
    public var schemaVersion: Int
    public var errorMessage: String?

    public init(
        id: UUID = UUID(),
        infoHash: String,
        source: String,
        name: String,
        savePath: URL,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        state: TorrentState = .queued,
        progress: TorrentProgress = TorrentProgress(),
        priority: TorrentPriority = .normal,
        sequenceIndex: Int64 = 0,
        isExplicitlyPaused: Bool = false,
        seedRatioLimit: Double? = nil,
        fastResumeFileName: String? = nil,
        schemaVersion: Int = TorrentRecord.currentSchemaVersion,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.infoHash = infoHash.lowercased()
        self.source = source
        self.name = name
        self.savePath = savePath
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.state = state
        self.progress = progress
        self.priority = priority
        self.sequenceIndex = sequenceIndex
        self.isExplicitlyPaused = isExplicitlyPaused
        self.seedRatioLimit = seedRatioLimit
        self.fastResumeFileName = fastResumeFileName
        self.schemaVersion = schemaVersion
        self.errorMessage = errorMessage
    }
}

/// Durable root manifest storing the persistent queue state of all tracked torrents.
public struct TorrentQueueManifest: Codable, Sendable, Equatable {
    public static let currentSchemaVersion: Int = 1

    public var schemaVersion: Int
    public var maxConcurrentTorrents: Int
    public var sequenceCounter: Int64
    public var records: [TorrentRecord]

    public init(
        schemaVersion: Int = TorrentQueueManifest.currentSchemaVersion,
        maxConcurrentTorrents: Int = 3,
        sequenceCounter: Int64 = 0,
        records: [TorrentRecord] = []
    ) {
        self.schemaVersion = schemaVersion
        self.maxConcurrentTorrents = max(1, maxConcurrentTorrents)
        self.sequenceCounter = sequenceCounter
        self.records = records
    }
}

/// Point-in-time snapshot of the overall torrent queue state and scheduling distribution.
public struct TorrentQueueSnapshot: Sendable, Equatable {
    public let totalTorrents: Int
    public let activeCount: Int
    public let queuedCount: Int
    public let pausedCount: Int
    public let completedCount: Int
    public let seedingCount: Int
    public let failedCount: Int
    public let records: [TorrentRecord]

    public init(
        totalTorrents: Int,
        activeCount: Int,
        queuedCount: Int,
        pausedCount: Int,
        completedCount: Int,
        seedingCount: Int,
        failedCount: Int,
        records: [TorrentRecord]
    ) {
        self.totalTorrents = totalTorrents
        self.activeCount = activeCount
        self.queuedCount = queuedCount
        self.pausedCount = pausedCount
        self.completedCount = completedCount
        self.seedingCount = seedingCount
        self.failedCount = failedCount
        self.records = records
    }
}

/// Current health and listener state of the native libtorrent session.
public struct TorrentSessionStatus: Equatable, Sendable {
    public let isRunning: Bool
    public let isListening: Bool
    public let listenPort: UInt
    public let libtorrentVersion: String

    public init(isRunning: Bool, isListening: Bool, listenPort: UInt, libtorrentVersion: String) {
        self.isRunning = isRunning
        self.isListening = isListening
        self.listenPort = listenPort
        self.libtorrentVersion = libtorrentVersion
    }
}

/// Errors produced by torrent management, persistence, and transfer operations.
public enum TorrentEngineError: LocalizedError, Equatable, Sendable {
    case sessionNotRunning
    case torrentNotFound
    case bridgeError(String)
    case resumeDataGenerationFailed(String)
    case resumeDataCorrupt(String)
    case persistenceError(String)
    case unsupportedSchemaVersion(Int)
    case duplicateTorrent(String)
    case invalidMagnetURI(String)
    case invalidTorrentFile(String)

    public var errorDescription: String? {
        switch self {
        case .sessionNotRunning:
            return "The torrent engine session is not running."
        case .torrentNotFound:
            return "The specified torrent was not found."
        case .bridgeError(let msg):
            return msg
        case .resumeDataGenerationFailed(let msg):
            return "Failed to generate fast-resume data: \(msg)"
        case .resumeDataCorrupt(let msg):
            return "Corrupted or incompatible fast-resume data: \(msg)"
        case .persistenceError(let msg):
            return "Persistence error: \(msg)"
        case .unsupportedSchemaVersion(let ver):
            return "Unsupported persistence schema version: \(ver)"
        case .duplicateTorrent(let hash):
            return "Torrent with info-hash \(hash) already exists."
        case .invalidMagnetURI(let uri):
            return "Invalid magnet URI: \(uri)"
        case .invalidTorrentFile(let msg):
            return "Invalid .torrent file: \(msg)"
        }
    }
}
