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

    public init(
        id: UUID = UUID(),
        source: String,
        name: String,
        savePath: URL,
        state: TorrentState = .queued,
        progress: TorrentProgress = TorrentProgress(),
        errorMessage: String? = nil,
        createdAt: Date = Date(),
        infoHash: String = ""
    ) {
        self.id = id
        self.source = source
        self.name = name
        self.savePath = savePath
        self.state = state
        self.progress = progress
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.infoHash = infoHash
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

/// Errors produced by torrent management and transfer operations.
public enum TorrentEngineError: LocalizedError, Equatable, Sendable {
    case sessionNotRunning
    case torrentNotFound
    case bridgeError(String)

    public var errorDescription: String? {
        switch self {
        case .sessionNotRunning:
            return "The torrent engine session is not running."
        case .torrentNotFound:
            return "The specified torrent was not found."
        case .bridgeError(let msg):
            return msg
        }
    }
}
