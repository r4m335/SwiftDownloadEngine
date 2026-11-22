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

        let sameOrigin = isSameOrigin(record.originalURL, newURL)
        if !sameOrigin {
            KeychainManager.shared.deleteCredentials(forDownloadId: id)
            if let host = record.originalURL.host {
                KeychainManager.shared.deleteCredentials(forHost: host)
            }
            for k in Array(record.headers.keys) {
                let lower = k.lowercased()
                if lower == "authorization" || lower == "cookie" || lower == "proxy-authorization" {
                    record.headers.removeValue(forKey: k)
                }
            }
        }

        // Filter and sanitize request headers according to origin security
        let sanitizedHeaders = sanitizeHeaders(newHeaders, for: newURL, originalURL: record.originalURL, downloadID: id)

        // Probe the replacement URL with existing secured headers overridden by fresh sanitized headers
        let probe = HTTPRangeProbe(session: session)
        var probeHeaders = record.securedHeaders
        if let sanitized = sanitizedHeaders {
            for (k, v) in sanitized {
                probeHeaders[k] = v
            }
        }
        let probeConfig = HTTPRangeProbeConfiguration(
            url: newURL,
            customHeaders: probeHeaders,
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
            for k in Array(record.headers.keys) {
                let lower = k.lowercased()
                if lower == "authorization" || lower == "cookie" || lower == "proxy-authorization" {
                    record.headers.removeValue(forKey: k)
                }
            }
            if let e = probeResult.eTag { record.eTag = e }
            if let lm = probeResult.lastModified { record.lastModified = lm }
            record.state = .paused
            record.updatedAt = Date()
            try await persistenceStore.save(record)
            if let qm = queueManager {
                try? await qm.updateRequest(id: id, newURL: newURL, newHeaders: record.securedHeaders)
            }
            return (record, outcome)

        case .requiresRestart(let reason):
            if forceRestartIfNonResumable {
                record.originalURL = newURL
                record.resolvedURL = probeResult.finalURL
                if let h = sanitizedHeaders {
                    record.updateHeaders(h)
                }
                for k in Array(record.headers.keys) {
                    let lower = k.lowercased()
                    if lower == "authorization" || lower == "cookie" || lower == "proxy-authorization" {
                        record.headers.removeValue(forKey: k)
                    }
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
                    try? await qm.updateRequest(id: id, newURL: newURL, newHeaders: record.securedHeaders)
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

    /// Evaluates same-origin policy including scheme, host, port, and prevention of HTTPS -> HTTP downgrade.
    private func isSameOrigin(_ url1: URL, _ url2: URL) -> Bool {
        guard let host1 = url1.host?.lowercased(),
              let host2 = url2.host?.lowercased(),
              host1 == host2 else {
            return false
        }

        let scheme1 = url1.scheme?.lowercased() ?? "http"
        let scheme2 = url2.scheme?.lowercased() ?? "http"

        // HTTPS -> HTTP downgrade is never same origin / violates security boundary
        if scheme1 == "https" && scheme2 == "http" {
            return false
        }

        // Scheme boundary
        if scheme1 != scheme2 {
            return false
        }

        // Effective ports must match
        let defaultPort1 = (scheme1 == "https" ? 443 : 80)
        let defaultPort2 = (scheme2 == "https" ? 443 : 80)
        let port1 = url1.port ?? defaultPort1
        let port2 = url2.port ?? defaultPort2
        if port1 != port2 {
            return false
        }

        return true
    }

    /// Strips case-insensitive sensitive credential headers (Authorization, Cookie, Proxy-Authorization).
    private func stripSensitiveHeaders(from headers: [String: String]) -> [String: String] {
        var h = headers
        for k in Array(h.keys) {
            let lower = k.lowercased()
            if lower == "authorization" || lower == "cookie" || lower == "proxy-authorization" {
                h.removeValue(forKey: k)
            }
        }
        return h
    }

    /// Strips authorization headers, proxy-authorization, and cookies if host origin has changed or downgraded.
    private func sanitizeHeaders(
        _ headers: [String: String]?,
        for newURL: URL,
        originalURL: URL,
        downloadID: String
    ) -> [String: String]? {
        let sameOrigin = isSameOrigin(originalURL, newURL)
        if !sameOrigin {
            KeychainManager.shared.deleteCredentials(forDownloadId: downloadID)
            if let host = originalURL.host {
                KeychainManager.shared.deleteCredentials(forHost: host)
            }
        }

        guard let h = headers else { return nil }

        if !sameOrigin {
            return stripSensitiveHeaders(from: h)
        }

        return h
    }
}
