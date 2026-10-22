import Foundation

/// Response facts that may be available after a browser observation or a
/// lightweight validation request. The planner itself never performs that
/// request.
public struct DirectMediaResponseMetadata: Sendable, Equatable {
    public let finalURL: URL?
    public let statusCode: Int?
    public let mimeType: String?
    public let contentDisposition: String?
    public let suggestedFilename: String?
    public let expectedContentLength: Int64?

    public init(
        finalURL: URL? = nil,
        statusCode: Int? = nil,
        mimeType: String? = nil,
        contentDisposition: String? = nil,
        suggestedFilename: String? = nil,
        expectedContentLength: Int64? = nil
    ) {
        self.finalURL = finalURL
        self.statusCode = statusCode
        self.mimeType = mimeType
        self.contentDisposition = contentDisposition
        self.suggestedFilename = suggestedFilename
        self.expectedContentLength = expectedContentLength
    }
}

public enum DirectMediaTransferPlanError: Error, LocalizedError, Codable, Sendable, Equatable {
    case unsupportedCandidate
    case invalidURL
    case insufficientEvidence
    case invalidResponseStatus(Int)
    case unsupportedResponseType
    case invalidContentLength
    case expiredURL
    case invalidDestination

    public var errorDescription: String? {
        switch self {
        case .unsupportedCandidate:
            return "This browser resource is not a supported direct media file."
        case .invalidURL:
            return "The media resource URL is invalid or uses an unsupported scheme."
        case .insufficientEvidence:
            return "There is not enough evidence to identify this resource as direct media."
        case .invalidResponseStatus(let status):
            return "The media resource returned an unusable HTTP status (\(status))."
        case .unsupportedResponseType:
            return "The media response type is not a supported direct media format."
        case .invalidContentLength:
            return "The media response reported an invalid content length."
        case .expiredURL:
            return "The signed media URL has expired. Rediscover the resource and try again."
        case .invalidDestination:
            return "The local download destination is invalid."
        }
    }
}

/// A validated direct-file proposal. It contains no download state and does
/// not execute network work; confirmation remains with the browser UI and the
/// existing BrowserDownloadDelegate/DownloadCoordinator pipeline.
public struct DirectMediaTransferPlan: Sendable, Equatable {
    public let candidateID: String
    public let originalURL: URL
    public let transferURL: URL
    public let filename: String
    public let mimeType: String?
    public let expectedContentLength: Int64?
    public let requestContext: BrowserRequestContext?
    public let requestHeaders: [String: String]

    public init(
        candidateID: String,
        originalURL: URL,
        transferURL: URL,
        filename: String,
        mimeType: String?,
        expectedContentLength: Int64?,
        requestContext: BrowserRequestContext?,
        requestHeaders: [String: String]
    ) {
        self.candidateID = candidateID
        self.originalURL = originalURL
        self.transferURL = transferURL
        self.filename = filename
        self.mimeType = mimeType
        self.expectedContentLength = expectedContentLength
        self.requestContext = requestContext
        self.requestHeaders = requestHeaders
    }

    /// Produces the existing coordinator request when a caller has selected a
    /// local destination. Browser credentials are never persisted in this
    /// request's durable record.
    public func makeDownloadRequest(
        destinationURL: URL,
        id: String = UUID().uuidString,
        threadCount: Int = 6,
        speedLimitBytesPerSecond: Int64? = nil
    ) throws -> DownloadRequest {
        guard destinationURL.isFileURL else {
            throw DirectMediaTransferPlanError.invalidDestination
        }
        return DownloadRequest(
            id: id,
            url: transferURL,
            destinationURL: destinationURL,
            headers: requestHeaders,
            persistSensitiveHeaders: false,
            configuredThreadCount: max(1, min(32, threadCount)),
            speedLimitBytesPerSecond: speedLimitBytesPerSecond
        )
    }
}

