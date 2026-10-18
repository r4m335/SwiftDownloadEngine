import XCTest
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

@testable import DM_Reverse_engineering

final class ResourceThrottlingTests: XCTestCase {
    private var server: LocalHTTPRangeServer!
    private var tempDirectory: URL!
    private var persistenceStore: DownloadPersistenceStore!
    private var coordinator: DownloadCoordinator!

    override func setUp() async throws {
        try await super.setUp()
        #if os(Linux)
        signal(SIGPIPE, SIG_IGN)
        #endif
        server = LocalHTTPRangeServer()
        try server.start()

        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("1DM_Throttling_Tests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let storeURL = tempDirectory.appendingPathComponent("Store", isDirectory: true)
        persistenceStore = try DownloadPersistenceStore(storageDirectoryURL: storeURL)
        coordinator = try DownloadCoordinator(session: .shared, persistenceStore: persistenceStore)
    }

    override func tearDown() async throws {
        server?.stop()
        server = nil
        coordinator = nil
        persistenceStore = nil
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try await super.tearDown()
    }

    private func makeTestData(size: Int, fillByte: UInt8 = 0x5A) -> Data {
        var data = Data(count: size)
        for i in 0..<size {
            data[i] = UInt8((Int(fillByte) + (i % 251)) & 0xFF)
        }
        return data
    }

    // MARK: - 1. Global Active-Request Limit Is Never Exceeded

    func testGlobalActiveRequestLimitNeverExceeded() async throws {
        let budget = SharedRequestBudget(maxGlobalRequests: 3)
        let totalWorkers = 12

        actor ConcurrencyTracker {
            var peakActive: Int = 0
            var completedCount: Int = 0

            func update(active: Int) {
                if active > peakActive {
                    peakActive = active
                }
            }

            func incrementCompleted() {
                completedCount += 1
            }
        }

        let tracker = ConcurrencyTracker()

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<totalWorkers {
                group.addTask {
                    try? await budget.acquire(downloadID: "download-\(i % 3)")
                    let current = await budget.currentGlobalActive
                    await tracker.update(active: current)

                    // Simulate in-flight HTTP request I/O
                    try? await Task.sleep(nanoseconds: 30_000_000)

                    await budget.release(downloadID: "download-\(i % 3)")
                    await tracker.incrementCompleted()
                }
            }
        }

        let peak = await tracker.peakActive
        let done = await tracker.completedCount
        let finalActive = await budget.currentGlobalActive

        XCTAssertLessThanOrEqual(peak, 3, "Peak active requests must never exceed maxGlobalRequests (3)")
        XCTAssertEqual(done, totalWorkers, "All workers should complete")
        XCTAssertEqual(finalActive, 0, "All permits must be released")
    }

    // MARK: - 2. Several Downloads Share the Same Global Budget

    func testMultipleDownloadsShareGlobalRequestBudget() async throws {
        let budget = SharedRequestBudget(maxGlobalRequests: 4)

        actor MultiDownloadObserver {
            var activeRecords: [(global: Int, dlA: Int, dlB: Int)] = []

            func record(global: Int, dlA: Int, dlB: Int) {
                activeRecords.append((global, dlA, dlB))
            }
        }

        let observer = MultiDownloadObserver()

        await withTaskGroup(of: Void.self) { group in
            // Download A workers
            for _ in 0..<4 {
                group.addTask {
                    try? await budget.acquire(downloadID: "A", maxPerDownload: 3)
                    let g = await budget.currentGlobalActive
                    let a = await budget.activeCount(for: "A")
                    let b = await budget.activeCount(for: "B")
                    await observer.record(global: g, dlA: a, dlB: b)

                    try? await Task.sleep(nanoseconds: 20_000_000)
                    await budget.release(downloadID: "A")
                }
            }
            // Download B workers
            for _ in 0..<4 {
                group.addTask {
                    try? await budget.acquire(downloadID: "B", maxPerDownload: 3)
                    let g = await budget.currentGlobalActive
                    let a = await budget.activeCount(for: "A")
                    let b = await budget.activeCount(for: "B")
                    await observer.record(global: g, dlA: a, dlB: b)

                    try? await Task.sleep(nanoseconds: 20_000_000)
                    await budget.release(downloadID: "B")
                }
            }
        }

        let records = await observer.activeRecords
        for r in records {
            XCTAssertLessThanOrEqual(r.global, 4, "Global active requests exceeded 4")
            XCTAssertLessThanOrEqual(r.dlA, 3, "Download A exceeded per-download cap 3")
            XCTAssertLessThanOrEqual(r.dlB, 3, "Download B exceeded per-download cap 3")
        }

        let finalGlobal = await budget.currentGlobalActive
        XCTAssertEqual(finalGlobal, 0, "All shared permits must be cleanly released")
    }

