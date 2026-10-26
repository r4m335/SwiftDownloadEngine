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
    public let hlsVariantPreferences: HLSVariantSelectionPreferences

    public init(
        url: URL,
        mimeType: String? = nil,
        browserRequestContext: BrowserRequestContext? = nil,
        hlsVariantPreferences: HLSVariantSelectionPreferences = HLSVariantSelectionPreferences()
    ) throws {
        guard BrowserURLResolver.isValidDownloadURL(url) else {
            throw StreamingDownloadOrchestratorError.invalidManifestURL
        }
        self.url = url
        self.mimeType = mimeType
        self.browserRequestContext = browserRequestContext
        self.hlsVariantPreferences = hlsVariantPreferences
    }

    public init(resource: WebpageResource) throws {
        try self.init(
            url: resource.url,
            mimeType: resource.mimeType,
            browserRequestContext: resource.requestContext,
            hlsVariantPreferences: HLSVariantSelectionPreferences()
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
        request = DownloadRequestEnricher.enrich(request)

        let delegate = StreamingRedirectDelegate(
            originalURL: candidate.url,
            headers: headers
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
        }
    }
}

/// Coordinates browser discovery, manifest loading/parsing, planning, segment
/// submission, and supported VOD assembly handoffs. It does not own application
/// download state.
public actor StreamingDownloadOrchestrator {
    @MainActor public static var shared: StreamingDownloadOrchestrator?

    private let manifestLoader: any StreamingManifestLoader
    private let segmentExecutor: any StreamingSegmentExecutor
    private let parsingLimits: ManifestParsingLimits
    private var proposals: [String: StreamingTransferProposal] = [:]
    private var runningTransfers: Set<String> = []
    private var completedTransfers: [String: StreamingTransferResult] = [:]

    public init(
        manifestLoader: any StreamingManifestLoader = URLSessionStreamingManifestLoader(),
        segmentExecutor: any StreamingSegmentExecutor,
        parsingLimits: ManifestParsingLimits = .default
    ) {
        self.manifestLoader = manifestLoader
        self.segmentExecutor = segmentExecutor
        self.parsingLimits = parsingLimits
    }

    public init(
        downloadCoordinator: DownloadCoordinator,
        manifestLoader: any StreamingManifestLoader = URLSessionStreamingManifestLoader(),
        parsingLimits: ManifestParsingLimits = .default,
        retryCount: Int = 2
    ) {
        self.init(
            manifestLoader: manifestLoader,
            segmentExecutor: DownloadCoordinatorSegmentExecutor(
                coordinator: downloadCoordinator,
                retryCount: retryCount
            ),
            parsingLimits: parsingLimits
        )
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
        do {
            response = try await manifestLoader.load(
                candidate: candidate,
                headers: headers,
                limits: parsingLimits
            )
        } catch let error as ManifestParserError {
            throw StreamingDownloadOrchestratorError.manifestParseFailed(error)
        } catch {
            if let loadError = error as? StreamingManifestLoadError,
               loadError == .authenticationRequired || loadError == .expiredOrMissing {
                throw error
            }
            throw error
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
                var parsed = try HLSManifestParser.parse(
                    response.data,
                    baseURL: response.finalURL,
                    limits: parsingLimits
                )
                if parsed.playlistType == .master {
                    let variant: HLSVariant
                    do {
                        variant = try HLSVariantSelector.select(
                            from: parsed,
                            preferences: candidate.hlsVariantPreferences
                        )
                        try HLSVariantSelector.validateAudioLayout(
                            selectedVariant: variant,
                            master: parsed
                        )
                    } catch let error as HLSVariantSelectionError {
                        throw StreamingDownloadOrchestratorError.hlsVariantSelectionFailed(error)
                    }
                    let variantCandidate = try StreamingManifestCandidate(
                        url: variant.uri,
                        mimeType: "application/vnd.apple.mpegurl",
                        browserRequestContext: candidate.browserRequestContext,
                        hlsVariantPreferences: candidate.hlsVariantPreferences
                    )
                    response = try await manifestLoader.load(
                        candidate: variantCandidate,
                        headers: manifestHeaders(for: variantCandidate),
                        limits: parsingLimits
                    )
                    let variantClassification = StreamingManifestClassifier.classify(
                        url: response.finalURL,
                        mimeType: response.mimeType ?? variantCandidate.mimeType,
                        content: response.data,
                        limits: parsingLimits
                    )
                    guard variantClassification.kind == .hls else {
                        throw StreamingDownloadOrchestratorError.manifestNotRecognized
                    }
                    parsed = try HLSManifestParser.parse(
                        response.data,
                        baseURL: response.finalURL,
                        limits: parsingLimits
                    )
                }
                guard parsed.playlistType == .media else {
                    throw StreamingDownloadOrchestratorError.playlistRequiresVariantSelection
                }
                let plan = try HLSTransferPlanner.makeVODPlan(
                    from: parsed,
                    browserRequestContext: candidate.browserRequestContext
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
        defer { runningTransfers.remove(proposal.transferID) }

        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        var completed: [StreamingSegmentIdentity] = []
        var localFiles: [URL] = []
        do {
            for resource in proposal.resources {
                try Task.checkCancellation()
                let completedBefore = completed.count
                let destinationURL = destinationDirectory.appendingPathComponent(
                    "\(resource.identity.value).part",
                    isDirectory: false
                )
                let request = StreamingSegmentTransferRequest(
                    identity: resource.identity,
                    url: resource.url,
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
                    progress?(StreamingTransferProgress(
                        transferID: proposal.transferID,
                        completedSegments: completedBefore,
                        totalSegments: proposal.resources.count,
                        currentOrder: resource.identity.order,
                        currentFraction: 1
                    ))
                    continue
                }

                do {
                    try await segmentExecutor.execute(request) { fraction in
                        progress?(StreamingTransferProgress(
                            transferID: proposal.transferID,
                            completedSegments: completedBefore,
                            totalSegments: proposal.resources.count,
                            currentOrder: resource.identity.order,
                            currentFraction: fraction
                        ))
                    }
                } catch is CancellationError {
                    throw StreamingDownloadOrchestratorError.cancelled
                } catch {
                    throw StreamingDownloadOrchestratorError.segmentTransferFailed(order: resource.identity.order)
                }
                completed.append(resource.identity)
                localFiles.append(destinationURL)
                progress?(StreamingTransferProgress(
                    transferID: proposal.transferID,
                    completedSegments: completed.count,
                    totalSegments: proposal.resources.count,
                    currentOrder: resource.identity.order,
                    currentFraction: 1
                ))
            }
        } catch is CancellationError {
            await segmentExecutor.cancel(transferID: proposal.transferID)
            throw StreamingDownloadOrchestratorError.cancelled
        } catch let error as StreamingDownloadOrchestratorError {
            if case .cancelled = error {
                await segmentExecutor.cancel(transferID: proposal.transferID)
            }
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
        let result = try await execute(
            proposal,
            approved: approved,
            destinationDirectory: destinationDirectory,
            progress: progress
        )
        try Task.checkCancellation()
        let completed = zip(transferPlan.resources, result.localFiles).map {
            HLSCompletedResource(resource: $0.0, fileURL: $0.1)
        }
        do {
            return try HLSVODReconstructor.assemble(
                transferPlan: transferPlan,
                completedResources: completed,
                destinationURL: outputURL,
                temporaryDirectoryURL: destinationDirectory.appendingPathComponent(
                    ".media-assembly",
                    isDirectory: true
                )
            )
        } catch let error as HLSVODReconstructionError {
            throw StreamingDownloadOrchestratorError.hlsReconstructionFailed(error)
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
            return try DASHVODReconstructor.assemble(
                transferPlan: transferPlan,
                completedResources: completed,
                destinationURL: outputURL,
                temporaryDirectoryURL: destinationDirectory.appendingPathComponent(
                    ".media-assembly",
                    isDirectory: true
                )
            )
        } catch let error as DASHVODReconstructionError {
            throw StreamingDownloadOrchestratorError.dashReconstructionFailed(error)
        }
    }

    /// Convenience method to download an HLS stream directly from a manifest URL,
    /// executing and assembling into the specified output URL (or destination directory).
    @discardableResult
    public func downloadHLS(
        manifestURL: URL,
        destinationDirectory: URL? = nil,
        outputURL: URL? = nil,
        progress: (@Sendable (StreamingTransferProgress) -> Void)? = nil
    ) async throws -> MediaAssemblyOutput {
        let candidate = try StreamingManifestCandidate(url: manifestURL)
        let proposal = try await prepare(candidate: candidate)
        guard case .hls(let transferPlan) = proposal.manifest else {
            throw StreamingDownloadOrchestratorError.unsupportedManifest(.dash)
        }
        let dest = destinationDirectory ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let finalOut = outputURL ?? dest.appendingPathComponent(HLSVODReconstructionPlanner.suggestedFilename(for: transferPlan), isDirectory: false)
        return try await executeAndAssembleHLS(
            proposal,
            approved: true,
            destinationDirectory: dest,
            outputURL: finalOut,
            progress: progress
        )
    }

    /// Convenience method to download a DASH stream directly from a manifest URL,
    /// executing and assembling into the specified output URL (or destination directory).
    @discardableResult
    public func downloadDASH(
        manifestURL: URL,
        destinationDirectory: URL? = nil,
        outputURL: URL? = nil,
        progress: (@Sendable (StreamingTransferProgress) -> Void)? = nil
    ) async throws -> MediaAssemblyOutput {
        let candidate = try StreamingManifestCandidate(url: manifestURL)
        let proposal = try await prepare(candidate: candidate)
        guard case .dash(let transferPlan) = proposal.manifest else {
            throw StreamingDownloadOrchestratorError.unsupportedManifest(.hls)
        }
        let dest = destinationDirectory ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let finalOut = outputURL ?? dest.appendingPathComponent(DASHVODReconstructionPlanner.suggestedFilename(for: transferPlan), isDirectory: false)
        return try await executeAndAssembleDASH(
            proposal,
            approved: true,
            destinationDirectory: dest,
            outputURL: finalOut,
            progress: progress
        )
    }

    public func cancel(transferID: String) async {
        await segmentExecutor.cancel(transferID: transferID)
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
            guard let planned = plan.resources.first(where: { $0.url == resource.url && $0.order == resource.identity.order }) else { return [:] }
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
            return try plan.resources.map { resource in
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

    init(originalURL: URL? = nil, headers: [String: String]? = nil) {
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
}
