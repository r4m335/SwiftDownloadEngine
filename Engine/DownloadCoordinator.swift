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

/// Defines network usage policy for downloads (e.g. Wi-Fi Only vs Any Network, expensive networks, constrained networks).
public struct DownloadNetworkPolicy: Codable, Sendable, Equatable, Hashable {
    public var allowsCellularAccess: Bool
    public var allowsExpensiveNetworkAccess: Bool
    public var allowsConstrainedNetworkAccess: Bool

    public init(
        allowsCellularAccess: Bool = true,
        allowsExpensiveNetworkAccess: Bool = true,
        allowsConstrainedNetworkAccess: Bool = false
    ) {
        self.allowsCellularAccess = allowsCellularAccess
        self.allowsExpensiveNetworkAccess = allowsExpensiveNetworkAccess
        self.allowsConstrainedNetworkAccess = allowsConstrainedNetworkAccess
    }

    public static let anyNetwork = DownloadNetworkPolicy(
        allowsCellularAccess: true,
        allowsExpensiveNetworkAccess: true,
        allowsConstrainedNetworkAccess: false
    )

    public static let wifiOnly = DownloadNetworkPolicy(
        allowsCellularAccess: false,
        allowsExpensiveNetworkAccess: false,
        allowsConstrainedNetworkAccess: false
    )

    public static let wifiAllowExpensive = DownloadNetworkPolicy(
        allowsCellularAccess: false,
        allowsExpensiveNetworkAccess: true,
        allowsConstrainedNetworkAccess: false
    )

    public static let unrestricted = DownloadNetworkPolicy(
        allowsCellularAccess: true,
        allowsExpensiveNetworkAccess: true,
        allowsConstrainedNetworkAccess: true
    )

    enum CodingKeys: String, CodingKey {
        case allowsCellularAccess
        case allowsExpensiveNetworkAccess
        case allowsConstrainedNetworkAccess
    }

    public init(from decoder: Decoder) throws {
        if let singleValue = try? decoder.singleValueContainer(),
           let stringVal = try? singleValue.decode(String.self) {
            switch stringVal {
            case "wifiOnly":
                self = .wifiOnly
            case "wifiAllowExpensive":
                self = .wifiAllowExpensive
            case "unrestricted":
                self = .unrestricted
            default:
                self = .anyNetwork
            }
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.allowsCellularAccess = try container.decodeIfPresent(Bool.self, forKey: .allowsCellularAccess) ?? true
        self.allowsExpensiveNetworkAccess = try container.decodeIfPresent(Bool.self, forKey: .allowsExpensiveNetworkAccess) ?? true
        self.allowsConstrainedNetworkAccess = try container.decodeIfPresent(Bool.self, forKey: .allowsConstrainedNetworkAccess) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(allowsCellularAccess, forKey: .allowsCellularAccess)
        try container.encode(allowsExpensiveNetworkAccess, forKey: .allowsExpensiveNetworkAccess)
        try container.encode(allowsConstrainedNetworkAccess, forKey: .allowsConstrainedNetworkAccess)
    }
}

extension EngineConfiguration {
    public var defaultNetworkPolicy: DownloadNetworkPolicy {
        DownloadNetworkPolicy(
            allowsCellularAccess: allowCellular,
            allowsExpensiveNetworkAccess: allowExpensiveNetwork,
            allowsConstrainedNetworkAccess: allowConstrainedNetwork
        )
    }
}

/// Request parameters for a download operation coordinated by `DownloadCoordinator`.
public struct DownloadRequest: Sendable, Equatable, Codable {
    public let id: String
    public var url: URL
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
    /// Verified allowed origins, hosts, or domain wildcards permitted to receive credentials
    /// (Authorization and custom authentication headers) across redirects.
    public var allowedCredentialOrigins: Set<String>

    public init(
        id: String = UUID().uuidString,
        url: URL,
        destinationURL: URL,
        headers: [String: String] = [:],
        persistSensitiveHeaders: Bool = false,
        configuredThreadCount: Int = 10,
        advancedMode: Bool = false,
        storageMode: DownloadStorageMode = .directSeek,
        reserveDiskBytes: Int64 = 64 * 1024 * 1024,
        retryCount: Int = 2,
        expectedSHA256: String? = nil,
        maxConcurrentRequests: Int? = nil,
        speedLimitBytesPerSecond: Int64? = nil,
        resumePolicy: ResumeIntegrityPolicy = .conservative,
        transportPolicy: HTTPTransportPolicy = .foreground,
        networkPolicy: DownloadNetworkPolicy = .anyNetwork,
        requestedByteRange: DownloadByteRange? = nil,
        allowedCredentialOrigins: Set<String> = []
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
        self.allowedCredentialOrigins = allowedCredentialOrigins
    }

