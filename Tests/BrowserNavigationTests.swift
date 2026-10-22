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
}
