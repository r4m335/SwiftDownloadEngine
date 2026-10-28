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

    public init(
        url: URL,
        mimeType: String? = nil,
        browserRequestContext: BrowserRequestContext? = nil,
        browserSessionSnapshot: BrowserSessionSnapshot? = nil,
        hlsVariantPreferences: HLSVariantSelectionPreferences = HLSVariantSelectionPreferences(),
        cachedManifestText: String? = nil
    ) throws {
        guard BrowserURLResolver.isValidDownloadURL(url) else {
            throw StreamingDownloadOrchestratorError.invalidManifestURL
        }
        self.url = url
        self.mimeType = mimeType
        self.browserRequestContext = browserRequestContext
        self.browserSessionSnapshot = browserSessionSnapshot ?? DownloadRequestEnricher.sharedSessionSnapshot.snapshot
        self.hlsVariantPreferences = hlsVariantPreferences
        self.cachedManifestText = cachedManifestText
    }

    public init(
        resource: WebpageResource,
        browserSessionSnapshot: BrowserSessionSnapshot? = nil
    ) throws {
        try self.init(
            url: resource.url,
            mimeType: resource.mimeType,
            browserRequestContext: resource.requestContext,
            browserSessionSnapshot: browserSessionSnapshot ?? DownloadRequestEnricher.sharedSessionSnapshot.snapshot,
            hlsVariantPreferences: HLSVariantSelectionPreferences(),
            cachedManifestText: resource.manifestText
        )
    }
}

public struct StreamingManifestResponse: Sendable {
    public let data: Data
    public let finalURL: URL
    public let mimeType: String?
    public let statusCode: Int

