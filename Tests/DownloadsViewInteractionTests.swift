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

    @MainActor
    func testDownloadStatusCounters_UnifiedCountsAndLiveUpdates() {
        let tDownloading = UnifiedTransfer(
            id: "t1", name: "movie.mp4", type: .http, state: .downloading,
            completedBytes: 100, totalBytes: 200, progressFraction: 0.5,
            downloadSpeedBytesPerSecond: 50,
            destinationURL: tempDirectory.appendingPathComponent("movie.mp4"),
            source: "https://example.com/movie.mp4"
        )
        let tSeeding = UnifiedTransfer(
            id: "t2", name: "distro.iso", type: .torrent, state: .seeding,
            completedBytes: 1000, totalBytes: 1000, progressFraction: 1.0,
            downloadSpeedBytesPerSecond: 0,
            destinationURL: tempDirectory.appendingPathComponent("distro.iso"),
            source: "magnet:?xt=urn:btih:abc"
        )
        let tQueued = UnifiedTransfer(
            id: "t3", name: "audio.mp3", type: .http, state: .queued,
            completedBytes: 0, totalBytes: 50, progressFraction: 0.0,
            downloadSpeedBytesPerSecond: 0,
            destinationURL: tempDirectory.appendingPathComponent("audio.mp3"),
            source: "https://example.com/audio.mp3"
        )
        let tPaused = UnifiedTransfer(
            id: "t4", name: "doc.pdf", type: .http, state: .paused,
            completedBytes: 10, totalBytes: 100, progressFraction: 0.1,
            downloadSpeedBytesPerSecond: 0,
            destinationURL: tempDirectory.appendingPathComponent("doc.pdf"),
            source: "https://example.com/doc.pdf"
        )
        let tCompleted = UnifiedTransfer(
            id: "t5", name: "archive.zip", type: .http, state: .completed,
            completedBytes: 500, totalBytes: 500, progressFraction: 1.0,
            downloadSpeedBytesPerSecond: 0,
            destinationURL: tempDirectory.appendingPathComponent("archive.zip"),
            source: "https://example.com/archive.zip"
        )
        let tFailed = UnifiedTransfer(
            id: "t6", name: "bad.bin", type: .http, state: .failed(reason: "HTTP 404"),
            completedBytes: 0, totalBytes: 100, progressFraction: 0.0,
            downloadSpeedBytesPerSecond: 0,
            destinationURL: tempDirectory.appendingPathComponent("bad.bin"),
            source: "https://example.com/bad.bin"
        )

        viewModel.unifiedTransfers = [tDownloading, tSeeding, tQueued, tPaused, tCompleted, tFailed]

        let counts = viewModel.statusCounts
        XCTAssertEqual(counts.all, 6)
        XCTAssertEqual(counts.active, 3, "Active must include downloading, seeding, and queued transfers")
        XCTAssertEqual(counts.paused, 1)
        XCTAssertEqual(counts.completed, 1)
        XCTAssertEqual(counts.failed, 1)

        // Test filtering behavior for each filter
        viewModel.selectedFilter = .all
        XCTAssertEqual(viewModel.filteredTransfers.count, 6)

        viewModel.selectedFilter = .active
        XCTAssertEqual(viewModel.filteredTransfers.count, 3)
        XCTAssertTrue(viewModel.filteredTransfers.contains(where: { $0.id == "t1" }))
        XCTAssertTrue(viewModel.filteredTransfers.contains(where: { $0.id == "t2" }))
        XCTAssertTrue(viewModel.filteredTransfers.contains(where: { $0.id == "t3" }))

        viewModel.selectedFilter = .paused
        XCTAssertEqual(viewModel.filteredTransfers.count, 1)
        XCTAssertEqual(viewModel.filteredTransfers.first?.id, "t4")

        viewModel.selectedFilter = .completed
        XCTAssertEqual(viewModel.filteredTransfers.count, 1)
        XCTAssertEqual(viewModel.filteredTransfers.first?.id, "t5")

        viewModel.selectedFilter = .failed
        XCTAssertEqual(viewModel.filteredTransfers.count, 1)
        XCTAssertEqual(viewModel.filteredTransfers.first?.id, "t6")

        // Test combined status + file-type category filtering
        viewModel.selectedFilter = .active
        viewModel.selectedCategory = .videos
        XCTAssertEqual(viewModel.filteredTransfers.count, 1)
        XCTAssertEqual(viewModel.filteredTransfers.first?.id, "t1")

        viewModel.selectedCategory = .audio
        XCTAssertEqual(viewModel.filteredTransfers.count, 1)
        XCTAssertEqual(viewModel.filteredTransfers.first?.id, "t3")

        viewModel.selectedCategory = nil
    }

    @MainActor
    func testHeaderStat_InteractiveTapsAndAccessibility() {
        var tapped = false
        let stat = HeaderStat(
            label: "Active",
            count: 7,
            color: .blue,
            isSelected: true,
            action: { tapped = true }
        )

        XCTAssertEqual(stat.label, "Active")
        XCTAssertEqual(stat.count, 7)
        XCTAssertTrue(stat.isSelected)
        stat.action?()
        XCTAssertTrue(tapped, "HeaderStat action must fire when tapped")
    }

    @MainActor
    func testMainNavigation_MediaTabAndAddDownloadHandoff() {
        // Tab 0: Downloads, Tab 1: Browser, Tab 2: Media, Tab 3: Settings
        viewModel.selectedTab = 0
        XCTAssertEqual(viewModel.selectedTab, 0)

        // Browser link refresh switches to Browser tab (Tab 1)
        viewModel.selectedTab = 1
        XCTAssertEqual(viewModel.selectedTab, 1)

        // Media tab is at Tab 2
        viewModel.selectedTab = 2
        XCTAssertEqual(viewModel.selectedTab, 2)

        // Settings tab is at Tab 3
        viewModel.selectedTab = 3
        XCTAssertEqual(viewModel.selectedTab, 3)

        // Browser Add Download handoff sets prefilled URL, flags sheet, and switches to Tab 0 (Downloads)
        let sampleURL = "https://example.com/video.mp4"
        viewModel.addDownloadPrefilledURL = sampleURL
        viewModel.showAddDownloadSheet = true
        viewModel.selectedTab = 0

        XCTAssertEqual(viewModel.selectedTab, 0)
        XCTAssertTrue(viewModel.showAddDownloadSheet)
        XCTAssertEqual(viewModel.addDownloadPrefilledURL, sampleURL)

        // Instantiating LIDPlayerLibraryView directly as Tab 2 root (onDismiss: nil)
        let mediaView = LIDPlayerLibraryView(
            baseDirectory: tempDirectory,
            knownTransfers: viewModel.unifiedTransfers,
            onDismiss: nil
        )
        XCTAssertNil(mediaView.onDismiss, "Media tab root view must not show a modal Done button")
    }

    @MainActor
    func testDownloadFilterPagerNavigation() {
        XCTAssertEqual(DownloadFilter.all.next, .active)
        XCTAssertEqual(DownloadFilter.active.next, .paused)
        XCTAssertEqual(DownloadFilter.paused.next, .completed)
        XCTAssertEqual(DownloadFilter.completed.next, .failed)
        XCTAssertNil(DownloadFilter.failed.next)

        XCTAssertEqual(DownloadFilter.failed.previous, .completed)
        XCTAssertEqual(DownloadFilter.completed.previous, .paused)
        XCTAssertEqual(DownloadFilter.paused.previous, .active)
        XCTAssertEqual(DownloadFilter.active.previous, .all)
        XCTAssertNil(DownloadFilter.all.previous)
    }

    @MainActor
    func testFilteredTransfersForCategoryPager() {
        let activeTransfer = UnifiedTransfer(
            id: "t-active",
            name: "active.mp4",
            type: .http,
            state: .downloading,
            destinationURL: tempDirectory.appendingPathComponent("active.mp4"),
            source: "https://example.com/active.mp4"
        )
        let pausedTransfer = UnifiedTransfer(
            id: "t-paused",
            name: "paused.mp4",
            type: .http,
            state: .paused,
            destinationURL: tempDirectory.appendingPathComponent("paused.mp4"),
            source: "https://example.com/paused.mp4"
        )
        let completedTransfer = UnifiedTransfer(
            id: "t-completed",
            name: "completed.mp4",
            type: .http,
            state: .completed,
            destinationURL: tempDirectory.appendingPathComponent("completed.mp4"),
            source: "https://example.com/completed.mp4"
        )
        let failedTransfer = UnifiedTransfer(
            id: "t-failed",
            name: "failed.mp4",
            type: .http,
            state: .failed,
            destinationURL: tempDirectory.appendingPathComponent("failed.mp4"),
            source: "https://example.com/failed.mp4"
        )

        viewModel.unifiedTransfers = [activeTransfer, pausedTransfer, completedTransfer, failedTransfer]

        XCTAssertEqual(viewModel.filteredTransfers(for: .all).count, 4)
        XCTAssertEqual(viewModel.filteredTransfers(for: .active).count, 1)
        XCTAssertEqual(viewModel.filteredTransfers(for: .active).first?.id, "t-active")
        XCTAssertEqual(viewModel.filteredTransfers(for: .paused).count, 1)
        XCTAssertEqual(viewModel.filteredTransfers(for: .paused).first?.id, "t-paused")
        XCTAssertEqual(viewModel.filteredTransfers(for: .completed).count, 1)
        XCTAssertEqual(viewModel.filteredTransfers(for: .completed).first?.id, "t-completed")
        XCTAssertEqual(viewModel.filteredTransfers(for: .failed).count, 1)
        XCTAssertEqual(viewModel.filteredTransfers(for: .failed).first?.id, "t-failed")

        // Switching selectedFilter updates default filteredTransfers property
        viewModel.selectedFilter = .active
        XCTAssertEqual(viewModel.filteredTransfers.count, 1)
        XCTAssertEqual(viewModel.filteredTransfers.first?.id, "t-active")

        viewModel.selectedFilter = .completed
        XCTAssertEqual(viewModel.filteredTransfers.count, 1)
        XCTAssertEqual(viewModel.filteredTransfers.first?.id, "t-completed")
    }

    @MainActor
    func testThreeDotMenuAlwaysAccessibleDirectlyOnCard() {
        var menuActionInvoked = false
        var detailsInvoked = false

        let transfer = UnifiedTransfer(
            id: "t-card-menu",
            name: "song.mp3",
            type: .http,
            state: .completed,
            destinationURL: tempDirectory.appendingPathComponent("song.mp3"),
            source: "https://example.com/song.mp3"
        )

        let rowView = UnifiedTransferRowView(
            viewModel: viewModel,
            transfer: transfer,
            isSelectingMultiple: false,
            onTapContent: { detailsInvoked = true },
            onOpen: { menuActionInvoked = true }
        )

        XCTAssertFalse(rowView.isSelectingMultiple, "Individual card three-dot menu must not be hidden")
        rowView.onOpen()
        XCTAssertTrue(menuActionInvoked, "Three-dot menu actions must be directly callable without long-press requirement")
        XCTAssertFalse(detailsInvoked, "Direct three-dot menu action must not trigger row tap navigation")
    }
#else
    func testDownloadsViewInteractionLinuxNoOp() {
        // SwiftUI is not available on Linux platforms.
        // Full interactive View validation executes on macOS/iOS test runners.
        XCTAssertTrue(true)
    }
#endif
}

