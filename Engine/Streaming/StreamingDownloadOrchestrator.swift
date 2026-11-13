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

    public init(
        url: URL,
        mimeType: String? = nil,
        browserRequestContext: BrowserRequestContext? = nil,
        browserSessionSnapshot: BrowserSessionSnapshot? = nil,
        hlsVariantPreferences: HLSVariantSelectionPreferences = HLSVariantSelectionPreferences(),
        cachedManifestText: String? = nil,
        dashVideoRepresentationID: String? = nil,
        dashAudioRepresentationID: String? = nil
    ) throws {
        guard BrowserURLResolver.isValidDownloadURL(url) else {
            throw StreamingDownloadOrchestratorError.invalidManifestURL
        }
        self.url = url
        self.mimeType = mimeType
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
    }

    public init(
        resource: WebpageResource,
        browserSessionSnapshot: BrowserSessionSnapshot? = nil
    ) throws {
        try self.init(
            url: resource.url,
            mimeType: resource.mimeType,
            browserRequestContext: resource.requestContext,
            browserSessionSnapshot: browserSessionSnapshot,
            hlsVariantPreferences: resource.hlsVariantPreferences ?? HLSVariantSelectionPreferences(),
            cachedManifestText: resource.manifestText,
            dashVideoRepresentationID: resource.dashVideoRepresentationID,
            dashAudioRepresentationID: resource.dashAudioRepresentationID
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
public final class URLSessionStreamingManifestLoader: StreamingManifestLoader, @unchecked Sendable {
    public static let sharedSession: URLSession = ForegroundURLSession.make()
    private let session: URLSession

    public init(session: URLSession = URLSessionStreamingManifestLoader.sharedSession) {
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
        if let s = candidate.browserSessionSnapshot {
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

        request = DownloadRequestEnricher.enrich(request, snapshot: effectiveSnapshot, context: candidate.browserRequestContext)

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
                let isDowngrade = candidate.url.scheme?.lowercased() == "http" && (URL(string: ref)?.scheme?.lowercased() == "https")
                if !isDowngrade {
                    request.setValue(ref, forHTTPHeaderField: "Referer")
                }
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

    private func registerActiveRequest(transferID: String, requestID: String) {
        lock.lock()
        defer { lock.unlock() }
        activeRequestIDs[transferID, default: []].insert(requestID)
    }

    private func unregisterActiveRequest(transferID: String, requestID: String) {
        lock.lock()
        defer { lock.unlock() }
        activeRequestIDs[transferID]?.remove(requestID)
        if activeRequestIDs[transferID]?.isEmpty == true {
            activeRequestIDs.removeValue(forKey: transferID)
        }
    }

    private func getActiveRequestIDs(for transferID: String) -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return activeRequestIDs[transferID] ?? []
    }

    public func execute(
        _ request: StreamingSegmentTransferRequest,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
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
            }
        )
        registerActiveRequest(transferID: request.identity.transferID, requestID: request.identity.value)
        defer {
            unregisterActiveRequest(transferID: request.identity.transferID, requestID: request.identity.value)
        }

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
        } catch {
            PipelineLogger.shared.log("[DownloadCoordinatorSegmentExecutor] Failed segment \(request.identity.order): \(error)")
            throw error
        }
    }

    public func cancel(transferID: String) async {
        let ids = getActiveRequestIDs(for: transferID)
        for id in ids {
            try? await coordinator.cancel(id: id, deleteDestinationFile: false)
        }
    }
}

/// Standalone segment executor using URLSession for environments where DownloadCoordinator is not yet injected.
public final class URLSessionStreamingSegmentExecutor: StreamingSegmentExecutor, @unchecked Sendable {
    public static let sharedSession: URLSession = ForegroundURLSession.make()

    private let session: URLSession
    private let lock = NSLock()
    private var activeTasks: [String: Set<URLSessionDownloadTask>] = [:]

    public init(session: URLSession? = nil) {
        self.session = session ?? Self.sharedSession
    }

    private func registerActiveTask(transferID: String, task: URLSessionDownloadTask) {
        lock.lock()
        defer { lock.unlock() }
        activeTasks[transferID, default: []].insert(task)
    }

    private func unregisterActiveTask(transferID: String, task: URLSessionDownloadTask) {
        lock.lock()
        defer { lock.unlock() }
        activeTasks[transferID]?.remove(task)
        if activeTasks[transferID]?.isEmpty == true {
            activeTasks.removeValue(forKey: transferID)
        }
    }

