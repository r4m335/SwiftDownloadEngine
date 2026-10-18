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

/// Main-actor isolated view model bridging `DownloadEngine` to UI layers (SwiftUI / UIKit).
///
/// Features:
/// - Real-Time Observation: Conforms directly to `ObservableObject` with `@Published` state properties for automatic SwiftUI view redraws.
/// - Event Stream Subscription: Subscribes to `engine.events()` via an `AsyncStream<DownloadEvent>` and updates UI state.
/// - Authoritative Snapshot Sync: Keeps live snapshots without diverging from underlying queue/persistence.
/// - Action Dispatching: Exposes pause, resume, cancel, retry, remove, and add operations.
/// - Configurable Settings & Persistence: Manages dynamic concurrency limits, request budgets, and bandwidth throttling, persisted via `UserDefaults`.
@MainActor
public final class DownloadManagerViewModel: ObservableObject, @unchecked Sendable {
    public let engine: DownloadEngine
    public let downloadsDirectoryURL: URL
    private let userDefaults: UserDefaults

    public enum SettingsKeys {
        public static let maxConcurrentDownloads = "SwiftDownloadEngine.maxConcurrentDownloads"
        public static let maxGlobalRequests = "SwiftDownloadEngine.maxGlobalRequests"
        public static let globalBandwidthLimit = "SwiftDownloadEngine.globalBandwidthLimit"
    }

    @Published public var downloads: [DownloadSnapshot] = []
    @Published public var selectedDownload: DownloadSnapshot? = nil
    @Published public var queueSummary: QueueSnapshot? = nil
    @Published public var filterText: String = ""
    @Published public var selectedFilter: DownloadFilter = .all

    @Published public var maxConcurrentDownloads: Int = 3
    @Published public var maxGlobalRequests: Int = 12
    @Published public var globalBandwidthLimitBytesPerSecond: Int64? = nil

    @Published public var errorMessage: String? = nil
    @Published public var isObserving: Bool = false

