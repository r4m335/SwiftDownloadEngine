import Foundation

/// User-selectable sort order for download listings (HTTP and BitTorrent transfers).
public enum DownloadSortOrder: String, CaseIterable, Identifiable, Codable, Sendable {
    case dateAddedDesc = "dateAddedDesc"
    case dateAddedAsc = "dateAddedAsc"
    case nameAsc = "nameAsc"
    case sizeDesc = "sizeDesc"
    case progressDesc = "progressDesc"
    case speedDesc = "speedDesc"
    case durationDesc = "durationDesc"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .dateAddedDesc:
            return "Date Added — Newest First"
        case .dateAddedAsc:
            return "Date Added — Oldest First"
        case .nameAsc:
            return "Name — A to Z"
        case .sizeDesc:
            return "Size — Largest First"
        case .progressDesc:
            return "Progress — Highest First"
        case .speedDesc:
            return "Speed — Fastest First"
        case .durationDesc:
            return "Duration / ETA — Longest First"
        }
    }
}

/// User-selectable grouping option for download listings.
public enum DownloadGroupingOption: String, CaseIterable, Identifiable, Codable, Sendable {
    case none = "none"
    case type = "type"
    case status = "status"
    case dateAdded = "dateAdded"
    case fileSize = "fileSize"
    case domain = "domain"
    case format = "format"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none: return "No Grouping"
        case .type: return "Type"
        case .status: return "Status"
        case .dateAdded: return "Date Added"
        case .fileSize: return "File Size"
        case .domain: return "Domain"
        case .format: return "Format"
        }
    }
}

/// User-configurable cookie blocking policy (Milestone B.2).
public enum BrowserCookiePolicy: String, CaseIterable, Identifiable, Codable, Sendable {
    case allowAll = "allowAll"
    case blockThirdParty = "blockThirdParty"
    case blockAll = "blockAll"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .allowAll:
            return "Allow All Cookies"
        case .blockThirdParty:
            return "Block Third-Party Cookies (Recommended)"
        case .blockAll:
            return "Block All Cookies"
        }
    }
}

/// Color themes available for Safari-style Reader Mode (Milestone B.3).
public enum BrowserReaderTheme: String, CaseIterable, Identifiable, Codable, Sendable {
    case light = "light"
    case sepia = "sepia"
    case gray = "gray"
    case dark = "dark"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .light: return "Light"
        case .sepia: return "Sepia"
        case .gray: return "Gray"
        case .dark: return "Dark"
        }
    }
}

/// Font families available for Safari-style Reader Mode (Milestone B.3).
public enum BrowserReaderFontFamily: String, CaseIterable, Identifiable, Codable, Sendable {
    case serif = "serif"
    case sansSerif = "sansSerif"
    case monospace = "monospace"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .serif: return "Serif (Georgia / New York)"
        case .sansSerif: return "Sans-Serif (System / SF)"
        case .monospace: return "Monospace (SF Mono / Menlo)"
        }
    }
}

/// Codable user-facing preferences stored in UserDefaults (@AppStorage).
/// Features a `version` field for seamless migrations across app updates.
public struct AppSettings: Codable, Sendable, Equatable {
    public static let currentVersion: Int = 8
    public static let userDefaultsKey = "com.r4m335.DownloadEngineKit.AppSettings"

    public var version: Int
    public var maxConcurrentDownloads: Int
    public var maxGlobalRequests: Int
    public var timeoutSeconds: Int
    public var customUserAgent: String?
    public var maxRetryAttempts: Int
    public var duplicateNamingRule: DuplicateNamingRule
    public var allowCellular: Bool
    public var allowExpensiveNetwork: Bool
    public var allowConstrainedNetwork: Bool
    public var enableGlobalSpeedLimit: Bool
    public var globalSpeedLimitKBps: Int
    public var globalBandwidthLimitBytes: Int64?
    public var maxConcurrentTorrents: Int
    public var defaultTorrentPriority: TorrentPriority
    public var seedingMode: SeedingMode
    public var targetRatio: Double
    public var targetDurationMinutes: Int

    // Browser Shields & Content Blocking (Phase 3 Milestone 3.2 & Workstream B Milestone B.2)
    public var isAdBlockerEnabled: Bool
    public var isTrackerBlockerEnabled: Bool
    public var isAnnoyanceBlockerEnabled: Bool
    public var cookiePolicy: BrowserCookiePolicy
    public var isPopupBlockerEnabled: Bool
    public var adBlockerWhitelistedDomains: [String]

