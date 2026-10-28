import Foundation

/// Defines how the probe request is sent to the remote server.
enum ProbeMethod: String, Sendable {
    /// Issues a GET request with a `Range: bytes=0-` header.
    /// This is the primary method used by 1DM+ (e.java:L7331) because many media servers
    /// and CDNs disallow HEAD requests or report inaccurate lengths.
    case rangeGet = "GET"

    /// Issues an HTTP HEAD request.
    case head = "HEAD"
}

/// Configuration options for probing a remote URL.
struct HTTPRangeProbeConfiguration: Sendable {
    /// Target URL to probe.
    let url: URL

    /// Additional HTTP headers to include in the probe (e.g., User-Agent, Referer, Cookie).
    let customHeaders: [String: String]

    /// Preferred probing method (defaults to `.rangeGet`).
    let probeMethod: ProbeMethod

    /// Network timeout interval in seconds (default is 45s, matching 1DM+).
    let timeoutInterval: TimeInterval

    /// Whether to allow requests over cellular networks.
    let allowsCellularAccess: Bool

    init(
        url: URL,
        customHeaders: [String: String] = [:],
        probeMethod: ProbeMethod = .rangeGet,
        timeoutInterval: TimeInterval = 45.0,
        allowsCellularAccess: Bool = true
    ) {
        self.url = url
        self.customHeaders = customHeaders
        self.probeMethod = probeMethod
        self.timeoutInterval = timeoutInterval
        self.allowsCellularAccess = allowsCellularAccess
    }
}

/// The verified metadata discovered by probing the remote server.
struct HTTPRangeProbeResult: Sendable, Equatable {
    /// The original URL passed to the probe.
    let initialURL: URL

    /// The final URL reached after following any HTTP 3xx redirect chain.
    let finalURL: URL

    /// Indicates whether any redirects occurred between `initialURL` and `finalURL`.
    var isRedirected: Bool {
        initialURL != finalURL
    }

    /// The HTTP status code returned by the final server (e.g., 200, 206).
    let statusCode: Int

    /// Whether the server explicitly honored the byte-range request (responded with HTTP 206 Partial Content).
    let supportsRange: Bool

    /// Whether downloading can be paused and resumed.
    /// True if the server responded with 206 or returned 200 with `Accept-Ranges: bytes`.
    let canResume: Bool

    /// Total size of the remote file in bytes, or `nil` if indeterminate (e.g., chunked transfer encoding).
    let totalSize: Int64?

    /// The Content-Type header value returned by the server, stripped of parameter suffixes.
    let mimeType: String?

    /// Suggested filename resolved from Content-Disposition, URL path, or MIME fallback.
    let suggestedFilename: String

    /// The ETag header value, if provided by the server.
    let eTag: String?

    /// The Last-Modified header value, if provided by the server.
    let lastModified: String?

    /// All normalized HTTP response headers returned by the server.
    let responseHeaders: [String: String]
}

/// Specific errors that can occur during range probing.
enum HTTPRangeProbeError: Error, LocalizedError, Equatable {
    case invalidURL(URL)
    case unsupportedResponse(statusCode: Int, message: String)
    case rateLimited(URL, retryAfterSeconds: Double?)
    case resourceNotFound(URL)
    case unauthorized(URL)
    case forbidden(URL)
    case rangeNotSatisfiable(URL)
    case networkError(String, code: Int?)
    case invalidResponseFormat

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "Invalid URL: \(BrowserURLResolver.sanitizeURLForLogging(url))"
        case .unsupportedResponse(let code, let msg):
            return "Unsupported HTTP response (\(code)): \(msg)"
        case .rateLimited(_, let retryAfter):
            if let sec = retryAfter {
                return "Server rate limit exceeded (HTTP 429). Retry after \(Int(sec))s."
            } else {
                return "Server rate limit exceeded (HTTP 429). Please wait before retrying."
            }
        case .resourceNotFound(let url):
            return "Resource not found (404): \(BrowserURLResolver.sanitizeURLForLogging(url))"
        case .unauthorized(let url):
            return "Authentication required (HTTP 401). The server rejected the request. Ensure session cookies or required authentication headers are enabled: \(BrowserURLResolver.sanitizeURLForLogging(url))"
        case .forbidden(let url):
            return "Access forbidden (HTTP 403). The server denied access to this resource. The download link may be expired, signed, or require active session cookies: \(BrowserURLResolver.sanitizeURLForLogging(url))"
        case .rangeNotSatisfiable(let url):
            return "Requested byte range not satisfiable (416): \(BrowserURLResolver.sanitizeURLForLogging(url))"
        case .networkError(let message, _):
            return "Network error: \(message)"
        case .invalidResponseFormat:
            return "Server returned an unexpected or non-HTTP response"
        }
    }
}

