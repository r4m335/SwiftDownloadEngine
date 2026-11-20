import XCTest
@testable import SwiftDownloadEngine

@MainActor
final class BrowserReaderAndExperienceTests: XCTestCase {

    // MARK: - 1. AppSettings Version 7 Migration & Reader Settings

    func testAppSettingsVersion7MigrationAndReaderPreferences() throws {
        XCTAssertGreaterThanOrEqual(AppSettings.currentVersion, 7)
        let defaultSettings = AppSettings.default
        XCTAssertEqual(defaultSettings.version, AppSettings.currentVersion)
        XCTAssertEqual(defaultSettings.browserHomepage, "https://duckduckgo.com")
        XCTAssertTrue(defaultSettings.restoreTabsOnLaunch)
        XCTAssertEqual(defaultSettings.readerTheme, BrowserReaderTheme.light)
        XCTAssertEqual(defaultSettings.readerFontFamily, BrowserReaderFontFamily.serif)
        XCTAssertEqual(defaultSettings.readerFontSize, 18.0)

        // Backward compatibility: Test decoding a v6 JSON missing B.3 fields
        let v6JSON = """
        {
            "version": 6,
            "maxConcurrentDownloads": 4,
            "maxGlobalRequests": 16,
            "timeoutSeconds": 45,
            "duplicateNamingRule": "Auto-rename with index",
            "allowCellular": true,
            "enableGlobalSpeedLimit": false,
            "globalSpeedLimitKBps": 1024,
            "maxConcurrentTorrents": 2,
            "defaultTorrentPriority": 2,
            "seedingMode": "Stop at Ratio",
            "targetRatio": 1.5,
            "targetDurationMinutes": 30,
            "isAdBlockerEnabled": true,
            "isTrackerBlockerEnabled": true,
            "isAnnoyanceBlockerEnabled": true,
            "cookiePolicy": "blockThirdParty",
            "isPopupBlockerEnabled": true,
            "adBlockerWhitelistedDomains": ["trusted.com"],
            "isAutomaticCategorizationEnabled": true,
            "customCategoryFolders": {},
            "downloadSortOrder": "nameAsc",
            "browserSearchEngine": "Brave"
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(AppSettings.self, from: v6JSON)
        XCTAssertEqual(decoded.version, 6)
        XCTAssertEqual(decoded.browserSearchEngine, BrowserSearchEngine.brave)
        // Verify default fallbacks for B.3 fields
        XCTAssertEqual(decoded.browserHomepage, "https://duckduckgo.com")
        XCTAssertTrue(decoded.restoreTabsOnLaunch)
        XCTAssertEqual(decoded.readerTheme, BrowserReaderTheme.light)
        XCTAssertEqual(decoded.readerFontFamily, BrowserReaderFontFamily.serif)
        XCTAssertEqual(decoded.readerFontSize, 18.0)
    }

    // MARK: - 2. Browser Session Store & Strict Incognito Exclusion Invariant

    func testBrowserSessionStorePersistenceAndIncognitoExclusion() {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_browser_session_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let store = BrowserSessionStore(fileURL: tempURL)

        let tab1 = BrowserTabState(
            id: UUID(),
            url: URL(string: "https://swift.org")!,
            title: "Swift.org",
            isDesktopMode: false,
            isIncognito: false
        )
        let tab2 = BrowserTabState(
            id: UUID(),
            url: URL(string: "https://github.com")!,
            title: "GitHub",
            isDesktopMode: true,
            isIncognito: false
        )
        let privateTab = BrowserTabState(
            id: UUID(),
            url: URL(string: "https://private-search.com")!,
            title: "Private Search",
            isDesktopMode: false,
            isIncognito: true
        )

        // Save session with 2 regular tabs and 1 private tab
        store.saveSession(tabs: [tab1, privateTab, tab2], activeTabID: privateTab.id)

        // Load saved session
        guard let restored = store.loadSession() else {
            XCTFail("Expected session to be restored successfully")
            return
        }

        // Strict invariant check: Private tab MUST NOT be persisted
        XCTAssertEqual(restored.tabs.count, 2)
        XCTAssertFalse(restored.tabs.contains(where: { $0.isIncognito }))
        XCTAssertTrue(restored.tabs.contains(where: { $0.id == tab1.id }))
        XCTAssertTrue(restored.tabs.contains(where: { $0.id == tab2.id }))
        XCTAssertFalse(restored.tabs.contains(where: { $0.id == privateTab.id }))

        // Active tab should safely fall back to the first non-incognito tab
        XCTAssertEqual(restored.activeTabID, tab1.id)

        // Clear session
        store.clearSession()
        XCTAssertNil(store.loadSession())
    }

    // MARK: - 3. Browser Reader Extractor Article Parsing

    func testBrowserReaderExtractorArticleParsing() {
        let validPayload: [String: Any] = [
            "success": true,
            "title": "Understanding Modern Swift Concurrency",
            "byline": "Jane Doe",
            "siteName": "Swift Blog",
            "publishDate": "2026-11-14",
            "contentHTML": "<p>Swift concurrency provides structured, safe async code execution.</p>",
            "plainText": "Swift concurrency provides structured, safe async code execution.",
            "wordCount": 420,
            "readingTimeMinutes": 2
        ]

        let sourceURL = URL(string: "https://developer.example.com/articles/swift-concurrency")!
        let article = BrowserReaderExtractor.parseExtraction(jsonDict: validPayload, sourceURL: sourceURL)

        XCTAssertNotNil(article)
        XCTAssertEqual(article?.title, "Understanding Modern Swift Concurrency")
        XCTAssertEqual(article?.byline, "Jane Doe")
        XCTAssertEqual(article?.siteName, "Swift Blog")
        XCTAssertEqual(article?.readingTimeMinutes, 2)
        XCTAssertEqual(article?.sourceURL, sourceURL)
        XCTAssertTrue(article?.contentHTML.contains("<p>Swift concurrency") == true)

        // Failed extraction payload
        let failedPayload: [String: Any] = [
            "success": false,
            "reason": "Page content is too brief for Reader Mode."
        ]
        let failedArticle = BrowserReaderExtractor.parseExtraction(jsonDict: failedPayload, sourceURL: sourceURL)
        XCTAssertNil(failedArticle)
    }

    // MARK: - 4. Browser Reader HTML Generation & Theme Customizations

    func testBrowserReaderHTMLGenerationAndThemes() {
        let article = BrowserReaderArticle(
            title: "Test Article Title",
            byline: "John Appleseed",
            siteName: "Example News",
            publishDate: "2026-11-14",
            readingTimeMinutes: 3,
            contentHTML: "<p>Paragraph 1</p><p>Paragraph 2</p>",
            sourceURL: URL(string: "https://example.com/article")
        )

        // Test Light Theme + Serif Font
        let lightSettings = BrowserReaderSettings(
            theme: .light,
            fontFamily: .serif,
            fontSize: 20.0
        )
        let lightHTML = BrowserReaderExtractor.generateReaderHTML(article: article, settings: lightSettings)
        XCTAssertTrue(lightHTML.contains("--bg-color: #ffffff;"))
        XCTAssertTrue(lightHTML.contains("--text-color: #1a1a1a;"))
        XCTAssertTrue(lightHTML.contains("Georgia, Cambria"))
        XCTAssertTrue(lightHTML.contains("--font-size: 20.0px;"))
        XCTAssertTrue(lightHTML.contains("Test Article Title"))
        XCTAssertTrue(lightHTML.contains("By John Appleseed"))
        XCTAssertTrue(lightHTML.contains("3 min read"))

        // Test Sepia Theme + Sans-Serif Font
        let sepiaSettings = BrowserReaderSettings(
            theme: .sepia,
            fontFamily: .sansSerif,
            fontSize: 16.0
        )
        let sepiaHTML = BrowserReaderExtractor.generateReaderHTML(article: article, settings: sepiaSettings)
        XCTAssertTrue(sepiaHTML.contains("--bg-color: #fbf0d9;"))
        XCTAssertTrue(sepiaHTML.contains("--text-color: #5f4b32;"))
        XCTAssertTrue(sepiaHTML.contains("-apple-system"))

        // Test Dark Theme + Monospace Font
        let darkSettings = BrowserReaderSettings(
            theme: .dark,
            fontFamily: .monospace,
            fontSize: 18.0
        )
        let darkHTML = BrowserReaderExtractor.generateReaderHTML(article: article, settings: darkSettings)
        XCTAssertTrue(darkHTML.contains("--bg-color: #121212;"))
        XCTAssertTrue(darkHTML.contains("--text-color: #d1d1d6;"))
        XCTAssertTrue(darkHTML.contains("'SF Mono', Menlo"))
    }

    // MARK: - 5. Find in Page Engine & Query Escaping

    func testBrowserFindInPageScriptsAndResultParsing() {
        // Query with special characters that require escaping
        let query = "quote: \"hello\\world\" \n test"
        let script = BrowserFindInPageEngine.searchScript(query: query)
        XCTAssertTrue(script.contains("window.__lidFindMatches"))
        XCTAssertTrue(script.contains("lid-find-match"))
        XCTAssertFalse(script.contains("\n test\"")) // Newlines should be escaped

        // Parsing results
        let resultDict: [String: Any] = [
            "matchCount": 15,
            "currentIndex": 3
        ]
        let result = BrowserFindInPageEngine.parseResult(from: resultDict)
        XCTAssertEqual(result.matchCount, 15)
        XCTAssertEqual(result.currentIndex, 3)
        XCTAssertEqual(result.displayString, "3 of 15")

        // Zero matches
        let emptyResult = BrowserFindInPageEngine.parseResult(from: ["matchCount": 0, "currentIndex": 0])
        XCTAssertEqual(emptyResult.matchCount, 0)
        XCTAssertEqual(emptyResult.displayString, "0 of 0")
    }

    // MARK: - 6. BrowserTabState Codable Conformity

    func testBrowserTabStateCodableConformity() throws {
        let original = BrowserTabState(
            id: UUID(),
            url: URL(string: "https://apple.com")!,
            title: "Apple",
            isLoading: false,
            canGoBack: true,
            canGoForward: false,
            estimatedProgress: 1.0,
            isDesktopMode: true,
            isIncognito: false,
            createdAt: Date(),
            previewUpdatedAt: Date()
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(BrowserTabState.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.url, original.url)
        XCTAssertEqual(decoded.title, original.title)
        XCTAssertEqual(decoded.isDesktopMode, original.isDesktopMode)
        XCTAssertEqual(decoded.isIncognito, original.isIncognito)
        XCTAssertEqual(decoded.canGoBack, original.canGoBack)
        XCTAssertEqual(decoded.canGoForward, original.canGoForward)
    }
}
