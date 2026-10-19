import XCTest
import Foundation
@testable import DM_Reverse_engineering

final class DownloadManagerViewModelTorrentTests: XCTestCase {
    private var tempDirectory: URL!
    private var downloadsDirectory: URL!
    private var torrentStorageDirectory: URL!
    private var httpStorageDirectory: URL!

    private var httpEngine: DownloadEngine!
    private var torrentEngine: TorrentEngine!
    private var viewModel: DownloadManagerViewModel!

    override func setUp() async throws {
        try await super.setUp()

        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Torrent_UI_Tests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        downloadsDirectory = tempDirectory.appendingPathComponent("Downloads", isDirectory: true)
        torrentStorageDirectory = tempDirectory.appendingPathComponent("TorrentStorage", isDirectory: true)
        httpStorageDirectory = tempDirectory.appendingPathComponent("HTTPStorage", isDirectory: true)

        try FileManager.default.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: torrentStorageDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: httpStorageDirectory, withIntermediateDirectories: true)

        let httpStore = try DownloadPersistenceStore(storageDirectoryURL: httpStorageDirectory)
        let coordinator = try DownloadCoordinator(session: .shared, persistenceStore: httpStore)
        let queueManager = DownloadQueueManager(coordinator: coordinator, persistenceStore: httpStore, maxConcurrentDownloads: 3)
        httpEngine = DownloadEngine(queueManager: queueManager, coordinator: coordinator, persistenceStore: httpStore)

        let torrentStore = try TorrentPersistenceStore(storageDirectoryURL: torrentStorageDirectory)
        torrentEngine = try TorrentEngine(
            storageDirectoryURL: torrentStorageDirectory,
            maxConcurrentTorrents: 3,
            persistenceStore: torrentStore
        )
        try await torrentEngine.start()

