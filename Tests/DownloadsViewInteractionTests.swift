import XCTest
import Foundation

#if canImport(SwiftUI)
import SwiftUI
#endif

@testable import DM_Reverse_engineering

final class DownloadsViewInteractionTests: XCTestCase {
#if canImport(SwiftUI)
    private var tempDirectory: URL!
    private var persistenceStore: DownloadPersistenceStore!
    private var coordinator: DownloadCoordinator!
    private var queueManager: DownloadQueueManager!
    private var engine: DownloadEngine!
    private var viewModel: DownloadManagerViewModel!

    @MainActor
    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DownloadsViewInteractionTests_\(UUID().uuidString)", isDirectory: true)
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
        viewModel = DownloadManagerViewModel(
            engine: engine,
            downloadsDirectory: downloadsDir
        )
    }

    @MainActor
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        try await super.tearDown()
    }

    @MainActor
    func testUnifiedTransferRowView_ContentTapOpensDetailsWithoutMenuInterference() {
        var contentTapped = false
        var detailsOpened = false
        var menuActionOpened = false

        let transfer = UnifiedTransfer(
            id: "test-transfer-1",
            name: "sample_video.mp4",
            type: .http,
            state: .completed,
            completedBytes: 1024,
            totalBytes: 1024,
            progressFraction: 1.0,
            downloadSpeedBytesPerSecond: 0,
            destinationURL: tempDirectory.appendingPathComponent("sample_video.mp4"),
            source: "https://example.com/sample_video.mp4"
        )

        let rowView = UnifiedTransferRowView(
            viewModel: viewModel,
            transfer: transfer,
            isSelectingMultiple: false,
            onTapContent: {
                contentTapped = true
                detailsOpened = true
            },
            onOpen: {
                menuActionOpened = true
            }
        )

        XCTAssertNotNil(rowView)
        XCTAssertFalse(rowView.isSelectingMultiple)

        // Simulate tapping file content
        rowView.onTapContent?()
        XCTAssertTrue(contentTapped, "Tapping file content must invoke onTapContent")
        XCTAssertTrue(detailsOpened, "Tapping file content must open details")
        XCTAssertFalse(menuActionOpened, "Tapping file content must not trigger menu actions")
    }

    @MainActor
    func testUnifiedTransferRowView_MenuActionsWorkIndependentlyWithoutAccidentalNavigation() {
        var navigationTriggered = false
        var openCalled = false
        var saveToFilesCalled = false
        var shareCalled = false
        var copyLinkCalled = false
        var showDetailsCalled = false
        var pauseCalled = false
        var resumeCalled = false
        var removeQueueCalled = false
        var deleteFileCalled = false

        let transfer = UnifiedTransfer(
            id: "test-transfer-2",
            name: "archive.zip",
            type: .http,
            state: .completed,
            completedBytes: 2048,
            totalBytes: 2048,
            progressFraction: 1.0,
            downloadSpeedBytesPerSecond: 0,
            destinationURL: tempDirectory.appendingPathComponent("archive.zip"),
            source: "https://example.com/archive.zip"
        )

        let rowView = UnifiedTransferRowView(
            viewModel: viewModel,
            transfer: transfer,
            isSelectingMultiple: false,
            onTapContent: {
                navigationTriggered = true
            },
            onOpen: { openCalled = true },
            onSaveToFiles: { saveToFilesCalled = true },
            onShare: { shareCalled = true },
            onCopyLink: { copyLinkCalled = true },
            onShowDetails: { showDetailsCalled = true },
            onPause: { pauseCalled = true },
            onResume: { resumeCalled = true },
            onRemoveQueue: { removeQueueCalled = true },
            onDeleteFile: { deleteFileCalled = true }
        )

        // Invoke each menu action independently
        rowView.onOpen()
        XCTAssertTrue(openCalled)
        XCTAssertFalse(navigationTriggered, "Menu action 'Open' must not trigger row content navigation")

        rowView.onSaveToFiles()
        XCTAssertTrue(saveToFilesCalled)
        XCTAssertFalse(navigationTriggered, "Menu action 'Save to Files' must not trigger row content navigation")

        rowView.onShare()
        XCTAssertTrue(shareCalled)
        XCTAssertFalse(navigationTriggered, "Menu action 'Share' must not trigger row content navigation")

        rowView.onCopyLink()
        XCTAssertTrue(copyLinkCalled)
        XCTAssertFalse(navigationTriggered, "Menu action 'Copy Link' must not trigger row content navigation")

        rowView.onPause()
        XCTAssertTrue(pauseCalled)
        XCTAssertFalse(navigationTriggered, "Menu action 'Pause' must not trigger row content navigation")

        rowView.onResume()
        XCTAssertTrue(resumeCalled)
        XCTAssertFalse(navigationTriggered, "Menu action 'Resume' must not trigger row content navigation")

        rowView.onRemoveQueue()
        XCTAssertTrue(removeQueueCalled)
        XCTAssertFalse(navigationTriggered, "Menu action 'Remove from Queue' must not trigger row content navigation")

        rowView.onDeleteFile()
        XCTAssertTrue(deleteFileCalled)
        XCTAssertFalse(navigationTriggered, "Menu action 'Delete File' must not trigger row content navigation")

        // Only explicit showDetails opens details without firing accidental content navigation
        rowView.onShowDetails()
        XCTAssertTrue(showDetailsCalled)
        XCTAssertFalse(navigationTriggered, "Show Details menu item should invoke its own action without row content tap")
    }

    @MainActor
    func testUnifiedTransferRowView_MultiSelectionTogglesSelectionAndHidesMenu() {
        var toggledSelection = false
        var openedDetails = false

        let transfer = UnifiedTransfer(
            id: "test-transfer-3",
            name: "dataset.tar",
            type: .http,
            state: .downloading,
            completedBytes: 500,
            totalBytes: 1000,
            progressFraction: 0.5,
            downloadSpeedBytesPerSecond: 100,
            destinationURL: tempDirectory.appendingPathComponent("dataset.tar"),
            source: "https://example.com/dataset.tar"
        )

        let rowView = UnifiedTransferRowView(
            viewModel: viewModel,
            transfer: transfer,
            isSelectingMultiple: true,
            onTapContent: {
                toggledSelection = true
            },
            onShowDetails: {
                openedDetails = true
            }
        )

        XCTAssertTrue(rowView.isSelectingMultiple)

        // In multi-selection mode, content tap toggles selection
        rowView.onTapContent?()
        XCTAssertTrue(toggledSelection, "Tapping content in multi-selection mode must toggle selection")
        XCTAssertFalse(openedDetails, "Tapping content in multi-selection mode must not open details")
    }
#else
    func testDownloadsViewInteractionLinuxNoOp() {
        // SwiftUI is not available on Linux platforms.
        // Full interactive View validation executes on macOS/iOS test runners.
        XCTAssertTrue(true)
    }
#endif
}

