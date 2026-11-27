import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A manifest candidate handed off by browser discovery. The candidate is still
/// untrusted input and is validated again before any request is made.
public struct StreamingManifestCandidate: Sendable, Equatable {
    public let url: URL
    public let mimeType: String?
    public let browserRequestContext: BrowserRequestContext?
    public let browserSessionSnapshot: BrowserSessionSnapshot?
    public let hlsVariantPreferences: HLSVariantSelectionPreferences
    public let cachedManifestText: String?
    public let dashVideoRepresentationID: String?
    public let dashAudioRepresentationID: String?
    public let dashTextRepresentationID: String?
    public var transportPolicy: HTTPTransportPolicy

    public init(
        url: URL,
        mimeType: String? = nil,
        browserRequestContext: BrowserRequestContext? = nil,
        browserSessionSnapshot: BrowserSessionSnapshot? = nil,
        hlsVariantPreferences: HLSVariantSelectionPreferences = HLSVariantSelectionPreferences(),
        cachedManifestText: String? = nil,
        dashVideoRepresentationID: String? = nil,
        dashAudioRepresentationID: String? = nil,
        dashTextRepresentationID: String? = nil,
        transportPolicy: HTTPTransportPolicy = .background
    ) throws {
        guard BrowserURLResolver.isValidDownloadURL(url) else {
            throw StreamingDownloadOrchestratorError.invalidManifestURL
        }
        self.url = url
        self.mimeType = mimeType
        self.transportPolicy = transportPolicy
        let snapshot = browserSessionSnapshot
        self.browserSessionSnapshot = snapshot
        if let browserRequestContext {
            self.browserRequestContext = browserRequestContext
        } else if let snapshot, snapshot.pageURL != nil {
            let cookies = snapshot.allCookies.compactMap { BrowserCookie(from: $0) }
            self.browserRequestContext = BrowserRequestContext(
                url: url,
                pageURL: snapshot.pageURL,
                userAgent: snapshot.userAgent.isEmpty ? nil : snapshot.userAgent,
                cookies: cookies,
                source: .webpageResource
            )
        } else {
            self.browserRequestContext = nil
        }
        self.hlsVariantPreferences = hlsVariantPreferences
        self.cachedManifestText = cachedManifestText
        self.dashVideoRepresentationID = dashVideoRepresentationID
        self.dashAudioRepresentationID = dashAudioRepresentationID
        self.dashTextRepresentationID = dashTextRepresentationID
    }

    /// Returns a copy of this candidate with an updated `browserRequestContext` and optional snapshot.
    public func updatingContext(
        browserRequestContext: BrowserRequestContext?,
        browserSessionSnapshot: BrowserSessionSnapshot? = nil
    ) -> StreamingManifestCandidate {
        try! StreamingManifestCandidate(
            url: url,
            mimeType: mimeType,
            browserRequestContext: browserRequestContext,
            browserSessionSnapshot: browserSessionSnapshot ?? self.browserSessionSnapshot,
            hlsVariantPreferences: hlsVariantPreferences,
            cachedManifestText: cachedManifestText,
            dashVideoRepresentationID: dashVideoRepresentationID,
            dashAudioRepresentationID: dashAudioRepresentationID,
            dashTextRepresentationID: dashTextRepresentationID,
            transportPolicy: transportPolicy
        )
    }

    /// Returns a copy of this candidate with cookies refreshed from the latest active session snapshot
    /// or explicit fresh cookies, enabling later playlist and segment requests to receive fresh session tokens.
    public func withRefreshedCookies(
        snapshot: BrowserSessionSnapshot? = nil,
        freshCookies: [BrowserCookie] = []
    ) -> StreamingManifestCandidate {
        let effectiveSnapshot = snapshot ?? browserSessionSnapshot ?? DownloadRequestEnricher.sharedSessionSnapshot.snapshot
        var updatedContext = browserRequestContext
        if let effectiveSnapshot {
            if let ctx = updatedContext {
                updatedContext = ctx.updatingCookies(from: effectiveSnapshot)
            } else if let pageURL = effectiveSnapshot.pageURL {
                let cookies = effectiveSnapshot.allCookies.compactMap { BrowserCookie(from: $0) }
                updatedContext = BrowserRequestContext(
                    url: url,
                    pageURL: pageURL,
                    userAgent: effectiveSnapshot.userAgent.isEmpty ? nil : effectiveSnapshot.userAgent,
                    cookies: cookies,
                    source: .webpageResource
                )
            }
        }
        if !freshCookies.isEmpty {
            if let ctx = updatedContext {
                updatedContext = ctx.updatingCookies(with: freshCookies)
            } else {
                updatedContext = BrowserRequestContext(
                    url: url,
                    pageURL: effectiveSnapshot?.pageURL,
                    userAgent: effectiveSnapshot?.userAgent.isEmpty == false ? effectiveSnapshot?.userAgent : nil,
                    cookies: freshCookies,
                    source: .webpageResource
                )
            }
        }
        return updatingContext(
            browserRequestContext: updatedContext,
            browserSessionSnapshot: effectiveSnapshot
        )
    }

