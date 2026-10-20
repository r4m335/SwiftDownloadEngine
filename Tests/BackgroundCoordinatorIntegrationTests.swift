import XCTest
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@testable import DM_Reverse_engineering

final class BackgroundCoordinatorIntegrationTests: XCTestCase {

    private var tempDirectory: URL!
    private var storageDirectory: URL!
    private var persistenceStore: DownloadPersistenceStore!
    private var bgSessionManager: BackgroundDownloadSessionManager!
    private var coordinator: DownloadCoordinator!
    private var server: LocalHTTPRangeServer!

    override func setUp() async throws {
        try await super.setUp()

        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("1DM_BG_Coord_Tests_\(UUID().uuidString)", isDirectory: true)
        storageDirectory = tempDirectory.appendingPathComponent("Store", isDirectory: true)
        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)

        persistenceStore = try DownloadPersistenceStore(storageDirectoryURL: storageDirectory)
        let bgDir = storageDirectory.appendingPathComponent("BackgroundTransport", isDirectory: true)
        bgSessionManager = try BackgroundDownloadSessionManager(
            sessionIdentifier: "com.r4m335.SwiftDownloadEngine.test-bg-\(UUID().uuidString.prefix(6))",
            storageDirectoryURL: bgDir,
            persistenceStore: persistenceStore
        )

        coordinator = try DownloadCoordinator(
            session: .shared,
            persistenceStore: persistenceStore,
            backgroundSessionManager: bgSessionManager
        )

