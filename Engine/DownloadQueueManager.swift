import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Scheduling priority for queued downloads.
///
/// Deterministic ordering: Higher priority downloads are scheduled ahead of lower priority downloads.
/// Within identical priority levels, deterministic FIFO (First-In, First-Out) scheduling applies.
public enum DownloadPriority: Int, Codable, Comparable, CaseIterable, Sendable {
    case low = 1
    case normal = 2
    case high = 3

    public static func < (lhs: DownloadPriority, rhs: DownloadPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Durable metadata and state representation of an item in the download queue.
public struct QueueItem: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public var request: DownloadRequest
    public var priority: DownloadPriority
    public var sequenceIndex: Int64
    public var enqueuedAt: Date
    public var state: DownloadState
    public var completedBytes: Int64
    public var totalBytes: Int64?

    public var fractionCompleted: Double {
        guard let total = totalBytes, total > 0 else { return 0.0 }
        return min(1.0, Double(completedBytes) / Double(total))
    }

    public init(
        request: DownloadRequest,
        priority: DownloadPriority = .normal,
        sequenceIndex: Int64 = 0,
        enqueuedAt: Date = Date(),
        state: DownloadState = .pending,
        completedBytes: Int64 = 0,
        totalBytes: Int64? = nil
    ) {
        self.id = request.id
        self.request = request
        self.priority = priority
        self.sequenceIndex = sequenceIndex
        self.enqueuedAt = enqueuedAt
        self.state = state
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
    }
}

/// Durable serializable manifest representing the persistent state of the queue on disk.
public struct QueueManifest: Codable, Sendable {
    public var maxConcurrentDownloads: Int
    public var sequenceCounter: Int64
    public var items: [QueueItem]

    public init(
        maxConcurrentDownloads: Int,
        sequenceCounter: Int64,
        items: [QueueItem]
    ) {
        self.maxConcurrentDownloads = maxConcurrentDownloads
        self.sequenceCounter = sequenceCounter
        self.items = items
    }
}

/// Point-in-time snapshot of the overall queue state and metrics.
public struct QueueSnapshot: Sendable, Equatable {
    public let totalItems: Int
    public let activeCount: Int
    public let queuedCount: Int
    public let pausedCount: Int
    public let completedCount: Int
    public let failedCount: Int
    public let cancelledCount: Int
    public let items: [QueueItem]

    public init(
        totalItems: Int,
        activeCount: Int,
        queuedCount: Int,
        pausedCount: Int,
        completedCount: Int,
        failedCount: Int,
        cancelledCount: Int,
        items: [QueueItem]
    ) {
        self.totalItems = totalItems
        self.activeCount = activeCount
        self.queuedCount = queuedCount
        self.pausedCount = pausedCount
        self.completedCount = completedCount
        self.failedCount = failedCount
        self.cancelledCount = cancelledCount
        self.items = items
    }
}

/// Errors raised by `DownloadQueueManager`.
public enum DownloadQueueError: Error, LocalizedError, Equatable, Sendable {
    case downloadAlreadyExists(id: String)
    case downloadNotFound(id: String)
    case invalidStateTransition(id: String, from: DownloadState, to: DownloadState)
    case invalidConcurrencyLimit(Int)
    case persistenceError(String)