/// Discovers server capabilities, validates HTTP Range support, resolves redirects,
/// and determines file size prior to multi-segment downloading.
///
/// Direct translation of 1DM+ v18.2's `e.m16668()` and `UZ.m8426()` into Swift Concurrency.
final class HTTPRangeProbe: Sendable {
    private let urlSession: URLSession

    init(session: URLSession = ForegroundURLSession.make(maximumConnectionsPerHost: 1)) {
        self.urlSession = session
    }

    /// Convenience probe method using default configuration.
    func probe(url: URL, headers: [String: String] = [:]) async throws -> HTTPRangeProbeResult {
        let config = HTTPRangeProbeConfiguration(url: url, customHeaders: headers)
        return try await probe(configuration: config)
    }

    /// Executes the server capability probe.
    func probe(configuration: HTTPRangeProbeConfiguration) async throws -> HTTPRangeProbeResult {
        switch DownloadURLPolicy.classify(configuration.url) {
        case .directHTTP:
            break
        case .mustUseBlobCaptureService, .unsupported:
            throw HTTPRangeProbeError.invalidURL(configuration.url)
        }

        var request = URLRequest(url: configuration.url)
        request.httpMethod = configuration.probeMethod.rawValue
        request.timeoutInterval = configuration.timeoutInterval
        request.allowsCellularAccess = configuration.allowsCellularAccess
        #if canImport(Darwin)
        if #available(iOS 13.0, macOS 10.15, *) {
            request.allowsExpensiveNetworkAccess = configuration.allowsCellularAccess
            request.allowsConstrainedNetworkAccess = configuration.allowsCellularAccess
        }
        #endif

        // Replicating 1DM+ header setup:
        // Accept-Encoding: gzip, deflate (e.java:L5637, e.java:L7331)
        request.setValue("gzip, deflate", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        if configuration.probeMethod == .rangeGet {
            request.setValue("bytes=0-", forHTTPHeaderField: "Range")
        }

        for (key, value) in BrowserHeaderFilter.sanitizeHeaders(configuration.customHeaders) {
            request.setValue(value, forHTTPHeaderField: key)
        }

        request = DownloadRequestEnricher.enrich(request)

        let redirectCaptureDelegate = RedirectCaptureDelegate()

        let response: URLResponse
        do {
            // URLSession.bytes connects and returns headers immediately without consuming the body
            let (_, streamResponse) = try await urlSession.bytes(for: request, delegate: redirectCaptureDelegate)
            response = streamResponse
        } catch let error as HTTPRangeProbeError {
            throw error
        } catch let urlError as URLError {
            throw HTTPRangeProbeError.networkError(
                urlError.localizedDescription,
                code: urlError.code.rawValue
            )
        } catch {
            throw HTTPRangeProbeError.networkError(error.localizedDescription, code: nil)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw HTTPRangeProbeError.invalidResponseFormat
        }

        let statusCode = httpResponse.statusCode
        let finalURL = redirectCaptureDelegate.resolvedFinalURL ?? httpResponse.url ?? configuration.url

        // Normalize response headers into a case-insensitive dictionary
        var headers: [String: String] = [:]
        for (key, value) in httpResponse.allHeaderFields {
            if let k = key as? String, let v = value as? String {
                headers[k.lowercased()] = v
            }
        }

        // Record any Set-Cookie headers back to HTTPCookieStorage.shared for rotation
        DownloadRequestEnricher.recordResponseCookies(headers: headers, for: finalURL)

        // Handle error status codes
        switch statusCode {
        case 404:
            throw HTTPRangeProbeError.resourceNotFound(finalURL)
        case 401:
            #if DEBUG
            print("[HTTPRangeProbe] 401 Unauthorized: status=\(statusCode), cf-mitigated=\(headers["cf-mitigated"] ?? "none"), headers=\(headers)")
            #endif
            throw HTTPRangeProbeError.unauthorized(finalURL)
        case 403:
            #if DEBUG
            print("[HTTPRangeProbe] 403 Forbidden: status=\(statusCode), cf-mitigated=\(headers["cf-mitigated"] ?? "none"), headers=\(headers)")
            #endif
            throw HTTPRangeProbeError.forbidden(finalURL)
        case 429:
            let retryAfter = Self.parseRetryAfter(headers["retry-after"])
            throw HTTPRangeProbeError.rateLimited(finalURL, retryAfterSeconds: retryAfter)
        case 416:
            if let contentRange = headers["content-range"], contentRange.hasSuffix("/0") {
                // RFC 7233 Section 4.4: Content-Range: bytes */0 indicates an empty resource
                break
            }
            throw HTTPRangeProbeError.rangeNotSatisfiable(finalURL)
        case 400...599 where statusCode != 416 && statusCode != 429:
            let statusText = HTTPURLResponse.localizedString(forStatusCode: statusCode)
            throw HTTPRangeProbeError.unsupportedResponse(statusCode: statusCode, message: statusText)
        default:
            break
        }

        // 1. Range Support & Resumability Determination (e.java:L7385-7389)
        let supportsRange = (statusCode == 206)
        let acceptRangesHeader = headers["accept-ranges"]?.lowercased()
        let canResume = supportsRange || (statusCode == 200 && acceptRangesHeader == "bytes")

        // 2. Length Calculation (UZ.m8426)
        let totalSize = Self.parseTotalSize(statusCode: statusCode, headers: headers)

        // 3. MIME Type Extraction
        let rawMime = headers["content-type"]
        let cleanedMime = rawMime?.split(separator: ";").first.map { String($0).trimmingCharacters(in: .whitespaces) }

        // 4. Filename Resolution (UZ.m8471)
        let filename = Self.resolveFilename(
            contentDisposition: headers["content-disposition"],
            finalURL: finalURL,
            mimeType: cleanedMime
        )

        return HTTPRangeProbeResult(
            initialURL: configuration.url,
            finalURL: finalURL,
            statusCode: statusCode,
            supportsRange: supportsRange,
            canResume: canResume,
            totalSize: totalSize,
            mimeType: cleanedMime,
            suggestedFilename: filename,
            eTag: headers["etag"],
            lastModified: headers["last-modified"],
            responseHeaders: headers
        )
    }

