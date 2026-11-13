import XCTest
import Foundation
@testable import DM_Reverse_engineering

final class BandwidthSpeedTrackerTests: XCTestCase {

    // MARK: - 1. Rolling Window Expiration & Bounded Capacity

    func testBandwidthHistoryExpiresSamplesOlderThanMaxDuration() {
        let tracker = BandwidthHistoryTracker(maxDuration: 60.0, maxCapacity: 100)
        let baseDate = Date(timeIntervalSince1970: 1_000_000.0)

        // Record a sample 70 seconds ago (should expire)
        tracker.record(downloadSpeed: 500_000, uploadSpeed: 100_000, timestamp: baseDate.addingTimeInterval(-70))
        // Record a sample 45 seconds ago (should remain)
        tracker.record(downloadSpeed: 1_200_000, uploadSpeed: 250_000, timestamp: baseDate.addingTimeInterval(-45))
        // Record a sample 10 seconds ago (should remain)
        tracker.record(downloadSpeed: 2_500_000, uploadSpeed: 300_000, timestamp: baseDate.addingTimeInterval(-10))
        // Record current sample
        tracker.record(downloadSpeed: 3_000_000, uploadSpeed: 400_000, timestamp: baseDate)

        let history = tracker.history(asOf: baseDate)
        XCTAssertEqual(history.count, 3, "Sample older than 60s must be expired")
        XCTAssertFalse(history.contains(where: { $0.downloadBytesPerSecond == 500_000 }))
        XCTAssertEqual(history.first?.downloadBytesPerSecond, 1_200_000)
        XCTAssertEqual(history.last?.downloadBytesPerSecond, 3_000_000)
    }

    func testBandwidthHistoryEnforcesBoundedCapacity() {
        let maxCap = 70
        let tracker = BandwidthHistoryTracker(maxDuration: 60.0, maxCapacity: maxCap)
        let baseDate = Date(timeIntervalSince1970: 1_000_000.0)

        // Insert 120 samples within a 30-second span
        for i in 0..<120 {
            let offset = Double(i) * 0.2
            tracker.record(downloadSpeed: Double(i * 1000), uploadSpeed: 0, timestamp: baseDate.addingTimeInterval(offset))
        }

        let queryDate = baseDate.addingTimeInterval(30.0)
        let history = tracker.history(asOf: queryDate)
        XCTAssertLessThanOrEqual(history.count, maxCap, "Buffer capacity must be strictly bounded to prevent unbounded memory growth")
    }

    func testPeakSpeedCalculationAndReset() {
        let tracker = BandwidthHistoryTracker(maxDuration: 60.0)
        let now = Date()

        tracker.record(downloadSpeed: 1_000_000, uploadSpeed: 200_000, timestamp: now.addingTimeInterval(-20))
        tracker.record(downloadSpeed: 5_000_000, uploadSpeed: 800_000, timestamp: now.addingTimeInterval(-10))
        tracker.record(downloadSpeed: 2_000_000, uploadSpeed: 300_000, timestamp: now)

        XCTAssertEqual(tracker.peakDownloadSpeed(asOf: now), 5_000_000)
        XCTAssertEqual(tracker.peakUploadSpeed(asOf: now), 800_000)
        XCTAssertEqual(tracker.latestSample?.downloadBytesPerSecond, 2_000_000)

        tracker.reset()
        XCTAssertEqual(tracker.history().count, 0)
        XCTAssertEqual(tracker.peakDownloadSpeed(), 0.0)
        XCTAssertEqual(tracker.peakUploadSpeed(), 0.0)
        XCTAssertNil(tracker.latestSample)
    }

    // MARK: - 2. Download and Upload Aggregation

