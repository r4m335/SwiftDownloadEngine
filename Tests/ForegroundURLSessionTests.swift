import XCTest
@testable import DownloadEngineKit

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
        #if canImport(Darwin)
        XCTAssertTrue(configuration.waitsForConnectivity)
        #endif
    }
}
