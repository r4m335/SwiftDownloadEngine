import Foundation

public enum DownloadRecoveryError: LocalizedError, Equatable {
    case recordNotFound(id: String)
    case invalidURL(String)
    case incompatibleResource(reason: String)
    case restartRequired(reason: String)
    case probeFailed(String)
    case streamRecoveryFailed(String)

    public var errorDescription: String? {
        switch self {
        case .recordNotFound(let id):
            return "Download record not found for ID: \(id)"
        case .invalidURL(let u):
            return "Invalid URL: \(u)"
        case .incompatibleResource(let reason):
            return "Incompatible resource: \(reason)"
        case .restartRequired(let reason):
            return "Server does not support range resume: \(reason)"
        case .probeFailed(let msg):
            return "Failed to probe new link: \(msg)"
        case .streamRecoveryFailed(let msg):
            return "Streaming recovery failed: \(msg)"
        }
    }
}

/// Coordinates replacing a download's URL with verification of resource identity.
public final class DownloadLinkRefresher: Sendable {
    private let session: URLSession
    private let persistenceStore: DownloadPersistenceStore
    private let queueManager: DownloadQueueManager?
    private let identityVerifier: DownloadIdentityVerifier

    public init(
        session: URLSession = .shared,
        persistenceStore: DownloadPersistenceStore,
        queueManager: DownloadQueueManager? = nil,
        identityVerifier: DownloadIdentityVerifier = DownloadIdentityVerifier()
    ) {
        self.session = session
        self.persistenceStore = persistenceStore
        self.queueManager = queueManager
        self.identityVerifier = identityVerifier
    }

    /// Validates and updates a download's URL.
    /// Preserves completed segments, download ID, and output destination if compatible.
    @discardableResult
    public func refresh(
        id: String,
        newURL: URL,
        newHeaders: [String: String]? = nil,
        forceRestartIfNonResumable: Bool = false
    ) async throws -> (record: DownloadRecord, outcome: ResourceIdentityOutcome) {
        guard var record = try await persistenceStore.fetch(tag: id) else {
            throw DownloadRecoveryError.recordNotFound(id: id)
        }

        // Filter and sanitize request headers according to origin security
        let sanitizedHeaders = sanitizeHeaders(newHeaders, for: newURL, originalURL: record.originalURL, downloadID: id)

        // Probe the replacement URL
        let probe = HTTPRangeProbe(session: session)
        let probeConfig = HTTPRangeProbeConfiguration(
            url: newURL,
            customHeaders: sanitizedHeaders ?? record.securedHeaders,
            allowsCellularAccess: record.networkPolicy.allowsCellularAccess
        )

        let probeResult: HTTPRangeProbeResult
        do {
            probeResult = try await probe.probe(configuration: probeConfig)
        } catch {
            throw DownloadRecoveryError.probeFailed(error.localizedDescription)
        }

        // Verify resource identity
        let outcome = identityVerifier.verify(
            record: record,
            probe: probeResult,
            policy: .compatibility
        )

        switch outcome {
        case .compatible:
            // Update URLs and validators while preserving completed segments
            record.originalURL = newURL
            record.resolvedURL = probeResult.finalURL
            if let h = sanitizedHeaders {
                record.updateHeaders(h)
            }
            if let e = probeResult.eTag { record.eTag = e }
            if let lm = probeResult.lastModified { record.lastModified = lm }
            record.state = .paused
            record.updatedAt = Date()
            try await persistenceStore.save(record)
            if let qm = queueManager {
                try? await qm.updateRequest(id: id, newURL: newURL, newHeaders: sanitizedHeaders ?? record.securedHeaders)
            }
            return (record, outcome)

        case .requiresRestart(let reason):
            if forceRestartIfNonResumable {
                record.originalURL = newURL
                record.resolvedURL = probeResult.finalURL
                if let h = sanitizedHeaders {
                    record.updateHeaders(h)
                }
                record.eTag = probeResult.eTag
                record.lastModified = probeResult.lastModified
                // Zero out segments cleanly for byte 0 restart
                record.segments = record.segments.map { seg in
                    SegmentRecord(
                        id: seg.id,
                        startOffset: seg.startOffset,
                        endOffset: seg.endOffset,
                        length: seg.length,
                        completedBytes: 0
                    )
                }
                record.state = .pending
                record.updatedAt = Date()
                try await persistenceStore.save(record)
                if let qm = queueManager {
                    try? await qm.updateRequest(id: id, newURL: newURL, newHeaders: sanitizedHeaders ?? record.securedHeaders)
                }
                return (record, outcome)
            } else {
                throw DownloadRecoveryError.restartRequired(reason: reason)
            }

        case .incompatible(let reason):
            // Safety rule: Never combine incompatible data. Preserve existing data untouched.
            throw DownloadRecoveryError.incompatibleResource(reason: reason)
        }
    }

    /// Strips authorization headers and cookies if host origin has changed.
    private func sanitizeHeaders(
        _ headers: [String: String]?,
        for newURL: URL,
        originalURL: URL,
        downloadID: String
    ) -> [String: String]? {
        guard var h = headers else { return nil }

        let sameOrigin = newURL.host?.lowercased() == originalURL.host?.lowercased()
        if !sameOrigin {
            // Strip sensitive credentials when redirecting or refreshing to a foreign origin
            h.removeValue(forKey: "Authorization")
            h.removeValue(forKey: "authorization")
            h.removeValue(forKey: "Cookie")
            h.removeValue(forKey: "cookie")
            KeychainManager.shared.deleteCredentials(forDownloadId: downloadID)
        }

        return h
    }
}