    public var errorDescription: String? {
        switch self {
        case .downloadAlreadyExists(let id):
            return "Download with ID '\(id)' already exists in queue"
        case .downloadNotFound(let id):
            return "Download with ID '\(id)' not found in queue"
        case .invalidStateTransition(let id, let from, let to):
            return "Invalid queue state transition for '\(id)': from \(from) to \(to)"
        case .invalidConcurrencyLimit(let limit):
            return "Concurrency limit must be greater than zero, got: \(limit)"
        case .persistenceError(let reason):
            return "Queue persistence error: \(reason)"
        }
    }
}

/// Persistent download queue and global lifecycle manager for the 1DM+-inspired Swift engine.
///
/// Features:
/// - Global Concurrency Control: Configurable limit (default 3) on simultaneously active downloads.
/// - Priority Scheduling: High priority downloads dispatch ahead of normal and low priorities.
/// - Deterministic FIFO: Within equal priorities, strictly First-In, First-Out order is maintained.
/// - Non-blocking Concurrency Limits: Reducing max concurrency allows active downloads to drain gracefully.
/// - Atomic Persistence: Queue metadata is written atomically, surviving ungraceful process crashes.
/// - Crash Reconciliation: Interrupted transfers (.downloading on crash) return safely to queue state without duplicate data.
/// - Terminal Invariants: Completed and explicitly cancelled downloads are never auto-restarted.
/// - Reusable Engine: Delegates segment allocation, HTTP range workers, disk I/O, and cryptographic hashing to `DownloadCoordinator`.
public actor DownloadQueueManager {
    public let coordinator: DownloadCoordinator
    public let persistenceStore: DownloadPersistenceStore
    public let queueStoreURL: URL

    private var items: [String: QueueItem] = [:]
    private var sequenceCounter: Int64 = 0
    private var activeTasks: [String: Task<Void, Never>] = [:]
    public private(set) var maxConcurrentDownloads: Int
    private var isProcessingQueue: Bool = false

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private var progressHandlers: [String: @Sendable (CoordinatorProgress) -> Void] = [:]
    private var globalProgressHandler: (@Sendable (CoordinatorProgress) -> Void)?
    private var onQueueChanged: (@Sendable (QueueSnapshot) -> Void)?

    public init(
        coordinator: DownloadCoordinator,
        persistenceStore: DownloadPersistenceStore,
        queueStoreURL: URL? = nil,
        maxConcurrentDownloads: Int = 3
    ) {
        self.coordinator = coordinator
        self.persistenceStore = persistenceStore
        if let storeURL = queueStoreURL {
            self.queueStoreURL = storeURL
        } else {
            self.queueStoreURL = persistenceStore.storageDirectoryURL.appendingPathComponent("queue_manifest.json")
        }
        self.maxConcurrentDownloads = max(1, maxConcurrentDownloads)

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = enc
        self.decoder = JSONDecoder()
    }

    // MARK: - Queue Management Operations

    /// Adds a download request to the queue.
    ///
    /// - Parameters:
    ///   - request: Target download request.
    ///   - priority: Priority level (.high, .normal, .low).
    ///   - autoStart: If true, immediately triggers the scheduler to process eligible items.
    /// - Returns: The newly created `QueueItem`.
    @discardableResult
    public func add(
        _ request: DownloadRequest,
        priority: DownloadPriority = .normal,
        autoStart: Bool = true
    ) throws -> QueueItem {
        guard items[request.id] == nil else {
            throw DownloadQueueError.downloadAlreadyExists(id: request.id)
        }

        sequenceCounter += 1
        let newItem = QueueItem(
            request: request,
            priority: priority,
            sequenceIndex: sequenceCounter,
            enqueuedAt: Date(),
            state: .pending
        )
        items[request.id] = newItem
        persistQueue()

        if autoStart {
            processQueue()
        }

        notifyQueueChanged()
        return newItem
    }

    /// Adds multiple download requests in bulk.
    @discardableResult
    public func add(
        _ requests: [DownloadRequest],
        priority: DownloadPriority = .normal,
        autoStart: Bool = true
    ) throws -> [QueueItem] {
        var added: [QueueItem] = []
        for req in requests {
            let item = try add(req, priority: priority, autoStart: false)
            added.append(item)
        }
        if autoStart {
            processQueue()
        }
        return added
    }

    /// Cooperatively pauses a download.
    ///
    /// If actively downloading, awaits worker settlement and flushes disk buffers before releasing the concurrency slot.
    /// If pending in queue, marks the item as paused so it will not be dispatched.
    public func pause(id: String) async throws {
        guard var item = items[id] else {
            throw DownloadQueueError.downloadNotFound(id: id)
        }
        guard !item.state.isTerminal else {
            return // Completed and cancelled downloads are terminal
        }

        item.state = .paused
        items[id] = item

        if let task = activeTasks.removeValue(forKey: id) {
            try? await coordinator.pause(id: id)
            task.cancel()
            _ = await task.value
        }

        persistQueue()
        processQueue()
        notifyQueueChanged()
    }

    /// Resumes an eligible paused download.
    ///
    /// Transitions state to `.pending` and triggers queue scheduling.
    public func resume(id: String) throws {
        guard var item = items[id] else {
            throw DownloadQueueError.downloadNotFound(id: id)
        }
        guard item.state == .paused else {
            return
        }

        item.state = .pending
        items[id] = item
        persistQueue()
        processQueue()
        notifyQueueChanged()
    }

    /// Cancels a download, stopping active transfers and optionally deleting destination files.
    public func cancel(id: String, deleteDestinationFile: Bool = false) async throws {
        guard var item = items[id] else {
            throw DownloadQueueError.downloadNotFound(id: id)
        }
        guard item.state != .completed else {
            return // Completed downloads cannot be cancelled
        }

        item.state = .cancelled
        items[id] = item

        if let task = activeTasks.removeValue(forKey: id) {
            try? await coordinator.cancel(id: id, deleteDestinationFile: deleteDestinationFile)
            task.cancel()
            _ = await task.value
        } else {
            if deleteDestinationFile {
                if let record = try? await persistenceStore.fetch(tag: id) {
                    try? FileManager.default.removeItem(at: record.destinationURL)
                } else if FileManager.default.fileExists(atPath: item.request.destinationURL.path) {
                    try? FileManager.default.removeItem(at: item.request.destinationURL)
                }
                try? await persistenceStore.delete(tag: id)
            } else {
                _ = try? await persistenceStore.updateState(tag: id, state: .cancelled)
            }
        }

        persistQueue()
        processQueue()
        notifyQueueChanged()
    }

    /// Retries a failed download.
    public func retry(id: String) throws {
        guard var item = items[id] else {
            throw DownloadQueueError.downloadNotFound(id: id)
        }
        guard case .failed = item.state else {
            throw DownloadQueueError.invalidStateTransition(id: id, from: item.state, to: .pending)
        }

        item.state = .pending
        items[id] = item
        persistQueue()
        processQueue()
        notifyQueueChanged()
    }

    /// Retries all failed downloads in bulk.
    public func retryAll() {
        for (id, item) in items {
            if case .failed = item.state {
                items[id]?.state = .pending
            }
        }
        persistQueue()
        processQueue()
        notifyQueueChanged()
    }

    /// Pauses all active and queued downloads.
    public func pauseAll() async {
        for (id, item) in items where item.state == .pending {
            items[id]?.state = .paused
        }

        let activeIDs = Array(activeTasks.keys)
        for id in activeIDs {
            items[id]?.state = .paused
            if let task = activeTasks.removeValue(forKey: id) {
                try? await coordinator.pause(id: id)
                task.cancel()
                _ = await task.value
            }
        }

        persistQueue()
        notifyQueueChanged()
    }

    /// Resumes all eligible paused downloads.
    public func resumeAll() {
        for (id, item) in items where item.state == .paused {
            items[id]?.state = .pending
        }
        persistQueue()
        processQueue()
        notifyQueueChanged()
    }

    /// Cancels all active and queued downloads.
    public func cancelAll(deleteDestinationFiles: Bool = false) async {
        // Mark all pending items as cancelled first so processQueue will not pick them up
        for (id, item) in items where item.state == .pending {
            items[id]?.state = .cancelled
            if deleteDestinationFiles {
                try? await persistenceStore.delete(tag: id)
            } else {
                _ = try? await persistenceStore.updateState(tag: id, state: .cancelled)
            }
        }

        // Cancel all active tasks
        let activeIDs = Array(activeTasks.keys)
        for id in activeIDs {
            items[id]?.state = .cancelled
            if let task = activeTasks.removeValue(forKey: id) {
                try? await coordinator.cancel(id: id, deleteDestinationFile: deleteDestinationFiles)
                task.cancel()
                _ = await task.value
            }
        }

        persistQueue()
        notifyQueueChanged()
    }

    /// Removes all completed download records from the queue without deleting downloaded files by default.
    public func removeCompleted(deleteDestinationFiles: Bool = false) async {
        let completedIDs = items.values.filter { $0.state == .completed }.map { $0.id }
        for id in completedIDs {
            try? await removeFromQueue(id: id, deleteDestinationFile: deleteDestinationFiles)
        }
    }

    /// Removes a download record from the queue.
    ///
    /// By default, does NOT delete the downloaded file from disk (`deleteDestinationFile = false`).
    public func removeFromQueue(id: String, deleteDestinationFile: Bool = false) async throws {
        guard let item = items[id] else {
            throw DownloadQueueError.downloadNotFound(id: id)
        }

        if let task = activeTasks.removeValue(forKey: id) {
            try? await coordinator.cancel(id: id, deleteDestinationFile: deleteDestinationFile)
            task.cancel()
            _ = await task.value
        } else if deleteDestinationFile {
            if let record = try? await persistenceStore.fetch(tag: id) {
                try? FileManager.default.removeItem(at: record.destinationURL)
            } else if FileManager.default.fileExists(atPath: item.request.destinationURL.path) {
                try? FileManager.default.removeItem(at: item.request.destinationURL)
            }
            try? await persistenceStore.delete(tag: id)
        }

        items.removeValue(forKey: id)
        progressHandlers.removeValue(forKey: id)
        persistQueue()
        processQueue()
        notifyQueueChanged()
    }

    /// Updates the scheduling priority of a queued download.
    ///
    /// If the download is actively running, its priority metadata is updated without interrupting the active transfer.
    public func updatePriority(id: String, priority: DownloadPriority) throws {
        guard var item = items[id] else {
            throw DownloadQueueError.downloadNotFound(id: id)
        }
        item.priority = priority
        items[id] = item
        persistQueue()

        if item.state == .pending {
            processQueue()
        }
        notifyQueueChanged()
    }

    /// Adjusts the maximum number of concurrent downloads.
    ///
    /// If increased, triggers immediate scheduling of eligible queued items.
    /// If decreased, running downloads continue to completion without interruption.
    public func setMaxConcurrentDownloads(_ newLimit: Int) throws {
        guard newLimit >= 1 else {
            throw DownloadQueueError.invalidConcurrencyLimit(newLimit)
        }
        let oldLimit = maxConcurrentDownloads
        maxConcurrentDownloads = newLimit
        persistQueue()

        if newLimit > oldLimit {
            processQueue()
        }
        notifyQueueChanged()
    }

    // MARK: - Persistence & Restoration

    /// Restores the queue from the persisted manifest and reconciles state with `DownloadPersistenceStore`.
    ///
    /// - Parameter autoStart: If true, dispatches eligible queued downloads up to the concurrency limit.
    public func restoreQueue(autoStart: Bool = true) async throws {
        guard FileManager.default.fileExists(atPath: queueStoreURL.path) else {
            return
        }

        let data: Data
        let manifest: QueueManifest
        do {
            data = try Data(contentsOf: queueStoreURL)
            manifest = try decoder.decode(QueueManifest.self, from: data)
        } catch {
            throw DownloadQueueError.persistenceError("Corrupted queue manifest: \(error.localizedDescription)")
        }

        if manifest.maxConcurrentDownloads > 0 {
            self.maxConcurrentDownloads = manifest.maxConcurrentDownloads
        }
        self.sequenceCounter = max(self.sequenceCounter, manifest.sequenceCounter)

        for rawItem in manifest.items {
            var item = rawItem
            if activeTasks[item.id] != nil {
                continue
            }
            if let record = try await persistenceStore.fetch(tag: item.id) {
                item.completedBytes = record.completedBytes
                item.totalBytes = record.totalSize

                switch record.state {
                case .completed:
                    item.state = .completed
                case .cancelled:
                    item.state = .cancelled
                case .paused:
                    item.state = .paused
                case .failed(let reason):
                    item.state = .failed(reason: reason)
                case .downloading, .probing, .pending:
                    // Process was terminated during transfer -> return to queued for safe resume
                    item.state = .pending
                }
            } else {
                if item.state == .downloading || item.state == .probing {
                    item.state = .pending
                }
            }

            self.items[item.id] = item
        }

        persistQueue()
        if autoStart {
            processQueue()
        }
        notifyQueueChanged()
    }

    // MARK: - Queue Scheduling Engine

    private func processQueue() {
        guard !isProcessingQueue else { return }
        isProcessingQueue = true
        defer { isProcessingQueue = false }

        while activeTasks.count < maxConcurrentDownloads {
            let pendingItems = items.values.filter { $0.state == .pending }
            guard !pendingItems.isEmpty else { break }

            // Deterministic scheduling:
            // 1. Highest priority first
            // 2. Earliest sequence index (FIFO) within equal priority
            // 3. Earliest enqueuedAt timestamp
            let sortedPending = pendingItems.sorted { a, b in
                if a.priority != b.priority {
                    return a.priority > b.priority
                }
                if a.sequenceIndex != b.sequenceIndex {
                    return a.sequenceIndex < b.sequenceIndex
                }
                return a.enqueuedAt < b.enqueuedAt
            }

            guard let nextItem = sortedPending.first else { break }
            launchDownloadTask(for: nextItem.id)
        }
    }

    private func launchDownloadTask(for id: String) {
        guard let item = items[id], item.state == .pending else { return }
        items[id]?.state = .downloading
        persistQueue()

        let task = Task<Void, Never> { [weak self] in
            guard let self = self else { return }
            do {
                try await self.coordinator.resume(item.request, progress: { [weak self] progress in
                    Task { [weak self] in
                        await self?.handleProgressUpdate(progress)
                    }
                })
                await self.handleDownloadFinished(id: id, error: nil)
            } catch is CancellationError {
                await self.handleDownloadCancelled(id: id)
            } catch DownloadCoordinatorError.cancelled {
                await self.handleDownloadCancelled(id: id)
            } catch {
                await self.handleDownloadFinished(id: id, error: error)
            }
        }
        activeTasks[id] = task
        notifyQueueChanged()
    }

    private func handleProgressUpdate(_ progress: CoordinatorProgress) {
        if items[progress.downloadID] != nil {
            items[progress.downloadID]?.completedBytes = progress.bytesReceived
            items[progress.downloadID]?.totalBytes = progress.totalBytes
            progressHandlers[progress.downloadID]?(progress)
            globalProgressHandler?(progress)
        }
    }

    private func handleDownloadFinished(id: String, error: Error?) {
        let wasActive = (activeTasks.removeValue(forKey: id) != nil)
        guard wasActive else { return }

        if let error = error {
            items[id]?.state = .failed(reason: error.localizedDescription)
        } else {
            items[id]?.state = .completed
            if let total = items[id]?.totalBytes {
                items[id]?.completedBytes = total
            }
        }

        persistQueue()
        processQueue()
        notifyQueueChanged()
    }

    private func handleDownloadCancelled(id: String) {
        let wasActive = (activeTasks.removeValue(forKey: id) != nil)
        if let current = items[id], current.state != .paused && current.state != .cancelled {
            items[id]?.state = .paused
        }

        if wasActive {
            persistQueue()
            processQueue()
            notifyQueueChanged()
        }
    }

    private func persistQueue() {
        let parentDir = queueStoreURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parentDir.path) {
            try? FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }

        let manifest = QueueManifest(
            maxConcurrentDownloads: maxConcurrentDownloads,
            sequenceCounter: sequenceCounter,
            items: Array(items.values)
        )
        do {
            let data = try encoder.encode(manifest)
            try data.write(to: queueStoreURL, options: .atomic)
        } catch {
            // Durable atomic write fallback
        }
    }

