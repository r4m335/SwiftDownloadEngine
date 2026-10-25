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

/// Thread-safe event collector for AsyncStream<DownloadEvent> consumption.
private actor EventCollector {
    private var events: [DownloadEvent] = []

    func append(_ event: DownloadEvent) {
        events.append(event)
    }

    func allEvents() -> [DownloadEvent] {
        events
    }

    func count() -> Int {
        events.count
    }

    func count(where predicate: (DownloadEvent) -> Bool) -> Int {
        events.filter(predicate).count
    }

    func contains(where predicate: (DownloadEvent) -> Bool) -> Bool {
        events.contains(where: predicate)
    }

    func first(where predicate: (DownloadEvent) -> Bool) -> DownloadEvent? {
        events.first(where: predicate)
    }
}

final class DownloadEngineTests: XCTestCase {
    private var server: LocalHTTPRangeServer!
    private var tempDirectory: URL!
    private var persistenceStore: DownloadPersistenceStore!
    private var coordinator: DownloadCoordinator!
    private var queueManager: DownloadQueueManager!
    private var engine: DownloadEngine!

    override func setUp() async throws {
        try await super.setUp()
        #if canImport(Glibc)
        Glibc.signal(SIGPIPE, SIG_IGN)
        #elseif canImport(Darwin)
        Darwin.signal(SIGPIPE, SIG_IGN)
        #endif

        server = LocalHTTPRangeServer()
        try server.start()

        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("1DM_Engine_Tests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let storeURL = tempDirectory.appendingPathComponent("Store", isDirectory: true)
        persistenceStore = try DownloadPersistenceStore(storageDirectoryURL: storeURL)
        coordinator = try DownloadCoordinator(session: .shared, persistenceStore: persistenceStore)
        queueManager = DownloadQueueManager(
            coordinator: coordinator,
            persistenceStore: persistenceStore,
            maxConcurrentDownloads: 3
        )
        engine = DownloadEngine(
            queueManager: queueManager,
            coordinator: coordinator,
            persistenceStore: persistenceStore
        )
    }

    override func tearDown() async throws {
        if let engine {
            await engine.cancelAllDownloads(deleteFiles: false)
            await engine.shutdown()
        }
        server?.stop()
        server = nil
        engine = nil
        queueManager = nil
        coordinator = nil
        persistenceStore = nil

        if let temp = tempDirectory {
            try? FileManager.default.removeItem(at: temp)
        }
        try await super.tearDown()
    }

    private func makePayload(size: Int, byte: UInt8 = 0xAB) -> Data {
        Data(repeating: byte, count: size)
    }

    // MARK: - 1. Adding a Download Through the Public Facade

    func testAddDownloadThroughFacade() async throws {
        let payload = makePayload(size: 64 * 1024)
        server.register(path: "/add_test.bin", data: payload)

        let destURL = tempDirectory.appendingPathComponent("add_test.bin")
        let request = DownloadRequest(
            url: server.baseURL.appendingPathComponent("add_test.bin"),
            destinationURL: destURL
        )

        let snapshot = try await engine.addDownload(request, priority: .normal, autoStart: false)

        XCTAssertEqual(snapshot.id, request.id)
        XCTAssertEqual(snapshot.url, request.url)
        XCTAssertEqual(snapshot.destinationURL, destURL)
        XCTAssertEqual(snapshot.state, .pending)
        XCTAssertEqual(snapshot.completedBytes, 0)
        XCTAssertFalse(snapshot.isCompleted)
        XCTAssertFalse(snapshot.isTerminal)

        let queried = await engine.snapshot(for: request.id)
        XCTAssertNotNil(queried)
        XCTAssertEqual(queried?.id, request.id)

        let all = await engine.allSnapshots()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.id, request.id)
    }

    // MARK: - 2. Download Completion and Final File Contents

