import XCTest
@testable import DM_Reverse_engineering

final class ForegroundURLSessionTests: XCTestCase {
    func testForegroundSessionIsConfiguredForRangeWorkers() {
        let configuration = SegmentDownloader.sharedSession.configuration

        XCTAssertEqual(
            configuration.httpMaximumConnectionsPerHost,
            SegmentAllocator.maxThreadCount
        )
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 30.0)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 300.0)
        XCTAssertTrue(configuration.waitsForConnectivity)
    }
}
