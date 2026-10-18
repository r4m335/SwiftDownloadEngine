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

/// Thread-safe test helper avoiding captured var mutations in Swift 6 concurrency mode.
private final class TestStateAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var order: [String] = []
    private var peakActive: Int = 0
    private var flag: Bool = false

    func recordCompletion(_ id: String) {
        lock.lock()
        defer { lock.unlock() }
        if !order.contains(id) {
            order.append(id)
        }
    }

    func getOrder() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return order
    }

    func updateActive(_ count: Int) {
        lock.lock()
        defer { lock.unlock() }
        if count > peakActive {
            peakActive = count
        }
    }

    func getPeakActive() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return peakActive
    }

    func setFlag(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        flag = value
    }

    func getFlag() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
}

final class DownloadQueueManagerTests: XCTestCase {
    private var server: LocalHTTPRangeServer!
    private var tempDirectory: URL!
    private var persistenceStore: DownloadPersistenceStore!
    private var coordinator: DownloadCoordinator!
    private var queueManager: DownloadQueueManager!

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
            .appendingPathComponent("1DM_Queue_Tests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let storeURL = tempDirectory.appendingPathComponent("Store", isDirectory: true)
        persistenceStore = try DownloadPersistenceStore(storageDirectoryURL: storeURL)
        coordinator = try DownloadCoordinator(session: .shared, persistenceStore: persistenceStore)
        queueManager = DownloadQueueManager(
            coordinator: coordinator,
            persistenceStore: persistenceStore,
            maxConcurrentDownloads: 3
        )
    }

    override func tearDown() async throws {
        if let queueManager {
            await queueManager.cancelAll(deleteDestinationFiles: false)
        }
        server?.stop()
        server = nil
        queueManager = nil
        coordinator = nil
        persistenceStore = nil
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try await super.tearDown()
    }

    // MARK: - Helper Data Generators

