import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if canImport(Combine)
import Combine
#else
/// Cross-platform fallback for Combine's ObservableObject on non-Apple environments.
public protocol ObservableObject: AnyObject {}

/// Cross-platform fallback for Combine's @Published property wrapper on non-Apple environments.
@propertyWrapper
public struct Published<Value> {
    public var wrappedValue: Value

    public init(wrappedValue: Value) {
        self.wrappedValue = wrappedValue
    }

    public var projectedValue: Published<Value> {
        get { self }
        set { self = newValue }
    }
}
#endif

/// UI filter options for the download manager list.
public enum DownloadFilter: String, CaseIterable, Sendable, Identifiable {
    case all = "All"
    case active = "Active"
    case paused = "Paused"
    case completed = "Completed"
    case failed = "Failed"

    public var id: String { rawValue }
}

/// Main-actor isolated view model bridging `DownloadEngine` and `TorrentEngine` to UI layers (SwiftUI / UIKit).
///
/// Features:
/// - Real-Time Observation: Conforms directly to `ObservableObject` with `@Published` state properties for automatic SwiftUI view redraws.
/// - Event Stream Subscription: Subscribes to `engine.events()` via an `AsyncStream<DownloadEvent>` and updates UI state.
/// - Unified Presentation: Merges HTTP snapshots and BitTorrent tasks into `unifiedTransfers` for consistent presentation.
/// - Authoritative Snapshot Sync: Keeps live snapshots without diverging from underlying queue/persistence.
/// - Action Dispatching: Exposes pause, resume, cancel, retry, remove, and add operations for both HTTP and BitTorrent.
/// - Configurable Settings & Persistence: Manages concurrency limits, request budgets, and bandwidth throttling, persisted via `UserDefaults`.
/// - Robust Edge-Case Handling: Validates input domains, sanitizes limits, manages stream lifecycle restarts, and surfaces user-facing errors.
@MainActor
public final class DownloadManagerViewModel: ObservableObject, @unchecked Sendable {
    public let engine: DownloadEngine
    public let torrentEngine: TorrentEngine?
    public let downloadsDirectoryURL: URL
    private let userDefaults: UserDefaults

    public enum SettingsKeys {
        public static let maxConcurrentDownloads = "SwiftDownloadEngine.maxConcurrentDownloads"
        public static let maxGlobalRequests = "SwiftDownloadEngine.maxGlobalRequests"
        public static let globalBandwidthLimit = "SwiftDownloadEngine.globalBandwidthLimit"
        public static let maxConcurrentTorrents = "SwiftDownloadEngine.maxConcurrentTorrents"
        public static let defaultTorrentPriority = "SwiftDownloadEngine.defaultTorrentPriority"
        public static let defaultSeedingMode = "SwiftDownloadEngine.defaultSeedingMode"
        public static let defaultSeedingRatio = "SwiftDownloadEngine.defaultSeedingRatio"
        public static let defaultSeedingDuration = "SwiftDownloadEngine.defaultSeedingDuration"
    }

    // HTTP-specific published properties (backward compatible)
    @Published public var downloads: [DownloadSnapshot] = []
    @Published public var selectedDownload: DownloadSnapshot? = nil
    @Published public var queueSummary: QueueSnapshot? = nil

    // Torrent-specific published properties
    @Published public var torrentTasks: [TorrentTask] = []
    @Published public var torrentQueueSummary: TorrentQueueSnapshot? = nil
    @Published public var torrentSessionStatus: TorrentSessionStatus? = nil
    @Published public var torrentFilesCache: [String: [TorrentFileInfo]] = [:]

    // Unified presentation properties
    @Published public var unifiedTransfers: [UnifiedTransfer] = []
    @Published public var selectedTransfer: UnifiedTransfer? = nil

    @Published public var filterText: String = ""
    @Published public var selectedFilter: DownloadFilter = .all

    // Codable UI Settings Model
    @Published public var appSettings: AppSettings

    /// Live active decoupled EngineConfiguration mapped from UI settings.
    public var activeEngineConfiguration: EngineConfiguration {
        appSettings.makeEngineConfiguration()
    }

    // HTTP Settings
    @Published public var maxConcurrentDownloads: Int = 3
    @Published public var maxGlobalRequests: Int = 12
    @Published public var globalBandwidthLimitBytesPerSecond: Int64? = nil

    // Torrent Settings
    @Published public var maxConcurrentTorrents: Int = 3
    @Published public var defaultTorrentPriority: TorrentPriority = .normal
    @Published public var defaultSeedingPreference: SeedingPreference = SeedingPreference(mode: .ratio, targetRatio: 1.0)

    // Schedule Coordinator & Rules
    public let scheduleCoordinator: ScheduleCoordinator
    @Published public var scheduleRules: [ScheduleRule] = []

    /// Dynamic active listening port string formatted for UI inspection.
    public var torrentActivePortString: String {
        guard let status = torrentSessionStatus, status.isListening else {
            return "Inactive"
        }
        return "\(status.listenPort) (TCP/UDP)"
    }

    /// Configured listening port range string for UI display.
    public var torrentPortRangeString: String {
        if let status = torrentSessionStatus {
            return "\(status.portRange.lowerBound) – \(status.portRange.upperBound) (TCP/UDP)"
        }
        return "6881 – 6891 (TCP/UDP)"
    }

    @Published public var errorMessage: String? = nil
    @Published public var userNotificationMessage: String? = nil
    @Published public var isObserving: Bool = false

