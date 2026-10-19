import XCTest
import Foundation

#if canImport(LibTorrent)
import LibTorrent

/// Milestone 1 Verification Test Suite.
/// Validates libtorrent 2.0.x native build feasibility, Objective-C++ bridge integration,
/// and safe session creation / teardown on iOS.
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

        var error: NSError?
        let started = bridge.startSession(&error)
        XCTAssertTrue(started, "Failed to start libtorrent session: \(String(describing: error))")
        XCTAssertNil(error, "Unexpected error starting session: \(String(describing: error))")
        XCTAssertTrue(bridge.isListening, "Expected session to be listening after startSession")
        XCTAssertGreaterThan(bridge.listenPort, 0, "Listen port should be non-zero after session starts")

        bridge.stopSession()
        XCTAssertFalse(bridge.isListening, "Expected session to no longer be listening after stopSession")
    }
}
#endif
