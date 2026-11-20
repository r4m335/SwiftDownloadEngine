import Foundation
import Combine

#if canImport(WebKit)
import WebKit
#endif

/// Central composition root providing complete dependency injection across DownloadEngineKit.
///
/// Owns the unified runtime dependency graph, guarantees deterministic initialization order,
/// eliminates hidden global singletons, and allows tests to run fully isolated in custom or
/// temporary sandbox directories.
@MainActor
public final class AppCompositionRoot {

    // MARK: - Core Directories & Settings
    public let baseStorageDirectory: URL
    public let downloadsDirectory: URL
    public let userDefaults: UserDefaults
    public let configuration: EngineConfiguration

    // MARK: - Logging & Diagnostics
    public let pipelineLogger: PipelineLogger
    public let diagnosticLogger: BrowserDiagnosticLogger

    // MARK: - Security & Networking
    public let keychainManager: KeychainManager
    public let connectivityGate: NetworkConnectivityGate
    public let publicSuffixList: PublicSuffixList

    // MARK: - Persistence Stores
    public let downloadPersistenceStore: DownloadPersistenceStore
    public let hlsPersistenceStore: HLSPersistenceStore?
    public let bookmarkStore: BrowserBookmarkStore
    public let historyStore: BrowserHistoryStore
    public let sessionStore: BrowserSessionStore
    public let sitePermissionsStore: BrowserSitePermissionsStore
    public let quickAccessStore: QuickAccessStore
    public let faviconService: FaviconService
    public let tabPreviewCache: BrowserTabPreviewCache
    public let certificateDecisionStore: BrowserCertificateDecisionStore

    // MARK: - Player & Media Stores / Engines
    public let libraryStore: LIDLibraryStore
    public let playbackHistoryStore: LIDPlaybackHistoryStore
    public let playerSettingsStore: LIDPlayerSettingsStore
    public let subtitleStore: LIDSubtitleStore
    public let subtitleSearchManager: LIDSubtitleSearchManager
    public let nowPlayingCoordinator: LIDNowPlayingCoordinator
    public let playbackEngine: LIDPlaybackEngine
    public let orientationManager: LIDOrientationManager
    public let liveStreamRecorder: LiveStreamRecorder

    // MARK: - Browser Handlers
    public let contentBlocker: BrowserContentBlocker
    public let permissionCoordinator: BrowserPermissionCoordinator
    public let authenticationHandler: BrowserAuthenticationHandler
    public let promptHandler: BrowserPromptHandler
    public let streamManifestExpander: StreamManifestResourceExpander
    public let urlInspector: URLInspector

    // MARK: - Download & Streaming Core Engines
    public let downloadCoordinator: DownloadCoordinator
    public let queueManager: DownloadQueueManager
    public let downloadEngine: DownloadEngine
    public let torrentEngine: TorrentEngine?
    public let streamingOrchestrator: StreamingDownloadOrchestrator

    // MARK: - Designated Initializer

