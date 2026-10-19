import XCTest
@testable import DM_Reverse_engineering

final class SegmentDownloaderTests: XCTestCase {
    private var session: URLSession!
    private var tempDirectory: URL!
    
    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)
        
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("1DM_Tests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }
    
    override func tearDown() {
        MockURLProtocol.reset()
        session = nil
        if let tempDir = tempDirectory {
            try? FileManager.default.removeItem(at: tempDir)
        }
        super.tearDown()
    }
    
    // MARK: - 1. Valid 206 Partial Content Download
    
    func testSuccessfulSegmentDownload206() async throws {
        let testURL = URL(string: "https://example.com/file.bin")!
        let fileURL = tempDirectory.appendingPathComponent("test_206.bin")
        let totalSize: Int64 = 1000
        
        let segment = DownloadSegment(id: 1, startOffset: 100, endOffset: 199, length: 100)
        let payload = Data((0..<100).map { UInt8($0 % 256) })
        
        MockURLProtocol.setHandler(for: testURL) { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=100-199")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
            
            let headers = [
                "Content-Range": "bytes 100-199/1000",
                "Content-Length": "100"
            ]
            let response = HTTPURLResponse(url: testURL, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: headers)!
            return (response, payload)
        }
        
        let writer = try DownloadFileWriter(destinationURL: fileURL, totalSize: totalSize)
        let downloader = SegmentDownloader(session: session, writer: writer)
        
        final class ProgressCollector: @unchecked Sendable {
            private(set) var snapshots: [SegmentDownloadSnapshot] = []
            private let lock = NSLock()
            func record(_ snapshot: SegmentDownloadSnapshot) {
                lock.lock()
                defer { lock.unlock() }
                snapshots.append(snapshot)
            }
        }
        let collector = ProgressCollector()
        try await downloader.download(
            url: testURL,
            segment: segment,
            expectedTotalSize: totalSize
        ) { snapshot in
            collector.record(snapshot)
        }
        
        try await writer.synchronize()
        try await writer.close()
        
        // Verify written data
        let writtenData = try Data(contentsOf: fileURL)
        XCTAssertEqual(writtenData.count, Int(totalSize))
        
        // Bytes before offset 100 should be untouched zeroes
        let prefix = writtenData[0..<100]
        XCTAssertEqual(prefix, Data(repeating: 0, count: 100))
        
        // Bytes at 100..<200 must match payload exactly
        let sliceData = writtenData[100..<200]
        XCTAssertEqual(sliceData, payload)
        
        // Progress was reported
        XCTAssertFalse(collector.snapshots.isEmpty)
        XCTAssertEqual(collector.snapshots.last?.bytesReceived, 100)
    }
    
    // MARK: - 2. Ignored Range: Server Returns 200 OK
    
    func testServerReturns200ThrowsUnexpectedStatus() async throws {
        let testURL = URL(string: "https://example.com/no_range.bin")!
        let fileURL = tempDirectory.appendingPathComponent("test_200.bin")
        let totalSize: Int64 = 500
        
        let segment = DownloadSegment(id: 0, startOffset: 0, endOffset: 99, length: 100)
        
        MockURLProtocol.setHandler(for: testURL) { _ in
            let headers = ["Content-Length": "500"]
            let response = HTTPURLResponse(url: testURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
            return (response, Data(repeating: 0x42, count: 500))
        }
        
        let writer = try DownloadFileWriter(destinationURL: fileURL, totalSize: totalSize)
        let downloader = SegmentDownloader(session: session, writer: writer)
        
        do {
            try await downloader.download(url: testURL, segment: segment)
            XCTFail("Expected unexpectedStatus error")
        } catch let error as SegmentDownloaderError {
            XCTAssertEqual(error, .unexpectedStatus(expected: 206, actual: 200))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
        
        try await writer.close()
    }
    
    // MARK: - 3. Content-Range Validation
    
    func testMissingOrMalformedContentRangeHeaderThrows() async throws {
        let testURL = URL(string: "https://example.com/bad_header.bin")!
        let fileURL = tempDirectory.appendingPathComponent("test_bad_header.bin")
        let segment = DownloadSegment(id: 0, startOffset: 0, endOffset: 99, length: 100)
        
        // Case A: Missing Content-Range
        MockURLProtocol.setHandler(for: testURL) { _ in
            let response = HTTPURLResponse(url: testURL, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: [:])!
            return (response, Data(repeating: 0, count: 100))
        }
        
        let writer = try DownloadFileWriter(destinationURL: fileURL, totalSize: 100)
        let downloader = SegmentDownloader(session: session, writer: writer)
        
        do {
            try await downloader.download(url: testURL, segment: segment)
            XCTFail("Expected invalidContentRange error")
        } catch let error as SegmentDownloaderError {
            XCTAssertEqual(error, .invalidContentRange)
        }
        
        // Case B: Malformed format (e.g. items instead of bytes)
        MockURLProtocol.setHandler(for: testURL) { _ in
            let headers = ["Content-Range": "items 0-99/100"]
            let response = HTTPURLResponse(url: testURL, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: headers)!
            return (response, Data(repeating: 0, count: 100))
        }
        
        do {
            try await downloader.download(url: testURL, segment: segment)
            XCTFail("Expected invalidContentRange error")
        } catch let error as SegmentDownloaderError {
            XCTAssertEqual(error, .invalidContentRange)
        }
        
        try await writer.close()
    }
    
    func testContentRangeBoundaryMismatchThrows() async throws {
        let testURL = URL(string: "https://example.com/mismatch.bin")!
        let fileURL = tempDirectory.appendingPathComponent("test_mismatch.bin")
        
        // We request bytes 100-199
        let segment = DownloadSegment(id: 1, startOffset: 100, endOffset: 199, length: 100)
        
        MockURLProtocol.setHandler(for: testURL) { _ in
            // Server erroneously sends bytes 0-99
            let headers = ["Content-Range": "bytes 0-99/1000"]
            let response = HTTPURLResponse(url: testURL, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: headers)!
            return (response, Data(repeating: 0, count: 100))
        }
        
        let writer = try DownloadFileWriter(destinationURL: fileURL, totalSize: 1000)
        let downloader = SegmentDownloader(session: session, writer: writer)
        
        do {
            try await downloader.download(url: testURL, segment: segment)
            XCTFail("Expected contentRangeMismatch error")
        } catch let error as SegmentDownloaderError {
            XCTAssertEqual(error, .contentRangeMismatch(expectedStart: 100, expectedEnd: 199, actualStart: 0, actualEnd: 99))
        }
        
        try await writer.close()
    }
    
    func testTotalSizeMismatchAgainstProbeThrows() async throws {
        let testURL = URL(string: "https://example.com/size_mismatch.bin")!
        let fileURL = tempDirectory.appendingPathComponent("test_size_mismatch.bin")
        let segment = DownloadSegment(id: 0, startOffset: 0, endOffset: 99, length: 100)
        
        MockURLProtocol.setHandler(for: testURL) { _ in
            // Server reports total 9999, but probe had established 5000
            let headers = ["Content-Range": "bytes 0-99/9999"]
            let response = HTTPURLResponse(url: testURL, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: headers)!
            return (response, Data(repeating: 0, count: 100))
        }
        
        let writer = try DownloadFileWriter(destinationURL: fileURL, totalSize: 5000)
        let downloader = SegmentDownloader(session: session, writer: writer)
        
        do {
            try await downloader.download(url: testURL, segment: segment, expectedTotalSize: 5000)
            XCTFail("Expected totalSizeMismatch error")
        } catch let error as SegmentDownloaderError {
            XCTAssertEqual(error, .totalSizeMismatch(expected: 5000, actual: 9999))
        }
        
        try await writer.close()
    }
    
    // MARK: - 4. Body Length Validation
    
    func testShortBodyThrowsBodyLengthMismatch() async throws {
        let testURL = URL(string: "https://example.com/short_body.bin")!
        let fileURL = tempDirectory.appendingPathComponent("test_short_body.bin")
        let segment = DownloadSegment(id: 0, startOffset: 0, endOffset: 99, length: 100)
        
        MockURLProtocol.setHandler(for: testURL) { _ in
            let headers = ["Content-Range": "bytes 0-99/1000"]
            let response = HTTPURLResponse(url: testURL, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: headers)!
            // Only 40 bytes provided instead of 100
            return (response, Data(repeating: 0xEE, count: 40))
        }
        
        let writer = try DownloadFileWriter(destinationURL: fileURL, totalSize: 1000)
        let downloader = SegmentDownloader(session: session, writer: writer)
        
        do {
            try await downloader.download(url: testURL, segment: segment)
            XCTFail("Expected bodyLengthMismatch error")
        } catch let error as SegmentDownloaderError {
            XCTAssertEqual(error, .bodyLengthMismatch(expected: 100, actual: 40))
        }
        
        try await writer.close()
    }
    
    // MARK: - 5. Cancellation
    
    func testTaskCancellationThrowsCancelled() async throws {
        let testURL = URL(string: "https://example.com/slow_stream.bin")!
        let fileURL = tempDirectory.appendingPathComponent("test_cancel.bin")
        let segment = DownloadSegment(id: 0, startOffset: 0, endOffset: 99999, length: 100000)
        
        MockURLProtocol.setHandler(for: testURL) { _ in
            let headers = ["Content-Range": "bytes 0-99999/100000"]
            let response = HTTPURLResponse(url: testURL, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: headers)!
            // 100,000 bytes
            return (response, Data(repeating: 0x01, count: 100000))
        }
        
        let writer = try DownloadFileWriter(destinationURL: fileURL, totalSize: 100000)
        let downloader = SegmentDownloader(session: session, writer: writer)
        
        let downloadTask = Task {
            try await downloader.download(url: testURL, segment: segment)
        }
        
        // Cancel task immediately
        downloadTask.cancel()
        
        do {
            try await downloadTask.value
            XCTFail("Expected task cancellation error")
        } catch let error as SegmentDownloaderError {
            XCTAssertEqual(error, .cancelled)
        } catch is CancellationError {
            // Also acceptable cancellation signal
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
        
        try await writer.close()
    }
    
    // MARK: - 6. Concurrent Multi-Segment Download Into Shared Writer
    
    func testConcurrentSegmentDownloadsWriteCorrectly() async throws {
        let testURL = URL(string: "https://example.com/multi_part.bin")!
        let fileURL = tempDirectory.appendingPathComponent("multi_part_dest.bin")
        let totalSize: Int64 = 400
        
        // 4 contiguous segments of 100 bytes each
        let segments = [
            DownloadSegment(id: 0, startOffset: 0, endOffset: 99, length: 100),
            DownloadSegment(id: 1, startOffset: 100, endOffset: 199, length: 100),
            DownloadSegment(id: 2, startOffset: 200, endOffset: 299, length: 100),
            DownloadSegment(id: 3, startOffset: 300, endOffset: 399, length: 100)
        ]
        
        let pattern0 = Data(repeating: 0x11, count: 100)
        let pattern1 = Data(repeating: 0x22, count: 100)
        let pattern2 = Data(repeating: 0x33, count: 100)
        let pattern3 = Data(repeating: 0x44, count: 100)
        
        MockURLProtocol.setHandler(for: testURL) { request in
            guard let rangeHeader = request.value(forHTTPHeaderField: "Range") else {
                let resp = HTTPURLResponse(url: testURL, statusCode: 400, httpVersion: "HTTP/1.1", headerFields: [:])!
                return (resp, Data())
            }
            
            let data: Data
            let contentRange: String
            switch rangeHeader {
            case "bytes=0-99":
                data = pattern0
                contentRange = "bytes 0-99/400"
            case "bytes=100-199":
                data = pattern1
                contentRange = "bytes 100-199/400"
            case "bytes=200-299":
                data = pattern2
                contentRange = "bytes 200-299/400"
            case "bytes=300-399":
                data = pattern3
                contentRange = "bytes 300-399/400"
            default:
                let resp = HTTPURLResponse(url: testURL, statusCode: 416, httpVersion: "HTTP/1.1", headerFields: [:])!
                return (resp, Data())
            }
            
            let headers = [
                "Content-Range": contentRange,
                "Content-Length": String(data.count)
            ]
            let resp = HTTPURLResponse(url: testURL, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: headers)!
            return (resp, data)
        }
        
        let writer = try DownloadFileWriter(destinationURL: fileURL, totalSize: totalSize)
        let downloader = SegmentDownloader(session: session, writer: writer)
        
        // Execute concurrent downloads via TaskGroup
        try await withThrowingTaskGroup(of: Void.self) { group in
            for segment in segments {
                group.addTask {
                    try await downloader.download(
                        url: testURL,
                        segment: segment,
                        expectedTotalSize: totalSize
                    )
                }
            }
            try await group.waitForAll()
        }
        
        try await writer.synchronize()
        try await writer.close()
        
        // Verify final file contents
        let writtenData = try Data(contentsOf: fileURL)
        XCTAssertEqual(writtenData.count, 400)
        XCTAssertEqual(writtenData[0..<100], pattern0)
        XCTAssertEqual(writtenData[100..<200], pattern1)
        XCTAssertEqual(writtenData[200..<300], pattern2)
        XCTAssertEqual(writtenData[300..<400], pattern3)
    }
    
    // MARK: - 7. Partial Segment Resume
    
    func testPartialSegmentResumeFetchesRemainingBytesOnly() async throws {
        let testURL = URL(string: "https://example.com/resume.bin")!
        let fileURL = tempDirectory.appendingPathComponent("test_resume.bin")
        let totalSize: Int64 = 200
        
        // Segment was 0-199, but 50 bytes were already downloaded previously
        let segment = DownloadSegment(id: 0, startOffset: 0, endOffset: 199, length: 200)
        let remainingPayload = Data(repeating: 0x77, count: 150)
        
        MockURLProtocol.setHandler(for: testURL) { request in
            // Must ask for bytes=50-199
            XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=50-199")
            
            let headers = [
                "Content-Range": "bytes 50-199/200",
                "Content-Length": "150"
            ]
            let response = HTTPURLResponse(url: testURL, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: headers)!
            return (response, remainingPayload)
        }
        
        let writer = try DownloadFileWriter(destinationURL: fileURL, totalSize: totalSize)
        // Pre-fill the first 50 bytes with existing data
        try await writer.writeDirect(Data(repeating: 0x11, count: 50), at: 0)
        
        let downloader = SegmentDownloader(session: session, writer: writer)
        try await downloader.download(
            url: testURL,
            segment: segment,
            completedBytes: 50,
            expectedTotalSize: totalSize
        )
        
        try await writer.synchronize()
        try await writer.close()
        
        let writtenData = try Data(contentsOf: fileURL)
        XCTAssertEqual(writtenData.count, 200)
        XCTAssertEqual(writtenData[0..<50], Data(repeating: 0x11, count: 50))
        XCTAssertEqual(writtenData[50..<200], remainingPayload)
    }
    
    // MARK: - 8. End-to-End Pipeline Integration (Probe -> Allocator -> Downloader)
    
    func testEndToEndProbeAllocatorDownloaderIntegration() async throws {
        let targetURL = URL(string: "https://example.com/ubuntu-mini.iso")!
        let fileURL = tempDirectory.appendingPathComponent("ubuntu-mini.iso")
        let fileSize: Int64 = 3 * 1024 * 1024 // 3 MiB
        
        // Step 1: Mock Probe response (bytes=0-)
        MockURLProtocol.setHandler(for: targetURL) { request in
            let range = request.value(forHTTPHeaderField: "Range") ?? ""
            
            if range == "bytes=0-" {
                let headers = [
                    "Content-Range": "bytes 0-0/\(fileSize)",
                    "Content-Type": "application/x-iso9660-image",
                    "Content-Disposition": "attachment; filename=\"ubuntu-mini.iso\"",
                    "ETag": "\"iso-v1\""
                ]
                let resp = HTTPURLResponse(url: targetURL, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: headers)!
                return (resp, Data([0x00]))
            }
            
            // Step 3: Handle segment range requests
            let parts = range.replacingOccurrences(of: "bytes=", with: "").split(separator: "-")
            guard parts.count == 2, let start = Int64(parts[0]), let end = Int64(parts[1]) else {
                let resp = HTTPURLResponse(url: targetURL, statusCode: 416, httpVersion: "HTTP/1.1", headerFields: [:])!
                return (resp, Data())
            }
            
            let count = Int(end - start + 1)
            let chunkData = Data((0..<count).map { UInt8(($0 + Int(start)) % 256) })
            let headers = [
                "Content-Range": "bytes \(start)-\(end)/\(fileSize)",
                "Content-Length": String(count)
            ]
            let resp = HTTPURLResponse(url: targetURL, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: headers)!
            return (resp, chunkData)
        }
        
        // Pipeline Execution:
        // 1. Probe
        let probe = HTTPRangeProbe(session: session)
        let probeResult = try await probe.probe(url: targetURL)
        XCTAssertTrue(probeResult.supportsRange)
        XCTAssertEqual(probeResult.totalSize, fileSize)
        XCTAssertEqual(probeResult.suggestedFilename, "ubuntu-mini.iso")
        
        // 2. Allocate Segments
        let segments = try SegmentAllocator.makeSegments(
            totalSize: probeResult.totalSize!,
            configuredThreadCount: 10,
            advancedMode: false
        )
        XCTAssertEqual(segments.count, 2)
        
        // 3. Download Segments Concurrently
        let writer = try DownloadFileWriter(destinationURL: fileURL, totalSize: probeResult.totalSize!)
        let downloader = SegmentDownloader(session: session, writer: writer)
        
        try await withThrowingTaskGroup(of: Void.self) { group in
            for segment in segments {
                group.addTask {
                    try await downloader.download(
                        url: probeResult.finalURL,
                        segment: segment,
                        expectedTotalSize: probeResult.totalSize,
                        eTag: probeResult.eTag
                    )
                }
            }
            try await group.waitForAll()
        }
        
        try await writer.synchronize()
        try await writer.close()
        
        // 4. Verify Final Assembly & Integrity
        let finalData = try Data(contentsOf: fileURL)
        XCTAssertEqual(finalData.count, Int(fileSize))
        
        // Verify byte sequence integrity across the entire 3 MiB file
        let expectedData = Data((0..<Int(fileSize)).map { UInt8($0 % 256) })
        XCTAssertEqual(finalData, expectedData)
    }

    // MARK: - 11. HTML Error Page Detection

    func testHtmlErrorPageReceivedThrowsError() async throws {
        let testURL = URL(string: "https://example.com/binary.bin")!
        let fileURL = tempDirectory.appendingPathComponent("test_html_error.bin")
        let totalSize: Int64 = 1_000_000

        let segment = DownloadSegment(id: 0, startOffset: 0, endOffset: 499_999, length: 500_000)
        let htmlPayload = "<html><body><h1>403 Forbidden / Login Required</h1></body></html>".data(using: .utf8)!

        MockURLProtocol.setHandler(for: testURL) { _ in
            let headers = [
                "Content-Type": "text/html; charset=utf-8",
                "Content-Length": String(htmlPayload.count),
                "Content-Range": "bytes 0-499999/1000000"
            ]
            let response = HTTPURLResponse(url: testURL, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: headers)!
            return (response, htmlPayload)
        }

        let writer = try DownloadFileWriter(destinationURL: fileURL, totalSize: totalSize)
        let downloader = SegmentDownloader(session: session, writer: writer)

        do {
            try await downloader.download(
                url: testURL,
                segment: segment,
                expectedTotalSize: totalSize
            )
            XCTFail("Expected htmlErrorPageReceived error")
        } catch let error as SegmentDownloaderError {
            if case .htmlErrorPageReceived(let type) = error {
                XCTAssertTrue(type.contains("text/html"))
            } else {
                XCTFail("Unexpected SegmentDownloaderError case: \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        try await writer.close()
    }
}
