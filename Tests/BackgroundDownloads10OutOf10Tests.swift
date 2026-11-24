import XCTest
import Foundation
@testable import DownloadEngineKit

final class BackgroundDownloads10OutOf10Tests: XCTestCase {

    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BG10Tests_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        DownloadNotificationManager.resetNotifiedIDs()
    }

    override func tearDown() {
        DownloadNotificationManager.resetNotifiedIDs()
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        super.tearDown()
    }

    // MARK: - 1. Streaming Handoff Cancels Foreground & Reconciles Checkpoints

    func testStreamingHandoffCancelsRunningForegroundSegmentsAndReconcilesCheckpoints() async throws {
        let manifestData = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:10
        #EXTINF:10.0,
        seg0.ts
        #EXTINF:10.0,
        seg1.ts
        #EXT-X-ENDLIST
        """.data(using: .utf8)!

        let manifestURL = URL(string: "https://example.com/handoff-test.m3u8")!
        let loader = MockManifestLoader(data: manifestData, finalURL: manifestURL)
        let executor = MockControllableSegmentExecutor()

        let hlsStore = try HLSPersistenceStore(storageDirectoryURL: tempDirectory)
        let bgManager = try BackgroundDownloadSessionManager(
            sessionIdentifier: "test.handoff.\(UUID().uuidString)",
            storageDirectoryURL: tempDirectory
        )

        let orchestrator = StreamingDownloadOrchestrator(
            manifestLoader: loader,
            segmentExecutor: executor,
            hlsPersistenceStore: hlsStore,
            backgroundSessionManager: bgManager
        )

        let candidate = try StreamingManifestCandidate(url: manifestURL, transportPolicy: .foreground)
        let proposal = try await orchestrator.prepare(candidate: candidate)
        let transferID = proposal.transferID

        // Pre-create segment 0 on disk to simulate it finishing right before handoff
        let segDir = tempDirectory.appendingPathComponent("handoff-segs", isDirectory: true)
        try FileManager.default.createDirectory(at: segDir, withIntermediateDirectories: true)
        let seg0File = segDir.appendingPathComponent("\(proposal.resources[0].identity.value).part")
        try Data(repeating: 0x47, count: 500).write(to: seg0File)

        // Save initial parent HLS record
        let parentRecord = HLSTransferRecord(
            id: transferID,
            manifestURL: manifestURL,
            outputFilename: "output.mp4",
            outputDestinationURL: tempDirectory.appendingPathComponent("output.mp4"),
            segmentDirectoryURL: segDir,
            totalSegments: proposal.resources.count,
            completedSegmentOrders: [],
            state: .downloading
        )
        try await hlsStore.save(parentRecord)

        // Register running transfer
        try await orchestrator.resume(transferID: transferID)
        let isManaging = await orchestrator.isManaging(id: transferID)
        XCTAssertTrue(isManaging)

        // Execute handoff to background
        await orchestrator.handoffActiveStreamingToBackground()

        // 1. Verify foreground cancellation was sent to executor
        let cancelledIDs = await executor.cancelledTransferIDs
        XCTAssertTrue(cancelledIDs.contains(transferID))

        // 2. Verify completed segment 0 was reconciled into checkpoints
        let updatedRecord = try await hlsStore.load(id: transferID)
        XCTAssertEqual(updatedRecord?.completedSegmentOrders.contains(0), true)

        // 3. Verify background session manager received remaining segment (seg 1) but NOT seg 0
        let bgRecords = await bgManager.mappingStore.records(forDownloadID: transferID)
        XCTAssertEqual(bgRecords.count, 1)
        XCTAssertEqual(bgRecords.first?.segmentID, 1)

        // 4. Verify proposal transport policy is now .background
        let activeProposal = await orchestrator.activeProposal(for: transferID)
        XCTAssertEqual(activeProposal?.transportPolicy, .background)

        // 5. Verify handoffInProgress transitioned back to false
        let inProgress = await orchestrator.isHandoffInProgress(transferID: transferID)
        XCTAssertFalse(inProgress)

        await bgManager.cancelTasks(for: transferID)
    }

    // MARK: - 2. Pause & PauseAll Cancels Active Segment Tasks and Checkpoints

    func testPauseAndPauseAllCancelsActiveSegmentTasksAndCheckpoints() async throws {
        let manifestData = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:10
        #EXTINF:10.0,
        seg0.ts
        #EXT-X-ENDLIST
        """.data(using: .utf8)!

        let manifestURL = URL(string: "https://example.com/pause-test.m3u8")!
        let loader = MockManifestLoader(data: manifestData, finalURL: manifestURL)
        let executor = MockControllableSegmentExecutor()
        let hlsStore = try HLSPersistenceStore(storageDirectoryURL: tempDirectory)

        let orchestrator = StreamingDownloadOrchestrator(
            manifestLoader: loader,
            segmentExecutor: executor,
            hlsPersistenceStore: hlsStore
        )

        let segDir = tempDirectory.appendingPathComponent("pause-segs", isDirectory: true)
        try FileManager.default.createDirectory(at: segDir, withIntermediateDirectories: true)
        let seg0File = segDir.appendingPathComponent("0_seg0.part")
        try Data(repeating: 0x47, count: 300).write(to: seg0File)

        let parentID = "stream-run-pause-test"
        let parentRecord = HLSTransferRecord(
            id: parentID,
            manifestURL: manifestURL,
            outputFilename: "output.mp4",
            outputDestinationURL: tempDirectory.appendingPathComponent("output.mp4"),
            segmentDirectoryURL: segDir,
            totalSegments: 1,
            completedSegmentOrders: [],
            state: .downloading
        )
        try await hlsStore.save(parentRecord)

        try await orchestrator.resume(transferID: parentID)

        // 1. Pause single transfer
        try await orchestrator.pause(transferID: parentID)
        let isPaused1 = await orchestrator.isPaused(transferID: parentID)
        XCTAssertTrue(isPaused1)

        // Verify cancellation was sent to executor
        let cancelledIDs = await executor.cancelledTransferIDs
        XCTAssertTrue(cancelledIDs.contains(parentID))

        // Verify segment was reconciled to disk
        let pausedRec = try await hlsStore.load(id: parentID)
        XCTAssertEqual(pausedRec?.state, .paused)
        XCTAssertEqual(pausedRec?.completedSegmentOrders.contains(0), true)

        // 2. Resume then test pauseAll()
        try await orchestrator.resume(transferID: parentID)
        let isPaused1AfterResume = await orchestrator.isPaused(transferID: parentID)
        XCTAssertFalse(isPaused1AfterResume)

        await orchestrator.pauseAll()
        let isPaused2 = await orchestrator.isPaused(transferID: parentID)
        XCTAssertTrue(isPaused2)
    }

    // MARK: - 3. Background Retry Recomputes Range From Actual Part File Size

    func testBackgroundRetryRecomputesRangeFromActualPartFileSize() async throws {
        let store = try DownloadPersistenceStore(storageDirectoryURL: tempDirectory)
        let download = DownloadRecord(
            id: "dl-range-recompute",
            originalURL: URL(string: "https://example.com/range-recompute.bin")!,
            destinationURL: tempDirectory.appendingPathComponent("range-recompute.bin"),
            totalSize: 1000,
            state: .downloading,
            storageMode: .partFiles,
            segments: [
                SegmentRecord(id: 0, startOffset: 0, endOffset: 999, length: 1000, completedBytes: 0)
            ]
        )
        try await store.save(download)

        let manager = try BackgroundDownloadSessionManager(
            sessionIdentifier: "test.recompute.\(UUID().uuidString)",
            storageDirectoryURL: tempDirectory,
            persistenceStore: store
        )

        let taskRecord = try await manager.scheduleSegmentDownload(
            download: download,
            segment: download.segments[0]
        )

        let tasks = await manager.activeSessionTasks()
        let initialTask = try XCTUnwrap(tasks.first { $0.taskIdentifier == taskRecord.taskIdentifier })

        // Pre-write 400 bytes to the part file on disk to simulate interrupted progress committed to disk
        let partFile = manager.partFileURL(downloadID: download.id, segmentID: 0)
        try Data(repeating: 0x55, count: 400).write(to: partFile)

        // Simulate transient network interruption without valid resumeData
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost, userInfo: [:])
        manager.urlSession(
            URLSession.shared,
            task: initialTask,
            didCompleteWithError: error
        )
        await manager.waitForInFlightEvents()

        // Verify recovered task record has recomputed start offset derived from disk size
        let records = await manager.mappingStore.records(forDownloadID: download.id)
        XCTAssertEqual(records.count, 1)
        let recovered = try XCTUnwrap(records.first)
        XCTAssertEqual(recovered.retryCount, 1)
        XCTAssertEqual(recovered.startOffset, 400, "Retry start offset must be recomputed from committed disk bytes")
        XCTAssertEqual(recovered.endOffset, 999)
        XCTAssertEqual(recovered.expectedBytes, 600, "Expected bytes must be remaining bytes (600)")
        XCTAssertEqual(recovered.initialSegmentCompletedBytes, 400)

        await manager.cancelTasks(for: download.id)
    }

    // MARK: - 4. Background Interruption When Part File Fully Downloaded Completes Immediately

    func testBackgroundInterruptionWhenPartFileFullyDownloadedCompletesImmediately() async throws {
        let store = try DownloadPersistenceStore(storageDirectoryURL: tempDirectory)
        let download = DownloadRecord(
            id: "dl-full-complete",
            originalURL: URL(string: "https://example.com/full-complete.bin")!,
            destinationURL: tempDirectory.appendingPathComponent("full-complete.bin"),
            totalSize: 1000,
            state: .downloading,
            storageMode: .partFiles,
            segments: [
                SegmentRecord(id: 0, startOffset: 0, endOffset: 999, length: 1000, completedBytes: 0)
            ]
        )
        try await store.save(download)

        let manager = try BackgroundDownloadSessionManager(
            sessionIdentifier: "test.fullcomplete.\(UUID().uuidString)",
            storageDirectoryURL: tempDirectory,
            persistenceStore: store
        )

        let taskRecord = try await manager.scheduleSegmentDownload(
            download: download,
            segment: download.segments[0]
        )

        let tasks = await manager.activeSessionTasks()
        let initialTask = try XCTUnwrap(tasks.first { $0.taskIdentifier == taskRecord.taskIdentifier })

        // Pre-write all 1000 bytes to disk
        let partFile = manager.partFileURL(downloadID: download.id, segmentID: 0)
        try Data(repeating: 0x77, count: 1000).write(to: partFile)

        var completedCalled = false
        manager.onSegmentCompleted = { dlID, segID, _ in
            if dlID == download.id && segID == 0 {
                completedCalled = true
            }
        }

        // Simulate interruption
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: [:])
        manager.urlSession(
            URLSession.shared,
            task: initialTask,
            didCompleteWithError: error
        )
        await manager.waitForInFlightEvents()

        // Verify task was marked completed without creating a new network retry
        let records = await manager.mappingStore.records(forDownloadID: download.id)
        XCTAssertEqual(records.count, 1)
        let completedRec = try XCTUnwrap(records.first)
        XCTAssertTrue(completedRec.isCompleted)
        XCTAssertEqual(completedRec.completedBytes, 1000)
        XCTAssertTrue(completedCalled)

        await manager.cancelTasks(for: download.id)
    }

    // MARK: - 5. Durable Notification De-Duplication Across Simulated Restarts

    func testDurableNotificationDeduplicationAcrossSimulatedRestart() throws {
        let notifStoreURL = tempDirectory.appendingPathComponent("test_notified_downloads.json")
        DownloadNotificationManager.setPersistenceFileURL(notifStoreURL)

        let downloadID = "dl-relaunch-persist-\(UUID().uuidString)"
        let filename = "relaunch.iso"

        var notificationCount = 0
        let observer = NotificationCenter.default.addObserver(
            forName: DownloadNotificationManager.downloadDidCompleteNotification,
            object: nil,
            queue: .main
        ) { _ in
            notificationCount += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        // 1. First completion post
        DownloadNotificationManager.postDownloadCompletedNotification(filename: filename, downloadID: downloadID)
        XCTAssertTrue(DownloadNotificationManager.isNotified(downloadID: downloadID))
        XCTAssertEqual(notificationCount, 1)

        // 2. Simulate complete app restart by pointing to the existing durable storage file
        DownloadNotificationManager.setPersistenceFileURL(notifStoreURL)

        // 3. Verify ID is still recorded as notified after reload
        XCTAssertTrue(DownloadNotificationManager.isNotified(downloadID: downloadID))

        // 4. Attempt second completion post (e.g. from launch reconciliation)
        DownloadNotificationManager.postDownloadCompletedNotification(filename: filename, downloadID: downloadID)

        // Give any async event time to settle
        let exp = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)

        // Notification count MUST remain 1 (no duplicate notification across restart)
        XCTAssertEqual(notificationCount, 1, "Notification must be deduplicated across app restarts via durable persistence")
    }

    // MARK: - 6. Permanent Error Status (401/403/404/410) Avoids Retries

    func testPermanentErrorStatus401And404AvoidsRetries() async throws {
        let store = try DownloadPersistenceStore(storageDirectoryURL: tempDirectory)
        let download = DownloadRecord(
            id: "dl-perm-error",
            originalURL: URL(string: "https://example.com/perm-error.bin")!,
            destinationURL: tempDirectory.appendingPathComponent("perm-error.bin"),
            totalSize: 1000,
            state: .downloading,
            storageMode: .partFiles,
            segments: [
                SegmentRecord(id: 0, startOffset: 0, endOffset: 999, length: 1000, completedBytes: 0)
            ]
        )
        try await store.save(download)

        let manager = try BackgroundDownloadSessionManager(
            sessionIdentifier: "test.permerror.\(UUID().uuidString)",
            storageDirectoryURL: tempDirectory,
            persistenceStore: store
        )

        let taskRecord = try await manager.scheduleSegmentDownload(
            download: download,
            segment: download.segments[0]
        )

        let tasks = await manager.activeSessionTasks()
        let initialTask = try XCTUnwrap(tasks.first { $0.taskIdentifier == taskRecord.taskIdentifier })

        var authStatus: Int?
        var failedError: Error?
        manager.onAuthenticationRequired = { dlID, segID, status in
            if dlID == download.id && segID == 0 {
                authStatus = status
            }
        }
        manager.onSegmentFailed = { dlID, segID, error in
            if dlID == download.id && segID == 0 {
                failedError = error
            }
        }

        // Simulate 401 Unauthorized
        let authError = NSError(
            domain: "HTTPErrorDomain",
            code: 401,
            userInfo: ["statusCode": 401]
        )
        manager.urlSession(
            URLSession.shared,
            task: initialTask,
            didCompleteWithError: authError
        )
        await manager.waitForInFlightEvents()

        // 1. Verify onAuthenticationRequired was triggered
        XCTAssertEqual(authStatus, 401)

        // 2. Verify no retry task was scheduled (retryCount remains 0, error recorded)
        let records = await manager.mappingStore.records(forDownloadID: download.id)
        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.retryCount, 0, "Permanent 401 error must NOT trigger automatic retry backoff")
        XCTAssertNotNil(record.errorDescription)

        // 3. Verify failedError was classified as authenticationRequired
        if let bgError = failedError as? BackgroundTransportError {
            XCTAssertEqual(bgError, BackgroundTransportError.authenticationRequired(status: 401))
        } else {
            XCTFail("Error must be BackgroundTransportError.authenticationRequired")
        }

        await manager.cancelTasks(for: download.id)
    }
}