    public init(
        resource: WebpageResource,
        browserSessionSnapshot: BrowserSessionSnapshot? = nil,
        transportPolicy: HTTPTransportPolicy = .background
    ) throws {
        try self.init(
            url: resource.url,
            mimeType: resource.mimeType,
            browserRequestContext: resource.requestContext,
            browserSessionSnapshot: browserSessionSnapshot,
            hlsVariantPreferences: resource.hlsVariantPreferences ?? HLSVariantSelectionPreferences(),
            cachedManifestText: resource.manifestText,
            dashVideoRepresentationID: resource.dashVideoRepresentationID,
            dashAudioRepresentationID: resource.dashAudioRepresentationID,
            dashTextRepresentationID: resource.dashTextRepresentationID,
            transportPolicy: transportPolicy
        )
    }
}

public struct StreamingManifestResponse: Sendable {
    public let data: Data
    public let finalURL: URL
    public let mimeType: String?
    public let statusCode: Int
    public let redirectResolvedContext: BrowserRequestContext?

    public init(
        data: Data,
        finalURL: URL,
        mimeType: String? = nil,
        statusCode: Int = 200,
        redirectResolvedContext: BrowserRequestContext? = nil
    ) {
        self.data = data
        self.finalURL = finalURL
        self.mimeType = mimeType
        self.statusCode = statusCode
        self.redirectResolvedContext = redirectResolvedContext
    }
}

public protocol StreamingManifestLoader: Sendable {
    func load(
        candidate: StreamingManifestCandidate,
        headers: [String: String],
        limits: ManifestParsingLimits
    ) async throws -> StreamingManifestResponse
}

/// Resolves raw segment or manifest media URLs via client/browser context when required.
public protocol BrowserMediaURLResolver: Sendable {
    @MainActor func resolveMediaURL(_ rawURL: URL) async throws -> URL
    @MainActor func fetchManifestText(from url: URL) async throws -> String
    @MainActor func fetchManifestText(from url: URL, maxBytes: Int) async throws -> String
}

extension BrowserMediaURLResolver {
    @MainActor
    public func fetchManifestText(from url: URL) async throws -> String {
        throw StreamingManifestLoadError.browserFetchUnavailable
    }

    @MainActor
    public func fetchManifestText(from url: URL, maxBytes: Int) async throws -> String {
        try await fetchManifestText(from: url)
    }
}

/// URLSession-backed manifest loader. Redirects are followed only after applying
/// the existing cross-origin credential stripping policy.
public final class URLSessionStreamingManifestLoader: StreamingManifestLoader, Sendable {
    public static let sharedSession: URLSession = ForegroundURLSession.make()
    let session: URLSession

    public init(session: URLSession = URLSessionStreamingManifestLoader.sharedSession) {
        self.session = session
    }