    private var eventTask: Task<Void, Never>? = nil
    private var torrentRefreshTask: Task<Void, Never>? = nil

    /// Resolves the default destination downloads directory.
    public static func defaultDownloadsDirectory() -> URL {
        let fileManager = FileManager.default
        let baseDir: URL
        if let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            baseDir = docs.appendingPathComponent("Downloads", isDirectory: true)
        } else {
            baseDir = fileManager.temporaryDirectory.appendingPathComponent("1DMDownloads", isDirectory: true)
        }
        try? fileManager.createDirectory(at: baseDir, withIntermediateDirectories: true)
        return baseDir
    }

    public init(
        engine: DownloadEngine,
        torrentEngine: TorrentEngine? = nil,
        downloadsDirectory: URL? = nil,
        userDefaults: UserDefaults = .standard
    ) {
        self.engine = engine
        self.torrentEngine = torrentEngine
        self.downloadsDirectoryURL = downloadsDirectory ?? Self.defaultDownloadsDirectory()
        self.userDefaults = userDefaults
        self.scheduleCoordinator = ScheduleCoordinator(
            engine: engine,
            persistenceStore: engine.persistenceStore
        )

        var loadedSettings = AppSettings.load(from: userDefaults)
        let legacyConcurrent = userDefaults.integer(forKey: SettingsKeys.maxConcurrentDownloads)
        if legacyConcurrent > 0 {
            loadedSettings.maxConcurrentDownloads = legacyConcurrent
        }
        let legacyRequests = userDefaults.integer(forKey: SettingsKeys.maxGlobalRequests)
        if legacyRequests > 0 {
            loadedSettings.maxGlobalRequests = legacyRequests
        }
        if let rawLimit = userDefaults.object(forKey: SettingsKeys.globalBandwidthLimit) as? NSNumber {
            let limit = rawLimit.int64Value
            if limit > 0 {
                loadedSettings.enableGlobalSpeedLimit = true
                loadedSettings.globalSpeedLimitKBps = Int(limit / 1024)
                loadedSettings.globalBandwidthLimitBytes = limit
            }
        }
        let legacyTorrents = userDefaults.integer(forKey: SettingsKeys.maxConcurrentTorrents)
        if legacyTorrents > 0 {
            loadedSettings.maxConcurrentTorrents = legacyTorrents
        }
        if let legacyPriorityRaw = userDefaults.object(forKey: SettingsKeys.defaultTorrentPriority) as? Int,
           let prio = TorrentPriority(rawValue: legacyPriorityRaw) {
            loadedSettings.defaultTorrentPriority = prio
        }
        self.appSettings = loadedSettings

        self.maxConcurrentDownloads = loadedSettings.maxConcurrentDownloads
        self.maxGlobalRequests = loadedSettings.maxGlobalRequests
        self.globalBandwidthLimitBytesPerSecond = loadedSettings.enableGlobalSpeedLimit
            ? (loadedSettings.globalBandwidthLimitBytes ?? Int64(loadedSettings.globalSpeedLimitKBps) * 1024)
            : nil

        self.maxConcurrentTorrents = loadedSettings.maxConcurrentTorrents
        self.defaultTorrentPriority = loadedSettings.defaultTorrentPriority
        self.defaultSeedingPreference = SeedingPreference(
            mode: loadedSettings.seedingMode,
            targetRatio: loadedSettings.targetRatio,
            targetDurationSeconds: TimeInterval(loadedSettings.targetDurationMinutes * 60)
        )

        Task { [weak self] in
            await self?.loadScheduleRules()
        }
    }

    // MARK: - Event Subscription & Synchronization

    /// Starts observing asynchronous events from `DownloadEngine` and `TorrentEngine`.
    public func startObserving() async {
        guard !isObserving else { return }
        isObserving = true

        // Apply persisted settings to the underlying engine
        try? await applyPersistedSettings()

        // Automatically restore persistent queue on boot
        try? await engine.restoreQueue(autoStart: false)

        // Initialize and start torrent engine if available
        if let te = torrentEngine {
            try? await te.start()
            try? await te.setMaxConcurrentTorrents(maxConcurrentTorrents)
            startTorrentPolling()
        }

        // Fetch authoritative initial snapshots
        await refreshSnapshots()

        // Listen for real-time background events from HTTP engine
        eventTask?.cancel()
        let stream = await engine.events()
        eventTask = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { break }
                self?.handleEngineEvent(event)
            }
            if !Task.isCancelled {
                self?.isObserving = false
            }
        }
    }

    /// Stops observing engine events and polling.
    public func stopObserving() {
        eventTask?.cancel()
        eventTask = nil
        torrentRefreshTask?.cancel()
        torrentRefreshTask = nil
        isObserving = false
    }

    /// Starts the underlying BitTorrent engine and initiates background snapshot polling.
    public func startTorrentEngine() async throws {
        guard let te = torrentEngine else { return }
        try await te.start()
        try await te.setMaxConcurrentTorrents(maxConcurrentTorrents)
        startTorrentPolling()
        await refreshTorrentSnapshots()
    }

    /// Stops the underlying BitTorrent engine, saving state and canceling polling.
    public func stopTorrentEngine() async throws {
        torrentRefreshTask?.cancel()
        torrentRefreshTask = nil
        if let te = torrentEngine {
            await te.stop()
        }
        await refreshTorrentSnapshots()
    }

    private func startTorrentPolling() {
        torrentRefreshTask?.cancel()
        torrentRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5s
                guard !Task.isCancelled else { break }
                await self?.refreshTorrentSnapshots()
            }
        }
    }

    /// Reloads all download records directly from both engines.
    public func refreshSnapshots() async {
        let snaps = await engine.allSnapshots()
        self.downloads = snaps
        self.queueSummary = await engine.queueSnapshot()

        if let selected = selectedDownload, let updated = snaps.first(where: { $0.id == selected.id }) {
            self.selectedDownload = updated
        }

        if let te = torrentEngine {
            self.torrentTasks = await te.allTasks()
            self.torrentQueueSummary = await te.queueSnapshot()
            self.torrentSessionStatus = await te.status()
        }

        rebuildUnifiedTransfers()
    }

    /// Reloads torrent snapshots directly from `TorrentEngine`.
    public func refreshTorrentSnapshots() async {
        guard let te = torrentEngine else { return }
        self.torrentTasks = await te.allTasks()
        self.torrentQueueSummary = await te.queueSnapshot()
        self.torrentSessionStatus = await te.status()
        rebuildUnifiedTransfers()
    }

    private func rebuildUnifiedTransfers() {
        let httpTransfers = downloads.map { UnifiedTransfer(from: $0) }
        let torrentTransfers = torrentTasks.map { UnifiedTransfer(from: $0) }
        var combined = httpTransfers + torrentTransfers
        combined.sort { $0.createdAt > $1.createdAt }
        self.unifiedTransfers = combined

        if let selected = selectedTransfer, let updated = combined.first(where: { $0.id == selected.id }) {
            self.selectedTransfer = updated
        }
    }

    private func handleEngineEvent(_ event: DownloadEvent) {
        switch event {
        case .added(let snap),
             .queued(let snap),
             .started(let snap),
             .progressUpdated(let snap),
             .paused(let snap),
             .resumed(let snap),
             .completed(let snap),
             .failed(let snap, _),
             .cancelled(let snap):
            upsertSnapshot(snap)

        case .removed(let id):
            downloads.removeAll { $0.id == id }
            if selectedDownload?.id == id {
                selectedDownload = nil
            }
            rebuildUnifiedTransfers()

        case .integrityVerified(let id, let outcome):
            if let index = downloads.firstIndex(where: { $0.id == id }) {
                let existing = downloads[index]
                let updated = DownloadSnapshot(
                    id: existing.id,
                    url: existing.url,
                    destinationURL: existing.destinationURL,
                    state: existing.state,
                    priority: existing.priority,
                    completedBytes: existing.completedBytes,
                    totalBytes: existing.totalBytes,
                    progressFraction: existing.progressFraction,
                    currentBytesPerSecond: existing.currentBytesPerSecond,
                    averageBytesPerSecond: existing.averageBytesPerSecond,
                    elapsedTime: existing.elapsedTime,
                    estimatedTimeRemaining: existing.estimatedTimeRemaining,
                    failureReason: existing.failureReason,
                    checksumOutcome: outcome,
                    enqueuedAt: existing.enqueuedAt,
                    transportPolicy: existing.transportPolicy,
                    networkPolicy: existing.networkPolicy
                )
                downloads[index] = updated
                if selectedDownload?.id == id {
                    selectedDownload = updated
                }
                rebuildUnifiedTransfers()
            }

        case .queueStateChanged(let summary):
            self.queueSummary = summary
        }
    }

    public func updateNetworkPolicy(for id: String, policy: DownloadNetworkPolicy) async {
        if let index = downloads.firstIndex(where: { $0.id == id }) {
            var existing = downloads[index]
            existing.networkPolicy = policy
            downloads[index] = existing
            if selectedDownload?.id == id {
                selectedDownload = existing
            }
            rebuildUnifiedTransfers()
        }
        _ = try? await engine.coordinator.persistenceStore.updateNetworkPolicy(tag: id, policy: policy)
    }

    private func upsertSnapshot(_ snap: DownloadSnapshot) {
        if let index = downloads.firstIndex(where: { $0.id == snap.id }) {
            downloads[index] = snap
        } else {
            downloads.append(snap)
        }

        if selectedDownload?.id == snap.id {
            selectedDownload = snap
        }
        rebuildUnifiedTransfers()
    }

    // MARK: - Filtered Views

    /// Returns downloads matching current search query and status filter.
    public var filteredDownloads: [DownloadSnapshot] {
        downloads.filter { snap in
            if !filterText.isEmpty {
                let filename = snap.destinationURL.lastPathComponent.lowercased()
                let urlString = snap.url.absoluteString.lowercased()
                let query = filterText.lowercased()
                guard filename.contains(query) || urlString.contains(query) else {
                    return false
                }
            }

            switch selectedFilter {
            case .all:
                return true
            case .active:
                return snap.state == .downloading || snap.state == .probing
            case .paused:
                return snap.state == .paused
            case .completed:
                return snap.state == .completed
            case .failed:
                if case .failed = snap.state { return true }
                return false
            }
        }
    }

    /// Returns unified transfers (HTTP + Torrent) matching current search query and status filter.
    public var filteredTransfers: [UnifiedTransfer] {
        unifiedTransfers.filter { item in
            if !filterText.isEmpty {
                let query = filterText.lowercased()
                let nameMatches = item.name.lowercased().contains(query)
                let sourceMatches = item.source.lowercased().contains(query)
                let hashMatches = item.infoHash?.lowercased().contains(query) ?? false
                guard nameMatches || sourceMatches || hashMatches else {
                    return false
                }
            }

            switch selectedFilter {
            case .all:
                return true
            case .active:
                return item.state == .downloading || item.state == .seeding
            case .paused:
                return item.state == .paused
            case .completed:
                return item.state == .completed
            case .failed:
                if case .failed = item.state { return true }
                return false
            }
        }
    }

    // MARK: - Download Lifecycle Actions (HTTP)

    @discardableResult
    public func addDownload(
        urlText: String,
        filename: String? = nil,
        threadCount: Int = 6,
        speedLimitBytesPerSecond: Int64? = nil,
        headers: [String: String] = [:],
        persistSensitiveHeaders: Bool = true,
        transportPolicy: HTTPTransportPolicy = .foreground,
        autoStart: Bool = true
    ) async throws -> DownloadSnapshot {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = url.host, !host.isEmpty else {
            let error = "Invalid URL: must be an http or https address with a valid host."
            self.errorMessage = error
            throw DownloadCoordinatorError.invalidRequest(reason: error)
        }
        let manifestKind = StreamingManifestClassifier.classify(url: url).kind
        if manifestKind == .hls || manifestKind == .dash || url.pathExtension.lowercased() == "m3u8" || url.pathExtension.lowercased() == "mpd" {
            let error = "Streaming playlist manifests (.m3u8 / .mpd) must be downloaded using the streaming workflow to assemble segments into playable media."
            self.errorMessage = error
            throw DownloadCoordinatorError.invalidRequest(reason: error)
        }
        if url.pathExtension.lowercased() == "ts" || url.pathExtension.lowercased() == "m4s" {
            let error = "Streaming segment chunks (.ts / .m4s) must be downloaded as part of a complete streaming manifest."
            self.errorMessage = error
            throw DownloadCoordinatorError.invalidRequest(reason: error)
        }

        let resolvedFilename: String
        if let custom = filename?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            resolvedFilename = custom
        } else {
            let last = url.lastPathComponent
            resolvedFilename = (!last.isEmpty && last != "/") ? last : "download_\(UUID().uuidString.prefix(8)).bin"
        }

        let destURL = FileConflictResolver.uniqueDestinationURL(desiredFilename: resolvedFilename, directory: downloadsDirectoryURL)
        let sanitizedLimit: Int64? = (speedLimitBytesPerSecond != nil && speedLimitBytesPerSecond! > 0) ? speedLimitBytesPerSecond : nil
        let request = DownloadRequest(
            url: url,
            destinationURL: destURL,
            headers: headers,
            persistSensitiveHeaders: persistSensitiveHeaders,
            configuredThreadCount: max(1, min(32, threadCount)),
            speedLimitBytesPerSecond: sanitizedLimit,
            transportPolicy: transportPolicy
        )

        do {
            let snapshot = try await engine.addDownload(request, priority: .normal, autoStart: autoStart)
            upsertSnapshot(snapshot)
            return snapshot
        } catch {
            self.errorMessage = error.localizedDescription
            throw error
        }
    }

    public func pauseDownload(id: DownloadID) async throws {
        do {
            try await engine.pauseDownload(id: id)
        } catch {
            self.errorMessage = error.localizedDescription
            throw error
        }
    }

    public func resumeDownload(id: DownloadID) async throws {
        do {
            try await engine.resumeDownload(id: id)
        } catch {
            self.errorMessage = error.localizedDescription
            throw error
        }
    }

    public func cancelDownload(id: DownloadID, deleteFile: Bool = false) async throws {
        do {
            try await engine.cancelDownload(id: id, deleteFile: deleteFile)
        } catch {
            self.errorMessage = error.localizedDescription
            throw error
        }
    }

    public func removeDownload(id: DownloadID, deleteFile: Bool = false) async throws {
        do {
            try await engine.removeDownload(id: id, deleteFile: deleteFile)
            downloads.removeAll { $0.id == id }
            if selectedDownload?.id == id {
                selectedDownload = nil
            }
            rebuildUnifiedTransfers()
        } catch {
            self.errorMessage = error.localizedDescription
            throw error
        }
    }

    public func retryDownload(id: DownloadID) async throws {
        do {
            try await engine.retryDownload(id: id)
        } catch {
            self.errorMessage = error.localizedDescription
            throw error
        }
    }

    public func restartDownload(id: DownloadID) async throws {
        do {
            try await engine.restartDownload(id: id)
        } catch {
            self.errorMessage = error.localizedDescription
            throw error
        }
    }

    public func resumeOrRetryDownload(id: DownloadID) async throws {
        guard let download = downloads.first(where: { $0.id == id }) else { return }
        if download.isNonResumable {
            try await restartDownload(id: id)
        } else if download.isFailed {
            try await retryDownload(id: id)
        } else {
            try await resumeDownload(id: id)
        }
    }

    /// Refreshes the download URL and token for a download (e.g. following a 401, 403, or 404/410 error).
    /// Preserves existing segment progress if server validators match, or restarts fresh if non-resumable.
    public func refreshDownloadLink(
        id: DownloadID,
        newURLText: String,
        newHeaders: [String: String]? = nil
    ) async throws {
        let trimmed = newURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let newURL = URL(string: trimmed), let scheme = newURL.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            let msg = "Invalid URL: must be HTTP or HTTPS"
            self.errorMessage = msg
            throw DownloadCoordinatorError.invalidRequest(reason: msg)
        }

        do {
            _ = try await engine.coordinator.refreshDownload(
                id: id,
                newURL: newURL,
                newHeaders: newHeaders
            )
            try await resumeDownload(id: id)
            await refreshSnapshots()
        } catch {
            self.errorMessage = error.localizedDescription
            throw error
        }
    }

    // MARK: - Torrent Operations

    @discardableResult
    public func addTorrent(
        magnetURI: String,
        saveDirectoryURL: URL? = nil,
        priority: TorrentPriority? = nil
    ) async throws -> UnifiedTransfer {
        guard let te = torrentEngine else {
            let error = "Torrent engine is not initialized."
            self.errorMessage = error
            throw TorrentEngineError.sessionNotRunning
        }

        let trimmed = magnetURI.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedMagnet: MagnetLink
        do {
            parsedMagnet = try MagnetLinkParser.parse(trimmed)
        } catch {
            let message = "Invalid Magnet URI: provide a magnet link with a supported BitTorrent info-hash."
            self.errorMessage = message
            throw TorrentEngineError.invalidMagnetURI("redacted")
        }
        let normalizedMagnetURI = parsedMagnet.uri.absoluteString

        let resolvedPriority = priority ?? defaultTorrentPriority
        do {
            let task = try await te.addTorrent(
                magnetURI: normalizedMagnetURI,
                saveDirectoryURL: saveDirectoryURL ?? downloadsDirectoryURL,
                priority: resolvedPriority
            )
            try? await te.setSeedingPreference(defaultSeedingPreference, for: task.infoHash)
            await refreshTorrentSnapshots()
            let transfer = UnifiedTransfer(from: task)
            showNotification("Torrent added successfully: \(task.name)")
            return transfer
        } catch {
            self.errorMessage = error.localizedDescription
            throw error
        }
    }

    @discardableResult
    public func addTorrent(
        fileURL: URL,
        saveDirectoryURL: URL? = nil,
        priority: TorrentPriority? = nil
    ) async throws -> UnifiedTransfer {
        guard let te = torrentEngine else {
            let error = "Torrent engine is not initialized."
            self.errorMessage = error
            throw TorrentEngineError.sessionNotRunning
        }

        let resolvedPriority = priority ?? defaultTorrentPriority
        do {
            #if os(iOS) || os(macOS)
            let hasSecurityScope = fileURL.startAccessingSecurityScopedResource()
            defer {
                if hasSecurityScope {
                    fileURL.stopAccessingSecurityScopedResource()
                }
            }
            #endif

            let task = try await te.addTorrent(
                fileURL: fileURL,
                saveDirectoryURL: saveDirectoryURL ?? downloadsDirectoryURL,
                priority: resolvedPriority
            )
            try? await te.setSeedingPreference(defaultSeedingPreference, for: task.infoHash)
            await refreshTorrentSnapshots()
            let transfer = UnifiedTransfer(from: task)
            showNotification("Torrent added successfully: \(task.name)")
            return transfer
        } catch {
            self.errorMessage = error.localizedDescription
            throw error
        }
    }

    @discardableResult
    public func addTorrent(
        data: Data,
        name: String? = nil,
        saveDirectoryURL: URL? = nil,
        priority: TorrentPriority? = nil
    ) async throws -> UnifiedTransfer {
        guard let te = torrentEngine else {
            let error = "Torrent engine is not initialized."
            self.errorMessage = error
            throw TorrentEngineError.sessionNotRunning
        }

        let resolvedPriority = priority ?? defaultTorrentPriority
        do {
            let task = try await te.addTorrent(
                data: data,
                name: name,
                saveDirectoryURL: saveDirectoryURL ?? downloadsDirectoryURL,
                priority: resolvedPriority
            )
            try? await te.setSeedingPreference(defaultSeedingPreference, for: task.infoHash)
            await refreshTorrentSnapshots()
            let transfer = UnifiedTransfer(from: task)
            showNotification("Torrent added successfully: \(task.name)")
            return transfer
        } catch {
            self.errorMessage = error.localizedDescription
            throw error
        }
    }

    public func pauseTorrent(infoHash: String) async throws {
        guard let te = torrentEngine else { return }
        do {
            try await te.pause(infoHash: infoHash)
            await refreshTorrentSnapshots()
        } catch {
            self.errorMessage = error.localizedDescription
            throw error
        }
    }

    public func resumeTorrent(infoHash: String) async throws {
        guard let te = torrentEngine else { return }
        do {
            try await te.resume(infoHash: infoHash)
            await refreshTorrentSnapshots()
        } catch {
            self.errorMessage = error.localizedDescription
            throw error
        }
    }

    public func removeTorrent(infoHash: String, deleteFiles: Bool = false) async throws {
        guard let te = torrentEngine else { return }
        do {
            try await te.remove(infoHash: infoHash, deleteFiles: deleteFiles)
            torrentTasks.removeAll { $0.infoHash.caseInsensitiveCompare(infoHash) == .orderedSame }
            if selectedTransfer?.infoHash?.caseInsensitiveCompare(infoHash) == .orderedSame {
                selectedTransfer = nil
            }
            rebuildUnifiedTransfers()
        } catch {
            self.errorMessage = error.localizedDescription
            throw error
        }
    }

    public func setTorrentPriority(_ priority: TorrentPriority, for infoHash: String) async throws {
        guard let te = torrentEngine else { return }
        do {
            try await te.setPriority(priority, for: infoHash)
            await refreshTorrentSnapshots()
        } catch {
            self.errorMessage = error.localizedDescription
            throw error
        }
    }

    /// Fetches all files for a given torrent info-hash, updating internal cache.
    public func fetchTorrentFiles(for infoHash: String) async -> [TorrentFileInfo] {
        guard let te = torrentEngine else { return [] }
        let files = (await te.files(for: infoHash)) ?? []
        torrentFilesCache[infoHash] = files
        return files
    }

    /// Updates the download priority for a single file within a multi-file torrent.
    public func setTorrentFilePriority(infoHash: String, fileIndex: Int, priority: TorrentFilePriority) async throws {
        guard let te = torrentEngine else { return }
        do {
            try await te.setFilePriority(priority, forFileAt: fileIndex, in: infoHash)
            let updatedFiles = (await te.files(for: infoHash)) ?? []
            torrentFilesCache[infoHash] = updatedFiles
            await refreshTorrentSnapshots()
        } catch {
            self.errorMessage = error.localizedDescription
            throw error
        }
    }

    /// Updates download priorities for multiple files within a multi-file torrent in batch.
    public func setTorrentFilePriorities(infoHash: String, priorities: [Int: TorrentFilePriority]) async throws {
        guard let te = torrentEngine else { return }
        do {
            try await te.setFilePriorities(priorities, for: infoHash)
            let updatedFiles = (await te.files(for: infoHash)) ?? []
            torrentFilesCache[infoHash] = updatedFiles
            await refreshTorrentSnapshots()
        } catch {
            self.errorMessage = error.localizedDescription
            throw error
        }
    }

    /// Sets the seeding preference policy for a specific torrent.
    public func setSeedingPreference(infoHash: String, preference: SeedingPreference) async throws {
        guard let te = torrentEngine else { return }
        do {
            try await te.setSeedingPreference(preference, for: infoHash)
            await refreshTorrentSnapshots()
        } catch {
            self.errorMessage = error.localizedDescription
            throw error
        }
    }

    /// Configures and persists the default seeding preference for new torrents.
    public func updateSeedingSettings(defaultPreference: SeedingPreference) {
        self.defaultSeedingPreference = defaultPreference
        userDefaults.set(defaultPreference.mode.rawValue, forKey: SettingsKeys.defaultSeedingMode)
        userDefaults.set(defaultPreference.targetRatio, forKey: SettingsKeys.defaultSeedingRatio)
        userDefaults.set(defaultPreference.targetDurationSeconds, forKey: SettingsKeys.defaultSeedingDuration)
    }

    public func updateTorrentSettings(
        maxConcurrentTorrents: Int,
        defaultPriority: TorrentPriority,
        seedingPreference: SeedingPreference? = nil
    ) async throws {
        guard maxConcurrentTorrents >= 1 else {
            let error = "Max concurrent torrents must be at least 1."
            self.errorMessage = error
            throw DownloadCoordinatorError.invalidRequest(reason: error)
        }

        var updated = appSettings
        updated.maxConcurrentTorrents = maxConcurrentTorrents
        updated.defaultTorrentPriority = defaultPriority
        if let pref = seedingPreference {
            updated.seedingMode = pref.mode
            updated.targetRatio = pref.targetRatio
            updated.targetDurationMinutes = Int(pref.targetDurationSeconds / 60)
        }
        try await applySettings(updated)
    }

    public func updateTorrentSettings(maxConcurrent: Int, defaultPriority: TorrentPriority) async throws {
        try await updateTorrentSettings(maxConcurrentTorrents: maxConcurrent, defaultPriority: defaultPriority, seedingPreference: nil)
    }

    // MARK: - Unified Dispatch Actions

    public func pauseTransfer(id: String) async throws {
        if let transfer = unifiedTransfers.first(where: { $0.id == id }) {
            if transfer.isTorrent, let hash = transfer.infoHash {
                try await pauseTorrent(infoHash: hash)
            } else {
                try await pauseDownload(id: id)
            }
        }
    }

    public func resumeTransfer(id: String) async throws {
        if let transfer = unifiedTransfers.first(where: { $0.id == id }) {
            if transfer.isTorrent, let hash = transfer.infoHash {
                try await resumeTorrent(infoHash: hash)
            } else {
                try await resumeOrRetryDownload(id: id)
            }
        }
    }

    public func removeTransfer(id: String, deleteFiles: Bool = false) async throws {
        if let transfer = unifiedTransfers.first(where: { $0.id == id }) {
            if transfer.isTorrent, let hash = transfer.infoHash {
                try await removeTorrent(infoHash: hash, deleteFiles: deleteFiles)
            } else {
                try await removeDownload(id: id, deleteFile: deleteFiles)
            }
        }
    }

    public func selectTransfer(id: String) {
        self.selectedTransfer = unifiedTransfers.first(where: { $0.id == id })
    }

    public func clearSelectedTransfer() {
        self.selectedTransfer = nil
    }

    // MARK: - Bulk Operations

    public func pauseAll() async {
        await engine.pauseAllDownloads()
        if let te = torrentEngine {
            for task in torrentTasks {
                try? await te.pause(infoHash: task.infoHash)
            }
            await refreshTorrentSnapshots()
        }
    }

    public func resumeAll() async {
        await engine.resumeAllDownloads()
        if let te = torrentEngine {
            for task in torrentTasks where !task.isExplicitlyPaused {
                try? await te.resume(infoHash: task.infoHash)
            }
            await refreshTorrentSnapshots()
        }
    }

    public func cancelAll(deleteFiles: Bool = false) async {
        await engine.cancelAllDownloads(deleteFiles: deleteFiles)
        if let te = torrentEngine {
            for task in torrentTasks {
                try? await te.remove(infoHash: task.infoHash, deleteFiles: deleteFiles)
            }
            await refreshTorrentSnapshots()
        }
    }

    // MARK: - Selection & UI Feedback

    public func selectDownload(id: DownloadID) {
        self.selectedDownload = downloads.first { $0.id == id }
    }

    public func clearSelection() {
        self.selectedDownload = nil
    }

    public func clearError() {
        self.errorMessage = nil
    }

    public func showNotification(_ message: String, autoDismissSeconds: Double = 3.5) {
        self.userNotificationMessage = message
        if autoDismissSeconds > 0 {
            Task { @MainActor [weak self] in
                let ns = UInt64(autoDismissSeconds * 1_000_000_000)
                try? await Task.sleep(nanoseconds: ns)
                if self?.userNotificationMessage == message {
                    self?.userNotificationMessage = nil
                }
            }
        }
    }

    public func clearNotification() {
        self.userNotificationMessage = nil
    }

    // MARK: - Settings Configuration & Persistence

    /// Updates and persists complete AppSettings, seamlessly propagating decoupled
    /// EngineConfiguration to DownloadEngine, TorrentEngine, and StreamingDownloadOrchestrator.
    public func applySettings(_ newSettings: AppSettings) async throws {
        newSettings.save(to: userDefaults)
        // Also sync legacy keys so existing tests asserting on UserDefaults keys pass seamlessly:
        userDefaults.set(newSettings.maxConcurrentDownloads, forKey: SettingsKeys.maxConcurrentDownloads)
        userDefaults.set(newSettings.maxGlobalRequests, forKey: SettingsKeys.maxGlobalRequests)
        if newSettings.enableGlobalSpeedLimit {
            let limit = newSettings.globalBandwidthLimitBytes ?? (Int64(newSettings.globalSpeedLimitKBps) * 1024)
            userDefaults.set(limit, forKey: SettingsKeys.globalBandwidthLimit)
        } else {
            userDefaults.removeObject(forKey: SettingsKeys.globalBandwidthLimit)
        }
        userDefaults.set(newSettings.maxConcurrentTorrents, forKey: SettingsKeys.maxConcurrentTorrents)
        userDefaults.set(newSettings.defaultTorrentPriority.rawValue, forKey: SettingsKeys.defaultTorrentPriority)
        userDefaults.set(newSettings.seedingMode.rawValue, forKey: SettingsKeys.defaultSeedingMode)
        userDefaults.set(newSettings.targetRatio, forKey: SettingsKeys.defaultSeedingRatio)
        userDefaults.set(TimeInterval(newSettings.targetDurationMinutes * 60), forKey: SettingsKeys.defaultSeedingDuration)

        self.appSettings = newSettings
        let engineConfig = newSettings.makeEngineConfiguration()

        try await engine.updateConfiguration(engineConfig)
        if let te = torrentEngine {
            try? await te.updateConfiguration(engineConfig)
        }
        await engine.streamingOrchestrator?.updateConfiguration(engineConfig)

        self.maxConcurrentDownloads = newSettings.maxConcurrentDownloads
        self.maxGlobalRequests = newSettings.maxGlobalRequests
        self.globalBandwidthLimitBytesPerSecond = engineConfig.globalBandwidthLimitBytesPerSecond
        self.maxConcurrentTorrents = newSettings.maxConcurrentTorrents
        self.defaultTorrentPriority = newSettings.defaultTorrentPriority
        self.defaultSeedingPreference = engineConfig.defaultSeedingPreference
    }

    public func updateSettings(
        maxConcurrent: Int,
        maxGlobalRequests: Int,
        globalBandwidthLimit: Int64?
    ) async throws {
        guard maxConcurrent >= 1 else {
            let error = "Maximum concurrent downloads must be at least 1."
            self.errorMessage = error
            throw DownloadCoordinatorError.invalidRequest(reason: error)
        }
        guard maxGlobalRequests >= 1 else {
            let error = "Global active HTTP request limit must be at least 1."
            self.errorMessage = error
            throw DownloadCoordinatorError.invalidRequest(reason: error)
        }

        var updated = appSettings
        updated.maxConcurrentDownloads = maxConcurrent
        updated.maxGlobalRequests = maxGlobalRequests
        if let limit = globalBandwidthLimit, limit > 0 {
            updated.enableGlobalSpeedLimit = true
            updated.globalSpeedLimitKBps = Int(limit / 1024)
            updated.globalBandwidthLimitBytes = limit
        } else {
            updated.enableGlobalSpeedLimit = false
            updated.globalBandwidthLimitBytes = nil
        }
        try await applySettings(updated)
    }

    public func applyPersistedSettings() async throws {
        try await applySettings(appSettings)
    }

    public func restoreQueue(autoStart: Bool = false) async throws {
        do {
            try await engine.restoreQueue(autoStart: autoStart)
            if let te = torrentEngine {
                try? await te.start()
            }
            await refreshSnapshots()
        } catch {
            self.errorMessage = error.localizedDescription
            throw error
        }
    }
}

