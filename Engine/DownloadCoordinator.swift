import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if canImport(CryptoKit)
import CryptoKit
#endif

/// A byte interval requested by a streaming resource transfer.
///
/// This is separate from `DownloadRequest.headers`: `Range` is a transport-managed
/// header and must not be persisted or copied across redirects as an ordinary header.
public struct DownloadByteRange: Sendable, Equatable, Codable, Hashable {
    public let start: Int64
    public let end: Int64

    public init(start: Int64, end: Int64) {
        self.start = start
        self.end = end
    }

    public var length: Int64? {
        guard start >= 0, end >= start else { return nil }
        let difference = end - start
        guard difference < Int64.max else { return nil }
        return difference + 1
    }
}

/// Defines network usage policy for downloads (e.g. Wi-Fi Only vs Any Network).
public enum DownloadNetworkPolicy: String, Codable, Sendable, Equatable, CaseIterable {
    case anyNetwork = "anyNetwork"
    case wifiOnly = "wifiOnly"

    public var allowsCellularAccess: Bool {
        switch self {
        case .anyNetwork: return true
        case .wifiOnly: return false
        }
    }
}

/// Request parameters for a download operation coordinated by `DownloadCoordinator`.
public struct DownloadRequest: Sendable, Equatable, Codable {
    public let id: String
    public let url: URL
    public let destinationURL: URL
    public var headers: [String: String]
    /// Runtime headers may include browser credentials; this controls whether those
    /// sensitive values are copied into the durable download record.
    public var persistSensitiveHeaders: Bool
    public var configuredThreadCount: Int
    public var advancedMode: Bool
    public var storageMode: DownloadStorageMode
    public var reserveDiskBytes: Int64
    public var retryCount: Int
    public var expectedSHA256: String?
    public var maxConcurrentRequests: Int?
    public var speedLimitBytesPerSecond: Int64?
    public var resumePolicy: ResumeIntegrityPolicy
    public var transportPolicy: HTTPTransportPolicy
    public var networkPolicy: DownloadNetworkPolicy
    /// An optional exact byte range for a standalone streaming resource.
    /// Ordinary downloads leave this `nil` and use the existing coordinator path.
    public var requestedByteRange: DownloadByteRange?

    public init(
        id: String = UUID().uuidString,
        url: URL,
        destinationURL: URL,
        headers: [String: String] = [:],
        persistSensitiveHeaders: Bool = true,
        configuredThreadCount: Int = 10,
        advancedMode: Bool = false,
        storageMode: DownloadStorageMode = .directSeek,
        reserveDiskBytes: Int64 = 64 * 1024 * 1024,
        retryCount: Int = 2,
        expectedSHA256: String? = nil,
        maxConcurrentRequests: Int? = nil,
        speedLimitBytesPerSecond: Int64? = nil,
        resumePolicy: ResumeIntegrityPolicy = .compatibility,
        transportPolicy: HTTPTransportPolicy = .foreground,
        networkPolicy: DownloadNetworkPolicy = .anyNetwork,
        requestedByteRange: DownloadByteRange? = nil
    ) {
        self.id = id
        self.url = url
        self.destinationURL = destinationURL
        self.headers = headers
        self.persistSensitiveHeaders = persistSensitiveHeaders
        self.configuredThreadCount = configuredThreadCount
        self.advancedMode = advancedMode
        self.storageMode = storageMode
        self.reserveDiskBytes = reserveDiskBytes
        self.retryCount = max(0, retryCount)
        self.expectedSHA256 = expectedSHA256
        self.maxConcurrentRequests = maxConcurrentRequests
        self.speedLimitBytesPerSecond = speedLimitBytesPerSecond
        self.resumePolicy = resumePolicy
        self.transportPolicy = transportPolicy
        self.networkPolicy = networkPolicy
        self.requestedByteRange = requestedByteRange
    }