    private func notifyQueueChanged() {
        let snap = self.snapshot()
        onQueueChanged?(snap)
    }

    // MARK: - Query & Inspection APIs

    public var isIdle: Bool {
        activeTasks.isEmpty && items.values.allSatisfy { $0.state != .pending }
    }

    public var activeCount: Int {
        activeTasks.count
    }

    public var queuedCount: Int {
        items.values.filter { $0.state == .pending }.count
    }

    public func item(for id: String) -> QueueItem? {
        items[id]
    }

    public func allItems() -> [QueueItem] {
        Array(items.values).sorted { a, b in
            if a.priority != b.priority {
                return a.priority > b.priority
            }
            return a.sequenceIndex < b.sequenceIndex
        }
    }

    public func snapshot() -> QueueSnapshot {
        let all = allItems()
        return QueueSnapshot(
            totalItems: all.count,
            activeCount: activeTasks.count,
            queuedCount: all.filter { $0.state == .pending }.count,
            pausedCount: all.filter { $0.state == .paused }.count,
            completedCount: all.filter { $0.state == .completed }.count,
            failedCount: all.filter {
                if case .failed = $0.state { return true } else { return false }
            }.count,
            cancelledCount: all.filter { $0.state == .cancelled }.count,
            items: all
        )
    }

