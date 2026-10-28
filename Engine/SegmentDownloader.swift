import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Progress for an individual HTTP byte-range segment.
public struct SegmentDownloadProgress: Equatable, Sendable {
    public let segmentID: Int
    public let bytesReceived: Int64
    public let expectedBytes: Int64

    public init(segmentID: Int, bytesReceived: Int64, expectedBytes: Int64) {
        self.segmentID = segmentID
        self.bytesReceived = bytesReceived
        self.expectedBytes = expectedBytes
    }
}

/// Aggregate progress emitted by SegmentDownloader workers.
public struct SegmentDownloadSnapshot: Equatable, Sendable {
    public let bytesReceived: Int64
    public let expectedBytes: Int64
    public let completedSegments: Int
    public let totalSegments: Int

    public var fractionCompleted: Double {
        guard expectedBytes > 0 else { return 0 }
        return min(1.0, Double(bytesReceived) / Double(expectedBytes))
    }

    public init(bytesReceived: Int64, expectedBytes: Int64, completedSegments: Int, totalSegments: Int) {
        self.bytesReceived = bytesReceived
        self.expectedBytes = expectedBytes
        self.completedSegments = completedSegments
        self.totalSegments = totalSegments
    }
}

/// Errors specific to concurrent HTTP Range segment downloading.
public enum SegmentDownloaderError: Error, LocalizedError, Equatable, Sendable {
    case invalidHTTPResponse
    case unexpectedStatus(expected: Int, actual: Int)
    case invalidContentRange
    case contentRangeMismatch(expectedStart: Int64, expectedEnd: Int64, actualStart: Int64, actualEnd: Int64)
    case totalSizeMismatch(expected: Int64, actual: Int64)
    case bodyLengthMismatch(expected: Int64, actual: Int64)
    case rateLimited(retryAfterSeconds: Double?)
    case tokenExpired
    case accessDenied
    case linkExpired
    case htmlErrorPageReceived(contentType: String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidHTTPResponse:
            return "Server returned a non-HTTP response"
        case .unexpectedStatus(let expected, let actual):
            return "Unexpected HTTP status: expected \(expected), received \(actual)"
        case .invalidContentRange:
            return "Missing or malformed Content-Range response header"
        case .contentRangeMismatch(let expS, let expE, let actS, let actE):
            return "Content-Range boundary mismatch: requested \(expS)-\(expE), received \(actS)-\(actE)"
        case .totalSizeMismatch(let expected, let actual):
            return "Content-Range total size (\(actual)) does not match probed file size (\(expected))"
        case .bodyLengthMismatch(let expected, let actual):
            return "Body length mismatch: expected \(expected) bytes, received \(actual) bytes"
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
        case .htmlErrorPageReceived(let contentType):
            return "Server returned HTML error or login page instead of binary content (\(contentType))"
        case .cancelled:
            return "Segment download task was cancelled"
        }
    }
}

/// Downloads allocated segments concurrently using HTTP Range requests.
///
/// Core engine component translating `C1569kI.java` and `AbstractC1399hi.java`:
/// - Requests `Range: bytes=start-end` (or `bytes=(start+completed)-end` for resumes).
/// - Enforces `Accept-Encoding: identity` to prevent byte offset distortion from server compression.
/// - Requires HTTP `206 Partial Content`; rejects `200 OK` (which signals that the server ignored
///   the byte-range request and requires single-stream fallback).
/// - Writes incoming chunks directly to the shared `DownloadFileWriter` at the worker's assigned offset.
/// - Validates both the `Content-Range` response header and the exact downloaded byte count.
public final class SegmentDownloader: Sendable {
    public static let sharedSession: URLSession = ForegroundURLSession.make()

    public typealias ProgressHandler = @Sendable (SegmentDownloadSnapshot) -> Void

    private let session: URLSession
    private let writer: DownloadFileWriter
    private let requestBudget: SharedRequestBudget?
    private let globalBandwidthLimiter: BandwidthLimiter?
    private let perDownloadBandwidthLimiter: BandwidthLimiter?
    private let speedTracker: DownloadSpeedTracker?
    private let downloadID: String
    private let maxConcurrentRequests: Int?

    public init(
        session: URLSession = SegmentDownloader.sharedSession,
        writer: DownloadFileWriter,
        requestBudget: SharedRequestBudget? = nil,
        globalBandwidthLimiter: BandwidthLimiter? = nil,
        perDownloadBandwidthLimiter: BandwidthLimiter? = nil,
        speedTracker: DownloadSpeedTracker? = nil,
        downloadID: String = "default",
        maxConcurrentRequests: Int? = nil
    ) {
        self.session = session
        self.writer = writer
        self.requestBudget = requestBudget
        self.globalBandwidthLimiter = globalBandwidthLimiter
        self.perDownloadBandwidthLimiter = perDownloadBandwidthLimiter
        self.speedTracker = speedTracker
        self.downloadID = downloadID
        self.maxConcurrentRequests = maxConcurrentRequests
    }

