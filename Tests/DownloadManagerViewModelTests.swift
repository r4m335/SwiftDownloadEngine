import XCTest
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

@testable import DM_Reverse_engineering

final class DownloadManagerViewModelTests: XCTestCase {
    private var server: LocalHTTPRangeServer!
    private var tempDirectory: URL!
    private var persistenceStore: DownloadPersistenceStore!
    private var coordinator: DownloadCoordinator!
    private var queueManager: DownloadQueueManager!
    private var engine: DownloadEngine!
    private var viewModel: DownloadManagerViewModel!

    override func setUp() async throws {
        try await super.setUp()
        #if os(Linux)
        signal(SIGPIPE, SIG_IGN)
        #endif

        server = LocalHTTPRangeServer()
        try server.start()

        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("1DM_UI_Tests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let storeURL = tempDirectory.appendingPathComponent("Store", isDirectory: true)
        let downloadsDir = tempDirectory.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)

        persistenceStore = try DownloadPersistenceStore(storageDirectoryURL: storeURL)
        coordinator = try DownloadCoordinator(session: .shared, persistenceStore: persistenceStore)
        queueManager = DownloadQueueManager(
            coordinator: coordinator,
            persistenceStore: persistenceStore,
            maxConcurrentDownloads: 3
        )
        engine = DownloadEngine(
            queueManager: queueManager,
            coordinator: coordinator,
            persistenceStore: persistenceStore
        )
        viewModel = await DownloadManagerViewModel(
            engine: engine,
            downloadsDirectory: downloadsDir
        )
    }

    override func tearDown() async throws {
        if let vm = viewModel {
            await vm.stopObserving()
            await vm.cancelAll(deleteFiles: false)
        }
        if let engine = engine {
            await engine.shutdown()
        }
        server?.stop()
        server = nil
        viewModel = nil
        engine = nil
        queueManager = nil
        coordinator = nil
        persistenceStore = nil

        if let temp = tempDirectory {
            try? FileManager.default.removeItem(at: temp)
        }
        try await super.tearDown()
    }

    private func makePayload(size: Int, byte: UInt8 = 0x5A) -> Data {
        Data(repeating: byte, count: size)
    }

    // MARK: - 1. Start Download From UI

