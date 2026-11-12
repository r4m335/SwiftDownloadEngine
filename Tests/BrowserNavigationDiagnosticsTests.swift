import XCTest
@testable import DM_Reverse_engineering

final class BrowserNavigationDiagnosticsTests: XCTestCase {
    func testCombinedSnapshotIncludesRequestAndFinalHTTPResponseMetadata() {
        var request = URLRequest(url: URL(string: "https://storage.googleapis.com/bucket/movie.mp4")!)
        request.httpMethod = "GET"
        request.setValue("TestBrowser/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        request.setValue("session=private", forHTTPHeaderField: "Cookie")

        let response = HTTPURLResponse(
            url: URL(string: "https://commondatastorage.googleapis.com/bucket/movie.mp4")!,
            statusCode: 403,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "application/xml",
                "Content-Length": "321",
                "Content-Range": "bytes */12345",
                "x-goog-request-id": "request-123",
                "Set-Cookie": "secret-cookie"
            ]
        )!

        let details = BrowserNavigationDiagnosticDetails.combinedDetails(
            request: request,
            response: response
        )

        XCTAssertEqual(details["requestURL"], "https://storage.googleapis.com/bucket/movie.mp4")
        XCTAssertEqual(details["finalURL"], "https://commondatastorage.googleapis.com/bucket/movie.mp4")
        XCTAssertEqual(details["method"], "GET")
        XCTAssertEqual(details["userAgent"], "TestBrowser/1.0")
        XCTAssertEqual(details["range"], "bytes=0-1023")
        XCTAssertEqual(details["statusCode"], "403")
        XCTAssertEqual(details["contentType"], "application/xml")
        XCTAssertEqual(details["contentLength"], "321")
        XCTAssertEqual(details["contentRange"], "bytes */12345")
        XCTAssertTrue(details["requestHeaders"]?.contains("Cookie: <redacted>") == true)
        XCTAssertTrue(details["responseHeaders"]?.contains("Set-Cookie: <redacted>") == true)
        XCTAssertTrue(details["responseHeaders"]?.contains("x-goog-request-id: request-123") == true)
    }

    func testSensitiveSignedURLQueryValuesAreRedacted() {
        let response = HTTPURLResponse(
            url: URL(string: "https://example.com/video.mp4?X-Goog-Signature=private&plain=value")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: [:]
        )!

        let details = BrowserNavigationDiagnosticDetails.responseDetails(response)

        XCTAssertEqual(
            details["finalURL"],
            "https://example.com/video.mp4?X-Goog-Signature=%3Credacted%3E&plain=value"
        )
    }
}
