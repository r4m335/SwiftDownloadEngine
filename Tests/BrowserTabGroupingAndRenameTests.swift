import XCTest
@testable import DownloadEngineKit

@MainActor
final class BrowserTabGroupingAndRenameTests: XCTestCase {

    // MARK: - 1. Tab Renaming Tests

    func testTabRenamingAndDisplayNameFallback() {
        var manager = BrowserTabManager()
        let tabID = manager.createTab(select: true)

        guard var tab = manager.tab(withID: tabID) else {
            XCTFail("Tab not found")
            return
        }

        tab.title = "Default Page Title"
        tab.url = URL(string: "https://example.com")
        _ = manager.updateTab(tab)

        // Initially displayName is the page title
        XCTAssertEqual(manager.tab(withID: tabID)?.displayName, "Default Page Title")
        XCTAssertNil(manager.tab(withID: tabID)?.customTitle)

        // Rename the tab with customTitle
        let renamed = manager.renameTab(tabID, newTitle: "My Work Dashboard")
        XCTAssertTrue(renamed)
        XCTAssertEqual(manager.tab(withID: tabID)?.customTitle, "My Work Dashboard")
        XCTAssertEqual(manager.tab(withID: tabID)?.displayName, "My Work Dashboard")

        // Reset to default (empty or nil)
        manager.renameTab(tabID, newTitle: "")
        XCTAssertNil(manager.tab(withID: tabID)?.customTitle)
        XCTAssertEqual(manager.tab(withID: tabID)?.displayName, "Default Page Title")

        // Whitespace only also resets to nil
        manager.renameTab(tabID, newTitle: "   ")
        XCTAssertNil(manager.tab(withID: tabID)?.customTitle)
    }

    func testViewModelRenameTabUpdatesPageTitleAndState() {
        let viewModel = BrowserViewModel()
        let tabID = viewModel.createNewTab()

        viewModel.renameTab(tabID, newTitle: "Custom Project Tab")

        XCTAssertEqual(viewModel.activeTab?.customTitle, "Custom Project Tab")
        XCTAssertEqual(viewModel.activeTab?.displayName, "Custom Project Tab")
        XCTAssertEqual(viewModel.pageTitle, "Custom Project Tab")

        // Reset name
        viewModel.renameTab(tabID, newTitle: nil)
        XCTAssertNil(viewModel.activeTab?.customTitle)
    }

    // MARK: - 2. Tab Grouping (Drag and Drop Emulation & APIs)

    func testGroupTwoUngroupedTabsViaDragAndDrop() {
        var manager = BrowserTabManager()
        let tab1 = manager.createTab(select: false)
        let tab2 = manager.createTab(select: false)

        var t1 = manager.tab(withID: tab1)!
        t1.title = "Docs"
        _ = manager.updateTab(t1)

        var t2 = manager.tab(withID: tab2)!
        t2.title = "Reference"
        _ = manager.updateTab(t2)

        XCTAssertNil(manager.tab(withID: tab1)?.groupID)
        XCTAssertNil(manager.tab(withID: tab2)?.groupID)
        XCTAssertEqual(manager.groups.count, 0)

        // Drag tab1 onto tab2
        let groupID = manager.groupTabs(sourceTabID: tab1, targetTabID: tab2)
        XCTAssertNotNil(groupID)

        XCTAssertEqual(manager.groups.count, 1)
        let group = manager.groups.first!
        XCTAssertEqual(group.id, groupID)
        XCTAssertEqual(group.title, "Reference & Docs")
        XCTAssertEqual(manager.tab(withID: tab1)?.groupID, groupID)
        XCTAssertEqual(manager.tab(withID: tab2)?.groupID, groupID)

        let groupedTabs = manager.tabsInGroup(group.id)
        XCTAssertEqual(groupedTabs.count, 2)
        XCTAssertEqual(manager.ungroupedTabs().count, 1) // default initial tab
    }

    func testDragTabIntoExistingGroup() {
        var manager = BrowserTabManager()
        let tab1 = manager.createTab(select: false)
        let tab2 = manager.createTab(select: false)
        let tab3 = manager.createTab(select: false)

        // Form group with tab1 and tab2
        let groupID = manager.groupTabs(sourceTabID: tab1, targetTabID: tab2)!

        // Drag tab3 onto tab1 (which is already in the group)
        let resultID = manager.groupTabs(sourceTabID: tab3, targetTabID: tab1)
        XCTAssertEqual(resultID, groupID)
        XCTAssertEqual(manager.tab(withID: tab3)?.groupID, groupID)
        XCTAssertEqual(manager.groups.count, 1)
        XCTAssertEqual(manager.tabsInGroup(groupID).count, 3)
    }

