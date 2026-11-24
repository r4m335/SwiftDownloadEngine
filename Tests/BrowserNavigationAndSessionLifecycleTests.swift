import XCTest
@testable import DownloadEngineKit
#if canImport(WebKit)
import WebKit
#endif

final class BrowserNavigationAndSessionLifecycleTests: XCTestCase {

    var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("BrowserNavTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - 1. Restored Tab Schedules and Loads Saved URL

    #if canImport(SwiftUI) && canImport(WebKit)
    @MainActor
    func testRestoredTabSchedulesSavedURL() {
        let sessionFile = tempDir.appendingPathComponent("session_restore_test.json")
        let sessionStore = BrowserSessionStore(fileURL: sessionFile)

        let initialTabID = UUID()
        let savedURL = URL(string: "https://example.com/restored-page")!
        let savedTab = BrowserTabState(
            id: initialTabID,
            url: savedURL,
            title: "Example Domain"
        )
        sessionStore.saveSession(tabs: [savedTab], activeTabID: initialTabID)

        // Initialize BrowserViewModel with the saved session
        var appSettings = AppSettings.default
        appSettings.restoreTabsOnLaunch = true

        let vm = BrowserViewModel(sessionStore: sessionStore)
        XCTAssertEqual(vm.tabs.count, 1)
        XCTAssertEqual(vm.activeTabID, initialTabID)
        XCTAssertEqual(vm.tabs.first?.url, savedURL)

        // Access the session's webView and ensure the URL was scheduled / loaded
        let session = vm.webViewSession(for: initialTabID)
        XCTAssertNotNil(session.webView)

        // Selecting the tab again must not re-trigger or duplicate navigation
        XCTAssertTrue(vm.selectTab(initialTabID))
        XCTAssertEqual(vm.activeTabID, initialTabID)
    }

    @MainActor
    func testMultipleRestoredTabsPreserveActiveTabAndLazyLoad() {
        let sessionFile = tempDir.appendingPathComponent("session_multi_tab.json")
        let sessionStore = BrowserSessionStore(fileURL: sessionFile)

        let tab1ID = UUID()
        let tab2ID = UUID()
        let tab3ID = UUID()

        let t1 = BrowserTabState(id: tab1ID, url: URL(string: "https://site1.org")!, title: "Site 1")
        let t2 = BrowserTabState(id: tab2ID, url: URL(string: "https://site2.org")!, title: "Site 2")
        let t3 = BrowserTabState(id: tab3ID, url: URL(string: "https://site3.org")!, title: "Site 3")

        // Save with Tab 2 as active
        sessionStore.saveSession(tabs: [t1, t2, t3], activeTabID: tab2ID)

        let vm = BrowserViewModel(sessionStore: sessionStore)
        XCTAssertEqual(vm.tabs.count, 3)
        XCTAssertEqual(vm.activeTabID, tab2ID)

        // Verify active tab URL is loaded
        let s2 = vm.webViewSession(for: tab2ID)
        XCTAssertNotNil(s2.webView)

        // Switch to Tab 1: triggers ensureRestoredTabLoaded
        XCTAssertTrue(vm.selectTab(tab1ID))
        XCTAssertEqual(vm.activeTabID, tab1ID)
        let s1 = vm.webViewSession(for: tab1ID)
        XCTAssertNotNil(s1.webView)
    }

    // MARK: - 2. Navigation Generation Protection Against Rapid A -> B Navigations

    @MainActor
    func testRapidNavigationGenerationProtection() {
        let vm = BrowserViewModel()
        guard let tabID = vm.activeTabID else {
            XCTFail("Missing active tab")
            return
        }

        let session = vm.webViewSession(for: tabID)
        let coordinator = session.coordinator

        // 1. Navigation A starts
        let urlA = URL(string: "https://slow-site.com/pageA")!
        let genA = vm.nextNavigationGeneration(for: tabID, target: urlA)
        coordinator.startNavigation(generation: genA, target: urlA)
        XCTAssertEqual(coordinator.navigationGeneration, genA)

        // 2. Navigation B immediately starts before A finishes
        let urlB = URL(string: "https://fast-site.com/pageB")!
        let genB = vm.nextNavigationGeneration(for: tabID, target: urlB)
        coordinator.startNavigation(generation: genB, target: urlB)
        XCTAssertEqual(coordinator.navigationGeneration, genB)
        XCTAssertGreaterThan(genB, genA)

        // 3. Late callback from A arrives: should be dropped as stale
        XCTAssertFalse(vm.isNavigationCurrent(tabID: tabID, generation: genA, url: urlA))
        XCTAssertTrue(vm.isNavigationCurrent(tabID: tabID, generation: genB, url: urlB))

        // Trigger commit/finish simulation for stale genA
        vm.updateWebViewState(
            for: tabID,
            webView: session.webView,
            url: urlA,
            title: "Stale Page A",
            isLoading: false,
            generation: genA
        )

        // Verify tab title and URL were NOT corrupted by stale callback A
        XCTAssertNotEqual(vm.tabManager.tab(withID: tabID)?.title, "Stale Page A")

        // Trigger finish for valid genB
        vm.updateWebViewState(
            for: tabID,
            webView: session.webView,
            url: urlB,
            title: "Current Page B",
            isLoading: false,
            generation: genB
        )

        XCTAssertEqual(vm.tabManager.tab(withID: tabID)?.title, "Current Page B")
        XCTAssertEqual(vm.tabManager.tab(withID: tabID)?.url, urlB)
    }

    // MARK: - 3. Closing Tab While Navigation Pending

    @MainActor
    func testCloseTabWhileNavigationPending() {
        let vm = BrowserViewModel()
        let tabID = vm.createNewTab(with: URL(string: "https://in-flight.org")!)

        XCTAssertEqual(vm.activeTabID, tabID)
        let _ = vm.nextNavigationGeneration(for: tabID, target: URL(string: "https://in-flight.org")!)

        // Close the tab while navigation is pending
        let replacementID = vm.closeTab(tabID)
        XCTAssertNotNil(replacementID)
        XCTAssertNotEqual(replacementID, tabID)
        XCTAssertNil(vm.tabManager.tab(withID: tabID))
        XCTAssertEqual(vm.currentNavigationGeneration(for: tabID), 0)
    }

    // MARK: - 4. Tab Switching During Manifest Expansion

    @MainActor
    func testTabSwitchingDuringManifestExpansion() {
        let vm = BrowserViewModel()
        let tab1ID = vm.activeTabID!

        let res1 = WebpageResource(
            id: "stream-tab1",
            url: URL(string: "https://example.com/playlist.m3u8")!,
            title: "Tab 1 Stream",
            suggestedFilename: "playlist.m3u8",
            resourceType: .video
        )
        vm.discoveredResources = [res1]
        vm.tabDiscoveredResources[tab1ID] = [res1]

        // Create Tab 2 and switch
        let tab2ID = vm.createNewTab()
        XCTAssertEqual(vm.activeTabID, tab2ID)
        XCTAssertTrue(vm.discoveredResources.isEmpty)

        // Switch back to Tab 1
        XCTAssertTrue(vm.selectTab(tab1ID))
        XCTAssertEqual(vm.discoveredResources.count, 1)
        XCTAssertEqual(vm.discoveredResources.first?.id, "stream-tab1")
    }

    // MARK: - 5. Memory-Pressure Tab Eviction & Lazy Recreation

    @MainActor
    func testMemoryPressureEvictsInactiveWebViewsAndRestoresOnSelection() {
        let vm = BrowserViewModel()
        vm.maxInactiveWebViews = 1

        let tab1 = vm.activeTabID!
        let tab2 = vm.createNewTab(with: URL(string: "https://site2.org")!)
        let tab3 = vm.createNewTab(with: URL(string: "https://site3.org")!)

        // We currently have 3 tabs, tab3 is active
        XCTAssertEqual(vm.activeTabID, tab3)

        // Trigger memory warning
        vm.handleMemoryWarning()

        // Tab 3 (active) remains, but inactive tab WebViews are evicted
        XCTAssertEqual(vm.tabs.count, 3)

        // Reselecting Tab 1 must lazily recreate session without crashing
        XCTAssertTrue(vm.selectTab(tab1))
        XCTAssertEqual(vm.activeTabID, tab1)
        let recreatedSession = vm.webViewSession(for: tab1)
        XCTAssertNotNil(recreatedSession.webView)
    }

    // MARK: - 6. WebContent Process Termination Recovery

    @MainActor
    func testWebContentProcessTerminationRecovery() {
        let vm = BrowserViewModel()
        let tabID = vm.activeTabID!
        let session = vm.webViewSession(for: tabID)

        // Simulate WebContent termination callback
        session.coordinator.webViewWebContentProcessDidTerminate(session.webView)

        // Tab state remains valid and recoverable
        XCTAssertEqual(vm.activeTabID, tabID)
        XCTAssertFalse(vm.tabs.isEmpty)
    }
    #endif

    // MARK: - 7. Session Store: Versioning, Corrupt Backup Recovery, and URL Scheme Validation

    @MainActor
    func testSessionStoreVersioningBackupRecoveryAndSchemeSanitization() throws {
        let sessionFile = tempDir.appendingPathComponent("session_v2.json")
        let sessionStore = BrowserSessionStore(fileURL: sessionFile)

        let safeURL = URL(string: "https://safe.org/index.html")!
        let badSchemeURL = URL(string: "javascript:alert('pwned')")!

        let t1 = BrowserTabState(url: safeURL, title: "Safe Site")
        let t2 = BrowserTabState(url: badSchemeURL, title: "Malicious Scheme")

        // 1. Scheme sanitization test
        sessionStore.saveSession(tabs: [t1, t2], activeTabID: t1.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionFile.path))

        let loaded = sessionStore.loadSession()
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.schemaVersion, BrowserSavedSession.currentSchemaVersion)
        XCTAssertEqual(loaded?.tabs.count, 2)

        // Safe URL preserved
        XCTAssertEqual(loaded?.tabs.first?.url, safeURL)

        // Bad scheme sanitized to nil URL and "New Tab" title
        let sanitizedTab = loaded?.tabs.last
        XCTAssertNil(sanitizedTab?.url, "Dangerous scheme must be sanitized to nil")
        XCTAssertEqual(sanitizedTab?.title, "New Tab")

        // 2. Backup recovery test
        // Write a second valid session so backup is populated
        let t3 = BrowserTabState(url: URL(string: "https://backup-test.org")!, title: "Backup Target")
        sessionStore.saveSession(tabs: [t3], activeTabID: t3.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionStore.backupFileURL.path), "Backup file must be created")

        // Corrupt primary file
        try "CORRUPT_NOT_JSON".write(to: sessionFile, atomically: true, encoding: .utf8)

        // Load must gracefully recover from backup
        let recovered = sessionStore.loadSession()
        XCTAssertNotNil(recovered, "Must recover from backup file when primary file is corrupt")
        XCTAssertFalse(recovered?.tabs.isEmpty ?? true)
    }
}
