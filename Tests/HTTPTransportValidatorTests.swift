import Foundation
import XCTest
@testable import SwiftDownloadEngine

final class HTTPTransportValidatorTests: XCTestCase {

    // MARK: - Content-Range Parsing Tests

    func testParseContentRangeValid() throws {
        let (start, end, total) = try HTTPTransportValidator.parseContentRange("bytes 0-499/1234")
        XCTAssertEqual(start, 0)
        XCTAssertEqual(end, 499)
        XCTAssertEqual(total, 1234)
    }

    func testParseContentRangeWildcardTotal() throws {
        let (start, end, total) = try HTTPTransportValidator.parseContentRange("bytes 500-999/*")
        XCTAssertEqual(start, 500)
        XCTAssertEqual(end, 999)
        XCTAssertNil(total)
    }

    func testParseContentRangeInvalid() {
        XCTAssertThrowsError(try HTTPTransportValidator.parseContentRange("invalid"))
        XCTAssertThrowsError(try HTTPTransportValidator.parseContentRange("bytes invalid"))
        XCTAssertThrowsError(try HTTPTransportValidator.parseContentRange("bytes 100-50/200"))
        XCTAssertThrowsError(try HTTPTransportValidator.parseContentRange("bytes 0-100"))
    }

    // MARK: - Content-Range Validation Tests

    func testValidateContentRangeSuccess() throws {
        XCTAssertNoThrow(
            try HTTPTransportValidator.validateContentRange(
                "bytes 0-499/1000",
                expectedStart: 0,
                expectedEnd: 499,
                expectedTotalSize: 1000
            )
        )
    }

    func testValidateContentRangeBoundaryMismatch() {
        XCTAssertThrowsError(
            try HTTPTransportValidator.validateContentRange(
                "bytes 0-499/1000",
                expectedStart: 100,
                expectedEnd: 499,
                expectedTotalSize: 1000
            )
        ) { error in
            guard case HTTPTransportValidator.Error.contentRangeMismatch(let expS, _, let actS, _) = error else {
                XCTFail("Expected contentRangeMismatch, got \(error)")
                return
            }
            XCTAssertEqual(expS, 100)
            XCTAssertEqual(actS, 0)
        }
    }

    func testValidateContentRangeTotalSizeMismatch() {
        XCTAssertThrowsError(
            try HTTPTransportValidator.validateContentRange(
                "bytes 0-499/2000",
                expectedStart: 0,
                expectedEnd: 499,
                expectedTotalSize: 1000
            )
        ) { error in
            guard case HTTPTransportValidator.Error.totalSizeMismatch(let exp, let act) = error else {
                XCTFail("Expected totalSizeMismatch, got \(error)")
                return
            }
            XCTAssertEqual(exp, 1000)
            XCTAssertEqual(act, 2000)
        }
    }

    func testValidateContentRangeWildcardTotalRejection() {
        XCTAssertThrowsError(
            try HTTPTransportValidator.validateContentRange(
                "bytes 0-499/*",
                expectedStart: 0,
                expectedEnd: 499,
                expectedTotalSize: 1000,
                allowWildcardTotal: false
            )
        ) { error in
            guard case HTTPTransportValidator.Error.wildcardTotalRejected = error else {
                XCTFail("Expected wildcardTotalRejected, got \(error)")
                return
            }
        }
    }

    // MARK: - HTML Sniffing Tests

    func testIsHTMLResponseContentType() {
        XCTAssertTrue(HTTPTransportValidator.isHTMLResponse(contentType: "text/html"))
        XCTAssertTrue(HTTPTransportValidator.isHTMLResponse(contentType: "text/html; charset=utf-8"))
        XCTAssertTrue(HTTPTransportValidator.isHTMLResponse(contentType: "application/xhtml+xml"))
        XCTAssertFalse(HTTPTransportValidator.isHTMLResponse(contentType: "video/mp4"))
        XCTAssertFalse(HTTPTransportValidator.isHTMLResponse(contentType: "application/octet-stream"))
    }

    func testIsHTMLResponseBodyPrefix() {
        let htmlDoc = "<!DOCTYPE html><html><head><title>Login</title></head><body>Login required</body></html>"
        XCTAssertTrue(HTTPTransportValidator.isHTMLResponse(contentType: "binary/octet-stream", bodyPrefix: Data(htmlDoc.utf8)))

        let binaryData = Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70]) // ftyp box
        XCTAssertFalse(HTTPTransportValidator.isHTMLResponse(contentType: "binary/octet-stream", bodyPrefix: binaryData))
    }

    // MARK: - Header Normalization Tests

    func testNormalizeRequestEnforcesAcceptEncodingIdentity() {
        let url = URL(string: "https://example.com/file.bin")!
        let request = HTTPTransportValidator.normalizeRequest(
            url: url,
            headers: ["Accept-Encoding": "gzip, deflate, br", "Custom-Header": "value"]
        )

        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Custom-Header"), "value")
    }

    func testNormalizeRequestAppliesByteRange() {
        let url = URL(string: "https://example.com/file.bin")!
        let request = HTTPTransportValidator.normalizeRequest(
            url: url,
            byteRange: (start: 1000, end: 1999)
        )

        XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=1000-1999")
    }

    // MARK: - Status Discrimination Tests

    func testValidateResponseStatus() throws {
        let makeResponse: (Int) -> HTTPURLResponse = { code in
            HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: code, httpVersion: nil, headerFields: nil)!
        }

        XCTAssertNoThrow(try HTTPTransportValidator.validateResponseStatus(makeResponse(206), expectingPartial: true))
        XCTAssertThrowsError(try HTTPTransportValidator.validateResponseStatus(makeResponse(200), expectingPartial: true))
        XCTAssertThrowsError(try HTTPTransportValidator.validateResponseStatus(makeResponse(401), expectingPartial: false)) {
            XCTAssertEqual($0 as? HTTPTransportValidator.Error, .tokenExpired)
        }
        XCTAssertThrowsError(try HTTPTransportValidator.validateResponseStatus(makeResponse(403), expectingPartial: false)) {
            XCTAssertEqual($0 as? HTTPTransportValidator.Error, .accessDenied)
        }
        XCTAssertThrowsError(try HTTPTransportValidator.validateResponseStatus(makeResponse(404), expectingPartial: false)) {
            XCTAssertEqual($0 as? HTTPTransportValidator.Error, .linkExpired)
        }
    }
}
