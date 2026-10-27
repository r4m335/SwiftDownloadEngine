import Foundation

#if canImport(SwiftUI)
import SwiftUI
#endif

/// Category of file transfer managed by the unified download application.
public enum TransferType: String, Sendable, Codable, CaseIterable, Identifiable {
    case http = "HTTP"
    case torrent = "BitTorrent"
    case streaming = "Streaming"
    case hls = "HLS"
    case dash = "DASH"

    public var id: String { rawValue }

    public var shortName: String {
        switch self {
        case .http: return "HTTP"
        case .torrent: return "TORRENT"
        case .streaming: return "STREAMING"
        case .hls: return "HLS"
        case .dash: return "DASH"
        }
    }
}

public typealias DownloadType = TransferType

/// Unified presentation states covering both HTTP segmented transfers and BitTorrent swarm transfers.
public enum UnifiedTransferState: Sendable, Equatable, Hashable {
    case queued
    case downloading
    case paused
    case completed
    case failed(reason: String)
    case seeding

    public var displayText: String {
        switch self {
        case .queued:
            return "Queued"
        case .downloading:
            return "Downloading"
        case .paused:
            return "Paused"
        case .completed:
            return "Completed"
        case .failed(let reason):
            return "Failed: \(reason)"
        case .seeding:
            return "Seeding"
        }
    }

    public var displayName: String {
        displayText
    }

    public var badgeText: String {
        switch self {
        case .queued: return "Queued"
        case .downloading: return "Downloading"
        case .paused: return "Paused"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .seeding: return "Seeding"
        }
    }
}

