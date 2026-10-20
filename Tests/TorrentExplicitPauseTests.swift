import XCTest
import Foundation
@testable import DM_Reverse_engineering

/// Milestone 6.2 Regression Suite: Verifies that an explicit user pause on a BitTorrent transfer
/// is an absolute invariant and NEVER automatically resumes across:
/// 1. Scheduler queue pumps & promotions (Test A & B)
/// 2. Concurrent transfers and priority modifications (Test B)
/// 3. Engine stop / restart & crash recovery (Test C)
/// 4. High-frequency status polling & snapshot reconciliation (Test D)
/// 5. Explicit user resume gating & capacity admission (Test E)
/// 6. Background suspension & foreground lifecycle restoration (Test F)
final class TorrentExplicitPauseTests: XCTestCase {
    var tempDirectoryURL: URL!
    var engineStorageURL: URL!
    var persistenceStore: TorrentPersistenceStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TorrentExplicitPauseTests_\(UUID().uuidString)", isDirectory: true)
        engineStorageURL = tempDirectoryURL.appendingPathComponent("EngineStorage", isDirectory: true)
        try FileManager.default.createDirectory(at: engineStorageURL, withIntermediateDirectories: true)
        persistenceStore = try TorrentPersistenceStore(storageDirectoryURL: tempDirectoryURL.appendingPathComponent("Metadata", isDirectory: true))
    }

    override func tearDownWithError() throws {
        if let dir = tempDirectoryURL {
            try? FileManager.default.removeItem(at: dir)
        }
        try super.tearDownWithError()
    }

    // MARK: - TEST A: Persistent Pause Survives Pumps & Intervals

    func testA_PersistentPauseSurvivesPumpsAndIntervals() async throws {
        let engine = try TorrentEngine(
            storageDirectoryURL: engineStorageURL,
            maxConcurrentTorrents: 2,
            persistenceStore: persistenceStore
        )
        try await engine.start()

        let hash = "aaaa111122223333444455556666777788889999"
        let task = try await engine.addTorrent(
            magnetURI: "magnet:?xt=urn:btih:\(hash)&dn=TestA",
            saveDirectoryURL: engineStorageURL
        )
        XCTAssertEqual(task.infoHash.lowercased(), hash)

        // 1. Explicitly pause the transfer
        try await engine.pause(infoHash: hash)

        // 2. Assert pause is in effect immediately
        let pausedTask = await engine.task(for: hash)
        XCTAssertNotNil(pausedTask)
        XCTAssertTrue(pausedTask!.isExplicitlyPaused)
        XCTAssertEqual(pausedTask!.state, .paused)

        let record = await engine.queueSnapshot()?.records.first(where: { $0.infoHash == hash })
        XCTAssertNotNil(record)
        XCTAssertTrue(record!.isExplicitlyPaused)
        XCTAssertEqual(record!.state, .paused)

        // 3. Repeatedly enumerate tasks, fetch snapshots, and wait for intervals
        for _ in 1...20 {
            let tasks = await engine.allTasks()
            let t = tasks.first(where: { $0.infoHash == hash })
            XCTAssertNotNil(t)
            XCTAssertTrue(t!.isExplicitlyPaused, "isExplicitlyPaused must remain true across repeated task enumeration")
            XCTAssertEqual(t!.state, .paused, "State must remain .paused")

            _ = await engine.queueSnapshot()
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }

        await engine.stop()
    }

    // MARK: - TEST B: Other Torrents Continue While Paused Torrent Remains Inactive

    func testB_OtherTorrentsCanContinueWhilePausedTorrentRemainsInactive() async throws {
        let engine = try TorrentEngine(
            storageDirectoryURL: engineStorageURL,
            maxConcurrentTorrents: 1, // Strict concurrency = 1
            persistenceStore: persistenceStore
        )
        try await engine.start()

        let hash1 = "1111aaaaaaaa1111aaaaaaaa1111aaaaaaaa1111"
        let hash2 = "2222bbbbbbbb2222bbbbbbbb2222bbbbbbbb2222"
        let hash3 = "3333cccccccc3333cccccccc3333cccccccc3333"

        // Enqueue first torrent (admitted to active slot)
        _ = try await engine.addTorrent(
            magnetURI: "magnet:?xt=urn:btih:\(hash1)&dn=Item1",
            saveDirectoryURL: engineStorageURL,
            priority: .normal
        )

        // Enqueue second and third torrents (queued due to capacity limit)
        _ = try await engine.addTorrent(
            magnetURI: "magnet:?xt=urn:btih:\(hash2)&dn=Item2",
            saveDirectoryURL: engineStorageURL,
            priority: .high
        )
        _ = try await engine.addTorrent(
            magnetURI: "magnet:?xt=urn:btih:\(hash3)&dn=Item3",
            saveDirectoryURL: engineStorageURL,
            priority: .low
        )

        // Explicitly pause Item 2 (which had high priority)
        try await engine.pause(infoHash: hash2)

        var snap = await engine.queueSnapshot()
        var r2 = snap?.records.first(where: { $0.infoHash == hash2 })
        XCTAssertTrue(r2!.isExplicitlyPaused)
        XCTAssertEqual(r2!.state, .paused)

        // Remove or finish Item 1 to free up capacity
        try await engine.remove(infoHash: hash1)

        // Item 3 (low priority) MUST be promoted because Item 2 is explicitly paused!
        snap = await engine.queueSnapshot()
        r2 = snap?.records.first(where: { $0.infoHash == hash2 })
        let r3 = snap?.records.first(where: { $0.infoHash == hash3 })

        XCTAssertTrue(r2!.isExplicitlyPaused, "Explicitly paused Item 2 must NOT be promoted")
        XCTAssertEqual(r2!.state, .paused, "Explicitly paused Item 2 must remain .paused")
        XCTAssertEqual(r3?.state, .downloading, "Eligible Item 3 must be promoted to downloading")

        // Dynamically raise concurrency to 5
        try await engine.setMaxConcurrentTorrents(5)

        snap = await engine.queueSnapshot()
        r2 = snap?.records.first(where: { $0.infoHash == hash2 })
        XCTAssertTrue(r2!.isExplicitlyPaused, "Item 2 must remain explicitly paused even with excess slots")
        XCTAssertEqual(r2!.state, .paused, "Item 2 must stay .paused")

        await engine.stop()
    }

    // MARK: - TEST C: Stop/Start Engine Restoration

    func testC_StopStartRestorationPreservesExplicitPause() async throws {
        let hash = "cccc4444dddd5555eeee6666ffff777700001111"

        // Session 1: Create, enqueue, pause, and cleanly stop
        do {
            let engine1 = try TorrentEngine(
                storageDirectoryURL: engineStorageURL,
                maxConcurrentTorrents: 2,
                persistenceStore: persistenceStore
            )
            try await engine1.start()

            _ = try await engine1.addTorrent(
                magnetURI: "magnet:?xt=urn:btih:\(hash)&dn=PersistItem",
                saveDirectoryURL: engineStorageURL
            )
            try await engine1.pause(infoHash: hash)

            let t1 = await engine1.task(for: hash)
            XCTAssertTrue(t1!.isExplicitlyPaused)
            XCTAssertEqual(t1!.state, .paused)

            await engine1.stop()
        }

        // Session 2: Fresh engine instance using identical persistence store
        do {
            let engine2 = try TorrentEngine(
                storageDirectoryURL: engineStorageURL,
                maxConcurrentTorrents: 2,
                persistenceStore: persistenceStore
            )
            try await engine2.start()

            // Verify task state restored from manifest
            let t2 = await engine2.task(for: hash)
            XCTAssertNotNil(t2, "Torrent must be restored from persistent store")
            XCTAssertTrue(t2!.isExplicitlyPaused, "Restored torrent must have isExplicitlyPaused == true")
            XCTAssertEqual(t2!.state, .paused, "Restored torrent state must be .paused")

            // Verify queue snapshot
            let snap = await engine2.queueSnapshot()
            let r = snap?.records.first(where: { $0.infoHash == hash })
            XCTAssertNotNil(r)
            XCTAssertTrue(r!.isExplicitlyPaused)
            XCTAssertEqual(r!.state, .paused)

            await engine2.stop()
        }
    }

    // MARK: - TEST D: Repeated Status Refresh and Snapshot Reconciliation

    func testD_RepeatedStatusRefreshDoesNotClearExplicitPause() async throws {
        let engine = try TorrentEngine(
            storageDirectoryURL: engineStorageURL,
            maxConcurrentTorrents: 3,
            persistenceStore: persistenceStore
        )
        try await engine.start()

        let hash = "dddd5555eeee6666ffff7777aaaa8888bbbb9999"
        _ = try await engine.addTorrent(
            magnetURI: "magnet:?xt=urn:btih:\(hash)&dn=ReconcileItem",
            saveDirectoryURL: engineStorageURL
        )
        try await engine.pause(infoHash: hash)

        // Rapidly call status queries 50 times in a row
        for _ in 1...50 {
            let task = await engine.task(for: hash)
            XCTAssertNotNil(task)
            XCTAssertTrue(task!.isExplicitlyPaused, "Status query must not unset isExplicitlyPaused")
            XCTAssertEqual(task!.state, .paused, "Status query must not flip state away from .paused")

            let all = await engine.allTasks()
            let matched = all.first(where: { $0.infoHash == hash })
            XCTAssertNotNil(matched)
            XCTAssertTrue(matched!.isExplicitlyPaused)
            XCTAssertEqual(matched!.state, .paused)
        }

        await engine.stop()
    }

    // MARK: - TEST E: Explicit User Resume Gating & Admission

    func testE_ExplicitUserResumeGatingAndAdmission() async throws {
        let engine = try TorrentEngine(
            storageDirectoryURL: engineStorageURL,
            maxConcurrentTorrents: 1, // Only 1 active slot
            persistenceStore: persistenceStore
        )
        try await engine.start()

        let hashActive = "1111111111111111111111111111111111111111"
        let hashPaused = "2222222222222222222222222222222222222222"

        // Enqueue active item
        _ = try await engine.addTorrent(
            magnetURI: "magnet:?xt=urn:btih:\(hashActive)&dn=ActiveItem",
            saveDirectoryURL: engineStorageURL
        )

        // Enqueue second item and pause it explicitly
        _ = try await engine.addTorrent(
            magnetURI: "magnet:?xt=urn:btih:\(hashPaused)&dn=PausedItem",
            saveDirectoryURL: engineStorageURL
        )
        try await engine.pause(infoHash: hashPaused)

        var tPaused = await engine.task(for: hashPaused)
        XCTAssertTrue(tPaused!.isExplicitlyPaused)
        XCTAssertEqual(tPaused!.state, .paused)

        // Explicitly resume the second item while slot is full
        try await engine.resume(infoHash: hashPaused)

        // Since max concurrency is 1 and hashActive is running, hashPaused must become .queued, NOT .downloading!
        tPaused = await engine.task(for: hashPaused)
        XCTAssertFalse(tPaused!.isExplicitlyPaused, "Explicit resume must clear isExplicitlyPaused")
        XCTAssertEqual(tPaused!.state, .queued, "Item must transition to .queued when capacity is unavailable")

        // Now remove the active item
        try await engine.remove(infoHash: hashActive)

        // hashPaused should now be admitted and become .downloading
        tPaused = await engine.task(for: hashPaused)
        XCTAssertEqual(tPaused!.state, .downloading, "Item should transition to .downloading once slot opens")

        await engine.stop()
    }

    // MARK: - TEST F: App Lifecycle Background Persistence & Foreground Restoration

    func testF_AppLifecycleBackgroundAndForegroundRestoration() async throws {
        let hash = "ffff999900001111222233334444555566667777"

        // Stage 1: App foreground session, add torrent, pause it
        let engine = try TorrentEngine(
            storageDirectoryURL: engineStorageURL,
            maxConcurrentTorrents: 2,
            persistenceStore: persistenceStore
        )
        try await engine.start()

        _ = try await engine.addTorrent(
            magnetURI: "magnet:?xt=urn:btih:\(hash)&dn=LifecycleItem",
            saveDirectoryURL: engineStorageURL
        )
        try await engine.pause(infoHash: hash)

        // Stage 2: Simulate App Entering Background (sceneDidEnterBackground)
        // Flushes manifest and saves resume data, then stops engine
        await engine.stop(timeoutSeconds: 2.0)

        // Verify state on disk while app is "suspended"
        let manifest = await persistenceStore.loadManifest()
        let diskRecord = manifest.records.first(where: { $0.infoHash == hash })
        XCTAssertNotNil(diskRecord, "Record must be persisted to manifest")
        XCTAssertTrue(diskRecord!.isExplicitlyPaused, "Disk manifest must preserve isExplicitlyPaused == true")
        XCTAssertEqual(diskRecord!.state, .paused, "Disk manifest state must be .paused")

        // Stage 3: Simulate App Returning to Foreground (sceneWillEnterForeground)
        let relaunchedEngine = try TorrentEngine(
            storageDirectoryURL: engineStorageURL,
            maxConcurrentTorrents: 2,
            persistenceStore: persistenceStore
        )
        try await relaunchedEngine.start()

        let restoredTask = await relaunchedEngine.task(for: hash)
        XCTAssertNotNil(restoredTask)
        XCTAssertTrue(restoredTask!.isExplicitlyPaused, "Restored task must retain isExplicitlyPaused == true")
        XCTAssertEqual(restoredTask!.state, .paused, "Restored task state must NOT be auto-resumed")

        await relaunchedEngine.stop()
    }
}
