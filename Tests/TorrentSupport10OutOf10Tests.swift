import XCTest
import Foundation
@testable import DownloadEngineKit

#if canImport(LibTorrent)
import LibTorrent
#endif

/// Comprehensive test suite verifying all 8 material gaps for 10/10 Torrent Support:
/// 1. Background lifecycle (suspendForBackground, resumeFromBackground, isSuspended state tracking)
/// 2. Durable seeding limits (ratio calculated from real bytes, duration from seedingStartedAt, persistent isSeedingComplete)
/// 3. Session-wide and per-torrent download & upload speed limits
/// 4. Atomic ingestion & duplicate detection preventing orphaned native handles
/// 5. BitTorrent V2 (urn:btmh:) multihash & hybrid magnet link parsing and deduplication
/// 6. Torrent completion, seeding-stop, and failure notification events
/// 7. Error recovery & piece hash rechecking APIs (recheckTorrent, retryTorrent)
/// 8. Backend engine transparency (isNativeBackend flag & UI view model exposure)
final class TorrentSupport10OutOf10Tests: XCTestCase {
    var tempDirectoryURL: URL!
    var store: TorrentPersistenceStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TorrentSupport10OutOf10Tests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        store = try TorrentPersistenceStore(storageDirectoryURL: tempDirectoryURL)
    }

    override func tearDownWithError() throws {
        if let dir = tempDirectoryURL {
            try? FileManager.default.removeItem(at: dir)
        }
        try super.tearDownWithError()
    }

    // MARK: - Gap 5: BitTorrent V2 (urn:btmh:) & Hybrid Identity Parsing

    func testBitTorrentV2MultihashAndHybridParsing() {
        // Standard V1 hex hash
        let v1Hash = "0123456789abcdef0123456789abcdef01234567"
        let v1Magnet = "magnet:?xt=urn:btih:\(v1Hash)&dn=Ubuntu"
        XCTAssertEqual(TorrentMetadataParser.extractInfoHash(from: v1Magnet), v1Hash)

        // V2 SHA-256 multihash: 1220 prefix followed by 64 hex characters (32 bytes hash)
        let v2Multihash = "1220cafebabe0123456789abcdef0123456789abcdef0123456789abcdef01234567"
        let v2Magnet = "magnet:?xt=urn:btmh:\(v2Multihash)&dn=V2Torrent"
        XCTAssertEqual(TorrentMetadataParser.extractInfoHash(from: v2Magnet), v2Multihash)

        // Hybrid Magnet URI containing both V1 (btih) and V2 (btmh)
        let hybridMagnet = "magnet:?xt=urn:btih:\(v1Hash)&xt=urn:btmh:\(v2Multihash)&dn=HybridDistro"
        let hashes = TorrentMetadataParser.extractAllInfoHashes(from: hybridMagnet)
        XCTAssertEqual(hashes.v1, v1Hash)
        XCTAssertEqual(hashes.v2, v2Multihash)

        // extractInfoHash on hybrid prefers V1 for backward compatibility
        XCTAssertEqual(TorrentMetadataParser.extractInfoHash(from: hybridMagnet), v1Hash)
    }

    func testHybridMagnetDuplicateDetection() async throws {
        let scheduler = try await TorrentQueueScheduler(persistenceStore: store, maxConcurrentTorrents: 4)

        let v1Hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let v2Hash = "1220bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        let hybridMagnet = "magnet:?xt=urn:btih:\(v1Hash)&xt=urn:btmh:\(v2Hash)&dn=Hybrid1"

        // Enqueue hybrid
        _ = try await scheduler.enqueue(
            infoHash: v1Hash,
            source: hybridMagnet,
            name: "Hybrid1",
            savePath: tempDirectoryURL
        )

        // 1. Same V1 infoHash must be detected as duplicate
        let dup1 = await scheduler.isDuplicate(infoHash: v1Hash)
        XCTAssertEqual(dup1, v1Hash)

        // 2. Incoming magnet link with only V2 hash must match the enrolled hybrid's V2 identity
        let v2OnlyMagnet = "magnet:?xt=urn:btmh:\(v2Hash)&dn=Hybrid1_V2Only"
        let dup2 = await scheduler.isDuplicate(infoHash: v2Hash, source: v2OnlyMagnet)
        XCTAssertEqual(dup2, v1Hash, "V2 magnet should match previously enrolled hybrid torrent")
    }

    // MARK: - Gap 2: Durable Seeding Limits (Upload Bytes, Duration, and Persistent Completion)

    func testSeedingLimitsWithRealBytesAndElapsedDuration() async throws {
        let scheduler = try await TorrentQueueScheduler(persistenceStore: store, maxConcurrentTorrents: 2)
        let hash = "1234567890123456789012345678901234567890"

        // Ratio-based seeding: ratio limit = 1.5
        let ratioPref = SeedingPreference(mode: .ratio, targetRatio: 1.5, targetDurationSeconds: 3600)
        _ = try await scheduler.enqueue(
            infoHash: hash,
            source: "magnet:?xt=urn:btih:\(hash)",
            name: "RatioSeedTest",
            savePath: tempDirectoryURL
        )
        try await scheduler.setSeedingPreference(ratioPref, for: hash)

        // Under ratio: downloaded 1,000,000, uploaded 1,000,000 (ratio 1.0 < 1.5)
        let shouldStop1 = await scheduler.shouldStopSeeding(
            infoHash: hash,
            totalUploaded: 1_000_000,
            totalDownloaded: 1_000_000,
            elapsedSeedingSeconds: 50
        )
        XCTAssertFalse(shouldStop1, "Should not stop seeding when ratio 1.0 is below 1.5 target")

        // Exceeded ratio: downloaded 1,000,000, uploaded 1,600,000 (ratio 1.6 >= 1.5)
        let shouldStop2 = await scheduler.shouldStopSeeding(
            infoHash: hash,
            totalUploaded: 1_600_000,
            totalDownloaded: 1_000_000,
            elapsedSeedingSeconds: 50
        )
        XCTAssertTrue(shouldStop2, "Should stop seeding when ratio 1.6 meets or exceeds 1.5 target")

        // Duration-based seeding: duration limit = 60s
        let durationHash = "abcdefabcdefabcdefabcdefabcdefabcdefabcd"
        let durationPref = SeedingPreference(mode: .duration, targetRatio: 2.0, targetDurationSeconds: 60)
        _ = try await scheduler.enqueue(
            infoHash: durationHash,
            source: "magnet:?xt=urn:btih:\(durationHash)",
            name: "DurationSeedTest",
            savePath: tempDirectoryURL
        )
        try await scheduler.setSeedingPreference(durationPref, for: durationHash)

        let shouldStopDuration1 = await scheduler.shouldStopSeeding(
            infoHash: durationHash,
            totalUploaded: 100,
            totalDownloaded: 1_000,
            elapsedSeedingSeconds: 30
        )
        XCTAssertFalse(shouldStopDuration1, "Should not stop when 30s < 60s target")

        let shouldStopDuration2 = await scheduler.shouldStopSeeding(
            infoHash: durationHash,
            totalUploaded: 100,
            totalDownloaded: 1_000,
            elapsedSeedingSeconds: 65
        )
        XCTAssertTrue(shouldStopDuration2, "Should stop when elapsed duration 65s >= 60s target")

        // Persistent seeding completion: once marked complete, it stays complete
        try await scheduler.markSeedingComplete(infoHash: durationHash)
        let rec = await scheduler.record(for: durationHash)
        XCTAssertTrue(rec?.isSeedingComplete == true)

        // Subsequent query with 0 elapsed time must still return true immediately
        let shouldStopPersistent = await scheduler.shouldStopSeeding(
            infoHash: durationHash,
            totalUploaded: 0,
            totalDownloaded: 1_000,
            elapsedSeedingSeconds: 0
        )
        XCTAssertTrue(shouldStopPersistent, "Persistent isSeedingComplete must immediately stop seeding")
    }

    // MARK: - Gap 3: Global Session and Per-Torrent Download/Upload Rate Limits

    func testRateLimitsEngineAndConfiguration() async throws {
        var config = EngineConfiguration.default
        config.torrentDownloadRateLimit = 500_000 // 500 KB/s
        config.torrentUploadRateLimit = 100_000   // 100 KB/s

        let engine = try TorrentEngine(
            configuration: config,
            storageDirectoryURL: tempDirectoryURL,
            persistenceStore: store
        )
        try await engine.start()

        // Verify session limits applied from configuration
        let dlLimit = await engine.sessionDownloadLimit()
        let ulLimit = await engine.sessionUploadLimit()
        XCTAssertEqual(dlLimit, 500_000)
        XCTAssertEqual(ulLimit, 100_000)

        // Update session limits dynamically
        try await engine.setSessionDownloadLimit(1_000_000)
        try await engine.setSessionUploadLimit(250_000)
        let sDl = await engine.sessionDownloadLimit()
        let sUl = await engine.sessionUploadLimit()
        XCTAssertEqual(sDl, 1_000_000)
        XCTAssertEqual(sUl, 250_000)

        // Add a torrent and set per-torrent rate limits
        let hash = "4444444444444444444444444444444444444444"
        _ = try await engine.addTorrent(
            magnetURI: "magnet:?xt=urn:btih:\(hash)&dn=SpeedLimitTest"
        )
        let initialDl = await engine.downloadLimit(for: hash)
        let initialUl = await engine.uploadLimit(for: hash)
        XCTAssertEqual(initialDl, 0)
        XCTAssertEqual(initialUl, 0)

        try await engine.setDownloadLimit(350_000, for: hash)
        try await engine.setUploadLimit(75_000, for: hash)
        let updatedDl = await engine.downloadLimit(for: hash)
        let updatedUl = await engine.uploadLimit(for: hash)
        XCTAssertEqual(updatedDl, 350_000)
        XCTAssertEqual(updatedUl, 75_000)

        let updatedTask = await engine.task(for: hash)
        XCTAssertEqual(updatedTask?.downloadLimit, 350_000)
        XCTAssertEqual(updatedTask?.uploadLimit, 75_000)

        await engine.stop()
    }

    // MARK: - Gap 1: Background Lifecycle & Suspension

    func testBackgroundSuspensionAndResume() async throws {
        let engine = try TorrentEngine(
            storageDirectoryURL: tempDirectoryURL,
            persistenceStore: store
        )
        try await engine.start()

        let hash = "5555555555555555555555555555555555555555"
        _ = try await engine.addTorrent(
            magnetURI: "magnet:?xt=urn:btih:\(hash)&dn=BackgroundTest"
        )

        let initialSuspended = await engine.isSuspended
        XCTAssertFalse(initialSuspended)

        // Suspend for background (simulating iOS expiration handler)
        await engine.suspendForBackground()
        let suspended = await engine.isSuspended
        XCTAssertTrue(suspended)

        let suspendedTask = await engine.task(for: hash)
        XCTAssertTrue(suspendedTask?.isSuspended == true)

        // Resume from background on app return to foreground
        await engine.resumeFromBackground()
        let resumed = await engine.isSuspended
        XCTAssertFalse(resumed)

        let resumedTask = await engine.task(for: hash)
        XCTAssertFalse(resumedTask?.isSuspended == true)
        XCTAssertEqual(resumedTask?.infoHash, hash)

        await engine.stop()
    }

    // MARK: - Gap 4: Atomic Ingestion & Duplicate Pre-check

    func testAtomicIngestionPreventsDuplicates() async throws {
        let engine = try TorrentEngine(
            storageDirectoryURL: tempDirectoryURL,
            persistenceStore: store
        )
        try await engine.start()

        let hash = "6666666666666666666666666666666666666666"
        let magnet = "magnet:?xt=urn:btih:\(hash)&dn=AtomicTest"

        _ = try await engine.addTorrent(magnetURI: magnet)

        // Attempting to add the identical torrent again must throw duplicateTorrent
        do {
            _ = try await engine.addTorrent(magnetURI: magnet)
            XCTFail("Re-adding identical magnet should throw duplicateTorrent")
        } catch let err as TorrentEngineError {
            switch err {
            case .duplicateTorrent(let dupHash):
                XCTAssertEqual(dupHash.lowercased(), hash.lowercased())
            default:
                XCTFail("Expected duplicateTorrent error, got \(err)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        await engine.stop()
    }

    // MARK: - Gap 7: Error Recovery (recheckTorrent and retryTorrent)

    func testErrorRecoveryRecheckAndRetry() async throws {
        let engine = try TorrentEngine(
            storageDirectoryURL: tempDirectoryURL,
            persistenceStore: store
        )
        try await engine.start()

        let hash = "7777777777777777777777777777777777777777"
        _ = try await engine.addTorrent(magnetURI: "magnet:?xt=urn:btih:\(hash)&dn=RecoveryTest")

        // Recheck clears error and marks task as checking
        try await engine.recheckTorrent(withHash: hash)
        let checkedTask = await engine.task(for: hash)
        XCTAssertNil(checkedTask?.errorMessage)

        // Retry clears error and re-enqueues into scheduler
        try await engine.retryTorrent(withHash: hash)
        let retriedTask = await engine.task(for: hash)
        XCTAssertNil(retriedTask?.errorMessage)

        await engine.stop()
    }

    // MARK: - Gap 6: Completion, Seeding-Stop, and Failure Notifications

    func testTorrentNotificationEvents() {
        let expComplete = expectation(description: "Completion notification received")
        let expSeedingStop = expectation(description: "Seeding stopped notification received")
        let expFailed = expectation(description: "Failure notification received")

        let tokenComplete = NotificationCenter.default.addObserver(
            forName: DownloadNotificationManager.torrentDidCompleteNotification,
            object: nil,
            queue: .main
        ) { notif in
            XCTAssertEqual(notif.userInfo?[DownloadNotificationManager.torrentNameUserInfoKey] as? String, "Linux ISO")
            XCTAssertEqual(notif.userInfo?[DownloadNotificationManager.torrentInfoHashUserInfoKey] as? String, "test-hash-1")
            expComplete.fulfill()
        }

        let tokenSeedingStop = NotificationCenter.default.addObserver(
            forName: DownloadNotificationManager.torrentSeedingDidStopNotification,
            object: nil,
            queue: .main
        ) { notif in
            XCTAssertEqual(notif.userInfo?[DownloadNotificationManager.torrentNameUserInfoKey] as? String, "Linux ISO")
            XCTAssertEqual(notif.userInfo?[DownloadNotificationManager.torrentReasonUserInfoKey] as? String, "Ratio reached")
            expSeedingStop.fulfill()
        }

        let tokenFailed = NotificationCenter.default.addObserver(
            forName: DownloadNotificationManager.torrentDidFailNotification,
            object: nil,
            queue: .main
        ) { notif in
            XCTAssertEqual(notif.userInfo?[DownloadNotificationManager.torrentNameUserInfoKey] as? String, "Linux ISO")
            XCTAssertEqual(notif.userInfo?[DownloadNotificationManager.torrentErrorUserInfoKey] as? String, "Tracker timeout")
            expFailed.fulfill()
        }

        defer {
            NotificationCenter.default.removeObserver(tokenComplete)
            NotificationCenter.default.removeObserver(tokenSeedingStop)
            NotificationCenter.default.removeObserver(tokenFailed)
        }

        DownloadNotificationManager.postTorrentCompletedNotification(name: "Linux ISO", infoHash: "test-hash-1")
        DownloadNotificationManager.postTorrentSeedingStoppedNotification(name: "Linux ISO", infoHash: "test-hash-1", reason: "Ratio reached")
        DownloadNotificationManager.postTorrentFailedNotification(name: "Linux ISO", infoHash: "test-hash-1", error: "Tracker timeout")

        wait(for: [expComplete, expSeedingStop, expFailed], timeout: 2.0)
    }

    // MARK: - Gap 8: Backend Engine Transparency

    func testBackendTransparencyFlags() async throws {
        let engine = try TorrentEngine(
            storageDirectoryURL: tempDirectoryURL,
            persistenceStore: store
        )
        let status = await engine.status()

        #if canImport(LibTorrent)
        XCTAssertTrue(TorrentEngine.isNativeBackendAvailable)
        XCTAssertTrue(status.isNativeBackend)
        #else
        XCTAssertFalse(TorrentEngine.isNativeBackendAvailable)
        XCTAssertFalse(status.isNativeBackend)
        #endif
    }
}