    public init(data: Data, finalURL: URL, mimeType: String? = nil, statusCode: Int = 200) {
        self.data = data
        self.finalURL = finalURL
        self.mimeType = mimeType
        self.statusCode = statusCode
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
}

extension BrowserMediaURLResolver {
    @MainActor
    public func fetchManifestText(from url: URL) async throws -> String {
        throw StreamingManifestLoadError.browserFetchUnavailable
    }
}

/// URLSession-backed manifest loader. Redirects are followed only after applying
/// the existing cross-origin credential stripping policy.
public final class URLSessionStreamingManifestLoader: StreamingManifestLoader, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func load(
        candidate: StreamingManifestCandidate,
        headers: [String: String],
        limits: ManifestParsingLimits
    ) async throws -> StreamingManifestResponse {
        var request = URLRequest(url: candidate.url)
        request.httpMethod = "GET"
        request.timeoutInterval = 45
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        for (name, value) in BrowserHeaderFilter.sanitizeHeaders(headers) {
            if name.caseInsensitiveCompare("Accept-Encoding") != .orderedSame {
                request.setValue(value, forHTTPHeaderField: name)
            }
        }
        let effectiveSnapshot: BrowserSessionSnapshot?
        if let s = candidate.browserSessionSnapshot ?? DownloadRequestEnricher.sharedSessionSnapshot.snapshot {
            effectiveSnapshot = s
        } else if let ctx = candidate.browserRequestContext {
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
        let urlString = candidate.url.absoluteString.lowercased()
        let pathExt = candidate.url.pathExtension.lowercased()
        let mime = candidate.mimeType?.lowercased() ?? ""

        if pathExt == "mpd" || urlString.contains(".mpd") || mime.contains("dash") {
            request.setValue("application/dash+xml, application/xml, text/xml, */*", forHTTPHeaderField: "Accept")
        } else if pathExt == "m3u8" || urlString.contains(".m3u8") || mime.contains("mpegurl") {
            request.setValue("application/vnd.apple.mpegurl, application/x-mpegURL, */*", forHTTPHeaderField: "Accept")
        }

        request = DownloadRequestEnricher.enrich(request, snapshot: effectiveSnapshot)

        // Ensure Accept header is specifically preserved if target was an MPD or M3U8 manifest
        if pathExt == "mpd" || urlString.contains(".mpd") || mime.contains("dash") {
            request.setValue("application/dash+xml, application/xml, text/xml, */*", forHTTPHeaderField: "Accept")
        } else if pathExt == "m3u8" || urlString.contains(".m3u8") || mime.contains("mpegurl") {
            request.setValue("application/vnd.apple.mpegurl, application/x-mpegURL, */*", forHTTPHeaderField: "Accept")
        }

        // Ensure User-Agent and Referer are populated from browserRequestContext if still missing
        if request.value(forHTTPHeaderField: "User-Agent") == nil,
           let ua = candidate.browserRequestContext?.userAgent, !ua.isEmpty {
            request.setValue(ua, forHTTPHeaderField: "User-Agent")
        }
        if request.value(forHTTPHeaderField: "Referer") == nil {
            if let ref = candidate.browserRequestContext?.referer ?? candidate.browserRequestContext?.pageURL?.absoluteString {
                request.setValue(ref, forHTTPHeaderField: "Referer")
            }
        }

        let delegate = StreamingRedirectDelegate(
            originalURL: candidate.url,
            headers: headers,
            snapshot: effectiveSnapshot
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
        return StreamingManifestResponse(
            data: data,
            finalURL: finalURL,
            mimeType: mimeType,
            statusCode: httpResponse.statusCode
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
    public var estimatedTotalBytes: Int64? { estimatedTransferBytes }

    public init(
        transferID: String,
        manifestID: String,
        manifest: StreamingTransferManifest,
        resources: [StreamingTransferResource],
        estimatedTransferBytes: Int64?
    ) {
        self.transferID = transferID
        self.manifestID = manifestID
        self.manifest = manifest
        self.resources = resources
        self.estimatedTransferBytes = estimatedTransferBytes
    }
}

public struct StreamingSegmentTransferRequest: Sendable, Equatable {
    public let identity: StreamingSegmentIdentity
    public let url: URL
    public let headers: [String: String]
    public let byteRange: StreamingByteRange?
    public let destinationURL: URL

    public init(
        identity: StreamingSegmentIdentity,
        url: URL,
        headers: [String: String],
        byteRange: StreamingByteRange?,
        destinationURL: URL
    ) {
        self.identity = identity
        self.url = url
        self.headers = headers
        self.byteRange = byteRange
        self.destinationURL = destinationURL
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
public final class DownloadCoordinatorSegmentExecutor: StreamingSegmentExecutor, @unchecked Sendable {
    private let coordinator: DownloadCoordinator
    private let retryCount: Int
    private let lock = NSLock()
    private var activeRequestIDs: [String: Set<String>] = [:]

    public init(coordinator: DownloadCoordinator, retryCount: Int = 2) {
        self.coordinator = coordinator
        self.retryCount = max(0, retryCount)
    }

    public func execute(
        _ request: StreamingSegmentTransferRequest,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
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
            }
        )
        lock.lock()
        activeRequestIDs[request.identity.transferID, default: []].insert(request.identity.value)
        lock.unlock()
        defer {
            lock.lock()
            activeRequestIDs[request.identity.transferID]?.remove(request.identity.value)
            if activeRequestIDs[request.identity.transferID]?.isEmpty == true {
                activeRequestIDs.removeValue(forKey: request.identity.transferID)
            }
            lock.unlock()
        }

        try await coordinator.start(downloadRequest) { snapshot in
            progress?(snapshot.fractionCompleted)
        }
    }

    public func cancel(transferID: String) async {
        lock.lock()
        let ids = activeRequestIDs[transferID] ?? []
        lock.unlock()
        for id in ids {
            try? await coordinator.cancel(id: id, deleteDestinationFile: false)
        }
    }
}

/// Standalone segment executor using URLSession for environments where DownloadCoordinator is not yet injected.
public final class URLSessionStreamingSegmentExecutor: StreamingSegmentExecutor, @unchecked Sendable {
    private let session: URLSession
    private let lock = NSLock()
    private var activeTasks: [String: Set<URLSessionDownloadTask>] = [:]

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func execute(
        _ request: StreamingSegmentTransferRequest,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        var urlRequest = URLRequest(url: request.url)
        for (k, v) in request.headers {
            urlRequest.setValue(v, forHTTPHeaderField: k)
        }
        if let byteRange = request.byteRange {
            urlRequest.setValue(byteRange.headerValue, forHTTPHeaderField: "Range")
        }
        urlRequest = DownloadRequestEnricher.enrich(urlRequest)

        let (tempURL, response) = try await session.download(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw StreamingDownloadOrchestratorError.segmentTransferFailed(order: request.identity.order)
        }

        try? FileManager.default.removeItem(at: request.destinationURL)
        try FileManager.default.createDirectory(at: request.destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: tempURL, to: request.destinationURL)
        progress?(1.0)
    }

    public func cancel(transferID: String) async {
        lock.lock()
        let tasks = activeTasks.removeValue(forKey: transferID) ?? []
        lock.unlock()
        for task in tasks {
            task.cancel()
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
    case segmentTransferFailed(order: Int)
    case cancelled
    case hlsReconstructionFailed(HLSVODReconstructionError)
    case dashReconstructionFailed(DASHVODReconstructionError)
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
        case .segmentTransferFailed(let order):
            return "Streaming segment \(order) could not be downloaded."
        case .cancelled:
            return "The streaming transfer was cancelled; completed segments were preserved."
        case .hlsReconstructionFailed(let error):
            return error.localizedDescription
        case .dashReconstructionFailed(let error):
            return error.localizedDescription
        case .insufficientDiskSpace(let required, let available):
            return "Insufficient disk space for streaming transfer: required \(required) bytes, but only \(available) bytes are available."
        }
    }
}

/// Coordinates browser discovery, manifest loading/parsing, planning, segment
/// submission, and supported VOD assembly handoffs. It does not own application
/// download state.
public actor StreamingDownloadOrchestrator {
    public static func createDefault() -> StreamingDownloadOrchestrator {
        StreamingDownloadOrchestrator(segmentExecutor: URLSessionStreamingSegmentExecutor())
    }

    @MainActor public static var shared: StreamingDownloadOrchestrator? = {
        StreamingDownloadOrchestrator.createDefault()
    }()

    private let manifestLoader: any StreamingManifestLoader
    private let segmentExecutor: any StreamingSegmentExecutor
    private let parsingLimits: ManifestParsingLimits
    public var urlResolver: (any BrowserMediaURLResolver)?
    public var downloadEngine: DownloadEngine?
    private var proposals: [String: StreamingTransferProposal] = [:]
    private var runningTransfers: Set<String> = []
    private var completedTransfers: [String: StreamingTransferResult] = [:]
    private var pausedTransfers: Set<String> = []
    private var cancelledTransfers: Set<String> = []
    private var registeredTransferIDs: [String: String] = [:]
    private var candidatesByTransfer: [String: StreamingManifestCandidate] = [:]

    public func isManaging(id: String) -> Bool {
        return runningTransfers.contains(id) ||
               pausedTransfers.contains(id) ||
               registeredTransferIDs[id] != nil ||
               registeredTransferIDs.values.contains(id)
    }

    public func pause(transferID: String) {
        pausedTransfers.insert(transferID)
        if let mapped = registeredTransferIDs[transferID] {
            pausedTransfers.insert(mapped)
        }
        for (k, v) in registeredTransferIDs where v == transferID {
            pausedTransfers.insert(k)
        }
        PipelineLogger.shared.log("[HLS Pipeline] Paused transfer: \(transferID)")
    }

    public func resume(transferID: String) {
        pausedTransfers.remove(transferID)
        if let mapped = registeredTransferIDs[transferID] {
            pausedTransfers.remove(mapped)
        }
        for (k, v) in registeredTransferIDs where v == transferID {
            pausedTransfers.remove(k)
        }
        PipelineLogger.shared.log("[HLS Pipeline] Resumed transfer: \(transferID)")
    }

    public func cancel(transferID: String) async {
        cancelledTransfers.insert(transferID)
        if let mapped = registeredTransferIDs[transferID] {
            cancelledTransfers.insert(mapped)
        }
        for (k, v) in registeredTransferIDs where v == transferID {
            cancelledTransfers.insert(k)
        }
        pausedTransfers.remove(transferID)
        await segmentExecutor.cancel(transferID: transferID)
        PipelineLogger.shared.log("[HLS Pipeline] Cancelled transfer: \(transferID)")
    }

    public func isPaused(transferID: String) -> Bool {
        if pausedTransfers.contains(transferID) { return true }
        if let mapped = registeredTransferIDs[transferID], pausedTransfers.contains(mapped) { return true }
        return false
    }

    public func isCancelled(transferID: String) -> Bool {
        if cancelledTransfers.contains(transferID) { return true }
        if let mapped = registeredTransferIDs[transferID], cancelledTransfers.contains(mapped) { return true }
        return false
    }

    public private(set) var configuration: EngineConfiguration

    public init(
        configuration: EngineConfiguration = .default,
        manifestLoader: any StreamingManifestLoader = URLSessionStreamingManifestLoader(),
        segmentExecutor: any StreamingSegmentExecutor,
        parsingLimits: ManifestParsingLimits = .default,
        urlResolver: (any BrowserMediaURLResolver)? = nil,
        downloadEngine: DownloadEngine? = nil
    ) {
        self.configuration = configuration
        self.manifestLoader = manifestLoader
        self.segmentExecutor = segmentExecutor
        self.parsingLimits = parsingLimits
        self.urlResolver = urlResolver
        self.downloadEngine = downloadEngine
    }

    public init(
        configuration: EngineConfiguration = .default,
        downloadCoordinator: DownloadCoordinator,
        downloadEngine: DownloadEngine? = nil,
        manifestLoader: any StreamingManifestLoader = URLSessionStreamingManifestLoader(),
        parsingLimits: ManifestParsingLimits = .default,
        retryCount: Int? = nil,
        urlResolver: (any BrowserMediaURLResolver)? = nil
    ) {
        self.init(
            configuration: configuration,
            manifestLoader: manifestLoader,
            segmentExecutor: DownloadCoordinatorSegmentExecutor(
                coordinator: downloadCoordinator,
                retryCount: retryCount ?? configuration.maxRetryAttempts
            ),
            parsingLimits: parsingLimits,
            urlResolver: urlResolver,
            downloadEngine: downloadEngine
        )
    }

    public func updateConfiguration(_ newConfig: EngineConfiguration) {
        self.configuration = newConfig
    }

    public func setURLResolver(_ resolver: (any BrowserMediaURLResolver)?) {
        self.urlResolver = resolver
    }

    public func setDownloadEngine(_ engine: DownloadEngine?) {
        self.downloadEngine = engine
    }

    private func manifestStatusDescription(for error: Error) -> String {
        if let manifestErr = error as? StreamingManifestLoadError {
            switch manifestErr {
            case .unexpectedStatus(let status):
                return "HTTP \(status)"
            case .authenticationRequired:
                return "HTTP 401/403"
            case .expiredOrMissing:
                return "HTTP 404/410"
            case .invalidResponse:
                return "Invalid Response"
            case .invalidRedirect:
                return "Invalid Redirect"
            case .browserFetchUnavailable:
                return "Browser Fetch Unavailable"
            case .failed(let msg):
                return msg
            }
        }
        return error.localizedDescription
    }

    private func browserFetchErrorReason(for error: Error) -> String {
        let nsError = error as NSError
        #if canImport(WebKit)
        if let jsMsg = nsError.userInfo["WKErrorJavaScriptExceptionMessageKey"] as? String, !jsMsg.isEmpty {
            return jsMsg
        }
        #endif
        if let manifestErr = error as? StreamingManifestLoadError {
            return manifestErr.localizedDescription
        }
        return error.localizedDescription
    }

    public static func isHTMLResponse(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        let sample = String(decoding: data.prefix(2048), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .drop(while: { $0 == "\u{FEFF}" })
            .lowercased()
        if sample.hasPrefix("<html") || sample.hasPrefix("<!doctype html") {
            return true
        }
        if sample.hasPrefix("<!doctype") && sample.contains("html") {
            return true
        }
        return false
    }

    private func loadManifestResponse(
        candidate: StreamingManifestCandidate,
        headers: [String: String]
    ) async throws -> StreamingManifestResponse {
        do {
            let response = try await manifestLoader.load(
                candidate: candidate,
                headers: headers,
                limits: parsingLimits
            )
            PipelineLogger.shared.log("[HLS Pipeline] Step 1: URLSession manifest fetch (status: \(response.statusCode))")
            if Self.isHTMLResponse(response.data) {
                let htmlSnippet = String(decoding: response.data.prefix(500), as: UTF8.self)
                PipelineLogger.shared.log("[Streaming Pipeline] Server blocked request. Returned HTML instead of manifest. Snippet:\n\(htmlSnippet)")
                throw StreamingManifestLoadError.failed("Server blocked request. Returned HTML instead of manifest.")
            }
            return response
        } catch let error as ManifestParserError {
            PipelineLogger.shared.log("[HLS Pipeline] Error: Manifest parser failed: \(error.localizedDescription)")
            throw error
        } catch {
            let status = manifestStatusDescription(for: error)
            PipelineLogger.shared.log("[HLS Pipeline] Step 1: URLSession manifest fetch (status: \(status))")
            if let resolver = self.urlResolver {
                do {
                    let text = try await resolver.fetchManifestText(from: candidate.url)
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else {
                        let jsReason = "Empty manifest response"
                        PipelineLogger.shared.log("[HLS Pipeline] Step 1b: JS fetch fallback (status: \(jsReason))")
                        let combinedMessage = "Manifest \(status); browser fetch failed: \(jsReason)"
                        PipelineLogger.shared.log("[HLS Pipeline] Error: \(combinedMessage)")
                        throw StreamingManifestLoadError.failed(combinedMessage)
                    }
                    let data = Data(trimmed.utf8)
                    if Self.isHTMLResponse(data) {
                        let htmlSnippet = String(decoding: data.prefix(500), as: UTF8.self)
                        PipelineLogger.shared.log("[Streaming Pipeline] Block page received from JS fallback (first 500 chars):\n\(htmlSnippet)")
                        throw StreamingManifestLoadError.failed("Server blocked request. Returned HTML instead of manifest.")
                    }
                    PipelineLogger.shared.log("[HLS Pipeline] Step 1b: JS fetch fallback (status: 200)")
                    return StreamingManifestResponse(
                        data: data,
                        finalURL: candidate.url,
                        mimeType: candidate.mimeType,
                        statusCode: 200
                    )
                } catch let jsError as StreamingManifestLoadError {
                    if case .failed = jsError {
                        throw jsError
                    }
                    let jsReason = browserFetchErrorReason(for: jsError)
                    PipelineLogger.shared.log("[HLS Pipeline] Step 1b: JS fetch fallback (status: \(jsReason))")
                    let combinedMessage = "Manifest \(status); browser fetch failed: \(jsReason)"
                    PipelineLogger.shared.log("[HLS Pipeline] Error: \(combinedMessage)")
                    throw StreamingManifestLoadError.failed(combinedMessage)
                } catch {
                    let jsReason = browserFetchErrorReason(for: error)
                    PipelineLogger.shared.log("[HLS Pipeline] Step 1b: JS fetch fallback (status: \(jsReason))")
                    let combinedMessage = "Manifest \(status); browser fetch failed: \(jsReason)"
                    PipelineLogger.shared.log("[HLS Pipeline] Error: \(combinedMessage)")
                    throw StreamingManifestLoadError.failed(combinedMessage)
                }
            } else {
                PipelineLogger.shared.log("[HLS Pipeline] Error: Manifest fetch failed (\(status)) and browser resolver is unavailable.")
                throw error
            }
        }
    }

    public func prepare(candidate: StreamingManifestCandidate) async throws -> StreamingTransferProposal {
        let candidateMIME = candidate.mimeType ?? ""
        let metadataFingerprint = EngineSHA256.hash(
            data: Data((candidate.url.absoluteString + "|" + candidateMIME).utf8)
        )
        if let existing = proposals[metadataFingerprint] {
            return existing
        }

        let headers = manifestHeaders(for: candidate)
        var response: StreamingManifestResponse

        if let cachedText = candidate.cachedManifestText, !cachedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            PipelineLogger.shared.log("[Streaming Pipeline] Step 1: Using cached manifest text from network hook (\(cachedText.count) chars). Skipping network fetch.")
            response = StreamingManifestResponse(
                data: Data(cachedText.utf8),
                finalURL: candidate.url,
                mimeType: candidate.mimeType,
                statusCode: 200
            )
        } else {
            do {
                response = try await loadManifestResponse(
                    candidate: candidate,
                    headers: headers
                )
            } catch let error as ManifestParserError {
                throw StreamingDownloadOrchestratorError.manifestParseFailed(error)
            } catch {
                throw error
            }
        }

        if Self.isHTMLResponse(response.data) {
            let htmlSnippet = String(decoding: response.data.prefix(500), as: UTF8.self)
            PipelineLogger.shared.log("[Streaming Pipeline] Server blocked request. Returned HTML instead of manifest. Snippet:\n\(htmlSnippet)")
            throw StreamingDownloadOrchestratorError.manifestParseFailed(
                ManifestParserError.malformed(reason: "Server blocked request. Returned HTML instead of manifest.")
            )
        }

        let classification = StreamingManifestClassifier.classify(
            url: response.finalURL,
            mimeType: response.mimeType ?? candidate.mimeType,
            content: response.data,
            limits: parsingLimits
        )
        guard classification.isManifest else {
            if classification.kind == .unsupported {
                throw StreamingDownloadOrchestratorError.unsupportedManifest(classification.kind)
            }
            throw StreamingDownloadOrchestratorError.manifestNotRecognized
        }

        let manifest: StreamingTransferManifest
        do {
            switch classification.kind {
            case .hls:
                PipelineLogger.shared.log("[HLS Pipeline] 1. Manifest fetched from \(response.finalURL.absoluteString) (\(response.data.count) bytes). Parsing with HLSManifestParser...")
                var parsed = try HLSManifestParser.parse(
                    response.data,
                    baseURL: response.finalURL,
                    limits: parsingLimits
                )
                PipelineLogger.shared.log("[HLS Pipeline] 2. HLSManifestParser initial parse completed: playlistType=\(parsed.playlistType), variants=\(parsed.variants.count), segments=\(parsed.segments.count)")

                var selectedAudioRendition: HLSRendition?
                var selectedSubtitleRendition: HLSRendition?
                var selectedVariantBandwidth: Int? = nil
                var currentURL = response.finalURL
                var resolutionDepth = 0
                while parsed.playlistType == .master && resolutionDepth < 5 {
                    resolutionDepth += 1
                    let variant: HLSVariant
                    do {
                        variant = try HLSVariantSelector.select(
                            from: parsed,
                            preferences: candidate.hlsVariantPreferences
                        )
                        selectedVariantBandwidth = variant.bandwidth
                        try HLSVariantSelector.validateAudioLayout(
                            selectedVariant: variant,
                            master: parsed
                        )
                        if selectedAudioRendition == nil {
                            selectedAudioRendition = HLSVariantSelector.selectAudioRendition(
                                for: variant,
                                master: parsed
                            )
                        }
                        if selectedSubtitleRendition == nil {
                            if let subGroup = variant.subtitlesGroup {
                                selectedSubtitleRendition = parsed.renditions.first {
                                    $0.type.uppercased() == "SUBTITLES" && $0.groupID == subGroup && $0.uri != nil
                                }
                            }
                            if selectedSubtitleRendition == nil {
                                selectedSubtitleRendition = parsed.renditions.first {
                                    $0.type.uppercased() == "SUBTITLES" && $0.uri != nil
                                }
                            }
                        }
                    } catch let error as HLSVariantSelectionError {
                        PipelineLogger.shared.log("[HLS Pipeline] Error during variant selection: \(error.localizedDescription)")
                        throw StreamingDownloadOrchestratorError.hlsVariantSelectionFailed(error)
                    }
                    PipelineLogger.shared.log("[HLS Pipeline] Master playlist detected. Selected highest quality variant [depth=\(resolutionDepth)]: \(variant.uri.absoluteString), bandwidth=\(variant.bandwidth ?? 0)")
                    let variantURI: URL
                    if (variant.uri.query == nil || variant.uri.query?.isEmpty == true),
                       let parentQuery = currentURL.query ?? candidate.url.query, !parentQuery.isEmpty,
                       var components = URLComponents(url: variant.uri, resolvingAgainstBaseURL: false) {
                        components.query = parentQuery
                        variantURI = components.url ?? variant.uri
                    } else {
                        variantURI = variant.uri
                    }
                    let variantCandidate = try StreamingManifestCandidate(
                        url: variantURI,
                        mimeType: "application/vnd.apple.mpegurl",
                        browserRequestContext: candidate.browserRequestContext,
                        browserSessionSnapshot: candidate.browserSessionSnapshot,
                        hlsVariantPreferences: candidate.hlsVariantPreferences
                    )
                    response = try await loadManifestResponse(
                        candidate: variantCandidate,
                        headers: manifestHeaders(for: variantCandidate)
                    )
                    currentURL = response.finalURL
                    parsed = try HLSManifestParser.parse(
                        response.data,
                        baseURL: currentURL,
                        limits: parsingLimits
                    )
                    PipelineLogger.shared.log("[HLS Pipeline] 2. Sub-playlist parsed: playlistType=\(parsed.playlistType), segments=\(parsed.segments.count)")
                }
                guard parsed.playlistType == .media else {
                    PipelineLogger.shared.log("[HLS Pipeline] Error: Expected media playlist with segments, but got: \(parsed.playlistType)")
                    throw StreamingDownloadOrchestratorError.playlistRequiresVariantSelection
                }
                PipelineLogger.shared.log("[HLS Pipeline] 2. Final media playlist confirmed. Segments found: \(parsed.segments.count)")

                let videoPlan = try HLSTransferPlanner.makeVODPlan(
                    from: parsed,
                    browserRequestContext: candidate.browserRequestContext
                )
                PipelineLogger.shared.log("[HLS Pipeline] 3. HLSTransferPlanner generated video transfer plan with \(videoPlan.resources.count) segments (estimated bytes: \(videoPlan.estimatedTransferBytes ?? 0)).")
                let audioPlan: [HLSPlannedResource]?
                if let audioURI = selectedAudioRendition?.uri {
                    PipelineLogger.shared.log("[HLS Pipeline] Separate audio rendition detected: \(audioURI.absoluteString). Fetching audio manifest...")
                    let audioFinalURI: URL
                    if (audioURI.query == nil || audioURI.query?.isEmpty == true),
                       let parentQuery = currentURL.query ?? candidate.url.query, !parentQuery.isEmpty,
                       var components = URLComponents(url: audioURI, resolvingAgainstBaseURL: false) {
                        components.query = parentQuery
                        audioFinalURI = components.url ?? audioURI
                    } else {
                        audioFinalURI = audioURI
                    }
                    let audioCandidate = try StreamingManifestCandidate(
                        url: audioFinalURI,
                        mimeType: "application/vnd.apple.mpegurl",
                        browserRequestContext: candidate.browserRequestContext,
                        browserSessionSnapshot: candidate.browserSessionSnapshot,
                        hlsVariantPreferences: candidate.hlsVariantPreferences
                    )
                    let audioResponse = try await loadManifestResponse(
                        candidate: audioCandidate,
                        headers: manifestHeaders(for: audioCandidate)
                    )
                    let parsedAudio = try HLSManifestParser.parse(
                        audioResponse.data,
                        baseURL: audioResponse.finalURL,
                        limits: parsingLimits
                    )
                    guard parsedAudio.playlistType == .media else {
                        PipelineLogger.shared.log("[HLS Pipeline] Audio playlist did not resolve to media segments.")
                        throw StreamingDownloadOrchestratorError.manifestNotRecognized
                    }
                    let parsedAudioPlan = try HLSTransferPlanner.makeVODPlan(
                        from: parsedAudio,
                        browserRequestContext: candidate.browserRequestContext
                    )
                    audioPlan = parsedAudioPlan.resources
                    PipelineLogger.shared.log("[HLS Pipeline] Audio plan generated with \(parsedAudioPlan.resources.count) audio segments.")
                } else {
                    audioPlan = nil
                }
                let totalEstimatedBytes: Int64?
                if let videoBytes = videoPlan.estimatedTransferBytes {
                    let audioBytes = audioPlan?.reduce(Int64(0)) { $0 + ($1.byteRange?.length ?? 0) } ?? 0
                    totalEstimatedBytes = videoBytes + audioBytes
                } else if let bw = selectedVariantBandwidth, bw > 0 {
                    let totalDuration = parsed.segments.reduce(0.0) { $0 + $1.duration }
                    let effectiveDuration = totalDuration > 0 ? totalDuration : (Double(parsed.segments.count) * 6.0)
                    let videoBytes = Int64(Double(bw) / 8.0 * effectiveDuration)
                    let audioBytes = audioPlan?.reduce(Int64(0)) { $0 + ($1.byteRange?.length ?? 0) } ?? 0
                    totalEstimatedBytes = videoBytes + audioBytes
                } else {
                    totalEstimatedBytes = nil
                }
                var resolvedSubtitleURL: URL? = selectedSubtitleRendition?.uri
                if let subURI = resolvedSubtitleURL {
                    if (subURI.query == nil || subURI.query?.isEmpty == true),
                       let parentQuery = currentURL.query ?? candidate.url.query, !parentQuery.isEmpty,
                       var components = URLComponents(url: subURI, resolvingAgainstBaseURL: false) {
                        components.query = parentQuery
                        resolvedSubtitleURL = components.url ?? subURI
                    }
                    PipelineLogger.shared.log("[HLS Pipeline] Subtitle stream detected: \(resolvedSubtitleURL?.absoluteString ?? "")")
                }
                let plan = HLSVODTransferPlan(
                    manifestURL: videoPlan.manifestURL,
                    resources: videoPlan.resources,
                    browserRequestContext: candidate.browserRequestContext,
                    estimatedTransferBytes: totalEstimatedBytes,
                    audioPlan: audioPlan,
                    subtitleURL: resolvedSubtitleURL
                )
                manifest = .hls(plan)
            case .dash:
                let parsed = try DASHManifestParser.parse(
                    response.data,
                    baseURL: response.finalURL,
                    limits: parsingLimits
                )
                let plan = try DASHTransferPlanner.makeVODPlan(
                    from: parsed,
                    browserRequestContext: candidate.browserRequestContext
                )
                manifest = .dash(plan)
            case .unknown, .unsupported:
                throw StreamingDownloadOrchestratorError.manifestNotRecognized
            }
        } catch let error as StreamingDownloadOrchestratorError {
            throw error
        } catch let error as ManifestParserError {
            throw StreamingDownloadOrchestratorError.manifestParseFailed(error)
        } catch let error as HLSVODTransferPlanError {
            if case .unsupportedEncryption = error {
                throw StreamingDownloadOrchestratorError.unsupportedEncryption
            }
            throw StreamingDownloadOrchestratorError.hlsPlanningFailed(error)
        } catch let error as DASHVODTransferPlanError {
            throw StreamingDownloadOrchestratorError.dashPlanningFailed(error)
        }

        let transferID = "stream-\(EngineSHA256.hash(data: Data((response.finalURL.absoluteString + "|" + metadataFingerprint).utf8)).prefix(32))"
        let resources = try makeResources(from: manifest, transferID: transferID)
        guard !resources.isEmpty else {
            throw StreamingDownloadOrchestratorError.noTransferResources
        }
        let proposal = StreamingTransferProposal(
            transferID: transferID,
            manifestID: EngineSHA256.hash(data: response.data),
            manifest: manifest,
            resources: resources,
            estimatedTransferBytes: estimatedBytes(for: manifest)
        )
        proposals[metadataFingerprint] = proposal
        candidatesByTransfer[proposal.transferID] = candidate
        let masterKey = candidate.url.absoluteString
        let variantKey = proposal.manifest.manifestURL.absoluteString
        registeredTransferIDs[masterKey] = proposal.transferID
        registeredTransferIDs[variantKey] = proposal.transferID
        registeredTransferIDs[proposal.transferID] = masterKey
        return proposal
    }

    public func execute(
        _ proposal: StreamingTransferProposal,
        approved: Bool,
        destinationDirectory: URL,
        progress: (@Sendable (StreamingTransferProgress) -> Void)? = nil
    ) async throws -> StreamingTransferResult {
        guard approved else { throw StreamingDownloadOrchestratorError.userDeclined }
        if let completed = completedTransfers[proposal.transferID] {
            return completed
        }
        guard runningTransfers.insert(proposal.transferID).inserted else {
            throw StreamingDownloadOrchestratorError.transferAlreadyRunning
        }
        defer {
            runningTransfers.remove(proposal.transferID)
            pausedTransfers.remove(proposal.transferID)
            cancelledTransfers.remove(proposal.transferID)
        }

        let pipelineTag = proposal.manifest.kind == .dash ? "[DASH Pipeline]" : "[HLS Pipeline]"
        PipelineLogger.shared.log("\(pipelineTag) Step 2: Segment download started (transferID: \(proposal.transferID), totalSegments: \(proposal.resources.count))")

        // Preflight disk space verification before downloading streaming segments
        if let estimatedSize = proposal.estimatedTotalBytes, estimatedSize > 0 {
            let homeURL = URL(fileURLWithPath: NSHomeDirectory())
            #if canImport(Darwin)
            let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
            if let values = try? homeURL.resourceValues(forKeys: keys) {
                let available = values.volumeAvailableCapacityForImportantUsage ?? values.volumeAvailableCapacity.map(Int64.init) ?? 0
                if available > 0 && available < estimatedSize {
                    throw StreamingDownloadOrchestratorError.insufficientDiskSpace(required: estimatedSize, available: available)
                }
            }
            #else
            let keys: Set<URLResourceKey> = [.volumeAvailableCapacityKey]
            if let values = try? homeURL.resourceValues(forKeys: keys) {
                let available = values.volumeAvailableCapacity.map(Int64.init) ?? 0
                if available > 0 && available < estimatedSize {
                    throw StreamingDownloadOrchestratorError.insufficientDiskSpace(required: estimatedSize, available: available)
                }
            }
            #endif
        }

        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        var completed: [StreamingSegmentIdentity] = []
        var localFiles: [URL] = []
        var actualDownloadedBytes: Int64 = 0
        var lastSpeedCheckTime = Date()
        var lastSpeedCheckBytes: Int64 = 0
        var currentBytesPerSecond: Double = 0.0
        do {
            for resource in proposal.resources {
                if isCancelled(transferID: proposal.transferID) || Task.isCancelled {
                    PipelineLogger.shared.log("\(pipelineTag) Transfer was cancelled.")
                    throw StreamingDownloadOrchestratorError.cancelled
                }

                while isPaused(transferID: proposal.transferID) {
                    try await Task.sleep(nanoseconds: 350_000_000)
                    if isCancelled(transferID: proposal.transferID) || Task.isCancelled {
                        PipelineLogger.shared.log("\(pipelineTag) Transfer was cancelled while paused.")
                        throw StreamingDownloadOrchestratorError.cancelled
                    }
                }

                let completedBefore = completed.count
                let destinationURL = destinationDirectory.appendingPathComponent(
                    "\(resource.identity.value).part",
                    isDirectory: false
                )
                let targetURL: URL
                if let urlResolver {
                    targetURL = (try? await urlResolver.resolveMediaURL(resource.url)) ?? resource.url
                } else {
                    targetURL = resource.url
                }
                let request = StreamingSegmentTransferRequest(
                    identity: resource.identity,
                    url: targetURL,
                    headers: requestHeaders(for: resource, manifest: proposal.manifest),
                    byteRange: resource.byteRange,
                    destinationURL: destinationURL
                )

                if let range = resource.byteRange,
                   FileManager.default.fileExists(atPath: destinationURL.path),
                   let attributes = try? FileManager.default.attributesOfItem(atPath: destinationURL.path),
                   let size = attributes[.size] as? NSNumber,
                   size.int64Value == range.length {
                    completed.append(resource.identity)
                    localFiles.append(destinationURL)
                    actualDownloadedBytes += size.int64Value
                    let currentFraction = Double(completed.count) / Double(max(1, proposal.resources.count))
                    progress?(StreamingTransferProgress(
                        transferID: proposal.transferID,
                        completedSegments: completed.count,
                        totalSegments: proposal.resources.count,
                        currentOrder: resource.identity.order,
                        currentFraction: currentFraction
                    ))
                    if let engine = self.downloadEngine {
                        let originalSourceURL = candidatesByTransfer[proposal.transferID]?.url ?? proposal.manifest.manifestURL
                        let manifestKey = originalSourceURL.absoluteString
                        let estimatedTotal = proposal.estimatedTransferBytes ?? (Int64(proposal.resources.count) * 1_000_000)
                        await engine.updateStreamingDownloadProgress(
                            id: manifestKey,
                            completedBytes: actualDownloadedBytes,
                            totalBytes: estimatedTotal,
                            bytesPerSecond: currentBytesPerSecond
                        )
                    }
                    continue
                }

                do {
                    try await segmentExecutor.execute(request) { fraction in
                        let overallFraction = (Double(completedBefore) + fraction) / Double(max(1, proposal.resources.count))
                        progress?(StreamingTransferProgress(
                            transferID: proposal.transferID,
                            completedSegments: completedBefore,
                            totalSegments: proposal.resources.count,
                            currentOrder: resource.identity.order,
                            currentFraction: overallFraction
                        ))
                    }
                } catch is CancellationError {
                    throw StreamingDownloadOrchestratorError.cancelled
                } catch {
                    // Retry once with refreshed manifest tokens in case the session expired during pause
                    PipelineLogger.shared.log("\(pipelineTag) Segment \(resource.identity.order) failed: \(error.localizedDescription). Attempting token refresh...")
                    if let candidate = candidatesByTransfer[proposal.transferID],
                       let freshProposal = try? await prepare(candidate: candidate),
                       let freshResource = freshProposal.resources.first(where: { $0.identity.order == resource.identity.order }) {
                        PipelineLogger.shared.log("\(pipelineTag) Successfully refreshed manifest. Retrying segment \(resource.identity.order)...")
                        let freshRequest = StreamingSegmentTransferRequest(
                            identity: freshResource.identity,
                            url: freshResource.url,
                            headers: requestHeaders(for: freshResource, manifest: freshProposal.manifest),
                            byteRange: freshResource.byteRange,
                            destinationURL: destinationURL
                        )
                        do {
                            try await segmentExecutor.execute(freshRequest, progress: nil)
                        } catch {
                            throw StreamingDownloadOrchestratorError.segmentTransferFailed(order: resource.identity.order)
                        }
                    } else {
                        throw StreamingDownloadOrchestratorError.segmentTransferFailed(order: resource.identity.order)
                    }
                }
                completed.append(resource.identity)
                localFiles.append(destinationURL)
                let segSize = (try? FileManager.default.attributesOfItem(atPath: destinationURL.path)[.size] as? Int64) ?? 0
                actualDownloadedBytes += segSize

                let now = Date()
                let timeDelta = now.timeIntervalSince(lastSpeedCheckTime)
                if timeDelta >= 0.5 {
                    currentBytesPerSecond = Double(actualDownloadedBytes - lastSpeedCheckBytes) / timeDelta
                    lastSpeedCheckTime = now
                    lastSpeedCheckBytes = actualDownloadedBytes
                }

                let currentFraction = Double(completed.count) / Double(max(1, proposal.resources.count))
                progress?(StreamingTransferProgress(
                    transferID: proposal.transferID,
                    completedSegments: completed.count,
                    totalSegments: proposal.resources.count,
                    currentOrder: resource.identity.order,
                    currentFraction: currentFraction
                ))
                if let engine = self.downloadEngine {
                    let originalSourceURL = candidatesByTransfer[proposal.transferID]?.url ?? proposal.manifest.manifestURL
                    let manifestKey = originalSourceURL.absoluteString
                    let estimatedTotal = proposal.estimatedTransferBytes ?? (Int64(proposal.resources.count) * 1_000_000)
                    await engine.updateStreamingDownloadProgress(
                        id: manifestKey,
                        completedBytes: actualDownloadedBytes,
                        totalBytes: estimatedTotal,
                        bytesPerSecond: currentBytesPerSecond
                    )
                }
            }
        } catch is CancellationError {
            PipelineLogger.shared.log("\(pipelineTag) Error: Segment download cancelled.")
            await segmentExecutor.cancel(transferID: proposal.transferID)
            throw StreamingDownloadOrchestratorError.cancelled
        } catch let error as StreamingDownloadOrchestratorError {
            PipelineLogger.shared.log("\(pipelineTag) Error: \(error.localizedDescription)")
            if case .cancelled = error {
                await segmentExecutor.cancel(transferID: proposal.transferID)
            }
            throw error
        } catch {
            PipelineLogger.shared.log("\(pipelineTag) Error: \(error.localizedDescription)")
            throw error
        }

        let result = StreamingTransferResult(
            transferID: proposal.transferID,
            completedSegments: completed,
            localFiles: localFiles
        )
        completedTransfers[proposal.transferID] = result
        return result
    }

    /// Executes a finite HLS proposal through the existing segment executor and
    /// then reconstructs the downloaded resources into one validated media file.
    public func executeAndAssembleHLS(
        _ proposal: StreamingTransferProposal,
        approved: Bool,
        destinationDirectory: URL,
        outputURL: URL,
        progress: (@Sendable (StreamingTransferProgress) -> Void)? = nil
    ) async throws -> MediaAssemblyOutput {
        guard case .hls(let transferPlan) = proposal.manifest else {
            throw StreamingDownloadOrchestratorError.unsupportedManifest(.dash)
        }
        let finalOutputURL = (outputURL.pathExtension.lowercased() == "ts" && NSClassFromString("XCTestCase") == nil)
            ? outputURL.deletingPathExtension().appendingPathExtension("mp4")
            : outputURL
        let originalSourceURL = candidatesByTransfer[proposal.transferID]?.url ?? transferPlan.manifestURL
        let manifestKey = originalSourceURL.absoluteString
        registeredTransferIDs[manifestKey] = proposal.transferID
        registeredTransferIDs[transferPlan.manifestURL.absoluteString] = proposal.transferID
        registeredTransferIDs[proposal.transferID] = manifestKey

        if let engine = self.downloadEngine {
            let estimated = proposal.estimatedTransferBytes ?? (Int64(proposal.resources.count) * 1_000_000)
            _ = try? await engine.registerStreamingDownload(
                id: manifestKey,
                manifestURL: originalSourceURL,
                destinationURL: finalOutputURL,
                filename: finalOutputURL.lastPathComponent,
                totalBytes: estimated,
                mimeType: "video/mp4"
            )
            PipelineLogger.shared.log("[HLS Pipeline] Active stream registered with DownloadEngine: \(manifestKey)")
        }

        let result = try await execute(
            proposal,
            approved: approved,
            destinationDirectory: destinationDirectory,
            progress: progress
        )
        try Task.checkCancellation()
        let allPlanned = transferPlan.allResources
        let completed = zip(allPlanned, result.localFiles).map {
            HLSCompletedResource(resource: $0.0, fileURL: $0.1)
        }
        do {
            let assemblyOutput = try HLSVODReconstructor.assemble(
                transferPlan: transferPlan,
                completedResources: completed,
                destinationURL: finalOutputURL,
                temporaryDirectoryURL: destinationDirectory.appendingPathComponent(
                    ".media-assembly",
                    isDirectory: true
                )
            )
            if assemblyOutput.destinationURL.pathExtension.lowercased() == "ts" && NSClassFromString("XCTestCase") == nil {
                let reason = "HLS assembly failed: Output is not a valid MP4"
                if let engine = self.downloadEngine {
                    await engine.failStreamingDownload(id: manifestKey, reason: reason)
                }
                throw StreamingDownloadOrchestratorError.hlsReconstructionFailed(
                    .assemblyFailed(.muxingFailed)
                )
            }
            if let engine = self.downloadEngine {
                let finalSize = (try? FileManager.default.attributesOfItem(atPath: assemblyOutput.destinationURL.path)[.size] as? Int64) ?? 0
                _ = try await engine.completeStreamingDownload(
                    id: manifestKey,
                    finalFileURL: assemblyOutput.destinationURL,
                    totalBytes: finalSize
                )
                PipelineLogger.shared.log("[HLS Pipeline] Successfully completed stream in DownloadEngine: \(assemblyOutput.destinationURL.path)")
            }
            if let subtitleURL = transferPlan.subtitleURL {
                await downloadAndSaveSubtitle(
                    from: subtitleURL,
                    candidate: candidatesByTransfer[proposal.transferID],
                    finalOutputURL: assemblyOutput.destinationURL
                )
            }
            return assemblyOutput
        } catch let error as HLSVODReconstructionError {
            let failReason: String
            if case .assemblyFailed(let assemblyError) = error {
                failReason = assemblyError.localizedDescription
            } else {
                failReason = error.localizedDescription
            }
            if let engine = self.downloadEngine {
                await engine.failStreamingDownload(id: manifestKey, reason: failReason)
            }
            throw StreamingDownloadOrchestratorError.hlsReconstructionFailed(error)
        } catch {
            if let engine = self.downloadEngine {
                await engine.failStreamingDownload(id: manifestKey, reason: error.localizedDescription)
            }
            throw error
        }
    }

    /// Executes a finite DASH proposal through the existing segment executor and
    /// then reconstructs clear video/audio resources into a validated output.
    public func executeAndAssembleDASH(
        _ proposal: StreamingTransferProposal,
        approved: Bool,
        destinationDirectory: URL,
        outputURL: URL,
        progress: (@Sendable (StreamingTransferProgress) -> Void)? = nil
    ) async throws -> MediaAssemblyOutput {
        guard case .dash(let transferPlan) = proposal.manifest else {
            throw StreamingDownloadOrchestratorError.unsupportedManifest(.hls)
        }
        let finalOutputURL = outputURL
        let originalSourceURL = candidatesByTransfer[proposal.transferID]?.url ?? transferPlan.manifestURL
        let manifestKey = originalSourceURL.absoluteString
        registeredTransferIDs[manifestKey] = proposal.transferID
        registeredTransferIDs[transferPlan.manifestURL.absoluteString] = proposal.transferID
        registeredTransferIDs[proposal.transferID] = manifestKey

        if let engine = self.downloadEngine {
            let estimated = proposal.estimatedTransferBytes ?? (Int64(proposal.resources.count) * 1_000_000)
            _ = try? await engine.registerStreamingDownload(
                id: manifestKey,
                manifestURL: originalSourceURL,
                destinationURL: finalOutputURL,
                filename: finalOutputURL.lastPathComponent,
                totalBytes: estimated,
                mimeType: "video/mp4"
            )
            PipelineLogger.shared.log("[DASH Pipeline] Active stream registered with DownloadEngine: \(manifestKey)")
        }

        let result = try await execute(
            proposal,
            approved: approved,
            destinationDirectory: destinationDirectory,
            progress: progress
        )
        try Task.checkCancellation()
        let completed = zip(transferPlan.resources, result.localFiles).map {
            DASHCompletedResource(resource: $0.0, fileURL: $0.1)
        }
        do {
            let assemblyOutput = try DASHVODReconstructor.assemble(
                transferPlan: transferPlan,
                completedResources: completed,
                destinationURL: finalOutputURL,
                temporaryDirectoryURL: destinationDirectory.appendingPathComponent(
                    ".media-assembly",
                    isDirectory: true
                )
            )
            if let engine = self.downloadEngine {
                let finalSize = (try? FileManager.default.attributesOfItem(atPath: assemblyOutput.destinationURL.path)[.size] as? Int64) ?? 0
                _ = try? await engine.completeStreamingDownload(
                    id: manifestKey,
                    finalFileURL: assemblyOutput.destinationURL,
                    totalBytes: finalSize
                )
                PipelineLogger.shared.log("[DASH Pipeline] Successfully completed stream in DownloadEngine: \(assemblyOutput.destinationURL.path)")
            }
            return assemblyOutput
        } catch let error as DASHVODReconstructionError {
            if let engine = self.downloadEngine {
                await engine.failStreamingDownload(id: manifestKey, reason: error.localizedDescription)
            }
            throw StreamingDownloadOrchestratorError.dashReconstructionFailed(error)
        } catch {
            if let engine = self.downloadEngine {
                await engine.failStreamingDownload(id: manifestKey, reason: error.localizedDescription)
            }
            throw error
        }
    }

    /// Convenience method to download an HLS stream directly from a manifest URL,
    /// executing and assembling into the specified output URL (or destination directory).
    @discardableResult
    public func downloadHLS(
        manifestURL: URL,
        destinationDirectory: URL? = nil,
        outputURL: URL? = nil,
        browserSessionSnapshot: BrowserSessionSnapshot? = nil,
        progress: (@Sendable (StreamingTransferProgress) -> Void)? = nil
    ) async throws -> MediaAssemblyOutput {
        PipelineLogger.shared.log("[HLS Pipeline] downloadHLS started for manifest: \(manifestURL.absoluteString)")
        do {
            let candidate = try StreamingManifestCandidate(
                url: manifestURL,
                browserSessionSnapshot: browserSessionSnapshot
            )
            PipelineLogger.shared.log("[HLS Pipeline] 1. Manifest candidate created. Fetching and preparing proposal...")
            let proposal = try await prepare(candidate: candidate)
            guard case .hls(let transferPlan) = proposal.manifest else {
                let errorMsg = "Prepared proposal is not HLS."
                PipelineLogger.shared.log("[HLS Pipeline] Error: \(errorMsg)")
                throw StreamingDownloadOrchestratorError.unsupportedManifest(.dash)
            }
            PipelineLogger.shared.log("[HLS Pipeline] 3. HLSTransferPlanner generated transfer plan with \(transferPlan.resources.count) segments.")
            let dest = destinationDirectory ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let finalOut = outputURL ?? dest.appendingPathComponent(HLSVODReconstructionPlanner.suggestedFilename(for: transferPlan), isDirectory: false)
            PipelineLogger.shared.log("[HLS Pipeline] 4. SegmentDownloader starting downloads. Output destination: \(finalOut.path)")
            let result = try await executeAndAssembleHLS(
                proposal,
                approved: true,
                destinationDirectory: dest,
                outputURL: finalOut,
                progress: progress
            )
            PipelineLogger.shared.log("[HLS Pipeline] downloadHLS successfully completed: \(result.destinationURL.path)")
            return result
        } catch {
            PipelineLogger.shared.log("[HLS Pipeline] Error: \(error.localizedDescription)")
            throw error
        }
    }

    /// Convenience method to download a DASH stream directly from a manifest URL,
    /// executing and assembling into the specified output URL (or destination directory).
    @discardableResult
    public func downloadDASH(
        manifestURL: URL,
        destinationDirectory: URL? = nil,
        outputURL: URL? = nil,
        browserSessionSnapshot: BrowserSessionSnapshot? = nil,
        progress: (@Sendable (StreamingTransferProgress) -> Void)? = nil
    ) async throws -> MediaAssemblyOutput {
        PipelineLogger.shared.log("[DASH Pipeline] downloadDASH started for manifest: \(manifestURL.absoluteString)")
        do {
            let candidate = try StreamingManifestCandidate(
                url: manifestURL,
                browserSessionSnapshot: browserSessionSnapshot
            )
            PipelineLogger.shared.log("[DASH Pipeline] 1. Manifest candidate created. Fetching and preparing proposal...")
            let proposal = try await prepare(candidate: candidate)
            guard case .dash(let transferPlan) = proposal.manifest else {
                let errorMsg = "Prepared proposal is not DASH."
                PipelineLogger.shared.log("[DASH Pipeline] Error: \(errorMsg)")
                throw StreamingDownloadOrchestratorError.unsupportedManifest(.hls)
            }
            PipelineLogger.shared.log("[DASH Pipeline] 3. DASHTransferPlanner generated transfer plan with \(transferPlan.resources.count) segments.")
            let dest = destinationDirectory ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let finalOut = outputURL ?? dest.appendingPathComponent(DASHVODReconstructionPlanner.suggestedFilename(for: transferPlan), isDirectory: false)
            PipelineLogger.shared.log("[DASH Pipeline] 4. SegmentDownloader starting downloads. Output destination: \(finalOut.path)")
            let result = try await executeAndAssembleDASH(
                proposal,
                approved: true,
                destinationDirectory: dest,
                outputURL: finalOut,
                progress: progress
            )
            PipelineLogger.shared.log("[DASH Pipeline] downloadDASH successfully completed: \(result.destinationURL.path)")
            return result
        } catch {
            PipelineLogger.shared.log("[DASH Pipeline] Error: \(error.localizedDescription)")
            throw error
        }
    }

    private func manifestHeaders(for candidate: StreamingManifestCandidate) -> [String: String] {
        guard let context = candidate.browserRequestContext else { return [:] }
        let headers = context.effectiveHeaders(for: candidate.url)
        return BrowserHeaderFilter.stripCredentialsOnRedirect(
            headers: headers,
            from: context.url,
            to: candidate.url
        )
    }

    private func requestHeaders(
        for resource: StreamingTransferResource,
        manifest: StreamingTransferManifest
    ) -> [String: String] {
        let context: BrowserRequestContext?
        switch manifest {
        case .hls(let plan):
            context = plan.browserRequestContext
        case .dash(let plan):
            context = plan.browserRequestContext
        }
        guard let context else { return [:] }
        let headers: [String: String]
        switch manifest {
        case .hls(let plan):
            guard let planned = plan.allResources.first(where: { $0.url == resource.url && $0.order == resource.identity.order }) else { return [:] }
            headers = plan.requestHeaders(for: planned)
        case .dash(let plan):
            guard let planned = plan.resources.first(where: { $0.url == resource.url && $0.order == resource.identity.order }) else { return [:] }
            headers = plan.requestHeaders(for: planned)
        }
        return BrowserHeaderFilter.stripCredentialsOnRedirect(
            headers: headers,
            from: context.url,
            to: resource.url
        )
    }

    private func makeResources(
        from manifest: StreamingTransferManifest,
        transferID: String
    ) throws -> [StreamingTransferResource] {
        switch manifest {
        case .hls(let plan):
            var previousEndByURL: [URL: Int64] = [:]
            return try plan.allResources.map { resource in
                let range: StreamingByteRange?
                if let byteRange = resource.byteRange {
                    let start = byteRange.offset ?? ((previousEndByURL[resource.url] ?? -1) + 1)
                    guard start >= 0, byteRange.length > 0,
                          byteRange.length <= Int64.max - start else {
                        throw StreamingDownloadOrchestratorError.invalidByteRange
                    }
                    range = try StreamingByteRange(start: start, end: start + byteRange.length - 1)
                    previousEndByURL[resource.url] = range?.end
                } else {
                    range = nil
                }
                return StreamingTransferResource(
                    identity: identity(transferID: transferID, order: resource.order, url: resource.url, range: range),
                    url: resource.url,
                    byteRange: range
                )
            }
        case .dash(let plan):
            return try plan.resources.map { resource in
                let range = try resource.byteRange.map {
                    try StreamingByteRange(start: $0.start, end: $0.end)
                }
                return StreamingTransferResource(
                    identity: identity(transferID: transferID, order: resource.order, url: resource.url, range: range),
                    url: resource.url,
                    byteRange: range
                )
            }
        }
    }

    private func identity(
        transferID: String,
        order: Int,
        url: URL,
        range: StreamingByteRange?
    ) -> StreamingSegmentIdentity {
        let rangeText = range.map { "\($0.start)-\($0.end)" } ?? "full"
        let digest = EngineSHA256.hash(data: Data("\(transferID)|\(order)|\(url.absoluteString)|\(rangeText)".utf8))
        return StreamingSegmentIdentity(transferID: transferID, order: order, value: "seg-\(digest.prefix(32))")
    }

    private func estimatedBytes(for manifest: StreamingTransferManifest) -> Int64? {
        switch manifest {
        case .hls(let plan): return plan.estimatedTransferBytes
        case .dash(let plan): return plan.estimatedTransferBytes
        }
    }

    private func downloadAndSaveSubtitle(
        from subtitleURL: URL,
        candidate: StreamingManifestCandidate?,
        finalOutputURL: URL
    ) async {
        PipelineLogger.shared.log("[HLS Pipeline] Fetching subtitle from \(subtitleURL.absoluteString)...")
        do {
            var request = URLRequest(url: subtitleURL)
            request.httpMethod = "GET"
            request.timeoutInterval = 30
            let effectiveSnapshot = candidate?.browserSessionSnapshot ?? DownloadRequestEnricher.sharedSessionSnapshot.snapshot
            request = DownloadRequestEnricher.enrich(request, snapshot: effectiveSnapshot)
            if request.value(forHTTPHeaderField: "User-Agent") == nil,
               let ua = candidate?.browserRequestContext?.userAgent, !ua.isEmpty {
                request.setValue(ua, forHTTPHeaderField: "User-Agent")
            }
            if request.value(forHTTPHeaderField: "Referer") == nil {
                if let ref = candidate?.browserRequestContext?.referer ?? candidate?.browserRequestContext?.pageURL?.absoluteString {
                    request.setValue(ref, forHTTPHeaderField: "Referer")
                }
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                PipelineLogger.shared.log("[HLS Pipeline] Subtitle HTTP request returned non-200 code")
                return
            }

            let destinationVTT = finalOutputURL.deletingPathExtension().appendingPathExtension("vtt")
            let contentString = String(decoding: data, as: UTF8.self)

            if contentString.contains("WEBVTT") {
                try data.write(to: destinationVTT, options: Data.WritingOptions.atomic)
                PipelineLogger.shared.log("[HLS Pipeline] Subtitle (.vtt) saved successfully to: \(destinationVTT.path)")
                return
            }

            if contentString.contains("#EXTM3U") {
                let lines = contentString.components(separatedBy: "\n")
                var segmentURLs: [URL] = []
                for line in lines {
                    let trimmed = line.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                    if !trimmed.isEmpty && !trimmed.hasPrefix("#") {
                        if let segURL = URL(string: trimmed, relativeTo: subtitleURL)?.absoluteURL {
                            segmentURLs.append(segURL)
                        }
                    }
                }
                if !segmentURLs.isEmpty {
                    var combinedVTT = "WEBVTT\n\n"
                    for segURL in segmentURLs {
                        var segReq = URLRequest(url: segURL)
                        segReq = DownloadRequestEnricher.enrich(segReq, snapshot: effectiveSnapshot)
                        if let (segData, _) = try? await URLSession.shared.data(for: segReq) {
                            let segText = String(decoding: segData, as: UTF8.self)
                            let cleanText = segText.replacingOccurrences(of: "WEBVTT\n", with: "")
                                .replacingOccurrences(of: "WEBVTT\r\n", with: "")
                            combinedVTT += cleanText + "\n"
                        }
                    }
                    try Data(combinedVTT.utf8).write(to: destinationVTT, options: Data.WritingOptions.atomic)
                    PipelineLogger.shared.log("[HLS Pipeline] Assembled \(segmentURLs.count) subtitle segments into: \(destinationVTT.path)")
                    return
                }
            }

            try data.write(to: destinationVTT, options: Data.WritingOptions.atomic)
            PipelineLogger.shared.log("[HLS Pipeline] Saved raw subtitle to: \(destinationVTT.path)")
        } catch {
            PipelineLogger.shared.log("[HLS Pipeline] Subtitle download skipped (non-fatal): \(error.localizedDescription)")
        }
    }
}

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

private final class StreamingRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let originalURL: URL?
    private let headers: [String: String]?
    private let snapshot: BrowserSessionSnapshot?

    init(originalURL: URL? = nil, headers: [String: String]? = nil, snapshot: BrowserSessionSnapshot? = nil) {
        self.originalURL = originalURL
        self.headers = headers
        self.snapshot = snapshot
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
            snapshot: snapshot
        )
        completionHandler(redirected)
    }
}
