import XCTest
@testable import DM_Reverse_engineering

final class TorrentModelsTests: XCTestCase {
    func testProgressClampsInvalidValues() {
        let progress = TorrentProgress(
            bytesDownloaded: -5,
            totalBytes: -10,
            downloadBytesPerSecond: -1,
            uploadBytesPerSecond: -2,
            connectedPeers: -3,
            activeSeeds: -4,
            progressFraction: 1.5
        )

        XCTAssertEqual(progress.bytesDownloaded, 0)
        XCTAssertEqual(progress.totalBytes, 0)
        XCTAssertEqual(progress.downloadBytesPerSecond, 0)
        XCTAssertEqual(progress.uploadBytesPerSecond, 0)
        XCTAssertEqual(progress.connectedPeers, 0)
        XCTAssertEqual(progress.activeSeeds, 0)
        XCTAssertEqual(progress.progressFraction, 1)
    }

    func testTorrentTaskRoundTripsCodable() throws {
        let task = TorrentTask(
            source: "magnet:?xt=urn:btih:example",
            name: "Example",
            savePath: URL(fileURLWithPath: "/tmp/example"),
            state: .paused,
            progress: TorrentProgress(bytesDownloaded: 50, totalBytes: 100, progressFraction: 0.5),
            infoHash: "0123456789abcdef0123456789abcdef01234567"
        )

        let data = try JSONEncoder().encode(task)
        let decoded = try JSONDecoder().decode(TorrentTask.self, from: data)
        XCTAssertEqual(decoded, task)
        XCTAssertEqual(decoded.infoHash, "0123456789abcdef0123456789abcdef01234567")
    }

    func testSessionStatusCapturesHealth() {
        let status = TorrentSessionStatus(
            isRunning: true,
            isListening: true,
            listenPort: 6881,
            libtorrentVersion: "2.0.10.0"
        )

        XCTAssertTrue(status.isRunning)
        XCTAssertTrue(status.isListening)
        XCTAssertEqual(status.listenPort, 6881)
        XCTAssertEqual(status.libtorrentVersion, "2.0.10.0")
    }

    func testTorrentEngineErrors() {
        let notRunning = TorrentEngineError.sessionNotRunning
        XCTAssertEqual(notRunning.localizedDescription, "The torrent engine session is not running.")

        let notFound = TorrentEngineError.torrentNotFound
        XCTAssertEqual(notFound.localizedDescription, "The specified torrent was not found.")

        let bridgeErr = TorrentEngineError.bridgeError("Custom error message")
        XCTAssertEqual(bridgeErr.localizedDescription, "Custom error message")
    }

    func testTorrentStateRawValues() {
        XCTAssertEqual(TorrentState.queued.rawValue, "queued")
        XCTAssertEqual(TorrentState.checking.rawValue, "checking")
        XCTAssertEqual(TorrentState.downloading.rawValue, "downloading")
        XCTAssertEqual(TorrentState.finished.rawValue, "finished")
        XCTAssertEqual(TorrentState.seeding.rawValue, "seeding")
        XCTAssertEqual(TorrentState.paused.rawValue, "paused")
        XCTAssertEqual(TorrentState.error.rawValue, "error")
        XCTAssertEqual(TorrentState.removed.rawValue, "removed")
    }
}