    private var eventTask: Task<Void, Never>? = nil

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
        downloadsDirectory: URL? = nil,
        userDefaults: UserDefaults = .standard
    ) {
        self.engine = engine
        self.downloadsDirectoryURL = downloadsDirectory ?? Self.defaultDownloadsDirectory()
        self.userDefaults = userDefaults

        let savedConcurrent = userDefaults.integer(forKey: SettingsKeys.maxConcurrentDownloads)
        self.maxConcurrentDownloads = savedConcurrent > 0 ? savedConcurrent : 3

        let savedRequests = userDefaults.integer(forKey: SettingsKeys.maxGlobalRequests)
        self.maxGlobalRequests = savedRequests > 0 ? savedRequests : 12

        if userDefaults.object(forKey: SettingsKeys.globalBandwidthLimit) != nil {
            let savedLimit = userDefaults.object(forKey: SettingsKeys.globalBandwidthLimit) as? Int64
                ?? Int64(userDefaults.integer(forKey: SettingsKeys.globalBandwidthLimit))
            self.globalBandwidthLimitBytesPerSecond = savedLimit > 0 ? savedLimit : nil
        } else {
            self.globalBandwidthLimitBytesPerSecond = nil
        }
    }

    // MARK: - Event Subscription & Synchronization

    /// Starts observing asynchronous events from `DownloadEngine`.
    public func startObserving() async {
        guard !isObserving else { return }
        isObserving = true

        // Apply persisted settings to the underlying engine
        try? await applyPersistedSettings()

        // Fetch authoritative initial snapshots
        await refreshSnapshots()

        // Listen for real-time background events
        eventTask?.cancel()
        let stream = await engine.events()
        eventTask = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { break }
                self?.handleEngineEvent(event)
            }
        }
    }

    /// Stops observing engine events.
    public func stopObserving() {
        eventTask?.cancel()
        eventTask = nil
        isObserving = false
    }

    /// Reloads all download records directly from the engine.
    public func refreshSnapshots() async {
        let snaps = await engine.allSnapshots()
        self.downloads = snaps
        self.queueSummary = await engine.queueSnapshot()

        if let selected = selectedDownload, let updated = snaps.first(where: { $0.id == selected.id }) {
            self.selectedDownload = updated
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
                    enqueuedAt: existing.enqueuedAt
                )
                downloads[index] = updated
                if selectedDownload?.id == id {
                    selectedDownload = updated
                }
            }

        case .queueStateChanged(let summary):
            self.queueSummary = summary
        }
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
    }

    // MARK: - Filtered Views

    /// Returns downloads matching current search query and status filter.
    public var filteredDownloads: [DownloadSnapshot] {
        downloads.filter { snap in
            // Filter by search text
            if !filterText.isEmpty {
                let filename = snap.destinationURL.lastPathComponent.lowercased()
                let urlString = snap.url.absoluteString.lowercased()
                let query = filterText.lowercased()
                guard filename.contains(query) || urlString.contains(query) else {
                    return false
                }
            }

            // Filter by status category
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

    // MARK: - Download Lifecycle Actions

    /// Enqueues a new download request from UI inputs.
    @discardableResult
    public func addDownload(
        urlText: String,
        filename: String? = nil,
        threadCount: Int = 6,
        speedLimitBytesPerSecond: Int64? = nil,
        autoStart: Bool = true
    ) async throws -> DownloadSnapshot {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            let error = "Invalid URL: must be an http or https address."
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

        let destURL = downloadsDirectoryURL.appendingPathComponent(resolvedFilename)
        let request = DownloadRequest(
            url: url,
            destinationURL: destURL,
            configuredThreadCount: max(1, min(32, threadCount)),
            speedLimitBytesPerSecond: speedLimitBytesPerSecond
        )

        let snapshot = try await engine.addDownload(request, priority: .normal, autoStart: autoStart)
        upsertSnapshot(snapshot)
        return snapshot
    }

    /// Cooperatively pauses an active download.
    public func pauseDownload(id: DownloadID) async throws {
        try await engine.pauseDownload(id: id)
    }

    /// Resumes a paused or interrupted download.
    public func resumeDownload(id: DownloadID) async throws {
        try await engine.resumeDownload(id: id)
    }

    /// Cancels an in-progress or queued download.
    public func cancelDownload(id: DownloadID, deleteFile: Bool = false) async throws {
        try await engine.cancelDownload(id: id, deleteFile: deleteFile)
    }

    /// Removes a download record from the queue.
    public func removeDownload(id: DownloadID, deleteFile: Bool = false) async throws {
        try await engine.removeDownload(id: id, deleteFile: deleteFile)
        downloads.removeAll { $0.id == id }
        if selectedDownload?.id == id {
            selectedDownload = nil
        }
    }

    /// Retries an eligible failed download.
    public func retryDownload(id: DownloadID) async throws {
        try await engine.retryDownload(id: id)
    }

    /// Bulk pauses all active downloads.
    public func pauseAll() async {
        await engine.pauseAllDownloads()
    }

    /// Bulk resumes all paused downloads.
    public func resumeAll() async {
        await engine.resumeAllDownloads()
    }

    /// Bulk cancels all downloads.
    public func cancelAll(deleteFiles: Bool = false) async {
        await engine.cancelAllDownloads(deleteFiles: deleteFiles)
    }

    /// Selects a download for viewing in the Details screen.
    public func selectDownload(id: DownloadID) {
        self.selectedDownload = downloads.first { $0.id == id }
    }

    /// Deselects the currently active download details view.
    public func clearSelection() {
        self.selectedDownload = nil
    }

    // MARK: - Settings Configuration & Persistence

    /// Updates the engine's configuration settings and persists them to UserDefaults.
    public func updateSettings(
        maxConcurrent: Int,
        maxGlobalRequests: Int,
        globalBandwidthLimit: Int64?
    ) async throws {
        self.maxConcurrentDownloads = maxConcurrent
        self.maxGlobalRequests = maxGlobalRequests
        self.globalBandwidthLimitBytesPerSecond = globalBandwidthLimit

        userDefaults.set(maxConcurrent, forKey: SettingsKeys.maxConcurrentDownloads)
        userDefaults.set(maxGlobalRequests, forKey: SettingsKeys.maxGlobalRequests)
        if let limit = globalBandwidthLimit {
            userDefaults.set(limit, forKey: SettingsKeys.globalBandwidthLimit)
        } else {
            userDefaults.removeObject(forKey: SettingsKeys.globalBandwidthLimit)
        }

        try await engine.setMaxConcurrentDownloads(maxConcurrent)
        try await engine.setMaxGlobalRequests(maxGlobalRequests)
        await engine.setGlobalSpeedLimit(globalBandwidthLimit)
    }

    /// Applies configured/persisted settings to the underlying engine.
    public func applyPersistedSettings() async throws {
        try await engine.setMaxConcurrentDownloads(maxConcurrentDownloads)
        try await engine.setMaxGlobalRequests(maxGlobalRequests)
        await engine.setGlobalSpeedLimit(globalBandwidthLimitBytesPerSecond)
    }

    /// Restores persistent queue state from disk.
    public func restoreQueue(autoStart: Bool = false) async throws {
        try await engine.restoreQueue(autoStart: autoStart)
        await refreshSnapshots()
    }
}
