import XCTest
@testable import DM_Reverse_engineering // Or standalone module import

// MARK: - Mock URL Protocol for Local Isolated Testing

final class MockURLProtocol: URLProtocol {
    typealias ResponseProvider = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    
    private static let lock = NSLock()
    private static var _providers: [URL: ResponseProvider] = [:]
    
    static func setHandler(for url: URL, handler: @escaping ResponseProvider) {
        lock.lock()
        defer { lock.unlock() }
        _providers[url] = handler
    }
    
    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        _providers.removeAll()
    }
    
    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        lock.lock()
        defer { lock.unlock() }
        return _providers[url] != nil
    }
    
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }
    
    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        
        MockURLProtocol.lock.lock()
        let handler = MockURLProtocol._providers[url]
        MockURLProtocol.lock.unlock()
        
        guard let handler = handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        
        do {
            let (response, data) = try handler(request)
            
            // Check for redirect
            if (300...399).contains(response.statusCode),
               let location = response.allHeaderFields["Location"] as? String,
               let targetURL = URL(string: location, relativeTo: url) {
                let redirectRequest = URLRequest(url: targetURL)
                client?.urlProtocol(self, wasRedirectedTo: redirectRequest, redirectResponse: response)
                return
            }
            
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    
    override func stopLoading() {}
}

// MARK: - Test Suite

