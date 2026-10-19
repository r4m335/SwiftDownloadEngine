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
            infoHash: "0123456789abcdef0123456789abcdef01234567",
            priority: .high,
            isExplicitlyPaused: true
        )

        let data = try JSONEncoder().encode(task)
        let decoded = try JSONDecoder().decode(TorrentTask.self, from: data)
        XCTAssertEqual(decoded, task)
        XCTAssertEqual(decoded.infoHash, "0123456789abcdef0123456789abcdef01234567")
        XCTAssertEqual(decoded.priority, .high)
        XCTAssertTrue(decoded.isExplicitlyPaused)
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

        let genFailed = TorrentEngineError.resumeDataGenerationFailed("Disk full")
        XCTAssertEqual(genFailed.localizedDescription, "Failed to generate fast-resume data: Disk full")

        let corrupt = TorrentEngineError.resumeDataCorrupt("Invalid bencode")
        XCTAssertEqual(corrupt.localizedDescription, "Corrupted or incompatible fast-resume data: Invalid bencode")

        let persistErr = TorrentEngineError.persistenceError("Cannot write")
        XCTAssertEqual(persistErr.localizedDescription, "Persistence error: Cannot write")

        let schemaErr = TorrentEngineError.unsupportedSchemaVersion(2)
        XCTAssertEqual(schemaErr.localizedDescription, "Unsupported persistence schema version: 2")

        let dupErr = TorrentEngineError.duplicateTorrent("abc")
        XCTAssertEqual(dupErr.localizedDescription, "Torrent with info-hash abc already exists.")
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

    func testTorrentPriorityOrdering() {
        XCTAssertTrue(TorrentPriority.low < TorrentPriority.normal)
        XCTAssertTrue(TorrentPriority.normal < TorrentPriority.high)
        XCTAssertFalse(TorrentPriority.high < TorrentPriority.low)
        XCTAssertEqual(TorrentPriority.low.rawValue, 1)
        XCTAssertEqual(TorrentPriority.normal.rawValue, 2)
        XCTAssertEqual(TorrentPriority.high.rawValue, 3)
    }

    func testTorrentRecordRoundTripsCodable() throws {
        let record = TorrentRecord(
            infoHash: "0123456789abcdef0123456789abcdef01234567",
            source: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567",
            name: "ArchLinux",
            savePath: URL(fileURLWithPath: "/var/tmp/downloads"),
            state: .seeding,
            progress: TorrentProgress(bytesDownloaded: 500, totalBytes: 500, progressFraction: 1.0),
            priority: .high,
            sequenceIndex: 42,
            isExplicitlyPaused: false,
            seedRatioLimit: 2.0,
            fastResumeFileName: "0123456789abcdef0123456789abcdef01234567.fastresume",
            schemaVersion: 1,
            errorMessage: nil
        )

        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(TorrentRecord.self, from: data)
        XCTAssertEqual(decoded, record)
        XCTAssertEqual(decoded.infoHash, "0123456789abcdef0123456789abcdef01234567")
        XCTAssertEqual(decoded.priority, .high)
        XCTAssertEqual(decoded.sequenceIndex, 42)
        XCTAssertEqual(decoded.seedRatioLimit, 2.0)
    }

    func testTorrentQueueManifestAndSnapshot() throws {
        let record = TorrentRecord(
            infoHash: "abc",
            source: "magnet:?xt=urn:btih:abc",
            name: "Test",
            savePath: URL(fileURLWithPath: "/tmp")
        )
        let manifest = TorrentQueueManifest(
            schemaVersion: 1,
            maxConcurrentTorrents: 4,
            sequenceCounter: 10,
            records: [record]
        )

        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(TorrentQueueManifest.self, from: data)
        XCTAssertEqual(decoded, manifest)
        XCTAssertEqual(decoded.maxConcurrentTorrents, 4)
        XCTAssertEqual(decoded.records.count, 1)

        let snapshot = TorrentQueueSnapshot(
            totalTorrents: 1,
            activeCount: 1,
            queuedCount: 0,
            pausedCount: 0,
            completedCount: 0,
            seedingCount: 0,
            failedCount: 0,
            records: [record]
        )
        XCTAssertEqual(snapshot.totalTorrents, 1)
        XCTAssertEqual(snapshot.activeCount, 1)
    }
}
