import XCTest
@testable import DownloadEngineKit

@MainActor
final class BrowserPrivacyAndSecurityTests: XCTestCase {

    // MARK: - 1. Content Blocker Multi-List Compilation Tests

    func testAnnoyanceBlockListContainsCookieConsentAndSocialRules() throws {
        let list = ContentBlockerDefaultRules.makeAnnoyanceBlockList(whitelistedDomains: ["safe.com"])
        XCTAssertEqual(list.identifier, "lid-annoyance-blocking")
        XCTAssertFalse(list.rules.isEmpty)

        let json = try list.jsonString()
        XCTAssertTrue(json.contains("onetrust"), "Should contain OneTrust cookie banner rule")
        XCTAssertTrue(json.contains("cookie-banner") || json.contains("cookie-consent"), "Should contain cosmetic cookie notice hiding")
        XCTAssertTrue(json.contains("twitter.com") || json.contains("facebook.net"), "Should contain social tracker script rules")
        XCTAssertTrue(json.contains("safe.com"), "Should respect whitelisted domains in unless-domain trigger")
    }

    func testCookieBlockListsGenerateCorrectRules() throws {
        let thirdPartyList = ContentBlockerDefaultRules.makeThirdPartyCookieBlockList()
        XCTAssertEqual(thirdPartyList.identifier, "lid-third-party-cookies")
        XCTAssertEqual(thirdPartyList.rules.count, 1)
        XCTAssertEqual(thirdPartyList.rules.first?.action.type, .blockCookies)
        XCTAssertEqual(thirdPartyList.rules.first?.trigger.loadType, [.thirdParty])

        let allCookieList = ContentBlockerDefaultRules.makeAllCookieBlockList()
        XCTAssertEqual(allCookieList.identifier, "lid-all-cookies")
        XCTAssertEqual(allCookieList.rules.count, 1)
        XCTAssertEqual(allCookieList.rules.first?.action.type, .blockCookies)
        XCTAssertNil(allCookieList.rules.first?.trigger.loadType)
    }

    // MARK: - 2. AppSettings Schema Version 6 Migration Tests

