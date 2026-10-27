import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Unique identifier for downloads managed by `DownloadEngine`.
public typealias DownloadID = String

/// High-level, application-facing immutable snapshot of a download operation.
public struct DownloadSnapshot: Sendable, Equatable, Identifiable, Codable {
    public let id: DownloadID
    public let url: URL
    public let destinationURL: URL
    public let state: DownloadState
    public let priority: DownloadPriority
    public let completedBytes: Int64
    public let totalBytes: Int64?
    public let progressFraction: Double
    public let currentBytesPerSecond: Double
    public let averageBytesPerSecond: Double
    public let elapsedTime: TimeInterval
    public let estimatedTimeRemaining: TimeInterval?
    public let failureReason: String?
    public let checksumOutcome: ChecksumOutcome
    public let enqueuedAt: Date
    public let transportPolicy: HTTPTransportPolicy

    public var isTerminal: Bool {
        state.isTerminal
    }

    public var canResume: Bool {
        state.canResume
    }

    public var isCompleted: Bool {
        state == .completed
    }

    public var isFailed: Bool {
        if case .failed = state { return true } else { return false }
    }

    public var isNonResumable: Bool {
        if case .failed(let reason) = state {
            return reason.localizedCaseInsensitiveContains("Resume unavailable") ||
                   reason.localizedCaseInsensitiveContains("non-resumable")
        }
        return false
    }

    public var isRateLimited: Bool {
        if case .failed(let reason) = state {
            return reason.localizedCaseInsensitiveContains("429") ||
                   reason.localizedCaseInsensitiveContains("rate-limit") ||
                   reason.localizedCaseInsensitiveContains("rate limited")
        }
        return false
    }

    public init(
        id: DownloadID,
        url: URL,
        destinationURL: URL,
        state: DownloadState,
        priority: DownloadPriority = .normal,
        completedBytes: Int64 = 0,
        totalBytes: Int64? = nil,
        progressFraction: Double = 0.0,
        currentBytesPerSecond: Double = 0.0,
        averageBytesPerSecond: Double = 0.0,
        elapsedTime: TimeInterval = 0.0,
        estimatedTimeRemaining: TimeInterval? = nil,
        failureReason: String? = nil,
        checksumOutcome: ChecksumOutcome = .notChecked,
        enqueuedAt: Date = Date(),
        transportPolicy: HTTPTransportPolicy = .foreground
    ) {
        self.id = id
        self.url = url
        self.destinationURL = destinationURL
        self.state = state
        self.priority = priority
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.progressFraction = progressFraction
        self.currentBytesPerSecond = currentBytesPerSecond
        self.averageBytesPerSecond = averageBytesPerSecond
        self.elapsedTime = elapsedTime
        self.estimatedTimeRemaining = estimatedTimeRemaining
        self.failureReason = failureReason
        self.checksumOutcome = checksumOutcome
        self.enqueuedAt = enqueuedAt
        self.transportPolicy = transportPolicy
    }

    enum CodingKeys: String, CodingKey {
        case id, url, destinationURL, state, priority, completedBytes, totalBytes, progressFraction, currentBytesPerSecond, averageBytesPerSecond, elapsedTime, estimatedTimeRemaining, failureReason, checksumOutcome, enqueuedAt, transportPolicy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(DownloadID.self, forKey: .id)
        url = try container.decode(URL.self, forKey: .url)
        destinationURL = try container.decode(URL.self, forKey: .destinationURL)
        state = try container.decode(DownloadState.self, forKey: .state)
        priority = try container.decodeIfPresent(DownloadPriority.self, forKey: .priority) ?? .normal
        completedBytes = try container.decodeIfPresent(Int64.self, forKey: .completedBytes) ?? 0
        totalBytes = try container.decodeIfPresent(Int64.self, forKey: .totalBytes)
        progressFraction = try container.decodeIfPresent(Double.self, forKey: .progressFraction) ?? 0.0
        currentBytesPerSecond = try container.decodeIfPresent(Double.self, forKey: .currentBytesPerSecond) ?? 0.0
        averageBytesPerSecond = try container.decodeIfPresent(Double.self, forKey: .averageBytesPerSecond) ?? 0.0
        elapsedTime = try container.decodeIfPresent(TimeInterval.self, forKey: .elapsedTime) ?? 0.0
        estimatedTimeRemaining = try container.decodeIfPresent(TimeInterval.self, forKey: .estimatedTimeRemaining)
        failureReason = try container.decodeIfPresent(String.self, forKey: .failureReason)
        checksumOutcome = try container.decodeIfPresent(ChecksumOutcome.self, forKey: .checksumOutcome) ?? .notChecked
        enqueuedAt = try container.decodeIfPresent(Date.self, forKey: .enqueuedAt) ?? Date()
        transportPolicy = try container.decodeIfPresent(HTTPTransportPolicy.self, forKey: .transportPolicy) ?? .foreground
    }
}