    // Download File Categorization & Routing (Phase 3 Milestone 3.3)
    public var isAutomaticCategorizationEnabled: Bool
    public var customCategoryFolders: [String: String]
    public var defaultDownloadDirectoryBookmark: Data?

    // Interactive Download Sorting & Grouping (Phase 4 Milestone 4.4)
    public var downloadSortOrder: DownloadSortOrder
    public var downloadGroupingOption: DownloadGroupingOption

    // Browser Search Engine & Navigation (Workstream B Milestone B.1 & Custom Search Engines)
    public var browserSearchEngine: BrowserSearchEngine
    public var customSearchEngines: [CustomSearchEngine]
    public var activeSearchEngineID: String

    // Browser Navigation & Reader Experience (Workstream B Milestone B.3)
    public var browserHomepage: String
    public var restoreTabsOnLaunch: Bool
    public var readerTheme: BrowserReaderTheme
    public var readerFontFamily: BrowserReaderFontFamily
    public var readerFontSize: Double

    public static let `default` = AppSettings(
        version: currentVersion,
        maxConcurrentDownloads: 3,
        maxGlobalRequests: 12,
        timeoutSeconds: 30,
        customUserAgent: nil,
        maxRetryAttempts: 3,
        duplicateNamingRule: .autoRename,
        allowCellular: true,
        allowExpensiveNetwork: true,
        allowConstrainedNetwork: false,
        enableGlobalSpeedLimit: false,
        globalSpeedLimitKBps: 2048,
        globalBandwidthLimitBytes: nil,
        maxConcurrentTorrents: 3,
        defaultTorrentPriority: .normal,
        seedingMode: .ratio,
        targetRatio: 1.0,
        targetDurationMinutes: 60,
        isAdBlockerEnabled: true,
        isTrackerBlockerEnabled: true,
        isAnnoyanceBlockerEnabled: true,
        cookiePolicy: .blockThirdParty,
        isPopupBlockerEnabled: true,
        adBlockerWhitelistedDomains: [],
        isAutomaticCategorizationEnabled: true,
        customCategoryFolders: [:],
        defaultDownloadDirectoryBookmark: nil,
        downloadSortOrder: .dateAddedDesc,
        downloadGroupingOption: .none,
        browserSearchEngine: .duckDuckGo,
        customSearchEngines: [],
        activeSearchEngineID: BrowserSearchEngine.duckDuckGo.rawValue,
        browserHomepage: "https://duckduckgo.com",
        restoreTabsOnLaunch: true,
        readerTheme: .light,
        readerFontFamily: .serif,
        readerFontSize: 18.0
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
        allowExpensiveNetwork: Bool = true,
        allowConstrainedNetwork: Bool = false,
        enableGlobalSpeedLimit: Bool = false,
        globalSpeedLimitKBps: Int = 2048,
        globalBandwidthLimitBytes: Int64? = nil,
        maxConcurrentTorrents: Int = 3,
        defaultTorrentPriority: TorrentPriority = .normal,
        seedingMode: SeedingMode = .ratio,
        targetRatio: Double = 1.0,
        targetDurationMinutes: Int = 60,
        isAdBlockerEnabled: Bool = true,
        isTrackerBlockerEnabled: Bool = true,
        isAnnoyanceBlockerEnabled: Bool = true,
        cookiePolicy: BrowserCookiePolicy = .blockThirdParty,
        isPopupBlockerEnabled: Bool = true,
        adBlockerWhitelistedDomains: [String] = [],
        isAutomaticCategorizationEnabled: Bool = true,
        customCategoryFolders: [String: String] = [:],
        defaultDownloadDirectoryBookmark: Data? = nil,
        downloadSortOrder: DownloadSortOrder = .dateAddedDesc,
        downloadGroupingOption: DownloadGroupingOption = .none,
        browserSearchEngine: BrowserSearchEngine = .duckDuckGo,
        customSearchEngines: [CustomSearchEngine] = [],
        activeSearchEngineID: String? = nil,
        browserHomepage: String = "https://duckduckgo.com",
        restoreTabsOnLaunch: Bool = true,
        readerTheme: BrowserReaderTheme = .light,
        readerFontFamily: BrowserReaderFontFamily = .serif,
        readerFontSize: Double = 18.0
    ) {
        self.version = version
        self.maxConcurrentDownloads = max(1, maxConcurrentDownloads)
        self.maxGlobalRequests = max(1, maxGlobalRequests)
        self.timeoutSeconds = max(5, timeoutSeconds)
        self.customUserAgent = customUserAgent
        self.maxRetryAttempts = max(0, maxRetryAttempts)
        self.duplicateNamingRule = duplicateNamingRule
        self.allowCellular = allowCellular
        self.allowExpensiveNetwork = allowExpensiveNetwork
        self.allowConstrainedNetwork = allowConstrainedNetwork
        self.enableGlobalSpeedLimit = enableGlobalSpeedLimit
        self.globalSpeedLimitKBps = max(64, globalSpeedLimitKBps)
        self.globalBandwidthLimitBytes = globalBandwidthLimitBytes
        self.maxConcurrentTorrents = max(1, maxConcurrentTorrents)
        self.defaultTorrentPriority = defaultTorrentPriority
        self.seedingMode = seedingMode
        self.targetRatio = targetRatio
        self.targetDurationMinutes = targetDurationMinutes
        self.isAdBlockerEnabled = isAdBlockerEnabled
        self.isTrackerBlockerEnabled = isTrackerBlockerEnabled
        self.isAnnoyanceBlockerEnabled = isAnnoyanceBlockerEnabled
        self.cookiePolicy = cookiePolicy
        self.isPopupBlockerEnabled = isPopupBlockerEnabled
        self.adBlockerWhitelistedDomains = adBlockerWhitelistedDomains
        self.isAutomaticCategorizationEnabled = isAutomaticCategorizationEnabled
        self.customCategoryFolders = customCategoryFolders
        self.defaultDownloadDirectoryBookmark = defaultDownloadDirectoryBookmark
        self.downloadSortOrder = downloadSortOrder
        self.downloadGroupingOption = downloadGroupingOption
        self.browserSearchEngine = browserSearchEngine
        self.customSearchEngines = customSearchEngines
        self.activeSearchEngineID = activeSearchEngineID ?? browserSearchEngine.rawValue
        self.browserHomepage = browserHomepage
        self.restoreTabsOnLaunch = restoreTabsOnLaunch
        self.readerTheme = readerTheme
        self.readerFontFamily = readerFontFamily
        self.readerFontSize = readerFontSize
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        self.maxConcurrentDownloads = try container.decodeIfPresent(Int.self, forKey: .maxConcurrentDownloads) ?? 3
        self.maxGlobalRequests = try container.decodeIfPresent(Int.self, forKey: .maxGlobalRequests) ?? 12
        self.timeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? 30
        self.customUserAgent = try container.decodeIfPresent(String.self, forKey: .customUserAgent)
        self.maxRetryAttempts = try container.decodeIfPresent(Int.self, forKey: .maxRetryAttempts) ?? 3
        self.duplicateNamingRule = try container.decodeIfPresent(DuplicateNamingRule.self, forKey: .duplicateNamingRule) ?? .autoRename
        self.allowCellular = try container.decodeIfPresent(Bool.self, forKey: .allowCellular) ?? true
        self.allowExpensiveNetwork = try container.decodeIfPresent(Bool.self, forKey: .allowExpensiveNetwork) ?? true
        self.allowConstrainedNetwork = try container.decodeIfPresent(Bool.self, forKey: .allowConstrainedNetwork) ?? false
        self.enableGlobalSpeedLimit = try container.decodeIfPresent(Bool.self, forKey: .enableGlobalSpeedLimit) ?? false
        self.globalSpeedLimitKBps = try container.decodeIfPresent(Int.self, forKey: .globalSpeedLimitKBps) ?? 2048
        self.globalBandwidthLimitBytes = try container.decodeIfPresent(Int64.self, forKey: .globalBandwidthLimitBytes)
        self.maxConcurrentTorrents = try container.decodeIfPresent(Int.self, forKey: .maxConcurrentTorrents) ?? 3
        self.defaultTorrentPriority = try container.decodeIfPresent(TorrentPriority.self, forKey: .defaultTorrentPriority) ?? .normal
        self.seedingMode = try container.decodeIfPresent(SeedingMode.self, forKey: .seedingMode) ?? .ratio
        self.targetRatio = try container.decodeIfPresent(Double.self, forKey: .targetRatio) ?? 1.0
        self.targetDurationMinutes = try container.decodeIfPresent(Int.self, forKey: .targetDurationMinutes) ?? 60
        self.isAdBlockerEnabled = try container.decodeIfPresent(Bool.self, forKey: .isAdBlockerEnabled) ?? true
        self.isTrackerBlockerEnabled = try container.decodeIfPresent(Bool.self, forKey: .isTrackerBlockerEnabled) ?? true
        self.isAnnoyanceBlockerEnabled = try container.decodeIfPresent(Bool.self, forKey: .isAnnoyanceBlockerEnabled) ?? true
        self.cookiePolicy = try container.decodeIfPresent(BrowserCookiePolicy.self, forKey: .cookiePolicy) ?? .blockThirdParty
        self.isPopupBlockerEnabled = try container.decodeIfPresent(Bool.self, forKey: .isPopupBlockerEnabled) ?? true
        self.adBlockerWhitelistedDomains = try container.decodeIfPresent([String].self, forKey: .adBlockerWhitelistedDomains) ?? []
        self.isAutomaticCategorizationEnabled = try container.decodeIfPresent(Bool.self, forKey: .isAutomaticCategorizationEnabled) ?? true
        self.customCategoryFolders = try container.decodeIfPresent([String: String].self, forKey: .customCategoryFolders) ?? [:]
        self.defaultDownloadDirectoryBookmark = try container.decodeIfPresent(Data.self, forKey: .defaultDownloadDirectoryBookmark)
        self.downloadSortOrder = try container.decodeIfPresent(DownloadSortOrder.self, forKey: .downloadSortOrder) ?? .dateAddedDesc
        self.downloadGroupingOption = try container.decodeIfPresent(DownloadGroupingOption.self, forKey: .downloadGroupingOption) ?? .none
        self.customSearchEngines = try container.decodeIfPresent([CustomSearchEngine].self, forKey: .customSearchEngines) ?? []
        let legacySearchEngine = try container.decodeIfPresent(BrowserSearchEngine.self, forKey: .browserSearchEngine) ?? .duckDuckGo
        self.browserSearchEngine = legacySearchEngine
        self.activeSearchEngineID = try container.decodeIfPresent(String.self, forKey: .activeSearchEngineID) ?? legacySearchEngine.rawValue
        self.browserHomepage = try container.decodeIfPresent(String.self, forKey: .browserHomepage) ?? "https://duckduckgo.com"
        self.restoreTabsOnLaunch = try container.decodeIfPresent(Bool.self, forKey: .restoreTabsOnLaunch) ?? true
        self.readerTheme = try container.decodeIfPresent(BrowserReaderTheme.self, forKey: .readerTheme) ?? .light
        self.readerFontFamily = try container.decodeIfPresent(BrowserReaderFontFamily.self, forKey: .readerFontFamily) ?? .serif
        self.readerFontSize = try container.decodeIfPresent(Double.self, forKey: .readerFontSize) ?? 18.0
    }