final class HTTPRangeProbeTests: XCTestCase {
    private var session: URLSession!
    private var probe: HTTPRangeProbe!
    
    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)
        probe = HTTPRangeProbe(session: session)
    }
    
    override func tearDown() {
        MockURLProtocol.reset()
        session = nil
        probe = nil
        super.tearDown()
    }
    
    // MARK: - 1. Status Code & Range Support Verification
    
    func testProbeRangeSupported206() async throws {
        let testURL = URL(string: "https://example.com/video.mp4")!
        
        MockURLProtocol.setHandler(for: testURL) { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=0-")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Encoding"), "gzip, deflate")
            
            let headers = [
                "Content-Range": "bytes 0-0/104857600",
                "Content-Type": "video/mp4; charset=utf-8",
                "Content-Length": "1",
                "ETag": "\"etag-12345\"",
                "Last-Modified": "Sun, 18 Oct 2026 14:00:00 GMT"
            ]
            let response = HTTPURLResponse(url: testURL, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: headers)!
            return (response, Data([0x00]))
        }
        
        let result = try await probe.probe(url: testURL)
        
        XCTAssertEqual(result.statusCode, 206)
        XCTAssertTrue(result.supportsRange)
        XCTAssertTrue(result.canResume)
        XCTAssertEqual(result.totalSize, 104_857_600)
        XCTAssertEqual(result.mimeType, "video/mp4")
        XCTAssertEqual(result.suggestedFilename, "video.mp4")
        XCTAssertEqual(result.eTag, "\"etag-12345\"")
        XCTAssertEqual(result.lastModified, "Sun, 18 Oct 2026 14:00:00 GMT")
        XCTAssertFalse(result.isRedirected)
    }
    
    func testProbeRangeIgnoredReturns200() async throws {
        let testURL = URL(string: "https://example.com/document.pdf")!
        
        MockURLProtocol.setHandler(for: testURL) { _ in
            let headers = [
                "Content-Length": "5242880",
                "Content-Type": "application/pdf",
                "Accept-Ranges": "none"
            ]
            let response = HTTPURLResponse(url: testURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
            return (response, Data(repeating: 0, count: 100))
        }
        
        let result = try await probe.probe(url: testURL)
        
        XCTAssertEqual(result.statusCode, 200)
        XCTAssertFalse(result.supportsRange)
        XCTAssertFalse(result.canResume)
        XCTAssertEqual(result.totalSize, 5_242_880)
        XCTAssertEqual(result.mimeType, "application/pdf")
        XCTAssertEqual(result.suggestedFilename, "document.pdf")
    }
    
    func testProbeAcceptRangesBytesWith200AllowsResume() async throws {
        let testURL = URL(string: "https://example.com/archive.zip")!
        
        MockURLProtocol.setHandler(for: testURL) { _ in
            let headers = [
                "Content-Length": "20971520",
                "Content-Type": "application/zip",
                "Accept-Ranges": "bytes"
            ]
            let response = HTTPURLResponse(url: testURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
            return (response, Data(repeating: 0, count: 50))
        }
        
        let result = try await probe.probe(url: testURL)
        
        XCTAssertEqual(result.statusCode, 200)
        XCTAssertFalse(result.supportsRange) // 200 means this specific request wasn't sliced
        XCTAssertTrue(result.canResume)      // but server advertises Range support for future slices
        XCTAssertEqual(result.totalSize, 20_971_520)
    }
    
    // MARK: - 2. Redirect Resolution
    
    func testRedirectResolutionCapturesFinalURL() async throws {
        #if !canImport(Darwin)
        throw XCTSkip("Linux swift-corelibs-foundation URLProtocol does not support wasRedirectedTo")
        #endif
        let initialURL = URL(string: "https://example.com/shortlink")!
        let redirectedURL = URL(string: "https://cdn.example.com/files/final_archive.tar.gz")!
        
        MockURLProtocol.setHandler(for: initialURL) { _ in
            let headers = ["Location": redirectedURL.absoluteString]
            let response = HTTPURLResponse(url: initialURL, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: headers)!
            return (response, Data())
        }
        
        MockURLProtocol.setHandler(for: redirectedURL) { _ in
            let headers = [
                "Content-Range": "bytes 0-0/50000000",
                "Content-Type": "application/gzip"
            ]
            let response = HTTPURLResponse(url: redirectedURL, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: headers)!
            return (response, Data([0x1F]))
        }
        
        let result = try await probe.probe(url: initialURL)
        
        XCTAssertTrue(result.isRedirected)
        XCTAssertEqual(result.initialURL, initialURL)
        XCTAssertEqual(result.finalURL, redirectedURL)
        XCTAssertEqual(result.suggestedFilename, "final_archive.tar.gz")
    }
    
    // MARK: - 3. Filename Extraction & Content-Disposition
    
    func testContentDispositionStandardQuotedFilename() async throws {
        let testURL = URL(string: "https://example.com/api/v1/get?id=88231")!
        
        MockURLProtocol.setHandler(for: testURL) { _ in
            let headers = [
                "Content-Disposition": "attachment; filename=\"ubuntu-24.04-desktop.iso\"",
                "Content-Length": "1000"
            ]
            let response = HTTPURLResponse(url: testURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
            return (response, Data())
        }
        
        let result = try await probe.probe(url: testURL)
        XCTAssertEqual(result.suggestedFilename, "ubuntu-24.04-desktop.iso")
    }
    
    func testContentDispositionRFC5987PercentEncodedFilename() async throws {
        let testURL = URL(string: "https://example.com/download_doc")!
        
        MockURLProtocol.setHandler(for: testURL) { _ in
            let headers = [
                "Content-Disposition": "attachment; filename*=UTF-8''Quarterly%20Report%202026.pdf",
                "Content-Length": "1000"
            ]
            let response = HTTPURLResponse(url: testURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
            return (response, Data())
        }
        
        let result = try await probe.probe(url: testURL)
        XCTAssertEqual(result.suggestedFilename, "Quarterly Report 2026.pdf")
    }
    
    func testFilenameFallbackToMimeExtensionWhenURLHasNone() async throws {
        let testURL = URL(string: "https://example.com/media/stream_blob_99")!
        
        MockURLProtocol.setHandler(for: testURL) { _ in
            let headers = [
                "Content-Type": "video/x-matroska",
                "Content-Length": "1000"
            ]
            let response = HTTPURLResponse(url: testURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
            return (response, Data())
        }
        
        let result = try await probe.probe(url: testURL)
        XCTAssertEqual(result.suggestedFilename, "stream_blob_99.mkv")
    }
    
    func testFilenameSanitizationStripsIllegalPathCharacters() {
        let dirty = "../../etc/passwd:colon*star?question|bar\"quote.zip"
        let sanitized = HTTPRangeProbe.sanitizeFilename(dirty)
        XCTAssertFalse(sanitized.contains("/"))
        XCTAssertFalse(sanitized.contains(":"))
        XCTAssertFalse(sanitized.contains("*"))
        XCTAssertFalse(sanitized.contains("?"))
        XCTAssertFalse(sanitized.contains("|"))
        XCTAssertFalse(sanitized.contains("\""))
    }
    
    // MARK: - 4. Length Parsing Edge Cases (UZ.m8426)
    
    func testTikTokCDNCustomLengthFallback() async throws {
        let testURL = URL(string: "https://example.com/tiktok_stream")!
        
        MockURLProtocol.setHandler(for: testURL) { _ in
            // No Content-Length or Content-Range, but CDN supplies X-TTDB-L
            let headers = [
                "X-TTDB-L": "987654321",
                "Content-Type": "video/mp4"
            ]
            let response = HTTPURLResponse(url: testURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
            return (response, Data())
        }
        
        let result = try await probe.probe(url: testURL)
        XCTAssertEqual(result.totalSize, 987_654_321)
    }
    
    func testIndeterminateLengthForChunkedEncoding() async throws {
        let testURL = URL(string: "https://example.com/live_feed")!
        
        MockURLProtocol.setHandler(for: testURL) { _ in
            let headers = [
                "Transfer-Encoding": "chunked",
                "Content-Type": "application/octet-stream"
            ]
            let response = HTTPURLResponse(url: testURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
            return (response, Data())
        }
        
        let result = try await probe.probe(url: testURL)
        XCTAssertNil(result.totalSize)
    }
    
    // MARK: - 5. Error Code Handling
    
    func testHTTP404ThrowsResourceNotFound() async {
        let testURL = URL(string: "https://example.com/missing.zip")!
        
        MockURLProtocol.setHandler(for: testURL) { _ in
            let response = HTTPURLResponse(url: testURL, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: [:])!
            return (response, Data())
        }
        
        do {
            _ = try await probe.probe(url: testURL)
            XCTFail("Expected resourceNotFound error")
        } catch let error as HTTPRangeProbeError {
            XCTAssertEqual(error, .resourceNotFound(testURL))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
    
    func testHTTP416ThrowsRangeNotSatisfiable() async {
        let testURL = URL(string: "https://example.com/invalid_range")!
        
        MockURLProtocol.setHandler(for: testURL) { _ in
            let response = HTTPURLResponse(url: testURL, statusCode: 416, httpVersion: "HTTP/1.1", headerFields: [:])!
            return (response, Data())
        }
        
        do {
            _ = try await probe.probe(url: testURL)
            XCTFail("Expected rangeNotSatisfiable error")
        } catch let error as HTTPRangeProbeError {
            XCTAssertEqual(error, .rangeNotSatisfiable(testURL))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
    
    func testHTTP403ThrowsForbidden() async {
        let testURL = URL(string: "https://example.com/protected")!
        
        MockURLProtocol.setHandler(for: testURL) { _ in
            let response = HTTPURLResponse(url: testURL, statusCode: 403, httpVersion: "HTTP/1.1", headerFields: [:])!
            return (response, Data())
        }
        
        do {
            _ = try await probe.probe(url: testURL)
            XCTFail("Expected forbidden error")
        } catch let error as HTTPRangeProbeError {
            XCTAssertEqual(error, .forbidden(testURL))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testHTTP401DescriptionRedactsSignedQueryValues() async {
        let testURL = URL(string: "https://example.com/protected.zip?token=do-not-log")!

        MockURLProtocol.setHandler(for: testURL) { _ in
            let response = HTTPURLResponse(url: testURL, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: [:])!
            return (response, Data())
        }

        do {
            _ = try await probe.probe(url: testURL)
            XCTFail("Expected unauthorized error")
        } catch let error as HTTPRangeProbeError {
            let description = error.localizedDescription
            XCTAssertTrue(description.contains("Authentication required"))
            XCTAssertFalse(description.contains("do-not-log"))
            XCTAssertTrue(description.contains("REDACTED"))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
}