    enum CodingKeys: String, CodingKey {
        case id, url, destinationURL, headers, persistSensitiveHeaders, configuredThreadCount, advancedMode, storageMode, reserveDiskBytes, retryCount, expectedSHA256, maxConcurrentRequests, speedLimitBytesPerSecond, resumePolicy, transportPolicy, networkPolicy, requestedByteRange, allowedCredentialOrigins
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
        resumePolicy = try container.decodeIfPresent(ResumeIntegrityPolicy.self, forKey: .resumePolicy) ?? .conservative
        transportPolicy = try container.decodeIfPresent(HTTPTransportPolicy.self, forKey: .transportPolicy) ?? .foreground
        networkPolicy = try container.decodeIfPresent(DownloadNetworkPolicy.self, forKey: .networkPolicy) ?? .anyNetwork
        requestedByteRange = try container.decodeIfPresent(DownloadByteRange.self, forKey: .requestedByteRange)
        allowedCredentialOrigins = try container.decodeIfPresent(Set<String>.self, forKey: .allowedCredentialOrigins) ?? []
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

    public var isUnauthorized: Bool {
        if case .unauthorized = self { return true }
        return false
    }

    public var isForbidden: Bool {
        if case .forbidden = self { return true }
        return false
    }

    public var isLinkExpired: Bool {
        if case .linkExpired = self { return true }
        return false
    }
}

/// Thread-safe accumulator computing aggregate progress across concurrent workers.
actor ProgressAccumulator {
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

/// Master download coordinator managing multi-segmented parallel downloads and lifecycle states.
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

    public typealias CredentialRefreshHandler = @Sendable (_ url: URL) async -> [String: String]?
    public nonisolated(unsafe) static var credentialRefreshHandler: CredentialRefreshHandler?

    private var dynamicAuthHeaders: [String: [String: String]] = [:]

    public func getDynamicHeaders(for downloadID: String, baseHeaders: [String: String]) -> [String: String] {
        guard let custom = dynamicAuthHeaders[downloadID] else { return baseHeaders }
        var result = baseHeaders
        for (k, v) in custom {
            result[k] = v
        }
        return result
    }

    public func updateDynamicHeaders(for downloadID: String, freshHeaders: [String: String]) {
        var current = dynamicAuthHeaders[downloadID] ?? [:]
        for (k, v) in freshHeaders {
            current[k] = v
        }
        dynamicAuthHeaders[downloadID] = current
    }

    /// Attempts to obtain refreshed authentication credentials (bearer tokens, session cookies, auth headers)
    /// when a transfer experiences HTTP 401 Unauthorized or 403 Forbidden.
    /// Priority order:
    /// 1. `DownloadCoordinator.credentialRefreshHandler` callback if registered.
    /// 2. Active browser snapshot from `DownloadRequestEnricher.sharedSessionSnapshot`.
    /// 3. Matching cookies from `HTTPCookieStorage.shared`.
    public func attemptCredentialRefresh(for url: URL, downloadID: String? = nil) async -> [String: String]? {
        var refreshed: [String: String]? = nil
        if let handler = Self.credentialRefreshHandler,
           let headers = await handler(url),
           !headers.isEmpty {
            PipelineLogger.shared.log("[DownloadCoordinator] Successfully refreshed credentials via credentialRefreshHandler for \(BrowserURLResolver.sanitizeURLForLogging(url))")
            refreshed = headers
        } else if let snapshot = DownloadRequestEnricher.sharedSessionSnapshot.snapshot {
            var headers: [String: String] = [:]
            if !snapshot.allCookies.isEmpty {
                let matching = snapshot.allCookies.filter { $0.matches(url: url) }
                if !matching.isEmpty {
                    headers["Cookie"] = matching.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                }
            }
            if !snapshot.userAgent.isEmpty {
                headers["User-Agent"] = snapshot.userAgent
            }
            if !headers.isEmpty {
                PipelineLogger.shared.log("[DownloadCoordinator] Refreshed credentials from active sharedSessionSnapshot for \(BrowserURLResolver.sanitizeURLForLogging(url))")
                refreshed = headers
            }
        } else if let cookies = HTTPCookieStorage.shared.cookies(for: url), !cookies.isEmpty {
            let cookieHeader = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            PipelineLogger.shared.log("[DownloadCoordinator] Refreshed credentials from HTTPCookieStorage for \(BrowserURLResolver.sanitizeURLForLogging(url))")
            refreshed = ["Cookie": cookieHeader]
        }

        if let refreshed, let downloadID {
            updateDynamicHeaders(for: downloadID, freshHeaders: refreshed)
        }
        return refreshed
    }

    public static let sharedSession: URLSession = ForegroundURLSession.make()

    var session: URLSession
    let connectivityGate: NetworkConnectivityGate
    public let persistenceStore: DownloadPersistenceStore

    public let requestBudget: SharedRequestBudget
    public let globalBandwidthLimiter: BandwidthLimiter
    var perDownloadLimiters: [String: BandwidthLimiter] = [:]
    var speedTrackers: [String: DownloadSpeedTracker] = [:]
    var checksumOutcomes: [String: ChecksumOutcome] = [:]

    // Active task tracking and shutdown synchronization
    var activeTasks: [String: Task<Void, Error>] = [:]
    var progressByID: [String: CoordinatorProgress] = [:]
    var pauseRequested: Set<String> = []
    var pendingBackgroundEarliestBeginDates: [String: Date] = [:]
    var backgroundSessionManager: BackgroundDownloadSessionManager?

    public nonisolated static func isInternalStreamingSegmentID(_ id: String) -> Bool {
        id.hasPrefix(InternalStreamingConstants.segmentIDPrefix) ||
        id.hasPrefix(InternalStreamingConstants.legacySegmentIDPrefix)
    }

    public nonisolated static func isLoopbackURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1" || host == "0.0.0.0"
    }

