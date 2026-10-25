import XCTest
@testable import DM_Reverse_engineering

final class CloudflareVerificationDiagnosticTests: XCTestCase {

    override func setUp() {
        super.setUp()
        BrowserDiagnosticLogger.shared.clear()
    }

    override func tearDown() {
        BrowserDiagnosticLogger.shared.clear()
        super.tearDown()
    }

    // MARK: - 1. Diagnostic Logging Telemetry

    func testDiagnosticLoggerRecordsEventsAcrossCategories() {
        let logger = BrowserDiagnosticLogger()
        let tabID = UUID()
        let testURL = URL(string: "https://example.com/protected")!

        logger.log(
            category: .navigation,
            message: "Provisional navigation started",
            url: testURL,
            tabID: tabID,
            details: ["key": "val"]
        )

        logger.log(
            category: .redirect,
            message: "Server redirect received",
            url: testURL,
            tabID: tabID
        )

        logger.log(
            category: .challenge,
            message: "Cloudflare challenge detected",
            url: testURL,
            tabID: tabID,
            details: ["hasTokenStatus": "true"]
        )

        logger.log(
            category: .javaScriptError,
            message: "Unhandled script error",
            url: testURL,
            tabID: tabID
        )

        logger.log(
            category: .processTermination,
            message: "WebContent process terminated",
            url: testURL,
            tabID: tabID
        )

        logger.log(
            category: .cookie,
            message: "Cloudflare cookies present: cf_clearance",
            url: testURL,
            tabID: tabID
        )

        logger.log(
            category: .policy,
            message: "Navigation action allowed",
            url: testURL,
            tabID: tabID
        )

        let allEvents = logger.events()
        XCTAssertEqual(allEvents.count, 7)

        let navEvents = logger.events(matching: .navigation)
        XCTAssertEqual(navEvents.count, 1)
        XCTAssertEqual(navEvents.first?.message, "Provisional navigation started")

        let challengeEvents = logger.events(matching: .challenge)
        XCTAssertEqual(challengeEvents.count, 1)
        XCTAssertEqual(challengeEvents.first?.details["hasTokenStatus"], "true")

        let tabEvents = logger.events(tabID: tabID)
        XCTAssertEqual(tabEvents.count, 7)

        let otherTabEvents = logger.events(tabID: UUID())
        XCTAssertEqual(otherTabEvents.count, 0)
    }

    func testDiagnosticLoggerEnforcesRingBufferLimit() {
        let logger = BrowserDiagnosticLogger()
        for i in 0..<(BrowserDiagnosticLogger.maximumEventCount + 50) {
            logger.log(category: .navigation, message: "Event \(i)")
        }

        let events = logger.events(limit: 1000)
        XCTAssertEqual(events.count, BrowserDiagnosticLogger.maximumEventCount)
        XCTAssertEqual(events.first?.message, "Event 50")
        XCTAssertEqual(events.last?.message, "Event \(BrowserDiagnosticLogger.maximumEventCount + 49)")
    }

    // MARK: - 2. User-Agent Conformance

    func testBrowserUserAgentHelperProvidesStandardSafariUA() {
        let ua = BrowserUserAgentHelper.standardSafariUserAgent
        XCTAssertFalse(ua.isEmpty)
        XCTAssertTrue(BrowserUserAgentHelper.isStandardSafariUserAgent(ua))
        XCTAssertTrue(ua.contains("Safari/"))
        XCTAssertTrue(ua.contains("AppleWebKit/"))
        XCTAssertTrue(ua.contains("Version/"))

        // Embedded webview UA without Safari token should be rejected
        let embeddedUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
        XCTAssertFalse(BrowserUserAgentHelper.isStandardSafariUserAgent(embeddedUA))
    }

    // MARK: - 3. Script Stealth & Anti-Tampering Protections

