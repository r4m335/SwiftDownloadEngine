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

/// Download priority for individual files within a torrent.
public enum TorrentFilePriority: UInt8, Codable, CaseIterable, Sendable {
    case doNotDownload = 0
    case normal = 4
    case high = 7

    public var title: String {
        switch self {
        case .doNotDownload: return "Don't Download"
        case .normal: return "Normal"
        case .high: return "High"
        }
    }
}

/// Metadata and download state for an individual file within a torrent.
public struct TorrentFileInfo: Identifiable, Codable, Equatable, Sendable {
    public var id: Int { index }
    public let index: Int
    public let path: String
    public let name: String
    public let size: Int64
    public var priority: TorrentFilePriority
    public let progressFraction: Double

    public init(
        index: Int,
        path: String,
        size: Int64,
        priority: TorrentFilePriority = .normal,
        progressFraction: Double = 0.0
    ) {
        self.index = index
        self.path = path
        self.name = (path as NSString).lastPathComponent
        self.size = max(0, size)
        self.priority = priority
        self.progressFraction = min(1.0, max(0.0, progressFraction))
    }
}

/// Configurable seeding mode for finished torrents.
public enum SeedingMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case doNotSeed = "Stop upon Completion"
    case ratio = "Stop at Ratio"
    case duration = "Stop after Duration"
    case indefinitely = "Seed Indefinitely"

    public var id: String { rawValue }
}

/// User preference and enforcement rules for post-download seeding.
public struct SeedingPreference: Codable, Equatable, Sendable {
    public var mode: SeedingMode
    public var targetRatio: Double
    public var targetDurationSeconds: TimeInterval

    public static let `default` = SeedingPreference(mode: .doNotSeed, targetRatio: 1.0, targetDurationSeconds: 3600)

    public init(mode: SeedingMode = .doNotSeed, targetRatio: Double = 1.0, targetDurationSeconds: TimeInterval = 3600) {
        self.mode = mode
        self.targetRatio = targetRatio
        self.targetDurationSeconds = targetDurationSeconds
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

/// Represents a BitTorrent info-hash supporting both BitTorrent v1 (20-byte SHA-1) and BitTorrent v2 (32-byte SHA-256), or Hybrid torrents containing both.
public struct TorrentInfoHash: Sendable, Codable, Equatable, Hashable, CustomStringConvertible {
    public let v1: String?
    public let v2: String?

    public init(v1: String? = nil, v2: String? = nil) {
        self.v1 = v1?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.v2 = v2?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public init(hexString: String) {
        let clean = hexString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if clean.count == 64 {
            self.v1 = nil
            self.v2 = clean
        } else {
            self.v1 = clean
            self.v2 = nil
        }
    }

    public var bestIdentifier: String {
        v1 ?? v2 ?? ""
    }

    public var description: String {
        bestIdentifier
    }

    public var isHybrid: Bool {
        v1 != nil && v2 != nil
    }

    public var isV2Only: Bool {
        v1 == nil && v2 != nil
    }

    public var isV1Only: Bool {
        v1 != nil && v2 == nil
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
    public var infoHashV1: String?
    public var infoHashV2: String?
    public var priority: TorrentPriority
    public var isExplicitlyPaused: Bool
    public var filePriorities: [Int: TorrentFilePriority]?
    public var seedingPreference: SeedingPreference?

    public var structuredInfoHash: TorrentInfoHash {
        TorrentInfoHash(v1: infoHashV1 ?? (infoHash.count == 40 ? infoHash : nil),
                        v2: infoHashV2 ?? (infoHash.count == 64 ? infoHash : nil))
    }

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
        infoHashV1: String? = nil,
        infoHashV2: String? = nil,
        priority: TorrentPriority = .normal,
        isExplicitlyPaused: Bool = false,
        filePriorities: [Int: TorrentFilePriority]? = nil,
        seedingPreference: SeedingPreference? = nil
    ) {
        self.id = id
        self.source = source
        self.name = name
        self.savePath = savePath
        self.state = state
        self.progress = progress
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        let cleanHash = infoHash.lowercased()
        self.infoHash = cleanHash
        self.infoHashV1 = infoHashV1?.lowercased() ?? (cleanHash.count == 40 ? cleanHash : nil)
        self.infoHashV2 = infoHashV2?.lowercased() ?? (cleanHash.count == 64 ? cleanHash : nil)
        self.priority = priority
        self.isExplicitlyPaused = isExplicitlyPaused
        self.filePriorities = filePriorities
        self.seedingPreference = seedingPreference
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
    public var filePriorities: [Int: TorrentFilePriority]?
    public var seedingPreference: SeedingPreference?
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
        filePriorities: [Int: TorrentFilePriority]? = nil,
        seedingPreference: SeedingPreference? = nil,
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
        self.filePriorities = filePriorities
        self.seedingPreference = seedingPreference
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
    public let portRange: ClosedRange<UInt>
    public let libtorrentVersion: String

    public init(
        isRunning: Bool,
        isListening: Bool,
        listenPort: UInt,
        portRange: ClosedRange<UInt> = 6881...6891,
        libtorrentVersion: String
    ) {
        self.isRunning = isRunning
        self.isListening = isListening
        self.listenPort = listenPort
        self.portRange = portRange
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
        case .invalidMagnetURI:
            return "Invalid magnet URI."
        case .invalidTorrentFile(let msg):
            return "Invalid .torrent file: \(msg)"
        }
    }
}