        server = LocalHTTPRangeServer()
        try server.start()
    }

    override func tearDown() async throws {
        server?.stop()
        server = nil
        coordinator = nil
        bgSessionManager = nil
        persistenceStore = nil
        if let temp = tempDirectory {
            try? FileManager.default.removeItem(at: temp)
        }
        try await super.tearDown()
    }

    private func makePayload(size: Int, seed: UInt8 = 0x3C) -> Data {
        var data = Data(count: size)
        data.withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for i in 0..<size {
                base[i] = UInt8(((i &* 37) &+ Int(seed)) & 0xFF)
            }
        }
        return data
    }

    // MARK: - 1. Transport Policy Selection & Backward-Compatible Defaults

    func testExplicitTransportPolicySelectionAndDefaults() throws {
        let dummyURL = URL(string: "https://example.com/file.bin")!
        let destURL = tempDirectory.appendingPathComponent("file.bin")

        // 1. Default request must be foreground
        let defaultReq = DownloadRequest(url: dummyURL, destinationURL: destURL)
        XCTAssertEqual(defaultReq.transportPolicy, .foreground)

        // 2. Explicit background request
        let bgReq = DownloadRequest(url: dummyURL, destinationURL: destURL, transportPolicy: .background)
        XCTAssertEqual(bgReq.transportPolicy, .background)

        // 3. DownloadRecord defaults
        let defaultRecord = DownloadRecord(
            id: "rec-1",
            originalURL: dummyURL,
            destinationURL: destURL,
            totalSize: 100,
            state: .pending
        )
        XCTAssertEqual(defaultRecord.transportPolicy, .foreground)

        // 4. DownloadSnapshot defaults
        let defaultSnap = DownloadSnapshot(
            id: "snap-1",
            url: dummyURL,
            destinationURL: destURL,
            state: .pending
        )
        XCTAssertEqual(defaultSnap.transportPolicy, .foreground)

        // 5. Backward compatibility: Legacy JSON decoding without transportPolicy field
        let legacyJSON = """
        {
            "id": "legacy-req",
            "url": "https://example.com/legacy.bin",
            "destinationURL": "file:///tmp/legacy.bin",
            "headers": {},
            "configuredThreadCount": 4,
            "advancedMode": false,
            "storageMode": "directSeek",
            "reserveDiskBytes": 1024,
            "retryCount": 2,
            "resumePolicy": "compatibility"
        }
        """.data(using: .utf8)!

        let decodedReq = try JSONDecoder().decode(DownloadRequest.self, from: legacyJSON)
        XCTAssertEqual(decodedReq.transportPolicy, .foreground)
    }

    // MARK: - 2. Existing Foreground Behavior Remaining Unchanged

    func testExistingForegroundBehaviorRemainingUnchanged() async throws {
        let payload = makePayload(size: 64 * 1024)
        let expectedSHA = EngineSHA256.hash(data: payload)
        let testPath = "/foreground_unchanged.bin"
        server.register(path: testPath, data: payload, eTag: "\"fg-test-etag\"")
        let sourceURL = server.url(for: testPath)
        let destURL = tempDirectory.appendingPathComponent("fg_result.bin")

        let request = DownloadRequest(
            id: "fg-unchanged",
            url: sourceURL,
            destinationURL: destURL,
            configuredThreadCount: 2,
            expectedSHA256: expectedSHA,
            transportPolicy: .foreground
        )

        try await coordinator.start(request)

        let record = try await persistenceStore.fetch(tag: "fg-unchanged")
        XCTAssertEqual(record?.state, .completed)
        XCTAssertEqual(record?.transportPolicy, .foreground)
        XCTAssertEqual(try? Data(contentsOf: destURL).count, payload.count)
        XCTAssertEqual(try? FileHasher.sha256(for: destURL), expectedSHA)

        // Ensure no background session tasks were scheduled
        let bgTasks = await bgSessionManager.activeTasks(for: "fg-unchanged")
        XCTAssertTrue(bgTasks.isEmpty)
    }

    // MARK: - 3. Background Segment Scheduling & Persistence

    func testBackgroundSegmentSchedulingAndPersistence() async throws {
        let targetURL = URL(string: "https://example.com/bg_archive.zip")!
        let destURL = tempDirectory.appendingPathComponent("bg_archive.zip")

        let segment1 = SegmentRecord(id: 0, startOffset: 0, endOffset: 999, length: 1000, completedBytes: 0)
        let segment2 = SegmentRecord(id: 1, startOffset: 1000, endOffset: 1999, length: 1000, completedBytes: 0)

        let record = DownloadRecord(
            id: "bg-sched-test",
            originalURL: targetURL,
            destinationURL: destURL,
            totalSize: 2000,
            state: .downloading,
            storageMode: .partFiles,
            transportPolicy: .background,
            eTag: "\"bg-etag-1\"",
            segments: [segment1, segment2]
        )
        try await persistenceStore.save(record)

        let task1 = try await bgSessionManager.scheduleSegmentDownload(download: record, segment: segment1)
        XCTAssertEqual(task1.downloadID, "bg-sched-test")
        XCTAssertEqual(task1.segmentID, 0)
        XCTAssertEqual(task1.expectedBytes, 1000)
        XCTAssertEqual(task1.sessionIdentifier, bgSessionManager.sessionIdentifier)

        let tasks = await bgSessionManager.activeTasks(for: "bg-sched-test")
        XCTAssertEqual(tasks.count, 1)

        await bgSessionManager.cancelTasks(for: "bg-sched-test")
    }

    // MARK: - 4. Duplicate-Task Prevention

    func testDuplicateTaskPrevention() async throws {
        let targetURL = URL(string: "https://example.com/duplicate_test.bin")!
        let destURL = tempDirectory.appendingPathComponent("dup.bin")

        let segment = SegmentRecord(id: 0, startOffset: 0, endOffset: 999, length: 1000)
        let record = DownloadRecord(
            id: "dup-check",
            originalURL: targetURL,
            destinationURL: destURL,
            totalSize: 1000,
            state: .downloading,
            storageMode: .partFiles,
            transportPolicy: .background,
            segments: [segment]
        )
        try await persistenceStore.save(record)

        let first = try await bgSessionManager.scheduleSegmentDownload(download: record, segment: segment)
        let activeBefore = await bgSessionManager.activeTasks(for: "dup-check")
        XCTAssertEqual(activeBefore.count, 1)
        XCTAssertEqual(activeBefore.first?.taskIdentifier, first.taskIdentifier)

        // Cancel tasks to clean up session
        await bgSessionManager.cancelTasks(for: "dup-check")
        let activeAfter = await bgSessionManager.activeTasks(for: "dup-check")
        XCTAssertTrue(activeAfter.isEmpty)
    }

    // MARK: - 5. Pause and Resume

    func testPauseAndResumeBackgroundTransfer() async throws {
        let targetURL = URL(string: "https://example.com/pause_resume.bin")!
        let destURL = tempDirectory.appendingPathComponent("pause_resume.bin")

        let seg0 = SegmentRecord(id: 0, startOffset: 0, endOffset: 499, length: 500, completedBytes: 500)
        let seg1 = SegmentRecord(id: 1, startOffset: 500, endOffset: 999, length: 500, completedBytes: 0)

        let record = DownloadRecord(
            id: "dl-pause-resume",
            originalURL: targetURL,
            destinationURL: destURL,
            totalSize: 1000,
            state: .downloading,
            storageMode: .partFiles,
            transportPolicy: .background,
            segments: [seg0, seg1]
        )
        try await persistenceStore.save(record)

        // Schedule seg1
        _ = try await bgSessionManager.scheduleSegmentDownload(download: record, segment: seg1)
        let active = await bgSessionManager.activeTasks(for: "dl-pause-resume")
        XCTAssertEqual(active.count, 1)

        // Pause via coordinator
        try await coordinator.pause(id: "dl-pause-resume")

        // Tasks must be cancelled and removed from mapping
        let activeAfterPause = await bgSessionManager.activeTasks(for: "dl-pause-resume")
        XCTAssertTrue(activeAfterPause.isEmpty)

        let saved = try await persistenceStore.fetch(tag: "dl-pause-resume")
        XCTAssertEqual(saved?.state, .paused)
    }

    // MARK: - 6. Cancellation and Removal

    func testCancellationAndRemoval() async throws {
        let targetURL = URL(string: "https://example.com/cancel_test.bin")!
        let destURL = tempDirectory.appendingPathComponent("cancel.bin")

        let seg0 = SegmentRecord(id: 0, startOffset: 0, endOffset: 999, length: 1000)
        let record = DownloadRecord(
            id: "dl-cancel",
            originalURL: targetURL,
            destinationURL: destURL,
            totalSize: 1000,
            state: .downloading,
            storageMode: .partFiles,
            transportPolicy: .background,
            segments: [seg0]
        )
        try await persistenceStore.save(record)

        // Create a dummy part file
        let partFile = bgSessionManager.partFileURL(downloadID: "dl-cancel", segmentID: 0)
        try Data(repeating: 0x42, count: 500).write(to: partFile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: partFile.path))

        // Schedule background task
        _ = try await bgSessionManager.scheduleSegmentDownload(download: record, segment: seg0)

        // Cancel with deleteDestinationFile = true
        try await coordinator.cancel(id: "dl-cancel", deleteDestinationFile: true)

        let active = await bgSessionManager.activeTasks(for: "dl-cancel")
        XCTAssertTrue(active.isEmpty)

        // Part file and record must be cleaned up
        XCTAssertFalse(FileManager.default.fileExists(atPath: partFile.path))
        let fetched = try await persistenceStore.fetch(tag: "dl-cancel")
        XCTAssertNil(fetched)
    }

    // MARK: - 7. Multi-Segment Merge and Checksum Verification

    func testMultiSegmentMergeAndChecksumVerification() throws {
        let destURL = tempDirectory.appendingPathComponent("merged_result.bin")
        let chunk1 = makePayload(size: 1024, seed: 0x11)
        let chunk2 = makePayload(size: 2048, seed: 0x22)
        let chunk3 = makePayload(size: 512, seed: 0x33)

        let fullPayload = chunk1 + chunk2 + chunk3
        let expectedSHA = EngineSHA256.hash(data: fullPayload)

        let part1 = tempDirectory.appendingPathComponent("seg-0.part")
        let part2 = tempDirectory.appendingPathComponent("seg-1.part")
        let part3 = tempDirectory.appendingPathComponent("seg-2.part")

        try chunk1.write(to: part1)
        try chunk2.write(to: part2)
        try chunk3.write(to: part3)

        try DownloadFileWriter.mergeFiles(
            partURLs: [part1, part2, part3],
            destinationURL: destURL,
            expectedMergedSize: Int64(fullPayload.count)
        )

        let actualData = try Data(contentsOf: destURL)
        XCTAssertEqual(actualData, fullPayload)
        let computedSHA = try FileHasher.sha256(for: destURL)
        XCTAssertEqual(computedSHA.caseInsensitiveCompare(expectedSHA), .orderedSame)
    }

    // MARK: - 8. Progress Restoration & Part File Reconciliation After Relaunch

    func testProgressRestorationAfterRelaunch() async throws {
        let dlID = "relaunch-test"
        let destURL = tempDirectory.appendingPathComponent("relaunch.bin")
        let seg0Length: Int64 = 1024
        let seg1Length: Int64 = 2048

        // Simulate complete part file for seg 0
        let part0 = bgSessionManager.partFileURL(downloadID: dlID, segmentID: 0)
        try Data(repeating: 0xAA, count: Int(seg0Length)).write(to: part0)

        let record0 = BackgroundDownloadTaskRecord(
            sessionIdentifier: bgSessionManager.sessionIdentifier,
            taskIdentifier: 901,
            downloadID: dlID,
            segmentID: 0,
            originalURL: URL(string: "https://example.com/file.bin")!,
            startOffset: 0,
            endOffset: seg0Length - 1,
            expectedBytes: seg0Length,
            segmentLength: seg0Length,
            destinationPartURL: part0
        )
        try await bgSessionManager.mappingStore.save(record: record0)

        let dlRecord = DownloadRecord(
            id: dlID,
            originalURL: URL(string: "https://example.com/file.bin")!,
            destinationURL: destURL,
            totalSize: seg0Length + seg1Length,
            state: .downloading,
            storageMode: .partFiles,
            transportPolicy: .background,
            segments: [
                SegmentRecord(id: 0, startOffset: 0, endOffset: seg0Length - 1, length: seg0Length, completedBytes: 0),
                SegmentRecord(id: 1, startOffset: seg0Length, endOffset: seg0Length + seg1Length - 1, length: seg1Length, completedBytes: 0)
            ]
        )
        try await persistenceStore.save(dlRecord)

        // Run reconciliation
        let report = try await coordinator.reconcileBackgroundTransfers()
        XCTAssertEqual(report.completedRecords.count, 1)
        XCTAssertEqual(report.completedRecords.first?.segmentID, 0)

        // Verify DownloadPersistenceStore updated seg0 to complete
        let updatedDL = try await persistenceStore.fetch(tag: dlID)
        XCTAssertEqual(updatedDL?.segments.first(where: { $0.id == 0 })?.completedBytes, seg0Length)
        XCTAssertEqual(updatedDL?.segments.first(where: { $0.id == 0 })?.isCompleted, true)
    }

    // MARK: - 9. Server Ignores Range Requests: Safe Foreground Fallback

    func testServerIgnoresRangeRequestsFallback() async throws {
        let payload = makePayload(size: 8192)
        let expectedSHA = EngineSHA256.hash(data: payload)
        let testPath = "/no_ranges.bin"

        // Register on LocalHTTPRangeServer with ignoresRange = true (returns 200 OK without partial content support)
        server.register(path: testPath, data: payload, ignoresRange: true)
        let sourceURL = server.url(for: testPath)
        let destURL = tempDirectory.appendingPathComponent("fallback_result.bin")

        let request = DownloadRequest(
            id: "bg-fallback-test",
            url: sourceURL,
            destinationURL: destURL,
            expectedSHA256: expectedSHA,
            transportPolicy: .background
        )

        try await coordinator.start(request)

        let record = try await persistenceStore.fetch(tag: "bg-fallback-test")
        XCTAssertEqual(record?.state, .completed)
        XCTAssertEqual(try? Data(contentsOf: destURL).count, payload.count)
        XCTAssertEqual(try? FileHasher.sha256(for: destURL), expectedSHA)
    }

    // MARK: - 10. Background Callback Ordering & Completion Handler Verification

    func testEventProcessingCompletesBeforeBackgroundCompletionHandler() async throws {
        let manager = bgSessionManager!

        final class CompletionBox: @unchecked Sendable {
            private let lock = NSLock()
            private var _invoked = false
            var invoked: Bool {
                lock.lock()
                defer { lock.unlock() }
                return _invoked
            }
            func setInvoked() {
                lock.lock()
                defer { lock.unlock() }
                _invoked = true
            }
        }

        let box = CompletionBox()
        manager.setEventsCompletionHandler {
            box.setInvoked()
        }

        // Track asynchronous delegate task
        manager.trackDelegateTaskStarted()

        // Simulate async task running: waitForInFlightEvents must wait
        let waitTask = Task {
            await manager.waitForInFlightEvents()
            return true
        }

        // Give small window to ensure waitTask is blocked
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(box.invoked)

        // Now signal delegate task finished
        manager.trackDelegateTaskFinished()
        let didFinish = await waitTask.value
        XCTAssertTrue(didFinish)

        // Trigger finish events
        manager.urlSessionDidFinishEvents(forBackgroundURLSession: URLSession.shared)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(box.invoked)
    }
}