public enum DirectMediaTransferPlanner {
    public static func makePlan(
        candidate: BrowserMediaCandidate,
        response: DirectMediaResponseMetadata? = nil,
        now: Date = Date()
    ) throws -> DirectMediaTransferPlan {
        guard candidate.kind == .directMedia,
              candidate.availability == .downloadable else {
            throw DirectMediaTransferPlanError.unsupportedCandidate
        }
        guard let originalURL = candidate.url,
              BrowserURLResolver.isValidDownloadURL(originalURL) else {
            throw DirectMediaTransferPlanError.invalidURL
        }

        let transferURL = response?.finalURL ?? candidate.finalURL ?? originalURL
        guard BrowserURLResolver.isValidDownloadURL(transferURL) else {
            throw DirectMediaTransferPlanError.invalidURL
        }
        guard !isExpired(transferURL, now: now) else {
            throw DirectMediaTransferPlanError.expiredURL
        }

        if let status = response?.statusCode,
           !(200...299).contains(status) {
            throw DirectMediaTransferPlanError.invalidResponseStatus(status)
        }
        if let expected = response?.expectedContentLength,
           expected < 0 {
            throw DirectMediaTransferPlanError.invalidContentLength
        }

        let responseMIME = normalizedMIME(response?.mimeType)
        if let responseMIME, isHTMLOrManifest(responseMIME) {
            throw DirectMediaTransferPlanError.unsupportedResponseType
        }
        let mimeType = responseMIME ?? normalizedMIME(candidate.mimeType)
        if let mimeType, isHTMLOrManifest(mimeType) {
            throw DirectMediaTransferPlanError.unsupportedResponseType
        }
        if let estimatedSize = candidate.estimatedSize, estimatedSize < 0 {
            throw DirectMediaTransferPlanError.invalidContentLength
        }
        guard hasDirectMediaEvidence(candidate: candidate, mimeType: mimeType) else {
            throw DirectMediaTransferPlanError.insufficientEvidence
        }

        let filenameResolver = BrowserDownloadInterceptionManager()
        let filename = filenameResolver.resolveFilename(
            serverSuggested: response?.suggestedFilename ?? candidate.suggestedFilename,
            contentDisposition: response?.contentDisposition,
            url: transferURL,
            mimeType: mimeType
        )
        let headers: [String: String]
        if let context = candidate.requestContext {
            let captured = context.effectiveHeaders(for: transferURL)
            headers = BrowserHeaderFilter.stripCredentialsOnRedirect(
                headers: captured,
                from: originalURL,
                to: transferURL
            )
        } else {
            headers = [:]
        }

        let safeContext: BrowserRequestContext?
        if let context = candidate.requestContext,
           sameOrigin(originalURL, transferURL) {
            safeContext = context
        } else {
            safeContext = nil
        }

        return DirectMediaTransferPlan(
            candidateID: candidate.id,
            originalURL: originalURL,
            transferURL: transferURL,
            filename: filename,
            mimeType: mimeType,
            expectedContentLength: response?.expectedContentLength ?? candidate.estimatedSize,
            requestContext: safeContext,
            requestHeaders: headers
        )
    }

    public static func makePlan(
        resource: WebpageResource,
        response: DirectMediaResponseMetadata? = nil,
        now: Date = Date()
    ) throws -> DirectMediaTransferPlan {
        let candidate = BrowserMediaCandidateClassifier.classify(resource: resource, now: now)
        return try makePlan(candidate: candidate, response: response, now: now)
    }

    private static func hasDirectMediaEvidence(
        candidate: BrowserMediaCandidate,
        mimeType: String?
    ) -> Bool {
        if let mimeType,
           mimeType.hasPrefix("video/") || mimeType.hasPrefix("audio/") {
            return true
        }
        if candidate.evidence.contains("supported media MIME type") ||
            candidate.evidence.contains("media element observation") {
            return true
        }
        guard let url = candidate.url else { return false }
        return WebpageResourceExtractor.categorize(
            extension: BrowserDownloadClassifier.extractURLExtension(from: url),
            mimeType: mimeType
        ) == .video || WebpageResourceExtractor.categorize(
            extension: BrowserDownloadClassifier.extractURLExtension(from: url),
            mimeType: mimeType
        ) == .audio
    }

    private static func normalizedMIME(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return result?.isEmpty == false ? result : nil
    }

    private static func isHTMLOrManifest(_ mime: String) -> Bool {
        mime == "text/html" || mime == "application/xhtml+xml" ||
            mime == "application/vnd.apple.mpegurl" || mime == "application/x-mpegurl" ||
            mime == "application/dash+xml" || mime == "video/vnd.mpeg.dash.mpd"
    }

    private static func isExpired(_ url: URL, now: Date) -> Bool {
        guard let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            return false
        }
        var values: [String: String] = [:]
        for item in queryItems {
            if let value = item.value {
                values[item.name.lowercased()] = value
            }
        }
        for key in ["expires", "exp", "x-amz-expires"] {
            if let raw = values[key], let seconds = Double(raw) {
                // X-Amz-Expires is a duration and only has meaning with
                // X-Amz-Date; standalone expires/exp values are Unix times.
                if key == "x-amz-expires",
                   let dateText = values["x-amz-date"],
                   let start = amzDate(dateText) {
                    return now >= start.addingTimeInterval(seconds)
                }
                if key != "x-amz-expires" {
                    return now >= Date(timeIntervalSince1970: seconds)
                }
            }
        }
        return false
    }

    private static func amzDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.date(from: value)
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let lhsScheme = lhs.scheme?.lowercased(),
              let rhsScheme = rhs.scheme?.lowercased(),
              let lhsHost = lhs.host?.lowercased(),
              let rhsHost = rhs.host?.lowercased() else { return false }

        func effectivePort(_ url: URL, scheme: String) -> Int? {
            if let port = url.port { return port }
            return scheme == "https" ? 443 : (scheme == "http" ? 80 : nil)
        }

        return lhsScheme == rhsScheme &&
            lhsHost == rhsHost &&
            effectivePort(lhs, scheme: lhsScheme) == effectivePort(rhs, scheme: rhsScheme)
    }
}