    func testStartDownloadFromUI() async throws {
        let size = 64 * 1024
        let payload = makePayload(size: size, byte: 0x12)
        server.register(path: "/ui_start.bin", data: payload)

        await viewModel.startObserving()

        let urlText = server.baseURL.appendingPathComponent("ui_start.bin").absoluteString
        let snapshot = try await viewModel.addDownload(
            urlText: urlText,
            filename: "my_file.bin",
            threadCount: 4,
            autoStart: true
        )

        XCTAssertEqual(snapshot.destinationURL.lastPathComponent, "my_file.bin")
        let currentDownloads = await viewModel.downloads
        XCTAssertTrue(currentDownloads.contains { $0.id == snapshot.id })

        try await engine.waitUntilIdle(timeoutSeconds: 10.0)
        await viewModel.refreshSnapshots()

        let completedList = await viewModel.downloads
        let item = completedList.first { $0.id == snapshot.id }
        XCTAssertNotNil(item)
        XCTAssertEqual(item?.state, .completed)
        XCTAssertEqual(item?.completedBytes, Int64(size))

        // Verify file written to configured UI downloads directory
        let expectedFile = await viewModel.downloadsDirectoryURL.appendingPathComponent("my_file.bin")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedFile.path))
        let downloadedData = try Data(contentsOf: expectedFile)
        XCTAssertEqual(downloadedData, payload)
    }

    // MARK: - 2. Progress Updates and Events

    func testProgressUpdatesAndEvents() async throws {
        let size = 384 * 1024
        let payload = makePayload(size: size, byte: 0x34)
        server.register(path: "/ui_progress.bin", data: payload, chunkDelayMs: 2)

        await viewModel.startObserving()

        let urlText = server.baseURL.appendingPathComponent("ui_progress.bin").absoluteString
        let snapshot = try await viewModel.addDownload(
            urlText: urlText,
            filename: "progress.bin",
            autoStart: true
        )

        // Wait briefly for download progress to stream into viewModel
        var sawProgress = false
        for _ in 0..<50 {
            let list = await viewModel.downloads
            if let snap = list.first(where: { $0.id == snapshot.id }), snap.completedBytes > 0 {
                sawProgress = true
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(sawProgress, "ViewModel should reflect streaming progress")

        try await engine.waitUntilIdle(timeoutSeconds: 15.0)
        await viewModel.refreshSnapshots()

        let finalItem = await viewModel.downloads.first { $0.id == snapshot.id }
        XCTAssertEqual(finalItem?.state, .completed)
    }

    // MARK: - 3. Pause and Resume Workflow

    func testUIPauseAndResumeWorkflow() async throws {
        let size = 512 * 1024
        let payload = makePayload(size: size, byte: 0x77)
        server.register(path: "/ui_pause_resume.bin", data: payload, chunkDelayMs: 2)

        await viewModel.startObserving()

        let urlText = server.baseURL.appendingPathComponent("ui_pause_resume.bin").absoluteString
        let snapshot = try await viewModel.addDownload(
            urlText: urlText,
            filename: "paused.bin",
            autoStart: true
        )

        // Wait for download to be active
        for _ in 0..<50 {
            let list = await viewModel.downloads
            if let snap = list.first(where: { $0.id == snapshot.id }), snap.state == .downloading {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        // Pause via ViewModel
        try await viewModel.pauseDownload(id: snapshot.id)
        await viewModel.refreshSnapshots()

        let pausedItem = await viewModel.downloads.first { $0.id == snapshot.id }
        XCTAssertEqual(pausedItem?.state, .paused)
        XCTAssertTrue(pausedItem?.canResume ?? false)

        // Resume via ViewModel
        try await viewModel.resumeDownload(id: snapshot.id)
        try await engine.waitUntilIdle(timeoutSeconds: 15.0)
        await viewModel.refreshSnapshots()

        let completedItem = await viewModel.downloads.first { $0.id == snapshot.id }
        XCTAssertEqual(completedItem?.state, .completed)
        XCTAssertEqual(completedItem?.completedBytes, Int64(size))
    }

    // MARK: - 4. Cancellation Workflow

    func testUICancellationWorkflow() async throws {
        let size = 512 * 1024
        let payload = makePayload(size: size, byte: 0x88)
        server.register(path: "/ui_cancel.bin", data: payload, chunkDelayMs: 2)

        await viewModel.startObserving()

        let urlText = server.baseURL.appendingPathComponent("ui_cancel.bin").absoluteString
        let snapshot = try await viewModel.addDownload(
            urlText: urlText,
            filename: "cancelled.bin",
            autoStart: true
        )

        for _ in 0..<50 {
            let list = await viewModel.downloads
            if let snap = list.first(where: { $0.id == snapshot.id }), snap.state == .downloading {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        // Cancel via ViewModel
        try await viewModel.cancelDownload(id: snapshot.id, deleteFile: false)
        await viewModel.refreshSnapshots()

        let cancelledItem = await viewModel.downloads.first { $0.id == snapshot.id }
        XCTAssertEqual(cancelledItem?.state, .cancelled)
        XCTAssertTrue(cancelledItem?.isTerminal ?? false)
    }

    // MARK: - 5. Failure Display Workflow

    func testUIFailureDisplayWorkflow() async throws {
        server.register(path: "/ui_fail.bin", data: Data(), statusCodeOverride: 404)

        await viewModel.startObserving()

        let urlText = server.baseURL.appendingPathComponent("ui_fail.bin").absoluteString
        let dest = await viewModel.downloadsDirectoryURL.appendingPathComponent("fail.bin")
        let request = DownloadRequest(
            url: URL(string: urlText)!,
            destinationURL: dest,
            retryCount: 0
        )

        _ = try await engine.addDownload(request, autoStart: true)
        try await engine.waitUntilIdle(timeoutSeconds: 10.0)
        await viewModel.refreshSnapshots()

        let failedItem = await viewModel.downloads.first { $0.id == request.id }
        XCTAssertNotNil(failedItem)
        XCTAssertTrue(failedItem?.isFailed ?? false)
        XCTAssertNotNil(failedItem?.failureReason)
        XCTAssertFalse(failedItem?.failureReason?.isEmpty ?? true)
    }

    // MARK: - 6. Remove Download Workflow

    func testUIRemoveDownloadWorkflow() async throws {
        let payload = makePayload(size: 32 * 1024, byte: 0x99)
        server.register(path: "/ui_remove.bin", data: payload)

        await viewModel.startObserving()

        let urlText = server.baseURL.appendingPathComponent("ui_remove.bin").absoluteString
        let snapshot = try await viewModel.addDownload(
            urlText: urlText,
            filename: "remove_test.bin",
            autoStart: true
        )

        try await engine.waitUntilIdle(timeoutSeconds: 10.0)
        await viewModel.refreshSnapshots()

        let file = await viewModel.downloadsDirectoryURL.appendingPathComponent("remove_test.bin")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        // Remove from UI without deleting file
        try await viewModel.removeDownload(id: snapshot.id, deleteFile: false)
        await viewModel.refreshSnapshots()

        let afterRemoval = await viewModel.downloads
        XCTAssertFalse(afterRemoval.contains { $0.id == snapshot.id })
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "File should be preserved on disk")
    }

    // MARK: - 7. Restored Downloads Workflow

    func testUIRestoredDownloadsWorkflow() async throws {
        let storeURL = tempDirectory.appendingPathComponent("RestoreUIStore", isDirectory: true)
        let persistence1 = try DownloadPersistenceStore(storageDirectoryURL: storeURL)
        let coord1 = try DownloadCoordinator(session: .shared, persistenceStore: persistence1)
        let queue1 = DownloadQueueManager(coordinator: coord1, persistenceStore: persistence1, maxConcurrentDownloads: 2)
        let engine1 = DownloadEngine(queueManager: queue1, coordinator: coord1, persistenceStore: persistence1)

        let req = DownloadRequest(
            url: server.baseURL.appendingPathComponent("restored_item.bin"),
            destinationURL: tempDirectory.appendingPathComponent("restored_item.bin")
        )
        _ = try await engine1.addDownload(req, priority: .high, autoStart: false)
        await engine1.shutdown()

        // Create new engine and viewModel pointing to same storage
        let persistence2 = try DownloadPersistenceStore(storageDirectoryURL: storeURL)
        let coord2 = try DownloadCoordinator(session: .shared, persistenceStore: persistence2)
        let queue2 = DownloadQueueManager(coordinator: coord2, persistenceStore: persistence2, maxConcurrentDownloads: 2)
        let engine2 = DownloadEngine(queueManager: queue2, coordinator: coord2, persistenceStore: persistence2)
        let vm2 = await DownloadManagerViewModel(engine: engine2)

        try await vm2.restoreQueue(autoStart: false)

        let restoredList = await vm2.downloads
        XCTAssertEqual(restoredList.count, 1)
        XCTAssertEqual(restoredList.first?.id, req.id)
        XCTAssertEqual(restoredList.first?.priority, .high)

        await engine2.shutdown()
    }

    // MARK: - 8. Settings Update Workflow

    func testUISettingsUpdateWorkflow() async throws {
        try await viewModel.updateSettings(
            maxConcurrent: 5,
            maxGlobalRequests: 20,
            globalBandwidthLimit: 1_500_000
        )

        let concurrent = await viewModel.maxConcurrentDownloads
        let requests = await viewModel.maxGlobalRequests
        let bandwidth = await viewModel.globalBandwidthLimitBytesPerSecond

        XCTAssertEqual(concurrent, 5)
        XCTAssertEqual(requests, 20)
        XCTAssertEqual(bandwidth, 1_500_000)
    }

    // MARK: - 9. Filtering and Search

    func testUIFilteringAndSearch() async throws {
        let d1 = DownloadSnapshot(
            id: "1",
            url: URL(string: "https://example.com/movie.mp4")!,
            destinationURL: URL(fileURLWithPath: "/tmp/movie.mp4"),
            state: .downloading
        )
        let d2 = DownloadSnapshot(
            id: "2",
            url: URL(string: "https://example.com/archive.zip")!,
            destinationURL: URL(fileURLWithPath: "/tmp/archive.zip"),
            state: .completed
        )
        let d3 = DownloadSnapshot(
            id: "3",
            url: URL(string: "https://example.com/photo.png")!,
            destinationURL: URL(fileURLWithPath: "/tmp/photo.png"),
            state: .failed(reason: "Disk full")
        )

        await MainActor.run {
            viewModel.downloads = [d1, d2, d3]
        }

        // Test filter by text
        await MainActor.run {
            viewModel.filterText = "movie"
        }
        var filtered = await viewModel.filteredDownloads
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.id, "1")

        // Test filter by category
        await MainActor.run {
            viewModel.filterText = ""
            viewModel.selectedFilter = .completed
        }
        filtered = await viewModel.filteredDownloads
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.id, "2")

        await MainActor.run {
            viewModel.selectedFilter = .failed
        }
        filtered = await viewModel.filteredDownloads
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.id, "3")
    }

    // MARK: - 10. Selection and Details

    func testUISelectAndDeselectDownload() async throws {
        let d = DownloadSnapshot(
            id: "select_test",
            url: URL(string: "https://example.com/test.bin")!,
            destinationURL: URL(fileURLWithPath: "/tmp/test.bin"),
            state: .completed
        )

        await MainActor.run {
            viewModel.downloads = [d]
            viewModel.selectDownload(id: "select_test")
            XCTAssertEqual(viewModel.selectedDownload?.id, "select_test")

            viewModel.clearSelection()
            XCTAssertNil(viewModel.selectedDownload)
        }
    }
}