    /// Resolves the URL template of the currently active search engine (built-in or custom).
    public var effectiveActiveSearchTemplate: String {
        if let custom = customSearchEngines.first(where: { $0.id == activeSearchEngineID }) {
            return custom.urlTemplate
        }
        if let builtIn = BrowserSearchEngine(rawValue: activeSearchEngineID) {
            return builtIn.urlTemplate
        }
        return browserSearchEngine.urlTemplate
    }

    /// Resolves the human-readable display name of the currently active search engine.
    public var effectiveActiveSearchEngineName: String {
        if let custom = customSearchEngines.first(where: { $0.id == activeSearchEngineID }) {
            return custom.name
        }
        if let builtIn = BrowserSearchEngine(rawValue: activeSearchEngineID) {
            return builtIn.displayName
        }
        return browserSearchEngine.displayName
    }

    /// Resolves the effective subfolder name for a category.
    public func subfolderName(for category: DownloadCategory) -> String {
        customCategoryFolders[category.rawValue] ?? category.defaultSubfolderName
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
        let ua: String
        if let trimmed = customUserAgent?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            ua = trimmed
        } else {
            ua = "SwiftDownloadEngine/1.0 (iOS; iPadOS)"
        }

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
            allowExpensiveNetwork: allowExpensiveNetwork,
            allowConstrainedNetwork: allowConstrainedNetwork,
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