    func testComputeAggregateThroughput_ActiveTransfers() {
        // Active HTTP downloads
        let http1 = DownloadSnapshot(
            id: "http-1",
            url: URL(string: "https://example.com/file1.bin")!,
            destinationURL: URL(fileURLWithPath: "/tmp/file1.bin"),
            state: .downloading,
            priority: .high,
            completedBytes: 10_000,
            totalBytes: 50_000,
            currentBytesPerSecond: 2_000_000
        )
        let http2 = DownloadSnapshot(
            id: "http-2",
            url: URL(string: "https://example.com/file2.bin")!,
            destinationURL: URL(fileURLWithPath: "/tmp/file2.bin"),
            state: .probing,
            priority: .normal,
            completedBytes: 500,
            totalBytes: 10_000,
            currentBytesPerSecond: 500_000
        )

        // Active Torrent: Downloading (has both download and swarm upload)
        let torrent1 = TorrentTask(
            source: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567",
            name: "Torrent1",
            savePath: URL(fileURLWithPath: "/tmp/t1"),
            state: .downloading,
            progress: TorrentProgress(
                downloadBytesPerSecond: 1_500_000,
                uploadBytesPerSecond: 300_000
            ),
            infoHash: "0123456789abcdef0123456789abcdef01234567"
        )

        // Active Torrent: Seeding (upload only, 0 download)
        let torrent2 = TorrentTask(
            source: "magnet:?xt=urn:btih:fedcba9876543210fedcba9876543210fedcba98",
            name: "Torrent2",
            savePath: URL(fileURLWithPath: "/tmp/t2"),
            state: .seeding,
            progress: TorrentProgress(
                downloadBytesPerSecond: 0,
                uploadBytesPerSecond: 450_000
            ),
            infoHash: "fedcba9876543210fedcba9876543210fedcba98"
        )

        let (totalDownload, totalUpload) = DownloadManagerViewModel.computeAggregateThroughput(
            downloads: [http1, http2],
            torrents: [torrent1, torrent2]
        )

        // Download: 2_000_000 (http1) + 500_000 (http2) + 1_500_000 (torrent1) = 4_000_000
        XCTAssertEqual(totalDownload, 4_000_000)
        // Upload: 300_000 (torrent1) + 450_000 (torrent2) = 750_000
        XCTAssertEqual(totalUpload, 750_000)
    }

    // MARK: - 3. Zero-Speed Behavior on Paused, Completed, and Failed Transfers

    func testComputeAggregateThroughput_InactiveStatesReportZero() {
        let pausedHTTP = DownloadSnapshot(
            id: "p-http",
            url: URL(string: "https://example.com/p.bin")!,
            destinationURL: URL(fileURLWithPath: "/tmp/p.bin"),
            state: .paused,
            completedBytes: 5_000,
            currentBytesPerSecond: 1_000_000 // Inactive state must be ignored
        )
        let completedHTTP = DownloadSnapshot(
            id: "c-http",
            url: URL(string: "https://example.com/c.bin")!,
            destinationURL: URL(fileURLWithPath: "/tmp/c.bin"),
            state: .completed,
            completedBytes: 50_000,
            currentBytesPerSecond: 800_000
        )
        let failedHTTP = DownloadSnapshot(
            id: "f-http",
            url: URL(string: "https://example.com/f.bin")!,
            destinationURL: URL(fileURLWithPath: "/tmp/f.bin"),
            state: .failed(reason: "timeout"),
            completedBytes: 1_000,
            currentBytesPerSecond: 200_000
        )
        let pendingHTTP = DownloadSnapshot(
            id: "q-http",
            url: URL(string: "https://example.com/q.bin")!,
            destinationURL: URL(fileURLWithPath: "/tmp/q.bin"),
            state: .pending,
            completedBytes: 0,
            currentBytesPerSecond: 50_000
        )

        let pausedTorrent = TorrentTask(
            source: "magnet:?xt=urn:btih:0000000000000000000000000000000000000000",
            name: "PausedT",
            savePath: URL(fileURLWithPath: "/tmp/pt"),
            state: .paused,
            progress: TorrentProgress(downloadBytesPerSecond: 900_000, uploadBytesPerSecond: 300_000),
            infoHash: "0000000000000000000000000000000000000000"
        )
        let queuedTorrent = TorrentTask(
            source: "magnet:?xt=urn:btih:1111111111111111111111111111111111111111",
            name: "QueuedT",
            savePath: URL(fileURLWithPath: "/tmp/qt"),
            state: .queued,
            progress: TorrentProgress(downloadBytesPerSecond: 100_000, uploadBytesPerSecond: 50_000),
            infoHash: "1111111111111111111111111111111111111111"
        )
        let finishedTorrent = TorrentTask(
            source: "magnet:?xt=urn:btih:2222222222222222222222222222222222222222",
            name: "FinishedT",
            savePath: URL(fileURLWithPath: "/tmp/ft"),
            state: .finished,
            progress: TorrentProgress(downloadBytesPerSecond: 50_000, uploadBytesPerSecond: 20_000),
            infoHash: "2222222222222222222222222222222222222222"
        )

        let (totalDownload, totalUpload) = DownloadManagerViewModel.computeAggregateThroughput(
            downloads: [pausedHTTP, completedHTTP, failedHTTP, pendingHTTP],
            torrents: [pausedTorrent, queuedTorrent, finishedTorrent]
        )

        XCTAssertEqual(totalDownload, 0.0, "Inactive downloads and torrents must produce exactly zero download throughput")
        XCTAssertEqual(totalUpload, 0.0, "Inactive torrents must produce exactly zero upload throughput")
    }