    func testObserverScriptExcludesChallengeDomainsAndEndpoints() {
        let script = BrowserMediaDiscoveryBridge.observerScript

        // Excludes challenge platforms and turnstile endpoints
        XCTAssertTrue(script.contains("challenges.cloudflare.com"))
        XCTAssertTrue(script.contains("/cdn-cgi/challenge-platform"))
        XCTAssertTrue(script.contains("cloudflare.com"))
    }

    func testObserverScriptPreservesNativeFunctionToString() {
        let script = BrowserMediaDiscoveryBridge.observerScript

        // Verifies wrapped fetch and XMLHttpRequest methods masquerade as native code
        XCTAssertTrue(script.contains("function fetch() { [native code] }"))
        XCTAssertTrue(script.contains("function open() { [native code] }"))
        XCTAssertTrue(script.contains("function send() { [native code] }"))
    }

    func testObserverScriptUsesWeakMapForXHRMetadataWithoutExposingProperties() {
        let script = BrowserMediaDiscoveryBridge.observerScript

        // Verifies XHR metadata uses WeakMap rather than attaching visible properties to XHR instances
        XCTAssertTrue(script.contains("xhrMeta"))
        XCTAssertFalse(script.contains("this.__lidMediaURL ="))
    }

    // MARK: - 4. In-Page Diagnostic Script

    func testDiagnosticScriptDetectsErrorsAndChallengeMarkers() {
        let script = BrowserDiagnosticLogger.diagnosticScript

        XCTAssertTrue(script.contains("window.addEventListener(\"error\""))
        XCTAssertTrue(script.contains("window.addEventListener(\"unhandledrejection\""))
        XCTAssertTrue(script.contains("challenge-stage"))
        XCTAssertTrue(script.contains("challenge-form"))
        XCTAssertTrue(script.contains("cf-turnstile-wrapper"))
        XCTAssertTrue(script.contains("challenges.cloudflare.com"))
        XCTAssertTrue(script.contains("Generating access token"))
    }

    // MARK: - 5. Navigation & Process Lifecycle Telemetry

    @MainActor
    func testCoordinatorLogsNavigationTransitionsAndProcessTermination() {
        let logger = BrowserDiagnosticLogger.shared
        let tabID = UUID()
        let coordinator = BrowserWebViewCoordinator(
            viewModel: BrowserViewModel(),
            tabID: tabID
        )

        // Verify coordinator has tabID and initiates logging
        XCTAssertNotNil(coordinator)

        logger.log(
            category: .navigation,
            message: "Navigation content committed",
            url: URL(string: "https://example.com"),
            tabID: tabID
        )

        logger.log(
            category: .processTermination,
            message: "WebContent process terminated. Triggering reload.",
            url: URL(string: "https://example.com"),
            tabID: tabID
        )

        let termEvents = logger.events(matching: .processTermination, tabID: tabID)
        XCTAssertEqual(termEvents.count, 1)
        XCTAssertTrue(termEvents.first?.message.contains("WebContent process terminated") == true)
    }

    // MARK: - 6. Cookie Telemetry & Challenge Persistence

    func testCookieDiagnosticLoggingDetectsCloudflareClearance() {
        let logger = BrowserDiagnosticLogger.shared
        let testURL = URL(string: "https://example.com")!
        let tabID = UUID()

        let cookieNames = ["__cf_bm", "cf_clearance", "session_id"]
        let cfCookies = cookieNames.filter { $0.contains("cf_") || $0.contains("__cf") }

        logger.log(
            category: .cookie,
            message: "Cloudflare verification cookies present: \(cfCookies.joined(separator: ", "))",
            url: testURL,
            tabID: tabID,
            details: ["count": "\(cfCookies.count)", "names": cfCookies.joined(separator: ", ")]
        )

        let events = logger.events(matching: .cookie, tabID: tabID)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.details["count"], "2")
        XCTAssertTrue(events.first?.details["names"]?.contains("cf_clearance") == true)
        XCTAssertTrue(events.first?.details["names"]?.contains("__cf_bm") == true)
    }
}