    // MARK: - Rate Limiting & Retry-After
    static func parseRetryAfter(_ headerValue: String?) -> Double? {
        guard let headerValue = headerValue?.trimmingCharacters(in: .whitespaces), !headerValue.isEmpty else {
            return nil
        }
        if let seconds = Double(headerValue), seconds >= 0 {
            return seconds
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: headerValue) {
            let interval = date.timeIntervalSinceNow
            return max(1.0, interval)
        }
        return nil
    }

    // MARK: - Length Resolution

    /// Direct translation of 1DM+'s `UZ.m8426()` length resolution algorithm.
    static func parseTotalSize(statusCode: Int, headers: [String: String]) -> Int64? {
        // Priority 1: Content-Range header (for 206 Partial Content or 416 with empty representation */0)
        if (statusCode == 206 || statusCode == 416), let contentRange = headers["content-range"] {
            // Format: "bytes <range-start>-<range-end>/<total-size>" or "bytes */<total-size>"
            if let slashIndex = contentRange.lastIndex(of: "/") {
                let sizeSubstring = contentRange[contentRange.index(after: slashIndex)...]
                    .trimmingCharacters(in: .whitespaces)
                if sizeSubstring != "*", let totalFromRange = Int64(sizeSubstring), totalFromRange >= 0 {
                    return totalFromRange
                }
            }
        }

        // Priority 2: Standard Content-Length header
        if let contentLengthStr = headers["content-length"] {
            if let length = Int64(contentLengthStr.trimmingCharacters(in: .whitespaces)), length >= 0 {
                return length
            }
        }

        // Priority 3: CDN-specific length headers (UZ.java:L11357 - e.g. TikTok / ByteDance)
        if let customLen = headers["x-ttdb-l"] ?? headers["x-content-length"] {
            if let length = Int64(customLen.trimmingCharacters(in: .whitespaces)), length > 0 {
                return length
            }
        }

        return nil
    }

    // MARK: - Filename Resolution

    /// Direct translation of 1DM+'s `UZ.m8471()` filename extraction and sanitization.
    static func resolveFilename(
        contentDisposition: String?,
        finalURL: URL,
        mimeType: String?
    ) -> String {
        // Step 1: Attempt Content-Disposition extraction
        if let disposition = contentDisposition {
            if let parsedName = parseContentDispositionFilename(disposition), !parsedName.isEmpty {
                return sanitizeFilename(parsedName)
            }
        }

        // Step 2: Fallback to URL last path component
        var candidate = finalURL.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.isEmpty || candidate == "/" {
            candidate = "download"
        }

        // Remove query parameters or percent encoding if present
        if let decoded = candidate.removingPercentEncoding {
            candidate = decoded
        }

        var sanitized = sanitizeFilename(candidate)

        // Step 3: Append MIME extension if missing extension
        if !sanitized.contains(".") {
            if let mime = mimeType, let ext = fileExtension(forMimeType: mime) {
                sanitized += ".\(ext)"
            }
        }

        return sanitized.isEmpty ? "download" : sanitized
    }