    /// Downloads a single segment from the remote URL.
    ///
    /// - Parameters:
    ///   - url: Target URL (resolved final URL from probe).
    ///   - segment: The byte range to download.
    ///   - completedBytes: Number of bytes already downloaded for this segment (used when resuming).
    ///   - expectedTotalSize: Expected total file size from `HTTPRangeProbe` for denominator verification.
    ///   - headers: Custom request headers (User-Agent, Referer, Cookie).
    ///   - eTag: Validator string for `If-Range` header to ensure remote file consistency.
    ///   - progress: Optional callback for streaming progress updates.
    public func download(
        url: URL,
        segment: DownloadSegment,
        completedBytes: Int64 = 0,
        expectedTotalSize: Int64? = nil,
        headers: [String: String] = [:],
        eTag: String? = nil,
        networkPolicy: DownloadNetworkPolicy = .anyNetwork,
        progress: ProgressHandler? = nil
    ) async throws {
        guard completedBytes < segment.length else {
            // Segment is already fully completed
            progress?(SegmentDownloadSnapshot(
                bytesReceived: segment.length,
                expectedBytes: segment.length,
                completedSegments: 1,
                totalSegments: 1
            ))
            return
        }

        var acquiredPermit = false
        if let budget = requestBudget {
            try await budget.acquire(
                downloadID: downloadID,
                maxPerDownload: maxConcurrentRequests,
                host: url.host
            )
            acquiredPermit = true
        }

        do {
            try await executeSegmentDownload(
                url: url,
                segment: segment,
                completedBytes: completedBytes,
                expectedTotalSize: expectedTotalSize,
                headers: headers,
                eTag: eTag,
                networkPolicy: networkPolicy,
                progress: progress
            )
            if acquiredPermit, let budget = requestBudget {
                await budget.release(downloadID: downloadID, host: url.host)
                acquiredPermit = false
            }
        } catch {
            if acquiredPermit, let budget = requestBudget {
                await budget.release(downloadID: downloadID, host: url.host)
                acquiredPermit = false
            }
            throw error
        }
    }

    private func executeSegmentDownload(
        url: URL,
        segment: DownloadSegment,
        completedBytes: Int64,
        expectedTotalSize: Int64?,
        headers: [String: String],
        eTag: String?,
        networkPolicy: DownloadNetworkPolicy = .anyNetwork,
        progress: ProgressHandler?
    ) async throws {
        let startOffset = segment.startOffset + completedBytes
        let endOffset = segment.endOffset
        let expectedBytesToReceive = segment.length - completedBytes

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.allowsCellularAccess = networkPolicy.allowsCellularAccess
        #if canImport(Darwin)
        if #available(iOS 13.0, macOS 10.15, *) {
            request.allowsExpensiveNetworkAccess = networkPolicy.allowsCellularAccess
            request.allowsConstrainedNetworkAccess = networkPolicy.allowsCellularAccess
        }
        #endif

        // HTTP Range Header: bytes=start-end (inclusive)
        request.setValue("bytes=\(startOffset)-\(endOffset)", forHTTPHeaderField: "Range")