    enum CodingKeys: String, CodingKey {
        case id, url, destinationURL, headers, persistSensitiveHeaders, configuredThreadCount, advancedMode, storageMode, reserveDiskBytes, retryCount, expectedSHA256, maxConcurrentRequests, speedLimitBytesPerSecond, resumePolicy, transportPolicy, networkPolicy, requestedByteRange
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        url = try container.decode(URL.self, forKey: .url)
        destinationURL = try container.decode(URL.self, forKey: .destinationURL)
        headers = try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        persistSensitiveHeaders = try container.decodeIfPresent(Bool.self, forKey: .persistSensitiveHeaders) ?? true
        configuredThreadCount = try container.decodeIfPresent(Int.self, forKey: .configuredThreadCount) ?? 10
        advancedMode = try container.decodeIfPresent(Bool.self, forKey: .advancedMode) ?? false
        storageMode = try container.decodeIfPresent(DownloadStorageMode.self, forKey: .storageMode) ?? .directSeek
        reserveDiskBytes = try container.decodeIfPresent(Int64.self, forKey: .reserveDiskBytes) ?? 64 * 1024 * 1024
        retryCount = try container.decodeIfPresent(Int.self, forKey: .retryCount) ?? 2
        expectedSHA256 = try container.decodeIfPresent(String.self, forKey: .expectedSHA256)
        maxConcurrentRequests = try container.decodeIfPresent(Int.self, forKey: .maxConcurrentRequests)
        speedLimitBytesPerSecond = try container.decodeIfPresent(Int64.self, forKey: .speedLimitBytesPerSecond)
        resumePolicy = try container.decodeIfPresent(ResumeIntegrityPolicy.self, forKey: .resumePolicy) ?? .compatibility
        transportPolicy = try container.decodeIfPresent(HTTPTransportPolicy.self, forKey: .transportPolicy) ?? .foreground
        networkPolicy = try container.decodeIfPresent(DownloadNetworkPolicy.self, forKey: .networkPolicy) ?? .anyNetwork
        requestedByteRange = try container.decodeIfPresent(DownloadByteRange.self, forKey: .requestedByteRange)
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
    case unauthorized(url: URL)
    case forbidden(url: URL)
    case linkExpired(url: URL)
    case tokenExpired(url: URL)
    case accessDenied(url: URL, cooldownUntil: Date)
    case rateLimited(url: URL, retryAfter: TimeInterval?)
    case nonResumable(url: URL)
    case insufficientDiskSpace(required: Int64, available: Int64)

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
        case .unauthorized(let url):
            return "Authentication required (HTTP 401) for \(url.host ?? url.absoluteString). Please log in to continue download."
        case .forbidden(let url):
            return "Access forbidden (HTTP 403) for \(url.host ?? url.absoluteString). Please refresh the download link."
        case .linkExpired(let url):
            return "Download link expired or not found (HTTP 404/410) for \(url.host ?? url.absoluteString). Please refresh the download link."
        case .tokenExpired(let url):
            return "Session or token expired (HTTP 401) for \(url.host ?? url.absoluteString). Please re-login or refresh the download link."
        case .accessDenied(let url, let cooldown):
            let seconds = max(0, Int(cooldown.timeIntervalSinceNow))
            return "Access denied (HTTP 403) for \(url.host ?? url.absoluteString). Automatic retry paused for \(seconds)s cooldown."
        case .rateLimited(let url, let retryAfter):
            if let sec = retryAfter {
                return "Rate limited (HTTP 429) for \(url.host ?? url.absoluteString). Retry after \(Int(sec))s."
            } else {
                return "Rate limited (HTTP 429) for \(url.host ?? url.absoluteString). Backing off before retrying."
            }
        case .nonResumable(let url):
            return "Server does not support range requests or reliable resumption for \(url.host ?? url.absoluteString)."
        case .insufficientDiskSpace(let required, let available):
            return "Insufficient disk space: required \(required) bytes, but only \(available) bytes are available."
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
    public typealias BasicAuthChallengeHandler = @Sendable (_ host: String, _ realm: String) async -> (username: String, password: String)?
    public nonisolated(unsafe) static var basicAuthChallengeHandler: BasicAuthChallengeHandler?

    private let session: URLSession
    public let persistenceStore: DownloadPersistenceStore

    public let requestBudget: SharedRequestBudget
    public let globalBandwidthLimiter: BandwidthLimiter
    private var perDownloadLimiters: [String: BandwidthLimiter] = [:]
    private var speedTrackers: [String: DownloadSpeedTracker] = [:]
    private var checksumOutcomes: [String: ChecksumOutcome] = [:]

    // Active task tracking and shutdown synchronization
    private var activeTasks: [String: Task<Void, Error>] = [:]
    private var progressByID: [String: CoordinatorProgress] = [:]
    private var pauseRequested: Set<String> = []
    private var backgroundSessionManager: BackgroundDownloadSessionManager?

    public init(
        session: URLSession = .shared,
        persistenceStore: DownloadPersistenceStore? = nil,
        requestBudget: SharedRequestBudget? = nil,
        globalBandwidthLimiter: BandwidthLimiter? = nil,
        backgroundSessionManager: BackgroundDownloadSessionManager? = nil
    ) throws {
        self.session = session
        self.persistenceStore = try persistenceStore ?? DownloadPersistenceStore()
        self.requestBudget = requestBudget ?? SharedRequestBudget(maxGlobalRequests: 12)
        self.globalBandwidthLimiter = globalBandwidthLimiter ?? BandwidthLimiter(bytesPerSecond: nil)
        self.backgroundSessionManager = backgroundSessionManager
    }

    private func headersForPersistence(_ request: DownloadRequest) -> [String: String] {
        guard !request.persistSensitiveHeaders else { return request.headers }
        return request.headers.filter {
            let name = $0.key.trimmingCharacters(in: .whitespaces).lowercased()
            return !BrowserHeaderFilter.isSensitiveHeader(name) && name != "referer"
        }
    }

    /// Sets or updates the associated background session manager.
    public func setBackgroundSessionManager(_ manager: BackgroundDownloadSessionManager) {
        self.backgroundSessionManager = manager
    }