    // MARK: - 4. ViewModel Sampling Execution

    func testViewModelSampleBandwidthUpdatesPublishedProperties() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let downloadEngine = try DownloadEngine(storageDirectoryURL: tempDir, maxConcurrentDownloads: 2)
        let vm = await MainActor.run {
            DownloadManagerViewModel(
                engine: downloadEngine,
                downloadsDirectory: tempDir
            )
        }

        let now = Date()

        await MainActor.run {
            // Initially 0
            XCTAssertEqual(vm.currentTotalDownloadSpeed, 0.0)
            XCTAssertEqual(vm.currentTotalUploadSpeed, 0.0)

            // Inject snapshot into view model
            let active = DownloadSnapshot(
                id: "active-1",
                url: URL(string: "https://example.com/test.iso")!,
                destinationURL: tempDir.appendingPathComponent("test.iso"),
                state: .downloading,
                completedBytes: 10_000_000,
                totalBytes: 50_000_000,
                currentBytesPerSecond: 4_500_000
            )
            vm.downloads = [active]

            vm.sampleBandwidth(timestamp: now)

            XCTAssertEqual(vm.currentTotalDownloadSpeed, 4_500_000)
            XCTAssertEqual(vm.currentTotalUploadSpeed, 0.0)
            XCTAssertEqual(vm.peakDownloadSpeed, 4_500_000)
            XCTAssertEqual(vm.bandwidthHistory.count, 1)
            XCTAssertEqual(vm.bandwidthHistory.first?.downloadBytesPerSecond, 4_500_000)
        }
    }

    // MARK: - 5. SpeedChartView Component Instantiation (iOS 15 / 16 Fallback Verification)

    #if canImport(SwiftUI)
    func testSpeedChartViewInitializesWithSamples() {
        let sample1 = BandwidthSample(timestamp: 1000.0, downloadBytesPerSecond: 1_000_000, uploadBytesPerSecond: 200_000)
        let sample2 = BandwidthSample(timestamp: 1030.0, downloadBytesPerSecond: 3_000_000, uploadBytesPerSecond: 500_000)
        let sample3 = BandwidthSample(timestamp: 1060.0, downloadBytesPerSecond: 2_000_000, uploadBytesPerSecond: 300_000)

        let view = SpeedChartView(
            history: [sample1, sample2, sample3],
            currentDownloadSpeed: 2_000_000,
            currentUploadSpeed: 300_000,
            peakDownloadSpeed: 3_000_000,
            peakUploadSpeed: 500_000
        )

        XCTAssertEqual(view.history.count, 3)
        XCTAssertEqual(view.currentDownloadSpeed, 2_000_000)
        XCTAssertEqual(view.peakDownloadSpeed, 3_000_000)
    }
    #endif
}