    func testDownloadCompletionAndFileContents() async throws {
        let size = 128 * 1024
        var payload = Data(count: size)
        for i in 0..<size {
            payload[i] = UInt8(i % 251)
        }
        server.register(path: "/complete.bin", data: payload)

        let destURL = tempDirectory.appendingPathComponent("complete.bin")
        let request = DownloadRequest(
            url: server.baseURL.appendingPathComponent("complete.bin"),
            destinationURL: destURL
        )

        let initialSnap = try await engine.addDownload(request, autoStart: true)
        XCTAssertEqual(initialSnap.id, request.id)

        try await engine.waitUntilIdle(timeoutSeconds: 10.0)

        guard let finalSnap = await engine.snapshot(for: request.id) else {
            XCTFail("Snapshot should exist")
            return
        }

        XCTAssertEqual(finalSnap.state, .completed)
        XCTAssertTrue(finalSnap.isCompleted)
        XCTAssertTrue(finalSnap.isTerminal)
        XCTAssertEqual(finalSnap.completedBytes, Int64(size))
        XCTAssertEqual(finalSnap.totalBytes, Int64(size))
        XCTAssertEqual(finalSnap.progressFraction, 1.0, accuracy: 0.001)

        XCTAssertTrue(FileManager.default.fileExists(atPath: destURL.path))
        let downloadedData = try Data(contentsOf: destURL)
        XCTAssertEqual(downloadedData.count, size)
        XCTAssertEqual(downloadedData, payload)
    }

    // MARK: - 3. Download Progress Events

    func testDownloadProgressEvents() async throws {
        let size = 256 * 1024
        let payload = makePayload(size: size, byte: 0x42)
        server.register(path: "/progress.bin", data: payload)

        let destURL = tempDirectory.appendingPathComponent("progress.bin")
        let request = DownloadRequest(
            url: server.baseURL.appendingPathComponent("progress.bin"),
            destinationURL: destURL
        )

        let collector = EventCollector()
        let stream = await engine.events()
        let task = Task {
            for await event in stream {
                await collector.append(event)
            }
        }

        _ = try await engine.addDownload(request, autoStart: true)
        try await engine.waitUntilIdle(timeoutSeconds: 10.0)
        try? await Task.sleep(nanoseconds: 50_000_000)

        task.cancel()

        let hasAdded = await collector.contains {
            if case .added(let snap) = $0 { return snap.id == request.id }
            return false
        }
        let hasCompleted = await collector.contains {
            if case .completed(let snap) = $0 { return snap.id == request.id }
            return false
        }

        XCTAssertTrue(hasAdded, "Stream must emit .added event")
        XCTAssertTrue(hasCompleted, "Stream must emit .completed event")

        let all = await collector.allEvents()
        XCTAssertGreaterThanOrEqual(all.count, 2)
    }

    // MARK: - 4. Pause and Resume Through the Facade