    public init(
        session: URLSession = DownloadCoordinator.sharedSession,
        persistenceStore: DownloadPersistenceStore? = nil,
        requestBudget: SharedRequestBudget? = nil,
        globalBandwidthLimiter: BandwidthLimiter? = nil,
        backgroundSessionManager: BackgroundDownloadSessionManager? = nil,
        connectivityGate: NetworkConnectivityGate = .shared
    ) throws {
        self.session = session
        self.persistenceStore = try persistenceStore ?? DownloadPersistenceStore()
        self.requestBudget = requestBudget ?? SharedRequestBudget(maxGlobalRequests: 12)
        self.globalBandwidthLimiter = globalBandwidthLimiter ?? BandwidthLimiter(bytesPerSecond: nil)
        self.backgroundSessionManager = backgroundSessionManager
        self.connectivityGate = connectivityGate
        if let bg = backgroundSessionManager {
            wireBackgroundAuthRecovery(bg)
        }
    }

    private func wireBackgroundAuthRecovery(_ manager: BackgroundDownloadSessionManager) {
        manager.onAuthenticationRequired = { [weak self] downloadID, segmentID, status in
            Task { [weak self] in
                guard let self else { return }
                if let rec = try? await self.persistenceStore.fetch(tag: downloadID) {
                    _ = await self.attemptCredentialRefresh(for: rec.originalURL, downloadID: downloadID)
                }
            }
        }
    }

    func headersForPersistence(_ request: DownloadRequest) -> [String: String] {
        guard !request.persistSensitiveHeaders else { return request.headers }
        return request.headers.filter {
            let name = $0.key.trimmingCharacters(in: .whitespaces).lowercased()
            return !BrowserHeaderFilter.isSensitiveHeader(name) && name != "referer"
        }
    }

    /// Sets or updates the associated background session manager.
    public func setBackgroundSessionManager(_ manager: BackgroundDownloadSessionManager) {
        self.backgroundSessionManager = manager
        wireBackgroundAuthRecovery(manager)
    }

    /// Returns the associated background session manager if configured.
    public func getBackgroundSessionManager() -> BackgroundDownloadSessionManager? {
        self.backgroundSessionManager
    }

    /// Configures earliestBeginDate on background session tasks.
    public func setBackgroundEarliestBeginDate(_ date: Date?, for downloadID: String? = nil) async {
        await backgroundSessionManager?.setEarliestBeginDate(date, for: downloadID)
    }

    /// Stores a scheduling date for the next background execution of a queue item.
    /// The date is consumed when that execution creates URLSession tasks, before
    /// those tasks are resumed.
    public func setPendingBackgroundEarliestBeginDate(_ date: Date, for downloadID: String) {
        pendingBackgroundEarliestBeginDates[downloadID] = date
    }

    /// Rebuilds the foreground `URLSession` when proxy settings change at runtime.
    public func updateSession(proxyDictionary: [AnyHashable: Any]?) {
        let previous = self.session
        self.session = ForegroundURLSession.make(
            maximumConnectionsPerHost: SegmentAllocator.maxThreadCount,
            proxyDictionary: proxyDictionary
        )
        if previous !== URLSession.shared && previous !== DownloadCoordinator.sharedSession {
            previous.finishTasksAndInvalidate()
        }
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
        try await startDownload(request: request, isResumeRequest: false, progress: progress)
    }

    func startDownload(
        request: DownloadRequest,
        isResumeRequest: Bool,
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
            try await self.executeDownload(request: request, isResumeRequest: isResumeRequest, progress: progress)
        }
        activeTasks[request.id] = task