    public func load(
        candidate: StreamingManifestCandidate,
        headers: [String: String],
        limits: ManifestParsingLimits
    ) async throws -> StreamingManifestResponse {
        let refreshedCandidate = candidate.withRefreshedCookies()
        var request = URLRequest(url: refreshedCandidate.url)
        request.httpMethod = "GET"
        request.timeoutInterval = 45
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        for (name, value) in BrowserHeaderFilter.sanitizeHeaders(headers) {
            if name.caseInsensitiveCompare("Accept-Encoding") != .orderedSame {
                request.setValue(value, forHTTPHeaderField: name)
            }
        }
        let effectiveSnapshot: BrowserSessionSnapshot?
        if let s = refreshedCandidate.browserSessionSnapshot {
            effectiveSnapshot = s
        } else if let s = DownloadRequestEnricher.sharedSessionSnapshot.snapshot {
            effectiveSnapshot = s
        } else if let ctx = refreshedCandidate.browserRequestContext {
            let httpCookies = ctx.cookies.compactMap { $0.toHTTPCookie() }
            effectiveSnapshot = BrowserSessionSnapshot(
                userAgent: ctx.userAgent ?? "",
                acceptLanguage: Locale.preferredLanguages.first ?? "en-US",
                allCookies: httpCookies,
                pageURL: ctx.pageURL
            )
        } else {
            effectiveSnapshot = nil
        }
        let urlString = refreshedCandidate.url.absoluteString.lowercased()
        let pathExt = refreshedCandidate.url.pathExtension.lowercased()
        let mime = refreshedCandidate.mimeType?.lowercased() ?? ""

        if pathExt == "mpd" || urlString.contains(".mpd") || mime.contains("dash") {
            request.setValue("application/dash+xml, application/xml, text/xml, */*", forHTTPHeaderField: "Accept")
        } else if pathExt == "m3u8" || urlString.contains(".m3u8") || mime.contains("mpegurl") {
            request.setValue("application/vnd.apple.mpegurl, application/x-mpegURL, */*", forHTTPHeaderField: "Accept")
        }

        request = await DownloadRequestEnricher.enrichAsync(request, snapshot: effectiveSnapshot, context: refreshedCandidate.browserRequestContext)

        // Ensure Accept header is specifically preserved if target was an MPD or M3U8 manifest
        if pathExt == "mpd" || urlString.contains(".mpd") || mime.contains("dash") {
            request.setValue("application/dash+xml, application/xml, text/xml, */*", forHTTPHeaderField: "Accept")
        } else if pathExt == "m3u8" || urlString.contains(".m3u8") || mime.contains("mpegurl") {
            request.setValue("application/vnd.apple.mpegurl, application/x-mpegURL, */*", forHTTPHeaderField: "Accept")
        }

        // Ensure User-Agent and Referer are populated from browserRequestContext if still missing
        if request.value(forHTTPHeaderField: "User-Agent") == nil,
           let ua = refreshedCandidate.browserRequestContext?.userAgent, !ua.isEmpty {
            request.setValue(ua, forHTTPHeaderField: "User-Agent")
        }
        if request.value(forHTTPHeaderField: "Referer") == nil {
            if let ref = refreshedCandidate.browserRequestContext?.referer ?? refreshedCandidate.browserRequestContext?.pageURL?.absoluteString {
                let isDowngrade = refreshedCandidate.url.scheme?.lowercased() == "http" && (URL(string: ref)?.scheme?.lowercased() == "https")
                if !isDowngrade {
                    request.setValue(ref, forHTTPHeaderField: "Referer")
                }
            }
        }

        let delegate = StreamingRedirectDelegate(
            originalURL: refreshedCandidate.url,
            headers: headers,
            snapshot: effectiveSnapshot,
            context: refreshedCandidate.browserRequestContext
        )
        let (data, response) = try await session.data(for: request, delegate: delegate)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw StreamingManifestLoadError.invalidResponse
        }

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw StreamingManifestLoadError.authenticationRequired
        }
        if httpResponse.statusCode == 404 || httpResponse.statusCode == 410 {
            throw StreamingManifestLoadError.expiredOrMissing
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw StreamingManifestLoadError.unexpectedStatus(httpResponse.statusCode)
        }
        if let contentLength = httpResponse.value(forHTTPHeaderField: "Content-Length"),
           let length = Int(contentLength), length > limits.maxBytes {
            throw ManifestParserError.inputTooLarge(limit: limits.maxBytes)
        }
        guard data.count <= limits.maxBytes else {
            throw ManifestParserError.inputTooLarge(limit: limits.maxBytes)
        }

        let finalURL = response.url ?? candidate.url
        guard BrowserURLResolver.isValidDownloadURL(finalURL) else {
            throw StreamingManifestLoadError.invalidRedirect
        }
        let mimeType = httpResponse.value(forHTTPHeaderField: "Content-Type")?
            .split(separator: ";", maxSplits: 1)
            .first
            .map(String.init)
        let redirectContext = candidate.browserRequestContext?.redirectResolved(to: finalURL)
        return StreamingManifestResponse(
            data: data,
            finalURL: finalURL,
            mimeType: mimeType,
            statusCode: httpResponse.statusCode,
            redirectResolvedContext: redirectContext
        )
    }
}

public enum StreamingManifestLoadError: Error, LocalizedError, Sendable, Equatable {
    case invalidResponse
    case authenticationRequired
    case expiredOrMissing
    case unexpectedStatus(Int)
    case invalidRedirect
    case browserFetchUnavailable
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The manifest request did not return an HTTP response."
        case .authenticationRequired:
            return "The manifest requires authentication or the browser session has expired."
        case .expiredOrMissing:
            return "The manifest is missing or its signed URL has expired."
        case .unexpectedStatus(let status):
            return "The manifest request failed with HTTP status \(status)."
        case .invalidRedirect:
            return "The manifest redirect resolved to an unsupported URL."
        case .browserFetchUnavailable:
            return "Browser JavaScript manifest fetch is unavailable."
        case .failed(let message):
            return message
        }
    }
}

public enum StreamingTransferManifest: Sendable, Equatable {
    case hls(HLSVODTransferPlan)
    case dash(DASHVODTransferPlan)

    public var kind: StreamingManifestKind {
        switch self {
        case .hls: return .hls
        case .dash: return .dash
        }
    }

    public var manifestURL: URL {
        switch self {
        case .hls(let plan): return plan.manifestURL
        case .dash(let plan): return plan.manifestURL
        }
    }
}

public struct StreamingByteRange: Sendable, Equatable, Hashable, Codable {
    public let start: Int64
    public let end: Int64

    public init(start: Int64, end: Int64) throws {
        guard start >= 0, end >= start else {
            throw StreamingDownloadOrchestratorError.invalidByteRange
        }
        self.start = start
        self.end = end
    }

    public var length: Int64 { end - start + 1 }
    public var headerValue: String { "bytes=\(start)-\(end)" }
}

/// A secret-free, stable identity for one resource in a streaming transfer.
/// The coordinator persists the same value as its per-resource request ID.
public struct StreamingSegmentIdentity: Sendable, Equatable, Hashable, Codable {
    public let transferID: String
    public let order: Int
    public let value: String