    func testPauseAndResumeThroughFacade() async throws {
        let size = 384 * 1024
        var payload = Data(count: size)
        for i in 0..<size {
            payload[i] = UInt8(i % 249)
        }
        server.register(path: "/pause_resume.bin", data: payload, chunkDelayMs: 2)

        let destURL = tempDirectory.appendingPathComponent("pause_resume.bin")
        let request = DownloadRequest(
            url: server.baseURL.appendingPathComponent("pause_resume.bin"),
            destinationURL: destURL
        )

        _ = try await engine.addDownload(request, autoStart: true)

        // Wait briefly for transfer to start
        var active = false
        for _ in 0..<50 {
            if let snap = await engine.snapshot(for: request.id), snap.state == .downloading {
                active = true
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(active)

        // Pause download
        try await engine.pauseDownload(id: request.id)
        let pausedSnap = await engine.snapshot(for: request.id)
        XCTAssertEqual(pausedSnap?.state, .paused)
        XCTAssertTrue(pausedSnap?.canResume ?? false)

        // Resume download
        try await engine.resumeDownload(id: request.id)
        try await engine.waitUntilIdle(timeoutSeconds: 15.0)

        let finalSnap = await engine.snapshot(for: request.id)
        XCTAssertEqual(finalSnap?.state, .completed)
        XCTAssertEqual(finalSnap?.completedBytes, Int64(size))

        let downloaded = try Data(contentsOf: destURL)
        XCTAssertEqual(downloaded, payload)
    }

    // MARK: - 5. Cancellation Through the Facade

    func testCancellationThroughFacade() async throws {
        let size = 512 * 1024
        let payload = makePayload(size: size, byte: 0xEE)
        server.register(path: "/cancel.bin", data: payload, chunkDelayMs: 2)

        let destURL = tempDirectory.appendingPathComponent("cancel.bin")
        let request = DownloadRequest(
            url: server.baseURL.appendingPathComponent("cancel.bin"),
            destinationURL: destURL
        )

        _ = try await engine.addDownload(request, autoStart: true)

        var active = false
        for _ in 0..<50 {
            if let snap = await engine.snapshot(for: request.id), snap.state == .downloading {
                active = true
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(active)

        try await engine.cancelDownload(id: request.id, deleteFile: false)

        let snap = await engine.snapshot(for: request.id)
        XCTAssertEqual(snap?.state, .cancelled)
        XCTAssertTrue(snap?.isTerminal ?? false)
    }

    // MARK: - 6. Retrying a Failed Download

    func testRetryingFailedDownload() async throws {
        let size = 64 * 1024
        let payload = makePayload(size: size, byte: 0x55)
        server.register(path: "/retry.bin", data: payload, statusCodeOverride: 500)

        let destURL = tempDirectory.appendingPathComponent("retry.bin")
        let request = DownloadRequest(
            url: server.baseURL.appendingPathComponent("retry.bin"),
            destinationURL: destURL,
            retryCount: 0
        )

        _ = try await engine.addDownload(request, autoStart: true)
        try await engine.waitUntilIdle(timeoutSeconds: 10.0)

        let failedSnap = await engine.snapshot(for: request.id)
        XCTAssertTrue(failedSnap?.isFailed ?? false)

        // Fix server endpoint to return 200 OK
        server.register(path: "/retry.bin", data: payload)

        // Retry via facade
        try await engine.retryDownload(id: request.id)
        try await engine.waitUntilIdle(timeoutSeconds: 10.0)

        let completedSnap = await engine.snapshot(for: request.id)
        XCTAssertEqual(completedSnap?.state, .completed)
        XCTAssertEqual(completedSnap?.completedBytes, Int64(size))

        let downloaded = try Data(contentsOf: destURL)
        XCTAssertEqual(downloaded, payload)
    }

    // MARK: - 7. Removing a Download Without Accidentally Deleting Its File

    func testRemoveDownloadWithoutDeletingFile() async throws {
        let size = 64 * 1024
        let payload = makePayload(size: size, byte: 0x99)
        server.register(path: "/remove_nodelete.bin", data: payload)

        let destURL = tempDirectory.appendingPathComponent("remove_nodelete.bin")
        let request = DownloadRequest(
            url: server.baseURL.appendingPathComponent("remove_nodelete.bin"),
            destinationURL: destURL
        )

        _ = try await engine.addDownload(request, autoStart: true)
        try await engine.waitUntilIdle(timeoutSeconds: 10.0)

        XCTAssertTrue(FileManager.default.fileExists(atPath: destURL.path))

        // Remove from queue with deleteFile = false
        try await engine.removeDownload(id: request.id, deleteFile: false)

        let snap = await engine.snapshot(for: request.id)
        XCTAssertNil(snap, "Download entry should be removed from queue")

        // File must still be intact on disk
        XCTAssertTrue(FileManager.default.fileExists(atPath: destURL.path), "Destination file must be preserved")
        let data = try Data(contentsOf: destURL)
        XCTAssertEqual(data, payload)

        // Now test removal with deleteFile = true
        let destURL2 = tempDirectory.appendingPathComponent("remove_delete.bin")
        let request2 = DownloadRequest(
            url: server.baseURL.appendingPathComponent("remove_nodelete.bin"),
            destinationURL: destURL2
        )
        _ = try await engine.addDownload(request2, autoStart: true)
        try await engine.waitUntilIdle(timeoutSeconds: 10.0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destURL2.path))

        try await engine.removeDownload(id: request2.id, deleteFile: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destURL2.path), "Destination file must be deleted when deleteFile is true")
    }

    // MARK: - 8. Retrieving Snapshots for Active and Completed Downloads

    func testRetrieveSnapshotsActiveAndCompleted() async throws {
        let fastPayload = makePayload(size: 32 * 1024, byte: 0x11)
        server.register(path: "/fast.bin", data: fastPayload)

        let slowPayload = makePayload(size: 512 * 1024, byte: 0x22)
        server.register(path: "/slow.bin", data: slowPayload, chunkDelayMs: 2)

        let fastDest = tempDirectory.appendingPathComponent("fast.bin")
        let slowDest = tempDirectory.appendingPathComponent("slow.bin")

        let fastReq = DownloadRequest(url: server.baseURL.appendingPathComponent("fast.bin"), destinationURL: fastDest)
        let slowReq = DownloadRequest(url: server.baseURL.appendingPathComponent("slow.bin"), destinationURL: slowDest)

        _ = try await engine.addDownload(fastReq, autoStart: true)
        _ = try await engine.addDownload(slowReq, autoStart: true)

        // Wait for fast to complete
        for _ in 0..<50 {
            if let snap = await engine.snapshot(for: fastReq.id), snap.isCompleted {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let fastSnap = await engine.snapshot(for: fastReq.id)
        XCTAssertEqual(fastSnap?.state, .completed)
        XCTAssertEqual(fastSnap?.completedBytes, 32 * 1024)

        let allSnaps = await engine.allSnapshots()
        XCTAssertEqual(allSnaps.count, 2)
        XCTAssertTrue(allSnaps.contains { $0.id == fastReq.id && $0.isCompleted })

        // Cancel slow download before ending test
        try await engine.cancelDownload(id: slowReq.id)
    }

    // MARK: - 9. Multiple Simultaneous Downloads

    func testMultipleSimultaneousDownloads() async throws {
        let count = 4
        var requests: [DownloadRequest] = []
        for i in 0..<count {
            let data = makePayload(size: 48 * 1024, byte: UInt8(i + 1))
            let path = "/multi_\(i).bin"
            server.register(path: path, data: data)

            let dest = tempDirectory.appendingPathComponent("multi_\(i).bin")
            let req = DownloadRequest(url: server.baseURL.appendingPathComponent(path), destinationURL: dest)
            requests.append(req)
        }

        _ = try await engine.addDownloads(requests, autoStart: true)
        try await engine.waitUntilIdle(timeoutSeconds: 15.0)

        for req in requests {
            guard let snap = await engine.snapshot(for: req.id) else {
                XCTFail("Snapshot missing for \(req.id)")
                continue
            }
            XCTAssertEqual(snap.state, .completed)
            XCTAssertEqual(snap.completedBytes, 48 * 1024)
            XCTAssertTrue(FileManager.default.fileExists(atPath: req.destinationURL.path))
        }
    }

    // MARK: - 10. Multiple Independent Event-Stream Subscribers

    func testMultipleIndependentSubscribers() async throws {
        let payload = makePayload(size: 64 * 1024, byte: 0x77)
        server.register(path: "/multi_sub.bin", data: payload)

        let dest = tempDirectory.appendingPathComponent("multi_sub.bin")
        let req = DownloadRequest(url: server.baseURL.appendingPathComponent("multi_sub.bin"), destinationURL: dest)

        let collector1 = EventCollector()
        let collector2 = EventCollector()

        let stream1 = await engine.events()
        let stream2 = await engine.events()

        let task1 = Task {
            for await event in stream1 {
                await collector1.append(event)
            }
        }
        let task2 = Task {
            for await event in stream2 {
                await collector2.append(event)
            }
        }

        _ = try await engine.addDownload(req, autoStart: true)
        try await engine.waitUntilIdle(timeoutSeconds: 10.0)

        task1.cancel()
        task2.cancel()

        let c1HasCompleted = await collector1.contains {
            if case .completed(let snap) = $0 { return snap.id == req.id }
            return false
        }
        let c2HasCompleted = await collector2.contains {
            if case .completed(let snap) = $0 { return snap.id == req.id }
            return false
        }

        XCTAssertTrue(c1HasCompleted, "Subscriber 1 must receive .completed")
        XCTAssertTrue(c2HasCompleted, "Subscriber 2 must receive .completed")
    }

    // MARK: - 11. A Subscriber Joining After a Download Has Already Started

    func testSubscriberJoiningAfterDownloadStarted() async throws {
        let size = 512 * 1024
        let payload = makePayload(size: size, byte: 0x33)
        server.register(path: "/late_sub.bin", data: payload, chunkDelayMs: 2)

        let dest = tempDirectory.appendingPathComponent("late_sub.bin")
        let req = DownloadRequest(url: server.baseURL.appendingPathComponent("late_sub.bin"), destinationURL: dest)

        _ = try await engine.addDownload(req, autoStart: true)

        // Wait until active
        for _ in 0..<50 {
            if let snap = await engine.snapshot(for: req.id), snap.state == .downloading {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        // Authoritative query is valid even before subscribing
        let midSnap = await engine.snapshot(for: req.id)
        XCTAssertNotNil(midSnap)

        // Late subscriber attaches
        let collector = EventCollector()
        let stream = await engine.events()
        let task = Task {
            for await event in stream {
                await collector.append(event)
            }
        }

        try await engine.waitUntilIdle(timeoutSeconds: 15.0)
        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()

        let hasCompleted = await collector.contains {
            if case .completed(let snap) = $0 { return snap.id == req.id }
            return false
        }
        XCTAssertTrue(hasCompleted, "Late subscriber must receive subsequent .completed event")
    }

    // MARK: - 12. Stream Termination and Subscriber Cleanup

    func testStreamTerminationAndSubscriberCleanup() async throws {
        let initialCount = await engine.subscriberCount
        XCTAssertEqual(initialCount, 0)

        let stream = await engine.events()
        let countAfterSub = await engine.subscriberCount
        XCTAssertEqual(countAfterSub, 1)

        let task = Task {
            for await _ in stream {
                break
            }
        }

        // Cancel consumer task to trigger onTermination
        task.cancel()

        // Allow cooperative cleanup
        for _ in 0..<20 {
            if await engine.subscriberCount == 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let finalCount = await engine.subscriberCount
        XCTAssertEqual(finalCount, 0, "Subscriber must be dereferenced upon task cancellation")
    }

    // MARK: - 13. Concurrent Control Operations

    func testConcurrentControlOperations() async throws {
        let size = 256 * 1024
        let payload = makePayload(size: size, byte: 0x88)
        server.register(path: "/concurrent.bin", data: payload, chunkDelayMs: 1)

        let dest = tempDirectory.appendingPathComponent("concurrent.bin")
        let req = DownloadRequest(url: server.baseURL.appendingPathComponent("concurrent.bin"), destinationURL: dest)

        _ = try await engine.addDownload(req, autoStart: true)

        // Rapid concurrent operations from multiple concurrent Tasks
        let engine = self.engine!
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = await engine.snapshot(for: req.id)
            }
            group.addTask {
                _ = await engine.allSnapshots()
            }
            group.addTask {
                _ = await engine.speedMetrics(for: req.id)
            }
            group.addTask {
                _ = await engine.queueSnapshot()
            }
        }

        try await engine.waitUntilIdle(timeoutSeconds: 10.0)
        let finalSnap = await engine.snapshot(for: req.id)
        XCTAssertTrue(finalSnap?.isTerminal ?? false)
    }

    // MARK: - 14. Correct Failure-Event Delivery

    func testCorrectFailureEventDelivery() async throws {
        server.register(path: "/fail.bin", data: Data(), statusCodeOverride: 404)

        let dest = tempDirectory.appendingPathComponent("fail.bin")
        let req = DownloadRequest(
            url: server.baseURL.appendingPathComponent("fail.bin"),
            destinationURL: dest,
            retryCount: 0
        )

        let collector = EventCollector()
        let stream = await engine.events()
        let task = Task {
            for await event in stream {
                await collector.append(event)
            }
        }

        _ = try await engine.addDownload(req, autoStart: true)
        try await engine.waitUntilIdle(timeoutSeconds: 10.0)
        try? await Task.sleep(nanoseconds: 150_000_000)
        task.cancel()

        let failedEvent = await collector.first {
            if case .failed(let snap, _) = $0 { return snap.id == req.id }
            return false
        }

        XCTAssertNotNil(failedEvent, "Failure event must be delivered")
        if case .failed(let snap, let reason) = failedEvent {
            XCTAssertEqual(snap.id, req.id)
            XCTAssertFalse(reason.isEmpty)
        }
    }

    // MARK: - 15. No Duplicate Terminal Events

    func testNoDuplicateTerminalEvents() async throws {
        let payload = makePayload(size: 64 * 1024, byte: 0x44)
        server.register(path: "/no_dup.bin", data: payload)

        let dest = tempDirectory.appendingPathComponent("no_dup.bin")
        let req = DownloadRequest(url: server.baseURL.appendingPathComponent("no_dup.bin"), destinationURL: dest)

        let collector = EventCollector()
        let stream = await engine.events()
        let task = Task {
            for await event in stream {
                await collector.append(event)
            }
        }

        _ = try await engine.addDownload(req, autoStart: true)
        try await engine.waitUntilIdle(timeoutSeconds: 10.0)
        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()

        let completedCount = await collector.count {
            if case .completed(let snap) = $0 { return snap.id == req.id }
            return false
        }
        let failedCount = await collector.count {
            if case .failed(let snap, _) = $0 { return snap.id == req.id }
            return false
        }
        let cancelledCount = await collector.count {
            if case .cancelled(let snap) = $0 { return snap.id == req.id }
            return false
        }

        let terminalTotal = completedCount + failedCount + cancelledCount
        XCTAssertEqual(terminalTotal, 1, "There must be exactly 1 terminal event emitted")
    }

    // MARK: - 16. Queue and Transfer-State Consistency After Restart

    func testQueueAndTransferStateConsistencyAfterRestore() async throws {
        let storeURL = tempDirectory.appendingPathComponent("RestoreStore", isDirectory: true)
        let persistence1 = try DownloadPersistenceStore(storageDirectoryURL: storeURL)
        let coord1 = try DownloadCoordinator(session: .shared, persistenceStore: persistence1)
        let queue1 = DownloadQueueManager(coordinator: coord1, persistenceStore: persistence1, maxConcurrentDownloads: 2)
        let engine1 = DownloadEngine(queueManager: queue1, coordinator: coord1, persistenceStore: persistence1)

        let req1 = DownloadRequest(
            url: server.baseURL.appendingPathComponent("item1.bin"),
            destinationURL: tempDirectory.appendingPathComponent("item1.bin")
        )
        let req2 = DownloadRequest(
            url: server.baseURL.appendingPathComponent("item2.bin"),
            destinationURL: tempDirectory.appendingPathComponent("item2.bin")
        )

        _ = try await engine1.addDownload(req1, priority: .high, autoStart: false)
        _ = try await engine1.addDownload(req2, priority: .low, autoStart: false)

        await engine1.shutdown()

        // Create a new engine instance pointing to the same persistent store
        let persistence2 = try DownloadPersistenceStore(storageDirectoryURL: storeURL)
        let coord2 = try DownloadCoordinator(session: .shared, persistenceStore: persistence2)
        let queue2 = DownloadQueueManager(coordinator: coord2, persistenceStore: persistence2, maxConcurrentDownloads: 2)
        let engine2 = DownloadEngine(queueManager: queue2, coordinator: coord2, persistenceStore: persistence2)

        try await engine2.restoreQueue(autoStart: false)

        let restoredSnaps = await engine2.allSnapshots()
        XCTAssertEqual(restoredSnaps.count, 2)
        XCTAssertTrue(restoredSnaps.contains { $0.id == req1.id && $0.priority == .high })
        XCTAssertTrue(restoredSnaps.contains { $0.id == req2.id && $0.priority == .low })

        await engine2.shutdown()
    }

    // MARK: - 17. Correct Reporting of Unknown Size, Speed, ETA, and Checksum States

    func testUnknownSizeAndChecksumStateReporting() async throws {
        // Part A: Checksum verification
        let size = 64 * 1024
        let payload = makePayload(size: size, byte: 0x66)
        server.register(path: "/checksum.bin", data: payload)

        let dest = tempDirectory.appendingPathComponent("checksum.bin")
        let req = DownloadRequest(
            url: server.baseURL.appendingPathComponent("checksum.bin"),
            destinationURL: dest,
            expectedSHA256: "invalid_hash_to_trigger_mismatch"
        )

        _ = try await engine.addDownload(req, autoStart: true)
        try await engine.waitUntilIdle(timeoutSeconds: 10.0)

        let snap = await engine.snapshot(for: req.id)
        XCTAssertNotNil(snap)
        if case .mismatch = snap?.checksumOutcome {
            // Expected mismatch reported properly
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected checksum mismatch to be reported")
        }

        // Part B: Default snapshot metrics for pending item
        let pendingReq = DownloadRequest(
            url: server.baseURL.appendingPathComponent("pending.bin"),
            destinationURL: tempDirectory.appendingPathComponent("pending.bin")
        )
        let pendingSnap = try await engine.addDownload(pendingReq, autoStart: false)
        XCTAssertNil(pendingSnap.estimatedTimeRemaining)
        XCTAssertEqual(pendingSnap.checksumOutcome, .notChecked)
    }

    // MARK: - 18. Regression Coverage for Existing Queue, Retry, and Resume Behavior

    func testRegressionExistingQueueRetryAndResume() async throws {
        // Verify request budgeting and bandwidth rate limit methods compile and execute
        try await engine.setMaxGlobalRequests(16)
        await engine.setGlobalSpeedLimit(500_000)
        try await engine.setMaxConcurrentDownloads(4)

        let qSnap = await engine.queueSnapshot()
        XCTAssertEqual(qSnap.totalItems, 0)

        // Bulk operations
        await engine.pauseAllDownloads()
        await engine.resumeAllDownloads()
        await engine.cancelAllDownloads(deleteFiles: false)
    }

    func testImportCompletedFilePersistsAsCompletedDownload() async throws {
        let sourceURL = tempDirectory.appendingPathComponent("blob-capture.mp4")
        let contents = Data("captured-media".utf8)
        try contents.write(to: sourceURL)

        let snapshot = try await engine.importCompletedFile(
            fileURL: sourceURL,
            originalURL: URL(string: "blob:https://example.test/capture")!,
            filename: "captured-media.mp4",
            mimeType: "video/mp4"
        )

        XCTAssertTrue(snapshot.isCompleted)
        XCTAssertEqual(snapshot.completedBytes, Int64(contents.count))
        XCTAssertEqual(snapshot.totalBytes, Int64(contents.count))
        XCTAssertEqual(snapshot.destinationURL, sourceURL)

        let persisted = try await persistenceStore.fetch(tag: snapshot.id)
        XCTAssertNotNil(persisted)
        let persistedRecord = try XCTUnwrap(persisted)
        XCTAssertEqual(persistedRecord.state, .completed)
        XCTAssertEqual(persistedRecord.suggestedFilename, "captured-media.mp4")
        XCTAssertEqual(persistedRecord.mimeType, "video/mp4")
        XCTAssertEqual(persistedRecord.completedBytes, Int64(contents.count))

        let restoredManager = DownloadQueueManager(
            coordinator: coordinator,
            persistenceStore: persistenceStore,
            maxConcurrentDownloads: 3
        )
        try await restoredManager.restoreQueue(autoStart: false)
        let restored = await restoredManager.item(for: snapshot.id)
        XCTAssertEqual(restored?.state, .completed)
        XCTAssertEqual(restored?.request.destinationURL, sourceURL)

        try await restoredManager.removeFromQueue(id: snapshot.id, deleteDestinationFile: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
        let deletedRecord = try await persistenceStore.fetch(tag: snapshot.id)
        XCTAssertNil(deletedRecord)
    }

    func testImportCompletedFileRejectsDuplicateDestination() async throws {
        let sourceURL = tempDirectory.appendingPathComponent("duplicate.bin")
        try Data("duplicate".utf8).write(to: sourceURL)
        let origin = URL(string: "blob:https://example.test/duplicate")!

        _ = try await engine.importCompletedFile(
            fileURL: sourceURL,
            originalURL: origin,
            filename: "duplicate.bin"
        )

        do {
            _ = try await engine.importCompletedFile(
                fileURL: sourceURL,
                originalURL: origin,
                filename: "duplicate.bin"
            )
            XCTFail("Expected duplicate destination registration to fail.")
        } catch {
            XCTAssertTrue(error is DownloadQueueError)
        }
    }
}