// MARK: - BrowserDownloadDelegate Conformance

extension DownloadManagerViewModel: BrowserDownloadDelegate {
    private func uniqueDownloadURL(in directory: URL, filename: String) -> URL {
        let original = URL(fileURLWithPath: filename).lastPathComponent
        let base = URL(fileURLWithPath: original).deletingPathExtension().lastPathComponent
        let ext = URL(fileURLWithPath: original).pathExtension
        var candidate = directory.appendingPathComponent(original)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base) (\(suffix))" : "\(base) (\(suffix)).\(ext)"
            candidate = directory.appendingPathComponent(name)
            suffix += 1
        }
        return candidate
    }

    public func importCompletedBrowserFile(
        fileURL: URL,
        filename: String,
        expectedSize: Int64?,
        originalURL: URL? = nil,
        mimeType: String? = nil
    ) async throws {
        guard fileURL.isFileURL,
              FileManager.default.fileExists(atPath: fileURL.path) else {
            throw BrowserDownloadDelegateError.completedFileImportUnavailable
        }
        if let expectedSize {
            let actualSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value
            guard actualSize == expectedSize else {
                throw BrowserDownloadDelegateError.completedFileImportUnavailable
            }
        }

        try FileManager.default.createDirectory(
            at: downloadsDirectoryURL,
            withIntermediateDirectories: true
        )
        let destination = uniqueDownloadURL(
            in: downloadsDirectoryURL,
            filename: filename
        )
        let temporaryDestination = downloadsDirectoryURL
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).partial")
        do {
            try FileManager.default.copyItem(at: fileURL, to: temporaryDestination)
            try FileManager.default.moveItem(at: temporaryDestination, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: temporaryDestination)
            throw error
        }
        do {
            _ = try await engine.importCompletedFile(
                fileURL: destination,
                originalURL: originalURL ?? fileURL,
                filename: filename,
                mimeType: mimeType
            )
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        try? FileManager.default.removeItem(at: fileURL)
        await refreshSnapshots()
    }

    public func handleDownloadRequest(
        url: URL,
        filename: String?,
        threadCount: Int,
        speedLimitBytesPerSecond: Int64?
    ) async throws {
        try await handleDownloadRequest(
            url: url,
            filename: filename,
            threadCount: threadCount,
            speedLimitBytesPerSecond: speedLimitBytesPerSecond,
            headers: nil
        )
    }

    public func handleDownloadRequest(
        url: URL,
        filename: String?,
        threadCount: Int,
        speedLimitBytesPerSecond: Int64?,
        headers: [String: String]?
    ) async throws {
        _ = try await addDownload(
            urlText: url.absoluteString,
            filename: filename,
            threadCount: threadCount,
            speedLimitBytesPerSecond: speedLimitBytesPerSecond,
            headers: headers ?? [:],
            persistSensitiveHeaders: false,
            transportPolicy: .foreground,
            autoStart: true
        )
    }

    /// Defensive handler for direct candidate download taps from UI components.
    public func handleDownloadTap(candidate: BrowserMediaCandidate) {
        guard let url = candidate.url ?? URL(string: candidate.rawURL) else {
            errorMessage = "Invalid URL: The grabber captured a malformed link."
            return
        }

        if candidate.blobKind == .mediaSource || candidate.kind == .mediaSource || (url.scheme?.lowercased() == "blob" && candidate.mimeType == nil) {
            errorMessage = "This site uses MediaSource streaming. You must download the manifest (.m3u8 or .mpd) instead."
            return
        }

        guard url.scheme?.lowercased() == "http" || url.scheme?.lowercased() == "https" else {
            errorMessage = "Unsupported link type: \(url.scheme ?? "unknown"). Cannot download directly."
            return
        }

        if candidate.kind == .hlsManifest || candidate.kind == .dashManifest || url.pathExtension.lowercased() == "m3u8" || url.pathExtension.lowercased() == "mpd" {
            errorMessage = "Streaming playlist manifest. Use the streaming workflow to download and assemble this media."
            return
        }

        if url.pathExtension.lowercased() == "ts" || url.pathExtension.lowercased() == "m4s" {
            errorMessage = "This is a streaming segment chunk. Download the playlist manifest (.m3u8 or .mpd) instead."
            return
        }

        Task { @MainActor in
            do {
                let filename = candidate.suggestedFilename.isEmpty ? nil : candidate.suggestedFilename
                _ = try await addDownload(urlText: url.absoluteString, filename: filename)
            } catch {
                errorMessage = "Engine error: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Schedule Integration

    public func loadScheduleRules() async {
        await scheduleCoordinator.loadRules()
        self.scheduleRules = scheduleCoordinator.rules
    }

    public func isScheduled(transferID: String) -> Bool {
        scheduleCoordinator.isScheduled(downloadID: transferID)
    }

    public func toggleScheduled(transferID: String) {
        Task { @MainActor in
            await scheduleCoordinator.toggleScheduled(downloadID: transferID)
            self.scheduleRules = scheduleCoordinator.rules
            self.userNotificationMessage = isScheduled(transferID: transferID) ? "Added to Schedule" : "Removed from Schedule"
        }
    }

    public func saveScheduleRule(_ rule: ScheduleRule) async {
        do {
            try await scheduleCoordinator.saveRule(rule)
            self.scheduleRules = scheduleCoordinator.rules
            self.userNotificationMessage = "Schedule updated successfully"
        } catch {
            self.errorMessage = "Failed to save schedule: \(error.localizedDescription)"
        }
    }

    public func reconcileSchedule() async {
        let report = await scheduleCoordinator.reconcile()
        if !report.resumedDownloadIDs.isEmpty || !report.pausedDownloadIDs.isEmpty {
            await refreshSnapshots()
        }
    }
}

// MARK: - BrowserMagnetDelegate Conformance

extension DownloadManagerViewModel: BrowserMagnetDelegate {
    public var isTorrentEngineAvailable: Bool {
        torrentEngine != nil
    }

    public func handleMagnetLink(_ magnet: MagnetLink) async throws {
        _ = try await addTorrent(magnetURI: magnet.uri.absoluteString)
    }
}
