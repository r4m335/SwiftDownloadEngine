import XCTest
@testable import DM_Reverse_engineering

final class HTTPRetryPolicyTests: XCTestCase {
    func testOnlyServerErrorsAndRateLimitsRetry() {
        XCTAssertTrue(HTTPRetryPolicy.isRetryable(SegmentDownloaderError.unexpectedStatus(expected: 206, actual: 500)))
        XCTAssertTrue(HTTPRetryPolicy.isRetryable(SegmentDownloaderError.rateLimited(retryAfterSeconds: nil)))
        XCTAssertFalse(HTTPRetryPolicy.isRetryable(SegmentDownloaderError.unexpectedStatus(expected: 206, actual: 400)))
        XCTAssertFalse(HTTPRetryPolicy.isRetryable(SegmentDownloaderError.tokenExpired))
        XCTAssertFalse(HTTPRetryPolicy.isRetryable(SegmentDownloaderError.accessDenied))
        XCTAssertFalse(HTTPRetryPolicy.isRetryable(SegmentDownloaderError.linkExpired))
    }

    func testProbeClassifiesServerAndNetworkFailures() {
        XCTAssertTrue(HTTPRetryPolicy.isRetryable(
            HTTPRangeProbeError.unsupportedResponse(statusCode: 503, message: "unavailable")
        ))
        XCTAssertTrue(HTTPRetryPolicy.isRetryable(
            HTTPRangeProbeError.networkError("offline", code: URLError.Code.notConnectedToInternet.rawValue)
        ))
        XCTAssertTrue(HTTPRetryPolicy.shouldWaitForConnectivity(
            HTTPRangeProbeError.networkError("offline", code: URLError.Code.notConnectedToInternet.rawValue)
        ))
        XCTAssertFalse(HTTPRetryPolicy.isRetryable(HTTPRangeProbeError.resourceNotFound(URL(string: "https://example.com/file")!)))
    }

    func testBackgroundRetryPolicyOnlyRetriesTransientFailures() {
        XCTAssertTrue(HTTPRetryPolicy.isRetryableBackground(
            BackgroundTransportError.unexpectedStatus(expected: 206, actual: 429)
        ))
        XCTAssertTrue(HTTPRetryPolicy.isRetryableBackground(
            BackgroundTransportError.unexpectedStatus(expected: 206, actual: 503)
        ))
        XCTAssertTrue(HTTPRetryPolicy.isRetryableBackground(
            BackgroundTransportError.bodyLengthMismatch(expected: 100, actual: 40)
        ))

        XCTAssertFalse(HTTPRetryPolicy.isRetryableBackground(
            BackgroundTransportError.unexpectedStatus(expected: 206, actual: 401)
        ))
        XCTAssertFalse(HTTPRetryPolicy.isRetryableBackground(
            BackgroundTransportError.unexpectedStatus(expected: 206, actual: 403)
        ))
        XCTAssertFalse(HTTPRetryPolicy.isRetryableBackground(
            BackgroundTransportError.unexpectedStatus(expected: 206, actual: 404)
        ))
        XCTAssertFalse(HTTPRetryPolicy.isRetryableBackground(
            BackgroundTransportError.unexpectedStatus(expected: 206, actual: 410)
        ))
    }

    func testBackgroundRetryPolicyExtractsHTTPStatus() {
        XCTAssertEqual(
            HTTPRetryPolicy.backgroundHTTPStatusCode(
                BackgroundTransportError.unexpectedStatus(expected: 206, actual: 403)
            ),
            403
        )
        XCTAssertNil(
            HTTPRetryPolicy.backgroundHTTPStatusCode(
                BackgroundTransportError.bodyLengthMismatch(expected: 10, actual: 5)
            )
        )

        let statusError = NSError(domain: NSURLErrorDomain, code: -1, userInfo: ["HTTPStatus": 503])
        XCTAssertEqual(HTTPRetryPolicy.backgroundHTTPStatusCode(statusError), 503)

        let dummyURL = URL(string: "https://example.com/test")!
        let httpResponse = HTTPURLResponse(url: dummyURL, statusCode: 429, httpVersion: nil, headerFields: nil)!
        let responseError = NSError(domain: NSURLErrorDomain, code: -1, userInfo: ["response": httpResponse])
        XCTAssertEqual(HTTPRetryPolicy.backgroundHTTPStatusCode(responseError), 429)

        let legacyKeyError = NSError(domain: NSURLErrorDomain, code: -1, userInfo: ["NSErrorFailingURLResponseKey": httpResponse])
        XCTAssertEqual(HTTPRetryPolicy.backgroundHTTPStatusCode(legacyKeyError), 429)
    }