    private func takeActiveTasks(for transferID: String) -> Set<URLSessionDownloadTask> {
        lock.lock()
        defer { lock.unlock() }
        return activeTasks.removeValue(forKey: transferID) ?? []
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

        let fileManager = FileManager.default
        if let mime = httpResponse.mimeType?.lowercased(), mime.contains("text/html") {
            try? fileManager.removeItem(at: tempURL)
            throw StreamingDownloadOrchestratorError.segmentTransferFailed(order: request.identity.order)
        }
        if let handle = try? FileHandle(forReadingFrom: tempURL) {
            let headerBytes = (try? handle.read(upToCount: 512)) ?? Data()
            try? handle.close()
            if StreamingDownloadOrchestrator.isHTMLResponse(headerBytes) {
                try? fileManager.removeItem(at: tempURL)
                throw StreamingDownloadOrchestratorError.segmentTransferFailed(order: request.identity.order)
            }
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
                    _ = try? fileManager.removeItem(at: backupURL)
                } catch {
                    _ = try? fileManager.moveItem(at: backupURL, to: request.destinationURL)
                    throw error
                }
            }
            #else
            let backupURL = parentDir.appendingPathComponent(".backup-\(UUID().uuidString)-\(request.destinationURL.lastPathComponent)")
            try fileManager.moveItem(at: request.destinationURL, to: backupURL)
            do {
                try fileManager.moveItem(at: tempURL, to: request.destinationURL)
                _ = try? fileManager.removeItem(at: backupURL)
            } catch {
                _ = try? fileManager.moveItem(at: backupURL, to: request.destinationURL)
                throw error
            }
            #endif
        } else {
            try fileManager.moveItem(at: tempURL, to: request.destinationURL)
        }
        progress?(1.0)
    }

    public func cancel(transferID: String) async {
        let tasks = takeActiveTasks(for: transferID)
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
public actor StreamingDownloadOrchestrator {
    public static func createDefault() -> StreamingDownloadOrchestrator {
        StreamingDownloadOrchestrator(segmentExecutor: URLSessionStreamingSegmentExecutor())
    }

    /// The application composition root must install the configured instance.
    /// There is intentionally no default here: a standalone orchestrator has
    /// no DownloadEngine and would make a stream invisible to Downloads.
    @MainActor public static var shared: StreamingDownloadOrchestrator?

    private let manifestLoader: any StreamingManifestLoader
    private let segmentExecutor: any StreamingSegmentExecutor
    private let parsingLimits: ManifestParsingLimits
    public var urlResolver: (any BrowserMediaURLResolver)?
    public var downloadEngine: DownloadEngine?
    /// Durable store for HLS parent-transfer records. `nil` when persistence is unavailable.
    public var hlsPersistenceStore: HLSPersistenceStore?
    private var proposals: [String: StreamingTransferProposal] = [:]
    private var runningTransfers: Set<String> = []
    private var activeAssemblyOperations: Set<String> = []
    private var activeAssemblyDirectories: [String: URL] = [:]
    private var completedTransfers: [String: StreamingTransferResult] = [:]
    private var pausedTransfers: Set<String> = []
    private var cancelledTransfers: Set<String> = []
    private var registeredTransferIDs: [String: String] = [:]
    private var candidatesByTransfer: [String: StreamingManifestCandidate] = [:]
    private var cachedManifestTextsByURL: [String: String] = [:]

    public func recordCachedManifest(text: String, for url: URL) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\u{FEFF}", with: "")
        guard !normalized.isEmpty else { return }
        cachedManifestTextsByURL[url.absoluteString] = normalized
        cachedManifestTextsByURL[url.absoluteString.lowercased()] = normalized
    }

    /// HLS uses the proposal transfer ID as its durable parent ID. Proposal
    /// IDs are deterministic digests and therefore safe for queue and metadata
    /// filenames; manifest URLs are not.
    private func hlsParentID(for proposal: StreamingTransferProposal) -> String {
        proposal.transferID
    }

    private func hlsParentID(for transferID: String) -> String {
        registeredTransferIDs[transferID] ?? transferID
    }

    private func persistenceFailure(_ error: Error) -> StreamingDownloadOrchestratorError {
        .persistenceFailed(error.localizedDescription)
    }

    private func persistHLSState(
        id: String,
        state: HLSTransferState
    ) async throws {
        guard let persistence = hlsPersistenceStore else { return }
        do {
            _ = try await persistence.updateState(id: id, state: state)
        } catch {
            PipelineLogger.shared.log(
                "[HLS Pipeline] Failed to persist state \(state) for \(id): \(error.localizedDescription)"
            )
            throw persistenceFailure(error)
        }
    }

    private func persistHLSAssemblyState(
        id: String,
        state: HLSAssemblyState
    ) async throws {
        guard let persistence = hlsPersistenceStore else { return }
        do {
            _ = try await persistence.updateAssemblyState(id: id, assemblyState: state)
        } catch {
            PipelineLogger.shared.log(
                "[HLS Pipeline] Failed to persist assembly state \(state) for \(id): \(error.localizedDescription)"
            )
            throw persistenceFailure(error)
        }
    }

    private func persistHLSStateBestEffort(
        id: String,
        state: HLSTransferState,
        context: String
    ) async {
        do {
            try await persistHLSState(id: id, state: state)
        } catch {
            PipelineLogger.shared.log(
                "[HLS Pipeline] Could not persist \(context) for \(id): \(error.localizedDescription)"
            )
        }
    }

    private func handleHLSCancellation(
        parentID: String,
        transferID: String,
        proposal: StreamingTransferProposal? = nil
    ) async {
        await segmentExecutor.cancel(transferID: transferID)
        await persistHLSStateBestEffort(
            id: parentID,
            state: .cancelled,
            context: "cancellation state"
        )
        if let proposal {
            await cleanupHLSChildRecords(proposal: proposal)
        }
        if let persistence = hlsPersistenceStore {
            do {
                if let record = try await persistence.load(id: parentID) {
                    await purgeInternalStreamingSegmentRecords(in: record.segmentDirectoryURL)
                }
            } catch {
                PipelineLogger.shared.log(
                    "[HLS Pipeline] Could not load cancelled transfer \(parentID) for child cleanup: \(error.localizedDescription)"
                )
            }
        }
    }

    public func isManaging(id: String) -> Bool {
        return runningTransfers.contains(id) ||
               pausedTransfers.contains(id) ||
               completedTransfers[id] != nil ||
               registeredTransferIDs[id] != nil ||
               registeredTransferIDs.values.contains(id)
    }

    public func pause(transferID: String) async throws {
        runningTransfers.remove(transferID)
        pausedTransfers.insert(transferID)
        if let mapped = registeredTransferIDs[transferID] {
            runningTransfers.remove(mapped)
            pausedTransfers.insert(mapped)
        }
        for (k, v) in registeredTransferIDs where v == transferID {
            runningTransfers.remove(k)
            pausedTransfers.insert(k)
        }
        try await persistHLSState(
            id: hlsParentID(for: transferID),
            state: .paused
        )
        PipelineLogger.shared.log("[HLS Pipeline] Paused transfer: \(transferID)")
    }

    public func resume(transferID: String) async throws {
        pausedTransfers.remove(transferID)
        runningTransfers.insert(transferID)
        if let mapped = registeredTransferIDs[transferID] {
            pausedTransfers.remove(mapped)
            runningTransfers.insert(mapped)
        }
        for (k, v) in registeredTransferIDs where v == transferID {
            pausedTransfers.remove(k)
            runningTransfers.insert(k)
        }
        try await persistHLSState(
            id: hlsParentID(for: transferID),
            state: .downloading
        )
        PipelineLogger.shared.log("[HLS Pipeline] Resumed transfer: \(transferID)")
    }

    public func cancel(transferID: String) async {
        runningTransfers.remove(transferID)
        pausedTransfers.remove(transferID)
        cancelledTransfers.insert(transferID)
        if let mapped = registeredTransferIDs[transferID] {
            runningTransfers.remove(mapped)
            pausedTransfers.remove(mapped)
            cancelledTransfers.insert(mapped)
        }
        for (k, v) in registeredTransferIDs where v == transferID {
            runningTransfers.remove(k)
            pausedTransfers.remove(k)
            cancelledTransfers.insert(k)
        }
        let parentID = hlsParentID(for: transferID)
        let proposal = proposals[parentID] ?? proposals[transferID]
        await handleHLSCancellation(
            parentID: parentID,
            transferID: parentID,
            proposal: proposal
        )
        PipelineLogger.shared.log("[HLS Pipeline] Cancelled transfer: \(transferID)")
    }

    public func pauseAll() async {
        let running = Array(runningTransfers)
        for id in running {
            try? await pause(transferID: id)
        }
    }

    public func resumeAll() async {
        let paused = Array(pausedTransfers)
        for id in paused {
            try? await resume(transferID: id)
        }
    }

    public func cancelAll() async {
        var targets = runningTransfers.union(pausedTransfers)
        for id in registeredTransferIDs.values {
            if completedTransfers[id] == nil && !cancelledTransfers.contains(id) {
                targets.insert(id)
            }
        }
        for id in targets {
            await cancel(transferID: id)
        }
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
        downloadEngine: DownloadEngine? = nil,
        hlsPersistenceStore: HLSPersistenceStore? = nil
    ) {
        self.configuration = configuration
        self.manifestLoader = manifestLoader
        self.segmentExecutor = segmentExecutor
        self.parsingLimits = parsingLimits
        self.urlResolver = urlResolver
        self.downloadEngine = downloadEngine
        self.hlsPersistenceStore = hlsPersistenceStore
    }

    public init(
        configuration: EngineConfiguration = .default,
        downloadCoordinator: DownloadCoordinator,
        downloadEngine: DownloadEngine? = nil,
        manifestLoader: any StreamingManifestLoader = URLSessionStreamingManifestLoader(),
        parsingLimits: ManifestParsingLimits = .default,
        retryCount: Int? = nil,
        urlResolver: (any BrowserMediaURLResolver)? = nil,
        hlsPersistenceStore: HLSPersistenceStore? = nil
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
            downloadEngine: downloadEngine,
            hlsPersistenceStore: hlsPersistenceStore
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

    public func setHLSPersistenceStore(_ store: HLSPersistenceStore?) {
        self.hlsPersistenceStore = store
    }

    private func purgeInternalStreamingSegmentRecords(in directory: URL? = nil) async {
        guard let engine = downloadEngine,
              let records = try? await engine.persistenceStore.fetchAll() else { return }
        let directoryPath = directory?.standardizedFileURL.path
        for record in records where record.isStreamingSegment {
            if let directoryPath,
               !record.destinationURL.standardizedFileURL.path.hasPrefix(directoryPath + "/") {
                continue
            }
            try? await engine.persistenceStore.delete(tag: record.id)
        }
    }

    private func purgeOrphanAssemblyDirectories(records: [HLSTransferRecord]) async {
        let fileManager = FileManager.default
        var activeDirectories = Set(
            records
                .filter { $0.state == .downloading || $0.state == .paused }
                .map { $0.segmentDirectoryURL.standardizedFileURL.path }
        )
        for url in activeAssemblyDirectories.values {
            activeDirectories.insert(url.standardizedFileURL.path)
        }
        for runId in runningTransfers {
            if let record = records.first(where: { $0.id == runId }) {
                activeDirectories.insert(record.segmentDirectoryURL.standardizedFileURL.path)
            }
        }
        for runId in activeAssemblyOperations {
            if let record = records.first(where: { $0.id == runId }) {
                activeDirectories.insert(record.segmentDirectoryURL.standardizedFileURL.path)
            }
        }

        let parentDirectories = Set(records.map {
            $0.segmentDirectoryURL.deletingLastPathComponent().standardizedFileURL
        })

        for parent in parentDirectories {
            guard let children = try? fileManager.contentsOfDirectory(
                at: parent,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            ) else { continue }
            for child in children where child.lastPathComponent.hasPrefix(".assembly_temp_") {
                let path = child.standardizedFileURL.path
                guard !activeDirectories.contains(path) else {
                    PipelineLogger.shared.log("[HLS Recovery] Preserving active assembly directory: \(path)")
                    continue
                }

                // Minimum age grace period: do not delete directories created or modified within 2 hours (7200 seconds)
                let attrs = try? fileManager.attributesOfItem(atPath: child.path)
                let modDate = (attrs?[.modificationDate] as? Date) ?? (attrs?[.creationDate] as? Date) ?? Date.distantPast
                let age = Date().timeIntervalSince(modDate)
                guard age > 7200 else {
                    PipelineLogger.shared.log("[HLS Recovery] Assembly directory \(path) was modified recently (\(Int(age))s ago < 7200s grace period). Preserving.")
                    continue
                }

                do {
                    try fileManager.removeItem(at: child)
                    PipelineLogger.shared.log("[HLS Recovery] Removed orphaned assembly directory: \(path)")
                } catch {
                    PipelineLogger.shared.log("[HLS Recovery] Failed to remove orphaned assembly directory \(path): \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - HLS Startup Recovery

    /// Restores durable HLS transfer records into the `DownloadEngine` after an app restart.
    ///
    /// Call this once during app startup, **after** `DownloadEngine` has been injected
    /// and the queue has been restored via `DownloadEngine.restoreQueue()`.
    ///
    /// For each active HLS record (`downloading` or `paused` state) whose parent
    /// download entry is no longer present in the engine queue, this method re-registers
    /// the parent entry so the Downloads UI shows one video, not nothing.
    ///
    /// Records in `completed`, `failed`, or `cancelled` state are not re-added to the
    /// active queue; they remain visible via the standard `DownloadRecord` in
    /// `DownloadPersistenceStore`.
    public func restoreHLSTransfers(resumeInterrupted: Bool = false) async {
        guard let persistence = hlsPersistenceStore else { return }
        guard let engine = downloadEngine else { return }

        let records: [HLSTransferRecord]
        do {
            records = try await persistence.loadAll()
        } catch {
            PipelineLogger.shared.log("[HLS Recovery] Failed to load HLS records: \(error.localizedDescription)")
            return
        }

        // Segment requests are implementation details. The parent HLS job
        // checkpoint is sufficient to resume them, so never restore child
        // DownloadRecord entries into the durable download store.
        await purgeInternalStreamingSegmentRecords()
        await purgeOrphanAssemblyDirectories(records: records)

        PipelineLogger.shared.log("[HLS Recovery] Found \(records.count) persisted HLS record(s).")

        for record in records {
            let manifestKey = record.manifestURL.absoluteString
            registeredTransferIDs[manifestKey] = record.id
            registeredTransferIDs[record.id] = record.id
        }

        for record in records where record.state == .downloading || record.state == .paused {
            // Check whether the parent download is already in the engine queue.
            let existingSnap = await engine.snapshot(for: record.id)
            if existingSnap != nil {
                // Already present — restore our in-memory registeredTransferIDs so
                // pause/resume/cancel routing still works.
                let manifestKey = record.manifestURL.absoluteString
                registeredTransferIDs[manifestKey] = record.id
                registeredTransferIDs[record.id] = record.id
                PipelineLogger.shared.log("[HLS Recovery] Transfer \(record.id) already in engine queue. Skipping re-registration.")
                if resumeInterrupted, record.state == .downloading {
                    let isRunningInMemory = runningTransfers.contains(record.id) || activeAssemblyOperations.contains(record.id)
                    let isEngineActive = existingSnap?.state == .downloading || existingSnap?.state == .pending || existingSnap?.state == .probing
                    if isRunningInMemory || isEngineActive {
                        PipelineLogger.shared.log("[HLS Recovery] Transfer \(record.id) is currently actively executing (engine state: \(String(describing: existingSnap?.state))). Skipping duplicate resume.")
                    } else {
                        Task { await self.resumePersistedHLS(record) }
                    }
                }
                continue
            }

            // Re-register the parent download entry so the UI shows one video row.
            do {
                let estimatedTotal = Int64(record.totalSegments) * 1_000_000
                _ = try await engine.registerStreamingDownload(
                    id: record.id,
                    manifestURL: record.manifestURL,
                    destinationURL: record.outputDestinationURL,
                    filename: record.outputFilename,
                    totalBytes: estimatedTotal,
                    mimeType: "video/mp4"
                )

                // Wire routing so orchestrator can route pause/resume/cancel.
                let manifestKey = record.manifestURL.absoluteString
                registeredTransferIDs[manifestKey] = record.id
                registeredTransferIDs[record.id] = record.id

                // If it was paused, mark that immediately.
                if record.state == .paused {
                    await engine.queueManager.pauseStreaming(id: record.id)
                    pausedTransfers.insert(record.id)
                }

                let segsDone = record.completedSegmentOrders.count
                let segsTotal = record.totalSegments
                PipelineLogger.shared.log("[HLS Recovery] Re-registered \(record.outputFilename) (\(segsDone)/\(segsTotal) segments).")
                if resumeInterrupted, record.state == .downloading {
                    let isRunningInMemory = runningTransfers.contains(record.id) || activeAssemblyOperations.contains(record.id)
                    if isRunningInMemory {
                        PipelineLogger.shared.log("[HLS Recovery] Transfer \(record.id) is already running in memory. Skipping duplicate resume.")
                    } else {
                        Task { await self.resumePersistedHLS(record) }
                    }
                }
            } catch {
                PipelineLogger.shared.log("[HLS Recovery] Failed to re-register \(record.id): \(error.localizedDescription)")
            }
        }

        // Cleanup records for transfers that have been completed/cancelled/failed and
        // whose output file has already been removed from disk by the user.
        for record in records where record.state == .completed {
            if !FileManager.default.fileExists(atPath: record.outputDestinationURL.path) {
                do {
                    try await persistence.delete(id: record.id)
                    PipelineLogger.shared.log("[HLS Recovery] Pruned stale completed record: \(record.id)")
                } catch {
                    PipelineLogger.shared.log("[HLS Recovery] Warning: Failed to prune stale completed record \(record.id): \(error.localizedDescription)")
                }
            }
        }
    }

    /// Rebuilds the in-memory proposal from the durable manifest URL and
    /// resumes an interrupted parent using its original segment directory and
    /// output destination. Browser credentials are intentionally not loaded
    /// from disk; the normal loader/keychain path supplies them when available.
    private func resumePersistedHLS(_ record: HLSTransferRecord) async {
        guard !runningTransfers.contains(record.id), !activeAssemblyOperations.contains(record.id) else {
            PipelineLogger.shared.log("[HLS Recovery] Transfer \(record.id) is already running or assembling. Aborting duplicate resume.")
            return
        }
        do {
            let candidate = try StreamingManifestCandidate(url: record.manifestURL)
            let proposal = try await prepare(candidate: candidate)
            guard case .hls = proposal.manifest else { return }
            _ = try await executeAndAssembleHLS(
                proposal,
                approved: true,
                destinationDirectory: record.segmentDirectoryURL,
                outputURL: record.outputDestinationURL,
                runID: record.id
            )
        } catch {
            PipelineLogger.shared.log("[HLS Recovery] Could not resume \(record.id): \(error.localizedDescription)")
        }
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
        if let jsMsg = nsError.userInfo["WKErrorJavaScriptExceptionMessageKey"] as? String, !jsMsg.isEmpty {
            return jsMsg
        }
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
        if let cached = cachedManifestTextsByURL[candidate.url.absoluteString] ?? cachedManifestTextsByURL[candidate.url.absoluteString.lowercased()],
           !cached.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let normalized = cached.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\u{FEFF}", with: "")
            let data = Data(normalized.utf8)
            if data.count <= parsingLimits.maxBytes && !Self.isHTMLResponse(data) {
                let classification = StreamingManifestClassifier.classify(
                    url: candidate.url,
                    mimeType: candidate.mimeType,
                    content: data,
                    limits: parsingLimits
                )
                if classification.isManifest {
                    PipelineLogger.shared.log("[HLS Pipeline] Step 1: Using cached manifest text from hook for \(candidate.url.absoluteString) (\(normalized.count) chars). Bypassing network fetch.")
                    return StreamingManifestResponse(
                        data: data,
                        finalURL: candidate.url,
                        mimeType: candidate.mimeType,
                        statusCode: 200
                    )
                }
            }
        }

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
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as StreamingDownloadOrchestratorError {
            throw error
        } catch let error as ManifestParserError {
            PipelineLogger.shared.log("[HLS Pipeline] Error: Manifest parser failed: \(error.localizedDescription)")
            throw error
        } catch {
            guard !Task.isCancelled else {
                throw CancellationError()
            }
            let status = manifestStatusDescription(for: error)
            PipelineLogger.shared.log("[HLS Pipeline] Step 1: URLSession manifest fetch (status: \(status))")
            if let resolver = self.urlResolver {
                do {
                    let text = try await resolver.fetchManifestText(from: candidate.url, maxBytes: parsingLimits.maxBytes)
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else {
                        let jsReason = "Empty manifest response"
                        PipelineLogger.shared.log("[HLS Pipeline] Step 1b: JS fetch fallback (status: \(jsReason))")
                        let combinedMessage = "Manifest \(status); browser fetch failed: \(jsReason)"
                        PipelineLogger.shared.log("[HLS Pipeline] Error: \(combinedMessage)")
                        throw StreamingManifestLoadError.failed(combinedMessage)
                    }
                    let data = Data(trimmed.utf8)
                    if data.count > parsingLimits.maxBytes {
                        throw ManifestParserError.inputTooLarge(limit: parsingLimits.maxBytes)
                    }
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
                } catch is CancellationError {
                    throw CancellationError()
                } catch let parserErr as ManifestParserError {
                    PipelineLogger.shared.log("[HLS Pipeline] Error: Manifest size limit reached on JS fetch fallback: \(parserErr.localizedDescription)")
                    throw parserErr
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
                    guard !Task.isCancelled else {
                        throw CancellationError()
                    }
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
        var fingerprintComponents = [candidate.url.absoluteString, candidateMIME]
        if let context = candidate.browserRequestContext {
            fingerprintComponents.append(context.userAgent ?? "")
            fingerprintComponents.append(context.referer ?? "")
            let cookieDesc = context.cookies.map { "\($0.name)=\($0.value)" }.sorted().joined(separator: ";")
            fingerprintComponents.append(cookieDesc)
            if !context.customHeaders.isEmpty {
                let headerDesc = context.customHeaders.sorted(by: { $0.key < $1.key }).map { "\($0.key):\($0.value)" }.joined(separator: "\n")
                fingerprintComponents.append(headerDesc)
            }
        }
        if let snapshot = candidate.browserSessionSnapshot {
            fingerprintComponents.append(snapshot.userAgent)
            let cookieDesc = snapshot.allCookies.map { "\($0.name)=\($0.value)" }.sorted().joined(separator: ";")
            fingerprintComponents.append(cookieDesc)
        }
        let metadataFingerprint = EngineSHA256.hash(
            data: Data(fingerprintComponents.joined(separator: "|").utf8)
        )
        if let existing = proposals[metadataFingerprint] {
            return existing
        }

        let headers = manifestHeaders(for: candidate)
        var parsedManifest: StreamingTransferManifest?
        var manifestData: Data?

        let rawCachedText = candidate.cachedManifestText ?? cachedManifestTextsByURL[candidate.url.absoluteString] ?? cachedManifestTextsByURL[candidate.url.absoluteString.lowercased()]
        if let rawCachedText, !rawCachedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let normalizedText = rawCachedText.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\u{FEFF}", with: "")
            let cachedData = Data(normalizedText.utf8)
            if cachedData.count <= parsingLimits.maxBytes && !Self.isHTMLResponse(cachedData) {
                let classification = StreamingManifestClassifier.classify(
                    url: candidate.url,
                    mimeType: candidate.mimeType,
                    content: cachedData,
                    limits: parsingLimits
                )
                if classification.isManifest {
                    do {
                        PipelineLogger.shared.log("[Streaming Pipeline] Step 1: Using cached manifest text from network hook (\(normalizedText.count) chars). Skipping network fetch.")
                        let manifest = try await parseManifest(
                            data: cachedData,
                            finalURL: candidate.url,
                            mimeType: candidate.mimeType,
                            candidate: candidate,
                            classification: classification
                        )
                        parsedManifest = manifest
                        manifestData = cachedData
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch let error as StreamingDownloadOrchestratorError {
                        throw error
                    } catch let error as HLSVODTransferPlanError {
                        if case .unsupportedEncryption = error {
                            throw StreamingDownloadOrchestratorError.unsupportedEncryption
                        }
                        throw StreamingDownloadOrchestratorError.hlsPlanningFailed(error)
                    } catch let error as DASHVODTransferPlanError {
                        if case .drmProtectedRepresentation = error {
                            throw StreamingDownloadOrchestratorError.unsupportedEncryption
                        }
                        throw StreamingDownloadOrchestratorError.dashPlanningFailed(error)
                    } catch let error as StreamingManifestLoadError {
                        throw error
                    } catch let error as URLError {
                        throw error
                    } catch let error as ManifestParserError {
                        PipelineLogger.shared.log("[Streaming Pipeline] Cached manifest text failed to parse (\(error.localizedDescription)). Falling back to network loader.")
                    } catch {
                        PipelineLogger.shared.log("[Streaming Pipeline] Error during cached manifest processing: \(error.localizedDescription)")
                        throw error
                    }
                } else {
                    PipelineLogger.shared.log("[Streaming Pipeline] Cached manifest text not recognized as valid manifest. Falling back to network loader.")
                }
            } else {
                PipelineLogger.shared.log("[Streaming Pipeline] Cached manifest text was HTML or exceeded byte limits (\(cachedData.count) bytes). Falling back to network loader.")
            }
        }

        if parsedManifest == nil {
            let response: StreamingManifestResponse
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

            do {
                let manifest = try await parseManifest(
                    data: response.data,
                    finalURL: response.finalURL,
                    mimeType: response.mimeType ?? candidate.mimeType,
                    candidate: candidate,
                    classification: classification
                )
                parsedManifest = manifest
                manifestData = response.data
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
                if case .drmProtectedRepresentation = error {
                    throw StreamingDownloadOrchestratorError.unsupportedEncryption
                }
                throw StreamingDownloadOrchestratorError.dashPlanningFailed(error)
            }
        }

        guard let manifest = parsedManifest, let finalData = manifestData else {
            throw StreamingDownloadOrchestratorError.manifestNotRecognized
        }

        // Derive the parent ID from the candidate URL, not the redirected or
        // signed response URL. A refreshed manifest must recover the same
        // parent even when its CDN query token has changed.
        let transferID = "stream-\(metadataFingerprint.prefix(32))"
        let resources = try makeResources(from: manifest, transferID: transferID)
        guard !resources.isEmpty else {
            throw StreamingDownloadOrchestratorError.noTransferResources
        }
        let proposal = StreamingTransferProposal(
            transferID: transferID,
            manifestID: EngineSHA256.hash(data: finalData),
            manifest: manifest,
            resources: resources,
            estimatedTransferBytes: estimatedBytes(for: manifest)
        )
        proposals[metadataFingerprint] = proposal
        proposals[proposal.transferID] = proposal
        candidatesByTransfer[proposal.transferID] = candidate
        let masterKey = candidate.url.absoluteString
        let variantKey = proposal.manifest.manifestURL.absoluteString
        registeredTransferIDs[masterKey] = proposal.transferID
        registeredTransferIDs[variantKey] = proposal.transferID
        registeredTransferIDs[proposal.transferID] = masterKey
        return proposal
    }

    private struct ResolvedHLSSelection {
        let mediaPlaylist: HLSManifest
        let mediaURL: URL
        let selectedVariant: HLSVariant?
        let selectedVariantBandwidth: Int?
        let videoPlan: HLSVODTransferPlan
        let audioPlan: [HLSPlannedResource]?
        let selectedSubtitleRendition: HLSRendition?
    }

    private func resolveCompatibleHLSVariant(
        manifest: HLSManifest,
        baseURL: URL,
        candidate: StreamingManifestCandidate,
        depth: Int = 0
    ) async throws -> ResolvedHLSSelection {
        guard depth < 5 else {
            throw StreamingDownloadOrchestratorError.playlistRequiresVariantSelection
        }
        guard manifest.playlistType == .master else {
            // Already a media playlist: validate directly
            let videoPlan: HLSVODTransferPlan
            do {
                videoPlan = try HLSTransferPlanner.makeVODPlan(
                    from: manifest,
                    browserRequestContext: candidate.browserRequestContext
                )
            } catch let error as HLSVODTransferPlanError {
                if case .unsupportedEncryption = error {
                    throw StreamingDownloadOrchestratorError.unsupportedEncryption
                }
                throw StreamingDownloadOrchestratorError.hlsPlanningFailed(error)
            }
            return ResolvedHLSSelection(
                mediaPlaylist: manifest,
                mediaURL: baseURL,
                selectedVariant: nil,
                selectedVariantBandwidth: nil,
                videoPlan: videoPlan,
                audioPlan: nil,
                selectedSubtitleRendition: nil
            )
        }

        let rankedVariants: [HLSVariant]
        do {
            rankedVariants = try HLSVariantSelector.rank(
                from: manifest,
                preferences: candidate.hlsVariantPreferences
            )
        } catch let error as HLSVariantSelectionError {
            PipelineLogger.shared.log("[HLS Pipeline] Error during variant ranking: \(error.localizedDescription)")
            throw StreamingDownloadOrchestratorError.hlsVariantSelectionFailed(error)
        }

        PipelineLogger.shared.log("[HLS Pipeline] Master playlist detected [depth=\(depth)]. Discovered \(manifest.variants.count) variants; \(rankedVariants.count) eligible variants ranked by preference.")
        BrowserDiagnosticLogger.shared.log(
            category: .policy,
            message: "HLS variants discovered and ranked",
            url: baseURL,
            details: [
                "discoveredVariants": "\(manifest.variants.count)",
                "rankedVariants": "\(rankedVariants.count)",
                "depth": "\(depth)"
            ]
        )

        var sawUnsupportedEncryption = false
        var lastPlanningError: Error? = nil

        for (index, variant) in rankedVariants.enumerated() {
            guard !Task.isCancelled else {
                throw CancellationError()
            }
            let variantResolution = variant.resolution.map { "\($0.width)x\($0.height)" } ?? "unknown"
            let variantDesc = "Variant #\(index + 1)/\(rankedVariants.count) [bw=\(variant.bandwidth), res=\(variantResolution), codecs=\(variant.codecs ?? "none")]"
            PipelineLogger.shared.log("[HLS Pipeline] Evaluating \(variantDesc) at \(variant.uri.absoluteString)...")

            do {
                try HLSVariantSelector.validateAudioLayout(
                    selectedVariant: variant,
                    master: manifest
                )
            } catch {
                PipelineLogger.shared.log("[HLS Pipeline] Audio layout validation failed for \(variantDesc): \(error.localizedDescription)")
                continue
            }

            let selectedAudioRendition = HLSVariantSelector.selectAudioRendition(
                for: variant,
                master: manifest
            )
            var selectedSubtitleRendition: HLSRendition? = nil
            if let subGroup = variant.subtitlesGroup {
                selectedSubtitleRendition = manifest.renditions.first {
                    $0.type.uppercased() == "SUBTITLES" && $0.groupID == subGroup && $0.uri != nil
                }
            }
            if selectedSubtitleRendition == nil {
                selectedSubtitleRendition = manifest.renditions.first {
                    $0.type.uppercased() == "SUBTITLES" && $0.uri != nil
                }
            }

            let variantURI: URL
            if (variant.uri.query == nil || variant.uri.query?.isEmpty == true),
               let parentQuery = baseURL.query ?? candidate.url.query, !parentQuery.isEmpty,
               var components = URLComponents(url: variant.uri, resolvingAgainstBaseURL: false) {
                components.query = parentQuery
                variantURI = components.url ?? variant.uri
            } else {
                variantURI = variant.uri
            }

            let variantCachedText = cachedManifestTextsByURL[variantURI.absoluteString] ?? cachedManifestTextsByURL[variantURI.absoluteString.lowercased()]
            let variantCandidate = try StreamingManifestCandidate(
                url: variantURI,
                mimeType: "application/vnd.apple.mpegurl",
                browserRequestContext: candidate.browserRequestContext,
                browserSessionSnapshot: candidate.browserSessionSnapshot,
                hlsVariantPreferences: candidate.hlsVariantPreferences,
                cachedManifestText: variantCachedText
            )

            let subResponse: StreamingManifestResponse
            do {
                subResponse = try await loadManifestResponse(
                    candidate: variantCandidate,
                    headers: manifestHeaders(for: variantCandidate)
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as StreamingManifestLoadError {
                // Do not downgrade on HTTP 401/403 authentication, 404/410, or network load errors!
                PipelineLogger.shared.log("[HLS Pipeline] Network/Auth error loading variant playlist: \(error.localizedDescription). Aborting without downgrade.")
                throw error
            } catch let error as URLError {
                PipelineLogger.shared.log("[HLS Pipeline] URLError loading variant playlist: \(error.localizedDescription). Aborting without downgrade.")
                throw error
            } catch {
                PipelineLogger.shared.log("[HLS Pipeline] Unexpected error loading variant playlist: \(error.localizedDescription). Aborting without downgrade.")
                throw error
            }

            let parsedChild: HLSManifest
            do {
                parsedChild = try HLSManifestParser.parse(
                    subResponse.data,
                    baseURL: subResponse.finalURL,
                    limits: parsingLimits
                )
            } catch let error as ManifestParserError {
                PipelineLogger.shared.log("[HLS Pipeline] Child variant playlist failed to parse: \(error.localizedDescription). Aborting without downgrade.")
                throw StreamingDownloadOrchestratorError.manifestParseFailed(error)
            }

            if parsedChild.playlistType == .master {
                // Nested master playlist: recursively evaluate compatible variant
                do {
                    return try await resolveCompatibleHLSVariant(
                        manifest: parsedChild,
                        baseURL: subResponse.finalURL,
                        candidate: variantCandidate,
                        depth: depth + 1
                    )
                } catch StreamingDownloadOrchestratorError.unsupportedEncryption {
                    sawUnsupportedEncryption = true
                    PipelineLogger.shared.log("[HLS Pipeline] Nested master playlist rejected due to unsupported encryption. Trying next variant...")
                    BrowserDiagnosticLogger.shared.log(
                        category: .policy,
                        message: "Nested HLS master playlist rejected due to unsupported encryption",
                        url: variantURI,
                        details: [
                            "bandwidth": "\(variant.bandwidth)",
                            "resolution": variantResolution,
                            "decision": "rejected",
                            "reason": "Unsupported encryption in nested master"
                        ]
                    )
                    continue
                } catch {
                    throw error
                }
            }

            guard parsedChild.playlistType == .media else {
                PipelineLogger.shared.log("[HLS Pipeline] Expected media playlist for variant but got \(parsedChild.playlistType). Trying next variant...")
                continue
            }

            // Evaluate download compatibility with HLSTransferPlanner
            let videoPlan: HLSVODTransferPlan
            do {
                videoPlan = try HLSTransferPlanner.makeVODPlan(
                    from: parsedChild,
                    browserRequestContext: candidate.browserRequestContext
                )
            } catch let error as HLSVODTransferPlanError {
                if case .unsupportedEncryption(let classification) = error {
                    sawUnsupportedEncryption = true
                    let reason = "Unsupported video encryption: \(classification.rawValue)"
                    PipelineLogger.shared.log("[HLS Pipeline] \(variantDesc) rejected: \(reason). Trying next variant...")
                    BrowserDiagnosticLogger.shared.log(
                        category: .policy,
                        message: "HLS variant rejected: \(reason)",
                        url: variantURI,
                        details: [
                            "bandwidth": "\(variant.bandwidth)",
                            "resolution": variantResolution,
                            "encryption": classification.rawValue,
                            "decision": "rejected",
                            "reason": reason
                        ]
                    )
                    continue
                }
                lastPlanningError = error
                PipelineLogger.shared.log("[HLS Pipeline] \(variantDesc) planning failed: \(error.localizedDescription). Trying next variant...")
                continue
            }

            // Evaluate audio rendition compatibility if present
            var audioPlan: [HLSPlannedResource]? = nil
            var audioFailedUnsupported = false
            if let audioURI = selectedAudioRendition?.uri {
                PipelineLogger.shared.log("[HLS Pipeline] Separate audio rendition detected for \(variantDesc): \(audioURI.absoluteString). Fetching audio manifest...")
                let audioFinalURI: URL
                if (audioURI.query == nil || audioURI.query?.isEmpty == true),
                   let parentQuery = subResponse.finalURL.query ?? candidate.url.query, !parentQuery.isEmpty,
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
                let audioResponse: StreamingManifestResponse
                do {
                    audioResponse = try await loadManifestResponse(
                        candidate: audioCandidate,
                        headers: manifestHeaders(for: audioCandidate)
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as StreamingManifestLoadError {
                    throw error
                } catch let error as URLError {
                    throw error
                } catch {
                    throw error
                }

                let parsedAudio: HLSManifest
                do {
                    parsedAudio = try HLSManifestParser.parse(
                        audioResponse.data,
                        baseURL: audioResponse.finalURL,
                        limits: parsingLimits
                    )
                } catch let error as ManifestParserError {
                    throw StreamingDownloadOrchestratorError.manifestParseFailed(error)
                }

                guard parsedAudio.playlistType == .media else {
                    PipelineLogger.shared.log("[HLS Pipeline] Separate audio playlist is not a media playlist. Trying next variant...")
                    continue
                }

                do {
                    let parsedAudioPlan = try HLSTransferPlanner.makeVODPlan(
                        from: parsedAudio,
                        browserRequestContext: candidate.browserRequestContext
                    )
                    audioPlan = parsedAudioPlan.resources
                } catch let error as HLSVODTransferPlanError {
                    if case .unsupportedEncryption(let classification) = error {
                        sawUnsupportedEncryption = true
                        audioFailedUnsupported = true
                        let reason = "Unsupported audio encryption: \(classification.rawValue)"
                        PipelineLogger.shared.log("[HLS Pipeline] \(variantDesc) rejected: \(reason). Trying next variant...")
                        BrowserDiagnosticLogger.shared.log(
                            category: .policy,
                            message: "HLS variant rejected: \(reason)",
                            url: variantURI,
                            details: [
                                "bandwidth": "\(variant.bandwidth)",
                                "resolution": variantResolution,
                                "encryption": classification.rawValue,
                                "decision": "rejected",
                                "reason": reason
                            ]
                        )
                    } else {
                        lastPlanningError = error
                    }
                }
            }

            if audioFailedUnsupported {
                continue
            }

            // Both video (and separate audio, if present) are compatible!
            let encryptionType = parsedChild.segments.first?.encryption?.classification.rawValue ?? "Clear"
            PipelineLogger.shared.log("[HLS Pipeline] Successfully selected compatible \(variantDesc) [encryption=\(encryptionType)].")
            BrowserDiagnosticLogger.shared.log(
                category: .policy,
                message: "HLS compatible variant selected",
                url: variantURI,
                details: [
                    "bandwidth": "\(variant.bandwidth)",
                    "resolution": variantResolution,
                    "encryption": encryptionType,
                    "decision": "accepted",
                    "selectedVariant": variantURI.absoluteString
                ]
            )

            return ResolvedHLSSelection(
                mediaPlaylist: parsedChild,
                mediaURL: subResponse.finalURL,
                selectedVariant: variant,
                selectedVariantBandwidth: variant.bandwidth,
                videoPlan: videoPlan,
                audioPlan: audioPlan,
                selectedSubtitleRendition: selectedSubtitleRendition
            )
        }

        if sawUnsupportedEncryption {
            PipelineLogger.shared.log("[HLS Pipeline] All evaluated variants use unsupported encryption.")
            throw StreamingDownloadOrchestratorError.unsupportedEncryption
        }
        if let planErr = lastPlanningError as? HLSVODTransferPlanError {
            throw StreamingDownloadOrchestratorError.hlsPlanningFailed(planErr)
        }
        throw StreamingDownloadOrchestratorError.playlistRequiresVariantSelection
    }

    private func parseManifest(
        data: Data,
        finalURL: URL,
        mimeType: String?,
        candidate: StreamingManifestCandidate,
        classification: StreamingManifestClassification
    ) async throws -> StreamingTransferManifest {
        switch classification.kind {
        case .hls:
            PipelineLogger.shared.log("[HLS Pipeline] 1. Manifest fetched from \(finalURL.absoluteString) (\(data.count) bytes). Parsing with HLSManifestParser...")
            let initialParsed = try HLSManifestParser.parse(
                data,
                baseURL: finalURL,
                limits: parsingLimits
            )
            PipelineLogger.shared.log("[HLS Pipeline] 2. HLSManifestParser initial parse completed: playlistType=\(initialParsed.playlistType), variants=\(initialParsed.variants.count), segments=\(initialParsed.segments.count)")

            let resolved = try await resolveCompatibleHLSVariant(
                manifest: initialParsed,
                baseURL: finalURL,
                candidate: candidate
            )

            let totalEstimatedBytes: Int64?
            if let videoBytes = resolved.videoPlan.estimatedTransferBytes {
                let audioBytes = resolved.audioPlan?.reduce(Int64(0)) { $0 + ($1.byteRange?.length ?? 0) } ?? 0
                totalEstimatedBytes = videoBytes + audioBytes
            } else if let bw = resolved.selectedVariantBandwidth, bw > 0 {
                let totalDuration = resolved.mediaPlaylist.segments.reduce(0.0) { $0 + $1.duration }
                let effectiveDuration = totalDuration > 0 ? totalDuration : (Double(resolved.mediaPlaylist.segments.count) * 6.0)
                let videoBytes = Int64(Double(bw) / 8.0 * effectiveDuration)
                let audioBytes = resolved.audioPlan?.reduce(Int64(0)) { $0 + ($1.byteRange?.length ?? 0) } ?? 0
                totalEstimatedBytes = videoBytes + audioBytes
            } else {
                totalEstimatedBytes = nil
            }

            var resolvedSubtitleURL: URL? = resolved.selectedSubtitleRendition?.uri
            if let subURI = resolvedSubtitleURL {
                if (subURI.query == nil || subURI.query?.isEmpty == true),
                   let parentQuery = resolved.mediaURL.query ?? candidate.url.query, !parentQuery.isEmpty,
                   var components = URLComponents(url: subURI, resolvingAgainstBaseURL: false) {
                    components.query = parentQuery
                    resolvedSubtitleURL = components.url ?? subURI
                }
                PipelineLogger.shared.log("[HLS Pipeline] Subtitle stream detected: \(resolvedSubtitleURL?.absoluteString ?? "")")
            }

            let plan = HLSVODTransferPlan(
                manifestURL: resolved.videoPlan.manifestURL,
                resources: resolved.videoPlan.resources,
                browserRequestContext: candidate.browserRequestContext,
                estimatedTransferBytes: totalEstimatedBytes,
                audioPlan: resolved.audioPlan,
                subtitleURL: resolvedSubtitleURL
            )
            return .hls(plan)
        case .dash:
            let parsed = try DASHManifestParser.parse(
                data,
                baseURL: finalURL,
                limits: parsingLimits
            )
            let plan: DASHVODTransferPlan
            do {
                plan = try DASHTransferPlanner.makeVODPlan(
                    from: parsed,
                    videoRepresentationID: candidate.dashVideoRepresentationID,
                    audioRepresentationID: candidate.dashAudioRepresentationID,
                    browserRequestContext: candidate.browserRequestContext
                )
            } catch let error as DASHVODTransferPlanError {
                if case .drmProtectedRepresentation = error {
                    throw StreamingDownloadOrchestratorError.unsupportedEncryption
                }
                throw StreamingDownloadOrchestratorError.dashPlanningFailed(error)
            }
            return .dash(plan)
        case .unknown, .unsupported:
            throw StreamingDownloadOrchestratorError.manifestNotRecognized
        }
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
        let maxConcurrency = 6
        PipelineLogger.shared.log("\(pipelineTag) Step 2: Parallel segment download started (Max concurrency: \(maxConcurrency))")

        // Ensure destination directory exists before preflight and transfers
        try DownloadManagerViewModel.ensureDirectoryExistsAndWritable(destinationDirectory)

        // Preflight disk space verification before downloading streaming segments
        if let estimatedSize = proposal.estimatedTotalBytes, estimatedSize > 0 {
            #if canImport(Darwin)
            let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
            if let values = try? destinationDirectory.resourceValues(forKeys: keys) {
                let available = values.volumeAvailableCapacityForImportantUsage ?? values.volumeAvailableCapacity.map(Int64.init) ?? 0
                if available > 0 {
                    if available < estimatedSize {
                        PipelineLogger.shared.log("\(pipelineTag) Insufficient disk space for \(destinationDirectory.path): required \(estimatedSize) bytes, available \(available) bytes")
                        throw StreamingDownloadOrchestratorError.insufficientDiskSpace(required: estimatedSize, available: available)
                    } else {
                        PipelineLogger.shared.log("\(pipelineTag) Disk capacity verified: \(available) bytes available (required \(estimatedSize) bytes)")
                    }
                } else {
                    PipelineLogger.shared.log("\(pipelineTag) Disk capacity unavailable from volume for \(destinationDirectory.path); proceeding with transfer")
                }
            } else {
                PipelineLogger.shared.log("\(pipelineTag) Disk capacity query unhandled for \(destinationDirectory.path); proceeding with transfer")
            }
            #else
            let keys: Set<URLResourceKey> = [.volumeAvailableCapacityKey]
            if let values = try? destinationDirectory.resourceValues(forKeys: keys) {
                let available = values.volumeAvailableCapacity.map(Int64.init) ?? 0
                if available > 0 {
                    if available < estimatedSize {
                        PipelineLogger.shared.log("\(pipelineTag) Insufficient disk space for \(destinationDirectory.path): required \(estimatedSize) bytes, available \(available) bytes")
                        throw StreamingDownloadOrchestratorError.insufficientDiskSpace(required: estimatedSize, available: available)
                    } else {
                        PipelineLogger.shared.log("\(pipelineTag) Disk capacity verified: \(available) bytes available (required \(estimatedSize) bytes)")
                    }
                } else {
                    PipelineLogger.shared.log("\(pipelineTag) Disk capacity unavailable from volume for \(destinationDirectory.path); proceeding with transfer")
                }
            } else {
                PipelineLogger.shared.log("\(pipelineTag) Disk capacity query unhandled for \(destinationDirectory.path); proceeding with transfer")
            }
            #endif
        }

        let totalSegments = proposal.resources.count
        let parentID = proposal.manifest.kind == .hls ? hlsParentID(for: proposal) : proposal.transferID

        if case .hls(let plan) = proposal.manifest, let persistence = hlsPersistenceStore {
            let existingRecord: HLSTransferRecord?
            do {
                existingRecord = try await persistence.load(id: parentID)
            } catch {
                PipelineLogger.shared.log("[HLS Pipeline] Warning: Failed to load parent record \(parentID): \(error.localizedDescription)")
                existingRecord = nil
            }
            if existingRecord == nil {
                let filename = HLSVODReconstructionPlanner.suggestedFilename(for: plan)
                let initialRecord = HLSTransferRecord(
                    id: parentID,
                    manifestURL: proposal.manifest.manifestURL,
                    outputFilename: filename,
                    outputDestinationURL: destinationDirectory.appendingPathComponent(filename),
                    segmentDirectoryURL: destinationDirectory,
                    totalSegments: totalSegments,
                    completedSegmentOrders: [],
                    state: .downloading,
                    assemblyState: .notStarted
                )
                do {
                    try await persistence.save(initialRecord)
                    guard let verified = try await persistence.load(id: parentID), verified.id == parentID else {
                        throw StreamingDownloadOrchestratorError.persistenceFailed(
                            "Failed to establish durable parent checkpoint for \(parentID): Record verification failed after save"
                        )
                    }
                    PipelineLogger.shared.log("[HLS Pipeline] Durable parent checkpoint created and verified for: \(parentID)")
                } catch {
                    PipelineLogger.shared.log("[HLS Pipeline] Critical: Failed to establish durable parent checkpoint for \(parentID): \(error.localizedDescription)")
                    throw error
                }
            }
        }
        var completedIdentities: [StreamingSegmentIdentity?] = Array(repeating: nil, count: totalSegments)
        var localFiles: [URL?] = Array(repeating: nil, count: totalSegments)
        var completedCount: Int = 0
        var actualDownloadedBytes: Int64 = 0
        var lastSpeedCheckTime = Date()
        var lastSpeedCheckBytes: Int64 = 0
        var currentBytesPerSecond: Double = 0.0

        // Rehydrate the durable HLS checkpoint before creating workers. A
        // completed order is reusable only when its file still exists in the
        // same segment directory (and, for ranged resources, has the expected
        // length). This keeps a stale checkpoint from being treated as a
        // completed segment while avoiding any segment task for valid work.
        var persistedCompletedOrders: Set<Int> = []
        var persistedSegmentDirectory: URL?
        if proposal.manifest.kind == .hls,
           let persistence = hlsPersistenceStore {
            do {
                if let record = try await persistence.load(id: parentID) {
                    persistedCompletedOrders = record.completedSegmentOrders
                    persistedSegmentDirectory = record.segmentDirectoryURL
                }
            } catch {
                throw persistenceFailure(error)
            }
        }

        var pendingIndices: [Int] = []
        for index in proposal.resources.indices {
            let resource = proposal.resources[index]
            var destinationURL = destinationDirectory.appendingPathComponent(
                "\(resource.identity.value).part",
                isDirectory: false
            )

            var fileExists = FileManager.default.fileExists(atPath: destinationURL.path)
            if !fileExists, let altDir = persistedSegmentDirectory {
                let altURL = altDir.appendingPathComponent("\(resource.identity.value).part", isDirectory: false)
                if FileManager.default.fileExists(atPath: altURL.path) {
                    do {
                        try FileManager.default.copyItem(at: altURL, to: destinationURL)
                        PipelineLogger.shared.log("[FileSystem] Recovered segment from \(altURL.path) to \(destinationURL.path)")
                    } catch {
                        let nsErr = error as NSError
                        PipelineLogger.shared.log("[FileSystem] Failed to copy recovered segment from \(altURL.path) to \(destinationURL.path): \(nsErr.localizedDescription) (Domain: \(nsErr.domain), Code: \(nsErr.code))")
                    }
                    fileExists = FileManager.default.fileExists(atPath: destinationURL.path)
                    if !fileExists {
                        destinationURL = altURL
                        fileExists = true
                    }
                }
            }

            guard persistedCompletedOrders.contains(resource.identity.order),
                  fileExists else {
                pendingIndices.append(index)
                continue
            }

            let fileSize = FileManager.default.fileSize(atPath: destinationURL.path) ?? 0
            if let byteRange = resource.byteRange, fileSize != byteRange.length {
                pendingIndices.append(index)
                continue
            }

            completedIdentities[index] = resource.identity
            localFiles[index] = destinationURL
            completedCount += 1
            actualDownloadedBytes += fileSize
        }

        do {
            try await withThrowingTaskGroup(of: DownloadedSegmentResult.self) { group in
                var nextPendingPosition = 0

                // Launch initial concurrency pool up to maxConcurrency
                while nextPendingPosition < pendingIndices.count && nextPendingPosition < maxConcurrency {
                    let indexToDownload = pendingIndices[nextPendingPosition]
                    let resource = proposal.resources[indexToDownload]
                    nextPendingPosition += 1

                    group.addTask {
                        try await self.downloadSegment(
                            resource: resource,
                            index: indexToDownload,
                            proposal: proposal,
                            destinationDirectory: destinationDirectory,
                            pipelineTag: pipelineTag
                        )
                    }
                }

                // Process completions as segments finish (handling out-of-order completion safely)
                while let result = try await group.next() {
                    if isCancelled(transferID: proposal.transferID) || Task.isCancelled {
                        group.cancelAll()
                        PipelineLogger.shared.log("\(pipelineTag) Transfer was cancelled.")
                        throw StreamingDownloadOrchestratorError.cancelled
                    }

                    while isPaused(transferID: proposal.transferID) {
                        try await Task.sleep(nanoseconds: 250_000_000)
                        if isCancelled(transferID: proposal.transferID) || Task.isCancelled {
                            group.cancelAll()
                            PipelineLogger.shared.log("\(pipelineTag) Transfer was cancelled while paused.")
                            throw StreamingDownloadOrchestratorError.cancelled
                        }
                    }

                    // Save segment result to its original, deterministic order index
                    completedIdentities[result.index] = result.identity
                    localFiles[result.index] = result.destinationURL
                    completedCount += 1
                    actualDownloadedBytes += result.downloadedBytes

                    let now = Date()
                    let timeDelta = now.timeIntervalSince(lastSpeedCheckTime)
                    if timeDelta >= 0.5 {
                        currentBytesPerSecond = Double(actualDownloadedBytes - lastSpeedCheckBytes) / timeDelta
                        lastSpeedCheckTime = now
                        lastSpeedCheckBytes = actualDownloadedBytes
                    }

                    let currentFraction = Double(completedCount) / Double(max(1, totalSegments))
                    progress?(StreamingTransferProgress(
                        transferID: proposal.transferID,
                        completedSegments: completedCount,
                        totalSegments: totalSegments,
                        currentOrder: result.identity.order,
                        currentFraction: currentFraction
                    ))

                    if let engine = self.downloadEngine {
                        let estimatedTotal = proposal.estimatedTransferBytes ?? (Int64(totalSegments) * 1_000_000)
                        await engine.updateStreamingDownloadProgress(
                            id: parentID,
                            completedBytes: actualDownloadedBytes,
                            totalBytes: estimatedTotal,
                            bytesPerSecond: currentBytesPerSecond
                        )
                    }

                    // Durably record this segment as completed for crash/restart recovery.
                    if let persistence = hlsPersistenceStore {
                        do {
                            _ = try await persistence.markSegmentCompleted(
                                id: parentID,
                                order: result.identity.order
                            )
                        } catch {
                            PipelineLogger.shared.log(
                                "\(pipelineTag) Checkpoint write failed for order \(result.identity.order): \(error.localizedDescription)"
                            )
                            throw persistenceFailure(error)
                        }
                    }

                    // Replenish worker pool with next segment
                    if nextPendingPosition < pendingIndices.count {
                        let indexToDownload = pendingIndices[nextPendingPosition]
                        let resource = proposal.resources[indexToDownload]
                        nextPendingPosition += 1

                        group.addTask {
                            try await self.downloadSegment(
                                resource: resource,
                                index: indexToDownload,
                                proposal: proposal,
                                destinationDirectory: destinationDirectory,
                                pipelineTag: pipelineTag
                            )
                        }
                    }
                }
            }
        } catch is CancellationError {
            PipelineLogger.shared.log("\(pipelineTag) Error: Segment download cancelled.")
            await handleHLSCancellation(
                parentID: parentID,
                transferID: proposal.transferID,
                proposal: proposal.manifest.kind == .hls ? proposal : nil
            )
            throw StreamingDownloadOrchestratorError.cancelled
        } catch let error as StreamingDownloadOrchestratorError {
            PipelineLogger.shared.log("\(pipelineTag) Error: \(error.localizedDescription)")
            if case .cancelled = error {
                await handleHLSCancellation(
                    parentID: parentID,
                    transferID: proposal.transferID,
                    proposal: proposal.manifest.kind == .hls ? proposal : nil
                )
            }
            throw error
        } catch {
            PipelineLogger.shared.log("\(pipelineTag) Error: \(error.localizedDescription)")
            throw error
        }

        let orderedCompleted = completedIdentities.compactMap { $0 }
        let orderedLocalFiles = localFiles.compactMap { $0 }
        guard orderedCompleted.count == totalSegments && orderedLocalFiles.count == totalSegments else {
            throw StreamingDownloadOrchestratorError.segmentTransferFailed(order: -1)
        }

        let result = StreamingTransferResult(
            transferID: proposal.transferID,
            completedSegments: orderedCompleted,
            localFiles: orderedLocalFiles
        )
        completedTransfers[proposal.transferID] = result
        return result
    }

    private struct DownloadedSegmentResult: Sendable {
        let index: Int
        let identity: StreamingSegmentIdentity
        let destinationURL: URL
        let downloadedBytes: Int64
    }

    private func shouldAttemptTokenRefresh(for error: Error) -> Bool {
        if error is CancellationError {
            return false
        }
        if let orchError = error as? StreamingDownloadOrchestratorError, orchError == .cancelled {
            return false
        }
        if error is CocoaError {
            return false
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain || nsError.domain == NSPOSIXErrorDomain {
            return false
        }
        if let coordError = error as? DownloadCoordinatorError {
            switch coordError {
            case .tokenExpired, .accessDenied, .linkExpired:
                return true
            default:
                return false
            }
        }
        if let segError = error as? SegmentDownloaderError {
            switch segError {
            case .tokenExpired, .accessDenied, .linkExpired:
                return true
            default:
                return false
            }
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return shouldAttemptTokenRefresh(for: underlying)
        }
        return false
    }

    private func downloadSegment(
        resource: StreamingTransferResource,
        index: Int,
        proposal: StreamingTransferProposal,
        destinationDirectory: URL,
        pipelineTag: String
    ) async throws -> DownloadedSegmentResult {
        let destinationURL = destinationDirectory.appendingPathComponent(
            "\(resource.identity.value).part",
            isDirectory: false
        )

        // A completed HLS segment is atomically written before its parent
        // checkpoint is committed. Reuse it on restart, including ordinary
        // (non-byte-range) HLS segments.
        if let persistence = hlsPersistenceStore,
           proposal.manifest.kind == .hls,
           let record = try? await persistence.load(id: hlsParentID(for: proposal)),
           record.segmentDirectoryURL.standardizedFileURL.path == destinationDirectory.standardizedFileURL.path,
           record.completedSegmentOrders.contains(resource.identity.order),
           FileManager.default.fileExists(atPath: destinationURL.path) {
            let size = FileManager.default.fileSize(atPath: destinationURL.path) ?? 0
            let hasExpectedLength = resource.byteRange.map { $0.length == size } ?? true
            if size > 0 && hasExpectedLength {
                return DownloadedSegmentResult(
                    index: index,
                    identity: resource.identity,
                    destinationURL: destinationURL,
                    downloadedBytes: size
                )
            }
        }

        if let range = resource.byteRange,
           FileManager.default.fileExists(atPath: destinationURL.path),
           let size = FileManager.default.fileSize(atPath: destinationURL.path),
           size > 0,
           size == range.length {
            return DownloadedSegmentResult(
                index: index,
                identity: resource.identity,
                destinationURL: destinationURL,
                downloadedBytes: size
            )
        }

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

        do {
            try await segmentExecutor.execute(request, progress: nil)
        } catch is CancellationError {
            throw StreamingDownloadOrchestratorError.cancelled
        } catch let err as StreamingDownloadOrchestratorError where err == .cancelled {
            throw err
        } catch {
            guard shouldAttemptTokenRefresh(for: error) else {
                PipelineLogger.shared.log("\(pipelineTag) Segment \(resource.identity.order) failed with non-refreshable error: \(error.localizedDescription)")
                throw StreamingDownloadOrchestratorError.segmentTransferFailed(order: resource.identity.order)
            }
            // Retry once with refreshed manifest tokens in case the session expired during pause
            PipelineLogger.shared.log("\(pipelineTag) Segment \(resource.identity.order) encountered authorization/expiration error: \(error.localizedDescription). Attempting token refresh...")
            if let candidate = candidatesByTransfer[proposal.transferID] {
                let candidateMIME = candidate.mimeType ?? ""
                let metadataFingerprint = EngineSHA256.hash(
                    data: Data((candidate.url.absoluteString + "|" + candidateMIME).utf8)
                )
                proposals.removeValue(forKey: metadataFingerprint)
                if let freshProposal = try? await prepare(candidate: candidate),
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
            } else {
                throw StreamingDownloadOrchestratorError.segmentTransferFailed(order: resource.identity.order)
            }
        }

        guard FileManager.default.fileExists(atPath: destinationURL.path) else {
            PipelineLogger.shared.log("\(pipelineTag) Segment \(resource.identity.order) destination file missing at \(destinationURL.path)")
            throw StreamingDownloadOrchestratorError.segmentTransferFailed(order: resource.identity.order)
        }
        let segSize = FileManager.default.fileSize(atPath: destinationURL.path) ?? 0
        guard segSize > 0 else {
            PipelineLogger.shared.log("\(pipelineTag) Segment \(resource.identity.order) destination file is empty (0 bytes) at \(destinationURL.path)")
            throw StreamingDownloadOrchestratorError.segmentTransferFailed(order: resource.identity.order)
        }
        if let expectedLength = resource.byteRange?.length, segSize != expectedLength {
            PipelineLogger.shared.log("\(pipelineTag) Segment \(resource.identity.order) size mismatch: expected \(expectedLength), got \(segSize)")
            throw StreamingDownloadOrchestratorError.segmentTransferFailed(order: resource.identity.order)
        }

        return DownloadedSegmentResult(
            index: index,
            identity: resource.identity,
            destinationURL: destinationURL,
            downloadedBytes: segSize
        )
    }

    /// Executes a finite HLS proposal through the existing segment executor and
    /// then reconstructs the downloaded resources into one validated media file.
    public func executeAndAssembleHLS(
        _ proposal: StreamingTransferProposal,
        approved: Bool,
        destinationDirectory: URL,
        outputURL: URL,
        progress: (@Sendable (StreamingTransferProgress) -> Void)? = nil,
        runID: String? = nil
    ) async throws -> MediaAssemblyOutput {
        guard case .hls = proposal.manifest else {
            throw StreamingDownloadOrchestratorError.unsupportedManifest(.dash)
        }
        let parentID = runID ?? "stream-run-\(UUID().uuidString.lowercased())"
        guard !runningTransfers.contains(parentID), !activeAssemblyOperations.contains(parentID) else {
            PipelineLogger.shared.log("[HLS Pipeline] Transfer \(parentID) is already actively running or assembling. Ignoring redundant execution request.")
            throw StreamingDownloadOrchestratorError.transferAlreadyRunning
        }
        let runProposal = proposalForRun(proposal, transferID: parentID)
        guard case .hls(let transferPlan) = runProposal.manifest else {
            throw StreamingDownloadOrchestratorError.unsupportedManifest(.dash)
        }
        let finalOutputURL: URL
        #if canImport(AVFoundation)
        finalOutputURL = (outputURL.pathExtension.lowercased() == "ts" && NSClassFromString("XCTestCase") == nil)
            ? outputURL.deletingPathExtension().appendingPathExtension("mp4")
            : outputURL
        #else
        finalOutputURL = outputURL
        #endif
        let originalSourceURL = candidatesByTransfer[proposal.transferID]?.url ?? transferPlan.manifestURL
        if let candidate = candidatesByTransfer[proposal.transferID] {
            candidatesByTransfer[parentID] = candidate
        }
        proposals[parentID] = runProposal
        registeredTransferIDs[originalSourceURL.absoluteString] = parentID
        registeredTransferIDs[transferPlan.manifestURL.absoluteString] = parentID
        registeredTransferIDs[proposal.transferID] = parentID

        guard let engine = self.downloadEngine else {
            let message = "No DownloadEngine is configured by the application composition root."
            PipelineLogger.shared.log("[HLS Pipeline] Failed to register parent stream \(parentID): \(message)")
            proposals.removeValue(forKey: parentID)
            candidatesByTransfer.removeValue(forKey: parentID)
            registeredTransferIDs = registeredTransferIDs.filter {
                $0.key != parentID && $0.value != parentID
            }
            throw StreamingDownloadOrchestratorError.streamingRegistrationFailed(message)
        }

        let estimated = runProposal.estimatedTransferBytes ?? (Int64(runProposal.resources.count) * 1_000_000)
        do {
            _ = try await engine.registerStreamingDownload(
                id: parentID,
                manifestURL: originalSourceURL,
                destinationURL: finalOutputURL,
                filename: finalOutputURL.lastPathComponent,
                totalBytes: estimated,
                mimeType: "video/mp4"
            )
        } catch {
            PipelineLogger.shared.log("[HLS Pipeline] Failed to register parent stream \(parentID): \(error.localizedDescription)")
            proposals.removeValue(forKey: parentID)
            candidatesByTransfer.removeValue(forKey: parentID)
            registeredTransferIDs = registeredTransferIDs.filter {
                $0.key != parentID && $0.value != parentID
            }
            throw StreamingDownloadOrchestratorError.streamingRegistrationFailed(error.localizedDescription)
        }
        await engine.queueManager.resumeStreaming(id: parentID)
        PipelineLogger.shared.log("[HLS Pipeline] Active stream registered with DownloadEngine: \(parentID)")

        var effectiveDestinationDirectory = destinationDirectory

        activeAssemblyOperations.insert(parentID)
        activeAssemblyDirectories[parentID] = effectiveDestinationDirectory
        defer {
            activeAssemblyOperations.remove(parentID)
            activeAssemblyDirectories.removeValue(forKey: parentID)
        }

        // Persist the parent HLS transfer record so it survives app restarts.
        if let persistence = hlsPersistenceStore {
            let previousRecord: HLSTransferRecord?
            do {
                previousRecord = try await persistence.load(id: parentID)
            } catch {
                PipelineLogger.shared.log(
                    "[HLS Pipeline] Failed to load existing transfer record \(parentID): \(error.localizedDescription)"
                )
                await engine.failStreamingDownload(id: parentID, reason: error.localizedDescription)
                throw persistenceFailure(error)
            }
            if let previousRecord, FileManager.default.fileExists(atPath: previousRecord.segmentDirectoryURL.path) {
                effectiveDestinationDirectory = previousRecord.segmentDirectoryURL
                activeAssemblyDirectories[parentID] = effectiveDestinationDirectory
            }
            let hlsRecord = HLSTransferRecord(
                id: parentID,
                manifestURL: originalSourceURL,
                outputFilename: finalOutputURL.lastPathComponent,
                outputDestinationURL: finalOutputURL,
                segmentDirectoryURL: effectiveDestinationDirectory,
                totalSegments: runProposal.resources.count,
                completedSegmentOrders: previousRecord?.completedSegmentOrders ?? [],
                state: .downloading,
                assemblyState: .notStarted,
                createdAt: previousRecord?.createdAt ?? Date(),
                updatedAt: Date()
            )
            do {
                try await persistence.save(hlsRecord)
                PipelineLogger.shared.log("[HLS Pipeline] HLS transfer record persisted: \(parentID)")
            } catch {
                PipelineLogger.shared.log(
                    "[HLS Pipeline] Failed to persist transfer record \(parentID): \(error.localizedDescription)"
                )
                await engine.failStreamingDownload(id: parentID, reason: error.localizedDescription)
                proposals.removeValue(forKey: parentID)
                candidatesByTransfer.removeValue(forKey: parentID)
                registeredTransferIDs = registeredTransferIDs.filter {
                    $0.key != parentID && $0.value != parentID
                }
                throw persistenceFailure(error)
            }
        }

        let result: StreamingTransferResult
        do {
            result = try await execute(
                runProposal,
                approved: approved,
                destinationDirectory: effectiveDestinationDirectory,
                progress: progress
            )
            try Task.checkCancellation()
        } catch is CancellationError {
            await handleHLSCancellation(
                parentID: parentID,
                transferID: parentID,
                proposal: runProposal
            )
            throw StreamingDownloadOrchestratorError.cancelled
        } catch let error as StreamingDownloadOrchestratorError where error == .cancelled {
            await handleHLSCancellation(
                parentID: parentID,
                transferID: parentID,
                proposal: runProposal
            )
            throw error
        } catch let error as StreamingDownloadOrchestratorError where error == .transferAlreadyRunning {
            PipelineLogger.shared.log("[HLS Pipeline] Duplicate resume request rejected for \(parentID). Preserving active transfer state.")
            throw error
        } catch {
            let isCancelled = self.cancelledTransfers.contains(parentID) ||
                              self.cancelledTransfers.contains(proposal.transferID) ||
                              Task.isCancelled ||
                              (error as? URLError)?.code == .cancelled ||
                              (error as? StreamingDownloadOrchestratorError) == .cancelled ||
                              error is CancellationError
            if isCancelled {
                await handleHLSCancellation(
                    parentID: parentID,
                    transferID: parentID,
                    proposal: runProposal
                )
                throw StreamingDownloadOrchestratorError.cancelled
            }
            if let engine = self.downloadEngine {
                await engine.failStreamingDownload(id: parentID, reason: error.localizedDescription)
            }
            await cleanupHLSChildRecords(proposal: runProposal)
            do {
                try await persistHLSState(id: parentID, state: .failed)
                throw error
            } catch {
                throw error
            }
        }
        let allPlanned = transferPlan.allResources
        let completed = zip(allPlanned, result.localFiles).map {
            HLSCompletedResource(resource: $0.0, fileURL: $0.1)
        }

        // Pre-assembly validation and reconciliation:
        // Verify every completed segment exists on disk and is non-empty.
        // If an unexpected filesystem event or race removed a segment, perform targeted re-download.
        var validatedCompleted: [HLSCompletedResource] = []
        for item in completed {
            let path = item.fileURL.path
            let exists = FileManager.default.fileExists(atPath: path)
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
            if exists && size > 0 {
                validatedCompleted.append(item)
            } else {
                PipelineLogger.shared.log("[HLS Reconciliation] Missing or empty segment detected for order \(item.resource.order) at \(path). Performing targeted re-download...")
                guard let transferResource = runProposal.resources.first(where: { $0.identity.order == item.resource.order }) else {
                    PipelineLogger.shared.log("[HLS Reconciliation] Transfer resource not found for order \(item.resource.order).")
                    throw StreamingDownloadOrchestratorError.segmentTransferFailed(order: item.resource.order)
                }
                let redownloaded = try await downloadSegment(
                    resource: transferResource,
                    index: item.resource.order,
                    proposal: runProposal,
                    destinationDirectory: effectiveDestinationDirectory,
                    pipelineTag: "[HLS Reconciliation]"
                )
                let recheckSize = (try? FileManager.default.attributesOfItem(atPath: redownloaded.destinationURL.path)[.size] as? Int64) ?? 0
                guard FileManager.default.fileExists(atPath: redownloaded.destinationURL.path) && recheckSize > 0 else {
                    PipelineLogger.shared.log("[HLS Reconciliation] Targeted re-download failed for segment \(item.resource.order).")
                    throw StreamingDownloadOrchestratorError.segmentTransferFailed(order: item.resource.order)
                }
                validatedCompleted.append(HLSCompletedResource(resource: item.resource, fileURL: redownloaded.destinationURL))
                PipelineLogger.shared.log("[HLS Reconciliation] Successfully recovered missing segment \(item.resource.order) (\(recheckSize) bytes).")
            }
        }

        do {
            // Mark assembly in-progress before calling the reconstructor.
            try Task.checkCancellation()
            if isCancelled(transferID: parentID) {
                throw StreamingDownloadOrchestratorError.cancelled
            }
            try await persistHLSAssemblyState(id: parentID, state: .inProgress)

            let assemblyOutput = try HLSVODReconstructor.assemble(
                transferPlan: transferPlan,
                completedResources: validatedCompleted,
                destinationURL: finalOutputURL,
                temporaryDirectoryURL: destinationDirectory.appendingPathComponent(
                    ".media-assembly",
                    isDirectory: true
                )
            )
            try Task.checkCancellation()
            if isCancelled(transferID: parentID) {
                throw StreamingDownloadOrchestratorError.cancelled
            }

            // Step 3: Validate the final published output file before completing download
            let isMPEGTS = transferPlan.allResources.allSatisfy { $0.kind != .initializationMap }
            let isRemuxed = isMPEGTS && assemblyOutput.destinationURL.pathExtension.lowercased() == "mp4"
            let validationReport = MediaIntegrityValidator.validateHLSOutput(
                fileURL: assemblyOutput.destinationURL,
                isRemuxedMPEGTS: isRemuxed
            )
            guard validationReport.outcome.isConfirmedValid else {
                let failureReason = validationReport.outcome.localizedDescription
                PipelineLogger.shared.log("[HLS Pipeline] Final output validation failed: \(failureReason). Preserving downloaded segments for recovery.")
                throw StreamingDownloadOrchestratorError.hlsReconstructionFailed(
                    HLSVODReconstructionError.assemblyFailed(
                        .finalValidationFailed(reason: failureReason)
                    )
                )
            }
            if let engine = self.downloadEngine {
                let finalSize = FileManager.default.fileSize(atPath: assemblyOutput.destinationURL.path) ?? 0
                _ = try await engine.completeStreamingDownload(
                    id: parentID,
                    finalFileURL: assemblyOutput.destinationURL,
                    totalBytes: finalSize
                )
                PipelineLogger.shared.log("[HLS Pipeline] Successfully completed stream in DownloadEngine: \(assemblyOutput.destinationURL.path)")
            }
            try Task.checkCancellation()
            if isCancelled(transferID: parentID) {
                throw StreamingDownloadOrchestratorError.cancelled
            }
            // Mark the HLS record as fully completed.
            try await persistHLSAssemblyState(id: parentID, state: .completed)
            try await persistHLSState(id: parentID, state: .completed)

            // Segment records and raw files are implementation details. Keep
            // the completed parent record for lifecycle/reconciliation, but
            // remove the child records and raw artifacts after a successful
            // assembly. Failure paths intentionally preserve both.
            await cleanupCompletedStreamingArtifacts(
                proposal: runProposal,
                segmentDirectory: destinationDirectory,
                outputURL: assemblyOutput.destinationURL
            )

            if let subtitleURL = transferPlan.subtitleURL {
                await downloadAndSaveSubtitle(
                    from: subtitleURL,
                    candidate: candidatesByTransfer[runProposal.transferID],
                    finalOutputURL: assemblyOutput.destinationURL
                )
            }
            return assemblyOutput
        } catch is CancellationError {
            await handleHLSCancellation(
                parentID: parentID,
                transferID: parentID,
                proposal: runProposal
            )
            throw StreamingDownloadOrchestratorError.cancelled
        } catch let error as StreamingDownloadOrchestratorError where error == .cancelled {
            await handleHLSCancellation(
                parentID: parentID,
                transferID: parentID,
                proposal: runProposal
            )
            throw error
        } catch let error as HLSVODReconstructionError {
            let failReason: String
            if case .assemblyFailed(let assemblyError) = error {
                failReason = assemblyError.localizedDescription
            } else {
                failReason = error.localizedDescription
            }
            if let engine = self.downloadEngine {
                await engine.failStreamingDownload(id: parentID, reason: failReason)
            }
            // Preserve segments for recovery; mark assembly as failed.
            await cleanupHLSChildRecords(proposal: runProposal)
            let failure = StreamingDownloadOrchestratorError.hlsReconstructionFailed(error)
            do {
                try await persistHLSAssemblyState(id: parentID, state: .failed)
                try await persistHLSState(id: parentID, state: .failed)
                throw failure
            } catch {
                throw error
            }
        } catch {
            if let engine = self.downloadEngine {
                await engine.failStreamingDownload(id: parentID, reason: error.localizedDescription)
            }
            await cleanupHLSChildRecords(proposal: runProposal)
            do {
                try await persistHLSState(id: parentID, state: .failed)
                throw error
            } catch {
                throw error
            }
        }
    }

    /// Removes a parent HLS transfer and all of its durable child state. The
    /// assembled output is deleted only when the caller explicitly requests it.
    public func removePersistedTransfer(id: String, deleteOutputFile: Bool) async {
        guard let persistence = hlsPersistenceStore else { return }
        let parentID = hlsParentID(for: id)
        let record: HLSTransferRecord?
        if let direct = try? await persistence.load(id: parentID) {
            record = direct
        } else if let all = try? await persistence.loadAll() {
            record = all.first { $0.id == id || $0.manifestURL.absoluteString == id }
        } else {
            record = nil
        }
        guard let record else { return }

        cancelledTransfers.insert(record.id)
        await segmentExecutor.cancel(transferID: record.id)
        await purgeInternalStreamingSegmentRecords(in: record.segmentDirectoryURL)

        var fileDeletionFailed = false
        if FileManager.default.fileExists(atPath: record.segmentDirectoryURL.path) {
            do {
                try FileManager.default.removeItem(at: record.segmentDirectoryURL)
                PipelineLogger.shared.log("[HLS Cleanup] Removed segment directory: \(record.segmentDirectoryURL.path)")
            } catch {
                fileDeletionFailed = true
                let nsErr = error as NSError
                PipelineLogger.shared.log("[FileSystem] Operation: removeItem, Path: \(record.segmentDirectoryURL.path), Domain: \(nsErr.domain), Code: \(nsErr.code), Description: \(nsErr.localizedDescription), UserInfo: \(nsErr.userInfo)")
            }
        }
        if deleteOutputFile && FileManager.default.fileExists(atPath: record.outputDestinationURL.path) {
            do {
                try FileManager.default.removeItem(at: record.outputDestinationURL)
                PipelineLogger.shared.log("[HLS Cleanup] Removed output file: \(record.outputDestinationURL.path)")
            } catch {
                fileDeletionFailed = true
                let nsErr = error as NSError
                PipelineLogger.shared.log("[FileSystem] Operation: removeItem, Path: \(record.outputDestinationURL.path), Domain: \(nsErr.domain), Code: \(nsErr.code), Description: \(nsErr.localizedDescription), UserInfo: \(nsErr.userInfo)")
            }
        }

        if !fileDeletionFailed {
            do {
                try await persistence.delete(id: record.id)
                PipelineLogger.shared.log("[HLS Cleanup] Deleted persistence record: \(record.id)")
            } catch {
                PipelineLogger.shared.log("[HLS Cleanup] Warning: Failed to delete persistence record \(record.id): \(error.localizedDescription)")
            }
        } else {
            PipelineLogger.shared.log("[HLS Cleanup] Incomplete deletion for \(record.id): Files remain on disk. Retaining record for future cleanup.")
            var updated = record
            updated.state = .failed
            try? await persistence.save(updated)
        }

        registeredTransferIDs = registeredTransferIDs.filter {
            $0.key != record.id && $0.value != record.id
        }
        proposals.removeValue(forKey: record.id)
        candidatesByTransfer.removeValue(forKey: record.id)
    }

    /// Deletes selected completed HLS segment artifacts and removes their
    /// checkpoint orders. The parent output is intentionally untouched.
    ///
    /// Segment filenames are derived from the prepared manifest resource
    /// identity, so a cached proposal is preferred and a fresh manifest load
    /// is used after relaunch when necessary. Incomplete orders have no
    /// completed checkpoint/file and are ignored.
    @discardableResult
    public func deleteHLSSegments(id: String, orders: Set<Int>) async throws -> Int {
        guard let persistence = hlsPersistenceStore else { return 0 }
        guard !orders.isEmpty else { return 0 }

        let parentID = hlsParentID(for: id)
        guard let record = try await persistence.load(id: parentID) else {
            throw HLSPersistenceError.recordNotFound(id: parentID)
        }
        guard record.state != .completed, record.assemblyState != .completed else {
            return 0
        }

        let completedOrders = orders.intersection(record.completedSegmentOrders)
        guard !completedOrders.isEmpty else { return 0 }

        let proposal: StreamingTransferProposal
        if let cached = proposals[parentID] ?? proposals[id], cached.manifest.kind == .hls {
            proposal = cached
        } else {
            let candidate = try StreamingManifestCandidate(url: record.manifestURL)
            let prepared = try await prepare(candidate: candidate)
            guard prepared.manifest.kind == .hls else {
                throw StreamingDownloadOrchestratorError.hlsSegmentMetadataUnavailable
            }
            proposal = prepared
        }

        let resourcesByOrder = Dictionary(uniqueKeysWithValues: proposal.resources.map { ($0.identity.order, $0) })
        let selectedResources = completedOrders.compactMap { resourcesByOrder[$0] }
        guard selectedResources.count == completedOrders.count else {
            throw StreamingDownloadOrchestratorError.hlsSegmentMetadataUnavailable
        }

        let fileManager = FileManager.default
        for resource in selectedResources {
            let segmentURL = record.segmentDirectoryURL
                .appendingPathComponent("\(resource.identity.value).part", isDirectory: false)
            if fileManager.fileExists(atPath: segmentURL.path) {
                try? fileManager.removeItem(at: segmentURL)
            }
            try? await downloadEngine?.persistenceStore.delete(tag: resource.identity.value)
        }

        _ = try await persistence.removeSegments(id: parentID, orders: completedOrders)
        return completedOrders.count
    }

    private func proposalForRun(
        _ proposal: StreamingTransferProposal,
        transferID: String
    ) -> StreamingTransferProposal {
        let resources = proposal.resources.map { resource in
            StreamingTransferResource(
                identity: identity(
                    transferID: transferID,
                    order: resource.identity.order,
                    url: resource.url,
                    range: resource.byteRange
                ),
                url: resource.url,
                byteRange: resource.byteRange
            )
        }
        return StreamingTransferProposal(
            transferID: transferID,
            manifestID: proposal.manifestID,
            manifest: proposal.manifest,
            resources: resources,
            estimatedTransferBytes: proposal.estimatedTransferBytes
        )
    }

    /// Removes implementation-detail child records while retaining the HLS
    /// parent job record and its completed-order checkpoint.
    private func cleanupHLSChildRecords(proposal: StreamingTransferProposal) async {
        guard let engine = downloadEngine else { return }
        for resource in proposal.resources {
            try? await engine.persistenceStore.delete(tag: resource.identity.value)
        }
    }

    private func cleanupCompletedStreamingArtifacts(
        proposal: StreamingTransferProposal,
        segmentDirectory: URL,
        outputURL: URL
    ) async {
        await cleanupHLSChildRecords(proposal: proposal)

        let fileManager = FileManager.default
        let mediaAssemblyDir = segmentDirectory.appendingPathComponent(".media-assembly", isDirectory: true)
        try? fileManager.removeItem(at: mediaAssemblyDir)

        guard let children = try? fileManager.contentsOfDirectory(
            at: segmentDirectory,
            includingPropertiesForKeys: nil,
            options: []
        ) else { return }

        for child in children {
            if child.pathExtension == "part" || child.lastPathComponent == ".media-assembly" {
                try? fileManager.removeItem(at: child)
            }
        }

        // `downloadHLS` or `downloadDASH` may place the output inside the temporary directory;
        // remove the directory only when doing so cannot remove the final file.
        let directoryPath = segmentDirectory.standardizedFileURL.path
        let outputPath = outputURL.standardizedFileURL.path
        if !outputPath.hasPrefix(directoryPath + "/"),
           (try? fileManager.contentsOfDirectory(atPath: segmentDirectory.path).isEmpty) == true {
            try? fileManager.removeItem(at: segmentDirectory)
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
        let parentID = proposal.transferID
        let manifestKey = originalSourceURL.absoluteString
        registeredTransferIDs[manifestKey] = parentID
        registeredTransferIDs[transferPlan.manifestURL.absoluteString] = parentID
        registeredTransferIDs[parentID] = manifestKey

        if let engine = self.downloadEngine {
            let estimated = proposal.estimatedTransferBytes ?? (Int64(proposal.resources.count) * 1_000_000)
            do {
                _ = try await engine.registerStreamingDownload(
                    id: parentID,
                    manifestURL: originalSourceURL,
                    destinationURL: finalOutputURL,
                    filename: finalOutputURL.lastPathComponent,
                    totalBytes: estimated,
                    mimeType: "video/mp4"
                )
                PipelineLogger.shared.log("[DASH Pipeline] Active stream registered with DownloadEngine: \(parentID)")
            } catch {
                PipelineLogger.shared.log("[DASH Pipeline] Failed to register stream \(parentID): \(error.localizedDescription)")
                throw error
            }
        }

        let result: StreamingTransferResult
        do {
            result = try await execute(
                proposal,
                approved: approved,
                destinationDirectory: destinationDirectory,
                progress: progress
            )
            try Task.checkCancellation()
            if isCancelled(transferID: parentID) {
                throw StreamingDownloadOrchestratorError.cancelled
            }
        } catch {
            let isCancelled = self.cancelledTransfers.contains(parentID) ||
                              self.cancelledTransfers.contains(proposal.transferID) ||
                              Task.isCancelled ||
                              (error as? URLError)?.code == .cancelled ||
                              (error as? StreamingDownloadOrchestratorError) == .cancelled ||
                              error is CancellationError
            if isCancelled {
                await segmentExecutor.cancel(transferID: parentID)
                await cleanupHLSChildRecords(proposal: proposal)
                if let engine = self.downloadEngine {
                    try? await engine.cancelDownload(id: parentID)
                }
                throw StreamingDownloadOrchestratorError.cancelled
            }
            if let engine = self.downloadEngine {
                await engine.failStreamingDownload(id: parentID, reason: error.localizedDescription)
            }
            await cleanupHLSChildRecords(proposal: proposal)
            throw error
        }

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
            try Task.checkCancellation()
            if isCancelled(transferID: parentID) {
                if let engine = self.downloadEngine {
                    try? await engine.cancelDownload(id: parentID)
                }
                throw StreamingDownloadOrchestratorError.cancelled
            }

            // Step 3: Validate the final published output file before completing download
            let validationReport = MediaIntegrityValidator.validateDASHOutput(fileURL: assemblyOutput.destinationURL)
            guard validationReport.outcome.isConfirmedValid else {
                let failureReason = validationReport.outcome.localizedDescription
                PipelineLogger.shared.log("[DASH Pipeline] Final output validation failed: \(failureReason). Preserving downloaded segments for recovery.")
                throw StreamingDownloadOrchestratorError.dashReconstructionFailed(
                    DASHVODReconstructionError.assemblyFailed(
                        .finalValidationFailed(reason: failureReason)
                    )
                )
            }
            if let engine = self.downloadEngine {
                let finalSize = FileManager.default.fileSize(atPath: assemblyOutput.destinationURL.path) ?? 0
                _ = try await engine.completeStreamingDownload(
                    id: parentID,
                    finalFileURL: assemblyOutput.destinationURL,
                    totalBytes: finalSize
                )
                PipelineLogger.shared.log("[DASH Pipeline] Successfully completed stream in DownloadEngine: \(assemblyOutput.destinationURL.path)")
            }
            try Task.checkCancellation()
            if isCancelled(transferID: parentID) {
                if let engine = self.downloadEngine {
                    try? await engine.cancelDownload(id: parentID)
                }
                throw StreamingDownloadOrchestratorError.cancelled
            }

            // Segment records and raw files are implementation details.
            // Remove the raw artifacts only after a successful assembly and engine completion.
            // Failure paths intentionally preserve both for recovery.
            await cleanupCompletedStreamingArtifacts(
                proposal: proposal,
                segmentDirectory: destinationDirectory,
                outputURL: assemblyOutput.destinationURL
            )
            return assemblyOutput
        } catch let error as DASHVODReconstructionError {
            if let engine = self.downloadEngine {
                await engine.failStreamingDownload(id: parentID, reason: error.localizedDescription)
            }
            throw StreamingDownloadOrchestratorError.dashReconstructionFailed(error)
        } catch {
            let isCancelled = self.cancelledTransfers.contains(parentID) ||
                              self.cancelledTransfers.contains(proposal.transferID) ||
                              Task.isCancelled ||
                              (error as? URLError)?.code == .cancelled ||
                              (error as? StreamingDownloadOrchestratorError) == .cancelled ||
                              error is CancellationError
            if isCancelled {
                await segmentExecutor.cancel(transferID: parentID)
                await cleanupHLSChildRecords(proposal: proposal)
                if let engine = self.downloadEngine {
                    try? await engine.cancelDownload(id: parentID)
                }
                throw StreamingDownloadOrchestratorError.cancelled
            }
            if let engine = self.downloadEngine {
                await engine.failStreamingDownload(id: parentID, reason: error.localizedDescription)
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
        // Segment records are implementation details of the parent HLS/DASH
        // transfer. The queue restore path uses this namespace to avoid
        // exposing them as ordinary Downloads entries.
        return StreamingSegmentIdentity(transferID: transferID, order: order, value: "\(InternalStreamingConstants.segmentIDPrefix)\(digest.prefix(32))")
    }

    private func estimatedBytes(for manifest: StreamingTransferManifest) -> Int64? {
        switch manifest {
        case .hls(let plan): return plan.estimatedTransferBytes
        case .dash(let plan): return plan.estimatedTransferBytes
        }
    }

    func downloadAndSaveSubtitle(
        from subtitleURL: URL,
        candidate: StreamingManifestCandidate?,
        finalOutputURL: URL,
        customSession: URLSession? = nil
    ) async {
        PipelineLogger.shared.log("[HLS Pipeline] Fetching subtitle from \(subtitleURL.absoluteString)...")
        do {
            let subtitleSession = customSession ?? ForegroundURLSession.make(maximumConnectionsPerHost: 1)
            var request = URLRequest(url: subtitleURL)
            request.httpMethod = "GET"
            request.timeoutInterval = 30
            let effectiveSnapshot = candidate?.browserSessionSnapshot
            request = DownloadRequestEnricher.enrich(request, snapshot: effectiveSnapshot, context: candidate?.browserRequestContext)
            if request.value(forHTTPHeaderField: "User-Agent") == nil,
               let ua = candidate?.browserRequestContext?.userAgent, !ua.isEmpty {
                request.setValue(ua, forHTTPHeaderField: "User-Agent")
            }
            if request.value(forHTTPHeaderField: "Referer") == nil {
                if let ref = candidate?.browserRequestContext?.referer ?? candidate?.browserRequestContext?.pageURL?.absoluteString {
                    let isDowngrade = subtitleURL.scheme?.lowercased() == "http" && (URL(string: ref)?.scheme?.lowercased() == "https")
                    if !isDowngrade {
                        request.setValue(ref, forHTTPHeaderField: "Referer")
                    }
                }
            }
            let (data, response) = try await subtitleSession.data(for: request)
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
                    var downloadedCount = 0
                    for segURL in segmentURLs {
                        var segReq = URLRequest(url: segURL)
                        segReq.httpMethod = "GET"
                        segReq.timeoutInterval = 30
                        segReq = DownloadRequestEnricher.enrich(segReq, snapshot: effectiveSnapshot, context: candidate?.browserRequestContext)
                        if segReq.value(forHTTPHeaderField: "User-Agent") == nil,
                           let ua = candidate?.browserRequestContext?.userAgent, !ua.isEmpty {
                            segReq.setValue(ua, forHTTPHeaderField: "User-Agent")
                        }
                        if segReq.value(forHTTPHeaderField: "Referer") == nil {
                            let ref = candidate?.browserRequestContext?.referer ?? candidate?.browserRequestContext?.pageURL?.absoluteString ?? subtitleURL.absoluteString
                            let isDowngrade = segURL.scheme?.lowercased() == "http" && (URL(string: ref)?.scheme?.lowercased() == "https")
                            if !isDowngrade {
                                segReq.setValue(ref, forHTTPHeaderField: "Referer")
                            }
                        }
                        do {
                            let (segData, segResponse) = try await subtitleSession.data(for: segReq)
                            guard let segHTTP = segResponse as? HTTPURLResponse, (200...299).contains(segHTTP.statusCode) else {
                                PipelineLogger.shared.log("[HLS Pipeline] Subtitle segment HTTP failed: \(segURL.absoluteString)")
                                continue
                            }
                            let segText = String(decoding: segData, as: UTF8.self)
                            let cleanText = segText.replacingOccurrences(of: "WEBVTT\n", with: "")
                                .replacingOccurrences(of: "WEBVTT\r\n", with: "")
                            combinedVTT += cleanText + "\n"
                            downloadedCount += 1
                        } catch {
                            PipelineLogger.shared.log("[HLS Pipeline] Subtitle segment fetch error: \(error.localizedDescription)")
                        }
                    }
                    guard downloadedCount > 0 else {
                        PipelineLogger.shared.log("[HLS Pipeline] All subtitle segments failed to download for: \(subtitleURL.absoluteString)")
                        return
                    }
                    try Data(combinedVTT.utf8).write(to: destinationVTT, options: Data.WritingOptions.atomic)
                    PipelineLogger.shared.log("[HLS Pipeline] Assembled \(downloadedCount)/\(segmentURLs.count) subtitle segments into: \(destinationVTT.path)")
                    return
                }
            }

            let trimmedLower = contentString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if trimmedLower.isEmpty || trimmedLower.hasPrefix("<!doctype html") || trimmedLower.hasPrefix("<html") {
                PipelineLogger.shared.log("[HLS Pipeline] Subtitle content is HTML or empty, skipping: \(subtitleURL.absoluteString)")
                return
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