        do {
            try await task.value
            activeTasks.removeValue(forKey: request.id)
            dynamicAuthHeaders.removeValue(forKey: request.id)
        } catch is CancellationError {
            activeTasks.removeValue(forKey: request.id)
            dynamicAuthHeaders.removeValue(forKey: request.id)
            throw CancellationError()
        } catch {
            activeTasks.removeValue(forKey: request.id)
            dynamicAuthHeaders.removeValue(forKey: request.id)
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
                do {
                    _ = try await persistenceStore.updateState(tag: id, state: .paused)
                } catch {
                    PipelineLogger.shared.log("[DownloadCoordinator] Failed to update persistence state to .paused for \(id): \(error.localizedDescription)")
                }
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
            do {
                _ = try await persistenceStore.updateState(tag: id, state: .paused)
            } catch {
                PipelineLogger.shared.log("[DownloadCoordinator] Failed to update persistence state to .paused for \(id): \(error.localizedDescription)")
            }
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

        do {
            _ = try await persistenceStore.updateState(tag: id, state: .cancelled)
        } catch {
            PipelineLogger.shared.log("[DownloadCoordinator] Failed to update persistence state to .cancelled for \(id): \(error.localizedDescription)")
        }

        if deleteDestinationFile {
            do {
                if let record = try await persistenceStore.fetch(tag: id) {
                    do {
                        try FileManager.default.removeItem(at: record.destinationURL)
                    } catch {
                        PipelineLogger.shared.log("[DownloadCoordinator] Warning: Failed to remove destination \(record.destinationURL.path): \(error.localizedDescription)")
                    }
                    let parentDir = record.destinationURL.deletingLastPathComponent()
                    let tempDir = parentDir.appendingPathComponent(".tmp", isDirectory: true)
                    for seg in record.segments {
                        let part = tempDir.appendingPathComponent("segment-\(seg.id).part")
                        do {
                            try FileManager.default.removeItem(at: part)
                        } catch {
                            PipelineLogger.shared.log("[DownloadCoordinator] Warning: Failed to remove part file \(part.path): \(error.localizedDescription)")
                        }
                    }
                    if let bgManager = backgroundSessionManager {
                        for seg in record.segments {
                            let part = bgManager.partFileURL(downloadID: id, segmentID: seg.id)
                            do {
                                try FileManager.default.removeItem(at: part)
                            } catch {
                                PipelineLogger.shared.log("[DownloadCoordinator] Warning: Failed to remove background part file \(part.path): \(error.localizedDescription)")
                            }
                        }
                    }
                }
            } catch {
                PipelineLogger.shared.log("[DownloadCoordinator] Warning: Failed to fetch record for deletion \(id): \(error.localizedDescription)")
            }
            do {
                _ = try await persistenceStore.delete(tag: id)
            } catch {
                PipelineLogger.shared.log("[DownloadCoordinator] Warning: Failed to delete persistence store record for \(id): \(error.localizedDescription)")
            }
        }
    }

    /// Cancels all active download tasks and awaits their termination barrier.
    public func cancelAll() async {
        for (id, task) in activeTasks {
            task.cancel()
            await requestBudget.cancelWaiters(for: id)
            await backgroundSessionManager?.cancelTasks(for: id)
        }
        for task in activeTasks.values {
            _ = try? await task.value
        }
        activeTasks.removeAll()
        pauseRequested.removeAll()
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

        guard existingRecord.originalURL == request.url || existingRecord.resolvedURL == request.url else {
            throw DownloadCoordinatorError.cannotResume(reason: "URL mismatch with persisted record")
        }

        try await startDownload(request: request, isResumeRequest: true, progress: progress)
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

        let probe = HTTPRangeProbe(session: session)
        let probeConfig = HTTPRangeProbeConfiguration(
            url: newURL,
            customHeaders: newHeaders ?? record.securedHeaders,
            networkPolicy: record.networkPolicy
        )
        let probeResult = try await probe.probe(configuration: probeConfig)

        let validation = record.validateForResume(
            remoteETag: probeResult.eTag,
            remoteLastModified: probeResult.lastModified,
            remoteTotalSize: probeResult.totalSize
        )

        record.originalURL = newURL
        record.resolvedURL = probeResult.finalURL
        if let h = newHeaders {
            record.updateHeaders(h)
        }
        record.eTag = probeResult.eTag ?? record.eTag
        record.lastModified = probeResult.lastModified ?? record.lastModified

        if case .valid = validation, (probeResult.supportsRange || probeResult.canResume) {
            record.state = .paused
            try await persistenceStore.save(record)
        } else {
            let zeroSegments = record.segments.map { seg in
                SegmentRecord(
                    id: seg.id,
                    startOffset: seg.startOffset,
                    endOffset: seg.endOffset,
                    length: seg.length,
                    completedBytes: 0
                )
            }
            record.segments = zeroSegments
            record.state = .pending
            try await persistenceStore.save(record)
        }

        return record
    }

    // MARK: - Pipeline Execution

