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
            progress: TorrentProgress(bytesDownloaded: 50, totalBytes: 100, progressFraction: 0.5)
        )

        let data = try JSONEncoder().encode(task)
        let decoded = try JSONDecoder().decode(TorrentTask.self, from: data)
        XCTAssertEqual(decoded, task)
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
}
