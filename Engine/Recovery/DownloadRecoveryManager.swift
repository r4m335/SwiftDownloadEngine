import Foundation
#if canImport(Combine)
import Combine
#endif

/// Session context when the user navigates from a failed download to the browser to refresh its link.
public struct LinkRefreshSession: Equatable, Sendable {
    public let targetTransferID: String
    public let targetFilename: String
    public let sourcePageURL: URL?
    public let isHLS: Bool

    public init(
        targetTransferID: String,
        targetFilename: String,
        sourcePageURL: URL?,
        isHLS: Bool
    ) {
        self.targetTransferID = targetTransferID
        self.targetFilename = targetFilename
        self.sourcePageURL = sourcePageURL
        self.isHLS = isHLS
    }
}

/// Central coordinator for download recovery, manual link updates, and browser-driven reconnection.
@MainActor
public final class DownloadRecoveryManager: ObservableObject {
    public let linkRefresher: DownloadLinkRefresher
    public let hlsRecoveryCoordinator: HLSRecoveryCoordinator
    public let matcher: BrowserDownloadMatcher
    public let streamingOrchestrator: StreamingDownloadOrchestrator?
    private let engine: DownloadEngine
    private let persistenceStore: DownloadPersistenceStore

    @Published public var activeSession: LinkRefreshSession? = nil
    @Published public var recoveryAlertMessage: String? = nil

    public init(
        engine: DownloadEngine,
        persistenceStore: DownloadPersistenceStore,
        hlsPersistenceStore: HLSPersistenceStore? = nil,
        streamingOrchestrator: StreamingDownloadOrchestrator? = nil,
        session: URLSession = .shared
    ) {
        self.engine = engine
        self.persistenceStore = persistenceStore
        self.streamingOrchestrator = streamingOrchestrator
        self.linkRefresher = DownloadLinkRefresher(
            session: session,
            persistenceStore: persistenceStore,
            queueManager: engine.queueManager
        )
        self.hlsRecoveryCoordinator = HLSRecoveryCoordinator(
            hlsPersistenceStore: hlsPersistenceStore,
            streamingOrchestrator: streamingOrchestrator
        )
        self.matcher = BrowserDownloadMatcher()
    }

    // MARK: - Method 1: Automatic / Manual Retry

    /// Re-attempts downloading a failed or paused transfer in-place, skipping completed segments.
    public func retry(transferID: String) async throws {
        try await engine.resumeDownload(id: transferID)
    }

    // MARK: - Method 2: Manual Update Download Link

    /// Updates the source URL and headers of an existing download and resumes it without creating duplicates.
    public func updateDownloadLink(
        transferID: String,
        newURLText: String,
        newHeaders: [String: String]? = nil,
        isHLS: Bool = false,
        expectedResolutionHeight: Int? = nil,
        forceRestartIfNonResumable: Bool = false
    ) async throws {
        let trimmed = newURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw DownloadRecoveryError.invalidURL(trimmed)
        }

        if isHLS {
            _ = try await hlsRecoveryCoordinator.recoverHLS(
                id: transferID,
                newManifestURL: url,
                expectedResolutionHeight: expectedResolutionHeight,
                headers: newHeaders
            )
            try await engine.resumeDownload(id: transferID)
        } else {
            let initialRecord = try? await persistenceStore.fetch(tag: transferID)
            let initialURL = initialRecord?.originalURL
            let (record, _) = try await linkRefresher.refresh(
                id: transferID,
                newURL: url,
                newHeaders: newHeaders,
                forceRestartIfNonResumable: forceRestartIfNonResumable
            )
            let sameOrigin = initialURL != nil && (initialURL?.host?.lowercased() == url.host?.lowercased() && initialURL?.scheme?.lowercased() == url.scheme?.lowercased())
            let headersToUpdate = sameOrigin ? record.securedHeaders : record.headers.filter {
                let l = $0.key.lowercased()
                return l != "authorization" && l != "cookie" && l != "proxy-authorization"
            }
            if !sameOrigin {
                KeychainManager.shared.deleteCredentials(forDownloadId: transferID)
                var sanitizedRecord = record
                sanitizedRecord.headers = headersToUpdate
                try? await persistenceStore.save(sanitizedRecord)
            }
            try? await engine.queueManager.updateRequest(
                id: transferID,
                newURL: url,
                newHeaders: headersToUpdate
            )
            try await engine.resumeDownload(id: transferID)
        }
    }

    // MARK: - Method 3: Browser Link Refresh Workflow

    /// Starts a browser link-refresh session for a failed transfer, preparing navigation to the source webpage.
    public func startBrowserRefresh(for transfer: UnifiedTransfer) -> URL? {
        let isHLS = transfer.type == .hls || transfer.name.lowercased().hasSuffix(".m3u8")
        var targetPageURL: URL? = nil

        // Extract referer or source URL if it was an HTTP webpage
        if let directURL = URL(string: transfer.source) {
            let ext = directURL.pathExtension.lowercased()
            if ext == "html" || ext == "htm" || ext.isEmpty {
                targetPageURL = directURL
            }
        }

        activeSession = LinkRefreshSession(
            targetTransferID: transfer.id,
            targetFilename: transfer.name,
            sourcePageURL: targetPageURL,
            isHLS: isHLS
        )

        return targetPageURL
    }

    /// Clears the active browser link-refresh session.
    public func cancelBrowserRefresh() {
        activeSession = nil
    }

    /// Reconnects a captured browser resource to an existing download record and resumes it in-place.
    @discardableResult
    public func reconnectBrowserResource(
        transferID: String,
        resource: WebpageResource
    ) async throws -> String {
        defer {
            activeSession = nil
        }

        // Extract browser request headers (cookies, user-agent, referer) securely scoped to origin
        var headers: [String: String] = [:]
        if let ctx = resource.requestContext {
            if let ua = ctx.userAgent, !ua.isEmpty { headers["User-Agent"] = ua }
            if let ref = ctx.referer, !ref.isEmpty { headers["Referer"] = ref }
            if !ctx.cookies.isEmpty {
                let cookieString = ctx.cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                if !cookieString.isEmpty { headers["Cookie"] = cookieString }
            }
        }

        let isHLS = resource.isStreamingManifest || resource.url.pathExtension.lowercased() == "m3u8"
        var expectedHeight: Int? = nil
        if let prefs = resource.hlsVariantPreferences {
            expectedHeight = prefs.maximumHeight
        }

        try await updateDownloadLink(
            transferID: transferID,
            newURLText: resource.url.absoluteString,
            newHeaders: headers.isEmpty ? nil : headers,
            isHLS: isHLS,
            expectedResolutionHeight: expectedHeight,
            forceRestartIfNonResumable: false
        )

        return transferID
    }
}
