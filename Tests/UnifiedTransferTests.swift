import XCTest
import Foundation
@testable import DM_Reverse_engineering

final class UnifiedTransferTests: XCTestCase {

    func testUnifiedTransferFromHTTPSnapshot() {
        let dest = URL(fileURLWithPath: "/tmp/downloads/video.mp4")
        let sourceURL = URL(string: "https://example.com/video.mp4")!
        let now = Date()

        let snapshot = DownloadSnapshot(
            id: "http-task-1",
            url: sourceURL,
            destinationURL: dest,
            state: .downloading,
            priority: .normal,
            completedBytes: 52_428_800,
            totalBytes: 104_857_600,
            progressFraction: 0.5,
            currentBytesPerSecond: 5_242_880,
            averageBytesPerSecond: 4_000_000,
            elapsedTime: 12,
            estimatedTimeRemaining: 10,
            failureReason: nil,
            checksumOutcome: .notChecked,
            enqueuedAt: now
        )

        let transfer = UnifiedTransfer(from: snapshot)

        XCTAssertEqual(transfer.id, "http-task-1")
        XCTAssertEqual(transfer.name, "video.mp4")
        XCTAssertEqual(transfer.type, TransferType.http)
        XCTAssertTrue(transfer.isHTTP)
        XCTAssertFalse(transfer.isTorrent)
        XCTAssertEqual(transfer.state, UnifiedTransferState.downloading)
        XCTAssertEqual(transfer.completedBytes, 52_428_800)
        XCTAssertEqual(transfer.totalBytes, 104_857_600)
        XCTAssertEqual(transfer.progressFraction, 0.5, accuracy: 0.001)
        XCTAssertEqual(transfer.downloadSpeedBytesPerSecond, 5_242_880)
        XCTAssertEqual(transfer.uploadSpeedBytesPerSecond, 0.0)
        XCTAssertEqual(transfer.destinationURL, dest)
        XCTAssertEqual(transfer.source, "https://example.com/video.mp4")
        XCTAssertNil(transfer.infoHash)
        XCTAssertNil(transfer.connectedPeers)
        XCTAssertNil(transfer.connectedSeeds)
        XCTAssertTrue(transfer.canPause)
        XCTAssertFalse(transfer.canResume)
    }

    func testUnifiedTransferFromTorrentTask() {
        let saveDir = URL(fileURLWithPath: "/tmp/downloads/ubuntu.iso")
        let hash = "0123456789abcdef0123456789abcdef01234567"
        let now = Date()

        let task = TorrentTask(
            source: "magnet:?xt=urn:btih:\(hash)&dn=ubuntu.iso",
            name: "ubuntu.iso",
            savePath: saveDir,
            state: .downloading,
            progress: TorrentProgress(
                bytesDownloaded: 200_000_000,
                totalBytes: 1_000_000_000,
                downloadBytesPerSecond: 10_000_000,
                uploadBytesPerSecond: 1_500_000,
                connectedPeers: 42,
                activeSeeds: 18,
                progressFraction: 0.2
            ),
            errorMessage: nil,
            createdAt: now,
            infoHash: hash,
            priority: .high,
            isExplicitlyPaused: false
        )

        let transfer = UnifiedTransfer(from: task)

        XCTAssertEqual(transfer.id, task.id.uuidString)
        XCTAssertEqual(transfer.name, "ubuntu.iso")
        XCTAssertEqual(transfer.type, .torrent)
        XCTAssertTrue(transfer.isTorrent)
        XCTAssertFalse(transfer.isHTTP)
        XCTAssertEqual(transfer.state, .downloading)
        XCTAssertEqual(transfer.completedBytes, 200_000_000)
        XCTAssertEqual(transfer.totalBytes, 1_000_000_000)
        XCTAssertEqual(transfer.progressFraction, 0.2, accuracy: 0.001)
        XCTAssertEqual(transfer.downloadSpeedBytesPerSecond, 10_000_000)
        XCTAssertEqual(transfer.uploadSpeedBytesPerSecond, 1_500_000)
        XCTAssertEqual(transfer.destinationURL, saveDir)
        XCTAssertEqual(transfer.infoHash, hash)
        XCTAssertEqual(transfer.connectedPeers, 42)
        XCTAssertEqual(transfer.connectedSeeds, 18)
        XCTAssertEqual(transfer.torrentPriority, .high)
        XCTAssertFalse(transfer.isExplicitlyPaused)
        XCTAssertTrue(transfer.canPause)
        XCTAssertFalse(transfer.canResume)
    }