    // MARK: - 3. Finished Request Releases Its Permit

    func testFinishedRequestReleasesPermit() async throws {
        let budget = SharedRequestBudget(maxGlobalRequests: 1)

        try await budget.acquire(downloadID: "test-dl")
        var current = await budget.currentGlobalActive
        XCTAssertEqual(current, 1)

        // Launch second task that should wait
        let acquiredSecond = expectation(description: "Second task acquires permit")
        let task2 = Task {
            try await budget.acquire(downloadID: "test-dl")
            acquiredSecond.fulfill()
            await budget.release(downloadID: "test-dl")
        }

        // Wait until task2 is registered in waiters
        for _ in 0..<50 {
            if await budget.waitingCount == 1 { break }
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
        let waitCount = await budget.waitingCount
        XCTAssertEqual(waitCount, 1)

        // Release first permit
        await budget.release(downloadID: "test-dl")
        current = await budget.currentGlobalActive

        await fulfillment(of: [acquiredSecond], timeout: 2.0)
        _ = await task2.result

        let finalActive = await budget.currentGlobalActive
        XCTAssertEqual(finalActive, 0)
    }

    // MARK: - 4. Failed Request Releases Its Permit

    func testFailedRequestReleasesPermit() async throws {
        let budget = SharedRequestBudget(maxGlobalRequests: 1)
        let path = "/failure_test.bin"
        server.register(path: path, data: Data([1, 2, 3]), statusCodeOverride: 500)

        let dest = tempDirectory.appendingPathComponent("failure.bin")
        let writer = try DownloadFileWriter(destinationURL: dest, totalSize: 3, mode: .directSeek)

        let downloader = SegmentDownloader(
            session: .shared,
            writer: writer,
            requestBudget: budget,
            downloadID: "fail-dl"
        )

        let seg = DownloadSegment(id: 0, startOffset: 0, endOffset: 2, length: 3)
        do {
            try await downloader.download(
                url: server.baseURL.appendingPathComponent(path),
                segment: seg,
                expectedTotalSize: 3
            )
            XCTFail("Should have thrown HTTP status error")
        } catch {
            // Expected error
        }

        try await writer.close()
        let active = await budget.currentGlobalActive
        let activeForDL = await budget.activeCount(for: "fail-dl")
        XCTAssertEqual(active, 0, "Permit must be released on failure")
        XCTAssertEqual(activeForDL, 0, "Download active count must be zero on failure")
    }

    // MARK: - 5. Cancellation While Waiting For A Permit Works

    func testCancellationWhileWaitingForPermit() async throws {
        let budget = SharedRequestBudget(maxGlobalRequests: 1)

        // Hold the single permit
        try await budget.acquire(downloadID: "holder")

        let readyToCancel = expectation(description: "Task 2 is waiting")
        let task2 = Task {
            readyToCancel.fulfill()
            try await budget.acquire(downloadID: "waiter")
        }

        await fulfillment(of: [readyToCancel], timeout: 1.0)
        // Give time for waiter to register in budget
        try await Task.sleep(nanoseconds: 50_000_000)

        let waitersBefore = await budget.waitingCount
        XCTAssertEqual(waitersBefore, 1)

        task2.cancel()
        do {
            _ = try await task2.value
            XCTFail("Should have thrown CancellationError")
        } catch is CancellationError {
            // Expected
        }

        // Waiters should be drained/cleaned up
        try await Task.sleep(nanoseconds: 50_000_000)
        let waitersAfter = await budget.waitingCount
        XCTAssertEqual(waitersAfter, 0, "Cancelled waiter must be removed from queue")

        // Release holder permit
        await budget.release(downloadID: "holder")
        let finalActive = await budget.currentGlobalActive
        XCTAssertEqual(finalActive, 0, "No leaked permits after cancellation")
    }

    // MARK: - 6. Repeated Retries Do Not Leak Permits

    func testRepeatedRetriesDoNotLeakPermits() async throws {
        let budget = SharedRequestBudget(maxGlobalRequests: 2)
        let path = "/retry_leak_test.bin"
        let data = makeTestData(size: 2048)
        server.register(path: path, data: data)
        server.failNextRequests(path: path, count: 2, statusCode: 500)

        let dest = tempDirectory.appendingPathComponent("retry_leak.bin")
        let req = DownloadRequest(
            url: server.baseURL.appendingPathComponent(path),
            destinationURL: dest,
            retryCount: 3
        )

        let testCoord = try DownloadCoordinator(
            session: .shared,
            persistenceStore: persistenceStore,
            requestBudget: budget
        )

        try await testCoord.start(req)

        let finalActive = await budget.currentGlobalActive
        XCTAssertEqual(finalActive, 0, "Retried request must release permit and end with zero held permits")
    }

    // MARK: - 7. Global Bandwidth Limit Is Enforced Within Reasonable Tolerance

    func testGlobalBandwidthLimitEnforcedWithinTolerance() async throws {
        let rateLimit: Int64 = 80 * 1024 // 80 KiB/s
        let limiter = BandwidthLimiter(bytesPerSecond: rateLimit, burstCapacity: 32 * 1024)

        // Reserve 160 KiB: 32 KiB burst available, deficit = 128 KiB
        // Wait time = 128 / 80 = 1.6 seconds
        let delay = await limiter.reserve(bytes: 160 * 1024)
        XCTAssertGreaterThanOrEqual(delay, 1.4, "Delay must enforce rate limit (~1.6s)")
        XCTAssertLessThanOrEqual(delay, 1.8, "Delay must stay within reasonable tolerance")
    }

    // MARK: - 8. Multiple Downloads Share Global Bandwidth Budget

    func testMultipleDownloadsShareGlobalBandwidthBudget() async throws {
        let globalLimiter = BandwidthLimiter(bytesPerSecond: 100 * 1024, burstCapacity: 32 * 1024)

        // Two downloads simultaneously requesting 100 KiB each
        let delay1 = await globalLimiter.reserve(bytes: 100 * 1024)
        let delay2 = await globalLimiter.reserve(bytes: 100 * 1024)

        // Combined deficit = 200 - 32 = 168 KiB / 100 KiB/s = ~1.68s
        let totalDelay = delay1 + delay2
        XCTAssertGreaterThanOrEqual(totalDelay, 1.5, "Combined reservations must reflect shared global limit")
    }

    // MARK: - 9. Per-Download Speed Limits Work

    func testPerDownloadSpeedLimitsWork() async throws {
        let perDownload = BandwidthLimiter(bytesPerSecond: 50 * 1024, burstCapacity: 16 * 1024)
        let delay = await perDownload.reserve(bytes: 100 * 1024)
        // Deficit: 100 - 16 = 84 KiB / 50 KiB/s = ~1.68s
        XCTAssertGreaterThanOrEqual(delay, 1.5, "Per-download limiter must enforce configured speed")
    }

    // MARK: - 10. Per-Download and Global Limits Interact Correctly

    func testPerDownloadAndGlobalLimitsInteractCorrectly() async throws {
        let globalLimiter = BandwidthLimiter(bytesPerSecond: 50 * 1024, burstCapacity: 16 * 1024) // tighter
        let perDownloadLimiter = BandwidthLimiter(bytesPerSecond: 200 * 1024, burstCapacity: 16 * 1024) // looser

        let start = ProcessInfo.processInfo.systemUptime
        try await BandwidthLimiter.throttle(
            bytes: 50 * 1024,
            global: globalLimiter,
            perDownload: perDownloadLimiter
        )
        let elapsed = ProcessInfo.processInfo.systemUptime - start

        // Deficit for global: 50 - 16 = 34 KiB / 50 KiB/s = ~0.68s
        // Deficit for perDownload: 50 - 16 = 34 KiB / 200 KiB/s = ~0.17s
        // Maximum delay should be picked (~0.68s)
        XCTAssertGreaterThanOrEqual(elapsed, 0.5, "Throttle must be constrained by the tighter global limit")
    }

    // MARK: - 11. Disabling Limits Restores Unrestricted Behavior

    func testDisablingLimitsRestoresUnrestrictedBehavior() async throws {
        let limiter = BandwidthLimiter(bytesPerSecond: 10 * 1024) // slow 10 KiB/s
        await limiter.setRateLimit(nil) // disable limit

        let delay = await limiter.reserve(bytes: 1_000_000)
        XCTAssertEqual(delay, 0, "Unrestricted limiter must return 0 delay immediately")
    }

    // MARK: - 12. Pause and Resume Work While Throttled

    func testPauseAndResumeWhileThrottled() async throws {
        let path = "/pause_throttle.bin"
        let data = makeTestData(size: 256 * 1024)
        server.register(path: path, data: data, chunkDelayMs: 40)

        let dest = tempDirectory.appendingPathComponent("pause_throttle.bin")
        let req = DownloadRequest(
            url: server.baseURL.appendingPathComponent(path),
            destinationURL: dest,
            configuredThreadCount: 4,
            speedLimitBytesPerSecond: 64 * 1024 // 64 KiB/s throttle
        )

        let startTask = Task {
            try await coordinator.start(req)
        }

        // Let it begin receiving chunks (server delay guarantees it is mid-stream)
        try await Task.sleep(nanoseconds: 80_000_000)

        // Pause download
        try await coordinator.pause(id: req.id)
        _ = try? await startTask.value

        let record = try await persistenceStore.fetch(tag: req.id)
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.state, .paused)

        // Resume download
        try await coordinator.resume(req)

        let finalRecord = try await persistenceStore.fetch(tag: req.id)
        XCTAssertEqual(finalRecord?.state, .completed)
        XCTAssertEqual(finalRecord?.completedBytes, Int64(data.count))

        let downloadedData = try Data(contentsOf: dest)
        XCTAssertEqual(downloadedData, data, "Resumed throttled file must match exact original data")
    }

