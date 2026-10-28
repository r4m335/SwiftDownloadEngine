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

        final class ProgressCollector: @unchecked Sendable {
            private(set) var history: [CoordinatorProgress] = []
            private let lock = NSLock()
            func record(_ progress: CoordinatorProgress) {
                lock.lock()
                defer { lock.unlock() }
                history.append(progress)
            }
        }
        let collector = ProgressCollector()
        try await coordinator.start(request) { progress in
            collector.record(progress)
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
        XCTAssertFalse(collector.history.isEmpty)
        XCTAssertEqual(collector.history.last?.state, .completed)
        XCTAssertEqual(collector.history.last?.bytesReceived, totalSize)
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

        final class AttemptCounter: @unchecked Sendable {
            private(set) var count = 0
            private let lock = NSLock()
            func increment() {
                lock.lock()
                defer { lock.unlock() }
                count += 1
            }
        }
        let seg1Attempts = AttemptCounter()
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
                seg1Attempts.increment()
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
        let attempts = seg1Attempts.count
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

    func testStartRejectsNonHTTPSchemes() async throws {
        let blobURL = URL(string: "blob:https://example.com/stream-blob-id")!
        let destURL = tempDirectory.appendingPathComponent("blob_video.mp4")
        let request = DownloadRequest(
            id: "dl-blob-scheme",
            url: blobURL,
            destinationURL: destURL
        )

        do {
            try await coordinator.start(request)
            XCTFail("Expected start() to reject blob: URL")
        } catch let error as DownloadCoordinatorError {
            if case .invalidRequest(let reason) = error {
                XCTAssertTrue(reason.contains("blob"))
            } else {
                XCTFail("Expected invalidRequest error, got: \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - Task 1: Network Policy Tests

    func testNetworkPolicyCellularVsWifiOnly() {
        let anyNet = DownloadNetworkPolicy.anyNetwork
        XCTAssertTrue(anyNet.allowsCellularAccess)

        let wifiOnly = DownloadNetworkPolicy.wifiOnly
        XCTAssertFalse(wifiOnly.allowsCellularAccess)

        let request = DownloadRequest(
            id: "net-test",
            url: URL(string: "https://example.com/file.zip")!,
            destinationURL: tempDirectory.appendingPathComponent("file.zip"),
            networkPolicy: .wifiOnly
        )
        XCTAssertEqual(request.networkPolicy, .wifiOnly)
        XCTAssertFalse(request.networkPolicy.allowsCellularAccess)
    }

    // MARK: - Task 2: Mature Error Policy Tests

    func testMatureErrorPolicyTokenExpired401() async throws {
        let testURL = URL(string: "https://example.com/protected_token.zip")!
        let destURL = tempDirectory.appendingPathComponent("protected_token.zip")

        MockURLProtocol.setHandler(for: testURL) { _ in
            let resp = HTTPURLResponse(url: testURL, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: [:])!
            return (resp, Data("Unauthorized".utf8))
        }

        let request = DownloadRequest(
            id: "dl-401-test",
            url: testURL,
            destinationURL: destURL
        )

        do {
            try await coordinator.start(request)
            XCTFail("Expected coordinator.start to throw tokenExpired error")
        } catch let error as DownloadCoordinatorError {
            guard case .tokenExpired(let url) = error else {
                XCTFail("Expected tokenExpired, got: \(error)")
                return
            }
            XCTAssertEqual(url, testURL)
        }
    }

    func testMatureErrorPolicyAccessDenied403Cooldown() async throws {
        let testURL = URL(string: "https://example.com/forbidden.zip")!
        let destURL = tempDirectory.appendingPathComponent("forbidden.zip")

        MockURLProtocol.setHandler(for: testURL) { _ in
            let resp = HTTPURLResponse(url: testURL, statusCode: 403, httpVersion: "HTTP/1.1", headerFields: [:])!
            return (resp, Data("Forbidden".utf8))
        }

        let request = DownloadRequest(
            id: "dl-403-test",
            url: testURL,
            destinationURL: destURL
        )

        do {
            try await coordinator.start(request)
            XCTFail("Expected coordinator.start to throw accessDenied error")
        } catch let error as DownloadCoordinatorError {
            guard case .accessDenied(let url, let cooldownUntil) = error else {
                XCTFail("Expected accessDenied, got: \(error)")
                return
            }
            XCTAssertEqual(url, testURL)
            XCTAssertGreaterThan(cooldownUntil, Date())
        }
    }

    func testNonResumableServerRestartsDownloadFromZero() async throws {
        let testURL = URL(string: "https://example.com/non_resumable.bin")!
        let destURL = tempDirectory.appendingPathComponent("non_resumable.bin")
        let totalSize: Int64 = 1000

        // Create an initial partial file on disk
        let partialData = Data(repeating: 0x55, count: 200)
        FileManager.default.createFile(atPath: destURL.path, contents: partialData)

        // Seed persisted record with partially completed segment
        let existingRecord = DownloadRecord(
            id: "dl-non-resumable-test",
            originalURL: testURL,
            destinationURL: destURL,
            totalSize: totalSize,
            state: .paused,
            storageMode: .directSeek,
            segments: [
                SegmentRecord(
                    id: 0,
                    startOffset: 0,
                    endOffset: totalSize - 1,
                    length: totalSize,
                    completedBytes: 200
                )
            ]
        )
        try await persistenceStore.save(existingRecord)

        // Remote server:
        // Probe returns 200 (does not support byte ranges, accept-ranges: none)
        // Download request returns full content
        let fullData = Data(repeating: 0x99, count: Int(totalSize))
        MockURLProtocol.setHandler(for: testURL) { request in
            let headers = [
                "Content-Length": "\(totalSize)",
                "Accept-Ranges": "none"
            ]
            let resp = HTTPURLResponse(url: testURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
            return (resp, fullData)
        }

        let request = DownloadRequest(
            id: "dl-non-resumable-test",
            url: testURL,
            destinationURL: destURL
        )

        try await coordinator.start(request)

        // Verify file was cleanly downloaded from byte 0 (not corrupted or failed)
        let downloadedData = try Data(contentsOf: destURL)
        XCTAssertEqual(downloadedData.count, Int(totalSize))
        XCTAssertEqual(downloadedData, fullData)
    }

    // MARK: - Task 3: Preallocation & Disk Space Check Tests

    func testPreallocationAndDiskCheckModel() {
        let error = DownloadCoordinatorError.insufficientDiskSpace(required: 1_000_000_000, available: 500_000_000)
        XCTAssertTrue(error.errorDescription?.contains("Insufficient disk space") == true)
        XCTAssertTrue(error.errorDescription?.contains("1000000000") == true)
    }

    // MARK: - Dynamic Auth & Keychain Tests

    func testKeychainManagerStorageAndPurge() {
        let km = KeychainManager.shared
        km.resetFallbackStore()

        // 1. Internet Password (HTTP Basic Auth)
        XCTAssertTrue(km.storeInternetPassword(username: "admin", password: "secretPassword123", server: "example.com"))
        let retrieved = km.getInternetPassword(server: "example.com")
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.username, "admin")
        XCTAssertEqual(retrieved?.password, "secretPassword123")

        // 2. Origin-scoped Cookie storage
        let cookie = HTTPCookie(properties: [
            .name: "cf_clearance",
            .value: "rotated_token_999",
            .domain: "example.com",
            .path: "/"
        ])!
        XCTAssertTrue(km.storeCookies([cookie], domain: "example.com", downloadId: "test-dl-keychain"))
        let cookies = km.getCookies(domain: "example.com")
        XCTAssertEqual(cookies.count, 1)
        XCTAssertEqual(cookies.first?.value, "rotated_token_999")

        // 3. Purge on download deletion
        km.deleteCredentials(forDownloadId: "test-dl-keychain")
        XCTAssertTrue(km.deleteInternetPassword(server: "example.com"))
        XCTAssertNil(km.getInternetPassword(server: "example.com"))
    }

    func testGranularErrorStatesUnauthorizedForbiddenLinkExpired() {
        let testURL = URL(string: "https://example.com/media.mp4")!

        let unauth = DownloadCoordinatorError.unauthorized(url: testURL)
        XCTAssertTrue(unauth.isUnauthorized)
        XCTAssertTrue(unauth.errorDescription?.contains("401") == true)

        let forbidden = DownloadCoordinatorError.forbidden(url: testURL)
        XCTAssertTrue(forbidden.isForbidden)
        XCTAssertTrue(forbidden.errorDescription?.contains("403") == true)

        let expired = DownloadCoordinatorError.linkExpired(url: testURL)
        XCTAssertTrue(expired.isLinkExpired)
        XCTAssertTrue(expired.errorDescription?.contains("404") == true)
    }

    func testRefreshDownloadFlowResumesWithMatchingETag() async throws {
        let initialURL = URL(string: "https://example.com/initial_token.zip")!
        let refreshedURL = URL(string: "https://example.com/new_token.zip")!
        let destURL = tempDirectory.appendingPathComponent("refresh_test.zip")
        let totalSize: Int64 = 2000
        let eTag = "\"stable-v1-hash\""

        // Seed persisted record with partially completed segment
        let existingRecord = DownloadRecord(
            id: "dl-refresh-test",
            originalURL: initialURL,
            destinationURL: destURL,
            totalSize: totalSize,
            state: .failed(reason: "403 Forbidden"),
            storageMode: .directSeek,
            eTag: eTag,
            segments: [
                SegmentRecord(
                    id: 0,
                    startOffset: 0,
                    endOffset: totalSize - 1,
                    length: totalSize,
                    completedBytes: 800
                )
            ]
        )
        try await persistenceStore.save(existingRecord)

        // Remote server: Probing the refreshed URL returns the SAME ETag and size
        MockURLProtocol.setHandler(for: refreshedURL) { _ in
            let headers = [
                "Content-Length": "\(totalSize)",
                "Accept-Ranges": "bytes",
                "ETag": eTag
            ]
            let resp = HTTPURLResponse(url: refreshedURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
            return (resp, Data())
        }

        let updated = try await coordinator.refreshDownload(id: "dl-refresh-test", newURL: refreshedURL)

        // Invariant: Matching ETag preserves the 800 completed bytes!
        XCTAssertEqual(updated.resolvedURL, refreshedURL)
        XCTAssertEqual(updated.completedBytes, 800)
        XCTAssertEqual(updated.state, .paused)
    }

    func testRefreshDownloadFlowRestartsWithMismatchedETag() async throws {
        let initialURL = URL(string: "https://example.com/old_file.zip")!
        let refreshedURL = URL(string: "https://example.com/new_file.zip")!
        let destURL = tempDirectory.appendingPathComponent("refresh_restart.zip")
        let totalSize: Int64 = 2000

        let existingRecord = DownloadRecord(
            id: "dl-refresh-restart",
            originalURL: initialURL,
            destinationURL: destURL,
            totalSize: totalSize,
            state: .failed(reason: "404 Not Found"),
            storageMode: .directSeek,
            eTag: "\"old-tag\"",
            segments: [
                SegmentRecord(
                    id: 0,
                    startOffset: 0,
                    endOffset: totalSize - 1,
                    length: totalSize,
                    completedBytes: 800
                )
            ]
        )
        try await persistenceStore.save(existingRecord)

        // Remote server: Probing new URL returns a DIFFERENT ETag
        MockURLProtocol.setHandler(for: refreshedURL) { _ in
            let headers = [
                "Content-Length": "\(totalSize)",
                "Accept-Ranges": "bytes",
                "ETag": "\"different-new-tag\""
            ]
            let resp = HTTPURLResponse(url: refreshedURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
            return (resp, Data())
        }

        let updated = try await coordinator.refreshDownload(id: "dl-refresh-restart", newURL: refreshedURL)

        // Invariant: Mismatched ETag resets completed bytes to 0 for safety!
        XCTAssertEqual(updated.resolvedURL, refreshedURL)
        XCTAssertEqual(updated.completedBytes, 0)
        XCTAssertEqual(updated.state, .pending)
    }
}

