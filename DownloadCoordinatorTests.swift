import XCTest
import Foundation
@testable import DM_Reverse_engineering

final class DownloadCoordinatorTests: XCTestCase {
    private var session: URLSession!
    private var tempDirectory: URL!
    private var persistenceStore: DownloadPersistenceStore!
    private var coordinator: DownloadCoordinator!

    override func setUp() async throws {
        try await super.setUp()
        MockURLProtocol.reset()

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)

        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("1DM_Coordinator_Tests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let storeDir = tempDirectory.appendingPathComponent("Store", isDirectory: true)
        persistenceStore = try DownloadPersistenceStore(storageDirectoryURL: storeDir)
        coordinator = try DownloadCoordinator(session: session, persistenceStore: persistenceStore)
    }

    override func tearDown() async throws {
        MockURLProtocol.reset()
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        session = nil
        coordinator = nil
        persistenceStore = nil
        try await super.tearDown()
    }

    // MARK: - 1. End-to-End Multi-Segment Download

    func testSuccessfulConcurrentMultiSegmentDownload() async throws {
        let testURL = URL(string: "https://example.com/multi_test.bin")!
        let destURL = tempDirectory.appendingPathComponent("multi_test.bin")
        let totalSize: Int64 = 3000

        // Server handler:
        // - Probe: Range bytes=0- -> 206
        // - Segments: Range bytes=X-Y -> 206
        MockURLProtocol.setHandler(for: testURL) { request in
            let range = request.value(forHTTPHeaderField: "Range") ?? ""
            if range == "bytes=0-" {
                let headers = [
                    "Content-Range": "bytes 0-0/\(totalSize)",
                    "Content-Length": "1",
                    "ETag": "\"etag-3000\""
                ]
                let resp = HTTPURLResponse(url: testURL, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: headers)!
                return (resp, Data([0xAA]))
            }

            // Parse range bounds
            let parts = range.replacingOccurrences(of: "bytes=", with: "").split(separator: "-")
            guard parts.count == 2, let start = Int64(parts[0]), let end = Int64(parts[1]) else {
                let resp = HTTPURLResponse(url: testURL, statusCode: 416, httpVersion: "HTTP/1.1", headerFields: [:])!
                return (resp, Data())
            }

            let count = Int(end - start + 1)
            let chunk = Data((0..<count).map { UInt8(($0 + Int(start)) % 256) })
            let headers = [
                "Content-Range": "bytes \(start)-\(end)/\(totalSize)",
                "Content-Length": String(count),
                "ETag": "\"etag-3000\""
            ]
            let resp = HTTPURLResponse(url: testURL, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: headers)!
            return (resp, chunk)
        }

        let request = DownloadRequest(
            id: "dl-multi",
            url: testURL,
            destinationURL: destURL,
            configuredThreadCount: 3,
            advancedMode: false,
            reserveDiskBytes: 1024
        )

        var progressHistory: [CoordinatorProgress] = []
        try await coordinator.start(request) { progress in
            progressHistory.append(progress)
        }

        // Verify output file
        let writtenData = try Data(contentsOf: destURL)
        XCTAssertEqual(writtenData.count, Int(totalSize))

        let expectedData = Data((0..<Int(totalSize)).map { UInt8($0 % 256) })
        XCTAssertEqual(writtenData, expectedData)

        // Verify persistence store state
        let record = try await persistenceStore.fetch(tag: "dl-multi")
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.state, .completed)
        XCTAssertEqual(record?.completedBytes, totalSize)

