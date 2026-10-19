import XCTest
import Foundation

#if canImport(LibTorrent)
import LibTorrent

/// Milestone 1-3 Verification Test Suite.
/// Validates libtorrent 2.0.x native build feasibility, Objective-C++ bridge integration,
/// safe session creation / teardown, and Milestone 3 core transfer operations.
final class TorrentSessionBridgeTests: XCTestCase {
    func testLibtorrentVersionString() {
        let version = TorrentSessionBridge.libtorrentVersion()
        XCTAssertFalse(version.isEmpty, "libtorrent version should not be empty")
        XCTAssertTrue(
            version.hasPrefix("2.0."),
            "Expected libtorrent 2.0.x version series, but received: \(version)"
        )
    }

    func testSessionLifecycleCreationAndShutdown() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("1DM_Torrent_Test_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let bridge = TorrentSessionBridge(storagePath: tempDir.path, portStart: 6881, portEnd: 6891)
        XCTAssertEqual(bridge.storagePath, tempDir.path)
        XCTAssertFalse(bridge.isListening)
        XCTAssertEqual(bridge.listenPort, 0)

        XCTAssertNoThrow(try bridge.startSession(), "Failed to start libtorrent session")
        XCTAssertTrue(bridge.isListening, "Expected session to be listening after startSession")
        XCTAssertGreaterThan(bridge.listenPort, 0, "Listen port should be non-zero after session starts")

        bridge.stopSession()
        XCTAssertFalse(bridge.isListening, "Expected session to no longer be listening after stopSession")
    }

    func testBridgeMagnetAdditionAndStatusAndRemoval() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("1DM_Torrent_Magnet_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let bridge = TorrentSessionBridge(storagePath: tempDir.path, portStart: 6892, portEnd: 6902)
        try bridge.startSession()
        defer { bridge.stopSession() }

        let magnet = "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=UbuntuISO"
        let hash = try bridge.addTorrent(withMagnetURI: magnet, savePath: tempDir.path)
        XCTAssertEqual(hash, "0123456789abcdef0123456789abcdef01234567")

        guard let status = bridge.status(forTorrentWithHash: hash) else {
            XCTFail("Status should be retrievable for added torrent")
            return
        }
        XCTAssertEqual(status.infoHash, hash)
        XCTAssertEqual(status.name, "UbuntuISO")
        XCTAssertEqual(status.savePath, tempDir.path)

        // Pause
        try bridge.pauseTorrent(withHash: hash)
        let pausedStatus = bridge.status(forTorrentWithHash: hash)
        XCTAssertEqual(pausedStatus?.state, .paused)

        // Resume
        try bridge.resumeTorrent(withHash: hash)
        let resumedStatus = bridge.status(forTorrentWithHash: hash)
        XCTAssertNotEqual(resumedStatus?.state, .paused)

        // All statuses
        let all = bridge.allTorrentStatuses()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.infoHash, hash)

        // Removal
        try bridge.removeTorrent(withHash: hash, deleteFiles: false)
        XCTAssertNil(bridge.status(forTorrentWithHash: hash))
        XCTAssertEqual(bridge.allTorrentStatuses().count, 0)
    }
}
#endif