    public init(
        baseStorageDirectory: URL,
        downloadsDirectory: URL,
        userDefaults: UserDefaults = .standard,
        configuration: EngineConfiguration = .default,
        pipelineLogger: PipelineLogger = .shared,
        diagnosticLogger: BrowserDiagnosticLogger = .shared,
        keychainManager: KeychainManager = .shared,
        connectivityGate: NetworkConnectivityGate = .shared,
        publicSuffixList: PublicSuffixList = .shared,
        downloadPersistenceStore: DownloadPersistenceStore,
        hlsPersistenceStore: HLSPersistenceStore?,
        bookmarkStore: BrowserBookmarkStore,
        historyStore: BrowserHistoryStore,
        sessionStore: BrowserSessionStore,
        sitePermissionsStore: BrowserSitePermissionsStore,
        quickAccessStore: QuickAccessStore,
        faviconService: FaviconService,
        tabPreviewCache: BrowserTabPreviewCache,
        certificateDecisionStore: BrowserCertificateDecisionStore = .shared,
        libraryStore: LIDLibraryStore,
        playbackHistoryStore: LIDPlaybackHistoryStore,
        playerSettingsStore: LIDPlayerSettingsStore,
        subtitleStore: LIDSubtitleStore,
        subtitleSearchManager: LIDSubtitleSearchManager,
        nowPlayingCoordinator: LIDNowPlayingCoordinator = .shared,
        playbackEngine: LIDPlaybackEngine,
        orientationManager: LIDOrientationManager = .shared,
        liveStreamRecorder: LiveStreamRecorder,
        contentBlocker: BrowserContentBlocker = .shared,
        permissionCoordinator: BrowserPermissionCoordinator = .shared,
        authenticationHandler: BrowserAuthenticationHandler = .shared,
        promptHandler: BrowserPromptHandler = .shared,
        streamManifestExpander: StreamManifestResourceExpander = .shared,
        urlInspector: URLInspector = .shared,
        downloadCoordinator: DownloadCoordinator,
        queueManager: DownloadQueueManager,
        downloadEngine: DownloadEngine,
        torrentEngine: TorrentEngine? = nil,
        streamingOrchestrator: StreamingDownloadOrchestrator
    ) {
        self.baseStorageDirectory = baseStorageDirectory
        self.downloadsDirectory = downloadsDirectory
        self.userDefaults = userDefaults
        self.configuration = configuration
        self.pipelineLogger = pipelineLogger
        self.diagnosticLogger = diagnosticLogger
        self.keychainManager = keychainManager
        self.connectivityGate = connectivityGate
        self.publicSuffixList = publicSuffixList
        self.downloadPersistenceStore = downloadPersistenceStore
        self.hlsPersistenceStore = hlsPersistenceStore
        self.bookmarkStore = bookmarkStore
        self.historyStore = historyStore
        self.sessionStore = sessionStore
        self.sitePermissionsStore = sitePermissionsStore
        self.quickAccessStore = quickAccessStore
        self.faviconService = faviconService
        self.tabPreviewCache = tabPreviewCache
        self.certificateDecisionStore = certificateDecisionStore
        self.libraryStore = libraryStore
        self.playbackHistoryStore = playbackHistoryStore
        self.playerSettingsStore = playerSettingsStore
        self.subtitleStore = subtitleStore
        self.subtitleSearchManager = subtitleSearchManager
        self.nowPlayingCoordinator = nowPlayingCoordinator
        self.playbackEngine = playbackEngine
        self.orientationManager = orientationManager
        self.liveStreamRecorder = liveStreamRecorder
        self.contentBlocker = contentBlocker
        self.permissionCoordinator = permissionCoordinator
        self.authenticationHandler = authenticationHandler
        self.promptHandler = promptHandler
        self.streamManifestExpander = streamManifestExpander
        self.urlInspector = urlInspector
        self.downloadCoordinator = downloadCoordinator
        self.queueManager = queueManager
        self.downloadEngine = downloadEngine
        self.torrentEngine = torrentEngine
        self.streamingOrchestrator = streamingOrchestrator

        // Explicitly wire engines and orchestrator without touching mutable globals
        Task {
            await downloadEngine.setStreamingOrchestrator(streamingOrchestrator)
            await streamingOrchestrator.setDownloadEngine(downloadEngine)
        }
    }

    // MARK: - Live Production Composition

    /// Assembles the complete production runtime dependency graph.
    public static func live(
        storageDirectory: URL? = nil,
        downloadsDirectory: URL? = nil,
        userDefaults: UserDefaults = .standard,
        backgroundSessionManager: BackgroundDownloadSessionManager? = nil
    ) -> AppCompositionRoot {
        let fileManager = FileManager.default

        // 1. Resolve storage and downloads directories
        let storeDir: URL
        if let customStorage = storageDirectory {
            storeDir = customStorage
        } else if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            storeDir = appSupport.appendingPathComponent("SwiftDownloadEngine", isDirectory: true)
        } else {
            storeDir = DownloadManagerViewModel.defaultDownloadsDirectory().appendingPathComponent(".store", isDirectory: true)
        }
        try? fileManager.createDirectory(at: storeDir, withIntermediateDirectories: true)

        let resolvedDownloads = downloadsDirectory ?? DownloadManagerViewModel.defaultDownloadsDirectory()
        try? fileManager.createDirectory(at: resolvedDownloads, withIntermediateDirectories: true)

        // 2. Settings & EngineConfiguration
        let settings = AppSettings.load(from: userDefaults)
        let config = settings.makeEngineConfiguration()

        // 3. Shared Singletons & Loggers
        let pipelineLogger = PipelineLogger.shared
        let diagnosticLogger = BrowserDiagnosticLogger.shared
        let keychain = KeychainManager.shared
        let connectivityGate = NetworkConnectivityGate.shared
        let psl = PublicSuffixList.shared

