import Foundation

#if canImport(SwiftUI)
import SwiftUI
#endif

/// Category of file transfer managed by the unified download application.
public enum TransferType: String, Sendable, Codable, CaseIterable, Identifiable {
    case http = "HTTP"
    case torrent = "BitTorrent"

    public var id: String { rawValue }

    public var shortName: String {
        switch self {
        case .http: return "HTTP"
        case .torrent: return "TORRENT"
        }
    }
}

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

    // Torrent-specific properties
    public let infoHash: String?
    public let connectedPeers: Int?
    public let connectedSeeds: Int?
    public let torrentPriority: TorrentPriority?
    public let isExplicitlyPaused: Bool

    // MARK: - Initializer for HTTP DownloadSnapshot
    public init(from snapshot: DownloadSnapshot) {
        self.id = snapshot.id
        self.name = snapshot.destinationURL.lastPathComponent
        self.type = .http

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

        self.infoHash = nil
        self.connectedPeers = nil
        self.connectedSeeds = nil
        self.torrentPriority = nil
        self.isExplicitlyPaused = false
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

        self.infoHash = task.infoHash
        self.connectedPeers = task.progress.connectedPeers
        self.connectedSeeds = task.progress.activeSeeds
        self.torrentPriority = task.priority
        self.isExplicitlyPaused = task.isExplicitlyPaused
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
        infoHash: String? = nil,
        connectedPeers: Int? = nil,
        connectedSeeds: Int? = nil,
        torrentPriority: TorrentPriority? = nil,
        isExplicitlyPaused: Bool = false
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
        self.infoHash = infoHash
        self.connectedPeers = connectedPeers
        self.connectedSeeds = connectedSeeds
        self.torrentPriority = torrentPriority
        self.isExplicitlyPaused = isExplicitlyPaused
    }

    // MARK: - Helper Predicates
    public var isTorrent: Bool { type == .torrent }
    public var isHTTP: Bool { type == .http }

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
        Text(type == .torrent ? "TORRENT" : "HTTP")
            .font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(type == .torrent ? Color.purple.opacity(0.18) : Color.blue.opacity(0.18))
            .foregroundColor(type == .torrent ? .purple : .blue)
            .cornerRadius(4)
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