    // MARK: - 13. Cancellation Works While Throttled

    func testCancellationWorksWhileThrottled() async throws {
        let path = "/cancel_throttle.bin"
        let data = makeTestData(size: 128 * 1024)
        server.register(path: path, data: data)

        let dest = tempDirectory.appendingPathComponent("cancel_throttle.bin")
        let req = DownloadRequest(
            url: server.baseURL.appendingPathComponent(path),
            destinationURL: dest,
            speedLimitBytesPerSecond: 10 * 1024 // slow 10 KiB/s
        )

        let startTask = Task {
            try await coordinator.start(req)
        }

        try await Task.sleep(nanoseconds: 80_000_000)
        let cancelStart = ProcessInfo.processInfo.systemUptime
        try await coordinator.cancel(id: req.id)
        _ = try? await startTask.value
        let cancelDuration = ProcessInfo.processInfo.systemUptime - cancelStart

        XCTAssertLessThan(cancelDuration, 1.5, "Cancellation must abort sleeping throttler without waiting for rate accumulation")
        let record = try await persistenceStore.fetch(tag: req.id)
        XCTAssertEqual(record?.state, .cancelled)
    }

    // MARK: - 14. Speed Measurements Accuracy

    func testSpeedMeasurementsAccuracy() throws {
        let tracker = DownloadSpeedTracker(windowDuration: 1.0)
        tracker.record(bytes: 50_000)
        tracker.record(bytes: 50_000)

        let snap = tracker.snapshot(expectedTotalBytes: 200_000)
        XCTAssertEqual(snap.totalBytesReceived, 100_000)
        XCTAssertEqual(snap.totalBytesExpected, 200_000)
        XCTAssertGreaterThan(snap.currentBytesPerSecond, 0)
        XCTAssertGreaterThan(snap.averageBytesPerSecond, 0)
        XCTAssertNotNil(snap.estimatedTimeRemaining)
        XCTAssertGreaterThan(snap.estimatedTimeRemaining ?? 0, 0)
    }