    /// Parses RFC 6266 and RFC 5987 Content-Disposition header.
    static func parseContentDispositionFilename(_ disposition: String) -> String? {
        // 1. Try filename*=UTF-8''filename.ext
        if let starRange = disposition.range(of: "filename\\*\\s*=\\s*([^;]+)", options: .regularExpression) {
            let match = String(disposition[starRange])
            if let equalsIndex = match.firstIndex(of: "=") {
                var value = String(match[match.index(after: equalsIndex)...]).trimmingCharacters(in: .whitespaces)
                // format: UTF-8''encoded_name.ext
                if let quoteIndex = value.range(of: "''")?.upperBound {
                    value = String(value[quoteIndex...])
                }
                value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if let decoded = value.removingPercentEncoding {
                    return decoded
                }
                return value
            }
        }

        // 2. Try standard filename="filename.ext" or filename=filename.ext
        if let range = disposition.range(of: "filename\\s*=\\s*(\"[^\"]+\"|[^;\\s]+)", options: .regularExpression) {
            let match = String(disposition[range])
            if let equalsIndex = match.firstIndex(of: "=") {
                var value = String(match[match.index(after: equalsIndex)...]).trimmingCharacters(in: .whitespaces)
                value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if let decoded = value.removingPercentEncoding {
                    return decoded
                }
                return value
            }
        }

        return nil
    }

    /// Sanitizes illegal file system characters across iOS and POSIX environments.
    static func sanitizeFilename(_ name: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\?%*|\":<>")
            .union(.controlCharacters)
            .union(.newlines)

        let components = name.components(separatedBy: invalidCharacters)
        let cleaned = components.filter { !$0.isEmpty }.joined(separator: "_")
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Maps common media and download MIME types to their standard file extensions.
    static func fileExtension(forMimeType mimeType: String) -> String? {
        let mapping: [String: String] = [
            "video/mp4": "mp4",
            "video/x-matroska": "mkv",
            "video/webm": "webm",
            "video/quicktime": "mov",
            "video/x-msvideo": "avi",
            "audio/mpeg": "mp3",
            "audio/mp4": "m4a",
            "audio/aac": "aac",
            "audio/flac": "flac",
            "audio/x-wav": "wav",
            "application/pdf": "pdf",
            "application/zip": "zip",
            "application/x-rar-compressed": "rar",
            "application/x-7z-compressed": "7z",
            "application/x-tar": "tar",
            "application/gzip": "gz",
            "application/vnd.apple.mpegurl": "m3u8",
            "application/x-mpegurl": "m3u8",
            "application/dash+xml": "mpd",
            "image/jpeg": "jpg",
            "image/png": "png",
            "image/webp": "webp",
            "image/gif": "gif"
        ]
        return mapping[mimeType.lowercased()]
    }
}

// MARK: - Redirect Tracking Delegate

private final class RedirectCaptureDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _resolvedFinalURL: URL?

    var resolvedFinalURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return _resolvedFinalURL
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        lock.lock()
        _resolvedFinalURL = request.url
        lock.unlock()

        let safeRequest = DownloadRequestEnricher.handleRedirect(
            task: task,
            response: response,
            newRequest: request
        )
        completionHandler(safeRequest)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        let host = space.host

        if space.authenticationMethod == NSURLAuthenticationMethodHTTPBasic ||
           space.authenticationMethod == NSURLAuthenticationMethodDefault ||
           space.authenticationMethod == NSURLAuthenticationMethodHTTPDigest {
            if let saved = KeychainManager.shared.getInternetPassword(server: host, path: "/") {
                completionHandler(.useCredential, URLCredential(user: saved.username, password: saved.password, persistence: .none))
                return
            }
            if let provider = DownloadCoordinator.basicAuthChallengeHandler {
                Task {
                    if let cred = await provider(host, space.realm ?? "") {
                        KeychainManager.shared.storeInternetPassword(
                            username: cred.username,
                            password: cred.password,
                            server: host
                        )
                        completionHandler(.useCredential, URLCredential(user: cred.username, password: cred.password, persistence: .none))
                    } else {
                        completionHandler(.cancelAuthenticationChallenge, nil)
                    }
                }
                return
            }
        }
        completionHandler(.performDefaultHandling, nil)
    }
}
