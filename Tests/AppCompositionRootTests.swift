import XCTest
@testable import DM_Reverse_engineering

@MainActor
final class AppCompositionRootTests: XCTestCase {

    private var tempDirectoryA: URL!
    private var tempDirectoryB: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let fm = FileManager.default
        tempDirectoryA = fm.temporaryDirectory.appendingPathComponent("CompositionRootTests_A_\(UUID().uuidString)")
        tempDirectoryB = fm.temporaryDirectory.appendingPathComponent("CompositionRootTests_B_\(UUID().uuidString)")
        try fm.createDirectory(at: tempDirectoryA, withIntermediateDirectories: true)
        try fm.createDirectory(at: tempDirectoryB, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        let fm = FileManager.default
        try? fm.removeItem(at: tempDirectoryA)
        try? fm.removeItem(at: tempDirectoryB)
        try super.tearDownWithError()
    }

    // MARK: - 1. Isolated Sandbox Creation

    func testAppCompositionRoot_IsolatedSandboxCreation() throws {
        let root = try AppCompositionRoot.isolatedForTesting(rootDirectory: tempDirectoryA)

        XCTAssertEqual(root.baseStorageDirectory, tempDirectoryA.appendingPathComponent("Storage", isDirectory: true))
        XCTAssertEqual(root.downloadsDirectory, tempDirectoryA.appendingPathComponent("Downloads", isDirectory: true))
        XCTAssertNotNil(root.downloadEngine)
        XCTAssertNotNil(root.downloadCoordinator)
        XCTAssertNotNil(root.streamingOrchestrator)
        XCTAssertNotNil(root.bookmarkStore)
        XCTAssertNotNil(root.historyStore)
        XCTAssertNotNil(root.sessionStore)
        XCTAssertNotNil(root.sitePermissionsStore)
        XCTAssertNotNil(root.quickAccessStore)
        XCTAssertNotNil(root.playbackEngine)
        XCTAssertNotNil(root.libraryStore)
    }

    // MARK: - 2. Complete Test Isolation Between Instances

    func testAppCompositionRoot_CompleteTestIsolation() throws {
        let defaultsA = UserDefaults(suiteName: "Suite_A_\(UUID().uuidString)")!
        let defaultsB = UserDefaults(suiteName: "Suite_B_\(UUID().uuidString)")!

        let rootA = try AppCompositionRoot.isolatedForTesting(rootDirectory: tempDirectoryA, userDefaults: defaultsA)
        let rootB = try AppCompositionRoot.isolatedForTesting(rootDirectory: tempDirectoryB, userDefaults: defaultsB)

        // Mutate Root A Bookmarks
        let bookmarkURL = URL(string: "https://isolated-a.example/page")!
        let addedBookmark = rootA.bookmarkStore.addBookmark(title: "Root A Exclusive", url: bookmarkURL)
        XCTAssertNotNil(addedBookmark)

        // Mutate Root A History
        rootA.historyStore.recordVisit(url: bookmarkURL, title: "Root A Visit", isIncognito: false)

        // Mutate Root A Quick Access
        rootA.quickAccessStore.add(name: "Shortcut A", url: bookmarkURL)

        // Verify Root B is completely unpolluted
        let rootBBookmarks = rootB.bookmarkStore.allBookmarks
        XCTAssertFalse(rootBBookmarks.contains(where: { $0.url == bookmarkURL }))

        let rootBHistory = rootB.historyStore.allEntries
        XCTAssertFalse(rootBHistory.contains(where: { $0.url == bookmarkURL }))

        let rootBShortcuts = rootB.quickAccessStore.load()
        XCTAssertFalse(rootBShortcuts.contains(where: { $0.url == bookmarkURL }))
    }

    // MARK: - 3. View Model Initialization Order & Orchestrator Injection

    @MainActor
    func testAppCompositionRoot_ViewModelInitializationOrder() throws {
        let root = try AppCompositionRoot.isolatedForTesting(rootDirectory: tempDirectoryA)

        // Save current global shared value before test
        let priorShared = StreamingDownloadOrchestrator.shared

        // Construct viewModel through the composition root
        let viewModel = root.makeDownloadManagerViewModel()

        // Verify that the viewModel received the root's orchestrator immediately upon init
        XCTAssertNotNil(viewModel.streamingOrchestrator)
        XCTAssertTrue(viewModel.streamingOrchestrator === root.streamingOrchestrator)

        // Verify that the recoveryManager also received the orchestrator
        XCTAssertNotNil(viewModel.recoveryManager.streamingOrchestrator)
        XCTAssertTrue(viewModel.recoveryManager.streamingOrchestrator === root.streamingOrchestrator)

        // Verify that creating the viewModel DID NOT overwrite or pollute the global shared variable
        XCTAssertTrue(StreamingDownloadOrchestrator.shared === priorShared)
    }

    // MARK: - 4. BrowserViewModel Dependency Injection

    @MainActor
    func testAppCompositionRoot_BrowserViewModelInjection() throws {
        let root = try AppCompositionRoot.isolatedForTesting(rootDirectory: tempDirectoryA)

        let browserVM = root.makeBrowserViewModel()

        // Verify injected stores match the composition root
        XCTAssertTrue(browserVM.bookmarkStore === root.bookmarkStore)
        XCTAssertTrue(browserVM.historyStore === root.historyStore)
        XCTAssertTrue(browserVM.sitePermissionsStore === root.sitePermissionsStore)
        XCTAssertTrue(browserVM.quickAccessStore === root.quickAccessStore)
        XCTAssertTrue(browserVM.streamingOrchestrator === root.streamingOrchestrator)

        // Mutate through browser view model
        let newURL = URL(string: "https://swift-injected.example")!
        browserVM.addQuickAccessShortcut(name: "Swift Injected", url: newURL)

        // Verify root's quickAccessStore reflects change
        XCTAssertTrue(root.quickAccessStore.load().contains(where: { $0.url == newURL }))
    }

    // MARK: - 5. Live Production Composition Root Sanity

    func testAppCompositionRoot_LiveProductionSanity() {
        let liveRoot = AppCompositionRoot.live(
            storageDirectory: tempDirectoryA,
            downloadsDirectory: tempDirectoryB
        )

        XCTAssertNotNil(liveRoot.downloadEngine)
        XCTAssertNotNil(liveRoot.streamingOrchestrator)
        XCTAssertNotNil(liveRoot.downloadCoordinator)
        XCTAssertNotNil(liveRoot.bookmarkStore)
        XCTAssertNotNil(liveRoot.playbackEngine)
    }
}
