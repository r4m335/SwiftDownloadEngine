import XCTest
import Foundation
@testable import DM_Reverse_engineering

#if canImport(LibTorrent)
import LibTorrent

/// Milestone 2 & 3 Integration Tests.
/// Validates that `TorrentEngine` Swift actor facade interacts correctly with
/// the underlying native libtorrent session lifecycle, magnet ingestion, and transfer controls.
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
}
#endif