    public init(transferID: String, order: Int, value: String) {
        self.transferID = transferID
        self.order = order
        self.value = value
    }
}

public struct StreamingTransferResource: Sendable, Equatable {
    public let identity: StreamingSegmentIdentity
    public let url: URL
    public let byteRange: StreamingByteRange?

    public init(identity: StreamingSegmentIdentity, url: URL, byteRange: StreamingByteRange? = nil) {
        self.identity = identity
        self.url = url
        self.byteRange = byteRange
    }
}

public struct StreamingTransferProposal: Sendable, Equatable {
    public let transferID: String
    public let manifestID: String
    public let manifest: StreamingTransferManifest
    public let resources: [StreamingTransferResource]
    public let estimatedTransferBytes: Int64?
    public var transportPolicy: HTTPTransportPolicy
    public var estimatedTotalBytes: Int64? { estimatedTransferBytes }

    public var browserRequestContext: BrowserRequestContext? {
        switch manifest {
        case .hls(let plan):
            return plan.browserRequestContext
        case .dash(let plan):
            return plan.browserRequestContext
        }
    }

    public init(
        transferID: String,
        manifestID: String,
        manifest: StreamingTransferManifest,
        resources: [StreamingTransferResource],
        estimatedTransferBytes: Int64?,
        transportPolicy: HTTPTransportPolicy = .foreground
    ) {
        self.transferID = transferID
        self.manifestID = manifestID
        self.manifest = manifest
        self.resources = resources
        self.estimatedTransferBytes = estimatedTransferBytes
        self.transportPolicy = transportPolicy
    }
}

public struct StreamingSegmentTransferRequest: Sendable, Equatable {
    public let identity: StreamingSegmentIdentity
    public let url: URL
    public let headers: [String: String]
    public let byteRange: StreamingByteRange?
    public let destinationURL: URL
    public let allowedCredentialOrigins: Set<String>
    public let transportPolicy: HTTPTransportPolicy

    public init(
        identity: StreamingSegmentIdentity,
        url: URL,
        headers: [String: String],
        byteRange: StreamingByteRange?,
        destinationURL: URL,
        allowedCredentialOrigins: Set<String> = [],
        transportPolicy: HTTPTransportPolicy = .foreground
    ) {
        self.identity = identity
        self.url = url
        self.headers = headers
        self.byteRange = byteRange
        self.destinationURL = destinationURL
        self.allowedCredentialOrigins = allowedCredentialOrigins
        self.transportPolicy = transportPolicy
    }
}

public struct StreamingTransferProgress: Sendable, Equatable {
    public let transferID: String
    public let completedSegments: Int
    public let totalSegments: Int
    public let currentOrder: Int
    public let currentFraction: Double

    public init(
        transferID: String,
        completedSegments: Int,
        totalSegments: Int,
        currentOrder: Int,
        currentFraction: Double
    ) {
        self.transferID = transferID
        self.completedSegments = completedSegments
        self.totalSegments = totalSegments
        self.currentOrder = currentOrder
        self.currentFraction = currentFraction
    }
}

public protocol StreamingSegmentExecutor: Sendable {
    func execute(
        _ request: StreamingSegmentTransferRequest,
        progress: (@Sendable (Double) -> Void)?
    ) async throws

    func cancel(transferID: String) async
}