    /// Returns the associated background session manager if configured.
    public func getBackgroundSessionManager() -> BackgroundDownloadSessionManager? {
        self.backgroundSessionManager
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
        switch DownloadURLPolicy.classify(request.url) {
        case .directHTTP:
            break
        case .mustUseBlobCaptureService:
            throw DownloadCoordinatorError.invalidRequest(reason: "Unsupported URL scheme 'blob'. Blob URLs must be captured in-browser via BrowserBlobCaptureService.")
        case .unsupported(let scheme, _):
            let schemeName = scheme.isEmpty ? "unknown" : scheme
            throw DownloadCoordinatorError.invalidRequest(reason: "Unsupported URL scheme '\(schemeName)'. Only HTTP and HTTPS URLs can be downloaded directly.")
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
        await backgroundSessionManager?.cancelTasks(for: id)

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
        await backgroundSessionManager?.cancelTasks(for: id)

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
                if let bgManager = backgroundSessionManager {
                    for seg in record.segments {
                        let part = bgManager.partFileURL(downloadID: id, segmentID: seg.id)
                        _ = try? FileManager.default.removeItem(at: part)
                    }
                }
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

    /// Refreshes the download URL and headers for an existing download (e.g. after a 403/404 expired token).
    /// If the remote server's validator (ETag / Last-Modified / total size) matches, preserves existing segment progress.
    /// If validators differ or server does not support ranges, restarts cleanly from byte 0.
    @discardableResult
    public func refreshDownload(
        id: String,
        newURL: URL,
        newHeaders: [String: String]? = nil
    ) async throws -> DownloadRecord {
        guard var record = try await persistenceStore.fetch(tag: id) else {
            throw DownloadCoordinatorError.invalidRequest(reason: "Download record not found for ID: \(id)")
        }

        let probeConfig = ProbeConfiguration(
            url: newURL,
            customHeaders: newHeaders ?? record.headers,
            retryCount: 2,
            allowsCellularAccess: record.networkPolicy.allowsCellularAccess
        )
        let probeResult = try await probe.probe(configuration: probeConfig)

        let validation = record.validateForResume(
            remoteETag: probeResult.eTag,
            remoteLastModified: probeResult.lastModified,
            remoteTotalSize: probeResult.contentLength
        )

        record.resolvedURL = probeResult.finalURL
        if let h = newHeaders {
            for (k, v) in h {
                record.headers[k] = v
            }
        }
        record.eTag = probeResult.eTag ?? record.eTag
        record.lastModified = probeResult.lastModified ?? record.lastModified

        if case .valid = validation, probeResult.supportsRange {
            record.state = .paused
            try await persistenceStore.save(record)
        } else {
            let zeroSegments = record.segments.map { seg in
                SegmentRecord(
                    id: seg.id,
                    startOffset: seg.startOffset,
                    endOffset: seg.endOffset,
                    length: seg.length,
                    completedBytes: 0,
                    isCompleted: false
                )
            }
            record.segments = zeroSegments
            record.state = .pending
            try await persistenceStore.save(record)
        }

        return record
    }

    // MARK: - Pipeline Execution

    private func executeDownload(
        request: DownloadRequest,
        progress handler: ProgressHandler?
    ) async throws {
        if let requestedByteRange = request.requestedByteRange {
            try await executeRequestedByteRange(
                request: request,
                byteRange: requestedByteRange,
                progress: handler
            )
            return
        }

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
                headers: headersForPersistence(request),
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
                customHeaders: request.headers,
                allowsCellularAccess: request.networkPolicy.allowsCellularAccess
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
                    if case HTTPRangeProbeError.unauthorized(let u) = error {
                        throw DownloadCoordinatorError.tokenExpired(url: u)
                    }
                    if case HTTPRangeProbeError.forbidden(let u) = error {
                        let cooldown = Date().addingTimeInterval(300)
                        throw DownloadCoordinatorError.accessDenied(url: u, cooldownUntil: cooldown)
                    }
                    if case HTTPRangeProbeError.resourceNotFound(let u) = error {
                        throw DownloadCoordinatorError.linkExpired(url: u)
                    }
                    if probeAttempt >= request.retryCount {
                        if case HTTPRangeProbeError.rateLimited(let u, let retryAfter) = error {
                            throw DownloadCoordinatorError.rateLimited(url: u, retryAfter: retryAfter)
                        }
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
                let requiresDestinationFile = (existing.storageMode == .directSeek && existing.transportPolicy == .foreground)
                if requiresDestinationFile && existing.completedBytes > 0 && !FileManager.default.fileExists(atPath: request.destinationURL.path) {
                    isResume = false
                    record = nil
                } else if !probeResult.supportsRange {
                    // Remote server does not support byte ranges for resumption.
                    // 1DM+ architectural rule: automatically restart download from byte 0 instead of failing.
                    print("[DownloadCoordinator] Server does not support byte ranges on resume for \(request.id); restarting download from byte 0.")
                    isResume = false
                    if FileManager.default.fileExists(atPath: request.destinationURL.path) {
                        try? FileManager.default.removeItem(at: request.destinationURL)
                    }
                    record = nil
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
                            record: existing,
                            backgroundSessionManager: self.backgroundSessionManager
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
                        // Clean up any existing part files and cancel background tasks to prevent mixing versions
                        if let bgManager = self.backgroundSessionManager {
                            await bgManager.cancelTasks(for: request.id)
                            for seg in existing.segments {
                                let part = bgManager.partFileURL(downloadID: request.id, segmentID: seg.id)
                                if FileManager.default.fileExists(atPath: part.path) {
                                    try? FileManager.default.removeItem(at: part)
                                }
                            }
                        }
                        record = nil
                    case .unsupportedNonResumable:
                        // 1DM+ rule: restart from 0 instead of failing with cannotResume
                        print("[DownloadCoordinator] Server non-resumable on resume for \(request.id); restarting download cleanly from byte 0.")
                        isResume = false
                        if FileManager.default.fileExists(atPath: request.destinationURL.path) {
                            try? FileManager.default.removeItem(at: request.destinationURL)
                        }
                        record = nil
                    }
                }
            } else {
                isResume = false
                record = nil
            }

            // Step 3: Disk-space preflight & preallocation check
            if let totalSize = probeResult.totalSize, totalSize > 0 {
                let homeURL = URL(fileURLWithPath: NSHomeDirectory())
                let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
                if let values = try? homeURL.resourceValues(forKeys: keys) {
                    let available = values.volumeAvailableCapacityForImportantUsage ?? values.volumeAvailableCapacity.map(Int64.init) ?? 0
                    if available > 0 && available < totalSize {
                        throw DownloadCoordinatorError.insufficientDiskSpace(required: totalSize, available: available)
                    }
                }
                do {
                    _ = try DownloadFileWriter.requireSufficientDiskSpace(
                        for: request.destinationURL,
                        requiredBytes: totalSize,
                        reserveBytes: request.reserveDiskBytes
                    )
                } catch let error as DownloadFileWriterError {
                    if case .insufficientDiskSpace(let req, let avail) = error {
                        throw DownloadCoordinatorError.insufficientDiskSpace(required: req, available: avail)
                    }
                    throw error
                }
            }

            // Step 4: Dispatch strategy based on server capabilities and transport policy
            // The probe delegate strips credentials on cross-origin redirects. Apply the
            // same decision to every later segment/stream request, otherwise a later
            // request could reintroduce the original Cookie or Authorization header.
            var executionRequest = request
            executionRequest.headers = BrowserHeaderFilter.stripCredentialsOnRedirect(
                headers: request.headers,
                from: request.url,
                to: probeResult.finalURL
            )

            if request.transportPolicy == .background {
                if probeResult.supportsRange, let totalSize = probeResult.totalSize, totalSize > 0 {
                    try await runMultiSegmentBackgroundDownload(
                        request: executionRequest,
                        probeResult: probeResult,
                        existingRecord: isResume ? record : nil,
                        progress: handler
                    )
                } else {
                    // Ranged background download unsupported (server ignores range or indeterminate length)
                    // Fall back cleanly to foreground single-stream transport as per Milestone 6B Requirement 4
                    print("[DownloadCoordinator] Server does not support byte ranges for \(BrowserURLResolver.sanitizeURLForLogging(request.url)); falling back to foreground single-stream transport.")
                    try await runSingleStreamDownload(
                        request: executionRequest,
                        probeResult: probeResult,
                        progress: handler
                    )
                }
            } else {
                if probeResult.supportsRange, let totalSize = probeResult.totalSize, totalSize > 0 {
                    do {
                        try await runMultiSegmentDownload(
                            request: executionRequest,
                            probeResult: probeResult,
                            existingRecord: isResume ? record : nil,
                            progress: handler
                        )
                    } catch {
                        if Self.isRangeIgnored(error) {
                            if isResume {
                                print("[DownloadCoordinator] Server ignored byte range on resume for \(request.id); restarting download cleanly from byte 0.")
                                if FileManager.default.fileExists(atPath: executionRequest.destinationURL.path) {
                                    try? FileManager.default.removeItem(at: executionRequest.destinationURL)
                                }
                            }
                            // Safe fallback for fresh or restarted downloads: Server returned 200 after ranged request
                            try await runSingleStreamFallback(
                                request: executionRequest,
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
                        request: executionRequest,
                        probeResult: probeResult,
                        progress: handler
                    )
                }
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

    /// Executes one exact ranged resource atomically. Streaming planners use this
    /// path for HLS/DASH resources backed by a media-file byte range; normal
    /// downloads continue through the existing probe/allocator pipeline above.
    private func executeRequestedByteRange(
        request: DownloadRequest,
        byteRange: DownloadByteRange,
        progress handler: ProgressHandler?
    ) async throws {
        guard let expectedLength = byteRange.length else {
            throw DownloadCoordinatorError.invalidRequest(reason: "Byte range is invalid")
        }

        let persistedHeaders = headersForPersistence(request)
        let initialRecord = DownloadRecord(
            id: request.id,
            originalURL: request.url,
            resolvedURL: request.url,
            destinationURL: request.destinationURL,
            totalSize: expectedLength,
            state: .downloading,
            storageMode: .directSeek,
            headers: persistedHeaders,
            segments: [SegmentRecord(segment: DownloadSegment(
                id: 0,
                startOffset: 0,
                endOffset: expectedLength - 1,
                length: expectedLength
            ))]
        )
        try await persistenceStore.save(initialRecord)
        updateProgress(
            downloadID: request.id,
            state: .downloading,
            bytesReceived: 0,
            totalBytes: expectedLength,
            completedSegments: 0,
            totalSegments: 1,
            handler: handler
        )

        let probe = HTTPRangeProbe(session: session)
        let probeResult = try await probe.probe(configuration: HTTPRangeProbeConfiguration(
            url: request.url,
            customHeaders: request.headers
        ))
        guard probeResult.supportsRange else {
            throw DownloadCoordinatorError.invalidRequest(
                reason: "The server does not support the requested media byte range"
            )
        }

        var rangedRequest = URLRequest(url: probeResult.finalURL)
        rangedRequest.httpMethod = "GET"
        rangedRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        rangedRequest.setValue("bytes=\(byteRange.start)-\(byteRange.end)", forHTTPHeaderField: "Range")
        let safeHeaders = BrowserHeaderFilter.stripCredentialsOnRedirect(
            headers: request.headers,
            from: request.url,
            to: probeResult.finalURL
        )
        for (name, value) in BrowserHeaderFilter.sanitizeHeaders(safeHeaders) {
            if name.caseInsensitiveCompare("Range") != .orderedSame &&
                name.caseInsensitiveCompare("Accept-Encoding") != .orderedSame {
                rangedRequest.setValue(value, forHTTPHeaderField: name)
            }
        }
        rangedRequest = DownloadRequestEnricher.enrich(rangedRequest)

        let redirectDelegate = DownloadResourceRedirectDelegate(
            originalURL: request.url,
            headers: safeHeaders
        )
        let temporaryURL = request.destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(".range-\(request.id)-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        do {
            let (data, response) = try await session.data(for: rangedRequest, delegate: redirectDelegate)
            try Task.checkCancellation()
            guard let httpResponse = response as? HTTPURLResponse else {
                throw DownloadCoordinatorError.unexpectedSingleStreamError(reason: "Ranged resource did not return an HTTP response")
            }
            guard httpResponse.statusCode == 206 else {
                throw DownloadCoordinatorError.unexpectedSingleStreamError(
                    reason: "Ranged resource returned HTTP \(httpResponse.statusCode) instead of partial content"
                )
            }
            guard Int64(data.count) == expectedLength else {
                throw DownloadCoordinatorError.unexpectedSingleStreamError(reason: "Ranged resource length did not match the planned byte range")
            }
            if let contentRange = httpResponse.value(forHTTPHeaderField: "Content-Range") {
                let parsed = try BackgroundResponseValidator.parseContentRange(contentRange)
                guard parsed.start == byteRange.start, parsed.end == byteRange.end else {
                    throw DownloadCoordinatorError.unexpectedSingleStreamError(reason: "Ranged resource returned an unexpected Content-Range")
                }
            } else {
                throw DownloadCoordinatorError.unexpectedSingleStreamError(reason: "Ranged resource omitted Content-Range")
            }

            try FileManager.default.createDirectory(
                at: request.destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: temporaryURL, options: .atomic)
            if FileManager.default.fileExists(atPath: request.destinationURL.path) {
                try FileManager.default.removeItem(at: request.destinationURL)
            }
            try FileManager.default.moveItem(at: temporaryURL, to: request.destinationURL)

            var completedRecord = initialRecord
            completedRecord.segments[0].completedBytes = expectedLength
            completedRecord.transition(to: .completed)
            try await persistenceStore.save(completedRecord)
            updateProgress(
                downloadID: request.id,
                state: .completed,
                bytesReceived: expectedLength,
                totalBytes: expectedLength,
                completedSegments: 1,
                totalSegments: 1,
                handler: handler
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            _ = try? await persistenceStore.updateState(tag: request.id, state: .failed(reason: error.localizedDescription))
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
            headers: headersForPersistence(request),
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
                                    networkPolicy: request.networkPolicy,
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
                                if case SegmentDownloaderError.tokenExpired = error {
                                    throw DownloadCoordinatorError.tokenExpired(url: request.url)
                                }
                                if case SegmentDownloaderError.accessDenied = error {
                                    let cooldown = Date().addingTimeInterval(300)
                                    throw DownloadCoordinatorError.accessDenied(url: request.url, cooldownUntil: cooldown)
                                }
                                if case SegmentDownloaderError.linkExpired = error {
                                    throw DownloadCoordinatorError.linkExpired(url: request.url)
                                }
                                if Self.isRangeIgnored(error) {
                                    throw error // Fail-fast to trigger fallback
                                }
                                if attempt >= request.retryCount {
                                    if case SegmentDownloaderError.rateLimited(let retryAfter) = error {
                                        throw DownloadCoordinatorError.rateLimited(url: request.url, retryAfter: retryAfter)
                                    }
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

        // File Preallocation: Preallocate disk space to catch disk-full / quota errors at byte 0
        if let total = probeResult.totalSize, total > 0 {
            try? fileHandle.truncate(atOffset: UInt64(total))
        }

        var urlRequest = URLRequest(url: probeResult.finalURL)
        urlRequest.httpMethod = "GET"
        urlRequest.allowsCellularAccess = request.networkPolicy.allowsCellularAccess
        #if canImport(Foundation)
        if #available(iOS 13.0, macOS 10.15, *) {
            urlRequest.allowsExpensiveNetworkAccess = request.networkPolicy.allowsCellularAccess
            urlRequest.allowsConstrainedNetworkAccess = request.networkPolicy.allowsCellularAccess
        }
        #endif
        urlRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        for (name, value) in request.headers {
            if name.caseInsensitiveCompare("Accept-Encoding") == .orderedSame ||
               name.caseInsensitiveCompare("Range") == .orderedSame {
                continue
            }
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        urlRequest = DownloadRequestEnricher.enrich(urlRequest)

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
            networkPolicy: request.networkPolicy,
            eTag: probeResult.eTag,
            lastModified: probeResult.lastModified,
            suggestedFilename: probeResult.suggestedFilename,
            mimeType: probeResult.mimeType,
            headers: headersForPersistence(request),
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

    // MARK: - Multi-Segment Background Download

    private enum BackgroundEvent: Sendable {
        case progress(segmentID: Int, completedBytes: Int64, totalBytes: Int64)
        case completed(segmentID: Int, partURL: URL)
        case failed(segmentID: Int, reason: String)
    }

    private func runMultiSegmentBackgroundDownload(
        request: DownloadRequest,
        probeResult: HTTPRangeProbeResult,
        existingRecord: DownloadRecord?,
        progress handler: ProgressHandler?
    ) async throws {
        guard let totalSize = probeResult.totalSize, totalSize > 0 else {
            throw DownloadCoordinatorError.invalidRequest(reason: "Invalid file size for ranged background download")
        }

        // 1. Allocate segments or restore existing boundaries
        let segments: [DownloadSegment]
        var initialCompletedMap: [Int: Int64] = [:]

        if let existingRecord, !existingRecord.segments.isEmpty {
            segments = existingRecord.segments.map { $0.toDownloadSegment() }
            for seg in existingRecord.segments {
                initialCompletedMap[seg.id] = seg.completedBytes
            }
        } else {
            segments = try SegmentAllocator.makeSegments(
                totalSize: totalSize,
                configuredThreadCount: request.configuredThreadCount,
                advancedMode: request.advancedMode
            )
        }

        try Self.validateSegmentLayout(segments, totalSize: totalSize)

        // Ensure background session manager is available
        guard let bgManager = self.backgroundSessionManager else {
            print("[DownloadCoordinator] Notice: BackgroundDownloadSessionManager unavailable, falling back to foreground transport.")
            try await runMultiSegmentDownload(
                request: request,
                probeResult: probeResult,
                existingRecord: existingRecord,
                progress: handler
            )
            return
        }

        // 2. Reconcile existing part files on disk for safe resumption
        var completedSegmentsSet = Set<Int>()
        for seg in segments {
            let partURL = bgManager.partFileURL(downloadID: request.id, segmentID: seg.id)
            if FileManager.default.fileExists(atPath: partURL.path),
               let attrs = try? FileManager.default.attributesOfItem(atPath: partURL.path),
               let size = attrs[.size] as? Int64 {
                if size == seg.length {
                    // Segment part file exists on disk and is 100% complete
                    initialCompletedMap[seg.id] = seg.length
                    completedSegmentsSet.insert(seg.id)
                } else if size > 0 && size < seg.length {
                    // Segment was partially downloaded and is resumable
                    initialCompletedMap[seg.id] = size
                } else {
                    // Corrupted/oversized part file: remove and reset
                    initialCompletedMap[seg.id] = 0
                    try? FileManager.default.removeItem(at: partURL)
                }
            } else {
                initialCompletedMap[seg.id] = 0
            }
        }

        // 3. Prepare persistent record with .partFiles mode and .background transportPolicy
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
            storageMode: .partFiles,
            transportPolicy: .background,
            eTag: probeResult.eTag,
            lastModified: probeResult.lastModified,
            suggestedFilename: probeResult.suggestedFilename,
            mimeType: probeResult.mimeType,
            headers: headersForPersistence(request),
            segments: segmentRecords
        )
        try await persistenceStore.save(currentRecord)

        // 4. Progress tracker
        let progressAccumulator = ProgressAccumulator(
            segments: segments,
            initialCompletedBytes: initialCompletedMap
        )
        let initialSnapshot = await progressAccumulator.snapshot()

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

        // 5. If all segments are already completed on disk, skip scheduling and jump straight to merge!
        if completedSegmentsSet.count == segments.count {
            try await finalizeBackgroundMerge(
                request: request,
                segments: segments,
                totalSize: totalSize,
                bgManager: bgManager,
                speedTracker: speedTracker,
                progressAccumulator: progressAccumulator,
                handler: handler
            )
            return
        }

        // 6. Setup asynchronous observer stream
        let (eventStream, eventContinuation) = AsyncStream<BackgroundEvent>.makeStream(bufferingPolicy: .unbounded)
        bgManager.addObserver(
            for: request.id,
            onProgress: { segID, done, total in
                eventContinuation.yield(.progress(segmentID: segID, completedBytes: done, totalBytes: total))
            },
            onCompleted: { segID, url in
                eventContinuation.yield(.completed(segmentID: segID, partURL: url))
            },
            onFailed: { segID, err in
                eventContinuation.yield(.failed(segmentID: segID, reason: err.localizedDescription))
            }
        )
        defer {
            bgManager.removeObservers(for: request.id)
            eventContinuation.finish()
        }

        // 7. Schedule pending segments, preventing duplicates
        let existingTasks = await bgManager.activeTasks(for: request.id)
        let activeSegmentIDs = Set(existingTasks.map { $0.segmentID })

        for segment in segments {
            guard !completedSegmentsSet.contains(segment.id) else { continue }
            guard !activeSegmentIDs.contains(segment.id) else { continue } // Prevent duplicate task

            let completedSoFar = initialCompletedMap[segment.id] ?? 0
            let segRec = SegmentRecord(segment: segment, completedBytes: completedSoFar)
            try await bgManager.scheduleSegmentDownload(
                download: currentRecord,
                segment: segRec,
                customHeaders: self.mergeValidatorHeaders(
                    original: request.headers,
                    eTag: probeResult.eTag,
                    lastModified: probeResult.lastModified
                )
            )
        }

        // 8. Event loop processing progress, completion, failure, pause, and cancellation
        var retryAttempts: [Int: Int] = [:]

        do {
            for await event in eventStream {
                try Task.checkCancellation()
                if pauseRequested.contains(request.id) {
                    throw CancellationError()
                }

                switch event {
                case .progress(let segID, let done, _):
                    let agg = await progressAccumulator.update(segmentID: segID, completedBytes: done)
                    let metrics = speedTracker.snapshot(expectedTotalBytes: totalSize)
                    updateProgress(
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

                    let needsCheckpoint = await progressAccumulator.shouldCheckpoint(segmentID: segID, completedBytes: done)
                    if needsCheckpoint {
                        _ = try? await self.persistenceStore.updateSegmentProgress(
                            tag: request.id,
                            segmentID: segID,
                            completedBytes: done
                        )
                    }

                case .completed(let segID, _):
                    completedSegmentsSet.insert(segID)
                    guard let seg = segments.first(where: { $0.id == segID }) else { continue }
                    let agg = await progressAccumulator.update(segmentID: segID, completedBytes: seg.length)
                    _ = try? await self.persistenceStore.updateSegmentProgress(
                        tag: request.id,
                        segmentID: segID,
                        completedBytes: seg.length
                    )

                    let metrics = speedTracker.snapshot(expectedTotalBytes: totalSize)
                    updateProgress(
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

                case .failed(let segID, let reason):
                    let attempt = retryAttempts[segID, default: 0]
                    if attempt < request.retryCount && !pauseRequested.contains(request.id) && !Task.isCancelled {
                        retryAttempts[segID] = attempt + 1
                        let delaySeconds = min(15.0, 0.5 * pow(2.0, Double(attempt)))
                        try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                        if let seg = segments.first(where: { $0.id == segID }) {
                            let segRec = SegmentRecord(segment: seg, completedBytes: 0)
                            _ = try? await bgManager.scheduleSegmentDownload(
                                download: currentRecord,
                                segment: segRec,
                                customHeaders: self.mergeValidatorHeaders(
                                    original: request.headers,
                                    eTag: probeResult.eTag,
                                    lastModified: probeResult.lastModified
                                )
                            )
                        }
                    } else {
                        throw DownloadCoordinatorError.retryLimitExceeded(id: request.id, underlyingError: reason)
                    }
                }

                // Check if all segments are completed
                if completedSegmentsSet.count == segments.count {
                    break
                }
            }

            if pauseRequested.contains(request.id) || Task.isCancelled {
                throw CancellationError()
            }
        } catch is CancellationError {
            await bgManager.cancelTasks(for: request.id)
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
        } catch {
            await bgManager.cancelTasks(for: request.id)
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
            throw error
        }

        // 9. Merge, verify, and finalize completed download
        try await finalizeBackgroundMerge(
            request: request,
            segments: segments,
            totalSize: totalSize,
            bgManager: bgManager,
            speedTracker: speedTracker,
            progressAccumulator: progressAccumulator,
            handler: handler
        )
    }

    private func finalizeBackgroundMerge(
        request: DownloadRequest,
        segments: [DownloadSegment],
        totalSize: Int64,
        bgManager: BackgroundDownloadSessionManager,
        speedTracker: DownloadSpeedTracker,
        progressAccumulator: ProgressAccumulator,
        handler: ProgressHandler?
    ) async throws {
        // 1. Gather and verify all part files
        let sortedSegments = segments.sorted { $0.id < $1.id }
        let partURLs = sortedSegments.map { bgManager.partFileURL(downloadID: request.id, segmentID: $0.id) }
        for (idx, seg) in sortedSegments.enumerated() {
            let partURL = partURLs[idx]
            guard FileManager.default.fileExists(atPath: partURL.path) else {
                throw DownloadCoordinatorError.cannotResume(reason: "Missing part file for segment \(seg.id)")
            }
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: partURL.path),
                  let size = attrs[.size] as? Int64,
                  size == seg.length else {
                throw DownloadCoordinatorError.cannotResume(reason: "Corrupted or incomplete part file for segment \(seg.id)")
            }
        }

        // 2. Safely merge part files using staged replacement
        try DownloadFileWriter.mergeFiles(
            partURLs: partURLs,
            destinationURL: request.destinationURL,
            expectedMergedSize: totalSize
        )

        // 3. Remove part files after successful merge
        for partURL in partURLs {
            try? FileManager.default.removeItem(at: partURL)
        }

        // 4. Validate physical disk file attributes
        let diskAttributes = try FileManager.default.attributesOfItem(atPath: request.destinationURL.path)
        guard let actualDiskSize = diskAttributes[.size] as? Int64, actualDiskSize == totalSize else {
            let error = SegmentDownloaderError.bodyLengthMismatch(
                expected: totalSize,
                actual: (diskAttributes[.size] as? Int64) ?? -1
            )
            _ = try? await persistenceStore.updateState(tag: request.id, state: .failed(reason: error.localizedDescription))
            throw error
        }

        // 5. Update persistence store segment records
        for seg in sortedSegments {
            _ = try? await persistenceStore.updateSegmentProgress(tag: request.id, segmentID: seg.id, completedBytes: seg.length)
        }

        guard let finalRecord = try await persistenceStore.fetch(tag: request.id),
              finalRecord.isAllSegmentsCompleted else {
            let error = DownloadCoordinatorError.segmentLayoutInvalid(reason: "Not all segments reported completed")
            _ = try? await persistenceStore.updateState(tag: request.id, state: .failed(reason: error.localizedDescription))
            throw error
        }

        // 6. Checksum validation
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

        // 7. Mark download completed
        try await persistenceStore.updateState(tag: request.id, state: .completed)
        let finalMetrics = speedTracker.snapshot(expectedTotalBytes: totalSize)
        updateProgress(
            downloadID: request.id,
            state: .completed,
            bytesReceived: totalSize,
            totalBytes: totalSize,
            completedSegments: sortedSegments.count,
            totalSegments: sortedSegments.count,
            currentSpeed: 0,
            averageSpeed: finalMetrics.averageBytesPerSecond,
            elapsedTime: finalMetrics.elapsedTime,
            eta: 0,
            checksumOutcome: checksumOutcomes[request.id],
            handler: handler
        )
    }

    // MARK: - Recovery & Reconciliation

    /// Reconciles system background tasks with persisted manifests and on-disk part files.
    public func reconcileBackgroundTransfers() async throws -> BackgroundReconciliationReport {
        guard let bgManager = self.backgroundSessionManager else {
            return BackgroundReconciliationReport(
                activeTasksCount: 0,
                orphanedTasksCount: 0,
                restoredRecords: [],
                completedRecords: []
            )
        }

        let report = try await bgManager.reconcileActiveTasks()
        let allRecords = try await persistenceStore.fetchAll()

        for record in allRecords where record.transportPolicy == .background && record.state == .downloading {
            var allSegmentsFinished = true
            let sortedSegments = record.segments.sorted { $0.id < $1.id }
            for seg in sortedSegments {
                let partURL = bgManager.partFileURL(downloadID: record.id, segmentID: seg.id)
                let exists = FileManager.default.fileExists(atPath: partURL.path)
                let attrs = try? FileManager.default.attributesOfItem(atPath: partURL.path)
                let size = (attrs?[.size] as? Int64) ?? 0
                if !exists || size != seg.length {
                    allSegmentsFinished = false
                    break
                }
            }

            if allSegmentsFinished && !sortedSegments.isEmpty {
                let partURLs = sortedSegments.map { bgManager.partFileURL(downloadID: record.id, segmentID: $0.id) }
                do {
                    try DownloadFileWriter.mergeFiles(
                        partURLs: partURLs,
                        destinationURL: record.destinationURL,
                        expectedMergedSize: record.totalSize
                    )
                    for partURL in partURLs {
                        try? FileManager.default.removeItem(at: partURL)
                    }
                    for seg in sortedSegments {
                        _ = try? await persistenceStore.updateSegmentProgress(tag: record.id, segmentID: seg.id, completedBytes: seg.length)
                    }
                    try await persistenceStore.updateState(tag: record.id, state: .completed)
                } catch {
                    print("[DownloadCoordinator] Recovery merge deferred for \(record.id): \(error)")
                }
            }
        }

        return report
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
        record: DownloadRecord,
        backgroundSessionManager: BackgroundDownloadSessionManager? = nil
    ) -> DownloadRecord {
        var reconciled = record
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: destinationURL.path) {
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
                // Non-directSeek mode with existing destination file (e.g. linear single-stream mode)
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

        // Destination file does not exist on disk:
        if record.storageMode == .partFiles || record.transportPolicy == .background {
            // For .partFiles or .background transport, progress is stored in individual segment part files.
            // The final destination file does not exist until merge at completion.
            reconciled.segments = record.segments.map { seg in
                var s = seg
                let partURL: URL = {
                    if let bg = backgroundSessionManager {
                        return bg.partFileURL(downloadID: record.id, segmentID: seg.id)
                    } else {
                        return destinationURL.deletingPathExtension().appendingPathExtension("part\(seg.id)")
                    }
                }()

                guard fileManager.fileExists(atPath: partURL.path),
                      let attrs = try? fileManager.attributesOfItem(atPath: partURL.path),
                      let fileSize = attrs[.size] as? Int64 else {
                    s.completedBytes = 0
                    return s
                }

                if fileSize == seg.length {
                    s.completedBytes = seg.length
                } else if fileSize > 0 && fileSize < seg.length {
                    s.completedBytes = fileSize
                } else {
                    // Invalid or corrupted size (e.g. exceeds segment length): purge corrupted file
                    try? fileManager.removeItem(at: partURL)
                    s.completedBytes = 0
                }
                return s
            }
            return reconciled
        }

        // Destination file is missing for directSeek: reset all segments to byte 0
        reconciled.segments = record.segments.map { seg in
            var s = seg
            s.completedBytes = 0
            return s
        }
        return reconciled
    }
}

/// Redirect delegate used by exact ranged resource transfers. It preserves the
/// coordinator's existing origin rule even though the transfer is issued as a
/// single URLSession request rather than through SegmentDownloader.
private final class DownloadResourceRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let originalURL: URL
    private let headers: [String: String]

    init(originalURL: URL, headers: [String: String]) {
        self.originalURL = originalURL
        self.headers = headers
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let redirected = DownloadRequestEnricher.handleRedirect(
            task: task,
            response: response,
            newRequest: request
        )
        completionHandler(redirected)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        let host = space.host

        if space.authenticationMethod == NSURLAuthenticationMethodHTTPBasic ||
           space.authenticationMethod == NSURLAuthenticationMethodDefault ||
           space.authenticationMethod == NSURLAuthenticationMethodHTTPDigest {
            if let saved = KeychainManager.shared.getInternetPassword(server: host, path: "/") {
                completionHandler(.useCredential, URLCredential(user: saved.username, password: saved.password, persistence: .none))
                return
            }
            if let provider = DownloadCoordinator.basicAuthChallengeHandler {
                Task {
                    if let cred = await provider(host, space.realm ?? "") {
                        KeychainManager.shared.storeInternetPassword(
                            username: cred.username,
                            password: cred.password,
                            server: host
                        )
                        completionHandler(.useCredential, URLCredential(user: cred.username, password: cred.password, persistence: .none))
                    } else {
                        completionHandler(.cancelAuthenticationChallenge, nil)
                    }
                }
                return
            }
        }
        completionHandler(.performDefaultHandling, nil)
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