    func testPrematureEOFAndDroppedConnectionClassification() {
        // Darwin standard network drop codes
        XCTAssertTrue(HTTPRetryPolicy.isRetryable(URLError(.networkConnectionLost)))
        XCTAssertTrue(HTTPRetryPolicy.isRetryable(URLError(.timedOut)))
        XCTAssertTrue(HTTPRetryPolicy.isRetryable(URLError(.cannotConnectToHost)))

        // FoundationNetworking / libcurl code -1 premature EOF descriptions
        let missingBytesError = NSError(
            domain: NSURLErrorDomain,
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "end of response with 172032 bytes missing"]
        )
        XCTAssertTrue(HTTPRetryPolicy.isRetryable(missingBytesError))

        let closedStreamError = NSError(
            domain: NSURLErrorDomain,
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "transfer closed with outstanding read data remaining"]
        )
        XCTAssertTrue(HTTPRetryPolicy.isRetryable(closedStreamError))

        let connResetError = NSError(
            domain: NSURLErrorDomain,
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "connection reset by peer"]
        )
        XCTAssertTrue(HTTPRetryPolicy.isRetryable(connResetError))

        let nonRetryableUnknown = NSError(
            domain: NSURLErrorDomain,
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "unsupported custom operation"]
        )
        XCTAssertFalse(HTTPRetryPolicy.isRetryable(nonRetryableUnknown))
    }

    func testCoordinatorErrorsAndUnderlyingNetworkErrors() {
        let dummyURL = URL(string: "https://example.com/segment.ts")!
        XCTAssertTrue(HTTPRetryPolicy.isRetryable(DownloadCoordinatorError.rateLimited(url: dummyURL, retryAfter: 2)))
        XCTAssertTrue(HTTPRetryPolicy.isRetryable(DownloadCoordinatorError.unexpectedSingleStreamError(reason: "Segment resource returned HTTP 503")))
        XCTAssertTrue(HTTPRetryPolicy.isRetryable(DownloadCoordinatorError.unexpectedSingleStreamError(reason: "connection reset")))
        XCTAssertFalse(HTTPRetryPolicy.isRetryable(DownloadCoordinatorError.tokenExpired(url: dummyURL)))
        XCTAssertFalse(HTTPRetryPolicy.isRetryable(DownloadCoordinatorError.accessDenied(url: dummyURL, cooldownUntil: Date())))
        XCTAssertFalse(HTTPRetryPolicy.isRetryable(DownloadCoordinatorError.linkExpired(url: dummyURL)))

        // -1005 network connection lost
        let lostConnectionError = NSError(domain: NSURLErrorDomain, code: -1005, userInfo: [NSLocalizedDescriptionKey: "The network connection was lost."])
        XCTAssertTrue(HTTPRetryPolicy.isRetryable(lostConnectionError))
        XCTAssertTrue(HTTPRetryPolicy.shouldWaitForConnectivity(lostConnectionError))

        // Underlying error wrapped inside NSError
        let wrappedLost = NSError(domain: "CustomDomain", code: 999, userInfo: [NSUnderlyingErrorKey: lostConnectionError])
        XCTAssertTrue(HTTPRetryPolicy.isRetryable(wrappedLost))
        XCTAssertTrue(HTTPRetryPolicy.shouldWaitForConnectivity(wrappedLost))
    }
}
