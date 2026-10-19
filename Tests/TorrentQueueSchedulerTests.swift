import XCTest
import Foundation
@testable import DM_Reverse_engineering

final class TorrentQueueSchedulerTests: XCTestCase {
    var tempDirectoryURL: URL!
    var store: TorrentPersistenceStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TorrentQueueSchedulerTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        store = try TorrentPersistenceStore(storageDirectoryURL: tempDirectoryURL)
    }

    override func tearDownWithError() throws {
        if let dir = tempDirectoryURL {
            try? FileManager.default.removeItem(at: dir)
        }
        try super.tearDownWithError()
    }

    func testPriorityOrdering() async throws {
        let scheduler = try await TorrentQueueScheduler(persistenceStore: store, maxConcurrentTorrents: 1)

        let hashLow = "1111111111111111111111111111111111111111"
        let hashNormal = "2222222222222222222222222222222222222222"
        let hashHigh = "3333333333333333333333333333333333333333"

        // Enqueue low priority first
        _ = try await scheduler.enqueue(
            infoHash: hashLow,
            source: "magnet:?xt=urn:btih:\(hashLow)",
            name: "LowItem",
            savePath: tempDirectoryURL,
            priority: .low
        )

        // hashLow gets admitted since capacity was 1
        let recLow = await scheduler.record(for: hashLow)
        XCTAssertEqual(recLow?.state, .downloading)

        // Enqueue normal and high
        _ = try await scheduler.enqueue(
            infoHash: hashNormal,
            source: "magnet:?xt=urn:btih:\(hashNormal)",
            name: "NormalItem",
            savePath: tempDirectoryURL,
            priority: .normal
        )
        _ = try await scheduler.enqueue(
            infoHash: hashHigh,
            source: "magnet:?xt=urn:btih:\(hashHigh)",
            name: "HighItem",
            savePath: tempDirectoryURL,
            priority: .high
        )

        // Low finished
        _ = try await scheduler.updateProgress(
            infoHash: hashLow,
            progress: TorrentProgress(progressFraction: 1.0),
            state: .finished
        )

        // High priority must be promoted ahead of normal!
        let recHigh = await scheduler.record(for: hashHigh)
        let recNormal = await scheduler.record(for: hashNormal)

        XCTAssertEqual(recHigh?.state, .downloading)
        XCTAssertEqual(recNormal?.state, .queued)
    }

    func testFIFOTieBreaking() async throws {
        let scheduler = try await TorrentQueueScheduler(persistenceStore: store, maxConcurrentTorrents: 1)

        let hash1 = "aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111"
        let hash2 = "bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222"
        let hash3 = "cccc3333cccc3333cccc3333cccc3333cccc3333"

        _ = try await scheduler.enqueue(infoHash: hash1, source: "source1", name: "Item1", savePath: tempDirectoryURL, priority: .normal)
        _ = try await scheduler.enqueue(infoHash: hash2, source: "source2", name: "Item2", savePath: tempDirectoryURL, priority: .normal)
        _ = try await scheduler.enqueue(infoHash: hash3, source: "source3", name: "Item3", savePath: tempDirectoryURL, priority: .normal)

        // hash1 is downloading, hash2 and hash3 are queued
        let rec1 = await scheduler.record(for: hash1)
        let rec2 = await scheduler.record(for: hash2)
        let rec3 = await scheduler.record(for: hash3)

        XCTAssertEqual(rec1?.state, .downloading)
        XCTAssertEqual(rec2?.state, .queued)
        XCTAssertEqual(rec3?.state, .queued)

        // When hash1 finishes, hash2 (earlier FIFO sequence) must be promoted before hash3
        _ = try await scheduler.updateProgress(infoHash: hash1, progress: TorrentProgress(), state: .finished)

        let rec2After = await scheduler.record(for: hash2)
        let rec3After = await scheduler.record(for: hash3)

        XCTAssertEqual(rec2After?.state, .downloading)
        XCTAssertEqual(rec3After?.state, .queued)
    }

    func testConcurrencyLimitEnforcement() async throws {
        let scheduler = try await TorrentQueueScheduler(persistenceStore: store, maxConcurrentTorrents: 2)

        for i in 1...5 {
            let hash = String(repeating: "\(i)", count: 40)
            _ = try await scheduler.enqueue(
                infoHash: hash,
                source: "source_\(i)",
                name: "Item_\(i)",
                savePath: tempDirectoryURL
            )
        }

        let snap = await scheduler.snapshot()
        XCTAssertEqual(snap.totalTorrents, 5)
        XCTAssertEqual(snap.activeCount, 2)
        XCTAssertEqual(snap.queuedCount, 3)
    }

    func testDynamicConcurrencyLimitChanges() async throws {
        let scheduler = try await TorrentQueueScheduler(persistenceStore: store, maxConcurrentTorrents: 2)

        for i in 1...4 {
            let hash = String(repeating: "\(i)", count: 40)
            _ = try await scheduler.enqueue(infoHash: hash, source: "src", name: "item", savePath: tempDirectoryURL)
        }

        var snap = await scheduler.snapshot()
        XCTAssertEqual(snap.activeCount, 2)

        // Expand limit to 4
        let expanded = try await scheduler.setMaxConcurrentTorrents(4)
        XCTAssertEqual(expanded.promoted.count, 2)
        snap = await scheduler.snapshot()
        XCTAssertEqual(snap.activeCount, 4)
        XCTAssertEqual(snap.queuedCount, 0)

        // Shrink limit to 1
        let shrunk = try await scheduler.setMaxConcurrentTorrents(1)
        XCTAssertEqual(shrunk.demoted.count, 3)
        snap = await scheduler.snapshot()
        XCTAssertEqual(snap.activeCount, 1)
        XCTAssertEqual(snap.queuedCount, 3)
    }

    func testExplicitPauseSurvivesQueuePumps() async throws {
        let scheduler = try await TorrentQueueScheduler(persistenceStore: store, maxConcurrentTorrents: 2)

        let hash1 = "1111111111111111111111111111111111111111"
        let hash2 = "2222222222222222222222222222222222222222"

        _ = try await scheduler.enqueue(infoHash: hash1, source: "src1", name: "Item1", savePath: tempDirectoryURL)
        _ = try await scheduler.enqueue(infoHash: hash2, source: "src2", name: "Item2", savePath: tempDirectoryURL)

        // Pause hash1 explicitly
        _ = try await scheduler.pause(infoHash: hash1)
        var rec1 = await scheduler.record(for: hash1)
        XCTAssertEqual(rec1?.state, .paused)
        XCTAssertEqual(rec1?.isExplicitlyPaused, true)

        // Call pumpQueue - hash1 must NOT be promoted despite available slots!
        let pumpResult = await scheduler.pumpQueue()
        XCTAssertFalse(pumpResult.promoted.contains(hash1))

        rec1 = await scheduler.record(for: hash1)
        XCTAssertEqual(rec1?.state, .paused)
        XCTAssertEqual(rec1?.isExplicitlyPaused, true)
    }

    func testRemovePromotesNextQueued() async throws {
        let scheduler = try await TorrentQueueScheduler(persistenceStore: store, maxConcurrentTorrents: 1)

        let hash1 = "1111111111111111111111111111111111111111"
        let hash2 = "2222222222222222222222222222222222222222"

        _ = try await scheduler.enqueue(infoHash: hash1, source: "src1", name: "Item1", savePath: tempDirectoryURL)
        _ = try await scheduler.enqueue(infoHash: hash2, source: "src2", name: "Item2", savePath: tempDirectoryURL)

        let rec1 = await scheduler.record(for: hash1)
        let rec2 = await scheduler.record(for: hash2)
        XCTAssertEqual(rec1?.state, .downloading)
        XCTAssertEqual(rec2?.state, .queued)

        // Removing active hash1 promotes queued hash2
        let changes = try await scheduler.remove(infoHash: hash1)
        XCTAssertEqual(changes.promoted, [hash2])

        let rec1After = await scheduler.record(for: hash1)
        let rec2After = await scheduler.record(for: hash2)
        XCTAssertNil(rec1After)
        XCTAssertEqual(rec2After?.state, .downloading)
    }

    func testDuplicateInfoHashRejection() async throws {
        let scheduler = try await TorrentQueueScheduler(persistenceStore: store, maxConcurrentTorrents: 2)
        let hash = "1234567890123456789012345678901234567890"

        _ = try await scheduler.enqueue(infoHash: hash, source: "src", name: "Item", savePath: tempDirectoryURL)

        do {
            _ = try await scheduler.enqueue(infoHash: hash, source: "src", name: "Item", savePath: tempDirectoryURL)
            XCTFail("Duplicate infoHash should throw duplicateTorrent")
        } catch let error as TorrentEngineError {
            XCTAssertEqual(error, .duplicateTorrent(hash))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFilePrioritiesUpdatingAndPersistence() async throws {
        let scheduler = try await TorrentQueueScheduler(persistenceStore: store, maxConcurrentTorrents: 2)
        let hash = "ffff1111ffff1111ffff1111ffff1111ffff1111"

        _ = try await scheduler.enqueue(infoHash: hash, source: "src", name: "MultiItem", savePath: tempDirectoryURL)

        try await scheduler.setFilePriorities([0: .doNotDownload, 1: .high], for: hash)

        let record = await scheduler.record(for: hash)
        XCTAssertEqual(record?.filePriorities?[0], .doNotDownload)
        XCTAssertEqual(record?.filePriorities?[1], .high)

        // Verify stored in persistence
        let freshStoreRecord = await store.loadRecord(infoHash: hash)
        XCTAssertEqual(freshStoreRecord?.filePriorities?[0], .doNotDownload)
        XCTAssertEqual(freshStoreRecord?.filePriorities?[1], .high)
    }

    func testSeedingPolicyCalculation() async throws {
        let scheduler = try await TorrentQueueScheduler(persistenceStore: store, maxConcurrentTorrents: 2)
        let hash = "eeee2222eeee2222eeee2222eeee2222eeee2222"

        _ = try await scheduler.enqueue(infoHash: hash, source: "src", name: "SeedingItem", savePath: tempDirectoryURL)

        // 1. Ratio-based policy
        try await scheduler.setSeedingPreference(SeedingPreference(mode: .ratio, targetRatio: 1.5), for: hash)
        // Ratio < 1.5: should not stop
        var stop = await scheduler.shouldStopSeeding(infoHash: hash, totalUploaded: 1400, totalDownloaded: 1000, elapsedSeedingSeconds: 60)
        XCTAssertFalse(stop)
        // Ratio >= 1.5: should stop
        stop = await scheduler.shouldStopSeeding(infoHash: hash, totalUploaded: 1500, totalDownloaded: 1000, elapsedSeedingSeconds: 60)
        XCTAssertTrue(stop)

        // 2. Duration-based policy
        try await scheduler.setSeedingPreference(SeedingPreference(mode: .duration, targetDurationSeconds: 1800), for: hash)
        // Elapsed < 1800s: should not stop
        stop = await scheduler.shouldStopSeeding(infoHash: hash, totalUploaded: 500, totalDownloaded: 1000, elapsedSeedingSeconds: 1200)
        XCTAssertFalse(stop)
        // Elapsed >= 1800s: should stop
        stop = await scheduler.shouldStopSeeding(infoHash: hash, totalUploaded: 500, totalDownloaded: 1000, elapsedSeedingSeconds: 1800)
        XCTAssertTrue(stop)

        // 3. Do not seed policy: stop immediately
        try await scheduler.setSeedingPreference(SeedingPreference(mode: .doNotSeed), for: hash)
        stop = await scheduler.shouldStopSeeding(infoHash: hash, totalUploaded: 0, totalDownloaded: 1000, elapsedSeedingSeconds: 0)
        XCTAssertTrue(stop)

        // 4. Indefinite policy: never stop automatically
        try await scheduler.setSeedingPreference(SeedingPreference(mode: .indefinitely), for: hash)
        stop = await scheduler.shouldStopSeeding(infoHash: hash, totalUploaded: 999999, totalDownloaded: 1000, elapsedSeedingSeconds: 999999)
        XCTAssertFalse(stop)
    }
}