    func testAppSettingsVersion6PrivacyFieldsAndMigration() throws {
        XCTAssertGreaterThanOrEqual(AppSettings.currentVersion, 6)

        // Verify default settings
        let defaults = AppSettings.default
        XCTAssertTrue(defaults.isAdBlockerEnabled)
        XCTAssertTrue(defaults.isTrackerBlockerEnabled)
        XCTAssertTrue(defaults.isAnnoyanceBlockerEnabled)
        XCTAssertEqual(defaults.cookiePolicy, .blockThirdParty)

        // Simulate decoding legacy JSON (version 5 lacking new privacy fields)
        let legacyJSON = """
        {
            "version": 5,
            "maxConcurrentDownloads": 4,
            "isAdBlockerEnabled": false,
            "isPopupBlockerEnabled": true
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(AppSettings.self, from: legacyJSON)
        XCTAssertEqual(decoded.maxConcurrentDownloads, 4)
        XCTAssertFalse(decoded.isAdBlockerEnabled)
        XCTAssertTrue(decoded.isTrackerBlockerEnabled, "Missing tracker blocker should fallback to true")
        XCTAssertTrue(decoded.isAnnoyanceBlockerEnabled, "Missing annoyance blocker should fallback to true")
        XCTAssertEqual(decoded.cookiePolicy, .blockThirdParty, "Missing cookie policy should fallback to blockThirdParty")
    }

    // MARK: - 3. Browser Site Permissions Store Tests

    func testBrowserSitePermissionsStoreCRUDAndPersistence() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storeURL = tempDir.appendingPathComponent("site_permissions.json")
        let store = BrowserSitePermissionsStore(storageURL: storeURL)

        XCTAssertNil(store.permission(for: "https://example.com", type: .camera))

        // Set permission
        store.setPermission(.grant, for: "https://example.com/meeting", type: .camera)
        XCTAssertEqual(store.permission(for: "example.com", type: .camera), .grant)

        store.setPermission(.deny, for: "malicious.org", type: .microphone)
        XCTAssertEqual(store.permission(for: "malicious.org", type: .microphone), .deny)

        // Query by domain
        let entries = store.entries(for: "example.com")
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.permissionType, .camera)

        // Verify persistence across new store instance
        let reloadedStore = BrowserSitePermissionsStore(storageURL: storeURL)
        XCTAssertEqual(reloadedStore.permission(for: "example.com", type: .camera), .grant)
        XCTAssertEqual(reloadedStore.permission(for: "malicious.org", type: .microphone), .deny)

        // Remove permission
        store.removePermission(for: "example.com", type: .camera)
        XCTAssertNil(store.permission(for: "example.com", type: .camera))

        // Clear all
        store.clearAll()
        XCTAssertTrue(store.allEntries.isEmpty)
    }

    // MARK: - 4. Redirect Loop Detector Tests

    func testRedirectLoopDetectorExcessiveHopsAndCyclicalLoops() {
        let detector = BrowserRedirectLoopDetector(maxHops: 5, timeWindowSeconds: 2.0)

        // Safe navigations
        let step1 = detector.recordNavigation(url: URL(string: "https://example.com/step1")!)
        XCTAssertFalse(step1.isLoopDetected)
        let step2 = detector.recordNavigation(url: URL(string: "https://example.com/step2")!)
        XCTAssertFalse(step2.isLoopDetected)

        // Reset on user navigation
        detector.reset()

        // Cyclical loop test (A -> B -> A -> B -> A)
        let urlA = URL(string: "https://site-a.com/auth")!
        let urlB = URL(string: "https://site-b.com/callback")!

        _ = detector.recordNavigation(url: urlA)
        _ = detector.recordNavigation(url: urlB)
        _ = detector.recordNavigation(url: urlA)
        _ = detector.recordNavigation(url: urlB)
        let loopAttempt = detector.recordNavigation(url: urlA)
        XCTAssertTrue(loopAttempt.isLoopDetected)
        XCTAssertNotNil(loopAttempt.reason)
        XCTAssertTrue(loopAttempt.reason?.contains("Cyclical redirect loop") == true)
    }

    // MARK: - 5. Suspicious Download Security Inspector Tests

    func testSuspiciousDownloadEvaluation() {
        // High risk dangerous executable extensions
        let exeURL = URL(string: "https://cdn.downloads.com/installer.exe")!
        let exeWarning = BrowserDownloadSecurityInspector.evaluate(url: exeURL)
        XCTAssertNotNil(exeWarning)
        XCTAssertEqual(exeWarning?.riskLevel, .high)
        XCTAssertEqual(exeWarning?.extensionName, "exe")

        let apkURL = URL(string: "https://cdn.downloads.com/malicious.apk")!
        let apkWarning = BrowserDownloadSecurityInspector.evaluate(url: apkURL)
        XCTAssertNotNil(apkWarning)
        XCTAssertEqual(apkWarning?.riskLevel, .high)

        let scriptURL = URL(string: "https://updates.com/payload.vbs")!
        let scriptWarning = BrowserDownloadSecurityInspector.evaluate(url: scriptURL)
        XCTAssertNotNil(scriptWarning)

        // Safe video download
        let mp4URL = URL(string: "https://media.org/video.mp4")!
        let mp4Warning = BrowserDownloadSecurityInspector.evaluate(url: mp4URL)
        XCTAssertNil(mp4Warning)

        // Mismatched MIME type spoofing test
        let spoofedURL = URL(string: "https://photo.org/picture.jpg")!
        let spoofedWarning = BrowserDownloadSecurityInspector.evaluate(
            url: spoofedURL,
            declaredFilename: "picture.jpg",
            mimeType: "application/x-msdownload"
        )
        XCTAssertNotNil(spoofedWarning)
        XCTAssertEqual(spoofedWarning?.riskLevel, .high)
    }

    // MARK: - 6. Certificate Decision Store Session Isolation Tests

    func testCertificateDecisionStoreSessionIsolation() {
        let store = BrowserCertificateDecisionStore.shared
        store.clearAllSessionOverrides()

        let host = "self-signed.local"
        XCTAssertFalse(store.isHostAllowedForSession(host))

        store.allowHostForSession(host)
        XCTAssertTrue(store.isHostAllowedForSession(host))
        XCTAssertTrue(store.isHostAllowedForSession("https://self-signed.local/login"))

        store.revokeHostForSession(host)
        XCTAssertFalse(store.isHostAllowedForSession(host))
    }

    // MARK: - 7. Frame-Busting Defense Script Tests

    func testFrameBustingDefenseScript() {
        let script = BrowserFrameBustingDefense.antiHijackScript
        XCTAssertFalse(script.isEmpty)
        XCTAssertTrue(script.contains("window.top !== window.self"))
        XCTAssertTrue(script.contains("onbeforeunload"))
    }
}
