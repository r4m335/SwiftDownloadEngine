import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if canImport(CryptoKit)
import CryptoKit
#endif

/// Request parameters for a download operation coordinated by `DownloadCoordinator`.
public struct DownloadRequest: Sendable, Equatable, Codable {
    public let id: String
    public let url: URL
    public let destinationURL: URL
    public var headers: [String: String]
    public var configuredThreadCount: Int
    public var advancedMode: Bool
    public var storageMode: DownloadStorageMode
    public var reserveDiskBytes: Int64
    public var retryCount: Int
    public var expectedSHA256: String?
    public var maxConcurrentRequests: Int?
    public var speedLimitBytesPerSecond: Int64?
    public var resumePolicy: ResumeIntegrityPolicy

    public init(
        id: String = UUID().uuidString,
        url: URL,
        destinationURL: URL,
        headers: [String: String] = [:],
        configuredThreadCount: Int = 10,
        advancedMode: Bool = false,
        storageMode: DownloadStorageMode = .directSeek,
        reserveDiskBytes: Int64 = 64 * 1024 * 1024,
        retryCount: Int = 2,
        expectedSHA256: String? = nil,
        maxConcurrentRequests: Int? = nil,
        speedLimitBytesPerSecond: Int64? = nil,
        resumePolicy: ResumeIntegrityPolicy = .compatibility
    ) {
        self.id = id
        self.url = url
        self.destinationURL = destinationURL
        self.headers = headers
        self.configuredThreadCount = configuredThreadCount
        self.advancedMode = advancedMode
        self.storageMode = storageMode
        self.reserveDiskBytes = reserveDiskBytes
        self.retryCount = max(0, retryCount)
        self.expectedSHA256 = expectedSHA256
        self.maxConcurrentRequests = maxConcurrentRequests
        self.speedLimitBytesPerSecond = speedLimitBytesPerSecond
        self.resumePolicy = resumePolicy
    }
}

/// Real-time progress snapshot emitted during download execution.
public struct CoordinatorProgress: Equatable, Sendable {
    public let downloadID: String
    public let state: DownloadState
    public let bytesReceived: Int64
    public let totalBytes: Int64?
    public let completedSegments: Int
    public let totalSegments: Int
    public let currentBytesPerSecond: Double
    public let averageBytesPerSecond: Double
    public let elapsedTime: TimeInterval
    public let estimatedTimeRemaining: TimeInterval?
    public let checksumOutcome: ChecksumOutcome

    public var fractionCompleted: Double {
        guard let totalBytes, totalBytes > 0 else { return 0 }
        return min(1.0, Double(bytesReceived) / Double(totalBytes))
    }

    public init(
        downloadID: String,
        state: DownloadState,
        bytesReceived: Int64,
        totalBytes: Int64?,
        completedSegments: Int,
        totalSegments: Int,
        currentBytesPerSecond: Double = 0,
        averageBytesPerSecond: Double = 0,
        elapsedTime: TimeInterval = 0,
        estimatedTimeRemaining: TimeInterval? = nil,
        checksumOutcome: ChecksumOutcome = .notChecked
    ) {
        self.downloadID = downloadID
        self.state = state
        self.bytesReceived = bytesReceived
        self.totalBytes = totalBytes
        self.completedSegments = completedSegments
        self.totalSegments = totalSegments
        self.currentBytesPerSecond = currentBytesPerSecond
        self.averageBytesPerSecond = averageBytesPerSecond
        self.elapsedTime = elapsedTime
        self.estimatedTimeRemaining = estimatedTimeRemaining
        self.checksumOutcome = checksumOutcome
    }
}

/// Errors specific to coordinated download operations.
public enum DownloadCoordinatorError: Error, LocalizedError, Equatable, Sendable {
    case invalidRequest(reason: String)
    case downloadAlreadyRunning(id: String)
    case cannotResume(reason: String)
    case unexpectedSingleStreamError(reason: String)
    case retryLimitExceeded(id: String, underlyingError: String)
    case cancelled
    case checksumMismatch(expected: String, actual: String)
    case segmentLayoutInvalid(reason: String)

    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let reason):
            return "Invalid download request: \(reason)"
        case .downloadAlreadyRunning(let id):
            return "Download is already running for ID: \(id)"
        case .cannotResume(let reason):
            return "Cannot resume download: \(reason)"
        case .unexpectedSingleStreamError(let reason):
            return "Single-stream download error: \(reason)"
        case .retryLimitExceeded(let id, let underlying):
            return "Retry limit exceeded for download \(id): \(underlying)"
        case .cancelled:
            return "Download operation was cancelled"
        case .checksumMismatch(let expected, let actual):
            return "Checksum mismatch: expected \(expected), computed \(actual)"
        case .segmentLayoutInvalid(let reason):
            return "Invalid segment layout: \(reason)"
        }
    }
}

/// Thread-safe accumulator computing aggregate progress across concurrent workers.
private actor ProgressAccumulator {
    private let segmentsByID: [Int: DownloadSegment]
    private var completedByID: [Int: Int64]
    private var lastFlushedBytesByID: [Int: Int64] = [:]
    private var lastFlushedTimeByID: [Int: Date] = [:]

    init(segments: [DownloadSegment], initialCompletedBytes: [Int: Int64]) {
        self.segmentsByID = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0) })
        self.completedByID = initialCompletedBytes
        self.lastFlushedBytesByID = initialCompletedBytes
        let now = Date()
        self.lastFlushedTimeByID = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, now) })
    }

    func update(
        segmentID: Int,
        completedBytes: Int64
    ) -> (bytesReceived: Int64, completedSegments: Int) {
        guard let segment = segmentsByID[segmentID] else {
            let total = completedByID.values.reduce(0, +)
            return (total, 0)
        }
        completedByID[segmentID] = min(segment.length, max(0, completedBytes))
        let total = completedByID.values.reduce(Int64(0), +)
        let finished = segmentsByID.values.filter {
            (completedByID[$0.id] ?? 0) >= $0.length
        }.count
        return (total, finished)
    }

    func snapshot() -> (bytesReceived: Int64, completedSegments: Int) {
        let total = completedByID.values.reduce(Int64(0), +)
        let finished = segmentsByID.values.filter {
            (completedByID[$0.id] ?? 0) >= $0.length
        }.count
        return (total, finished)
    }

    func shouldCheckpoint(segmentID: Int, completedBytes: Int64) -> Bool {
        let lastBytes = lastFlushedBytesByID[segmentID] ?? 0
        let lastTime = lastFlushedTimeByID[segmentID] ?? .distantPast
        let bytesDelta = completedBytes - lastBytes
        let timeDelta = Date().timeIntervalSince(lastTime)

        if bytesDelta >= 256 * 1024 || timeDelta >= 1.0 {
            lastFlushedBytesByID[segmentID] = completedBytes
            lastFlushedTimeByID[segmentID] = Date()
            return true
        }
        return false
    }

    func getCompletedBytes() -> [Int: Int64] {
        completedByID
    }
}