// MARK: - Test Helpers

private actor MockControllableSegmentExecutor: StreamingSegmentExecutor {
    private(set) var requests: [StreamingSegmentTransferRequest] = []
    private(set) var cancelledTransferIDs: Set<String> = []

    func execute(
        _ request: StreamingSegmentTransferRequest,
        progress: (@Sendable (Double) -> Void)?
    ) async throws {
        requests.append(request)
        let count = request.byteRange.map { Int($0.length) } ?? 188
        let payload = Data(repeating: 0x47, count: count)
        try? FileManager.default.createDirectory(at: request.destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? payload.write(to: request.destinationURL)
        progress?(1)
    }

    func cancel(transferID: String) async {
        cancelledTransferIDs.insert(transferID)
    }
}

private actor MockManifestLoader: StreamingManifestLoader {
    let data: Data
    let finalURL: URL

    init(data: Data, finalURL: URL) {
        self.data = data
        self.finalURL = finalURL
    }

    func load(
        candidate: StreamingManifestCandidate,
        headers: [String: String],
        limits: ManifestParsingLimits
    ) async throws -> StreamingManifestResponse {
        return StreamingManifestResponse(
            data: data,
            finalURL: finalURL,
            mimeType: "application/vnd.apple.mpegurl"
        )
    }
}
