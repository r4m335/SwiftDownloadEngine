import XCTest
@testable import DownloadEngineKit

#if canImport(SwiftUI)
import SwiftUI

final class L10nAndAccessibilityTests: XCTestCase {
    func testL10nFormattingAndFallback() {
        XCTAssertEqual(L10n.tr("Downloads"), "Downloads")
        XCTAssertEqual(L10n.tr("Tabs (%d open)", 3), "Tabs (3 open)")
        XCTAssertEqual(L10n.tr("%@, %d downloads", "Active", 5), "Active, 5 downloads")
    }

    func testScaledSystemFontModifierConstructsCleanly() {
        let view = Text("Dynamic").scaledFont(size: 14, weight: .semibold, design: .rounded, relativeTo: .subheadline)
        XCTAssertNotNil(view)
    }
}
#endif
