import XCTest
import Foundation
@testable import DM_Reverse_engineering

#if canImport(LibTorrent)
import LibTorrent

/// Milestone 2, 3 & 4 Integration Tests.
/// Validates that `TorrentEngine` Swift actor facade interacts correctly with
/// the underlying native libtorrent session lifecycle, magnet ingestion, transfer controls,
/// persistence, fast-resume recovery, and queue scheduling.
final class TorrentEngineTests: XCTestCase {
    func testTorrentEngineLifecycleAndStatus() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TorrentEngineTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let engine = TorrentEngine(
            storageDirectoryURL: tempDir,
            portStart: 6881,
            portEnd: 6891
        )

        // 1. Initial State before starting
        var status = await engine.status()
        XCTAssertFalse(status.isRunning, "Engine should report isRunning == false before start")
        XCTAssertFalse(status.isListening, "Engine should report isListening == false before start")
        XCTAssertEqual(status.listenPort, 0, "Listen port should be 0 before start")
        XCTAssertFalse(status.libtorrentVersion.isEmpty, "libtorrentVersion should not be empty")
        XCTAssertTrue(status.libtorrentVersion.hasPrefix("2.0."), "libtorrentVersion should start with 2.0., got \(status.libtorrentVersion)")

        // 2. Start session
        try await engine.start()
        status = await engine.status()
        XCTAssertTrue(status.isRunning, "Engine should report isRunning == true after start")
        XCTAssertTrue(status.isListening, "Engine should report isListening == true after start")
        XCTAssertGreaterThan(status.listenPort, 0, "Engine listenPort should be non-zero after start")

        // 3. Idempotent start call must not fail or crash
        try await engine.start()
        status = await engine.status()
        XCTAssertTrue(status.isRunning, "Engine should remain running on repeated start()")

        // 4. Stop session
        await engine.stop()
        status = await engine.status()
        XCTAssertFalse(status.isRunning, "Engine should report isRunning == false after stop")
        XCTAssertFalse(status.isListening, "Engine should report isListening == false after stop")

        // 5. Idempotent stop call must be safe
        await engine.stop()
        status = await engine.status()
        XCTAssertFalse(status.isRunning)
    }

    func testTorrentEngineMagnetIngestionAndControls() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TorrentEngineMagnetTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let engine = TorrentEngine(
            storageDirectoryURL: tempDir,
            portStart: 6912,
            portEnd: 6922
        )

        // Engine must be started before adding torrents
        let magnet = "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=TestLinux"
        do {
            _ = try await engine.addTorrent(magnetURI: magnet)
            XCTFail("Adding torrent before engine start must throw sessionNotRunning")
        } catch let error as TorrentEngineError {
            XCTAssertEqual(error, .sessionNotRunning)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        try await engine.start()
        defer {
            Task { await engine.stop() }
        }

        let task = try await engine.addTorrent(magnetURI: magnet)
        XCTAssertEqual(task.infoHash, "0123456789abcdef0123456789abcdef01234567")
        XCTAssertEqual(task.name, "TestLinux")

        // Inspect via task(for:)
        let fetched = await engine.task(for: task.infoHash)
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.infoHash, task.infoHash)

        // All tasks
        let all = await engine.allTasks()
        XCTAssertEqual(all.count, 1)

        // Pause
        try await engine.pause(infoHash: task.infoHash)
        let pausedTask = await engine.task(for: task.infoHash)
        XCTAssertEqual(pausedTask?.state, .paused)

        // Resume
        try await engine.resume(infoHash: task.infoHash)
        let resumedTask = await engine.task(for: task.infoHash)
        XCTAssertNotEqual(resumedTask?.state, .paused)

        // Removal
        try await engine.remove(infoHash: task.infoHash, deleteFiles: false)
        let afterRemove = await engine.task(for: task.infoHash)
        XCTAssertNil(afterRemove)
        let allAfterRemove = await engine.allTasks()
        XCTAssertEqual(allAfterRemove.count, 0)
    }

    func testTorrentEngineQueueAndPersistenceIntegration() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TorrentEngineQueueTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let engine = TorrentEngine(
            storageDirectoryURL: tempDir,
            portStart: 6932,
            portEnd: 6942,
            maxConcurrentTorrents: 2
        )

        try await engine.start()

        let m1 = "magnet:?xt=urn:btih:1111111111111111111111111111111111111111&dn=First"
        let m2 = "magnet:?xt=urn:btih:2222222222222222222222222222222222222222&dn=Second"
        let m3 = "magnet:?xt=urn:btih:3333333333333333333333333333333333333333&dn=Third"

        _ = try await engine.addTorrent(magnetURI: m1, priority: .normal)
        _ = try await engine.addTorrent(magnetURI: m2, priority: .high)
        _ = try await engine.addTorrent(magnetURI: m3, priority: .low)

        let snapshot = await engine.queueSnapshot()
        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.totalTorrents, 3)
        XCTAssertEqual(snapshot?.activeCount, 2)
        XCTAssertEqual(snapshot?.queuedCount, 1)

        // Explicitly pause Second (hash 2222...)
        try await engine.pause(infoHash: "2222222222222222222222222222222222222222")

        // Third should have been promoted into the vacated slot!
        let snapAfterPause = await engine.queueSnapshot()
        XCTAssertEqual(snapAfterPause?.activeCount, 2)
        XCTAssertEqual(snapAfterPause?.pausedCount, 1)

        // Stop session safely with persistence
        await engine.stop(timeoutSeconds: 2.0)

        // Restart fresh engine with the same directory
        let freshEngine = TorrentEngine(
            storageDirectoryURL: tempDir,
            portStart: 6932,
            portEnd: 6942,
            maxConcurrentTorrents: 2
        )

        try await freshEngine.start()
        defer {
            Task { await freshEngine.stop() }
        }

        let restoredSnap = await freshEngine.queueSnapshot()
        XCTAssertNotNil(restoredSnap)
        XCTAssertEqual(restoredSnap?.totalTorrents, 3)
        XCTAssertEqual(restoredSnap?.pausedCount, 1, "Explicitly paused torrent must remain paused upon restoration")
    }
}
#endif
