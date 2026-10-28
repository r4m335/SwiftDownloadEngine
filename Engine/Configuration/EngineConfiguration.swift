import Foundation

/// Defines how duplicate file downloads are handled when a file with the destination name already exists.
public enum DuplicateNamingRule: String, Codable, Sendable, CaseIterable {
    case autoRename = "Auto-rename with index"
    case overwrite = "Overwrite existing file"
    case skip = "Skip if file exists"
}

/// Plain immutable configuration model used strictly within the core engine layer.
/// In accordance with clean iOS architecture, the engine NEVER reads directly from UI preferences (UserDefaults / AppSettings).
public struct EngineConfiguration: Sendable, Equatable {
    public var maxConcurrentDownloads: Int
    public var maxGlobalRequests: Int
    public var requestTimeoutSeconds: TimeInterval
    public var resourceTimeoutSeconds: TimeInterval
    public var userAgent: String
    public var maxRetryAttempts: Int
    public var globalBandwidthLimitBytesPerSecond: Int64?
    public var duplicateNamingRule: DuplicateNamingRule
    public var allowCellular: Bool
    public var maxConcurrentTorrents: Int
    public var defaultTorrentPriority: TorrentPriority
    public var defaultSeedingPreference: SeedingPreference

    public static let `default` = EngineConfiguration(
        maxConcurrentDownloads: 3,
        maxGlobalRequests: 12,
        requestTimeoutSeconds: 30.0,
        resourceTimeoutSeconds: 300.0,
        userAgent: "SwiftDownloadEngine/1.0 (iOS; iPadOS)",
        maxRetryAttempts: 3,
        globalBandwidthLimitBytesPerSecond: nil,
        duplicateNamingRule: .autoRename,
        allowCellular: true,
        maxConcurrentTorrents: 3,
        defaultTorrentPriority: .normal,
        defaultSeedingPreference: SeedingPreference(mode: .ratio, targetRatio: 1.0, targetDurationSeconds: 3600)
    )

    public init(
        maxConcurrentDownloads: Int = 3,
        maxGlobalRequests: Int = 12,
        requestTimeoutSeconds: TimeInterval = 30.0,
        resourceTimeoutSeconds: TimeInterval = 300.0,
        userAgent: String = "SwiftDownloadEngine/1.0 (iOS; iPadOS)",
        maxRetryAttempts: Int = 3,
        globalBandwidthLimitBytesPerSecond: Int64? = nil,
        duplicateNamingRule: DuplicateNamingRule = .autoRename,
        allowCellular: Bool = true,
        maxConcurrentTorrents: Int = 3,
        defaultTorrentPriority: TorrentPriority = .normal,
        defaultSeedingPreference: SeedingPreference = SeedingPreference(mode: .ratio, targetRatio: 1.0, targetDurationSeconds: 3600)
    ) {
        self.maxConcurrentDownloads = max(1, maxConcurrentDownloads)
        self.maxGlobalRequests = max(1, maxGlobalRequests)
        self.requestTimeoutSeconds = max(5.0, requestTimeoutSeconds)
        self.resourceTimeoutSeconds = max(15.0, resourceTimeoutSeconds)
        self.userAgent = userAgent
        self.maxRetryAttempts = max(0, maxRetryAttempts)
        self.globalBandwidthLimitBytesPerSecond = globalBandwidthLimitBytesPerSecond
        self.duplicateNamingRule = duplicateNamingRule
        self.allowCellular = allowCellular
        self.maxConcurrentTorrents = max(1, maxConcurrentTorrents)
        self.defaultTorrentPriority = defaultTorrentPriority
        self.defaultSeedingPreference = defaultSeedingPreference
    }
}
