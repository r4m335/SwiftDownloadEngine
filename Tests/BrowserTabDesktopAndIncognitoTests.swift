import XCTest
@testable import DM_Reverse_engineering

final class BrowserTabDesktopAndIncognitoTests: XCTestCase {

    // MARK: - 1. Tab State Defaults & Models

    func testDefaultTabState() {
        let tab = BrowserTabState()
        XCTAssertFalse(tab.isDesktopMode, "Tab must default to mobile mode")
        XCTAssertFalse(tab.isIncognito, "Tab must default to standard persistent mode")
        XCTAssertEqual(tab.displayName, "New Tab")
    }

    func testIncognitoTabInitialization() {
        let incognitoTab = BrowserTabState(isIncognito: true)
        XCTAssertTrue(incognitoTab.isIncognito)
        XCTAssertFalse(incognitoTab.isDesktopMode)
        XCTAssertEqual(incognitoTab.displayName, "Private Tab")

        // When a host is loaded, display the host
        var loadedTab = incognitoTab
        loadedTab.url = URL(string: "https://duckduckgo.com")
        loadedTab.title = ""
        XCTAssertEqual(loadedTab.displayName, "duckduckgo.com")
    }

    func testDesktopTabInitialization() {
        let desktopTab = BrowserTabState(isDesktopMode: true)
        XCTAssertTrue(desktopTab.isDesktopMode)
        XCTAssertFalse(desktopTab.isIncognito)
        XCTAssertEqual(desktopTab.displayName, "New Tab")
    }

    // MARK: - 2. Tab Manager Creation & Selection

    func testTabManagerCreateIncognitoAndDesktopTabs() {
        var manager = BrowserTabManager()
        XCTAssertEqual(manager.tabs.count, 1)
        XCTAssertFalse(manager.activeTab?.isIncognito ?? true)
        XCTAssertFalse(manager.activeTab?.isDesktopMode ?? true)

        let incognitoID = manager.createTab(select: true, isIncognito: true)
        XCTAssertEqual(manager.tabs.count, 2)
        XCTAssertEqual(manager.activeTabID, incognitoID)
        XCTAssertTrue(manager.activeTab?.isIncognito ?? false)
        XCTAssertFalse(manager.activeTab?.isDesktopMode ?? true)

        let desktopID = manager.createTab(select: true, isDesktopMode: true)
        XCTAssertEqual(manager.tabs.count, 3)
        XCTAssertEqual(manager.activeTabID, desktopID)
        XCTAssertFalse(manager.activeTab?.isIncognito ?? true)
        XCTAssertTrue(manager.activeTab?.isDesktopMode ?? false)

        // Select the incognito tab
        XCTAssertTrue(manager.selectTab(incognitoID))
        XCTAssertEqual(manager.activeTabID, incognitoID)
        XCTAssertTrue(manager.activeTab?.isIncognito ?? false)

        // Close incognito tab
        let replacement = manager.closeTab(incognitoID)
        XCTAssertEqual(manager.tabs.count, 2)
        XCTAssertNotNil(replacement)
    }

    func testTabManagerDesktopModeUpdating() {
        var manager = BrowserTabManager()
        let id = manager.createTab()
        guard var tab = manager.tab(withID: id) else {
            XCTFail("Tab not found")
            return
        }
        XCTAssertFalse(tab.isDesktopMode)

        tab.isDesktopMode = true
        _ = manager.updateTab(tab)

        let updated = manager.tab(withID: id)
        XCTAssertTrue(updated?.isDesktopMode ?? false)
    }

    // MARK: - 3. Desktop User-Agent Format

    func testDesktopUserAgentFormat() {
        let ua = BrowserTabState.defaultDesktopUserAgent
        XCTAssertTrue(ua.contains("Macintosh"), "Desktop User-Agent must identify as a desktop Mac platform")
        XCTAssertTrue(ua.contains("Safari"), "Desktop User-Agent must identify Safari browser engine")
        XCTAssertTrue(ua.contains("AppleWebKit"), "Desktop User-Agent must identify WebKit engine")
        XCTAssertFalse(ua.contains("iPhone"), "Desktop User-Agent must not identify as iPhone")
    }

    // MARK: - 4. BrowserViewModel Tab Operations (Apple Platforms / SwiftUI)

    #if canImport(SwiftUI)
    @MainActor
    func testBrowserViewModelTabOperations() {
        let viewModel = BrowserViewModel()

        // Initial default tab
        XCTAssertFalse(viewModel.isCurrentTabIncognito)
        XCTAssertFalse(viewModel.isCurrentTabDesktopMode)

        // Create incognito tab
        let incognitoID = viewModel.createNewTab(isIncognito: true)
        XCTAssertEqual(viewModel.activeTabID, incognitoID)
        XCTAssertTrue(viewModel.isCurrentTabIncognito)
        XCTAssertFalse(viewModel.isCurrentTabDesktopMode)

        // Create standard desktop tab
        let desktopID = viewModel.createNewTab(isDesktopMode: true)
        XCTAssertEqual(viewModel.activeTabID, desktopID)
        XCTAssertFalse(viewModel.isCurrentTabIncognito)
        XCTAssertTrue(viewModel.isCurrentTabDesktopMode)

        // Switch back to incognito tab
        XCTAssertTrue(viewModel.selectTab(incognitoID))
        XCTAssertTrue(viewModel.isCurrentTabIncognito)
        XCTAssertFalse(viewModel.isCurrentTabDesktopMode)
    }

    @MainActor
    func testToggleDesktopMode() {
        let viewModel = BrowserViewModel()
        let tabID = viewModel.createNewTab(isDesktopMode: false)
        XCTAssertFalse(viewModel.isCurrentTabDesktopMode)

        // Toggle to desktop
        viewModel.toggleDesktopMode(for: tabID)
        XCTAssertTrue(viewModel.isCurrentTabDesktopMode)

        // Toggle back to mobile
        viewModel.toggleDesktopMode(for: tabID)
        XCTAssertFalse(viewModel.isCurrentTabDesktopMode)
    }

    @MainActor
    func testCloseAllIncognitoTabs() {
        let viewModel = BrowserViewModel()
        _ = viewModel.createNewTab(isIncognito: false) // standard tab 1
        _ = viewModel.createNewTab(isIncognito: true)  // private tab 1
        _ = viewModel.createNewTab(isIncognito: true)  // private tab 2

        let incognitoCount = viewModel.tabs.filter { $0.isIncognito }.count
        XCTAssertEqual(incognitoCount, 2)

        viewModel.closeAllIncognitoTabs()

        let remainingIncognitoCount = viewModel.tabs.filter { $0.isIncognito }.count
        XCTAssertEqual(remainingIncognitoCount, 0)
        XCTAssertFalse(viewModel.tabs.isEmpty)
        XCTAssertFalse(viewModel.isCurrentTabIncognito)
    }
    #endif
}