    // MARK: - 15. Zero-Byte Downloads Do Not Cause Invalid Speed Calculations

    func testZeroByteDownloadsDoNotCauseInvalidSpeedCalculations() async throws {
        let path = "/zero_byte.bin"
        server.register(path: path, data: Data())

        let dest = tempDirectory.appendingPathComponent("zero_byte.bin")
        let req = DownloadRequest(
            url: server.baseURL.appendingPathComponent(path),
            destinationURL: dest
        )

        try await coordinator.start(req)

        let metrics = await coordinator.speedMetrics(for: req.id)
        XCTAssertNotNil(metrics)
        XCTAssertFalse((metrics?.currentBytesPerSecond ?? 0).isNaN)
        XCTAssertFalse((metrics?.averageBytesPerSecond ?? 0).isNaN)
        XCTAssertFalse((metrics?.currentBytesPerSecond ?? 0).isInfinite)

        let fileData = try Data(contentsOf: dest)
        XCTAssertEqual(fileData.count, 0)
    }

    // MARK: - 16. Unknown-Size Downloads Do Not Report Invented Time Estimates

    func testUnknownSizeDownloadsDoNotReportInventedTimeEstimates() throws {
        let tracker = DownloadSpeedTracker()
        tracker.record(bytes: 65_536)

        let snap = tracker.snapshot(expectedTotalBytes: nil)
        XCTAssertNil(snap.estimatedTimeRemaining, "ETA must be nil when expected total bytes is nil")
    }

