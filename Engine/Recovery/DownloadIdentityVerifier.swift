import Foundation

/// Outcome of evaluating whether a new or refreshed URL/resource matches an existing download.
public enum ResourceIdentityOutcome: Equatable, Sendable {
    /// Safe to resume existing download; completed segments and destination file are preserved.
    case compatible(reasons: [String])

    /// Identity matches or is acceptable, but byte ranges are not supported, requiring a clean restart from byte 0.
    case requiresRestart(reason: String)

    /// Incompatible resource; resuming would corrupt the download or combine unrelated files.
    case incompatible(reason: String)

    public var isCompatible: Bool {
        if case .compatible = self { return true }
        return false
    }

    public var isRequiresRestart: Bool {
        if case .requiresRestart = self { return true }
        return false
    }

    public var isIncompatible: Bool {
        if case .incompatible = self { return true }
        return false
    }

    public var diagnosticMessage: String {
        switch self {
        case .compatible(let reasons):
            return "Compatible: " + reasons.joined(separator: ", ")
        case .requiresRestart(let reason):
            return "Restart Required: " + reason
        case .incompatible(let reason):
            return "Incompatible: " + reason
        }
    }
}

/// Verifies resource identity before allowing resume or link replacement.
/// Enforces identity verification to prevent mixing data from incompatible remote files.
public struct DownloadIdentityVerifier: Sendable {
    public struct ProbeMetadata: Sendable, Equatable {
        public let finalURL: URL
        public let totalSize: Int64?
        public let eTag: String?
        public let lastModified: String?
        public let supportsRange: Bool
        public let mimeType: String?
        public let statusCode: Int
        public let isRedirected: Bool
        public let canResume: Bool

        public init(
            finalURL: URL,
            totalSize: Int64?,
            eTag: String?,
            lastModified: String?,
            supportsRange: Bool,
            mimeType: String?,
            statusCode: Int = 200,
            isRedirected: Bool = false,
            canResume: Bool = true
        ) {
            self.finalURL = finalURL
            self.totalSize = totalSize
            self.eTag = eTag
            self.lastModified = lastModified
            self.supportsRange = supportsRange
            self.mimeType = mimeType
            self.statusCode = statusCode
            self.isRedirected = isRedirected
            self.canResume = canResume
        }
    }

    public init() {}

    /// Evaluates remote probe metadata against an existing download record.
    public func verify(
        record: DownloadRecord,
        probe: ProbeMetadata,
        policy: ResumeIntegrityPolicy = .compatibility
    ) -> ResourceIdentityOutcome {
        var reasons: [String] = []

        // 1. File size consistency check
        if let remoteSize = probe.totalSize, record.totalSize > 0 {
            if remoteSize != record.totalSize {
                return .incompatible(
                    reason: "File size mismatch: remote server reported \(remoteSize) bytes, but existing download is \(record.totalSize) bytes."
                )
            }
            reasons.append("Exact file size match (\(remoteSize) bytes)")
        }

        // 2. Strong validator check (ETag)
        if let persistedETag = record.eTag, let remoteETag = probe.eTag {
            let normPersisted = normalizeValidator(persistedETag)
            let normRemote = normalizeValidator(remoteETag)
            if normPersisted != normRemote {
                return .incompatible(
                    reason: "ETag mismatch: remote server reported '\(remoteETag)', but existing download has '\(persistedETag)'. The server file has been modified."
                )
            }
            reasons.append("ETag validator match (\(remoteETag))")
        }

        // 3. Weak validator fallback (Last-Modified) when ETag is absent
        if record.eTag == nil && probe.eTag == nil,
           let persistedLM = record.lastModified, let remoteLM = probe.lastModified {
            if persistedLM != remoteLM {
                return .incompatible(
                    reason: "Last-Modified mismatch: server reported '\(remoteLM)', but existing download has '\(persistedLM)'."
                )
            }
            reasons.append("Last-Modified match (\(remoteLM))")
        }

        // 4. MIME type divergence check (e.g. video turned into text/html error page or captive portal)
        if let remoteMime = probe.mimeType?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines), !remoteMime.isEmpty {
            if remoteMime.contains("text/html") || remoteMime.contains("text/plain") {
                // If existing record was a media file (> 1 MB or non-html extension), an HTML response indicates a login or error page
                let pathExt = record.destinationURL.pathExtension.lowercased()
                let isMediaExt = ["mp4", "mkv", "avi", "mov", "ts", "mp3", "m4a", "zip", "rar", "bin", "iso", "tar", "gz"].contains(pathExt)
                if isMediaExt || record.totalSize > 1_000_000 {
                    return .incompatible(
                        reason: "Remote URL returned MIME type '\(remoteMime)' (webpage or error), but existing download expects media (\(pathExt))."
                    )
                }
            }
            reasons.append("MIME type: \(remoteMime)")
        }

        // 5. Byte range resumption capability check
        let canResumeRanges = probe.supportsRange || probe.canResume
        if !canResumeRanges {
            if record.completedBytes > 0 {
                return .requiresRestart(
                    reason: "Remote server does not support HTTP Range requests for download resumption. Resuming from byte \(record.completedBytes) is not supported."
                )
            }
        } else {
            reasons.append("Byte-range resumption supported")
        }

        // 6. Policy evaluation when no validators exist
        let hasPersistedValidator = (record.eTag != nil || record.lastModified != nil)
        let hasRemoteValidator = (probe.eTag != nil || probe.lastModified != nil)
        if !hasPersistedValidator && !hasRemoteValidator {
            switch policy {
            case .compatibility:
                reasons.append("No validators provided by server; allowed by compatibility policy")
            case .conservative:
                return .requiresRestart(
                    reason: "Server provides neither ETag nor Last-Modified validators, and conservative policy is active."
                )
            }
        }

        return .compatible(reasons: reasons)
    }

    /// Internal overload accepting internal HTTPRangeProbeResult from SwiftDownloadEngine.
    func verify(
        record: DownloadRecord,
        probe: HTTPRangeProbeResult,
        policy: ResumeIntegrityPolicy = .compatibility
    ) -> ResourceIdentityOutcome {
        let meta = ProbeMetadata(
            finalURL: probe.finalURL,
            totalSize: probe.totalSize,
            eTag: probe.eTag,
            lastModified: probe.lastModified,
            supportsRange: probe.supportsRange,
            mimeType: probe.mimeType,
            statusCode: probe.statusCode,
            isRedirected: probe.isRedirected,
            canResume: probe.canResume
        )
        return verify(record: record, probe: meta, policy: policy)
    }

    private func normalizeValidator(_ v: String) -> String {
        var s = v.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("W/") || s.hasPrefix("w/") {
            s = String(s.dropFirst(2))
        }
        return s.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }
}