    func executeDownload(
        request: DownloadRequest,
        isResumeRequest: Bool = false,
        progress handler: ProgressHandler?
    ) async throws {
        let backgroundEarliestBeginDate: Date? = pendingBackgroundEarliestBeginDates.removeValue(forKey: request.id)

        if let requestedByteRange = request.requestedByteRange {
            try await executeRequestedByteRange(
                request: request,
                byteRange: requestedByteRange,
                progress: handler
            )
            return
        }

        if Self.isInternalStreamingSegmentID(request.id) {
            try await executeStandaloneStreamingSegment(
                request: request,
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
        let initialTotal = (existingRecord?.totalSize ?? 0) > 0 ? existingRecord?.totalSize : nil
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
                networkPolicy: request.networkPolicy,
                allowedCredentialOrigins: request.allowedCredentialOrigins
            )
            var probeResult: HTTPRangeProbeResult!
            var probeAttempt = 0
            while true {
                try Task.checkCancellation()
                if !Self.isLoopbackURL(request.url) {
                    try await connectivityGate.waitUntilAvailable(
                        networkPolicy: request.networkPolicy
                    )
                }
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
                    guard HTTPRetryPolicy.isRetryable(error) else {
                        throw error
                    }
                    if HTTPRetryPolicy.shouldWaitForConnectivity(error) && !Self.isLoopbackURL(request.url) {
                        try await connectivityGate.waitUntilAvailable(
                            networkPolicy: request.networkPolicy
                        )
                        continue
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
                    if isResumeRequest {
                        throw DownloadCoordinatorError.cannotResume(
                            reason: "Resume unavailable: This server doesn't support reliable download resumption. Restarting the download may be required."
                        )
                    }
                    // Remote server does not support byte ranges for resumption.
                    // Resiliency rule: automatically restart download from byte 0 instead of failing.
                    PipelineLogger.shared.log("[DownloadCoordinator] Server does not support byte ranges on resume for \(request.id); restarting download from byte 0.")
                    isResume = false
                    if FileManager.default.fileExists(atPath: request.destinationURL.path) {
                        do {
                            try FileManager.default.removeItem(at: request.destinationURL)
                        } catch {
                            PipelineLogger.shared.log("[DownloadCoordinator] Warning: Failed to remove destination on non-range resume: \(error.localizedDescription)")
                        }
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
                            do {
                                try FileManager.default.removeItem(at: request.destinationURL)
                            } catch {
                                PipelineLogger.shared.log("[DownloadCoordinator] Warning: Failed to remove destination on validator mismatch: \(error.localizedDescription)")
                            }
                        }
                        // Clean up any existing part files and cancel background tasks to prevent mixing versions
                        if let bgManager = self.backgroundSessionManager {
                            await bgManager.cancelTasks(for: request.id)
                            for seg in existing.segments {
                                let part = bgManager.partFileURL(downloadID: request.id, segmentID: seg.id)
                                if FileManager.default.fileExists(atPath: part.path) {
                                    do {
                                        try FileManager.default.removeItem(at: part)
                                    } catch {
                                        PipelineLogger.shared.log("[DownloadCoordinator] Warning: Failed to remove part file \(part.path): \(error.localizedDescription)")
                                    }
                                }
                            }
                        }
                        record = nil
                    case .unsupportedNonResumable:
                        if isResumeRequest {
                            throw DownloadCoordinatorError.cannotResume(
                                reason: "Resume unavailable: This server doesn't support reliable download resumption. Restarting the download may be required."
                            )
                        }
                        // Resiliency rule: restart from 0 instead of failing with cannotResume
                        PipelineLogger.shared.log("[DownloadCoordinator] Server non-resumable on resume for \(request.id); restarting download cleanly from byte 0.")
                        isResume = false
                        if FileManager.default.fileExists(atPath: request.destinationURL.path) {
                            do {
                                try FileManager.default.removeItem(at: request.destinationURL)
                            } catch {
                                PipelineLogger.shared.log("[DownloadCoordinator] Warning: Failed to remove destination on non-resumable restart: \(error.localizedDescription)")
                            }
                        }
                        record = nil
                    }
                }
            } else {
                isResume = false
                record = nil
            }

            // Step 3: Disk-space preflight & preallocation check on target destination volume
            if let totalSize = probeResult.totalSize, totalSize > 0 {
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
                to: probeResult.finalURL,
                allowedOrigins: request.allowedCredentialOrigins
            )

            if request.transportPolicy == .background {
                if probeResult.supportsRange, let totalSize = probeResult.totalSize, totalSize > 0 {
                    try await runMultiSegmentBackgroundDownload(
                        request: executionRequest,
                        probeResult: probeResult,
                        existingRecord: isResume ? record : nil,
                        earliestBeginDate: backgroundEarliestBeginDate,
                        progress: handler
                    )
                } else {
                    // Ranged background download unsupported (server ignores range or indeterminate length)
                    // Fall back cleanly to foreground single-stream transport as per Milestone 6B Requirement 4.
                    // The foreground fallback must still honor a queued schedule.
                    PipelineLogger.shared.log("[DownloadCoordinator] Server does not support byte ranges for \(BrowserURLResolver.sanitizeURLForLogging(request.url)); falling back to foreground single-stream transport.")
                    try await runSingleStreamDownload(
                        request: executionRequest,
                        probeResult: probeResult,
                        progress: handler,
                        earliestBeginDate: backgroundEarliestBeginDate
                    )
                }
            } else {
                if probeResult.supportsRange, let totalSize = probeResult.totalSize, totalSize > 0 {
                    do {
                        try await runMultiSegmentDownload(
                            request: executionRequest,
                            probeResult: probeResult,
                            existingRecord: isResume ? record : nil,
                            progress: handler,
                            earliestBeginDate: backgroundEarliestBeginDate
                        )
                    } catch {
                        if Self.isRangeIgnored(error) {
                            if isResumeRequest {
                                throw DownloadCoordinatorError.cannotResume(
                                    reason: "Resume unavailable: This server doesn't support reliable download resumption. Restarting the download may be required."
                                )
                            }
                            if isResume {
                                PipelineLogger.shared.log("[DownloadCoordinator] Server ignored byte range on resume for \(request.id); restarting download cleanly from byte 0.")
                                if FileManager.default.fileExists(atPath: executionRequest.destinationURL.path) {
                                    do {
                                        try FileManager.default.removeItem(at: executionRequest.destinationURL)
                                    } catch {
                                        PipelineLogger.shared.log("[DownloadCoordinator] Warning: Failed to remove destination on restart: \(error.localizedDescription)")
                                    }
                                }
                            }
                            // Safe fallback for fresh or restarted downloads: Server returned 200 after ranged request
                            try await runSingleStreamFallback(
                                request: executionRequest,
                                probeResult: probeResult,
                                progress: handler,
                                earliestBeginDate: backgroundEarliestBeginDate
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
                        progress: handler,
                        earliestBeginDate: backgroundEarliestBeginDate
                    )
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            do {
                _ = try await persistenceStore.updateState(tag: request.id, state: .failed(reason: error.localizedDescription))
            } catch let stateErr {
                PipelineLogger.shared.log("[DownloadCoordinator] Failed updating persistence state to .failed for \(request.id): \(stateErr.localizedDescription)")
            }
            let currentRecord: DownloadRecord?
            do {
                currentRecord = try await persistenceStore.fetch(tag: request.id)
            } catch {
                PipelineLogger.shared.log("[DownloadCoordinator] Failed fetching record for \(request.id) on error: \(error.localizedDescription)")
                currentRecord = nil
            }
            if let current = currentRecord {
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
            customHeaders: request.headers,
            allowedCredentialOrigins: request.allowedCredentialOrigins
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
            to: probeResult.finalURL,
            allowedOrigins: request.allowedCredentialOrigins
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
            headers: safeHeaders,
            allowedOrigins: request.allowedCredentialOrigins
        )
        let temporaryURL = request.destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(".range-\(request.id)-\(UUID().uuidString).tmp")
        defer {
            if FileManager.default.fileExists(atPath: temporaryURL.path) {
                do {
                    try FileManager.default.removeItem(at: temporaryURL)
                } catch {
                    PipelineLogger.shared.log("[DownloadCoordinator] Warning: Failed to clean up temporaryURL \(temporaryURL.path): \(error.localizedDescription)")
                }
            }
        }

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

            let parentDir = request.destinationURL.deletingLastPathComponent()
            do {
                try DownloadManagerViewModel.ensureDirectoryExistsAndWritable(parentDir)
            } catch {
                let nsErr = error as NSError
                PipelineLogger.shared.log("[DownloadCoordinator] Operation: createDirectory, Path: \(parentDir.path), Domain: \(nsErr.domain), Code: \(nsErr.code), Description: \(nsErr.localizedDescription), UserInfo: \(nsErr.userInfo)")
                throw error
            }
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
            do {
                _ = try await persistenceStore.updateState(tag: request.id, state: .failed(reason: error.localizedDescription))
            } catch let stateErr {
                PipelineLogger.shared.log("[DownloadCoordinator] Failed updating persistence state to .failed for \(request.id): \(stateErr.localizedDescription)")
            }
            throw error
        }
    }

    /// Executes one standalone streaming media segment atomically (e.g. standard HLS .ts files).
    /// Used by DownloadCoordinatorSegmentExecutor to reliably download individual video/audio chunks
    /// without entering the multi-segment range-worker pipeline.
    /// Streams directly to disk to prevent unbounded memory buffering of video segments.
    private func executeStandaloneStreamingSegment(
        request: DownloadRequest,
        progress handler: ProgressHandler?
    ) async throws {
        let persistedHeaders = headersForPersistence(request)
        var initialRecord = DownloadRecord(
            id: request.id,
            originalURL: request.url,
            resolvedURL: request.url,
            destinationURL: request.destinationURL,
            totalSize: 0,
            state: .downloading,
            storageMode: .directSeek,
            headers: persistedHeaders,
            segments: [SegmentRecord(segment: DownloadSegment(
                id: 0,
                startOffset: 0,
                endOffset: 0,
                length: 0
            ))],
            isInternalStreamingSegment: true
        )
        try await persistenceStore.save(initialRecord)

        let maxAttempts = max(1, request.retryCount + 1)
        var attempt = 0
        var acquiredPermit = false

        while true {
            try Task.checkCancellation()
            do {
                updateProgress(
                    downloadID: request.id,
                    state: .probing,
                    bytesReceived: 0,
                    totalBytes: nil,
                    completedSegments: 0,
                    totalSegments: 1,
                    handler: handler
                )

                let probe = HTTPRangeProbe(session: session)
                let probeResult: HTTPRangeProbeResult
                do {
                    probeResult = try await probe.probe(configuration: HTTPRangeProbeConfiguration(
                        url: request.url,
                        customHeaders: request.headers,
                        networkPolicy: request.networkPolicy,
                        allowedCredentialOrigins: request.allowedCredentialOrigins
                    ))
                } catch let probeError as HTTPRangeProbeError {
                    switch probeError {
                    case .unauthorized(let u):
                        throw DownloadCoordinatorError.tokenExpired(url: u)
                    case .forbidden(let u):
                        let cooldown = Date().addingTimeInterval(300)
                        throw DownloadCoordinatorError.accessDenied(url: u, cooldownUntil: cooldown)
                    case .resourceNotFound(let u):
                        throw DownloadCoordinatorError.linkExpired(url: u)
                    case .rateLimited(let u, let sec):
                        throw DownloadCoordinatorError.rateLimited(url: u, retryAfter: sec)
                    default:
                        throw probeError
                    }
                }

                let totalSize = probeResult.totalSize ?? 0
                if totalSize > 0 {
                    initialRecord.totalSize = totalSize
                    initialRecord.segments[0].endOffset = totalSize - 1
                    initialRecord.segments[0].length = totalSize
                    do {
                        try await persistenceStore.save(initialRecord)
                    } catch {
                        PipelineLogger.shared.log("[DownloadCoordinator] Warning: Failed to persist segment checkpoint after probe for \(request.id): \(error.localizedDescription)")
                    }
                }

                var segmentRequest = URLRequest(url: probeResult.finalURL)
                segmentRequest.httpMethod = "GET"
                segmentRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                let safeHeaders = BrowserHeaderFilter.stripCredentialsOnRedirect(
                    headers: request.headers,
                    from: request.url,
                    to: probeResult.finalURL,
                    allowedOrigins: request.allowedCredentialOrigins
                )
                for (name, value) in BrowserHeaderFilter.sanitizeHeaders(safeHeaders) {
                    if name.caseInsensitiveCompare("Accept-Encoding") != .orderedSame &&
                       name.caseInsensitiveCompare("Range") != .orderedSame {
                        segmentRequest.setValue(value, forHTTPHeaderField: name)
                    }
                }
                segmentRequest = DownloadRequestEnricher.enrich(segmentRequest)

                let redirectDelegate = DownloadResourceRedirectDelegate(
                    originalURL: request.url,
                    headers: safeHeaders,
                    allowedOrigins: request.allowedCredentialOrigins
                )

                try await requestBudget.acquire(
                    downloadID: request.id,
                    maxPerDownload: request.maxConcurrentRequests,
                    host: request.url.host
                )
                acquiredPermit = true

                updateProgress(
                    downloadID: request.id,
                    state: .downloading,
                    bytesReceived: 0,
                    totalBytes: totalSize > 0 ? totalSize : nil,
                    completedSegments: 0,
                    totalSegments: 1,
                    handler: handler
                )

                // Stream directly to disk using URLSession.download(for:delegate:) instead of loading into RAM
                let (tempDownloadedURL, response) = try await session.download(for: segmentRequest, delegate: redirectDelegate)
                defer {
                    if FileManager.default.fileExists(atPath: tempDownloadedURL.path) {
                        do {
                            try FileManager.default.removeItem(at: tempDownloadedURL)
                        } catch {
                            PipelineLogger.shared.log("[DownloadCoordinator] Warning: Failed cleaning up tempDownloadedURL \(tempDownloadedURL.path): \(error.localizedDescription)")
                        }
                    }
                }
                try Task.checkCancellation()

                if acquiredPermit {
                    await requestBudget.release(downloadID: request.id, host: request.url.host)
                    acquiredPermit = false
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw DownloadCoordinatorError.unexpectedSingleStreamError(reason: "Segment resource did not return an HTTP response")
                }
                if httpResponse.statusCode == 401 {
                    throw DownloadCoordinatorError.tokenExpired(url: request.url)
                }
                if httpResponse.statusCode == 403 {
                    let cooldown = Date().addingTimeInterval(300)
                    throw DownloadCoordinatorError.accessDenied(url: request.url, cooldownUntil: cooldown)
                }
                if httpResponse.statusCode == 404 || httpResponse.statusCode == 410 {
                    throw DownloadCoordinatorError.linkExpired(url: request.url)
                }
                if httpResponse.statusCode == 429 {
                    let retryAfter = HTTPRangeProbe.parseRetryAfter(httpResponse.value(forHTTPHeaderField: "Retry-After"))
                    throw DownloadCoordinatorError.rateLimited(url: request.url, retryAfter: retryAfter)
                }
                guard (200...299).contains(httpResponse.statusCode) else {
                    throw DownloadCoordinatorError.unexpectedSingleStreamError(
                        reason: "Segment resource returned HTTP \(httpResponse.statusCode)"
                    )
                }

                let attrs = try FileManager.default.attributesOfItem(atPath: tempDownloadedURL.path)
                let receivedBytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                guard receivedBytes > 0 else {
                    throw DownloadCoordinatorError.unexpectedSingleStreamError(reason: "Segment resource returned 0 bytes")
                }
                if totalSize > 0 && receivedBytes != totalSize {
                    throw SegmentDownloaderError.bodyLengthMismatch(expected: totalSize, actual: receivedBytes)
                }

                let parentDir = request.destinationURL.deletingLastPathComponent()
                do {
                    try DownloadManagerViewModel.ensureDirectoryExistsAndWritable(parentDir)
                } catch {
                    let nsErr = error as NSError
                    PipelineLogger.shared.log("[DownloadCoordinator] Operation: createDirectory, Path: \(parentDir.path), Domain: \(nsErr.domain), Code: \(nsErr.code), Description: \(nsErr.localizedDescription), UserInfo: \(nsErr.userInfo)")
                    throw error
                }

                // Safe atomic publication: Stage inside destination directory, then atomically replace without deleting target first
                let stagingURL = parentDir.appendingPathComponent(".stage-\(request.id)-\(UUID().uuidString).tmp")
                try FileManager.default.moveItem(at: tempDownloadedURL, to: stagingURL)
                defer {
                    if FileManager.default.fileExists(atPath: stagingURL.path) {
                        do {
                            try FileManager.default.removeItem(at: stagingURL)
                        } catch {
                            PipelineLogger.shared.log("[DownloadCoordinator] Warning: Failed cleaning up stagingURL \(stagingURL.path): \(error.localizedDescription)")
                        }
                    }
                }

                #if canImport(Darwin)
                if FileManager.default.fileExists(atPath: request.destinationURL.path) {
                    do {
                        _ = try FileManager.default.replaceItemAt(request.destinationURL, withItemAt: stagingURL, backupItemName: nil, options: [])
                    } catch {
                        do {
                            try FileManager.default.removeItem(at: request.destinationURL)
                        } catch {
                            PipelineLogger.shared.log("[DownloadCoordinator] Warning: Failed removing destination before move: \(error.localizedDescription)")
                        }
                        try FileManager.default.moveItem(at: stagingURL, to: request.destinationURL)
                    }
                } else {
                    try FileManager.default.moveItem(at: stagingURL, to: request.destinationURL)
                }
                #else
                if FileManager.default.fileExists(atPath: request.destinationURL.path) {
                    do {
                        try FileManager.default.removeItem(at: request.destinationURL)
                    } catch {
                        PipelineLogger.shared.log("[DownloadCoordinator] Warning: Failed removing destination before move: \(error.localizedDescription)")
                    }
                }
                try FileManager.default.moveItem(at: stagingURL, to: request.destinationURL)
                #endif

                var completedRecord = initialRecord
                completedRecord.totalSize = receivedBytes
                completedRecord.segments[0].completedBytes = receivedBytes
                completedRecord.segments[0].length = receivedBytes
                completedRecord.segments[0].endOffset = max(0, receivedBytes - 1)
                completedRecord.transition(to: .completed)
                try await persistenceStore.save(completedRecord)

                updateProgress(
                    downloadID: request.id,
                    state: .completed,
                    bytesReceived: receivedBytes,
                    totalBytes: receivedBytes,
                    completedSegments: 1,
                    totalSegments: 1,
                    handler: handler
                )
                return
            } catch is CancellationError {
                if acquiredPermit {
                    await requestBudget.release(downloadID: request.id, host: request.url.host)
                    acquiredPermit = false
                }
                do {
                    try await persistenceStore.updateState(tag: request.id, state: .cancelled)
                } catch {
                    PipelineLogger.shared.log("[DownloadCoordinator] Failed to update persistence state to .cancelled for \(request.id): \(error.localizedDescription)")
                }
                throw CancellationError()
            } catch {
                if acquiredPermit {
                    await requestBudget.release(downloadID: request.id, host: request.url.host)
                    acquiredPermit = false
                }
                attempt += 1
                if attempt < maxAttempts && HTTPRetryPolicy.isRetryable(error) {
                    PipelineLogger.shared.log("[DownloadCoordinator] Segment \(request.id) encountered retryable error (\(error.localizedDescription)). Retrying attempt \(attempt + 1)/\(maxAttempts)...")
                    if HTTPRetryPolicy.shouldWaitForConnectivity(error) && !Self.isLoopbackURL(request.url) {
                        try? await connectivityGate.waitUntilAvailable(
                            networkPolicy: request.networkPolicy
                        )
                    }
                    let delaySeconds: Double
                    if case DownloadCoordinatorError.rateLimited(_, let retryAfter) = error, let sec = retryAfter {
                        delaySeconds = min(60.0, max(1.0, sec))
                    } else {
                        delaySeconds = min(2.0, Double(attempt) * 0.5)
                    }
                    try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                    continue
                }
                do {
                    try await persistenceStore.updateState(tag: request.id, state: .failed(reason: error.localizedDescription))
                } catch {
                    PipelineLogger.shared.log("[DownloadCoordinator] Failed to update persistence state to .failed for \(request.id): \(error.localizedDescription)")
                }
                throw error
            }
        }
    }

}