    private func makePayload(size: Int, seed: UInt8 = 0x5A) -> Data {
        var data = Data(count: size)
        data.withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for i in 0..<size {
                base[i] = UInt8(((i &* 31) &+ Int(seed)) & 0xFF)
            }
        }
        return data
    }

    private func makeRequest(id: String, path: String, configuredThreadCount: Int = 2) -> DownloadRequest {
        let destURL = tempDirectory.appendingPathComponent("\(id).bin")
        return DownloadRequest(
            id: id,
            url: server.url(for: path),
            destinationURL: destURL,
            configuredThreadCount: configuredThreadCount,
            reserveDiskBytes: 1024
        )
    }

    // MARK: - 1. FIFO Scheduling

    func test1_FIFOScheduling() async throws {
        try await queueManager.setMaxConcurrentDownloads(1)

        let size = 10 * 1024
        let p1 = makePayload(size: size, seed: 1)
        let p2 = makePayload(size: size, seed: 2)
        let p3 = makePayload(size: size, seed: 3)

        server.register(path: "/fifo1.bin", data: p1)
        server.register(path: "/fifo2.bin", data: p2)
        server.register(path: "/fifo3.bin", data: p3)

        let r1 = makeRequest(id: "fifo-1", path: "/fifo1.bin", configuredThreadCount: 1)
        let r2 = makeRequest(id: "fifo-2", path: "/fifo2.bin", configuredThreadCount: 1)
        let r3 = makeRequest(id: "fifo-3", path: "/fifo3.bin", configuredThreadCount: 1)

        let tracker = TestStateAccumulator()

        await queueManager.setQueueChangedHandler { snapshot in
            for item in snapshot.items where item.state == .completed {
                tracker.recordCompletion(item.id)
            }
        }

        try await queueManager.add(r1, priority: .normal)
        try await queueManager.add(r2, priority: .normal)
        try await queueManager.add(r3, priority: .normal)

        try await queueManager.waitUntilIdle(timeoutSeconds: 10.0)

        XCTAssertEqual(tracker.getOrder(), ["fifo-1", "fifo-2", "fifo-3"], "FIFO scheduling must process items in enqueued order")
    }

    // MARK: - 2. Maximum Concurrency of One

    func test2_MaximumConcurrencyOfOne() async throws {
        try await queueManager.setMaxConcurrentDownloads(1)

        let size = 30 * 1024
        for i in 1...3 {
            server.register(path: "/conc1_\(i).bin", data: makePayload(size: size, seed: UInt8(i)), chunkDelayMs: 3)
        }

        let r1 = makeRequest(id: "c1-1", path: "/conc1_1.bin")
        let r2 = makeRequest(id: "c1-2", path: "/conc1_2.bin")
        let r3 = makeRequest(id: "c1-3", path: "/conc1_3.bin")

        let tracker = TestStateAccumulator()

        await queueManager.setQueueChangedHandler { snap in
            tracker.updateActive(snap.activeCount)
        }

        try await queueManager.add([r1, r2, r3], priority: .normal)
        try await queueManager.waitUntilIdle(timeoutSeconds: 15.0)

        XCTAssertEqual(tracker.getPeakActive(), 1, "Concurrency of one must never exceed 1 active download")

        let snap = await queueManager.snapshot()
        XCTAssertEqual(snap.completedCount, 3)
    }

    // MARK: - 3. Maximum Concurrency of Three

    func test3_MaximumConcurrencyOfThree() async throws {
        try await queueManager.setMaxConcurrentDownloads(3)

        let size = 200 * 1024
        for i in 1...5 {
            server.register(path: "/conc3_\(i).bin", data: makePayload(size: size, seed: UInt8(i)), chunkDelayMs: 15)
        }

        let requests = (1...5).map { makeRequest(id: "c3-\($0)", path: "/conc3_\($0).bin") }
        try await queueManager.add(requests, priority: .normal, autoStart: true)

        // Wait until 3 downloads become actively running
        for _ in 0..<50 {
            let snap = await queueManager.snapshot()
            if snap.activeCount == 3 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        let initialSnap = await queueManager.snapshot()
        XCTAssertEqual(initialSnap.activeCount, 3, "Exactly 3 downloads should be active initially")
        XCTAssertEqual(initialSnap.queuedCount, 2, "Remaining 2 downloads should be queued")

        try await queueManager.waitUntilIdle(timeoutSeconds: 20.0)

        let finalSnap = await queueManager.snapshot()
        XCTAssertEqual(finalSnap.completedCount, 5)
        XCTAssertEqual(finalSnap.activeCount, 0)
    }

    // MARK: - 4. Queued Download Starts When Slot Becomes Available

    func test4_QueuedDownloadStartsWhenSlotBecomesAvailable() async throws {
        try await queueManager.setMaxConcurrentDownloads(2)

        let sizeFast = 10 * 1024
        let sizeSlow = 60 * 1024

        server.register(path: "/slot_fast.bin", data: makePayload(size: sizeFast, seed: 1), chunkDelayMs: 0)
        server.register(path: "/slot_slow.bin", data: makePayload(size: sizeSlow, seed: 2), chunkDelayMs: 4)
        server.register(path: "/slot_queued.bin", data: makePayload(size: sizeFast, seed: 3), chunkDelayMs: 0)

        let rFast = makeRequest(id: "slot-fast", path: "/slot_fast.bin")
        let rSlow = makeRequest(id: "slot-slow", path: "/slot_slow.bin")
        let rQueued = makeRequest(id: "slot-queued", path: "/slot_queued.bin")

        let tracker = TestStateAccumulator()

        await queueManager.setQueueChangedHandler { snap in
            if let item = snap.items.first(where: { $0.id == "slot-queued" }), item.state == .downloading {
                tracker.setFlag(true)
            }
        }

        try await queueManager.add([rFast, rSlow, rQueued], priority: .normal)

        try await queueManager.waitUntilIdle(timeoutSeconds: 15.0)

        XCTAssertTrue(tracker.getFlag(), "Queued download must start automatically when a slot becomes available")
    }

    // MARK: - 5. Concurrency Limit Is Never Exceeded

    func test5_ConcurrencyLimitNeverExceeded() async throws {
        let limit = 2
        try await queueManager.setMaxConcurrentDownloads(limit)

        let size = 30 * 1024
        for i in 1...6 {
            server.register(path: "/never_exceed_\(i).bin", data: makePayload(size: size, seed: UInt8(i)), chunkDelayMs: 3)
        }

        let tracker = TestStateAccumulator()

        await queueManager.setQueueChangedHandler { snap in
            tracker.updateActive(snap.activeCount)
        }

        let requests = (1...6).map { makeRequest(id: "limit-\($0)", path: "/never_exceed_\($0).bin") }
        try await queueManager.add(requests, priority: .normal)

        try await queueManager.waitUntilIdle(timeoutSeconds: 20.0)

        XCTAssertLessThanOrEqual(tracker.getPeakActive(), limit, "Active downloads must never exceed configured concurrency limit (\(limit)), got \(tracker.getPeakActive())")
    }

    // MARK: - 6. Priority Scheduling (High before Normal and Low)

    func test6_PriorityScheduling() async throws {
        try await queueManager.setMaxConcurrentDownloads(1)

        let size = 20 * 1024
        server.register(path: "/p_active.bin", data: makePayload(size: 30 * 1024, seed: 1), chunkDelayMs: 3)
        server.register(path: "/p_low.bin", data: makePayload(size: size, seed: 2))
        server.register(path: "/p_high.bin", data: makePayload(size: size, seed: 3))
        server.register(path: "/p_norm.bin", data: makePayload(size: size, seed: 4))

        let rActive = makeRequest(id: "p-active", path: "/p_active.bin")
        let rLow = makeRequest(id: "p-low", path: "/p_low.bin")
        let rHigh = makeRequest(id: "p-high", path: "/p_high.bin")
        let rNorm = makeRequest(id: "p-norm", path: "/p_norm.bin")

        let tracker = TestStateAccumulator()

        await queueManager.setQueueChangedHandler { snap in
            for item in snap.items where item.state == .completed {
                tracker.recordCompletion(item.id)
            }
        }

        // Start active download
        try await queueManager.add(rActive, priority: .normal)

        // While active is running, enqueue low, high, and normal
        try await queueManager.add(rLow, priority: .low)
        try await queueManager.add(rHigh, priority: .high)
        try await queueManager.add(rNorm, priority: .normal)

        try await queueManager.waitUntilIdle(timeoutSeconds: 15.0)

        XCTAssertEqual(tracker.getOrder(), ["p-active", "p-high", "p-norm", "p-low"], "High priority item must be scheduled before normal and low priority items")
    }

    // MARK: - 7. FIFO Order Within Equal Priorities

    func test7_FIFOOrderWithinEqualPriorities() async throws {
        try await queueManager.setMaxConcurrentDownloads(1)

        let size = 15 * 1024
        server.register(path: "/fifo_active.bin", data: makePayload(size: 25 * 1024, seed: 1), chunkDelayMs: 3)
        server.register(path: "/fifo_h1.bin", data: makePayload(size: size, seed: 2))
        server.register(path: "/fifo_h2.bin", data: makePayload(size: size, seed: 3))
        server.register(path: "/fifo_n1.bin", data: makePayload(size: size, seed: 4))

        let rActive = makeRequest(id: "eq-active", path: "/fifo_active.bin")
        let rH1 = makeRequest(id: "eq-h1", path: "/fifo_h1.bin")
        let rH2 = makeRequest(id: "eq-h2", path: "/fifo_h2.bin")
        let rN1 = makeRequest(id: "eq-n1", path: "/fifo_n1.bin")

        let tracker = TestStateAccumulator()

        await queueManager.setQueueChangedHandler { snap in
            for item in snap.items where item.state == .completed {
                tracker.recordCompletion(item.id)
            }
        }

        try await queueManager.add(rActive, priority: .normal)
        try await queueManager.add(rH1, priority: .high)
        try await queueManager.add(rH2, priority: .high)
        try await queueManager.add(rN1, priority: .normal)

        try await queueManager.waitUntilIdle(timeoutSeconds: 15.0)

        XCTAssertEqual(tracker.getOrder(), ["eq-active", "eq-h1", "eq-h2", "eq-n1"], "Deterministic FIFO order must be preserved within equal high priority items")
    }

    // MARK: - 8. Changing the Priority of a Queued Item

    func test8_ChangingPriorityOfQueuedItem() async throws {
        try await queueManager.setMaxConcurrentDownloads(1)

        let size = 20 * 1024
        server.register(path: "/chg_active.bin", data: makePayload(size: 30 * 1024, seed: 1), chunkDelayMs: 3)
        server.register(path: "/chg_norm.bin", data: makePayload(size: size, seed: 2))
        server.register(path: "/chg_low.bin", data: makePayload(size: size, seed: 3))

        let rActive = makeRequest(id: "chg-active", path: "/chg_active.bin")
        let rNorm = makeRequest(id: "chg-norm", path: "/chg_norm.bin")
        let rLow = makeRequest(id: "chg-low", path: "/chg_low.bin")

        let tracker = TestStateAccumulator()

        await queueManager.setQueueChangedHandler { snap in
            for item in snap.items where item.state == .completed {
                tracker.recordCompletion(item.id)
            }
        }

        try await queueManager.add(rActive, priority: .normal)
        try await queueManager.add(rNorm, priority: .normal)
        try await queueManager.add(rLow, priority: .low)

        // Elevate low priority item to high while active is running
        try await queueManager.updatePriority(id: "chg-low", priority: .high)

        try await queueManager.waitUntilIdle(timeoutSeconds: 15.0)

        XCTAssertEqual(tracker.getOrder(), ["chg-active", "chg-low", "chg-norm"], "Promoting queued item to high priority must reschedule it ahead of normal item")
    }

    // MARK: - 9. Pause One Download

    func test9_PauseOneDownload() async throws {
        try await queueManager.setMaxConcurrentDownloads(1)

        let size = 200 * 1024
        server.register(path: "/pause1_a.bin", data: makePayload(size: size, seed: 1), chunkDelayMs: 15)
        server.register(path: "/pause1_b.bin", data: makePayload(size: 10 * 1024, seed: 2), chunkDelayMs: 0)

        let rA = makeRequest(id: "pause-a", path: "/pause1_a.bin")
        let rB = makeRequest(id: "pause-b", path: "/pause1_b.bin")

        try await queueManager.add(rA, priority: .normal)
        try await queueManager.add(rB, priority: .normal)

        // Wait until rA is downloading
        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 20_000_000)
            if let item = await queueManager.item(for: "pause-a"), item.state == .downloading {
                break
            }
        }

        // Pause rA
        try await queueManager.pause(id: "pause-a")

        let itemA = await queueManager.item(for: "pause-a")
        XCTAssertEqual(itemA?.state, .paused, "Item A must transition to paused state")

        // Wait until rB completes in the freed slot
        for _ in 0..<100 {
            try await Task.sleep(nanoseconds: 20_000_000)
            if let itemB = await queueManager.item(for: "pause-b"), itemB.state == .completed {
                break
            }
        }

        let itemB = await queueManager.item(for: "pause-b")
        XCTAssertEqual(itemB?.state, .completed, "Item B must start and complete after Item A frees the concurrency slot")
    }

    // MARK: - 10. Pause All Active Downloads

    func test10_PauseAllActiveDownloads() async throws {
        try await queueManager.setMaxConcurrentDownloads(2)

        let size = 200 * 1024
        for i in 1...4 {
            server.register(path: "/pauseall_\(i).bin", data: makePayload(size: size, seed: UInt8(i)), chunkDelayMs: 15)
        }

        let requests = (1...4).map { makeRequest(id: "pa-\($0)", path: "/pauseall_\($0).bin") }
        try await queueManager.add(requests, priority: .normal)

        for _ in 0..<50 {
            let snap = await queueManager.snapshot()
            if snap.activeCount == 2 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        // Pause all
        await queueManager.pauseAll()

        let snap = await queueManager.snapshot()
        XCTAssertEqual(snap.activeCount, 0, "No downloads should remain active after pauseAll")
        XCTAssertEqual(snap.pausedCount, 4, "All active and queued downloads should be paused")
    }

    // MARK: - 11. Resume Eligible Paused Downloads

    func test11_ResumeEligiblePausedDownloads() async throws {
        try await queueManager.setMaxConcurrentDownloads(2)

        let size = 100 * 1024
        for i in 1...3 {
            server.register(path: "/resall_\(i).bin", data: makePayload(size: size, seed: UInt8(i)), chunkDelayMs: 10)
        }

        let requests = (1...3).map { makeRequest(id: "res-\($0)", path: "/resall_\($0).bin") }
        try await queueManager.add(requests, priority: .normal, autoStart: false)
        await queueManager.pauseAll()

        let pausedSnap = await queueManager.snapshot()
        XCTAssertEqual(pausedSnap.pausedCount, 3)

        // Resume all
        await queueManager.resumeAll()

        for _ in 0..<50 {
            let snap = await queueManager.snapshot()
            if snap.activeCount == 2 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        let activeSnap = await queueManager.snapshot()
        XCTAssertEqual(activeSnap.activeCount, 2, "Resumed downloads should occupy active slots up to limit 2")

        try await queueManager.waitUntilIdle(timeoutSeconds: 15.0)

        let finalSnap = await queueManager.snapshot()
        XCTAssertEqual(finalSnap.completedCount, 3)
    }

    // MARK: - 12. Cancel One Queued Download

    func test12_CancelOneQueuedDownload() async throws {
        try await queueManager.setMaxConcurrentDownloads(1)

        let size = 30 * 1024
        server.register(path: "/cq_active.bin", data: makePayload(size: size, seed: 1), chunkDelayMs: 3)
        server.register(path: "/cq_queued.bin", data: makePayload(size: size, seed: 2), chunkDelayMs: 0)

        let rActive = makeRequest(id: "cq-active", path: "/cq_active.bin")
        let rQueued = makeRequest(id: "cq-queued", path: "/cq_queued.bin")

        try await queueManager.add(rActive, priority: .normal)
        try await queueManager.add(rQueued, priority: .normal)

        // Cancel the queued item
        try await queueManager.cancel(id: "cq-queued")

        let queuedItem = await queueManager.item(for: "cq-queued")
        XCTAssertEqual(queuedItem?.state, .cancelled, "Queued item must transition to cancelled state")

        try await queueManager.waitUntilIdle(timeoutSeconds: 15.0)

        let activeItem = await queueManager.item(for: "cq-active")
        XCTAssertEqual(activeItem?.state, .completed)

        let finalQueued = await queueManager.item(for: "cq-queued")
        XCTAssertEqual(finalQueued?.state, .cancelled, "Cancelled queued item must not be executed")
    }

    // MARK: - 13. Cancel One Active Download

    func test13_CancelOneActiveDownload() async throws {
        try await queueManager.setMaxConcurrentDownloads(1)

        let size = 40 * 1024
        server.register(path: "/ca_active.bin", data: makePayload(size: size, seed: 1), chunkDelayMs: 4)
        server.register(path: "/ca_queued.bin", data: makePayload(size: 10 * 1024, seed: 2), chunkDelayMs: 0)

        let rActive = makeRequest(id: "ca-active", path: "/ca_active.bin")
        let rQueued = makeRequest(id: "ca-queued", path: "/ca_queued.bin")

        try await queueManager.add(rActive, priority: .normal)
        try await queueManager.add(rQueued, priority: .normal)

        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 20_000_000)
            if let item = await queueManager.item(for: "ca-active"), item.state == .downloading {
                break
            }
        }

        // Cancel active item
        try await queueManager.cancel(id: "ca-active")

        let activeItem = await queueManager.item(for: "ca-active")
        XCTAssertEqual(activeItem?.state, .cancelled, "Active item must transition to cancelled state")

        // Queued item should start and complete
        for _ in 0..<100 {
            try await Task.sleep(nanoseconds: 20_000_000)
            if let item = await queueManager.item(for: "ca-queued"), item.state == .completed {
                break
            }
        }

        let queuedItem = await queueManager.item(for: "ca-queued")
        XCTAssertEqual(queuedItem?.state, .completed, "Queued item must automatically start and finish after active cancellation")
    }

    // MARK: - 14. Cancel All Eligible Downloads

    func test14_CancelAllEligibleDownloads() async throws {
        try await queueManager.setMaxConcurrentDownloads(2)

        let size = 300 * 1024
        for i in 1...4 {
            server.register(path: "/cancelall_\(i).bin", data: makePayload(size: size, seed: UInt8(i)), chunkDelayMs: 25)
        }

        let requests = (1...4).map { makeRequest(id: "call-\($0)", path: "/cancelall_\($0).bin") }
        try await queueManager.add(requests, priority: .normal)

        for _ in 0..<50 {
            let snap = await queueManager.snapshot()
            if snap.activeCount == 2 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        await queueManager.cancelAll()

        let snap = await queueManager.snapshot()
        XCTAssertEqual(snap.activeCount, 0, "No active downloads should remain after cancelAll")
        XCTAssertEqual(snap.cancelledCount, 4, "All non-completed downloads must be cancelled")
    }

    // MARK: - 15. Retry a Failed Download

    func test15_RetryFailedDownload() async throws {
        try await queueManager.setMaxConcurrentDownloads(1)

        let path = "/retry_test.bin"
        server.failNextRequests(path: path, count: 5, statusCode: 500)

        let r = makeRequest(id: "retry-1", path: path)
        try await queueManager.add(r, priority: .normal)

        // Wait until it fails
        for _ in 0..<100 {
            try await Task.sleep(nanoseconds: 20_000_000)
            if let item = await queueManager.item(for: "retry-1") {
                if case .failed = item.state { break }
            }
        }

        let failedItem = await queueManager.item(for: "retry-1")
        guard case .failed = failedItem?.state else {
            XCTFail("Item should be in failed state")
            return
        }

        // Clear transient failures on server and register valid payload
        server.failNextRequests(path: path, count: 0)
        let payload = makePayload(size: 15 * 1024, seed: 99)
        server.register(path: path, data: payload)

        // Retry failed download
        try await queueManager.retry(id: "retry-1")

        try await queueManager.waitUntilIdle(timeoutSeconds: 10.0)

        let finalItem = await queueManager.item(for: "retry-1")
        XCTAssertEqual(finalItem?.state, .completed, "Retried download must complete successfully")
    }

    // MARK: - 16. Restore Queued Items After Restarting Queue Manager

    func test16_RestoreQueuedItemsAfterRestartingQueueManager() async throws {
        let manifestURL = tempDirectory.appendingPathComponent("restart_queue_manifest.json")
        let mgr1 = DownloadQueueManager(
            coordinator: coordinator,
            persistenceStore: persistenceStore,
            queueStoreURL: manifestURL,
            maxConcurrentDownloads: 2
        )

        let r1 = makeRequest(id: "rest-1", path: "/rest1.bin")
        let r2 = makeRequest(id: "rest-2", path: "/rest2.bin")

        try await mgr1.add(r1, priority: .high, autoStart: false)
        try await mgr1.add(r2, priority: .normal, autoStart: false)

        // Instantiate new queue manager pointing to exact same storage
        let mgr2 = DownloadQueueManager(
            coordinator: coordinator,
            persistenceStore: persistenceStore,
            queueStoreURL: manifestURL,
            maxConcurrentDownloads: 2
        )
        try await mgr2.restoreQueue(autoStart: false)

        let snap2 = await mgr2.snapshot()
        XCTAssertEqual(snap2.totalItems, 2)
        XCTAssertEqual(snap2.queuedCount, 2)

        let item1 = await mgr2.item(for: "rest-1")
        let item2 = await mgr2.item(for: "rest-2")

        XCTAssertEqual(item1?.priority, .high)
        XCTAssertEqual(item2?.priority, .normal)
        XCTAssertEqual(item1?.state, .pending)
        XCTAssertEqual(item2?.state, .pending)
    }

    // MARK: - 17. Restore Interrupted Downloads Safely

    func test17_RestoreInterruptedDownloadsSafely() async throws {
        let manifestURL = tempDirectory.appendingPathComponent("interrupted_manifest.json")
        let size = 60 * 1024
        let payload = makePayload(size: size, seed: 42)
        let expectedSHA = EngineSHA256.hash(data: payload)
        server.register(path: "/interrupted.bin", data: payload, chunkDelayMs: 4)

        let r = makeRequest(id: "interrupted-dl", path: "/interrupted.bin")

        let mgr1 = DownloadQueueManager(
            coordinator: coordinator,
            persistenceStore: persistenceStore,
            queueStoreURL: manifestURL,
            maxConcurrentDownloads: 1
        )
        try await mgr1.add(r, priority: .normal)

        // Wait for partial progress
        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 20_000_000)
            if let prog = await coordinator.currentProgress(for: "interrupted-dl"), prog.bytesReceived > 0 {
                break
            }
        }

        // Simulate crash: stop coordinator task and don't cleanly complete mgr1
        try await coordinator.pause(id: "interrupted-dl")

        // New queue manager starts up after crash
        let coord2 = try DownloadCoordinator(session: .shared, persistenceStore: persistenceStore)
        let mgr2 = DownloadQueueManager(
            coordinator: coord2,
            persistenceStore: persistenceStore,
            queueStoreURL: manifestURL,
            maxConcurrentDownloads: 1
        )

        try await mgr2.restoreQueue(autoStart: true)
        try await mgr2.waitUntilIdle(timeoutSeconds: 20.0)

        let finalItem = await mgr2.item(for: "interrupted-dl")
        XCTAssertEqual(finalItem?.state, .completed, "Interrupted download must resume and complete")

        let downloadedData = try Data(contentsOf: r.destinationURL)
        let actualSHA = EngineSHA256.hash(data: downloadedData)
        XCTAssertEqual(actualSHA, expectedSHA, "Recovered download checksum must match original payload")
    }

    // MARK: - 18. Do Not Automatically Restart Completed Downloads

    func test18_DoNotAutomaticallyRestartCompletedDownloads() async throws {
        let manifestURL = tempDirectory.appendingPathComponent("no_restart_manifest.json")
        let payload = makePayload(size: 10 * 1024, seed: 77)
        server.register(path: "/already_done.bin", data: payload)

        let r = makeRequest(id: "already-done", path: "/already_done.bin")

        let mgr1 = DownloadQueueManager(
            coordinator: coordinator,
            persistenceStore: persistenceStore,
            queueStoreURL: manifestURL,
            maxConcurrentDownloads: 1
        )
        try await mgr1.add(r, priority: .normal)
        try await mgr1.waitUntilIdle(timeoutSeconds: 10.0)

        let snap1 = await mgr1.snapshot()
        XCTAssertEqual(snap1.completedCount, 1)

        // New queue manager restores with autoStart: true
        let mgr2 = DownloadQueueManager(
            coordinator: coordinator,
            persistenceStore: persistenceStore,
            queueStoreURL: manifestURL,
            maxConcurrentDownloads: 1
        )
        try await mgr2.restoreQueue(autoStart: true)

        let snap2 = await mgr2.snapshot()
        XCTAssertEqual(snap2.activeCount, 0, "Completed download must not be restarted")
        XCTAssertEqual(snap2.completedCount, 1)
    }

    // MARK: - 19. Do Not Automatically Restart Explicitly Cancelled Downloads

    func test19_DoNotAutomaticallyRestartExplicitlyCancelledDownloads() async throws {
        let manifestURL = tempDirectory.appendingPathComponent("no_restart_cancelled.json")
        let r = makeRequest(id: "cancel-saved", path: "/dummy.bin")

        let mgr1 = DownloadQueueManager(
            coordinator: coordinator,
            persistenceStore: persistenceStore,
            queueStoreURL: manifestURL,
            maxConcurrentDownloads: 1
        )
        try await mgr1.add(r, priority: .normal, autoStart: false)
        try await mgr1.cancel(id: "cancel-saved")

        let item1 = await mgr1.item(for: "cancel-saved")
        XCTAssertEqual(item1?.state, .cancelled)

        // Restart queue manager with autoStart: true
        let mgr2 = DownloadQueueManager(
            coordinator: coordinator,
            persistenceStore: persistenceStore,
            queueStoreURL: manifestURL,
            maxConcurrentDownloads: 1
        )
        try await mgr2.restoreQueue(autoStart: true)

        let snap2 = await mgr2.snapshot()
        XCTAssertEqual(snap2.activeCount, 0, "Cancelled download must not be restarted automatically")
        XCTAssertEqual(snap2.cancelledCount, 1)
    }

    // MARK: - 20. Changing Concurrency While Downloads Are Active

    func test20_ChangingConcurrencyWhileDownloadsAreActive() async throws {
        try await queueManager.setMaxConcurrentDownloads(1)

        let size = 40 * 1024
        for i in 1...4 {
            server.register(path: "/chg_conc_\(i).bin", data: makePayload(size: size, seed: UInt8(i)), chunkDelayMs: 4)
        }

        let requests = (1...4).map { makeRequest(id: "chg-c-\($0)", path: "/chg_conc_\($0).bin") }
        try await queueManager.add(requests, priority: .normal)

        // Wait until download 1 is active
        try await Task.sleep(nanoseconds: 30_000_000)
        let initialSnap = await queueManager.snapshot()
        XCTAssertEqual(initialSnap.activeCount, 1)

        // Increase limit to 3 -> 2 additional downloads should start immediately
        try await queueManager.setMaxConcurrentDownloads(3)
        try await Task.sleep(nanoseconds: 30_000_000)

        let increasedSnap = await queueManager.snapshot()
        XCTAssertEqual(increasedSnap.activeCount, 3, "Increasing concurrency must immediately schedule queued items up to new limit")

        // Decrease limit to 1 -> Active downloads should not be cancelled, but drain gracefully
        try await queueManager.setMaxConcurrentDownloads(1)

        try await queueManager.waitUntilIdle(timeoutSeconds: 20.0)

        let finalSnap = await queueManager.snapshot()
        XCTAssertEqual(finalSnap.completedCount, 4, "All downloads must complete successfully despite dynamic concurrency changes")
    }

    // MARK: - 21. Multiple Simultaneous Completion Events

    func test21_MultipleSimultaneousCompletionEvents() async throws {
        try await queueManager.setMaxConcurrentDownloads(4)

        let size = 8 * 1024
        for i in 1...4 {
            server.register(path: "/sim_comp_\(i).bin", data: makePayload(size: size, seed: UInt8(i)), chunkDelayMs: 0)
        }

        let requests = (1...4).map { makeRequest(id: "sim-c-\($0)", path: "/sim_comp_\($0).bin") }
        try await queueManager.add(requests, priority: .normal)

        try await queueManager.waitUntilIdle(timeoutSeconds: 15.0)

        let snap = await queueManager.snapshot()
        XCTAssertEqual(snap.completedCount, 4, "All simultaneous completions must be captured accurately")
        XCTAssertEqual(snap.activeCount, 0)
        let isIdle = await queueManager.isIdle
        XCTAssertTrue(isIdle)
    }

    // MARK: - 22. Multiple Simultaneous Failure Events

    func test22_MultipleSimultaneousFailureEvents() async throws {
        try await queueManager.setMaxConcurrentDownloads(3)

        for i in 1...3 {
            server.failNextRequests(path: "/sim_fail_\(i).bin", count: 10, statusCode: 503)
        }

        let requests = (1...3).map { makeRequest(id: "sim-f-\($0)", path: "/sim_fail_\($0).bin") }
        try await queueManager.add(requests, priority: .normal)

        // Wait until all 3 fail
        for _ in 0..<100 {
            try await Task.sleep(nanoseconds: 20_000_000)
            let snap = await queueManager.snapshot()
            if snap.failedCount == 3 { break }
        }

        let snap = await queueManager.snapshot()
        XCTAssertEqual(snap.failedCount, 3, "Simultaneous failures must all transition cleanly to failed state")
        XCTAssertEqual(snap.activeCount, 0, "Slots must be completely released after failures")
    }

    // MARK: - 23. Repeated Restoration Does Not Duplicate Queue Items

    func test23_RepeatedRestorationDoesNotDuplicateQueueItems() async throws {
        let manifestURL = tempDirectory.appendingPathComponent("dedup_manifest.json")
        let mgr1 = DownloadQueueManager(
            coordinator: coordinator,
            persistenceStore: persistenceStore,
            queueStoreURL: manifestURL,
            maxConcurrentDownloads: 2
        )

        let r1 = makeRequest(id: "dup-1", path: "/dup1.bin")
        let r2 = makeRequest(id: "dup-2", path: "/dup2.bin")

        try await mgr1.add(r1, priority: .high, autoStart: false)
        try await mgr1.add(r2, priority: .normal, autoStart: false)

        let mgr2 = DownloadQueueManager(
            coordinator: coordinator,
            persistenceStore: persistenceStore,
            queueStoreURL: manifestURL,
            maxConcurrentDownloads: 2
        )

        // Call restoreQueue three times in a row
        try await mgr2.restoreQueue(autoStart: false)
        try await mgr2.restoreQueue(autoStart: false)
        try await mgr2.restoreQueue(autoStart: false)

        let allItems = await mgr2.allItems()
        XCTAssertEqual(allItems.count, 2, "Repeated restoreQueue calls must never duplicate items")
    }

    // MARK: - 24. Removing a Queue Record Does Not Delete Its Downloaded File

    func test24_RemovingQueueRecordDoesNotDeleteFile() async throws {
        try await queueManager.setMaxConcurrentDownloads(1)

        let payload = makePayload(size: 12 * 1024, seed: 88)
        let expectedSHA = EngineSHA256.hash(data: payload)
        server.register(path: "/rm_keep_file.bin", data: payload)

        let r = makeRequest(id: "rm-keep", path: "/rm_keep_file.bin")
        try await queueManager.add(r, priority: .normal)
        try await queueManager.waitUntilIdle(timeoutSeconds: 10.0)

        XCTAssertTrue(FileManager.default.fileExists(atPath: r.destinationURL.path))

        // Remove queue record with deleteDestinationFile: false (default)
        try await queueManager.removeFromQueue(id: "rm-keep", deleteDestinationFile: false)

        let item = await queueManager.item(for: "rm-keep")
        XCTAssertNil(item, "Queue record should be removed from queue")

        XCTAssertTrue(FileManager.default.fileExists(atPath: r.destinationURL.path), "Downloaded file must remain intact when removing queue record")
        let dataOnDisk = try Data(contentsOf: r.destinationURL)
        XCTAssertEqual(EngineSHA256.hash(data: dataOnDisk), expectedSHA)
    }

    // MARK: - 25. Queue Persistence Survives a Process Restart

    func test25_QueuePersistenceSurvivesProcessRestart() async throws {
        let manifestURL = tempDirectory.appendingPathComponent("process_restart_manifest.json")
        let r1 = makeRequest(id: "proc-1", path: "/proc1.bin")
        let r2 = makeRequest(id: "proc-2", path: "/proc2.bin")
        let r3 = makeRequest(id: "proc-3", path: "/proc3.bin")

        do {
            let mgr = DownloadQueueManager(
                coordinator: coordinator,
                persistenceStore: persistenceStore,
                queueStoreURL: manifestURL,
                maxConcurrentDownloads: 2
            )
            try await mgr.add(r1, priority: .low, autoStart: false)
            try await mgr.add(r2, priority: .high, autoStart: false)
            try await mgr.add(r3, priority: .normal, autoStart: false)
        }

        // Verify the raw JSON manifest exists on disk and is readable
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path))
        let rawData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(QueueManifest.self, from: rawData)
        XCTAssertEqual(manifest.maxConcurrentDownloads, 2)
        XCTAssertEqual(manifest.items.count, 3)

        // Instantiate fresh manager simulating process relaunch
        let freshManager = DownloadQueueManager(
            coordinator: coordinator,
            persistenceStore: persistenceStore,
            queueStoreURL: manifestURL,
            maxConcurrentDownloads: 2
        )
        try await freshManager.restoreQueue(autoStart: false)

        let items = await freshManager.allItems()
        XCTAssertEqual(items.count, 3)
        // High priority should be first in sorted allItems()
        XCTAssertEqual(items[0].id, "proc-2")
        XCTAssertEqual(items[0].priority, .high)
        XCTAssertEqual(items[1].id, "proc-3")
        XCTAssertEqual(items[1].priority, .normal)
        XCTAssertEqual(items[2].id, "proc-1")
        XCTAssertEqual(items[2].priority, .low)
    }
}