/// Adapter that submits every planned resource to the existing coordinator.
/// Browser credentials are runtime-only and are explicitly excluded from durable
/// coordinator records.
public actor DownloadCoordinatorSegmentExecutor: StreamingSegmentExecutor {
    let coordinator: DownloadCoordinator
    let retryCount: Int
    var activeRequestIDs: [String: Set<String>] = [:]
    let backgroundExecutor: BackgroundStreamingSegmentExecutor?

    public init(
        coordinator: DownloadCoordinator,
        retryCount: Int = 2,
        backgroundSessionManager: BackgroundDownloadSessionManager? = nil
    ) {
        self.coordinator = coordinator
        self.retryCount = max(0, retryCount)
        if let bgManager = backgroundSessionManager {
            self.backgroundExecutor = BackgroundStreamingSegmentExecutor(
                backgroundSessionManager: bgManager,
                retryCount: retryCount
            )
        } else {
            self.backgroundExecutor = nil
        }
    }

    func registerActiveRequest(transferID: String, requestID: String) {
        activeRequestIDs[transferID, default: []].insert(requestID)
    }

    func unregisterActiveRequest(transferID: String, requestID: String) {
        activeRequestIDs[transferID]?.remove(requestID)
        if activeRequestIDs[transferID]?.isEmpty == true {
            activeRequestIDs.removeValue(forKey: transferID)
        }
    }

    func getActiveRequestIDs(for transferID: String) -> Set<String> {
        return activeRequestIDs[transferID] ?? []
    }

    public func execute(
        _ request: StreamingSegmentTransferRequest,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        if request.transportPolicy == .background, let bgExec = self.backgroundExecutor {
            try await bgExec.execute(request, progress: progress)
            return
        }
        PipelineLogger.shared.log("[DownloadCoordinatorSegmentExecutor] Starting segment \(request.identity.order) (\(request.identity.value)) -> \(request.destinationURL.lastPathComponent)")
        let downloadRequest = DownloadRequest(
            id: request.identity.value,
            url: request.url,
            destinationURL: request.destinationURL,
            headers: request.headers,
            persistSensitiveHeaders: false,
            configuredThreadCount: 1,
            advancedMode: false,
            storageMode: .directSeek,
            retryCount: retryCount,
            requestedByteRange: request.byteRange.map {
                DownloadByteRange(start: $0.start, end: $0.end)
            },
            allowedCredentialOrigins: request.allowedCredentialOrigins
        )
        registerActiveRequest(transferID: request.identity.transferID, requestID: request.identity.value)
        defer {
            unregisterActiveRequest(transferID: request.identity.transferID, requestID: request.identity.value)
        }

        var attempts = 0
        let maxAttempts = max(1, retryCount + 1)
        while true {
            attempts += 1
            do {
                try await coordinator.start(downloadRequest) { snapshot in
                    progress?(snapshot.fractionCompleted)
                }
                guard FileManager.default.fileExists(atPath: request.destinationURL.path) else {
                    PipelineLogger.shared.log("[DownloadCoordinatorSegmentExecutor] Missing output file for segment \(request.identity.order) at \(request.destinationURL.path)")
                    throw StreamingDownloadOrchestratorError.segmentTransferFailed(order: request.identity.order)
                }
                let fileSize = FileManager.default.fileSize(atPath: request.destinationURL.path) ?? 0
                guard fileSize > 0 else {
                    PipelineLogger.shared.log("[DownloadCoordinatorSegmentExecutor] Empty output file (0 bytes) for segment \(request.identity.order)")
                    throw StreamingDownloadOrchestratorError.segmentTransferFailed(order: request.identity.order)
                }
                PipelineLogger.shared.log("[DownloadCoordinatorSegmentExecutor] Completed segment \(request.identity.order) (\(fileSize) bytes)")
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if attempts < maxAttempts && HTTPRetryPolicy.isRetryable(error) {
                    PipelineLogger.shared.log("[DownloadCoordinatorSegmentExecutor] Segment \(request.identity.order) encountered retryable error (\(error.localizedDescription)). Retrying attempt \(attempts + 1)/\(maxAttempts)...")
                    let delay = min(2.0, Double(attempts) * 0.5)
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                PipelineLogger.shared.log("[DownloadCoordinatorSegmentExecutor] Failed segment \(request.identity.order): \(error)")
                throw error
            }
        }
    }

    public func cancel(transferID: String) async {
        if let bgExec = self.backgroundExecutor {
            await bgExec.cancel(transferID: transferID)
        }
        let ids = getActiveRequestIDs(for: transferID)
        for id in ids {
            do {
                try await coordinator.cancel(id: id, deleteDestinationFile: false)
            } catch {
                PipelineLogger.shared.log(stage: .coordinator, message: "Failed to cancel segment \(id): \(error)")
            }
        }
        while !(activeRequestIDs[transferID]?.isEmpty ?? true) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

/// Standalone segment executor using Apple's BackgroundDownloadSessionManager for out-of-process background streaming.
public actor BackgroundStreamingSegmentExecutor: StreamingSegmentExecutor {
    let backgroundSessionManager: BackgroundDownloadSessionManager
    let retryCount: Int
    var pendingContinuations: [String: [Int: CheckedContinuation<Void, Error>]] = [:]
    var registeredTransferIDs: Set<String> = []

    public init(backgroundSessionManager: BackgroundDownloadSessionManager, retryCount: Int = 2) {
        self.backgroundSessionManager = backgroundSessionManager
        self.retryCount = max(0, retryCount)
    }

    func ensureObserverRegistered(for transferID: String, progress: (@Sendable (Double) -> Void)? = nil) {
        guard !registeredTransferIDs.contains(transferID) else { return }
        registeredTransferIDs.insert(transferID)
        backgroundSessionManager.addObserver(
            for: transferID,
            onProgress: { [weak self] segID, completed, total in
                if total > 0 {
                    let fraction = min(1.0, max(0.0, Double(completed) / Double(total)))
                    progress?(fraction)
                }
            },
            onCompleted: { [weak self] segID, partURL in
                guard let self else { return }
                Task {
                    await self.completeSegment(transferID: transferID, order: segID)
                }
            },
            onFailed: { [weak self] segID, error in
                guard let self else { return }
                Task {
                    await self.failSegment(transferID: transferID, order: segID, error: error)
                }
            }
        )
    }

    func completeSegment(transferID: String, order: Int) {
        if let cont = pendingContinuations[transferID]?.removeValue(forKey: order) {
            cont.resume(returning: ())
        }
        if pendingContinuations[transferID]?.isEmpty == true {
            pendingContinuations.removeValue(forKey: transferID)
        }
    }

    func failSegment(transferID: String, order: Int, error: Error) {
        if let cont = pendingContinuations[transferID]?.removeValue(forKey: order) {
            cont.resume(throwing: error)
        }
        if pendingContinuations[transferID]?.isEmpty == true {
            pendingContinuations.removeValue(forKey: transferID)
        }
    }

    public func execute(
        _ request: StreamingSegmentTransferRequest,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        // Fast-path: Check if chunk already exists and is non-empty
        if FileManager.default.fileExists(atPath: request.destinationURL.path),
           let fileSize = FileManager.default.fileSize(atPath: request.destinationURL.path),
           fileSize > 0 {
            let matchesByteRange = request.byteRange.map { $0.length == fileSize } ?? true
            if matchesByteRange {
                progress?(1.0)
                return
            }
        }

        let transferID = request.identity.transferID
        let order = request.identity.order

        let parentDir = request.destinationURL.deletingLastPathComponent()
        try DownloadManagerViewModel.ensureDirectoryExistsAndWritable(parentDir)

        ensureObserverRegistered(for: transferID, progress: progress)

        var attempts = 0
        let maxAttempts = max(1, retryCount + 1)
        while true {
            attempts += 1
            do {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        self.pendingContinuations[transferID, default: [:]][order] = continuation
                        Task {
                            do {
                                _ = try await self.backgroundSessionManager.scheduleStreamingSegment(
                                    transferID: transferID,
                                    order: order,
                                    url: request.url,
                                    destinationURL: request.destinationURL,
                                    headers: request.headers,
                                    byteRange: request.byteRange.map { ($0.start, $0.end) }
                                )
                            } catch {
                                await self.failSegment(transferID: transferID, order: order, error: error)
                            }
                        }
                    }
                } onCancel: {
                    Task {
                        await self.failSegment(transferID: transferID, order: order, error: CancellationError())
                    }
                }

                guard FileManager.default.fileExists(atPath: request.destinationURL.path) else {
                    PipelineLogger.shared.log("[BackgroundStreamingSegmentExecutor] Missing output file for segment \(order) at \(request.destinationURL.path)")
                    throw StreamingDownloadOrchestratorError.segmentTransferFailed(order: order)
                }
                let finalSize = FileManager.default.fileSize(atPath: request.destinationURL.path) ?? 0
                guard finalSize > 0 else {
                    PipelineLogger.shared.log("[BackgroundStreamingSegmentExecutor] Empty output file (0 bytes) for segment \(order)")
                    throw StreamingDownloadOrchestratorError.segmentTransferFailed(order: order)
                }
                if let byteRange = request.byteRange, finalSize != byteRange.length {
                    PipelineLogger.shared.log("[BackgroundStreamingSegmentExecutor] Byte range mismatch for segment \(order): expected \(byteRange.length), got \(finalSize)")
                    throw StreamingDownloadOrchestratorError.segmentTransferFailed(order: order)
                }
                progress?(1.0)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if attempts < maxAttempts && HTTPRetryPolicy.isRetryable(error) {
                    PipelineLogger.shared.log("[BackgroundStreamingSegmentExecutor] Segment \(order) encountered retryable error (\(error.localizedDescription)). Retrying attempt \(attempts + 1)/\(maxAttempts)...")
                    let delay = min(2.0, Double(attempts) * 0.5)
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                PipelineLogger.shared.log("[BackgroundStreamingSegmentExecutor] Failed segment \(order): \(error)")
                throw error
            }
        }
    }

    public func cancel(transferID: String) async {
        await backgroundSessionManager.cancelTasks(for: transferID)
        if let continuations = pendingContinuations.removeValue(forKey: transferID) {
            for (_, cont) in continuations {
                cont.resume(throwing: CancellationError())
            }
        }
        registeredTransferIDs.remove(transferID)
        backgroundSessionManager.removeObservers(for: transferID)
    }
}

final class StreamingTaskRegistry {
    let lock = NSLock()
    var tasks: [String: Set<URLSessionDownloadTask>] = [:]

    func register(transferID: String, task: URLSessionDownloadTask) {
        lock.lock()
        defer { lock.unlock() }
        tasks[transferID, default: []].insert(task)
    }

    func unregister(transferID: String, task: URLSessionDownloadTask) {
        lock.lock()
        defer { lock.unlock() }
        tasks[transferID]?.remove(task)
        if tasks[transferID]?.isEmpty == true {
            tasks.removeValue(forKey: transferID)
        }
    }

    func take(transferID: String) -> Set<URLSessionDownloadTask> {
        lock.lock()
        defer { lock.unlock() }
        return tasks.removeValue(forKey: transferID) ?? []
    }

    func hasTasks(transferID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !(tasks[transferID]?.isEmpty ?? true)
    }
}

/// Standalone segment executor using URLSession for environments where DownloadCoordinator is not yet injected.
public actor URLSessionStreamingSegmentExecutor: StreamingSegmentExecutor {
    public static let sharedSession: URLSession = ForegroundURLSession.make()

    let session: URLSession
    let taskRegistry = StreamingTaskRegistry()

    public init(session: URLSession? = nil) {
        self.session = session ?? Self.sharedSession
    }

    public nonisolated func hasActiveTasks(for transferID: String) -> Bool {
        taskRegistry.hasTasks(transferID: transferID)
    }

    public func execute(
        _ request: StreamingSegmentTransferRequest,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        let rangeTuple = request.byteRange.map { ($0.start, $0.end) }
        let urlRequest = HTTPTransportValidator.normalizeRequest(
            url: request.url,
            headers: request.headers,
            byteRange: rangeTuple
        )

        try await HTTPTransportValidator.executeWithRetry(
            maxAttempts: 3,
            isRetryable: { HTTPRetryPolicy.isRetryable($0) },
            onRetry: { error, attempt, maxAttempts in
                PipelineLogger.shared.log("[URLSessionStreamingSegmentExecutor] Segment \(request.identity.order) encountered retryable error (\(error.localizedDescription)). Retrying attempt \(attempt + 1)/\(maxAttempts)...")
            }
        ) {
            let (tempURL, response): (URL, URLResponse) = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let transferID = request.identity.transferID
                    var taskRef: URLSessionDownloadTask?
                    let task = self.session.downloadTask(with: urlRequest) { [weak self] tempURL, response, error in
                        if let taskRef {
                            self?.taskRegistry.unregister(transferID: transferID, task: taskRef)
                        }
                        if let error = error {
                            continuation.resume(throwing: error)
                        } else if let tempURL = tempURL, let response = response {
                            continuation.resume(returning: (tempURL, response))
                        } else {
                            continuation.resume(throwing: URLError(.unknown))
                        }
                    }
                    taskRef = task
                    self.taskRegistry.register(transferID: transferID, task: task)
                    task.resume()
                }
            } onCancel: {
                Task {
                    await self.cancel(transferID: request.identity.transferID)
                }
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                throw StreamingDownloadOrchestratorError.segmentTransferFailed(order: request.identity.order)
            }

            do {
                try HTTPTransportValidator.validateResponseStatus(httpResponse, expectingPartial: request.byteRange != nil)
            } catch {
                throw StreamingDownloadOrchestratorError.segmentTransferFailed(order: request.identity.order)
            }

            let fileManager = FileManager.default
            let headerBytes: Data
            if let handle = try? FileHandle(forReadingFrom: tempURL) {
                headerBytes = (try? handle.read(upToCount: 512)) ?? Data()
                do {
                    try handle.close()
                } catch {
                    PipelineLogger.shared.log("[StreamingDownloadOrchestrator] Failed to close handle: \(error)")
                }
            } else {
                headerBytes = Data()
            }

            if HTTPTransportValidator.isHTMLResponse(contentType: httpResponse.mimeType, bodyPrefix: headerBytes) {
                do {
                    try fileManager.removeItem(at: tempURL)
                } catch {
                    PipelineLogger.shared.log("[StreamingDownloadOrchestrator] Failed to remove HTML tempURL: \(error)")
                }
                throw StreamingDownloadOrchestratorError.segmentTransferFailed(order: request.identity.order)
            }

            let parentDir = request.destinationURL.deletingLastPathComponent()
            try DownloadManagerViewModel.ensureDirectoryExistsAndWritable(parentDir, fileManager: fileManager)

            if fileManager.fileExists(atPath: request.destinationURL.path) {
                #if canImport(Darwin)
                do {
                    _ = try fileManager.replaceItemAt(request.destinationURL, withItemAt: tempURL, backupItemName: nil, options: [])
                } catch {
                    let backupURL = parentDir.appendingPathComponent(".backup-\(UUID().uuidString)-\(request.destinationURL.lastPathComponent)")
                    try fileManager.moveItem(at: request.destinationURL, to: backupURL)
                    do {
                        try fileManager.moveItem(at: tempURL, to: request.destinationURL)
                        do {
                            try fileManager.removeItem(at: backupURL)
                        } catch {
                            PipelineLogger.shared.log("[StreamingDownloadOrchestrator] Failed to remove backupURL \(backupURL.path): \(error)")
                        }
                    } catch {
                        do {
                            try fileManager.moveItem(at: backupURL, to: request.destinationURL)
                        } catch {
                            PipelineLogger.shared.log("[StreamingDownloadOrchestrator] Failed to restore backupURL \(backupURL.path): \(error)")
                        }
                        throw error
                    }
                }
                #else
                let backupURL = parentDir.appendingPathComponent(".backup-\(UUID().uuidString)-\(request.destinationURL.lastPathComponent)")
                try fileManager.moveItem(at: request.destinationURL, to: backupURL)
                do {
                    try fileManager.moveItem(at: tempURL, to: request.destinationURL)
                    do {
                        try fileManager.removeItem(at: backupURL)
                    } catch {
                        PipelineLogger.shared.log("[StreamingDownloadOrchestrator] Failed to remove backupURL \(backupURL.path): \(error)")
                    }
                } catch {
                    do {
                        try fileManager.moveItem(at: backupURL, to: request.destinationURL)
                    } catch {
                        PipelineLogger.shared.log("[StreamingDownloadOrchestrator] Failed to restore backupURL \(backupURL.path): \(error)")
                    }
                    throw error
                }
                #endif
            } else {
                try fileManager.moveItem(at: tempURL, to: request.destinationURL)
            }
        }
        progress?(1.0)
    }

    public func cancel(transferID: String) async {
        let tasks = taskRegistry.take(transferID: transferID)
        for task in tasks {
            task.cancel()
        }
        while taskRegistry.hasTasks(transferID: transferID) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

public enum StreamingDownloadOrchestratorError: Error, LocalizedError, Sendable, Equatable {
    case invalidManifestURL
    case manifestNotRecognized
    case unsupportedManifest(StreamingManifestKind)
    case playlistRequiresVariantSelection
    case hlsVariantSelectionFailed(HLSVariantSelectionError)
    case manifestParseFailed(ManifestParserError)
    case hlsPlanningFailed(HLSVODTransferPlanError)
    case dashPlanningFailed(DASHVODTransferPlanError)
    case unsupportedEncryption
    case invalidByteRange
    case noTransferResources
    case userDeclined
    case transferAlreadyRunning
    case streamingRegistrationFailed(String)
    case persistenceFailed(String)
    case segmentTransferFailed(order: Int)
    case cancelled
    case hlsReconstructionFailed(HLSVODReconstructionError)
    case dashReconstructionFailed(DASHVODReconstructionError)
    case hlsSegmentMetadataUnavailable
    case insufficientDiskSpace(required: Int64, available: Int64)

    public var errorDescription: String? {
        switch self {
        case .invalidManifestURL:
            return "The discovered manifest URL is not a valid HTTP or HTTPS destination."
        case .manifestNotRecognized:
            return "The response is not a recognized HLS or DASH manifest."
        case .unsupportedManifest(let kind):
            return "The discovered manifest is unsupported (\(kind.rawValue))."
        case .playlistRequiresVariantSelection:
            return "The HLS master playlist requires an explicit variant selection."
        case .hlsVariantSelectionFailed(let error):
            return error.localizedDescription
        case .manifestParseFailed(let error):
            return error.localizedDescription
        case .hlsPlanningFailed(let error):
            return error.localizedDescription
        case .dashPlanningFailed(let error):
            return error.localizedDescription
        case .unsupportedEncryption:
            return "The manifest uses encryption or DRM that this transfer path does not implement."
        case .invalidByteRange:
            return "The manifest contains an invalid or ambiguous byte range."
        case .noTransferResources:
            return "The manifest produced no downloadable resources."
        case .userDeclined:
            return "The streaming transfer was not approved."
        case .transferAlreadyRunning:
            return "This streaming transfer is already running."
        case .streamingRegistrationFailed(let message):
            return "The streaming download could not be added to Downloads: \(message)"
        case .persistenceFailed(let message):
            return "The streaming transfer state could not be saved: \(message)"
        case .segmentTransferFailed(let order):
            return "Streaming segment \(order) could not be downloaded."
        case .cancelled:
            return "The streaming transfer was cancelled; completed segments were preserved."
        case .hlsReconstructionFailed(let error):
            return error.localizedDescription
        case .dashReconstructionFailed(let error):
            return error.localizedDescription
        case .hlsSegmentMetadataUnavailable:
            return "The HLS manifest could not be loaded, so the selected segment files could not be identified."
        case .insufficientDiskSpace(let required, let available):
            return "Insufficient disk space for streaming transfer: required \(required) bytes, but only \(available) bytes are available."
        }
    }
}

/// Coordinates browser discovery, manifest loading/parsing, planning, segment
/// submission, and supported VOD assembly handoffs. It does not own application
/// download state.

public struct StreamingTransferResult: Sendable, Equatable {
    public let transferID: String
    public let completedSegments: [StreamingSegmentIdentity]
    public let localFiles: [URL]

    public init(transferID: String, completedSegments: [StreamingSegmentIdentity], localFiles: [URL]) {
        self.transferID = transferID
        self.completedSegments = completedSegments
        self.localFiles = localFiles
    }
}

final class StreamingRedirectDelegate: NSObject, URLSessionTaskDelegate {
    let originalURL: URL?
    let headers: [String: String]?
    let snapshot: BrowserSessionSnapshot?
    let context: BrowserRequestContext?

    init(
        originalURL: URL? = nil,
        headers: [String: String]? = nil,
        snapshot: BrowserSessionSnapshot? = nil,
        context: BrowserRequestContext? = nil
    ) {
        self.originalURL = originalURL
        self.headers = headers
        self.snapshot = snapshot
        self.context = context
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
            newRequest: request,
            snapshot: snapshot,
            context: context
        )
        completionHandler(redirected)
    }
}
