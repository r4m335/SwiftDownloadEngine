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
}
