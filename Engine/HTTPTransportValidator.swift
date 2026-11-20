import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Unified validation and request normalization across all engine HTTP transports:
/// - `SegmentDownloader`: Foreground concurrent range chunk transport
/// - `BackgroundHTTPTransport`: Background iOS URLSession transport
/// - `StreamingSegmentExecutor`: HLS/DASH media playlist segment transport
public enum HTTPTransportValidator {

    // MARK: - Validation Errors

    public enum Error: Swift.Error, LocalizedError, Equatable, Sendable {
        case invalidResponse
        case unexpectedStatus(expected: Int, actual: Int)
        case invalidContentRange(String)
        case contentRangeMismatch(expectedStart: Int64, expectedEnd: Int64, actualStart: Int64, actualEnd: Int64)
        case totalSizeMismatch(expected: Int64, actual: Int64)
        case wildcardTotalRejected(header: String)
        case bodyLengthMismatch(expected: Int64, actual: Int64)
        case htmlErrorPageReceived(contentType: String)
        case rateLimited(retryAfterSeconds: Double?)
        case tokenExpired
        case accessDenied
        case linkExpired
        case cancelled

        public var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "Server returned a non-HTTP response"
            case .unexpectedStatus(let exp, let act):
                return "Unexpected HTTP status: expected \(exp), received \(act)"
            case .invalidContentRange(let header):
                return "Missing or malformed Content-Range header: '\(header)'"
            case .contentRangeMismatch(let expS, let expE, let actS, let actE):
                return "Content-Range boundary mismatch: requested \(expS)-\(expE), received \(actS)-\(actE)"
            case .totalSizeMismatch(let exp, let act):
                return "Content-Range total size (\(act)) does not match expected size (\(exp))"
            case .wildcardTotalRejected(let header):
                return "Server returned wildcard total (*) in Content-Range when exact size is known: \(header)"
            case .bodyLengthMismatch(let exp, let act):
                return "Downloaded body length mismatch: expected \(exp) bytes, received \(act) bytes"
            case .htmlErrorPageReceived(let contentType):
                return "Server returned HTML error/login page instead of binary content (\(contentType))"
            case .rateLimited(let retryAfter):
                if let sec = retryAfter {
                    return "Server rate limit exceeded (HTTP 429). Retry after \(Int(sec))s."
                } else {
                    return "Server rate limit exceeded (HTTP 429). Please wait before retrying."
                }
            case .tokenExpired:
                return "Server rejected authorization token or session expired (HTTP 401)"
            case .accessDenied:
                return "Server access denied or forbidden (HTTP 403)"
            case .linkExpired:
                return "Download link expired or resource not found (HTTP 404/410)"
            case .cancelled:
                return "HTTP transport operation was cancelled"
            }
        }
    }

    // MARK: - Header Normalization

    /// Normalizes request headers across all transports.
    ///
    /// - Guarantees `Accept-Encoding: identity` to prevent byte offset distortion from compression.
    /// - Removes duplicate/conflicting `Range` and `If-Range` headers.
    /// - Applies byte-range header if requested.
    /// - Sanitizes and formats ETag validator for `If-Range`.
    public static func normalizeRequest(
        url: URL,
        headers: [String: String] = [:],
        byteRange: (start: Int64, end: Int64)? = nil,
        eTag: String? = nil
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        if let byteRange {
            request.setValue("bytes=\(byteRange.start)-\(byteRange.end)", forHTTPHeaderField: "Range")
        }

        if let validator = DownloadRequestEnricher.ifRangeValidator(eTag: eTag, lastModified: nil) {
            request.setValue(validator, forHTTPHeaderField: "If-Range")
        }

        for (name, value) in headers {
            let lower = name.lowercased()
            if lower == "accept-encoding" || lower == "range" {
                continue
            }
            if lower == "if-range" {
                if let sanitized = DownloadRequestEnricher.ifRangeValidator(eTag: value, lastModified: nil) {
                    request.setValue(sanitized, forHTTPHeaderField: name)
                }
                continue
            }
            request.setValue(value, forHTTPHeaderField: name)
        }

        return DownloadRequestEnricher.enrich(request)
    }

    // MARK: - Response Status Discrimination

    /// Validates response HTTP status codes, discriminating standard terminal errors.
    public static func validateResponseStatus(
        _ httpResponse: HTTPURLResponse,
        expectingPartial: Bool = false
    ) throws {
        let code = httpResponse.statusCode

        if code == 401 { throw Error.tokenExpired }
        if code == 403 { throw Error.accessDenied }
        if code == 404 || code == 410 { throw Error.linkExpired }
        if code == 429 {
            let retryAfter = HTTPRangeProbe.parseRetryAfter(httpResponse.value(forCaseInsensitiveField: "Retry-After"))
            throw Error.rateLimited(retryAfterSeconds: retryAfter)
        }

        if expectingPartial {
            guard code == 206 else {
                throw Error.unexpectedStatus(expected: 206, actual: code)
            }
        } else {
            guard (200...299).contains(code) else {
                throw Error.unexpectedStatus(expected: 200, actual: code)
            }
        }
    }

    // MARK: - Content-Range Parsing & Validation

    /// Parses a standard `Content-Range` response header.
    ///
    /// Accepts: `bytes <start>-<end>/<total>` or `bytes <start>-<end>/*`.
    public static func parseContentRange(_ header: String) throws -> (start: Int64, end: Int64, total: Int64?) {
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("bytes ") else {
            throw Error.invalidContentRange(header)
        }

        let rangePart = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        let components = rangePart.split(separator: "/", maxSplits: 1)
        guard components.count == 2 else {
            throw Error.invalidContentRange(header)
        }

        let bounds = components[0].split(separator: "-", maxSplits: 1)
        guard bounds.count == 2,
              let start = Int64(bounds[0].trimmingCharacters(in: .whitespaces)),
              let end = Int64(bounds[1].trimmingCharacters(in: .whitespaces)),
              start <= end else {
            throw Error.invalidContentRange(header)
        }

        let totalStr = String(components[1]).trimmingCharacters(in: .whitespaces)
        let total = totalStr == "*" ? nil : Int64(totalStr)

        return (start: start, end: end, total: total)
    }

    /// Validates `Content-Range` header boundaries against expected offsets.
    public static func validateContentRange(
        _ headerValue: String?,
        expectedStart: Int64,
        expectedEnd: Int64,
        expectedTotalSize: Int64? = nil,
        allowWildcardTotal: Bool = true
    ) throws {
        guard let value = headerValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            throw Error.invalidContentRange("")
        }

        let parsed = try parseContentRange(value)
        guard parsed.start == expectedStart, parsed.end == expectedEnd else {
            throw Error.contentRangeMismatch(
                expectedStart: expectedStart,
                expectedEnd: expectedEnd,
                actualStart: parsed.start,
                actualEnd: parsed.end
            )
        }

        if let expectedTotal = expectedTotalSize {
            guard let actualTotal = parsed.total else {
                if !allowWildcardTotal {
                    throw Error.wildcardTotalRejected(header: value)
                }
                return
            }
            guard actualTotal == expectedTotal else {
                throw Error.totalSizeMismatch(expected: expectedTotal, actual: actualTotal)
            }
        }
    }

    // MARK: - HTML Error & Captive Portal Sniffing

    /// Inspects Content-Type and initial payload bytes for HTML markers (e.g. login gates or captive portals).
    public static func isHTMLResponse(
        contentType: String?,
        bodyPrefix: Data? = nil
    ) -> Bool {
        if let contentType = contentType?.lowercased() {
            if contentType.contains("text/html") || contentType.contains("application/xhtml+xml") {
                return true
            }
        }
        if let bodyPrefix, !bodyPrefix.isEmpty {
            return isHTMLData(bodyPrefix)
        }
        return false
    }

    /// Checks if a buffer sample begins with HTML or DOCTYPE tags.
    public static func isHTMLData(_ data: Data) -> Bool {
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

    // MARK: - Retry Executor Helper

    /// Executes an async network operation with bounded retries according to standard retry policies.
    public static func executeWithRetry<T: Sendable>(
        maxAttempts: Int = 3,
        initialDelaySeconds: Double = 0.5,
        maxDelaySeconds: Double = 2.0,
        isRetryable: @Sendable (Swift.Error) -> Bool,
        onRetry: (@Sendable (Swift.Error, Int, Int) -> Void)? = nil,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        var attempts = 0
        let effectiveAttempts = max(1, maxAttempts)
        while true {
            attempts += 1
            do {
                return try await operation()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if attempts < effectiveAttempts && isRetryable(error) {
                    onRetry?(error, attempts, effectiveAttempts)
                    let delay = min(maxDelaySeconds, initialDelaySeconds * Double(attempts))
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                throw error
            }
        }
    }
}

// MARK: - Internal Case-Insensitive Header Lookup

extension HTTPURLResponse {
    func value(forCaseInsensitiveField field: String) -> String? {
        if #available(iOS 13.0, macOS 10.15, *) {
            return value(forHTTPHeaderField: field)
        } else {
            let lower = field.lowercased()
            for (key, val) in allHeaderFields {
                if let k = key as? String, k.lowercased() == lower, let v = val as? String {
                    return v
                }
            }
            return nil
        }
    }
}