        // 4. Persistence Stores
        let persistence: DownloadPersistenceStore
        do {
            persistence = try DownloadPersistenceStore(storageDirectoryURL: storeDir)
        } catch {
            pipelineLogger.log(stage: .persistence, message: "Live persistence init failed at \(storeDir.path): \(error). Using inMemory fallback.")
            persistence = DownloadPersistenceStore(inMemory: true)
        }

        let hlsStore: HLSPersistenceStore?
        do {
            hlsStore = try HLSPersistenceStore(storageDirectoryURL: persistence.storageDirectoryURL)
        } catch {
            pipelineLogger.log(stage: .persistence, message: "Live HLSPersistenceStore init failed: \(error)")
            hlsStore = nil
        }

        let browserDir = storeDir.appendingPathComponent("Browser", isDirectory: true)
        try? fileManager.createDirectory(at: browserDir, withIntermediateDirectories: true)

        let bookmarkStore = BrowserBookmarkStore(customStorageURL: browserDir.appendingPathComponent("bookmarks.json"))
        let historyStore = BrowserHistoryStore(customStorageURL: browserDir.appendingPathComponent("history.json"))
        let sessionStore = BrowserSessionStore(fileURL: browserDir.appendingPathComponent("lid_browser_session.json"))
        let sitePermissionsStore = BrowserSitePermissionsStore(storageURL: browserDir.appendingPathComponent("lid_site_permissions.json"))
        let quickAccessStore = QuickAccessStore(defaults: userDefaults, customStorageURL: browserDir.appendingPathComponent("quick_access.json"))
        let faviconService = FaviconService.shared
        let tabPreviewCache = BrowserTabPreviewCache(customCacheDirectoryURL: browserDir.appendingPathComponent("TabPreviews", isDirectory: true))
        let certStore = BrowserCertificateDecisionStore.shared

        // 5. Media & Subtitle Stores
        let libraryDir = storeDir.appendingPathComponent("Library", isDirectory: true)
        try? fileManager.createDirectory(at: libraryDir, withIntermediateDirectories: true)

        let historyURL = storeDir.appendingPathComponent("playback_history.json")
        let playbackHistoryStore = LIDPlaybackHistoryStore(storageURL: historyURL)
        let libraryStore = LIDLibraryStore(storageDirectory: libraryDir, historyStore: playbackHistoryStore)
        let playerSettingsStore = LIDPlayerSettingsStore(userDefaults: userDefaults)
        let subtitleStore = LIDSubtitleStore(storageDirectory: storeDir.appendingPathComponent("Subtitles", isDirectory: true))
        let subtitleSearchManager = LIDSubtitleSearchManager()
        let nowPlayingCoordinator = LIDNowPlayingCoordinator.shared
        let playbackEngine = LIDPlaybackEngine(
            historyStore: playbackHistoryStore,
            nowPlayingCoordinator: nowPlayingCoordinator,
            playerSettingsStore: playerSettingsStore,
            subtitleSearchManager: subtitleSearchManager,
            subtitleStore: subtitleStore
        )
        let orientationManager = LIDOrientationManager.shared
        let liveStreamRecorder = LiveStreamRecorder(libraryStore: libraryStore)

        // 6. Browser Coordinators & Handlers
        let contentBlocker = BrowserContentBlocker.shared
        let permissionCoordinator = BrowserPermissionCoordinator.shared
        let authenticationHandler = BrowserAuthenticationHandler.shared
        let promptHandler = BrowserPromptHandler.shared
        let streamManifestExpander = StreamManifestResourceExpander.shared
        let urlInspector = URLInspector.shared

        // 7. Core Transfer Engines
        let session = ForegroundURLSession.make(maximumConnectionsPerHost: SegmentAllocator.maxThreadCount)
        let budget = SharedRequestBudget(maxGlobalRequests: config.maxGlobalRequests)
        let limiter = BandwidthLimiter(bytesPerSecond: config.globalBandwidthLimitBytesPerSecond)

        let coordinator: DownloadCoordinator
        do {
            coordinator = try DownloadCoordinator(
                session: session,
                persistenceStore: persistence,
                requestBudget: budget,
                globalBandwidthLimiter: limiter,
                backgroundSessionManager: backgroundSessionManager
            )
        } catch {
            fatalError("Failed to initialize production DownloadCoordinator: \(error)")
        }