    /// Awaits until all pending and active downloads in the queue have settled or completed.
    public func waitUntilIdle(timeoutSeconds: TimeInterval = 10.0) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while !isIdle {
            if Date() > deadline {
                throw DownloadQueueError.persistenceError("Timed out waiting for queue to become idle")
            }
            try await Task.sleep(nanoseconds: 20_000_000) // 20ms
        }
    }

    /// Returns items that are actively in progress.
    public func activeItems() -> [QueueItem] {
        activeTasks.keys.compactMap { items[$0] }
    }

    /// Registers a progress callback for a specific download ID.
    public func setProgressHandler(for id: String, handler: @escaping @Sendable (CoordinatorProgress) -> Void) {
        progressHandlers[id] = handler
    }

    /// Registers a global progress callback invoked whenever any download in the queue makes progress.
    public func setGlobalProgressHandler(_ handler: @escaping @Sendable (CoordinatorProgress) -> Void) {
        globalProgressHandler = handler
    }

    /// Registers a global queue state change observer.
    public func setQueueChangedHandler(_ handler: @escaping @Sendable (QueueSnapshot) -> Void) {
        onQueueChanged = handler
    }

    // MARK: - Resource & Bandwidth Throttling Controls

    /// Sets or removes the global bandwidth rate limit across all downloads.
    public func setGlobalSpeedLimit(_ bytesPerSecond: Int64?) async {
        await coordinator.setGlobalSpeedLimit(bytesPerSecond)
    }

    /// Sets or removes an individual download's speed limit.
    public func setSpeedLimit(for id: String, bytesPerSecond: Int64?) async {
        await coordinator.setSpeedLimit(for: id, bytesPerSecond: bytesPerSecond)
        if var item = items[id] {
            item.request.speedLimitBytesPerSecond = bytesPerSecond
            items[id] = item
            persistQueue()
        }
    }

    /// Retrieves current speed and ETA metrics for a download.
    public func speedMetrics(for id: String) async -> SpeedMetrics? {
        await coordinator.speedMetrics(for: id)
    }

    /// Retrieves the checksum outcome for a completed download.
    public func checksumOutcome(for id: String) async -> ChecksumOutcome {
        await coordinator.checksumOutcome(for: id)
    }

    /// Updates the global in-flight HTTP request limit.
    public func setMaxGlobalRequests(_ limit: Int) async throws {
        try await coordinator.requestBudget.setMaxGlobalRequests(limit)
    }
}