        // Mandatory byte-safe transfer encoding (C1569kI.java:L57)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        if let eTag = eTag, !eTag.isEmpty {
            request.setValue(eTag, forHTTPHeaderField: "If-Range")
        }

        for (name, value) in headers {
            if name.caseInsensitiveCompare("Accept-Encoding") == .orderedSame ||
               name.caseInsensitiveCompare("Range") == .orderedSame {
                continue
            }
            request.setValue(value, forHTTPHeaderField: name)
        }

        request = await DownloadRequestEnricher.enrichAsync(request)

        let chunkStream = URLSessionDataChunkStream(session: session, request: request)
        defer { chunkStream.cancel() }

        let httpResponse: HTTPURLResponse
        do {
            httpResponse = try await chunkStream.start()
        } catch is CancellationError {
            throw SegmentDownloaderError.cancelled
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw SegmentDownloaderError.cancelled
        } catch let urlError as URLError where urlError.code == .badServerResponse {
            throw SegmentDownloaderError.invalidHTTPResponse
        } catch {
            throw error
        }

        if let allHeaders = httpResponse.allHeaderFields as? [String: String] {
            DownloadRequestEnricher.recordResponseCookies(headers: allHeaders, for: url)
        }

        if httpResponse.statusCode == 401 {
            throw SegmentDownloaderError.tokenExpired
        }

        if httpResponse.statusCode == 403 {
            throw SegmentDownloaderError.accessDenied
        }

        if httpResponse.statusCode == 404 || httpResponse.statusCode == 410 {
            throw SegmentDownloaderError.linkExpired
        }

        if httpResponse.statusCode == 429 {
            let retryAfter = HTTPRangeProbe.parseRetryAfter(httpResponse.value(forHTTPHeaderField: "Retry-After"))
            throw SegmentDownloaderError.rateLimited(retryAfterSeconds: retryAfter)
        }

        // Strict 206 Partial Content enforcement (C1569kI.java:L126 & e.java:L5649)
        guard httpResponse.statusCode == 206 else {
            throw SegmentDownloaderError.unexpectedStatus(expected: 206, actual: httpResponse.statusCode)
        }

        // Validate Content-Type: reject HTML error/captive portal pages when downloading binary data
        if let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type")?.lowercased() {
            if contentType.contains("text/html") || contentType.contains("application/xhtml+xml") {
                if (expectedTotalSize ?? 0) > 64 * 1024 || (expectedTotalSize == nil && segment.length > 64 * 1024) {
                    throw SegmentDownloaderError.htmlErrorPageReceived(contentType: contentType)
                }
            }
        }

        // Validate Content-Range boundaries and total file size
        try validateContentRange(
            httpResponse.value(forHTTPHeaderField: "Content-Range"),
            expectedStart: startOffset,
            expectedEnd: endOffset,
            expectedTotalSize: expectedTotalSize
        )

        var currentOffset = startOffset
        var receivedThisSession: Int64 = 0

        do {
            while let chunk = try await chunkStream.next() {
                try Task.checkCancellation()

                // URLSession has already coalesced network bytes into this Data
                // chunk. Keep that chunk intact for the file write; unlike the
                // old AsyncBytes loop, no async suspension occurs per byte.
                if globalBandwidthLimiter != nil || perDownloadBandwidthLimiter != nil {
                    try await BandwidthLimiter.throttle(
                        bytes: Int64(chunk.count),
                        global: globalBandwidthLimiter,
                        perDownload: perDownloadBandwidthLimiter
                    )
                }

                try await writer.writeDirect(chunk, at: currentOffset)
                currentOffset += Int64(chunk.count)
                receivedThisSession += Int64(chunk.count)
                speedTracker?.record(bytes: Int64(chunk.count))

                progress?(SegmentDownloadSnapshot(
                    bytesReceived: completedBytes + receivedThisSession,
                    expectedBytes: segment.length,
                    completedSegments: 0,
                    totalSegments: 1
                ))
            }
        } catch is CancellationError {
            throw SegmentDownloaderError.cancelled
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw SegmentDownloaderError.cancelled
        }

        // Validate exact body length matches expected slice
        guard receivedThisSession == expectedBytesToReceive else {
            throw SegmentDownloaderError.bodyLengthMismatch(
                expected: expectedBytesToReceive,
                actual: receivedThisSession
            )
        }

        progress?(SegmentDownloadSnapshot(
            bytesReceived: segment.length,
            expectedBytes: segment.length,
            completedSegments: 1,
            totalSegments: 1
        ))
    }

    // MARK: - Validation

    private func validateContentRange(
        _ headerValue: String?,
        expectedStart: Int64,
        expectedEnd: Int64,
        expectedTotalSize: Int64?
    ) throws {
        guard let value = headerValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            throw SegmentDownloaderError.invalidContentRange
        }

        // Expected format: "bytes <start>-<end>/<total>"
        let parts = value.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "bytes" else {
            throw SegmentDownloaderError.invalidContentRange
        }

        let rangeAndTotal = parts[1].split(separator: "/", maxSplits: 1)
        guard rangeAndTotal.count == 2 else {
            throw SegmentDownloaderError.invalidContentRange
        }

        let bounds = rangeAndTotal[0].split(separator: "-", maxSplits: 1)
        guard bounds.count == 2,
              let actualStart = Int64(bounds[0].trimmingCharacters(in: .whitespaces)),
              let actualEnd = Int64(bounds[1].trimmingCharacters(in: .whitespaces)) else {
            throw SegmentDownloaderError.invalidContentRange
        }

        guard actualStart == expectedStart, actualEnd == expectedEnd else {
            throw SegmentDownloaderError.contentRangeMismatch(
                expectedStart: expectedStart,
                expectedEnd: expectedEnd,
                actualStart: actualStart,
                actualEnd: actualEnd
            )
        }

        let totalStr = String(rangeAndTotal[1]).trimmingCharacters(in: .whitespaces)
        if totalStr != "*", let actualTotal = Int64(totalStr), let expectedTotal = expectedTotalSize {
            guard actualTotal == expectedTotal else {
                throw SegmentDownloaderError.totalSizeMismatch(expected: expectedTotal, actual: actualTotal)
            }
        }
    }
}