/// Structured asynchronous event emitted during download and queue lifecycle transitions.
public enum DownloadEvent: Sendable, Equatable {
    case added(DownloadSnapshot)
    case queued(DownloadSnapshot)
    case started(DownloadSnapshot)
    case progressUpdated(DownloadSnapshot)
    case paused(DownloadSnapshot)
    case resumed(DownloadSnapshot)
    case completed(DownloadSnapshot)
    case failed(DownloadSnapshot, reason: String)
    case cancelled(DownloadSnapshot)
    case removed(id: DownloadID)
    case integrityVerified(id: DownloadID, outcome: ChecksumOutcome)
    case queueStateChanged(QueueSnapshot)

    public var downloadID: DownloadID? {
        switch self {
        case .added(let snap),
             .queued(let snap),
             .started(let snap),
             .progressUpdated(let snap),
             .paused(let snap),
             .resumed(let snap),
             .completed(let snap),
             .failed(let snap, _),
             .cancelled(let snap):
            return snap.id
        case .removed(let id),
             .integrityVerified(let id, _):
            return id
        case .queueStateChanged:
            return nil
        }
    }
}

/// Unified, high-level public facade coordinating download queues, transfers, and real-time event streams.
///
/// Features:
/// - Single Public Entry Point: Coordinates `DownloadQueueManager`, `DownloadCoordinator`, and `DownloadPersistenceStore`.
/// - Asynchronous Event Streams: Exposes `AsyncStream<DownloadEvent>` with non-competing, broadcast fan-out to multiple observers.
/// - Progress Event Coalescing: Throttles high-frequency progress emissions to avoid buffer overflow, while dispatching
///   all lifecycle state changes immediately.
/// - Authoritative State: Every snapshot reflects live engine and queue invariants without duplicating persisted storage.
/// - Thread-Safe Lifecycle: Built as an actor to enforce structured concurrency and eliminate data races.
public actor DownloadEngine {
    public let queueManager: DownloadQueueManager
    public let coordinator: DownloadCoordinator
    public let persistenceStore: DownloadPersistenceStore

    private var subscribers: [UUID: AsyncStream<DownloadEvent>.Continuation] = [:]
    private var terminalEventsEmitted: Set<DownloadID> = []
    private var lastProgressEmittedAt: [DownloadID: TimeInterval] = [:]
    private var previousStates: [DownloadID: DownloadState] = [:]

    /// Convenience initializer configuring engine with default storage and components.
    public init(
        storageDirectoryURL: URL? = nil,
        maxConcurrentDownloads: Int = 3,
        maxGlobalRequests: Int = 12,
        globalBandwidthLimit: Int64? = nil,
        session: URLSession = .shared,
        backgroundSessionManager: BackgroundDownloadSessionManager? = nil
    ) throws {
        let persistence = try DownloadPersistenceStore(storageDirectoryURL: storageDirectoryURL)
        let budget = SharedRequestBudget(maxGlobalRequests: maxGlobalRequests)
        let limiter = BandwidthLimiter(bytesPerSecond: globalBandwidthLimit)
        let bgManager = backgroundSessionManager ?? (try? BackgroundDownloadSessionManager(
            storageDirectoryURL: persistence.storageDirectoryURL,
            persistenceStore: persistence
        ))
        let coord = try DownloadCoordinator(
            session: session,
            persistenceStore: persistence,
            requestBudget: budget,
            globalBandwidthLimiter: limiter,
            backgroundSessionManager: bgManager
        )
        let queue = DownloadQueueManager(
            coordinator: coord,
            persistenceStore: persistence,
            maxConcurrentDownloads: maxConcurrentDownloads
        )
        self.queueManager = queue
        self.coordinator = coord
        self.persistenceStore = persistence

        Task { [weak self] in
            await self?.attachListeners()
        }
    }

    /// Primary designated initializer accepting explicit engine components.
    public init(
        queueManager: DownloadQueueManager,
        coordinator: DownloadCoordinator,
        persistenceStore: DownloadPersistenceStore
    ) {
        self.queueManager = queueManager
        self.coordinator = coordinator
        self.persistenceStore = persistenceStore

        Task { [weak self] in
            await self?.attachListeners()
        }
    }

    public weak var streamingOrchestrator: StreamingDownloadOrchestrator?

    private var listenersAttached = false

    /// Attaches internal listeners to `DownloadQueueManager` for automated event broadcasting.
    public func attachListeners() async {
        guard !listenersAttached else { return }
        listenersAttached = true
        await queueManager.setGlobalProgressHandler { [weak self] progress in
            Task { [weak self] in
                await self?.handleProgressUpdate(progress)
            }
        }
        await queueManager.setQueueChangedHandler { [weak self] snapshot in
            Task { [weak self] in
                await self?.handleQueueChanged(snapshot)
            }
        }
    }

    // MARK: - Event Subscription

    /// Subscribes to real-time download and queue lifecycle events via an `AsyncStream`.
    ///
    /// Each subscriber receives an independent, non-competing stream of broadcast events.
    /// When the consuming task is cancelled or finishes, observer registration is automatically cleaned up.
    public func events() -> AsyncStream<DownloadEvent> {
        let (stream, continuation) = AsyncStream<DownloadEvent>.makeStream(bufferingPolicy: .bufferingNewest(200))
        let subscriptionID = UUID()
        continuation.onTermination = { [weak self] _ in
            Task { [weak self] in
                await self?.removeSubscriber(subscriptionID)
            }
        }
        registerSubscriber(id: subscriptionID, continuation: continuation)
        return stream
    }

    private func registerSubscriber(id: UUID, continuation: AsyncStream<DownloadEvent>.Continuation) {
        subscribers[id] = continuation
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }

    /// Number of active event-stream subscribers.
    public var subscriberCount: Int {
        subscribers.count
    }

    private func broadcast(_ event: DownloadEvent) {
        for continuation in subscribers.values {
            continuation.yield(event)
        }
    }

    // MARK: - Download Lifecycle Operations

    /// Enqueues a new download request through the engine pipeline.
    ///
    /// - Parameters:
    ///   - request: Target download request configuration.
    ///   - priority: Scheduling priority (.high, .normal, .low).
    ///   - autoStart: If true, immediately triggers the queue scheduler.
    /// - Returns: Initial immutable snapshot of the added download.
    @discardableResult
    public func addDownload(
        _ request: DownloadRequest,
        priority: DownloadPriority = .normal,
        autoStart: Bool = true
    ) async throws -> DownloadSnapshot {
        switch DownloadURLPolicy.classify(request.url) {
        case .directHTTP:
            break
        case .mustUseBlobCaptureService:
            throw DownloadQueueError.unsupportedScheme("Unsupported URL scheme 'blob'. Blob URLs must be captured in-browser via BrowserBlobCaptureService.")
        case .unsupported(let scheme, _):
            if scheme == "http" || scheme == "https" {
                throw DownloadQueueError.invalidURL("Download URL must have a valid non-empty host: \(BrowserURLResolver.sanitizeURLForLogging(request.url))")
            } else {
                let schemeName = scheme.isEmpty ? "unknown" : scheme
                throw DownloadQueueError.unsupportedScheme("Unsupported URL scheme '\(schemeName)'. Only HTTP and HTTPS URLs can be downloaded through the standard download engine.")
            }
        }
        await attachListeners()
        let item = try await queueManager.add(request, priority: priority, autoStart: autoStart)
        let snap = await makeSnapshot(from: item)
        previousStates[request.id] = item.state
        terminalEventsEmitted.remove(request.id)

        broadcast(.added(snap))
        if item.state == .pending {
            broadcast(.queued(snap))
        }
        return snap
    }

    @discardableResult
    public func importCompletedFile(
        fileURL: URL,
        originalURL: URL,
        filename: String,
        mimeType: String? = nil
    ) async throws -> DownloadSnapshot {
        await attachListeners()
        guard fileURL.isFileURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let totalBytes = (attributes[.size] as? NSNumber)?.int64Value,
              totalBytes >= 0 else {
            throw DownloadQueueError.persistenceError("The captured file is missing or has no valid size.")
        }

        let now = Date()
        let record = DownloadRecord(
            originalURL: originalURL,
            resolvedURL: originalURL,
            destinationURL: fileURL,
            totalSize: totalBytes,
            state: .completed,
            storageMode: .directSeek,
            transportPolicy: .foreground,
            suggestedFilename: filename,
            mimeType: mimeType,
            createdAt: now,
            updatedAt: now,
            segments: [
                SegmentRecord(
                    id: 0,
                    startOffset: 0,
                    endOffset: max(0, totalBytes - 1),
                    length: totalBytes,
                    completedBytes: totalBytes
                )
            ]
        )
        do {
            try await persistenceStore.save(record)
            let item = try await queueManager.addCompletedFile(record: record)
            let snapshot = await makeSnapshot(from: item)
            previousStates[item.id] = .completed
            terminalEventsEmitted.insert(item.id)
            broadcast(.added(snapshot))
            broadcast(.completed(snapshot))
            return snapshot
        } catch {
            try? await persistenceStore.delete(tag: record.id)
            if let persistenceError = error as? DownloadQueueError {
                throw persistenceError
            }
            throw DownloadQueueError.persistenceError(error.localizedDescription)
        }
    }

    /// Registers an active streaming download (e.g. HLS or DASH), writing it to persistence
    /// and adding it to the queue manager so it immediately appears in the active Downloads UI.
    @discardableResult
    public func registerStreamingDownload(
        id: DownloadID,
        manifestURL: URL,
        destinationURL: URL,
        filename: String,
        totalBytes: Int64,
        mimeType: String? = "video/mp4"
    ) async throws -> DownloadSnapshot {
        await attachListeners()
        let now = Date()
        let record = DownloadRecord(
            id: id,
            originalURL: manifestURL,
            resolvedURL: manifestURL,
            destinationURL: destinationURL,
            totalSize: totalBytes,
            state: .downloading,
            storageMode: .directSeek,
            transportPolicy: .foreground,
            suggestedFilename: filename,
            mimeType: mimeType,
            createdAt: now,
            updatedAt: now,
            segments: [
                SegmentRecord(
                    id: 0,
                    startOffset: 0,
                    endOffset: max(0, totalBytes - 1),
                    length: totalBytes,
                    completedBytes: 0
                )
            ]
        )
        try await persistenceStore.save(record)
        let item = try await queueManager.addActiveStreamingDownload(record: record)
        let snapshot = await makeSnapshot(from: item)
        previousStates[item.id] = .downloading
        broadcast(.added(snapshot))
        broadcast(.started(snapshot))
        return snapshot
    }

    /// Updates the progress of an active streaming download and broadcasts progress updates to the UI.
    public func updateStreamingDownloadProgress(
        id: DownloadID,
        completedBytes: Int64,
        totalBytes: Int64?,
        bytesPerSecond: Double = 0.0
    ) async {
        await queueManager.updateStreamingProgress(id: id, completedBytes: completedBytes, totalBytes: totalBytes)
        if let item = await queueManager.item(for: id) {
            let snapshot = await makeSnapshot(from: item)
            broadcast(.progressUpdated(snapshot))
        }
    }

    /// Completes an active streaming download after segments are assembled into the final playable file.
    @discardableResult
    public func completeStreamingDownload(
        id: DownloadID,
        finalFileURL: URL,
        totalBytes: Int64
    ) async throws -> DownloadSnapshot {
        await queueManager.completeStreaming(id: id, finalDestinationURL: finalFileURL, totalBytes: totalBytes)
        if var record = try? await persistenceStore.fetch(tag: id) {
            record.state = .completed
            record.destinationURL = finalFileURL
            record.totalSize = totalBytes
            record.updatedAt = Date()
            record.segments = [
                SegmentRecord(
                    id: 0,
                    startOffset: 0,
                    endOffset: max(0, totalBytes - 1),
                    length: totalBytes,
                    completedBytes: totalBytes
                )
            ]
            try? await persistenceStore.save(record)
        }
        if let item = await queueManager.item(for: id) {
            let snapshot = await makeSnapshot(from: item)
            previousStates[item.id] = .completed
            terminalEventsEmitted.insert(item.id)
            broadcast(.completed(snapshot))
            return snapshot
        }
        throw DownloadQueueError.downloadNotFound(id: id)
    }

    /// Marks an active streaming download as failed and broadcasts the failure to the UI.
    public func failStreamingDownload(
        id: DownloadID,
        reason: String
    ) async {
        await queueManager.failStreaming(id: id, reason: reason)
        if var record = try? await persistenceStore.fetch(tag: id) {
            record.state = .failed(reason: reason)
            record.updatedAt = Date()
            try? await persistenceStore.save(record)
        }
        if let item = await queueManager.item(for: id) {
            let snapshot = await makeSnapshot(from: item)
            previousStates[item.id] = .failed(reason: reason)
            broadcast(.failed(snapshot, reason: reason))
        }
    }

    /// Enqueues multiple download requests in bulk.
    @discardableResult
    public func addDownloads(
        _ requests: [DownloadRequest],
        priority: DownloadPriority = .normal,
        autoStart: Bool = true
    ) async throws -> [DownloadSnapshot] {
        await attachListeners()
        var added: [DownloadSnapshot] = []
        for req in requests {
            let snap = try await addDownload(req, priority: priority, autoStart: false)
            added.append(snap)
        }
        if autoStart {
            _ = try await queueManager.add([], autoStart: true)
        }
        return added
    }

    /// Cooperatively pauses an active or queued download.
    public func pauseDownload(id: DownloadID) async throws {
        await attachListeners()
        if let orchestrator = streamingOrchestrator, await orchestrator.isManaging(id: id) {
            await orchestrator.pause(transferID: id)
            await queueManager.pauseStreaming(id: id)
            if var record = try? await persistenceStore.fetch(tag: id) {
                record.state = .paused
                record.updatedAt = Date()
                try? await persistenceStore.save(record)
            }
            if let item = await queueManager.item(for: id) {
                let snap = await makeSnapshot(from: item)
                previousStates[item.id] = .paused
                broadcast(.paused(snap))
            }
            return
        }
        try await queueManager.pause(id: id)
    }

    /// Resumes an interrupted or paused download.
    public func resumeDownload(id: DownloadID) async throws {
        await attachListeners()
        terminalEventsEmitted.remove(id)
        if let orchestrator = streamingOrchestrator, await orchestrator.isManaging(id: id) {
            await orchestrator.resume(transferID: id)
            await queueManager.resumeStreaming(id: id)
            if var record = try? await persistenceStore.fetch(tag: id) {
                record.state = .downloading
                record.updatedAt = Date()
                try? await persistenceStore.save(record)
            }
            if let item = await queueManager.item(for: id) {
                let snap = await makeSnapshot(from: item)
                previousStates[item.id] = .downloading
                broadcast(.resumed(snap))
            }
            return
        }
        try await queueManager.resume(id: id)
    }

    /// Restarts a download from byte 0.
    public func restartDownload(id: DownloadID) async throws {
        await attachListeners()
        terminalEventsEmitted.remove(id)
        try await queueManager.restart(id: id)
    }

    /// Cancels a download, stopping active transfers and optionally deleting destination files.
    public func cancelDownload(id: DownloadID, deleteFile: Bool = false) async throws {
        if let orchestrator = streamingOrchestrator, await orchestrator.isManaging(id: id) {
            await orchestrator.cancel(transferID: id)
            await queueManager.cancel(id: id, deleteDestinationFile: deleteFile)
            return
        }
        try await queueManager.cancel(id: id, deleteDestinationFile: deleteFile)
    }

    /// Removes a download record from the queue.
    ///
    /// - Parameters:
    ///   - id: Identifier of the download to remove.
    ///   - deleteFile: If false (default), the partially or fully downloaded file is preserved on disk.
    public func removeDownload(id: DownloadID, deleteFile: Bool = false) async throws {
        try await queueManager.removeFromQueue(id: id, deleteDestinationFile: deleteFile)
    }

    /// Retries an eligible failed download.
    public func retryDownload(id: DownloadID) async throws {
        await attachListeners()
        terminalEventsEmitted.remove(id)
        try await queueManager.retry(id: id)
    }

    /// Pauses all active and queued downloads in bulk.
    public func pauseAllDownloads() async {
        await queueManager.pauseAll()
    }

    /// Resumes all paused downloads in bulk.
    public func resumeAllDownloads() async {
        await queueManager.resumeAll()
    }

    /// Cancels all active and queued downloads in bulk.
    public func cancelAllDownloads(deleteFiles: Bool = false) async {
        await queueManager.cancelAll(deleteDestinationFiles: deleteFiles)
    }

    // MARK: - State & Inspection APIs

    /// Returns the authoritative snapshot for a specific download ID.
    public func snapshot(for id: DownloadID) async -> DownloadSnapshot? {
        guard let item = await queueManager.item(for: id) else { return nil }
        return await makeSnapshot(from: item)
    }

    /// Returns snapshots of all downloads in priority and sequence order.
    public func allSnapshots() async -> [DownloadSnapshot] {
        let items = await queueManager.allItems()
        var result: [DownloadSnapshot] = []
        for item in items {
            let snap = await makeSnapshot(from: item)
            result.append(snap)
        }
        return result
    }

    /// Returns a high-level summary snapshot of the overall queue.
    public func queueSnapshot() async -> QueueSnapshot {
        await queueManager.snapshot()
    }

    /// Awaits until all pending and active downloads in the queue have settled or completed.
    public func waitUntilIdle(timeoutSeconds: TimeInterval = 10.0) async throws {
        try await queueManager.waitUntilIdle(timeoutSeconds: timeoutSeconds)
    }

    /// Restores the queue state from persistent disk storage after application or process launch.
    public func restoreQueue(autoStart: Bool = true) async throws {
        try await queueManager.restoreQueue(autoStart: autoStart)
    }

    /// Reconciles system background tasks with persisted manifests and on-disk part files.
    public func reconcileBackgroundTransfers() async throws -> BackgroundReconciliationReport {
        try await coordinator.reconcileBackgroundTransfers()
    }

    // MARK: - Resource & Bandwidth Throttling Configuration

    /// Updates the global in-flight HTTP request limit across all downloads.
    public func setMaxGlobalRequests(_ limit: Int) async throws {
        try await queueManager.setMaxGlobalRequests(limit)
    }

    /// Updates or removes the global bandwidth rate limit.
    public func setGlobalSpeedLimit(_ bytesPerSecond: Int64?) async {
        await queueManager.setGlobalSpeedLimit(bytesPerSecond)
    }

    /// Updates or removes an individual download's bandwidth rate limit.
    public func setSpeedLimit(for id: DownloadID, bytesPerSecond: Int64?) async {
        await queueManager.setSpeedLimit(for: id, bytesPerSecond: bytesPerSecond)
    }

    /// Updates maximum concurrent downloads allowed in the queue.
    public func setMaxConcurrentDownloads(_ limit: Int) async throws {
        try await queueManager.setMaxConcurrentDownloads(limit)
    }

    /// Retrieves current speed and ETA metrics for a download.
    public func speedMetrics(for id: DownloadID) async -> SpeedMetrics? {
        await queueManager.speedMetrics(for: id)
    }

    /// Retrieves the final checksum verification outcome for a completed download.
    public func checksumOutcome(for id: DownloadID) async -> ChecksumOutcome {
        await queueManager.checksumOutcome(for: id)
    }

    // MARK: - Internal Event Dispatching

    private func handleProgressUpdate(_ progress: CoordinatorProgress) async {
        guard let item = await queueManager.item(for: progress.downloadID) else { return }
        let snap = await makeSnapshot(from: item, progress: progress)

        // Coalesce high-frequency progress events (maximum 20 Hz / once per 50ms per download)
        let now = ProcessInfo.processInfo.systemUptime
        let last = lastProgressEmittedAt[progress.downloadID] ?? 0
        if now - last >= 0.05 {
            lastProgressEmittedAt[progress.downloadID] = now
            broadcast(.progressUpdated(snap))
        }
    }

    private func handleQueueChanged(_ queueSnap: QueueSnapshot) async {
        for item in queueSnap.items {
            let id = item.id
            let prevState = previousStates[id]
            let currState = item.state
            previousStates[id] = currState

            let snap = await makeSnapshot(from: item)

            // Trigger lifecycle event only on real state transitions
            if prevState != currState {
                if prevState == .paused && (currState == .pending || currState == .downloading) {
                    broadcast(.resumed(snap))
                }

                switch currState {
                case .pending:
                    if prevState != .paused && prevState != nil {
                        broadcast(.queued(snap))
                    }
                case .downloading:
                    terminalEventsEmitted.remove(id)
                    broadcast(.started(snap))
                case .paused:
                    broadcast(.paused(snap))
                case .completed:
                    if !terminalEventsEmitted.contains(id) {
                        terminalEventsEmitted.insert(id)
                        broadcast(.completed(snap))
                        let outcome = await coordinator.checksumOutcome(for: id)
                        if outcome != .notChecked {
                            broadcast(.integrityVerified(id: id, outcome: outcome))
                        }
                    }
                case .failed(let reason):
                    if !terminalEventsEmitted.contains(id) {
                        terminalEventsEmitted.insert(id)
                        broadcast(.failed(snap, reason: reason))
                    }
                case .cancelled:
                    if !terminalEventsEmitted.contains(id) {
                        terminalEventsEmitted.insert(id)
                        broadcast(.cancelled(snap))
                    }
                case .probing:
                    break
                }
            }
        }

        // Detect items removed from queue
        let currentIDs = Set(queueSnap.items.map { $0.id })
        for knownID in previousStates.keys where !currentIDs.contains(knownID) {
            previousStates.removeValue(forKey: knownID)
            terminalEventsEmitted.remove(knownID)
            lastProgressEmittedAt.removeValue(forKey: knownID)
            broadcast(.removed(id: knownID))
        }

        broadcast(.queueStateChanged(queueSnap))
    }

    private func makeSnapshot(from item: QueueItem, progress: CoordinatorProgress? = nil) async -> DownloadSnapshot {
        let coordProg: CoordinatorProgress?
        if let progress = progress {
            coordProg = progress
        } else {
            coordProg = await coordinator.currentProgress(for: item.id)
        }
        let metrics = await coordinator.speedMetrics(for: item.id)
        let outcome = await coordinator.checksumOutcome(for: item.id)

        var failureReason: String? = nil
        if case .failed(let reason) = item.state {
            failureReason = reason
        }

        return DownloadSnapshot(
            id: item.id,
            url: item.request.url,
            destinationURL: item.request.destinationURL,
            state: item.state,
            priority: item.priority,
            completedBytes: item.completedBytes,
            totalBytes: item.totalBytes,
            progressFraction: item.fractionCompleted,
            currentBytesPerSecond: metrics?.currentBytesPerSecond ?? coordProg?.currentBytesPerSecond ?? 0,
            averageBytesPerSecond: metrics?.averageBytesPerSecond ?? coordProg?.averageBytesPerSecond ?? 0,
            elapsedTime: metrics?.elapsedTime ?? coordProg?.elapsedTime ?? 0,
            estimatedTimeRemaining: metrics?.estimatedTimeRemaining ?? coordProg?.estimatedTimeRemaining,
            failureReason: failureReason,
            checksumOutcome: outcome,
            enqueuedAt: item.enqueuedAt,
            transportPolicy: item.request.transportPolicy
        )
    }

    /// Closes all active event streams upon engine termination.
    public func shutdown() {
        for continuation in subscribers.values {
            continuation.finish()
        }
        subscribers.removeAll()
    }

    deinit {
        for continuation in subscribers.values {
            continuation.finish()
        }
    }
}