    // MARK: - 17. Compatibility and Conservative Resume Policies

    func testCompatibilityAndConservativeResumePolicies() async throws {
        let path = "/validatorless.bin"
        let data = makeTestData(size: 4096)
        // Register without ETag and without Last-Modified
        server.register(path: path, data: data, eTag: "")

        let baseRecord = DownloadRecord(
            id: "val-test",
            originalURL: server.baseURL.appendingPathComponent(path),
            destinationURL: tempDirectory.appendingPathComponent("val.bin"),
            totalSize: 4096,
            state: .paused,
            storageMode: .directSeek,
            eTag: nil,
            lastModified: nil,
            segments: [SegmentRecord(id: 0, startOffset: 0, endOffset: 4095, length: 4096, completedBytes: 2048)]
        )

        // Compatibility mode permits resumption on size match alone
        let compatResult = baseRecord.validateForResume(
            remoteETag: nil,
            remoteLastModified: nil,
            remoteTotalSize: 4096,
            policy: .compatibility
        )
        XCTAssertEqual(compatResult, .valid, "Compatibility mode must permit resume when file sizes match")

        // Conservative mode rejects resumption when no validator is present
        let conservativeResult = baseRecord.validateForResume(
            remoteETag: nil,
            remoteLastModified: nil,
            remoteTotalSize: 4096,
            policy: .conservative
        )
        XCTAssertEqual(conservativeResult, .unsupportedNonResumable, "Conservative mode must reject resume without validators")
    }

    // MARK: - 18. Existing Checksum and Recovery Tests Remain Valid

    func testChecksumVerificationOutcomes() async throws {
        let path = "/checksum_test.bin"
        let data = makeTestData(size: 1024)
        server.register(path: path, data: data)

        let expectedHash = EngineSHA256.hash(data: data)
        let dest = tempDirectory.appendingPathComponent("checksum_test.bin")
        let req = DownloadRequest(
            url: server.baseURL.appendingPathComponent(path),
            destinationURL: dest,
            expectedSHA256: expectedHash
        )

        try await coordinator.start(req)

        let outcome = await coordinator.checksumOutcome(for: req.id)
        if case .verified(let sha) = outcome {
            XCTAssertEqual(sha.lowercased(), expectedHash.lowercased())
        } else {
            XCTFail("Expected .verified outcome, got \(outcome)")
        }

        // Test mismatch
        let mismatchDest = tempDirectory.appendingPathComponent("mismatch.bin")
        let mismatchReq = DownloadRequest(
            url: server.baseURL.appendingPathComponent(path),
            destinationURL: mismatchDest,
            expectedSHA256: "0000000000000000000000000000000000000000000000000000000000000000"
        )

        do {
            try await coordinator.start(mismatchReq)
            XCTFail("Should have thrown checksumMismatch error")
        } catch DownloadCoordinatorError.checksumMismatch {
            // Expected
            let mismatchOutcome = await coordinator.checksumOutcome(for: mismatchReq.id)
            if case .mismatch = mismatchOutcome {
                // Verified
            } else {
                XCTFail("Expected .mismatch outcome, got \(mismatchOutcome)")
            }
        }
    }
}