        let queueManager = DownloadQueueManager(
            coordinator: coordinator,
            persistenceStore: persistence,
            maxConcurrentDownloads: config.maxConcurrentDownloads
        )

        let downloadEngine = DownloadEngine(
            configuration: config,
            queueManager: queueManager,
            coordinator: coordinator,
            persistenceStore: persistence
        )

        var torrentEngine: TorrentEngine? = nil
        do {
            let torrentStorage = storeDir.appendingPathComponent("Torrents", isDirectory: true)
            try? fileManager.createDirectory(at: torrentStorage, withIntermediateDirectories: true)
            torrentEngine = try TorrentEngine(
                configuration: config,
                storageDirectoryURL: torrentStorage
            )
            if let te = torrentEngine {
                playbackEngine.configure(torrentEngine: te)
            }
        } catch {
            pipelineLogger.log(stage: .coordinator, message: "TorrentEngine initialization skipped: \(error)")
        }

        let streamingOrchestrator = StreamingDownloadOrchestrator(
            configuration: config,
            downloadCoordinator: coordinator,
            downloadEngine: downloadEngine,
            hlsPersistenceStore: hlsStore
        )

        return AppCompositionRoot(
            baseStorageDirectory: storeDir,
            downloadsDirectory: resolvedDownloads,
            userDefaults: userDefaults,
            configuration: config,
            pipelineLogger: pipelineLogger,
            diagnosticLogger: diagnosticLogger,
            keychainManager: keychain,
            connectivityGate: connectivityGate,
            publicSuffixList: psl,
            downloadPersistenceStore: persistence,
            hlsPersistenceStore: hlsStore,
            bookmarkStore: bookmarkStore,
            historyStore: historyStore,
            sessionStore: sessionStore,
            sitePermissionsStore: sitePermissionsStore,
            quickAccessStore: quickAccessStore,
            faviconService: faviconService,
            tabPreviewCache: tabPreviewCache,
            certificateDecisionStore: certStore,
            libraryStore: libraryStore,
            playbackHistoryStore: playbackHistoryStore,
            playerSettingsStore: playerSettingsStore,
            subtitleStore: subtitleStore,
            subtitleSearchManager: subtitleSearchManager,
            nowPlayingCoordinator: nowPlayingCoordinator,
            playbackEngine: playbackEngine,
            orientationManager: orientationManager,
            liveStreamRecorder: liveStreamRecorder,
            contentBlocker: contentBlocker,
            permissionCoordinator: permissionCoordinator,
            authenticationHandler: authenticationHandler,
            promptHandler: promptHandler,
            streamManifestExpander: streamManifestExpander,
            urlInspector: urlInspector,
            downloadCoordinator: coordinator,
            queueManager: queueManager,
            downloadEngine: downloadEngine,
            torrentEngine: torrentEngine,
            streamingOrchestrator: streamingOrchestrator
        )
    }

    // MARK: - Isolated Testing Composition

    /// Assembles a completely isolated dependency graph sandboxed inside `rootDirectory`.
    /// Guarantees that tests never read or write shared singletons, system paths, or shared UserDefaults.
    public static func isolatedForTesting(
        rootDirectory: URL,
        userDefaults: UserDefaults? = nil,
        configuration: EngineConfiguration = .default
    ) throws -> AppCompositionRoot {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)

        let storeDir = rootDirectory.appendingPathComponent("Storage", isDirectory: true)
        let downloadsDir = rootDirectory.appendingPathComponent("Downloads", isDirectory: true)
        let browserDir = rootDirectory.appendingPathComponent("Browser", isDirectory: true)
        let libraryDir = rootDirectory.appendingPathComponent("Library", isDirectory: true)
        let subtitlesDir = rootDirectory.appendingPathComponent("Subtitles", isDirectory: true)

        try fileManager.createDirectory(at: storeDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: browserDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: libraryDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: subtitlesDir, withIntermediateDirectories: true)

        let defaults = userDefaults ?? UserDefaults(suiteName: "Test_\(UUID().uuidString)") ?? .standard

        let pipelineLogger = PipelineLogger()
        let diagnosticLogger = BrowserDiagnosticLogger()
        let keychain = KeychainManager()
        let connectivityGate = NetworkConnectivityGate()
        let psl = PublicSuffixList()

        let persistence = try DownloadPersistenceStore(storageDirectoryURL: storeDir)
        let hlsStore = try HLSPersistenceStore(storageDirectoryURL: storeDir)

        let bookmarkStore = BrowserBookmarkStore(customStorageURL: browserDir.appendingPathComponent("bookmarks.json"))
        let historyStore = BrowserHistoryStore(customStorageURL: browserDir.appendingPathComponent("history.json"))
        let sessionStore = BrowserSessionStore(fileURL: browserDir.appendingPathComponent("lid_browser_session.json"))
        let sitePermissionsStore = BrowserSitePermissionsStore(storageURL: browserDir.appendingPathComponent("lid_site_permissions.json"))
        let quickAccessStore = QuickAccessStore(defaults: defaults, customStorageURL: browserDir.appendingPathComponent("quick_access.json"))
        let faviconService = FaviconService(session: .shared)
        let tabPreviewCache = BrowserTabPreviewCache(customCacheDirectoryURL: browserDir.appendingPathComponent("TabPreviews", isDirectory: true))
        let certStore = BrowserCertificateDecisionStore()

        let historyURL = storeDir.appendingPathComponent("playback_history.json")
        let playbackHistoryStore = LIDPlaybackHistoryStore(storageURL: historyURL)
        let libraryStore = LIDLibraryStore(storageDirectory: libraryDir, historyStore: playbackHistoryStore)
        let playerSettingsStore = LIDPlayerSettingsStore(userDefaults: defaults)
        let subtitleStore = LIDSubtitleStore(storageDirectory: subtitlesDir)
        let subtitleSearchManager = LIDSubtitleSearchManager()
        let nowPlayingCoordinator = LIDNowPlayingCoordinator()
        let playbackEngine = LIDPlaybackEngine(
            historyStore: playbackHistoryStore,
            nowPlayingCoordinator: nowPlayingCoordinator,
            playerSettingsStore: playerSettingsStore,
            subtitleSearchManager: subtitleSearchManager,
            subtitleStore: subtitleStore
        )
        let orientationManager = LIDOrientationManager()
        let liveStreamRecorder = LiveStreamRecorder(libraryStore: libraryStore)

        let contentBlocker = BrowserContentBlocker()
        let permissionCoordinator = BrowserPermissionCoordinator()
        let authenticationHandler = BrowserAuthenticationHandler(keychain: keychain)
        let promptHandler = BrowserPromptHandler()
        let streamManifestExpander = StreamManifestResourceExpander()
        let urlInspector = URLInspector()

        let session = ForegroundURLSession.make(maximumConnectionsPerHost: SegmentAllocator.maxThreadCount)
        let budget = SharedRequestBudget(maxGlobalRequests: configuration.maxGlobalRequests)
        let limiter = BandwidthLimiter(bytesPerSecond: configuration.globalBandwidthLimitBytesPerSecond)

        let coordinator = try DownloadCoordinator(
            session: session,
            persistenceStore: persistence,
            requestBudget: budget,
            globalBandwidthLimiter: limiter,
            backgroundSessionManager: nil
        )

        let queueManager = DownloadQueueManager(
            coordinator: coordinator,
            persistenceStore: persistence,
            maxConcurrentDownloads: configuration.maxConcurrentDownloads
        )

        let downloadEngine = DownloadEngine(
            configuration: configuration,
            queueManager: queueManager,
            coordinator: coordinator,
            persistenceStore: persistence
        )

        var torrentEngine: TorrentEngine? = nil
        do {
            let torrentStorage = storeDir.appendingPathComponent("Torrents", isDirectory: true)
            try? fileManager.createDirectory(at: torrentStorage, withIntermediateDirectories: true)
            torrentEngine = try TorrentEngine(
                configuration: configuration,
                storageDirectoryURL: torrentStorage
            )
            if let te = torrentEngine {
                playbackEngine.configure(torrentEngine: te)
            }
        } catch {
            pipelineLogger.log(stage: .coordinator, message: "Isolated TorrentEngine initialization skipped: \(error)")
        }

        let streamingOrchestrator = StreamingDownloadOrchestrator(
            configuration: configuration,
            downloadCoordinator: coordinator,
            downloadEngine: downloadEngine,
            hlsPersistenceStore: hlsStore
        )

        return AppCompositionRoot(
            baseStorageDirectory: storeDir,
            downloadsDirectory: downloadsDir,
            userDefaults: defaults,
            configuration: configuration,
            pipelineLogger: pipelineLogger,
            diagnosticLogger: diagnosticLogger,
            keychainManager: keychain,
            connectivityGate: connectivityGate,
            publicSuffixList: psl,
            downloadPersistenceStore: persistence,
            hlsPersistenceStore: hlsStore,
            bookmarkStore: bookmarkStore,
            historyStore: historyStore,
            sessionStore: sessionStore,
            sitePermissionsStore: sitePermissionsStore,
            quickAccessStore: quickAccessStore,
            faviconService: faviconService,
            tabPreviewCache: tabPreviewCache,
            certificateDecisionStore: certStore,
            libraryStore: libraryStore,
            playbackHistoryStore: playbackHistoryStore,
            playerSettingsStore: playerSettingsStore,
            subtitleStore: subtitleStore,
            subtitleSearchManager: subtitleSearchManager,
            nowPlayingCoordinator: nowPlayingCoordinator,
            playbackEngine: playbackEngine,
            orientationManager: orientationManager,
            liveStreamRecorder: liveStreamRecorder,
            contentBlocker: contentBlocker,
            permissionCoordinator: permissionCoordinator,
            authenticationHandler: authenticationHandler,
            promptHandler: promptHandler,
            streamManifestExpander: streamManifestExpander,
            urlInspector: urlInspector,
            downloadCoordinator: coordinator,
            queueManager: queueManager,
            downloadEngine: downloadEngine,
            torrentEngine: torrentEngine,
            streamingOrchestrator: streamingOrchestrator
        )
    }

    // MARK: - View Model Factories

    /// Creates a fully injected `DownloadManagerViewModel` without relying on any global shared instances.
    @MainActor
    public func makeDownloadManagerViewModel() -> DownloadManagerViewModel {
        DownloadManagerViewModel(
            engine: downloadEngine,
            torrentEngine: torrentEngine,
            downloadsDirectory: downloadsDirectory,
            userDefaults: userDefaults,
            streamingOrchestrator: streamingOrchestrator
        )
    }

    /// Creates a fully injected `BrowserViewModel` wiring all sandboxed stores, coordinators, and handlers.
    @MainActor
    public func makeBrowserViewModel(
        downloadDelegate: BrowserDownloadDelegate? = nil,
        magnetDelegate: (any BrowserMagnetDelegate)? = nil,
        onDownloadInitiated: (() -> Void)? = nil,
        onOpenAddDownload: ((URL) -> Void)? = nil,
        onOpenDownloads: (() -> Void)? = nil
    ) -> BrowserViewModel {
        BrowserViewModel(
            downloadDelegate: downloadDelegate,
            magnetDelegate: magnetDelegate,
            onDownloadInitiated: onDownloadInitiated,
            onOpenAddDownload: onOpenAddDownload,
            onOpenDownloads: onOpenDownloads,
            streamingOrchestrator: streamingOrchestrator,
            streamingDestinationDirectoryURL: downloadsDirectory,
            sessionStore: sessionStore,
            bookmarkStore: bookmarkStore,
            historyStore: historyStore,
            sitePermissionsStore: sitePermissionsStore,
            quickAccessStore: quickAccessStore,
            faviconService: faviconService,
            tabPreviewCache: tabPreviewCache,
            certificateDecisionStore: certificateDecisionStore,
            contentBlocker: contentBlocker,
            permissionCoordinator: permissionCoordinator,
            promptHandler: promptHandler,
            authenticationHandler: authenticationHandler,
            diagnosticLogger: diagnosticLogger,
            streamManifestExpander: streamManifestExpander
        )
    }

    /// Creates an injected `LIDPlayerView` configured with this composition root's playback engine and orientation manager.
    @MainActor
    public func makePlayerView(
        source: LIDPlayerSource,
        onDismiss: (() -> Void)? = nil
    ) -> LIDPlayerView {
        LIDPlayerView(
            source: source,
            engine: playbackEngine,
            playerSettingsStore: playerSettingsStore,
            orientationManager: orientationManager,
            onDismiss: onDismiss
        )
    }

    /// Creates an injected `LIDPlayerLibraryView` configured with this composition root's library and history stores.
    @MainActor
    public func makePlayerLibraryView(
        knownTransfers: [UnifiedTransfer] = [],
        onDismiss: (() -> Void)? = nil
    ) -> LIDPlayerLibraryView {
        LIDPlayerLibraryView(
            baseDirectory: downloadsDirectory,
            knownTransfers: knownTransfers,
            libraryStore: libraryStore,
            historyStore: playbackHistoryStore,
            onDismiss: onDismiss
        )
    }
}