    func testCannotGroupTabWithItself() {
        var manager = BrowserTabManager()
        let tabID = manager.createTab(select: true)

        let result = manager.groupTabs(sourceTabID: tabID, targetTabID: tabID)
        XCTAssertNil(result)
        XCTAssertEqual(manager.groups.count, 0)
    }

    func testRenameAndCollapseGroup() {
        var manager = BrowserTabManager()
        let group = manager.createGroup(title: "Research", colorName: "purple")

        XCTAssertEqual(group.title, "Research")
        XCTAssertFalse(group.isCollapsed)

        manager.renameGroup(group.id, newTitle: "Deep Research")
        XCTAssertEqual(manager.groups.first?.title, "Deep Research")

        manager.toggleGroupCollapse(group.id)
        XCTAssertTrue(manager.groups.first?.isCollapsed == true)

        manager.toggleGroupCollapse(group.id)
        XCTAssertFalse(manager.groups.first?.isCollapsed == true)
    }

    func testRemoveTabFromGroupAndAutoCleanup() {
        var manager = BrowserTabManager()
        let tab1 = manager.createTab(select: false)
        let tab2 = manager.createTab(select: false)

        let groupID = manager.groupTabs(sourceTabID: tab1, targetTabID: tab2)!
        XCTAssertEqual(manager.groups.count, 1)

        // Remove tab1 from group
        manager.removeTabFromGroup(tabID: tab1)
        XCTAssertNil(manager.tab(withID: tab1)?.groupID)
        XCTAssertEqual(manager.tab(withID: tab2)?.groupID, groupID)
        XCTAssertEqual(manager.groups.count, 1)

        // Remove tab2 from group -> Group is now empty and should auto-prune
        manager.removeTabFromGroup(tabID: tab2)
        XCTAssertNil(manager.tab(withID: tab2)?.groupID)
        XCTAssertEqual(manager.groups.count, 0)
    }

    func testClosingTabInGroupPrunesEmptyGroup() {
        var manager = BrowserTabManager()
        let tab1 = manager.createTab(select: false)
        let tab2 = manager.createTab(select: false)

        let groupID = manager.groupTabs(sourceTabID: tab1, targetTabID: tab2)!
        XCTAssertEqual(manager.groups.count, 1)

        manager.closeTab(tab1)
        XCTAssertEqual(manager.groups.count, 1)

        // Closing the last tab in the group prunes the group
        manager.closeTab(tab2)
        XCTAssertEqual(manager.groups.count, 0)
    }

    func testDeleteGroupWithAndWithoutClosingTabs() {
        var manager = BrowserTabManager()
        let tab1 = manager.createTab(select: false)
        let tab2 = manager.createTab(select: false)
        let groupID = manager.groupTabs(sourceTabID: tab1, targetTabID: tab2)!

        // Delete group without closing tabs (ungroup all)
        manager.deleteGroup(groupID, closeContainedTabs: false)
        XCTAssertEqual(manager.groups.count, 0)
        XCTAssertNil(manager.tab(withID: tab1)?.groupID)
        XCTAssertNil(manager.tab(withID: tab2)?.groupID)

        // Re-group and delete with closing tabs
        let group2ID = manager.groupTabs(sourceTabID: tab1, targetTabID: tab2)!
        XCTAssertEqual(manager.groups.count, 1)
        manager.deleteGroup(group2ID, closeContainedTabs: true)
        XCTAssertEqual(manager.groups.count, 0)
        XCTAssertNil(manager.tab(withID: tab1))
        XCTAssertNil(manager.tab(withID: tab2))
    }

    // MARK: - 3. Session Persistence & Backward Compatibility (v1/v2/v3)

    func testSessionStorePersistsTabGroupsAndCustomTitles() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sessionFile = tempDir.appendingPathComponent("session.json")
        let store = BrowserSessionStore(fileURL: sessionFile)

        var tab1 = BrowserTabState(url: URL(string: "https://apple.com"), title: "Apple", customTitle: "Cupertino")
        let group = BrowserTabGroup(title: "Tech Giants", colorName: "blue")
        tab1.groupID = group.id
        let tab2 = BrowserTabState(url: URL(string: "https://google.com"), title: "Google")

        store.saveSession(tabs: [tab1, tab2], groups: [group], activeTabID: tab1.id)

        guard let loaded = store.loadSession() else {
            XCTFail("Failed to load session")
            return
        }

        XCTAssertEqual(loaded.schemaVersion, 3)
        XCTAssertEqual(loaded.tabs.count, 2)
        XCTAssertEqual(loaded.groups.count, 1)
        XCTAssertEqual(loaded.groups.first?.title, "Tech Giants")