        // Verify progress updates occurred
        XCTAssertFalse(progressHistory.isEmpty)
        XCTAssertEqual(progressHistory.last?.state, .completed)
        XCTAssertEqual(progressHistory.last?.bytesReceived, totalSize)
    }

    // MARK: - 2. Safe Fallback on Ignored Range Request (200 OK)

    func testServerIgnoresRangeAndReturns200TriggersSafeFallback() async throws {
        let testURL = URL(string: "https://example.com/fallback.bin")!
        let destURL = tempDirectory.appendingPathComponent("fallback.bin")
        let totalSize: Int64 = 2000
        let fullPayload = Data((0..<Int(totalSize)).map { UInt8($0 % 128) })

        MockURLProtocol.setHandler(for: testURL) { request in
            let range = request.value(forHTTPHeaderField: "Range")

            if range == "bytes=0-" {
                // Probe succeeds claiming Range support
                let headers = [
                    "Content-Range": "bytes 0-0/\(totalSize)",
                    "Content-Length": "1",
                    "ETag": "\"etag-fallback\""
                ]
                let resp = HTTPURLResponse(url: testURL, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: headers)!
                return (resp, Data([0x01]))
            } else if range != nil {
                // Server drops Range header and returns 200 OK for range workers!
                let headers = [
                    "Content-Length": String(totalSize),
                    "Content-Type": "application/octet-stream"
                ]
                let resp = HTTPURLResponse(url: testURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
                return (resp, fullPayload)
            } else {
                // Single-stream request (no Range header)
                let headers = [
                    "Content-Length": String(totalSize),
                    "Content-Type": "application/octet-stream"
                ]
                let resp = HTTPURLResponse(url: testURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
                return (resp, fullPayload)
            }
        }

        let request = DownloadRequest(
            id: "dl-fallback",
            url: testURL,
            destinationURL: destURL,
            configuredThreadCount: 4,
            reserveDiskBytes: 1024
        )

        try await coordinator.start(request)

        // Verify single stream fallback completed the download without data corruption
        let writtenData = try Data(contentsOf: destURL)
        XCTAssertEqual(writtenData.count, Int(totalSize))
        XCTAssertEqual(writtenData, fullPayload)

        let record = try await persistenceStore.fetch(tag: "dl-fallback")
        XCTAssertEqual(record?.state, .completed)
    }

    // MARK: - 3. Linear Single-Stream Download (No Range Support from Probe)

    func testLinearSingleStreamDownloadWhenRangesUnsupported() async throws {
        let testURL = URL(string: "https://example.com/stream.bin")!
        let destURL = tempDirectory.appendingPathComponent("stream.bin")
        let payload = Data(repeating: 0x55, count: 500)

        MockURLProtocol.setHandler(for: testURL) { _ in
            let headers = [
                "Content-Length": "500",
                "Content-Type": "application/octet-stream"
            ]
            let resp = HTTPURLResponse(url: testURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
            return (resp, payload)
        }

        let request = DownloadRequest(
            id: "dl-stream",
            url: testURL,
            destinationURL: destURL,
            reserveDiskBytes: 1024
        )

        try await coordinator.start(request)

        let writtenData = try Data(contentsOf: destURL)
        XCTAssertEqual(writtenData, payload)

        let record = try await persistenceStore.fetch(tag: "dl-stream")
        XCTAssertEqual(record?.state, .completed)
    }

    // MARK: - 4. Pause, Shutdown Barrier & Resume

    func testPauseAndResumePipeline() async throws {
        let testURL = URL(string: "https://example.com/resumable.bin")!
        let destURL = tempDirectory.appendingPathComponent("resumable.bin")
        let totalSize: Int64 = 400

        // 2 segments: 0-199 and 200-399
        let seg0Payload = Data(repeating: 0x11, count: 200)
        let seg1Payload = Data(repeating: 0x22, count: 200)

        MockURLProtocol.setHandler(for: testURL) { request in
            let range = request.value(forHTTPHeaderField: "Range") ?? ""

            if range == "bytes=0-" {
                let headers = [
                    "Content-Range": "bytes 0-0/400",
                    "ETag": "\"resume-v1\""
                ]
                let resp = HTTPURLResponse(url: testURL, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: headers)!
                return (resp, Data([0x11]))
            } else if range == "bytes=0-199" {
                let headers = ["Content-Range": "bytes 0-199/400"]
                let resp = HTTPURLResponse(url: testURL, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: headers)!
                return (resp, seg0Payload)
            } else if range == "bytes=200-399" {
                let headers = ["Content-Range": "bytes 200-399/400"]
                let resp = HTTPURLResponse(url: testURL, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: headers)!
                return (resp, seg1Payload)
            } else if range == "bytes=300-399" {
                // Resumed segment 1 with 100 bytes remaining
                let headers = ["Content-Range": "bytes 300-399/400"]
                let resp = HTTPURLResponse(url: testURL, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: headers)!
                return (resp, Data(repeating: 0x22, count: 100))
            } else {
                let resp = HTTPURLResponse(url: testURL, statusCode: 416, httpVersion: "HTTP/1.1", headerFields: [:])!
                return (resp, Data())
            }
        }

        // Simulate paused record: segment 0 completed, segment 1 had 100 bytes downloaded
        let segments = [
            SegmentRecord(id: 0, startOffset: 0, endOffset: 199, length: 200, completedBytes: 200),
            SegmentRecord(id: 1, startOffset: 200, endOffset: 399, length: 200, completedBytes: 100)
        ]
        let initialRecord = DownloadRecord(
            id: "dl-resume",
            originalURL: testURL,
            resolvedURL: testURL,
            destinationURL: destURL,
            totalSize: 400,
            state: .paused,
            storageMode: .directSeek,
            eTag: "\"resume-v1\"",
            segments: segments
        )
        try await persistenceStore.save(initialRecord)

        // Pre-populate partial destination file
        let writer = try DownloadFileWriter(destinationURL: destURL, totalSize: 400)
        try await writer.writeDirect(seg0Payload, at: 0)
        try await writer.writeDirect(Data(repeating: 0x22, count: 100), at: 200)
        try await writer.synchronize()
        try await writer.close()

        let request = DownloadRequest(
            id: "dl-resume",
            url: testURL,
            destinationURL: destURL,
            configuredThreadCount: 2,
            reserveDiskBytes: 1024
        )

        // Resume operation
        try await coordinator.resume(request)

        // Verify final assembled file
        let finalData = try Data(contentsOf: destURL)
        XCTAssertEqual(finalData.count, 400)
        XCTAssertEqual(finalData[0..<200], seg0Payload)
        XCTAssertEqual(finalData[200..<400], seg1Payload)

        let record = try await persistenceStore.fetch(tag: "dl-resume")
        XCTAssertEqual(record?.state, .completed)
        XCTAssertEqual(record?.completedBytes, 400)
    }

    // MARK: - 5. Invalidation on Changed ETag Restarts Fresh

    func testResumeWithMismatchedETagRestartsFromScratch() async throws {
        let testURL = URL(string: "https://example.com/changed.bin")!
        let destURL = tempDirectory.appendingPathComponent("changed.bin")
        let totalSize: Int64 = 200
        let newPayload = Data(repeating: 0x99, count: 200)

        // Server reports NEW ETag ("etag-v2")
        MockURLProtocol.setHandler(for: testURL) { request in
            let range = request.value(forHTTPHeaderField: "Range") ?? ""
            if range == "bytes=0-" {
                let headers = [
                    "Content-Range": "bytes 0-0/200",
                    "ETag": "\"etag-v2\""
                ]
                let resp = HTTPURLResponse(url: testURL, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: headers)!
                return (resp, Data([0x99]))
            } else {
                let headers = [
                    "Content-Range": "bytes 0-199/200",
                    "ETag": "\"etag-v2\""
                ]
                let resp = HTTPURLResponse(url: testURL, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: headers)!
                return (resp, newPayload)
            }
        }

        // Persisted record had OLD ETag ("etag-v1")
        let oldRecord = DownloadRecord(
            id: "dl-changed",
            originalURL: testURL,
            destinationURL: destURL,
            totalSize: 200,
            state: .paused,
            eTag: "\"etag-v1\"",
            segments: [SegmentRecord(id: 0, startOffset: 0, endOffset: 199, length: 200, completedBytes: 100)]
        )
        try await persistenceStore.save(oldRecord)

        let request = DownloadRequest(
            id: "dl-changed",
            url: testURL,
            destinationURL: destURL,
            configuredThreadCount: 1,
            reserveDiskBytes: 1024
        )

        try await coordinator.resume(request)

        let finalData = try Data(contentsOf: destURL)
        XCTAssertEqual(finalData, newPayload)

        let record = try await persistenceStore.fetch(tag: "dl-changed")
        XCTAssertEqual(record?.eTag, "\"etag-v2\"")
        XCTAssertEqual(record?.state, .completed)
    }

    // MARK: - 6. Cancellation & Duplicate Operation Guard

    func testDuplicateStartThrowsAlreadyRunning() async throws {
        let testURL = URL(string: "https://example.com/slow.bin")!
        let destURL = tempDirectory.appendingPathComponent("slow.bin")

        MockURLProtocol.setHandler(for: testURL) { _ in
            let headers = ["Content-Range": "bytes 0-0/1000"]
            let resp = HTTPURLResponse(url: testURL, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: headers)!
            return (resp, Data([0x01]))
        }

        let request = DownloadRequest(
            id: "dl-duplicate",
            url: testURL,
            destinationURL: destURL,
            reserveDiskBytes: 1024
        )

        // Launch first task in background
        let bgTask = Task {
            try await coordinator.start(request)
        }

        // Give it a fraction of time to start
        try await Task.sleep(nanoseconds: 50_000_000)

        do {
            try await coordinator.start(request)
            XCTFail("Expected downloadAlreadyRunning error")
        } catch let error as DownloadCoordinatorError {
            XCTAssertEqual(error, .downloadAlreadyRunning(id: "dl-duplicate"))
        }

        // Cancel background task
        try? await coordinator.cancel(id: "dl-duplicate", deleteDestinationFile: false)
        _ = try? await bgTask.value
    }

    // MARK: - 7. Worker Retry Exhaustion & Sibling Cancellation

    func testWorkerRetryExhaustionTriggersSiblingCancellationAndPreservesCompletedSegments() async throws {
        let testURL = URL(string: "https://example.com/retry_exhaust.bin")!
        let destURL = tempDirectory.appendingPathComponent("retry_exhaust.bin")
        let totalSize: Int64 = 2000

        // Pre-save 2 segments in store so coordinator runs 2 concurrent workers
        let segments = [
            SegmentRecord(id: 0, startOffset: 0, endOffset: 999, length: 1000, completedBytes: 0),
            SegmentRecord(id: 1, startOffset: 1000, endOffset: 1999, length: 1000, completedBytes: 0)
        ]
        let initialRecord = DownloadRecord(
            id: "dl-retry-exhaust",
            originalURL: testURL,
            destinationURL: destURL,
            totalSize: 2000,
            state: .paused,
            storageMode: .directSeek,
            eTag: "\"etag-exhaust\"",
            segments: segments
        )
        try await persistenceStore.save(initialRecord)

        let lock = NSLock()
        var seg1Attempts = 0
        MockURLProtocol.setHandler(for: testURL) { request in
            let range = request.value(forHTTPHeaderField: "Range") ?? ""
            if range == "bytes=0-" {
                let headers = [
                    "Content-Range": "bytes 0-0/\(totalSize)",
                    "Content-Length": "1",
                    "ETag": "\"etag-exhaust\""
                ]
                let resp = HTTPURLResponse(url: testURL, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: headers)!
                return (resp, Data([0xAA]))
            } else if range == "bytes=0-999" {
                let headers = [
                    "Content-Range": "bytes 0-999/\(totalSize)",
                    "Content-Length": "1000",
                    "ETag": "\"etag-exhaust\""
                ]
                let resp = HTTPURLResponse(url: testURL, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: headers)!
                return (resp, Data(repeating: 0x11, count: 1000))
            } else if range.contains("1000-1999") {
                lock.lock()
                seg1Attempts += 1
                lock.unlock()
                let resp = HTTPURLResponse(url: testURL, statusCode: 500, httpVersion: "HTTP/1.1", headerFields: [:])!
                return (resp, Data())
            }
            let resp = HTTPURLResponse(url: testURL, statusCode: 416, httpVersion: "HTTP/1.1", headerFields: [:])!
            return (resp, Data())
        }

        let request = DownloadRequest(
            id: "dl-retry-exhaust",
            url: testURL,
            destinationURL: destURL,
            configuredThreadCount: 2,
            reserveDiskBytes: 1024,
            retryCount: 2
        )

        do {
            try await coordinator.start(request)
            XCTFail("Expected retry exhaustion to throw an error")
        } catch {
            // Worker retry failed
        }

        // Verify that retry attempts were made
        lock.lock()
        let attempts = seg1Attempts
        lock.unlock()
        XCTAssertGreaterThanOrEqual(attempts, 2)

        // Verify persistence store state transitioned to .failed
        let record = try await persistenceStore.fetch(tag: "dl-retry-exhaust")
        XCTAssertNotNil(record)
        if case .failed = record?.state {
            // Success
        } else {
            XCTFail("Expected record state to be .failed, but got \(String(describing: record?.state))")
        }

        // Verify completed bytes for Segment 0 were preserved in store
        let seg0 = record?.segments.first(where: { $0.id == 0 })
        XCTAssertEqual(seg0?.completedBytes, 1000)
    }

    // MARK: - 8. Checksum Validation (Size Necessary but Not Sufficient)

    func testChecksumMismatchFailsDownloadEvenIfSizeMatches() async throws {
        let testURL = URL(string: "https://example.com/corrupt_payload.bin")!
        let destURL = tempDirectory.appendingPathComponent("corrupt_payload.bin")
        let totalSize: Int64 = 1000
        let payload = Data(repeating: 0xEE, count: 1000)

        MockURLProtocol.setHandler(for: testURL) { request in
            let range = request.value(forHTTPHeaderField: "Range") ?? ""
            if range == "bytes=0-" {
                let headers = [
                    "Content-Range": "bytes 0-0/1000",
                    "Content-Length": "1",
                    "ETag": "\"etag-checksum\""
                ]
                let resp = HTTPURLResponse(url: testURL, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: headers)!
                return (resp, Data([0xEE]))
            } else {
                let headers = [
                    "Content-Range": "bytes 0-999/1000",
                    "Content-Length": "1000",
                    "ETag": "\"etag-checksum\""
                ]
                let resp = HTTPURLResponse(url: testURL, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: headers)!
                return (resp, payload)
            }
        }

        let incorrectSHA = "0000000000000000000000000000000000000000000000000000000000000000"
        let request = DownloadRequest(
            id: "dl-checksum-fail",
            url: testURL,
            destinationURL: destURL,
            configuredThreadCount: 1,
            reserveDiskBytes: 1024,
            expectedSHA256: incorrectSHA
        )

        do {
            try await coordinator.start(request)
            XCTFail("Expected checksum mismatch to throw")
        } catch let error as DownloadCoordinatorError {
            if case .checksumMismatch(let expected, let actual) = error {
                XCTAssertEqual(expected, incorrectSHA)
                XCTAssertNotEqual(actual, incorrectSHA)
            } else {
                XCTFail("Expected checksumMismatch error, got: \(error)")
            }
        }

        // Verify physical file size matches 1000 on disk, yet state is .failed
        let writtenData = try Data(contentsOf: destURL)
        XCTAssertEqual(writtenData.count, 1000)

        let record = try await persistenceStore.fetch(tag: "dl-checksum-fail")
        if case .failed = record?.state {
            // Success
        } else {
            XCTFail("Expected record state to be .failed, but got \(String(describing: record?.state))")
        }
    }

    func testChecksumVerificationPassesWhenHashMatches() async throws {
        let testURL = URL(string: "https://example.com/valid_payload.bin")!
        let destURL = tempDirectory.appendingPathComponent("valid_payload.bin")
        let totalSize: Int64 = 500
        let payload = Data((0..<500).map { UInt8($0 % 256) })
        let expectedSHA = EngineSHA256.hash(data: payload)

        MockURLProtocol.setHandler(for: testURL) { request in
            let range = request.value(forHTTPHeaderField: "Range") ?? ""
            if range == "bytes=0-" {
                let headers = [
                    "Content-Range": "bytes 0-0/500",
                    "Content-Length": "1",
                    "ETag": "\"etag-valid-sha\""
                ]
                let resp = HTTPURLResponse(url: testURL, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: headers)!
                return (resp, Data([payload[0]]))
            } else {
                let headers = [
                    "Content-Range": "bytes 0-499/500",
                    "Content-Length": "500",
                    "ETag": "\"etag-valid-sha\""
                ]
                let resp = HTTPURLResponse(url: testURL, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: headers)!
                return (resp, payload)
            }
        }

        let request = DownloadRequest(
            id: "dl-checksum-pass",
            url: testURL,
            destinationURL: destURL,
            configuredThreadCount: 1,
            reserveDiskBytes: 1024,
            expectedSHA256: expectedSHA
        )

        try await coordinator.start(request)

        let record = try await persistenceStore.fetch(tag: "dl-checksum-pass")
        XCTAssertEqual(record?.state, .completed)
        XCTAssertEqual(record?.completedBytes, 500)
    }

    // MARK: - 9. Contiguous Segment Layout Validation

    func testNonContiguousSegmentLayoutThrowsInvalidLayout() {
        let gapSegments = [
            DownloadSegment(id: 0, startOffset: 0, endOffset: 99, length: 100),
            DownloadSegment(id: 1, startOffset: 105, endOffset: 199, length: 95)
        ]
        XCTAssertThrowsError(try DownloadCoordinator.validateSegmentLayout(gapSegments, totalSize: 200)) { error in
            guard case DownloadCoordinatorError.segmentLayoutInvalid(let reason) = error else {
                XCTFail("Expected segmentLayoutInvalid, got \(error)")
                return
            }
            XCTAssertTrue(reason.contains("gap or overlap"))
        }

        let overlapSegments = [
            DownloadSegment(id: 0, startOffset: 0, endOffset: 100, length: 101),
            DownloadSegment(id: 1, startOffset: 100, endOffset: 199, length: 100)
        ]
        XCTAssertThrowsError(try DownloadCoordinator.validateSegmentLayout(overlapSegments, totalSize: 200)) { error in
            guard case DownloadCoordinatorError.segmentLayoutInvalid(let reason) = error else {
                XCTFail("Expected segmentLayoutInvalid, got \(error)")
                return
            }
            XCTAssertTrue(reason.contains("gap or overlap"))
        }
    }
}