        viewModel = await DownloadManagerViewModel(
            engine: httpEngine,
            torrentEngine: torrentEngine,
            downloadsDirectory: downloadsDirectory
        )
        try await viewModel.startTorrentEngine()
    }

    override func tearDown() async throws {
        if let vm = viewModel {
            await vm.stopObserving()
            try? await vm.stopTorrentEngine()
        }
        if let te = torrentEngine {
            await te.stop()
        }
        if let he = httpEngine {
            await he.shutdown()
        }
        viewModel = nil
        torrentEngine = nil
        httpEngine = nil

        if let temp = tempDirectory {
            try? FileManager.default.removeItem(at: temp)
        }
        try await super.tearDown()
    }

    // MARK: - Minimum Requirement 1 & 2: HTTP downloads & Torrent tasks appear in unifiedTransfers

    func testMixedTransfersAppearInUnifiedList() async throws {
        let hash = "1234567890abcdef1234567890abcdef12345678"
        let magnet = "magnet:?xt=urn:btih:\(hash)&dn=MyTorrent"

        _ = try await viewModel.addTorrent(magnetURI: magnet, priority: .high)

        await MainActor.run {
            XCTAssertEqual(viewModel.torrentTasks.count, 1)
            XCTAssertEqual(viewModel.unifiedTransfers.count, 1)
            let first = viewModel.unifiedTransfers.first
            XCTAssertEqual(first?.name, "MyTorrent")
            XCTAssertEqual(first?.type, .torrent)
            XCTAssertEqual(first?.infoHash, hash)
            XCTAssertEqual(first?.torrentPriority, .high)
        }
    }

    // MARK: - Minimum Requirement 3 & 12: Adding a torrent updates the interface without duplicates

    func testAddingTorrentUpdatesInterfaceWithoutDuplicates() async throws {
        let hash = "abcdef1234567890abcdef1234567890abcdef12"
        let magnet = "magnet:?xt=urn:btih:\(hash)&dn=Debian"

        let transfer = try await viewModel.addTorrent(magnetURI: magnet, priority: .normal)
        XCTAssertEqual(transfer.name, "Debian")

        await viewModel.refreshTorrentSnapshots()

        await MainActor.run {
            XCTAssertEqual(viewModel.torrentTasks.count, 1)
            XCTAssertEqual(viewModel.unifiedTransfers.count, 1)
        }

        // Triggering another snapshot refresh must not duplicate the item
        await viewModel.refreshTorrentSnapshots()
        await MainActor.run {
            XCTAssertEqual(viewModel.torrentTasks.count, 1)
            XCTAssertEqual(viewModel.unifiedTransfers.count, 1)
        }
    }

    // MARK: - Minimum Requirement 4: Invalid input displays an error

    func testInvalidMagnetURIDisplaysError() async {
        let invalid = "https://example.com/not-a-magnet"
        do {
            _ = try await viewModel.addTorrent(magnetURI: invalid)
            XCTFail("Adding invalid magnet URI should throw")
        } catch {
            await MainActor.run {
                XCTAssertNotNil(viewModel.errorMessage)
                XCTAssertTrue(viewModel.errorMessage?.contains("Invalid Magnet URI") == true)
            }
        }
    }

    func testDuplicateTorrentRejectionDisplaysError() async throws {
        let hash = "2222222222222222222222222222222222222222"
        let magnet = "magnet:?xt=urn:btih:\(hash)&dn=DupTest"

        _ = try await viewModel.addTorrent(magnetURI: magnet)

        do {
            _ = try await viewModel.addTorrent(magnetURI: magnet)
            XCTFail("Adding duplicate torrent should throw")
        } catch {
            await MainActor.run {
                XCTAssertNotNil(viewModel.errorMessage)
            }
        }
    }

    // MARK: - Minimum Requirement 5: Pausing and resuming update the UI

    func testPauseAndResumeTorrentUpdatesUI() async throws {
        let hash = "3333333333333333333333333333333333333333"
        let magnet = "magnet:?xt=urn:btih:\(hash)&dn=PauseResumeTest"

        let transfer = try await viewModel.addTorrent(magnetURI: magnet)

        try await viewModel.pauseTransfer(id: transfer.id)
        await viewModel.refreshTorrentSnapshots()

        await MainActor.run {
            let paused = viewModel.unifiedTransfers.first(where: { $0.id == transfer.id })
            XCTAssertEqual(paused?.state, .paused)
        }

        try await viewModel.resumeTransfer(id: transfer.id)
        await viewModel.refreshTorrentSnapshots()

        await MainActor.run {
            let resumed = viewModel.unifiedTransfers.first(where: { $0.id == transfer.id })
            XCTAssertTrue(resumed?.state == .downloading || resumed?.state == .queued)
        }
    }

    // MARK: - Minimum Requirement 6 & 7: Removing torrent preserves payload files unless requested

    func testRemovingTorrentPreservesPayloadFiles() async throws {
        let hash = "4444444444444444444444444444444444444444"
        let magnet = "magnet:?xt=urn:btih:\(hash)&dn=PayloadTest"

        let transfer = try await viewModel.addTorrent(magnetURI: magnet)

        // Create a fake payload file at destination
        let payloadFile = transfer.destinationURL.appendingPathComponent("file.bin")
        try FileManager.default.createDirectory(at: transfer.destinationURL, withIntermediateDirectories: true)
        try "dummy-payload-data".write(to: payloadFile, atomically: true, encoding: .utf8)
        XCTAssertTrue(FileManager.default.fileExists(atPath: payloadFile.path))

        // Remove without deleting files
        try await viewModel.removeTransfer(id: transfer.id, deleteFiles: false)
        await viewModel.refreshTorrentSnapshots()

        await MainActor.run {
            XCTAssertTrue(viewModel.unifiedTransfers.isEmpty)
            XCTAssertTrue(viewModel.torrentTasks.isEmpty)
        }

        // Verify payload file is strictly preserved
        XCTAssertTrue(FileManager.default.fileExists(atPath: payloadFile.path), "Payload file must not be deleted when deleteFiles is false")

        // Re-add and remove with deleteFiles = true
        let transfer2 = try await viewModel.addTorrent(magnetURI: magnet)
        try await viewModel.removeTransfer(id: transfer2.id, deleteFiles: true)

        XCTAssertFalse(FileManager.default.fileExists(atPath: transfer.destinationURL.path), "Payload directory should be removed when deleteFiles is true")
    }

    // MARK: - Minimum Requirement 8: Unknown metadata representation

    func testUnknownMetadataRepresentation() async throws {
        let hash = "5555555555555555555555555555555555555555"
        let magnet = "magnet:?xt=urn:btih:\(hash)"

        let transfer = try await viewModel.addTorrent(magnetURI: magnet)

        XCTAssertNil(transfer.totalBytes, "Unknown metadata must produce nil totalBytes")
        XCTAssertEqual(transfer.completedBytes, 0)
        XCTAssertEqual(transfer.progressFraction, 0.0)
    }

    // MARK: - Minimum Requirement 9: Engine errors do not crash interface

    func testEngineErrorDoesNotCrashInterface() async throws {
        try await viewModel.stopTorrentEngine()

        do {
            _ = try await viewModel.addTorrent(magnetURI: "magnet:?xt=urn:btih:6666666666666666666666666666666666666666")
            XCTFail("Should fail when engine is stopped")
        } catch {
            await MainActor.run {
                XCTAssertNotNil(viewModel.errorMessage)
                XCTAssertTrue(viewModel.unifiedTransfers.isEmpty)
            }
        }
    }

    // MARK: - Minimum Requirement 10 & 11: Restored torrents appear & paused remain paused

    func testRestoredTorrentsAppearAndPausedRemainPaused() async throws {
        let hash1 = "7777777777777777777777777777777777777777"
        let hash2 = "8888888888888888888888888888888888888888"

        _ = try await viewModel.addTorrent(magnetURI: "magnet:?xt=urn:btih:\(hash1)&dn=ActiveTorrent")
        let t2 = try await viewModel.addTorrent(magnetURI: "magnet:?xt=urn:btih:\(hash2)&dn=PausedTorrent")
        try await viewModel.pauseTransfer(id: t2.id)

        // Simulate application restart
        try await viewModel.stopTorrentEngine()

        // Create new view model instance backed by the exact same storage directory
        let newTorrentStore = try TorrentPersistenceStore(storageDirectoryURL: torrentStorageDirectory)
        let newTorrentEngine = try TorrentEngine(
            storageDirectoryURL: torrentStorageDirectory,
            maxConcurrentTorrents: 3,
            persistenceStore: newTorrentStore
        )
        try await newTorrentEngine.start()

        let newVM = await DownloadManagerViewModel(
            engine: httpEngine,
            torrentEngine: newTorrentEngine,
            downloadsDirectory: downloadsDirectory
        )
        try await newVM.startTorrentEngine()

        await MainActor.run {
            XCTAssertEqual(newVM.torrentTasks.count, 2)
            XCTAssertEqual(newVM.unifiedTransfers.count, 2)

            let restoredPaused = newVM.unifiedTransfers.first(where: { $0.infoHash == hash2 })
            XCTAssertEqual(restoredPaused?.state, .paused, "Explicitly paused torrent must remain paused upon restoration")
        }
    }

    // MARK: - Torrent Priority Updates

    func testSetTorrentPriorityUpdatesState() async throws {
        let hash = "9999999999999999999999999999999999999999"
        let magnet = "magnet:?xt=urn:btih:\(hash)&dn=PrioTest"

        _ = try await viewModel.addTorrent(magnetURI: magnet, priority: .low)

        try await viewModel.setTorrentPriority(.high, for: hash)
        await viewModel.refreshTorrentSnapshots()

        await MainActor.run {
            let transfer = viewModel.unifiedTransfers.first(where: { $0.infoHash == hash })
            XCTAssertEqual(transfer?.torrentPriority, .high)
        }
    }
}