        let loadedTab1 = loaded.tabs.first(where: { $0.url?.host == "apple.com" })
        XCTAssertEqual(loadedTab1?.customTitle, "Cupertino")
        XCTAssertEqual(loadedTab1?.displayName, "Cupertino")
        XCTAssertEqual(loadedTab1?.groupID, group.id)
    }

    func testBackwardCompatibilityWithSchemaV2JSON() throws {
        // v2 JSON without groups field, groupID, or customTitle
        let json = """
        {
            "schemaVersion": 2,
            "activeTabID": "11111111-1111-1111-1111-111111111111",
            "tabs": [
                {
                    "id": "11111111-1111-1111-1111-111111111111",
                    "url": "https://example.com",
                    "title": "Example",
                    "isLoading": false,
                    "estimatedProgress": 1.0,
                    "canGoBack": false,
                    "canGoForward": false,
                    "isDesktopMode": false,
                    "isIncognito": false,
                    "createdAt": 1700000000
                }
            ],
            "savedAt": 1700000000
        }
        """

        let data = json.data(using: .utf8)!
        let session = try JSONDecoder().decode(BrowserSavedSession.self, from: data)

        XCTAssertEqual(session.tabs.count, 1)
        XCTAssertEqual(session.groups.count, 0)
        XCTAssertNil(session.tabs.first?.customTitle)
        XCTAssertNil(session.tabs.first?.groupID)
        XCTAssertEqual(session.tabs.first?.displayName, "Example")
    }

    // MARK: - 4. ViewModel Drag & Drop Grouping Forwarding

    func testViewModelGroupTabsAndUngroup() {
        let viewModel = BrowserViewModel()
        let tab1 = viewModel.createNewTab()
        let tab2 = viewModel.createNewTab()

        XCTAssertEqual(viewModel.groups.count, 0)

        // Emulate drag and drop grouping via ViewModel
        let groupID = viewModel.groupTabs(sourceTabID: tab1, targetTabID: tab2)
        XCTAssertNotNil(groupID)
        XCTAssertEqual(viewModel.groups.count, 1)
        XCTAssertEqual(viewModel.tabsInGroup(groupID!).count, 2)

        // Remove from group
        viewModel.removeTabFromGroup(tabID: tab1)
        XCTAssertEqual(viewModel.tabsInGroup(groupID!).count, 1)
        XCTAssertEqual(viewModel.ungroupedTabs().contains(where: { $0.id == tab1 }), true)
    }

    // MARK: - 5. Swipe to Close Tab (Left & Right) Policy Tests

    func testSwipeLeftOrRightToCloseTabPolicy() {
        // Swiping right past threshold triggers close
        XCTAssertTrue(BrowserTabSwipePolicy.shouldClose(translationX: 70.0, translationY: 0.0))
        XCTAssertTrue(BrowserTabSwipePolicy.shouldClose(translationX: 120.0, translationY: 10.0))

        // Swiping left past threshold triggers close
        XCTAssertTrue(BrowserTabSwipePolicy.shouldClose(translationX: -70.0, translationY: 0.0))
        XCTAssertTrue(BrowserTabSwipePolicy.shouldClose(translationX: -150.0, translationY: -5.0))

        // Swiping upward (flick up) triggers close
        XCTAssertTrue(BrowserTabSwipePolicy.shouldClose(translationX: 5.0, translationY: -80.0))

        // Subtle drags below threshold do not close
        XCTAssertFalse(BrowserTabSwipePolicy.shouldClose(translationX: 30.0, translationY: 0.0))
        XCTAssertFalse(BrowserTabSwipePolicy.shouldClose(translationX: -40.0, translationY: 5.0))
        XCTAssertFalse(BrowserTabSwipePolicy.shouldClose(translationX: 0.0, translationY: 0.0))

        // Downward drag does not close
        XCTAssertFalse(BrowserTabSwipePolicy.shouldClose(translationX: 10.0, translationY: 80.0))
    }

    func testCloseTabAfterSwipeUpdatesActiveTabAndPrunesEmptyGroup() {
        var manager = BrowserTabManager()
        let initialTab = manager.tabs[0].id
        let tab1 = manager.createTab(select: true)
        let tab2 = manager.createTab(select: false)

        let groupID = manager.groupTabs(sourceTabID: tab1, targetTabID: tab2)!
        XCTAssertEqual(manager.groups.count, 1)
        XCTAssertEqual(manager.activeTabID, tab1)

        // Simulate swipe-to-close on tab1
        let replacementID = manager.closeTab(tab1)
        XCTAssertEqual(replacementID, tab2)
        XCTAssertEqual(manager.activeTabID, tab2)
        XCTAssertEqual(manager.tabsInGroup(groupID).count, 1)
        XCTAssertEqual(manager.groups.count, 1)

        // Close last remaining tab in group -> group is automatically cleaned up
        let nextActiveID = manager.closeTab(tab2)
        XCTAssertEqual(nextActiveID, initialTab)
        XCTAssertEqual(manager.tabs.count, 1)
        XCTAssertEqual(manager.groups.count, 0)
    }
}