/// Authoritative UI-facing presentation model representing either an HTTP download or a BitTorrent task.
///
/// Phase 2: Unified Transfer Presentation Model.
/// Preserves underlying engine distinctions without fabricating HTTP values for Torrents or Torrent values for HTTP.
public struct UnifiedTransfer: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let type: TransferType
    public let state: UnifiedTransferState
    public let completedBytes: Int64
    public let totalBytes: Int64?
    public let progressFraction: Double
    public let downloadSpeedBytesPerSecond: Double
    public let uploadSpeedBytesPerSecond: Double
    public let destinationURL: URL
    public let source: String
    public let createdAt: Date
    public let failureReason: String?
    public let checksumOutcome: ChecksumOutcome?
    public let transportPolicy: HTTPTransportPolicy?

    // Torrent-specific properties
    public let infoHash: String?
    public let connectedPeers: Int?
    public let connectedSeeds: Int?
    public let torrentPriority: TorrentPriority?
    public let isExplicitlyPaused: Bool
    public let seedingPreference: SeedingPreference?
    public let filePriorities: [Int: TorrentFilePriority]?

    // MARK: - Initializer for HTTP DownloadSnapshot
    public init(from snapshot: DownloadSnapshot) {
        self.id = snapshot.id
        self.name = snapshot.destinationURL.lastPathComponent
        if snapshot.url.pathExtension.lowercased() == "m3u8" || snapshot.url.absoluteString.contains(".m3u8") {
            self.type = .hls
        } else if snapshot.url.pathExtension.lowercased() == "mpd" || snapshot.url.absoluteString.contains(".mpd") {
            self.type = .dash
        } else {
            self.type = .http
        }

        switch snapshot.state {
        case .pending:
            self.state = .queued
        case .probing, .downloading:
            self.state = .downloading
        case .paused:
            self.state = .paused
        case .completed:
            self.state = .completed
        case .failed(let reason):
            self.state = .failed(reason: reason)
        case .cancelled:
            self.state = .failed(reason: "Download cancelled")
        }

        self.completedBytes = snapshot.completedBytes
        self.totalBytes = snapshot.totalBytes
        self.progressFraction = snapshot.progressFraction
        self.downloadSpeedBytesPerSecond = snapshot.currentBytesPerSecond
        self.uploadSpeedBytesPerSecond = 0.0
        self.destinationURL = snapshot.destinationURL
        self.source = snapshot.url.absoluteString
        self.createdAt = snapshot.enqueuedAt
        self.failureReason = snapshot.failureReason
        self.checksumOutcome = snapshot.checksumOutcome
        self.transportPolicy = snapshot.transportPolicy

        self.infoHash = nil
        self.connectedPeers = nil
        self.connectedSeeds = nil
        self.torrentPriority = nil
        self.isExplicitlyPaused = false
        self.seedingPreference = nil
        self.filePriorities = nil
    }

    // MARK: - Initializer for TorrentTask
    public init(from task: TorrentTask) {
        self.id = task.id.uuidString
        self.name = task.name
        self.type = .torrent

        switch task.state {
        case .queued:
            self.state = .queued
        case .checking, .downloading:
            self.state = .downloading
        case .paused:
            self.state = .paused
        case .finished:
            self.state = .completed
        case .seeding:
            self.state = .seeding
        case .error:
            self.state = .failed(reason: task.errorMessage ?? "BitTorrent error")
        case .removed:
            self.state = .failed(reason: "Torrent removed")
        }

        self.completedBytes = task.progress.bytesDownloaded
        self.totalBytes = task.progress.totalBytes > 0 ? task.progress.totalBytes : nil
        self.progressFraction = task.progress.progressFraction
        self.downloadSpeedBytesPerSecond = task.progress.downloadBytesPerSecond
        self.uploadSpeedBytesPerSecond = task.progress.uploadBytesPerSecond
        self.destinationURL = task.savePath
        self.source = task.source
        self.createdAt = task.createdAt
        self.failureReason = task.errorMessage
        self.checksumOutcome = nil
        self.transportPolicy = nil

        self.infoHash = task.infoHash
        self.connectedPeers = task.progress.connectedPeers
        self.connectedSeeds = task.progress.activeSeeds
        self.torrentPriority = task.priority
        self.isExplicitlyPaused = task.isExplicitlyPaused
        self.seedingPreference = task.seedingPreference
        self.filePriorities = task.filePriorities
    }

    // MARK: - Explicit Initializer (for testing and previews)
    public init(
        id: String,
        name: String,
        type: TransferType,
        state: UnifiedTransferState,
        completedBytes: Int64,
        totalBytes: Int64? = nil,
        progressFraction: Double = 0.0,
        downloadSpeedBytesPerSecond: Double = 0.0,
        uploadSpeedBytesPerSecond: Double = 0.0,
        destinationURL: URL,
        source: String,
        createdAt: Date = Date(),
        failureReason: String? = nil,
        checksumOutcome: ChecksumOutcome? = nil,
        transportPolicy: HTTPTransportPolicy? = nil,
        infoHash: String? = nil,
        connectedPeers: Int? = nil,
        connectedSeeds: Int? = nil,
        torrentPriority: TorrentPriority? = nil,
        isExplicitlyPaused: Bool = false,
        seedingPreference: SeedingPreference? = nil,
        filePriorities: [Int: TorrentFilePriority]? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.state = state
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.progressFraction = progressFraction
        self.downloadSpeedBytesPerSecond = downloadSpeedBytesPerSecond
        self.uploadSpeedBytesPerSecond = uploadSpeedBytesPerSecond
        self.destinationURL = destinationURL
        self.source = source
        self.createdAt = createdAt
        self.failureReason = failureReason
        self.checksumOutcome = checksumOutcome
        self.transportPolicy = transportPolicy
        self.infoHash = infoHash
        self.connectedPeers = connectedPeers
        self.connectedSeeds = connectedSeeds
        self.torrentPriority = torrentPriority
        self.isExplicitlyPaused = isExplicitlyPaused
        self.seedingPreference = seedingPreference
        self.filePriorities = filePriorities
    }

    // MARK: - Helper Predicates
    public var isTorrent: Bool { type == .torrent }
    public var isHTTP: Bool { type == .http || type == .streaming || type == .hls || type == .dash }
    public var isStreaming: Bool { type == .streaming || type == .hls || type == .dash }

    public var canPause: Bool {
        switch state {
        case .downloading, .seeding:
            return true
        default:
            return false
        }
    }

    public var canResume: Bool {
        switch state {
        case .paused, .queued:
            return true
        default:
            return false
        }
    }

    public var canRetry: Bool {
        if case .failed = state { return true }
        return false
    }

    public var isTerminal: Bool {
        switch state {
        case .completed, .seeding, .failed:
            return true
        default:
            return false
        }
    }

    public var isCompleted: Bool {
        state == .completed || state == .seeding
    }

    public var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    public var isSeeding: Bool {
        state == .seeding
    }

    public func matchesFilter(_ filter: DownloadFilter) -> Bool {
        switch filter {
        case .all:
            return true
        case .active:
            return state == .downloading || state == .seeding
        case .paused:
            return state == .paused
        case .completed:
            return state == .completed
        case .failed:
            if case .failed = state { return true }
            return false
        }
    }
}

#if canImport(SwiftUI)
import SwiftUI

public struct TypeBadge: View {
    public let type: TransferType

    public init(type: TransferType) {
        self.type = type
    }

    public var body: some View {
        Text(badgeText)
            .font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(badgeColor.opacity(0.18))
            .foregroundColor(badgeColor)
            .cornerRadius(4)
    }

    private var badgeText: String {
        switch type {
        case .torrent: return "TORRENT"
        case .hls: return "HLS"
        case .dash: return "DASH"
        case .streaming: return "HLS"
        case .http: return "HTTP"
        }
    }

    private var badgeColor: Color {
        switch type {
        case .torrent: return .purple
        case .hls, .dash, .streaming: return .orange
        case .http: return .blue
        }
    }
}

public struct UnifiedStatusBadge: View {
    public let state: UnifiedTransferState

    public init(state: UnifiedTransferState) {
        self.state = state
    }

    public var body: some View {
        Text(state.displayName)
            .font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(statusColor.opacity(0.18))
            .foregroundColor(statusColor)
            .cornerRadius(4)
    }

    private var statusColor: Color {
        switch state {
        case .queued:
            return .gray
        case .downloading:
            return .blue
        case .paused:
            return .orange
        case .completed:
            return .green
        case .failed:
            return .red
        case .seeding:
            return .teal
        }
    }
}
#endif