    func testTorrentUnknownMetadataRepresentation() {
        let saveDir = URL(fileURLWithPath: "/tmp/downloads/pending")
        let hash = "abcdef0123456789abcdef0123456789abcdef01"

        let task = TorrentTask(
            source: "magnet:?xt=urn:btih:\(hash)",
            name: "Magnet-\(hash.prefix(8))",
            savePath: saveDir,
            state: .queued,
            progress: TorrentProgress(
                bytesDownloaded: 0,
                totalBytes: 0, // Metadata not yet fetched
                downloadBytesPerSecond: 0,
                uploadBytesPerSecond: 0,
                connectedPeers: 0,
                activeSeeds: 0,
                progressFraction: 0
            ),
            createdAt: Date(),
            infoHash: hash,
            priority: .normal,
            isExplicitlyPaused: false
        )

        let transfer = UnifiedTransfer(from: task)

        XCTAssertNil(transfer.totalBytes, "Unknown total bytes must be represented as nil rather than completed")
        XCTAssertEqual(transfer.completedBytes, 0)
        XCTAssertEqual(transfer.progressFraction, 0.0)
        XCTAssertEqual(transfer.state, .queued)
        XCTAssertFalse(transfer.isCompleted)
    }

    func testSeedingTorrentStateRepresentation() {
        let saveDir = URL(fileURLWithPath: "/tmp/downloads/shared.zip")
        let hash = "fedcba9876543210fedcba9876543210fedcba98"

        let task = TorrentTask(
            source: "magnet:?xt=urn:btih:\(hash)&dn=shared.zip",
            name: "shared.zip",
            savePath: saveDir,
            state: .seeding,
            progress: TorrentProgress(
                bytesDownloaded: 50_000_000,
                totalBytes: 50_000_000,
                downloadBytesPerSecond: 0,
                uploadBytesPerSecond: 2_000_000,
                connectedPeers: 12,
                activeSeeds: 5,
                progressFraction: 1.0
            ),
            createdAt: Date(),
            infoHash: hash,
            priority: .normal,
            isExplicitlyPaused: false
        )

        let transfer = UnifiedTransfer(from: task)

        XCTAssertEqual(transfer.state, .seeding)
        XCTAssertTrue(transfer.isSeeding)
        XCTAssertTrue(transfer.isCompleted)
        XCTAssertTrue(transfer.canPause)
        XCTAssertEqual(transfer.uploadSpeedBytesPerSecond, 2_000_000)
    }

    func testUnifiedTransferFilterMatching() {
        let downloadingTransfer = UnifiedTransfer(
            id: "t1",
            name: "File1",
            type: .torrent,
            state: .downloading,
            completedBytes: 10,
            totalBytes: 100,
            progressFraction: 0.1,
            downloadSpeedBytesPerSecond: 1000,
            destinationURL: URL(fileURLWithPath: "/tmp"),
            source: "magnet:?",
            createdAt: Date()
        )

        let pausedTransfer = UnifiedTransfer(
            id: "t2",
            name: "File2",
            type: .http,
            state: .paused,
            completedBytes: 10,
            totalBytes: 100,
            progressFraction: 0.1,
            destinationURL: URL(fileURLWithPath: "/tmp"),
            source: "https://",
            createdAt: Date()
        )

        let completedTransfer = UnifiedTransfer(
            id: "t3",
            name: "File3",
            type: .torrent,
            state: .completed,
            completedBytes: 100,
            totalBytes: 100,
            progressFraction: 1.0,
            destinationURL: URL(fileURLWithPath: "/tmp"),
            source: "magnet:?",
            createdAt: Date()
        )

        let failedTransfer = UnifiedTransfer(
            id: "t4",
            name: "File4",
            type: .torrent,
            state: .failed(reason: "Tracker error"),
            completedBytes: 0,
            totalBytes: nil,
            progressFraction: 0.0,
            destinationURL: URL(fileURLWithPath: "/tmp"),
            source: "magnet:?",
            createdAt: Date()
        )

        XCTAssertTrue(downloadingTransfer.matchesFilter(DownloadFilter.all))
        XCTAssertTrue(downloadingTransfer.matchesFilter(DownloadFilter.active))
        XCTAssertFalse(downloadingTransfer.matchesFilter(DownloadFilter.paused))
        XCTAssertFalse(downloadingTransfer.matchesFilter(DownloadFilter.completed))
        XCTAssertFalse(downloadingTransfer.matchesFilter(DownloadFilter.failed))

        XCTAssertTrue(pausedTransfer.matchesFilter(DownloadFilter.all))
        XCTAssertFalse(pausedTransfer.matchesFilter(DownloadFilter.active))
        XCTAssertTrue(pausedTransfer.matchesFilter(DownloadFilter.paused))

        XCTAssertTrue(completedTransfer.matchesFilter(DownloadFilter.all))
        XCTAssertFalse(completedTransfer.matchesFilter(DownloadFilter.active))
        XCTAssertTrue(completedTransfer.matchesFilter(DownloadFilter.completed))

        XCTAssertTrue(failedTransfer.matchesFilter(DownloadFilter.all))
        XCTAssertTrue(failedTransfer.matchesFilter(DownloadFilter.failed))
    }

    func testIdentifiableURL() {
        let sampleURL = URL(fileURLWithPath: "/tmp/test.mp4")
        let item1 = IdentifiableURL(url: sampleURL)
        let item2 = IdentifiableURL(url: sampleURL)
        XCTAssertEqual(item1.id, sampleURL.absoluteString)
        XCTAssertEqual(item1, item2)
        XCTAssertEqual(item1.url, sampleURL)
    }
}
