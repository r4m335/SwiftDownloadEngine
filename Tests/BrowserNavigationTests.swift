import XCTest
@testable import DM_Reverse_engineering

final class BrowserNavigationTests: XCTestCase {
    func testTabManagerPreservesSelectionAndChoosesReplacementAfterClose() {
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        var manager = BrowserTabManager(initialTab: BrowserTabState(id: firstID))
        let secondID = manager.createTab()

        XCTAssertEqual(manager.activeTabID, secondID)
        XCTAssertTrue(manager.selectTab(firstID))
        XCTAssertEqual(manager.activeTabID, firstID)

        var first = manager.tab(withID: firstID)!
        first.url = URL(string: "https://example.com/first")
        first.title = "First"
        _ = manager.updateTab(first)

        XCTAssertEqual(manager.closeTab(firstID), secondID)
        XCTAssertEqual(manager.activeTabID, secondID)
        XCTAssertEqual(manager.tabs.count, 1)

        XCTAssertNil(manager.closeTab(secondID))
        XCTAssertTrue(manager.tabs.isEmpty)
        XCTAssertNil(manager.activeTabID)
    }

    func testEdgePolicyOnlyAcceptsDirectionalEdgeGestures() {
        let policy = BrowserEdgeGesturePolicy(activationWidth: 32, minimumTranslation: 60)

        XCTAssertEqual(
            policy.action(
                startX: 10,
                translationX: 80,
                containerWidth: 400,
                canGoBack: true,
                modalPresented: false
            ),
            .goBack
        )
        XCTAssertNil(policy.action(
            startX: 10,
            translationX: 80,
            containerWidth: 400,
            canGoBack: false,
            modalPresented: false
        ))
        XCTAssertEqual(
            policy.action(
                startX: 395,
                translationX: -80,
                containerWidth: 400,
                canGoBack: false,
                modalPresented: false
            ),
            .showTabSwitcher
        )
        XCTAssertNil(policy.action(
            startX: 200,
            translationX: -120,
            containerWidth: 400,
            canGoBack: true,
            modalPresented: false
        ))
        XCTAssertNil(policy.action(
            startX: 395,
            translationX: -120,
            containerWidth: 400,
            canGoBack: false,
            modalPresented: true
        ))
    }

    // MARK: - External App Detection & Prompt Permission Tests

    func testExternalAppServiceDetectionForCustomSchemesAndUniversalLinks() {
        // YouTube custom schemes
        let ytScheme1 = URL(string: "vnd.youtube:dQw4w9WgXcQ")!
        let ytResult1 = BrowserViewModel.externalAppService(for: ytScheme1)
        XCTAssertEqual(ytResult1?.serviceName, "YouTube")
        XCTAssertEqual(ytResult1?.webURL.absoluteString, "https://www.youtube.com/watch?v=dQw4w9WgXcQ")

        let ytScheme2 = URL(string: "youtube://watch?v=dQw4w9WgXcQ")!
        let ytResult2 = BrowserViewModel.externalAppService(for: ytScheme2)
        XCTAssertEqual(ytResult2?.serviceName, "YouTube")
        XCTAssertEqual(ytResult2?.webURL.absoluteString, "https://www.youtube.com/watch?v=dQw4w9WgXcQ")

        // YouTube web links
        let ytWeb1 = URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!
        let ytResult3 = BrowserViewModel.externalAppService(for: ytWeb1)
        XCTAssertEqual(ytResult3?.serviceName, "YouTube")

        let ytShort = URL(string: "https://youtu.be/dQw4w9WgXcQ")!
        let ytResult4 = BrowserViewModel.externalAppService(for: ytShort)
        XCTAssertEqual(ytResult4?.serviceName, "YouTube")
        XCTAssertEqual(ytResult4?.webURL.absoluteString, "https://www.youtube.com/watch?v=dQw4w9WgXcQ")

        // X / Twitter
        let twitterLink = URL(string: "https://twitter.com/example/status/123")!
        let twitterResult = BrowserViewModel.externalAppService(for: twitterLink)
        XCTAssertEqual(twitterResult?.serviceName, "X")

        let xLink = URL(string: "https://x.com/example")!
        let xResult = BrowserViewModel.externalAppService(for: xLink)
        XCTAssertEqual(xResult?.serviceName, "X")

        // Instagram
        let instaLink = URL(string: "https://instagram.com/p/12345")!
        let instaResult = BrowserViewModel.externalAppService(for: instaLink)
        XCTAssertEqual(instaResult?.serviceName, "Instagram")

        // Reddit
        let redditLink = URL(string: "https://reddit.com/r/apple")!
        let redditResult = BrowserViewModel.externalAppService(for: redditLink)
        XCTAssertEqual(redditResult?.serviceName, "Reddit")

        // Normal web page (not an external app)
        let normalWeb = URL(string: "https://example.com/test")!
        XCTAssertNil(BrowserViewModel.externalAppService(for: normalWeb))
    }

    #if canImport(SwiftUI)
    @MainActor
    func testBrowserViewModelExternalAppPermissionTracking() {
        let vm = BrowserViewModel()
        let ytURL = URL(string: "https://www.youtube.com/watch?v=test123")!

        XCTAssertFalse(vm.isURLAllowedInBrowser(ytURL))

        // Allowing the URL or its host allows browsing without prompts
        vm.allowURLInBrowser(ytURL)
        XCTAssertTrue(vm.isURLAllowedInBrowser(ytURL))
        XCTAssertTrue(vm.isURLAllowedInBrowser(URL(string: "https://www.youtube.com/feed/trending")!))
    }

    @MainActor
    func testTabSwitchingSwapsActiveTabState() {
        let vm = BrowserViewModel()
        let initialTabID = vm.activeTabID!

        let secondTabID = vm.createNewTab()
        XCTAssertEqual(vm.activeTabID, secondTabID)

        #if canImport(WebKit)
        let firstWebView = vm.webViewForTab(initialTabID)
        let secondWebView = vm.webViewForTab(secondTabID)
        XCTAssertNotNil(firstWebView)
        XCTAssertNotNil(secondWebView)
        XCTAssertTrue(firstWebView !== secondWebView, "Each tab must maintain its own WKWebView instance")
        #endif

        // Switch back to initial tab
        XCTAssertTrue(vm.selectTab(initialTabID))
        XCTAssertEqual(vm.activeTabID, initialTabID)

        // Switch to second tab
        XCTAssertTrue(vm.selectTab(secondTabID))
        XCTAssertEqual(vm.activeTabID, secondTabID)
    }
    #endif
}
