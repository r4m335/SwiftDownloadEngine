import Foundation

/// Codable user-facing preferences stored in UserDefaults (@AppStorage).
/// Features a `version` field for seamless migrations across app updates.
public struct AppSettings: Codable, Sendable, Equatable {
    public static let currentVersion: Int = 1
    public static let userDefaultsKey = "com.r4m335.SwiftDownloadEngine.AppSettings"

    public var version: Int
    public var maxConcurrentDownloads: Int
    public var maxGlobalRequests: Int
    public var timeoutSeconds: Int
    public var customUserAgent: String?
    public var maxRetryAttempts: Int
    public var duplicateNamingRule: DuplicateNamingRule
    public var allowCellular: Bool
    public var enableGlobalSpeedLimit: Bool
    public var globalSpeedLimitKBps: Int
    public var globalBandwidthLimitBytes: Int64?
    public var maxConcurrentTorrents: Int
    public var defaultTorrentPriority: TorrentPriority
    public var seedingMode: SeedingMode
    public var targetRatio: Double
    public var targetDurationMinutes: Int

    public static let `default` = AppSettings(
        version: currentVersion,
        maxConcurrentDownloads: 3,
        maxGlobalRequests: 12,
        timeoutSeconds: 30,
        customUserAgent: nil,
        maxRetryAttempts: 3,
        duplicateNamingRule: .autoRename,
        allowCellular: true,
        enableGlobalSpeedLimit: false,
        globalSpeedLimitKBps: 2048,
        globalBandwidthLimitBytes: nil,
        maxConcurrentTorrents: 3,
        defaultTorrentPriority: .normal,
        seedingMode: .ratio,
        targetRatio: 1.0,
        targetDurationMinutes: 60
    )

    public init(
        version: Int = currentVersion,
        maxConcurrentDownloads: Int = 3,
        maxGlobalRequests: Int = 12,
        timeoutSeconds: Int = 30,
        customUserAgent: String? = nil,
        maxRetryAttempts: Int = 3,
        duplicateNamingRule: DuplicateNamingRule = .autoRename,
        allowCellular: Bool = true,
        enableGlobalSpeedLimit: Bool = false,
        globalSpeedLimitKBps: Int = 2048,
        globalBandwidthLimitBytes: Int64? = nil,
        maxConcurrentTorrents: Int = 3,
        defaultTorrentPriority: TorrentPriority = .normal,
        seedingMode: SeedingMode = .ratio,
        targetRatio: Double = 1.0,
        targetDurationMinutes: Int = 60
    ) {
        self.version = version
        self.maxConcurrentDownloads = max(1, maxConcurrentDownloads)
        self.maxGlobalRequests = max(1, maxGlobalRequests)
        self.timeoutSeconds = max(5, timeoutSeconds)
        self.customUserAgent = customUserAgent
        self.maxRetryAttempts = max(0, maxRetryAttempts)
        self.duplicateNamingRule = duplicateNamingRule
        self.allowCellular = allowCellular
        self.enableGlobalSpeedLimit = enableGlobalSpeedLimit
        self.globalSpeedLimitKBps = max(64, globalSpeedLimitKBps)
        self.globalBandwidthLimitBytes = globalBandwidthLimitBytes
        self.maxConcurrentTorrents = max(1, maxConcurrentTorrents)
        self.defaultTorrentPriority = defaultTorrentPriority
        self.seedingMode = seedingMode
        self.targetRatio = targetRatio
        self.targetDurationMinutes = targetDurationMinutes
    }

    /// Maps UI AppSettings into the engine layer's decoupled EngineConfiguration.
    public func makeEngineConfiguration() -> EngineConfiguration {
        let speedLimit: Int64?
        if enableGlobalSpeedLimit {
            speedLimit = globalBandwidthLimitBytes ?? Int64(globalSpeedLimitKBps) * 1024
        } else {
            speedLimit = nil
        }
        let seedingPref = SeedingPreference(
            mode: seedingMode,
            targetRatio: targetRatio,
            targetDurationSeconds: TimeInterval(targetDurationMinutes * 60)
        )
        let ua = (customUserAgent?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? customUserAgent!
            : "SwiftDownloadEngine/1.0 (iOS; iPadOS)"

        return EngineConfiguration(
            maxConcurrentDownloads: maxConcurrentDownloads,
            maxGlobalRequests: maxGlobalRequests,
            requestTimeoutSeconds: TimeInterval(timeoutSeconds),
            resourceTimeoutSeconds: TimeInterval(timeoutSeconds * 10),
            userAgent: ua,
            maxRetryAttempts: maxRetryAttempts,
            globalBandwidthLimitBytesPerSecond: speedLimit,
            duplicateNamingRule: duplicateNamingRule,
            allowCellular: allowCellular,
            maxConcurrentTorrents: maxConcurrentTorrents,
            defaultTorrentPriority: defaultTorrentPriority,
            defaultSeedingPreference: seedingPref
        )
    }

    /// Loads settings from standard UserDefaults with schema version check and fallback.
    public static func load(from defaults: UserDefaults = .standard) -> AppSettings {
        guard let data = defaults.data(forKey: userDefaultsKey),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return .default
        }
        if settings.version < currentVersion {
            var migrated = settings
            migrated.version = currentVersion
            migrated.save(to: defaults)
            return migrated
        }
        return settings
    }

    /// Persists settings to standard UserDefaults.
    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.userDefaultsKey)
        }
    }
}