/// Master download coordinator reproducing 1DM+'s complete download engine lifecycle.
///
/// Workflow:
/// 1. **Probe:** Query remote server using `HTTPRangeProbe` (`Range: bytes=0-`) to determine redirect URL,
///    range capabilities, total size, and HTTP validators (`ETag`, `Last-Modified`).
/// 2. **Preflight Disk Space:** Verify operating system free space via `DownloadFileWriter.requireSufficientDiskSpace`.
/// 3. **Allocate / Resume:** Reconstruct or allocate segment byte boundaries via `SegmentAllocator`.
/// 4. **Initialize Storage:** Prepare destination via `DownloadFileWriter` with `directSeek` or `partFiles`.
/// 5. **Concurrent Execution:** Run concurrent range workers using `SegmentDownloader` in a structured `withThrowingTaskGroup`.
/// 6. **Safe Fallback:** If a worker encounters HTTP `200 OK` (server ignored Range header), cancel sibling workers,
///    safely reset the destination file, and fallback to linear single-stream streaming.
/// 7. **Durable Persistence:** Checkpoint progress periodically and after segment completions via `DownloadPersistenceStore`.
/// 8. **Awaitable Shutdown Barrier:** Guarantees all worker tasks and file handles have cleanly stopped upon pause or cancellation.
public actor DownloadCoordinator {
    public typealias ProgressHandler = @Sendable (CoordinatorProgress) -> Void

    private let session: URLSession
    private let persistenceStore: DownloadPersistenceStore

    public let requestBudget: SharedRequestBudget
    public let globalBandwidthLimiter: BandwidthLimiter
    private var perDownloadLimiters: [String: BandwidthLimiter] = [:]
    private var speedTrackers: [String: DownloadSpeedTracker] = [:]
    private var checksumOutcomes: [String: ChecksumOutcome] = [:]

    // Active task tracking and shutdown synchronization
    private var activeTasks: [String: Task<Void, Error>] = [:]
    private var progressByID: [String: CoordinatorProgress] = [:]
    private var pauseRequested: Set<String> = []

    public init(
        session: URLSession = .shared,
        persistenceStore: DownloadPersistenceStore? = nil,
        requestBudget: SharedRequestBudget? = nil,
        globalBandwidthLimiter: BandwidthLimiter? = nil
    ) throws {
        self.session = session
        self.persistenceStore = try persistenceStore ?? DownloadPersistenceStore()
        self.requestBudget = requestBudget ?? SharedRequestBudget(maxGlobalRequests: 12)
        self.globalBandwidthLimiter = globalBandwidthLimiter ?? BandwidthLimiter(bytesPerSecond: nil)
    }

    /// Dynamically updates the global bandwidth limit.
    public func setGlobalSpeedLimit(_ bytesPerSecond: Int64?) async {
        await globalBandwidthLimiter.setRateLimit(bytesPerSecond)
    }

    /// Dynamically updates or configures the per-download speed limit.
    public func setSpeedLimit(for id: String, bytesPerSecond: Int64?) async {
        if let limiter = perDownloadLimiters[id] {
            await limiter.setRateLimit(bytesPerSecond)
        } else {
            let limiter = BandwidthLimiter(bytesPerSecond: bytesPerSecond)
            perDownloadLimiters[id] = limiter
        }
    }

    /// Retrieves current speed and ETA metrics for a download ID.
    public func speedMetrics(for id: String) -> SpeedMetrics? {
        guard let tracker = speedTrackers[id] else { return nil }
        let total = progressByID[id]?.totalBytes
        return tracker.snapshot(expectedTotalBytes: total)
    }

    /// Retrieves the final checksum outcome for a download ID.
    public func checksumOutcome(for id: String) -> ChecksumOutcome {
        checksumOutcomes[id] ?? .notChecked
    }

    /// Returns the latest progress snapshot for the specified download ID.
    public func currentProgress(for id: String) -> CoordinatorProgress? {
        progressByID[id]
    }

    /// Indicates whether a download operation is actively running.
    public func isRunning(id: String) -> Bool {
        activeTasks[id] != nil
    }

    /// Starts or executes a download request through the engine pipeline.
    public func start(
        _ request: DownloadRequest,
        progress: ProgressHandler? = nil
    ) async throws {
        guard !request.id.isEmpty else {
            throw DownloadCoordinatorError.invalidRequest(reason: "Download ID cannot be empty")
        }
        guard activeTasks[request.id] == nil else {
            throw DownloadCoordinatorError.downloadAlreadyRunning(id: request.id)
        }

        pauseRequested.remove(request.id)

        // Spawn managed Task with an awaitable shutdown barrier
        let task = Task<Void, Error> {
            try await self.executeDownload(request: request, progress: progress)
        }
        activeTasks[request.id] = task

        do {
            try await task.value
            activeTasks.removeValue(forKey: request.id)
        } catch is CancellationError {
            activeTasks.removeValue(forKey: request.id)
            throw CancellationError()
        } catch {
            activeTasks.removeValue(forKey: request.id)
            throw error
        }
    }

    /// Cooperatively pauses an active download.
    /// Awaits the shutdown barrier to guarantee in-flight worker tasks have stopped,
    /// writer buffers are flushed, and persistence state is safely recorded before returning.
    public func pause(id: String) async throws {
        pauseRequested.insert(id)
        await requestBudget.cancelWaiters(for: id)

        guard let task = activeTasks[id] else {
            // If task is not actively running, update persisted state only if not already completed
            if let record = try await persistenceStore.fetch(tag: id), record.state != .completed {
                _ = try? await persistenceStore.updateState(tag: id, state: .paused)
                if var current = progressByID[id] {
                    current = CoordinatorProgress(
                        downloadID: id,
                        state: .paused,
                        bytesReceived: current.bytesReceived,
                        totalBytes: current.totalBytes,
                        completedSegments: current.completedSegments,
                        totalSegments: current.totalSegments,
                        currentBytesPerSecond: 0,
                        averageBytesPerSecond: current.averageBytesPerSecond,
                        elapsedTime: current.elapsedTime,
                        estimatedTimeRemaining: nil,
                        checksumOutcome: current.checksumOutcome
                    )
                    progressByID[id] = current
                }
            }
            return
        }

        // Cancel the task and await completion
        task.cancel()
        _ = try? await task.value
        activeTasks.removeValue(forKey: id)
        pauseRequested.remove(id)

        if let record = try await persistenceStore.fetch(tag: id), record.state != .completed {
            _ = try? await persistenceStore.updateState(tag: id, state: .paused)
            if var current = progressByID[id] {
                current = CoordinatorProgress(
                    downloadID: id,
                    state: .paused,
                    bytesReceived: current.bytesReceived,
                    totalBytes: current.totalBytes,
                    completedSegments: current.completedSegments,
                    totalSegments: current.totalSegments,
                    currentBytesPerSecond: 0,
                    averageBytesPerSecond: current.averageBytesPerSecond,
                    elapsedTime: current.elapsedTime,
                    estimatedTimeRemaining: nil,
                    checksumOutcome: current.checksumOutcome
                )
                progressByID[id] = current
            }
        }
    }

    /// Cancels an active download, updating persistence and optionally deleting the partial file.
    public func cancel(id: String, deleteDestinationFile: Bool = false) async throws {
        await requestBudget.cancelWaiters(for: id)

        let task = activeTasks[id]
        task?.cancel()
        _ = try? await task?.value
        activeTasks.removeValue(forKey: id)
        pauseRequested.remove(id)

        if var current = progressByID[id] {
            current = CoordinatorProgress(
                downloadID: id,
                state: .cancelled,
                bytesReceived: current.bytesReceived,
                totalBytes: current.totalBytes,
                completedSegments: current.completedSegments,
                totalSegments: current.totalSegments,
                currentBytesPerSecond: 0,
                averageBytesPerSecond: current.averageBytesPerSecond,
                elapsedTime: current.elapsedTime,
                estimatedTimeRemaining: nil,
                checksumOutcome: current.checksumOutcome
            )
            progressByID[id] = current
        }

        _ = try? await persistenceStore.updateState(tag: id, state: .cancelled)

        if deleteDestinationFile {
            if let record = try? await persistenceStore.fetch(tag: id) {
                _ = try? FileManager.default.removeItem(at: record.destinationURL)
            }
            _ = try? await persistenceStore.delete(tag: id)
        }
    }

    /// Resumes an interrupted or paused download.
    /// If no valid checkpoint exists, seamlessly performs a standard start.
    public func resume(
        _ request: DownloadRequest,
        progress: ProgressHandler? = nil
    ) async throws {
        guard activeTasks[request.id] == nil else {
            throw DownloadCoordinatorError.downloadAlreadyRunning(id: request.id)
        }

        guard let existingRecord = try await persistenceStore.fetch(tag: request.id) else {
            try await start(request, progress: progress)
            return
        }

        guard existingRecord.originalURL == request.url else {
            throw DownloadCoordinatorError.cannotResume(reason: "URL mismatch with persisted record")
        }

        try await start(request, progress: progress)
    }

    // MARK: - Pipeline Execution

    private func executeDownload(
        request: DownloadRequest,
        progress handler: ProgressHandler?
    ) async throws {
        // Configure per-download speed limiter
        if let limit = request.speedLimitBytesPerSecond {
            if let existing = perDownloadLimiters[request.id] {
                await existing.setRateLimit(limit)
            } else {
                perDownloadLimiters[request.id] = BandwidthLimiter(bytesPerSecond: limit)
            }
        }

        // Configure speed tracker
        let speedTracker = speedTrackers[request.id] ?? DownloadSpeedTracker()
        speedTrackers[request.id] = speedTracker
        speedTracker.reset()

        // Ensure durable record exists from inception so pause, cancel, and failure handlers can track it
        var existingRecord = try await persistenceStore.fetch(tag: request.id)
        if existingRecord == nil {
            let initialRecord = DownloadRecord(
                id: request.id,
                originalURL: request.url,
                resolvedURL: request.url,
                destinationURL: request.destinationURL,
                totalSize: 0,
                state: .downloading,
                storageMode: request.storageMode,
                headers: request.headers,
                segments: []
            )
            try await persistenceStore.save(initialRecord)
            existingRecord = initialRecord
        }

        // Retrieve existing confirmed bytes and total size if resuming or re-probing
        let initialCompleted = existingRecord?.completedBytes ?? 0
        let initialTotal = (existingRecord?.totalSize != nil && existingRecord!.totalSize > 0) ? existingRecord?.totalSize : nil
        let initialFinishedSegments = existingRecord?.segments.filter { $0.isCompleted }.count ?? 0
        let initialTotalSegments = existingRecord?.segments.count ?? 0

        updateProgress(
            downloadID: request.id,
            state: .probing,
            bytesReceived: initialCompleted,
            totalBytes: initialTotal,
            completedSegments: initialFinishedSegments,
            totalSegments: initialTotalSegments,
            handler: handler
        )

        do {
            // Step 1: Probe remote URL with retry
            let probe = HTTPRangeProbe(session: session)
            let probeConfig = HTTPRangeProbeConfiguration(
                url: request.url,
                customHeaders: request.headers
            )
            var probeResult: HTTPRangeProbeResult!
            var probeAttempt = 0
            while true {
                try Task.checkCancellation()
                do {
                    probeResult = try await probe.probe(configuration: probeConfig)
                    break
                } catch {
                    if Task.isCancelled {
                        throw CancellationError()
                    }
                    if probeAttempt >= request.retryCount {
                        throw error
                    }
                    probeAttempt += 1
                    let delaySeconds: Double
                    if case HTTPRangeProbeError.rateLimited(_, let retryAfter) = error, let sec = retryAfter {
                        delaySeconds = min(60.0, max(1.0, sec))
                    } else {
                        delaySeconds = min(15.0, 0.5 * pow(2.0, Double(probeAttempt - 1)))
                    }
                    try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                }
            }
            try Task.checkCancellation()

            // Step 2: Validate against persisted record for safe resume
            var record = try await persistenceStore.fetch(tag: request.id)
            let isResume: Bool
            if let existing = record, existing.state.canResume, existing.totalSize > 0, !existing.segments.isEmpty {
                if existing.completedBytes > 0 && !FileManager.default.fileExists(atPath: request.destinationURL.path) {
                    isResume = false
                    record = nil
                } else if !probeResult.supportsRange {
                    // Remote server does not support byte ranges for resumption.
                    // Preserve the file and notify the user clearly.
                    throw DownloadCoordinatorError.cannotResume(
                        reason: "Resume unavailable: This server doesn't support reliable download resumption. Restarting the download may be required."
                    )
                } else {
                    let validation = existing.validateForResume(
                        remoteETag: probeResult.eTag,
                        remoteLastModified: probeResult.lastModified,
                        remoteTotalSize: probeResult.totalSize,
                        policy: request.resumePolicy
                    )
                    switch validation {
                    case .valid:
                        let reconciled = Self.reconcilePartialFile(
                            destinationURL: request.destinationURL,
                            record: existing
                        )
                        if reconciled != existing {
                            try await persistenceStore.save(reconciled)
                        }
                        isResume = true
                        record = reconciled
                    case .sizeMismatch, .validatorMismatch:
                        isResume = false
                        if FileManager.default.fileExists(atPath: request.destinationURL.path) {
                            try? FileManager.default.removeItem(at: request.destinationURL)
                        }
                        record = nil
                    case .unsupportedNonResumable:
                        throw DownloadCoordinatorError.cannotResume(
                            reason: "Resume unavailable: This server doesn't support reliable download resumption. Restarting the download may be required."
                        )
                    }
                }
            } else {
                isResume = false
                record = nil
            }

            // Step 3: Disk-space preflight
            if let totalSize = probeResult.totalSize, totalSize > 0 {
                _ = try DownloadFileWriter.requireSufficientDiskSpace(
                    for: request.destinationURL,
                    requiredBytes: totalSize,
                    reserveBytes: request.reserveDiskBytes
                )
            }

            // Step 4: Dispatch strategy based on server capabilities
            if probeResult.supportsRange, let totalSize = probeResult.totalSize, totalSize > 0 {
                do {
                    try await runMultiSegmentDownload(
                        request: request,
                        probeResult: probeResult,
                        existingRecord: isResume ? record : nil,
                        progress: handler
                    )
                } catch {
                    if Self.isRangeIgnored(error) {
                        if isResume {
                            throw DownloadCoordinatorError.cannotResume(
                                reason: "Resume unavailable: This server doesn't support reliable download resumption. Restarting the download may be required."
                            )
                        }
                        // Safe fallback for fresh downloads: Server returned 200 after ranged request
                        try await runSingleStreamFallback(
                            request: request,
                            probeResult: probeResult,
                            progress: handler
                        )
                    } else {
                        throw error
                    }
                }
            } else {
                // Linear single-stream download (ranges unsupported or indeterminate length)
                try await runSingleStreamDownload(
                    request: request,
                    probeResult: probeResult,
                    progress: handler
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            _ = try? await persistenceStore.updateState(tag: request.id, state: .failed(reason: error.localizedDescription))
            if let current = try? await persistenceStore.fetch(tag: request.id) {
                updateProgress(
                    downloadID: request.id,
                    state: .failed(reason: error.localizedDescription),
                    bytesReceived: current.completedBytes,
                    totalBytes: current.totalSize,
                    completedSegments: current.segments.filter { $0.isCompleted }.count,
                    totalSegments: current.segments.count,
                    handler: handler
                )
            }
            throw error
        }
    }

    // MARK: - Multi-Segment Download

    private func runMultiSegmentDownload(
        request: DownloadRequest,
        probeResult: HTTPRangeProbeResult,
        existingRecord: DownloadRecord?,
        progress handler: ProgressHandler?
    ) async throws {
        guard let totalSize = probeResult.totalSize, totalSize > 0 else {
            throw DownloadCoordinatorError.invalidRequest(reason: "Invalid file size for ranged download")
        }

        // 1. Allocate segments or restore existing boundaries
        let segments: [DownloadSegment]
        let initialCompletedMap: [Int: Int64]

        if let existingRecord, !existingRecord.segments.isEmpty {
            segments = existingRecord.segments.map { $0.toDownloadSegment() }
            initialCompletedMap = Dictionary(uniqueKeysWithValues: existingRecord.segments.map { ($0.id, $0.completedBytes) })
        } else {
            segments = try SegmentAllocator.makeSegments(
                totalSize: totalSize,
                configuredThreadCount: request.configuredThreadCount,
                advancedMode: request.advancedMode
            )
            initialCompletedMap = [:]
        }

        // Validate segment layout: contiguous boundaries covering 0..<totalSize with no gaps/overlaps
        try Self.validateSegmentLayout(segments, totalSize: totalSize)

        // 2. Prepare persistent record
        let segmentRecords = segments.map { segment in
            SegmentRecord(segment: segment, completedBytes: initialCompletedMap[segment.id] ?? 0)
        }
        let currentRecord = DownloadRecord(
            id: request.id,
            originalURL: request.url,
            resolvedURL: probeResult.finalURL,
            destinationURL: request.destinationURL,
            totalSize: totalSize,
            state: .downloading,
            storageMode: request.storageMode,
            eTag: probeResult.eTag,
            lastModified: probeResult.lastModified,
            suggestedFilename: probeResult.suggestedFilename,
            mimeType: probeResult.mimeType,
            headers: request.headers,
            segments: segmentRecords
        )
        try await persistenceStore.save(currentRecord)

        // 3. Initialize file writer
        let writer = try DownloadFileWriter(
            destinationURL: request.destinationURL,
            totalSize: totalSize,
            mode: request.storageMode
        )
        defer {
            Task { try? await writer.close() }
        }

        // 4. Progress tracker & limiters
        let progressAccumulator = ProgressAccumulator(
            segments: segments,
            initialCompletedBytes: initialCompletedMap
        )
        let initialSnapshot = await progressAccumulator.snapshot()

        let perDownloadLimiter = perDownloadLimiters[request.id]
        let speedTracker = speedTrackers[request.id] ?? DownloadSpeedTracker()
        speedTrackers[request.id] = speedTracker

        updateProgress(
            downloadID: request.id,
            state: .downloading,
            bytesReceived: initialSnapshot.bytesReceived,
            totalBytes: totalSize,
            completedSegments: initialSnapshot.completedSegments,
            totalSegments: segments.count,
            handler: handler
        )

        // 5. Worker downloader
        let downloader = SegmentDownloader(
            session: session,
            writer: writer,
            requestBudget: requestBudget,
            globalBandwidthLimiter: globalBandwidthLimiter,
            perDownloadBandwidthLimiter: perDownloadLimiter,
            speedTracker: speedTracker,
            downloadID: request.id,
            maxConcurrentRequests: request.maxConcurrentRequests
        )

        // 6. Structured concurrent execution
        do {
            try await withThrowingTaskGroup(of: (Int, Int64).self) { group in
                for segment in segments {
                    let alreadyDone = min(segment.length, max(0, initialCompletedMap[segment.id] ?? 0))
                    if alreadyDone >= segment.length {
                        continue
                    }

                    group.addTask {
                        var attempt = 0
                        while true {
                            try Task.checkCancellation()
                            do {
                                try await downloader.download(
                                    url: probeResult.finalURL,
                                    segment: segment,
                                    completedBytes: alreadyDone,
                                    expectedTotalSize: totalSize,
                                    headers: self.mergeValidatorHeaders(
                                        original: request.headers,
                                        eTag: probeResult.eTag,
                                        lastModified: probeResult.lastModified
                                    ),
                                    eTag: probeResult.eTag,
                                    progress: { snapshot in
                                        Task {
                                            let agg = await progressAccumulator.update(
                                                segmentID: segment.id,
                                                completedBytes: snapshot.bytesReceived
                                            )
                                            let metrics = speedTracker.snapshot(expectedTotalBytes: totalSize)
                                            await self.updateProgress(
                                                downloadID: request.id,
                                                state: .downloading,
                                                bytesReceived: agg.bytesReceived,
                                                totalBytes: totalSize,
                                                completedSegments: agg.completedSegments,
                                                totalSegments: segments.count,
                                                currentSpeed: metrics.currentBytesPerSecond,
                                                averageSpeed: metrics.averageBytesPerSecond,
                                                elapsedTime: metrics.elapsedTime,
                                                eta: metrics.estimatedTimeRemaining,
                                                handler: handler
                                            )

                                            let needsCheckpoint = await progressAccumulator.shouldCheckpoint(
                                                segmentID: segment.id,
                                                completedBytes: snapshot.bytesReceived
                                            )
                                            if needsCheckpoint {
                                                // Guarantee partial file is safely flushed to disk before committing checkpoint
                                                try? await writer.synchronize()
                                                _ = try? await self.persistenceStore.updateSegmentProgress(
                                                    tag: request.id,
                                                    segmentID: segment.id,
                                                    completedBytes: snapshot.bytesReceived
                                                )
                                            }
                                        }
                                    }
                                )
                                return (segment.id, segment.length)
                            } catch {
                                if Task.isCancelled {
                                    throw CancellationError()
                                }
                                if Self.isRangeIgnored(error) {
                                    throw error // Fail-fast to trigger fallback
                                }
                                if attempt >= request.retryCount {
                                    throw error
                                }
                                attempt += 1
                                let delaySeconds: Double
                                if case SegmentDownloaderError.rateLimited(let retryAfter) = error, let sec = retryAfter {
                                    delaySeconds = min(60.0, max(1.0, sec))
                                } else if case SegmentDownloaderError.rateLimited = error {
                                    delaySeconds = min(30.0, 1.0 * pow(2.0, Double(attempt)))
                                } else {
                                    delaySeconds = min(15.0, 0.25 * Double(attempt))
                                }
                                try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                            }
                        }
                    }
                }

                // Checkpoint segments as they complete
                while let (finishedSegmentID, finalLength) = try await group.next() {
                    try await self.persistenceStore.updateSegmentProgress(
                        tag: request.id,
                        segmentID: finishedSegmentID,
                        completedBytes: finalLength
                    )
                }
            }
            if pauseRequested.contains(request.id) || Task.isCancelled {
                // Ensure writer buffers are flushed to disk before recording checkpoint
                try? await writer.synchronize()
                let completedMap = await progressAccumulator.getCompletedBytes()
                for (segID, bytes) in completedMap {
                    _ = try? await persistenceStore.updateSegmentProgress(tag: request.id, segmentID: segID, completedBytes: bytes)
                }
                _ = try? await persistenceStore.updateState(tag: request.id, state: .paused)
                let snap = await progressAccumulator.snapshot()
                let metrics = speedTracker.snapshot(expectedTotalBytes: totalSize)
                updateProgress(
                    downloadID: request.id,
                    state: .paused,
                    bytesReceived: snap.bytesReceived,
                    totalBytes: totalSize,
                    completedSegments: snap.completedSegments,
                    totalSegments: segments.count,
                    currentSpeed: 0,
                    averageSpeed: metrics.averageBytesPerSecond,
                    elapsedTime: metrics.elapsedTime,
                    eta: nil,
                    handler: handler
                )
                throw CancellationError()
            }
        } catch let error {
            if pauseRequested.contains(request.id) || Task.isCancelled {
                try? await writer.synchronize()
                let completedMap = await progressAccumulator.getCompletedBytes()
                for (segID, bytes) in completedMap {
                    _ = try? await persistenceStore.updateSegmentProgress(tag: request.id, segmentID: segID, completedBytes: bytes)
                }
                _ = try? await persistenceStore.updateState(tag: request.id, state: .paused)
                let snap = await progressAccumulator.snapshot()
                let metrics = speedTracker.snapshot(expectedTotalBytes: totalSize)
                updateProgress(
                    downloadID: request.id,
                    state: .paused,
                    bytesReceived: snap.bytesReceived,
                    totalBytes: totalSize,
                    completedSegments: snap.completedSegments,
                    totalSegments: segments.count,
                    currentSpeed: 0,
                    averageSpeed: metrics.averageBytesPerSecond,
                    elapsedTime: metrics.elapsedTime,
                    eta: nil,
                    handler: handler
                )
                throw CancellationError()
            }
            if !Self.isRangeIgnored(error) {
                try? await writer.synchronize()
                let completedMap = await progressAccumulator.getCompletedBytes()
                for (segID, bytes) in completedMap {
                    _ = try? await persistenceStore.updateSegmentProgress(tag: request.id, segmentID: segID, completedBytes: bytes)
                }
                _ = try? await persistenceStore.updateState(tag: request.id, state: .failed(reason: error.localizedDescription))
                let snap = await progressAccumulator.snapshot()
                let metrics = speedTracker.snapshot(expectedTotalBytes: totalSize)
                updateProgress(
                    downloadID: request.id,
                    state: .failed(reason: error.localizedDescription),
                    bytesReceived: snap.bytesReceived,
                    totalBytes: totalSize,
                    completedSegments: snap.completedSegments,
                    totalSegments: segments.count,
                    currentSpeed: 0,
                    averageSpeed: metrics.averageBytesPerSecond,
                    elapsedTime: metrics.elapsedTime,
                    eta: nil,
                    handler: handler
                )
            }
            throw error
        }

        // 7. Flush and close writer
        try await writer.synchronize()
        try await writer.close()

        // 8. MANDATORY INVARIANT: Physical file validation before marking completed
        let diskAttributes = try FileManager.default.attributesOfItem(atPath: request.destinationURL.path)
        guard let actualDiskSize = diskAttributes[.size] as? Int64, actualDiskSize == totalSize else {
            let error = SegmentDownloaderError.bodyLengthMismatch(
                expected: totalSize,
                actual: (diskAttributes[.size] as? Int64) ?? -1
            )
            _ = try? await persistenceStore.updateState(tag: request.id, state: .failed(reason: error.localizedDescription))
            throw error
        }

        // 9. MANDATORY INVARIANT: Verify all segments completed in persistence store
        let finalCompletedMap = await progressAccumulator.getCompletedBytes()
        for (segID, bytes) in finalCompletedMap {
            _ = try? await persistenceStore.updateSegmentProgress(tag: request.id, segmentID: segID, completedBytes: bytes)
        }

        guard let finalRecord = try await persistenceStore.fetch(tag: request.id),
              finalRecord.isAllSegmentsCompleted else {
            let error = DownloadCoordinatorError.segmentLayoutInvalid(reason: "Not all segments reported completed")
            _ = try? await persistenceStore.updateState(tag: request.id, state: .failed(reason: error.localizedDescription))
            throw error
        }

        // 10. Checksum validation (if provided)
        if let expectedSHA = request.expectedSHA256, !expectedSHA.isEmpty {
            let actualSHA = try FileHasher.sha256(for: request.destinationURL)
            guard actualSHA.caseInsensitiveCompare(expectedSHA) == .orderedSame else {
                checksumOutcomes[request.id] = .mismatch(expected: expectedSHA, actual: actualSHA)
                let error = DownloadCoordinatorError.checksumMismatch(expected: expectedSHA, actual: actualSHA)
                _ = try? await persistenceStore.updateState(tag: request.id, state: .failed(reason: error.localizedDescription))
                throw error
            }
            checksumOutcomes[request.id] = .verified(sha256: actualSHA)
        } else {
            checksumOutcomes[request.id] = .notChecked
        }

        // 11. Finalize completed status
        try await persistenceStore.updateState(tag: request.id, state: .completed)
        let finalMetrics = speedTracker.snapshot(expectedTotalBytes: totalSize)
        updateProgress(
            downloadID: request.id,
            state: .completed,
            bytesReceived: totalSize,
            totalBytes: totalSize,
            completedSegments: segments.count,
            totalSegments: segments.count,
            currentSpeed: 0,
            averageSpeed: finalMetrics.averageBytesPerSecond,
            elapsedTime: finalMetrics.elapsedTime,
            eta: 0,
            checksumOutcome: checksumOutcomes[request.id],
            handler: handler
        )
    }

    // MARK: - Single-Stream Fallback

    private func runSingleStreamFallback(
        request: DownloadRequest,
        probeResult: HTTPRangeProbeResult,
        progress handler: ProgressHandler?
    ) async throws {
        // Discard partially written destination file to prevent overlapping corrupted slices
        let manager = FileManager.default
        if manager.fileExists(atPath: request.destinationURL.path) {
            try? manager.removeItem(at: request.destinationURL)
        }

        try await runSingleStreamDownload(
            request: request,
            probeResult: probeResult,
            progress: handler
        )
    }

    // MARK: - Linear Single-Stream Download

    private func runSingleStreamDownload(
        request: DownloadRequest,
        probeResult: HTTPRangeProbeResult,
        progress handler: ProgressHandler?
    ) async throws {
        let destinationURL = request.destinationURL
        let parentDir = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try? FileManager.default.removeItem(at: destinationURL)
        }
        guard FileManager.default.createFile(atPath: destinationURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let fileHandle = try FileHandle(forWritingTo: destinationURL)
        defer {
            try? fileHandle.synchronize()
            try? fileHandle.close()
        }

        var urlRequest = URLRequest(url: probeResult.finalURL)
        urlRequest.httpMethod = "GET"
        urlRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        for (name, value) in request.headers {
            if name.caseInsensitiveCompare("Accept-Encoding") == .orderedSame ||
               name.caseInsensitiveCompare("Range") == .orderedSame {
                continue
            }
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        let expectedTotal = probeResult.totalSize
        let singleSegment = DownloadSegment(
            id: 0,
            startOffset: 0,
            endOffset: (expectedTotal ?? 1) - 1,
            length: expectedTotal ?? 0
        )
        let record = DownloadRecord(
            id: request.id,
            originalURL: request.url,
            resolvedURL: probeResult.finalURL,
            destinationURL: destinationURL,
            totalSize: expectedTotal ?? 0,
            state: .downloading,
            storageMode: .directSeek,
            eTag: probeResult.eTag,
            lastModified: probeResult.lastModified,
            suggestedFilename: probeResult.suggestedFilename,
            mimeType: probeResult.mimeType,
            headers: request.headers,
            segments: [SegmentRecord(segment: singleSegment)]
        )
        try await persistenceStore.save(record)

        let perDownloadLimiter = perDownloadLimiters[request.id]
        let speedTracker = speedTrackers[request.id] ?? DownloadSpeedTracker()
        speedTrackers[request.id] = speedTracker
        speedTracker.reset()

        updateProgress(
            downloadID: request.id,
            state: .downloading,
            bytesReceived: 0,
            totalBytes: expectedTotal,
            completedSegments: 0,
            totalSegments: 1,
            handler: handler
        )

        var acquiredPermit = false
        try await requestBudget.acquire(downloadID: request.id, maxPerDownload: request.maxConcurrentRequests)
        acquiredPermit = true

        do {
            let (bytes, response) = try await session.bytes(for: urlRequest)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw DownloadCoordinatorError.unexpectedSingleStreamError(
                    reason: "Unexpected HTTP response: not HTTPURLResponse"
                )
            }
            if httpResponse.statusCode == 429 {
                let retryAfter = HTTPRangeProbe.parseRetryAfter(httpResponse.value(forHTTPHeaderField: "Retry-After"))
                throw SegmentDownloaderError.rateLimited(retryAfterSeconds: retryAfter)
            }
            guard httpResponse.statusCode == 200 || httpResponse.statusCode == 206 else {
                throw DownloadCoordinatorError.unexpectedSingleStreamError(
                    reason: "Unexpected HTTP status: \(httpResponse.statusCode)"
                )
            }

            var buffer = Data()
            buffer.reserveCapacity(64 * 1024)
            var totalWritten: Int64 = 0
            var lastFlushedSingleStreamBytes: Int64 = 0
            var lastFlushedSingleStreamTime = Date()

            do {
                for try await byte in bytes {
                    try Task.checkCancellation()
                    buffer.append(byte)
                    if buffer.count >= 64 * 1024 {
                        try await BandwidthLimiter.throttle(
                            bytes: Int64(buffer.count),
                            global: self.globalBandwidthLimiter,
                            perDownload: perDownloadLimiter
                        )
                        try fileHandle.write(contentsOf: buffer)
                        totalWritten += Int64(buffer.count)
                        speedTracker.record(bytes: Int64(buffer.count))
                        buffer.removeAll(keepingCapacity: true)

                        let metrics = speedTracker.snapshot(expectedTotalBytes: expectedTotal)
                        updateProgress(
                            downloadID: request.id,
                            state: .downloading,
                            bytesReceived: totalWritten,
                            totalBytes: expectedTotal,
                            completedSegments: 0,
                            totalSegments: 1,
                            currentSpeed: metrics.currentBytesPerSecond,
                            averageSpeed: metrics.averageBytesPerSecond,
                            elapsedTime: metrics.elapsedTime,
                            eta: metrics.estimatedTimeRemaining,
                            handler: handler
                        )

                        if totalWritten - lastFlushedSingleStreamBytes >= 256 * 1024 ||
                            Date().timeIntervalSince(lastFlushedSingleStreamTime) >= 1.0 {
                            lastFlushedSingleStreamBytes = totalWritten
                            lastFlushedSingleStreamTime = Date()
                            try? fileHandle.synchronize()
                            _ = try? await persistenceStore.updateSegmentProgress(
                                tag: request.id,
                                segmentID: 0,
                                completedBytes: totalWritten
                            )
                        }
                    }
                }

                if !buffer.isEmpty {
                    try Task.checkCancellation()
                    try await BandwidthLimiter.throttle(
                        bytes: Int64(buffer.count),
                        global: self.globalBandwidthLimiter,
                        perDownload: perDownloadLimiter
                    )
                    try fileHandle.write(contentsOf: buffer)
                    totalWritten += Int64(buffer.count)
                    speedTracker.record(bytes: Int64(buffer.count))
                    buffer.removeAll(keepingCapacity: false)
                }
            } catch {
                if pauseRequested.contains(request.id) || Task.isCancelled {
                    _ = try? await persistenceStore.updateState(tag: request.id, state: .paused)
                    let metrics = speedTracker.snapshot(expectedTotalBytes: expectedTotal)
                    updateProgress(
                        downloadID: request.id,
                        state: .paused,
                        bytesReceived: totalWritten,
                        totalBytes: expectedTotal,
                        completedSegments: 0,
                        totalSegments: 1,
                        currentSpeed: 0,
                        averageSpeed: metrics.averageBytesPerSecond,
                        elapsedTime: metrics.elapsedTime,
                        eta: nil,
                        handler: handler
                    )
                    throw CancellationError()
                }
                _ = try? await persistenceStore.updateState(tag: request.id, state: .failed(reason: error.localizedDescription))
                updateProgress(
                    downloadID: request.id,
                    state: .failed(reason: error.localizedDescription),
                    bytesReceived: totalWritten,
                    totalBytes: expectedTotal,
                    completedSegments: 0,
                    totalSegments: 1,
                    currentSpeed: 0,
                    averageSpeed: 0,
                    elapsedTime: 0,
                    eta: nil,
                    handler: handler
                )
                throw error
            }

            if let expected = expectedTotal, totalWritten != expected {
                throw SegmentDownloaderError.bodyLengthMismatch(expected: expected, actual: totalWritten)
            }

            try fileHandle.synchronize()

            // Physical file size validation on disk
            let diskAttributes = try FileManager.default.attributesOfItem(atPath: request.destinationURL.path)
            if let expected = expectedTotal {
                guard let actualDiskSize = diskAttributes[.size] as? Int64, actualDiskSize == expected else {
                    let error = SegmentDownloaderError.bodyLengthMismatch(
                        expected: expected,
                        actual: (diskAttributes[.size] as? Int64) ?? -1
                    )
                    _ = try? await persistenceStore.updateState(tag: request.id, state: .failed(reason: error.localizedDescription))
                    throw error
                }
            }

            // Checksum validation (if provided)
            if let expectedSHA = request.expectedSHA256, !expectedSHA.isEmpty {
                let actualSHA = try FileHasher.sha256(for: request.destinationURL)
                guard actualSHA.caseInsensitiveCompare(expectedSHA) == .orderedSame else {
                    checksumOutcomes[request.id] = .mismatch(expected: expectedSHA, actual: actualSHA)
                    let error = DownloadCoordinatorError.checksumMismatch(expected: expectedSHA, actual: actualSHA)
                    _ = try? await persistenceStore.updateState(tag: request.id, state: .failed(reason: error.localizedDescription))
                    throw error
                }
                checksumOutcomes[request.id] = .verified(sha256: actualSHA)
            } else {
                checksumOutcomes[request.id] = .notChecked
            }

            try await persistenceStore.updateSegmentProgress(tag: request.id, segmentID: 0, completedBytes: totalWritten)
            try await persistenceStore.updateState(tag: request.id, state: .completed)

            let finalMetrics = speedTracker.snapshot(expectedTotalBytes: expectedTotal)
            updateProgress(
                downloadID: request.id,
                state: .completed,
                bytesReceived: totalWritten,
                totalBytes: expectedTotal ?? totalWritten,
                completedSegments: 1,
                totalSegments: 1,
                currentSpeed: 0,
                averageSpeed: finalMetrics.averageBytesPerSecond,
                elapsedTime: finalMetrics.elapsedTime,
                eta: 0,
                checksumOutcome: checksumOutcomes[request.id],
                handler: handler
            )

            if acquiredPermit {
                await requestBudget.release(downloadID: request.id)
                acquiredPermit = false
            }
        } catch {
            if acquiredPermit {
                await requestBudget.release(downloadID: request.id)
                acquiredPermit = false
            }
            throw error
        }
    }

    // MARK: - Helpers

    nonisolated static func isRangeIgnored(_ error: Error) -> Bool {
        if let segError = error as? SegmentDownloaderError,
           case .unexpectedStatus(let expected, let actual) = segError {
            return expected == 206 && actual == 200
        }
        return false
    }

    private func mergeValidatorHeaders(
        original: [String: String],
        eTag: String?,
        lastModified: String?
    ) -> [String: String] {
        var result = original
        if let eTag, !eTag.isEmpty {
            result["If-Range"] = eTag
        } else if let lastModified, !lastModified.isEmpty {
            result["If-Range"] = lastModified
        }
        return result
    }

    nonisolated static func validateSegmentLayout(_ segments: [DownloadSegment], totalSize: Int64) throws {
        guard !segments.isEmpty else {
            throw DownloadCoordinatorError.segmentLayoutInvalid(reason: "Segments list is empty")
        }
        guard segments[0].startOffset == 0 else {
            throw DownloadCoordinatorError.segmentLayoutInvalid(reason: "First segment does not start at byte 0")
        }
        guard segments.last!.endOffset == totalSize - 1 else {
            throw DownloadCoordinatorError.segmentLayoutInvalid(reason: "Last segment does not end at totalSize - 1")
        }
        for i in 1..<segments.count {
            if segments[i].startOffset != segments[i - 1].endOffset + 1 {
                throw DownloadCoordinatorError.segmentLayoutInvalid(
                    reason: "Segment gap or overlap detected between \(segments[i-1].id) and \(segments[i].id)"
                )
            }
        }
        let sumLength = segments.reduce(0) { $0 + $1.length }
        guard sumLength == totalSize else {
            throw DownloadCoordinatorError.segmentLayoutInvalid(
                reason: "Sum of segment lengths (\(sumLength)) does not equal totalSize (\(totalSize))"
            )
        }
    }

    private func updateProgress(
        downloadID: String,
        state: DownloadState,
        bytesReceived: Int64,
        totalBytes: Int64?,
        completedSegments: Int,
        totalSegments: Int,
        currentSpeed: Double = 0,
        averageSpeed: Double = 0,
        elapsedTime: TimeInterval = 0,
        eta: TimeInterval? = nil,
        checksumOutcome: ChecksumOutcome? = nil,
        handler: ProgressHandler?
    ) {
        let outcome = checksumOutcome ?? checksumOutcomes[downloadID] ?? .notChecked
        let snapshot = CoordinatorProgress(
            downloadID: downloadID,
            state: state,
            bytesReceived: bytesReceived,
            totalBytes: totalBytes,
            completedSegments: completedSegments,
            totalSegments: totalSegments,
            currentBytesPerSecond: currentSpeed,
            averageBytesPerSecond: averageSpeed,
            elapsedTime: elapsedTime,
            estimatedTimeRemaining: eta,
            checksumOutcome: outcome
        )
        progressByID[downloadID] = snapshot
        handler?(snapshot)
    }

    // MARK: - Disk Reconciliation

    /// Reconciles the partial destination file on disk with persisted segment metadata before resumption.
    /// Ensures the partial file, persisted byte offset, and subsequent HTTP Range request all agree.
    public static func reconcilePartialFile(
        destinationURL: URL,
        record: DownloadRecord
    ) -> DownloadRecord {
        var reconciled = record
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: destinationURL.path) else {
            // Destination file is missing: reset all segments to byte 0
            reconciled.segments = record.segments.map { seg in
                var s = seg
                s.completedBytes = 0
                return s
            }
            return reconciled
        }

        guard let attrs = try? fileManager.attributesOfItem(atPath: destinationURL.path),
              let fileSize = attrs[.size] as? Int64 else {
            return reconciled
        }

        if record.storageMode == .directSeek {
            // Direct seek files are preallocated to totalSize
            let total = record.totalSize
            if total > 0 {
                if fileSize < total {
                    // File on disk is smaller than expected totalSize: re-truncate or reset
                    if let handle = try? FileHandle(forWritingTo: destinationURL) {
                        try? handle.truncate(atOffset: UInt64(total))
                        try? handle.close()
                    } else {
                        reconciled.segments = record.segments.map { seg in
                            var s = seg
                            s.completedBytes = 0
                            return s
                        }
                    }
                }
            }
        } else {
            // Linear single-stream mode
            let savedCompleted = record.completedBytes
            if fileSize > savedCompleted {
                // File contains more data than saved checkpoint (e.g. 90 MB on disk vs 25 MB checkpointed)
                // Truncate to saved checkpoint so subsequent HTTP Range request and disk file align perfectly
                if let handle = try? FileHandle(forWritingTo: destinationURL) {
                    try? handle.truncate(atOffset: UInt64(savedCompleted))
                    try? handle.close()
                }
            } else if fileSize < savedCompleted {
                // Disk file has fewer bytes than checkpoint: clamp completedBytes to actual disk size
                if !reconciled.segments.isEmpty {
                    reconciled.segments[0].completedBytes = max(0, fileSize)
                }
            }
        }

        return reconciled
    }
}

/// Standard, zero-dependency SHA-256 implementation ensuring portable digest validation across all platforms.
public enum EngineSHA256 {
    public static func hash(data: Data) -> String {
        var h: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
        ]
        let k: [UInt32] = [
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
            0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
            0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
            0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
            0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
            0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
            0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
            0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
        ]

        var bytes = Array(data)
        let bitLength = UInt64(data.count) * 8
        bytes.append(0x80)
        while (bytes.count % 64) != 56 {
            bytes.append(0x00)
        }
        for i in (0..<8).reversed() {
            bytes.append(UInt8((bitLength >> (i * 8)) & 0xff))
        }

        for chunkStart in stride(from: 0, to: bytes.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 64)
            for i in 0..<16 {
                let idx = chunkStart + i * 4
                w[i] = (UInt32(bytes[idx]) << 24) |
                       (UInt32(bytes[idx + 1]) << 16) |
                       (UInt32(bytes[idx + 2]) << 8) |
                       UInt32(bytes[idx + 3])
            }
            for i in 16..<64 {
                let s0 = (w[i-15] >> 7 | w[i-15] << 25) ^ (w[i-15] >> 18 | w[i-15] << 14) ^ (w[i-15] >> 3)
                let s1 = (w[i-2] >> 17 | w[i-2] << 15) ^ (w[i-2] >> 19 | w[i-2] << 13) ^ (w[i-2] >> 10)
                w[i] = w[i-16] &+ s0 &+ w[i-7] &+ s1
            }

            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hVal = h[7]
            for i in 0..<64 {
                let s1 = (e >> 6 | e << 26) ^ (e >> 11 | e << 21) ^ (e >> 25 | e << 7)
                let ch = (e & f) ^ (~e & g)
                let temp1 = hVal &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = (a >> 2 | a << 30) ^ (a >> 13 | a << 19) ^ (a >> 22 | a << 10)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ maj

                hVal = g
                g = f
                f = e
                e = d &+ temp1
                d = c
                c = b
                b = a
                a = temp1 &+ temp2
            }
            h[0] = h[0] &+ a
            h[1] = h[1] &+ b
            h[2] = h[2] &+ c
            h[3] = h[3] &+ d
            h[4] = h[4] &+ e
            h[5] = h[5] &+ f
            h[6] = h[6] &+ g
            h[7] = h[7] &+ hVal
        }

        return h.map { String(format: "%08x", $0) }.joined()
    }
}

// MARK: - Streaming File Hasher
#if canImport(CryptoKit)
public enum FileHasher {
    public static func sha256(for url: URL, progress: (@Sendable (Double) -> Void)? = nil) throws -> String {
        let fileHandle = try FileHandle(forReadingFrom: url)
        defer { try? fileHandle.close() }
        let totalSize: Int64 = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        var hasher = SHA256()
        let bufferSize = 256 * 1024
        var processed: Int64 = 0

        while true {
            let data = fileHandle.readData(ofLength: bufferSize)
            if data.isEmpty { break }
            hasher.update(data: data)
            processed += Int64(data.count)
            if totalSize > 0, let progress = progress {
                let frac = min(1.0, max(0.0, Double(processed) / Double(totalSize)))
                progress(frac)
            }
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
#else
public enum FileHasher {
    public static func sha256(for url: URL, progress: (@Sendable (Double) -> Void)? = nil) throws -> String {
        let data = try Data(contentsOf: url)
        progress?(1.0)
        return EngineSHA256.hash(data: data)
    }
}
#endif
