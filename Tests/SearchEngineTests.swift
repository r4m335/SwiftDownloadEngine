import XCTest
@testable import SwiftDownloadEngine

final class SearchEngineTests: XCTestCase {

    // MARK: - 1. Built-in Engines Preservation & Templates

    func testBuiltInEnginesPreservationAndTemplates() {
        let engines = BrowserSearchEngine.allCases
        XCTAssertEqual(engines.count, 4)
        XCTAssertTrue(engines.contains(.duckDuckGo))
        XCTAssertTrue(engines.contains(.google))
        XCTAssertTrue(engines.contains(.bing))
        XCTAssertTrue(engines.contains(.brave))

        XCTAssertEqual(BrowserSearchEngine.duckDuckGo.displayName, "DuckDuckGo")
        XCTAssertEqual(BrowserSearchEngine.duckDuckGo.urlTemplate, "https://duckduckgo.com/?q=%s")

        XCTAssertEqual(BrowserSearchEngine.google.displayName, "Google")
        XCTAssertEqual(BrowserSearchEngine.google.urlTemplate, "https://www.google.com/search?q=%s")

        XCTAssertEqual(BrowserSearchEngine.bing.displayName, "Bing")
        XCTAssertEqual(BrowserSearchEngine.bing.urlTemplate, "https://www.bing.com/search?q=%s")

        XCTAssertEqual(BrowserSearchEngine.brave.displayName, "Brave")
        XCTAssertEqual(BrowserSearchEngine.brave.urlTemplate, "https://search.brave.com/search?q=%s")
    }

    // MARK: - 2. CustomSearchEngine Model & Codable

    func testCustomSearchEngineModelAndCodable() throws {
        let engine = CustomSearchEngine(
            id: "kagi-123",
            name: "Kagi",
            urlTemplate: "https://kagi.com/search?q=%s",
            searchDescription: "Fast, ad-free search"
        )

        XCTAssertEqual(engine.id, "kagi-123")
        XCTAssertEqual(engine.name, "Kagi")
        XCTAssertEqual(engine.urlTemplate, "https://kagi.com/search?q=%s")
        XCTAssertEqual(engine.searchDescription, "Fast, ad-free search")

        let encoded = try JSONEncoder().encode(engine)
        let decoded = try JSONDecoder().decode(CustomSearchEngine.self, from: encoded)
        XCTAssertEqual(decoded, engine)
    }

    // MARK: - 3. URL Template Validation

    private func assertValidationSuccess(_ template: String, file: StaticString = #file, line: UInt = #line) {
        switch SearchURLBuilder.validateTemplate(template) {
        case .success:
            break
        case .failure(let error):
            XCTFail("Expected success for '\(template)', but got error: \(error)", file: file, line: line)
        }
    }

    private func assertValidationFailure(_ template: String, expected: SearchURLValidationError, file: StaticString = #file, line: UInt = #line) {
        switch SearchURLBuilder.validateTemplate(template) {
        case .success:
            XCTFail("Expected failure for '\(template)', but succeeded", file: file, line: line)
        case .failure(let error):
            XCTAssertEqual(error, expected, file: file, line: line)
        }
    }

    func testTemplateValidation_Success() {
        assertValidationSuccess("https://kagi.com/search?q=%s")
        assertValidationSuccess("https://www.ecosia.org/search?method=index&q=%s&addon=opensearch")
        assertValidationSuccess("https://github.com/search?q=%s&type=repositories")
    }

    func testTemplateValidation_Failures() {
        // Empty or whitespace
        assertValidationFailure("", expected: .emptyTemplate)
        assertValidationFailure("   \t  ", expected: .emptyTemplate)

        // Insecure scheme (HTTP, FTP, file, javascript)
        assertValidationFailure("http://example.com/search?q=%s", expected: .missingHTTPS)
        assertValidationFailure("ftp://example.com/search?q=%s", expected: .missingHTTPS)
        assertValidationFailure("javascript:alert(%s)", expected: .missingHTTPS)

        // Missing %s placeholder
        assertValidationFailure("https://kagi.com/search?q=", expected: .missingPlaceholder)

        // Multiple %s placeholders
        assertValidationFailure("https://kagi.com/search?q=%s&alt=%s", expected: .multiplePlaceholders)

        // Invalid or missing host
        assertValidationFailure("https:///search?q=%s", expected: .invalidHost)
        assertValidationFailure("https://localhost/search?q=%s", expected: .invalidHost)

        // Control characters or newlines
        assertValidationFailure("https://example.com/search?q=%s\n", expected: .invalidCharacters)
        assertValidationFailure("https://example.com/\nsearch?q=%s", expected: .invalidCharacters)
        assertValidationFailure("https://example.com/search?q=%s\u{0000}", expected: .invalidCharacters)
    }

    // MARK: - 4. Search URL Construction & Query Percent Encoding

    func testSearchURLConstruction() {
        let template = "https://kagi.com/search?q=%s"

        // Basic query with spaces
        let url1 = SearchURLBuilder.buildURL(query: "swift async await", template: template)
        XCTAssertEqual(url1?.absoluteString, "https://kagi.com/search?q=swift%20async%20await")

        // C++ (plus sign preserved via %2B, not decoded as space)
        let url2 = SearchURLBuilder.buildURL(query: "C++", template: template)
        XCTAssertEqual(url2?.absoluteString, "https://kagi.com/search?q=C%2B%2B")

        // Ampersand (escaped so it doesn't break URL parameters)
        let url3 = SearchURLBuilder.buildURL(query: "Tom & Jerry", template: template)
        XCTAssertEqual(url3?.absoluteString, "https://kagi.com/search?q=Tom%20%26%20Jerry")

        // Equals and Hash signs
        let url4 = SearchURLBuilder.buildURL(query: "x = 42 #tag", template: template)
        XCTAssertEqual(url4?.absoluteString, "https://kagi.com/search?q=x%20%3D%2042%20%23tag")

        // Unicode and Non-English characters
        let url5 = SearchURLBuilder.buildURL(query: "東京 ラーメン", template: template)
        XCTAssertNotNil(url5)
        XCTAssertTrue(url5!.absoluteString.contains("%E6%9D%B1%E4%BA%AC%20%E3%83%A9%E3%83%BC%E3%83%A1%E3%83%B3"))

        // Empty query returns nil
        XCTAssertNil(SearchURLBuilder.buildURL(query: "", template: template))
        XCTAssertNil(SearchURLBuilder.buildURL(query: "   ", template: template))
    }

    // MARK: - 5. BrowserURLResolver with Custom Engine Resolution

    func testBrowserURLResolver_DirectURLsUnaffected() {
        let custom = CustomSearchEngine(
            id: "kagi",
            name: "Kagi",
            urlTemplate: "https://kagi.com/search?q=%s"
        )

        // Direct HTTPS URL
        let url1 = BrowserURLResolver.resolve(input: "https://apple.com", engineID: custom.id, customEngines: [custom])
        XCTAssertEqual(url1?.absoluteString, "https://apple.com")

        // Domain name without scheme
        let url2 = BrowserURLResolver.resolve(input: "github.com/torvalds/linux", engineID: custom.id, customEngines: [custom])
        XCTAssertEqual(url2?.absoluteString, "https://github.com/torvalds/linux")

        // Localhost
        let url3 = BrowserURLResolver.resolve(input: "localhost:8080/dashboard", engineID: custom.id, customEngines: [custom])
        XCTAssertEqual(url3?.absoluteString, "http://localhost:8080/dashboard")

        // Disallowed scheme
        let url4 = BrowserURLResolver.resolve(input: "javascript:alert(1)", engineID: custom.id, customEngines: [custom])
        XCTAssertNil(url4)
    }

    func testBrowserURLResolver_QueriesResolveToSelectedEngine() {
        let custom = CustomSearchEngine(
            id: "kagi",
            name: "Kagi",
            urlTemplate: "https://kagi.com/search?q=%s"
        )

        // Query with custom engine
        let queryURL = BrowserURLResolver.resolve(input: "ios 18 download manager", engineID: custom.id, customEngines: [custom])
        XCTAssertEqual(queryURL?.absoluteString, "https://kagi.com/search?q=ios%2018%20download%20manager")

        // Single word query
        let singleWordURL = BrowserURLResolver.resolve(input: "swiftlang", engineID: custom.id, customEngines: [custom])
        XCTAssertEqual(singleWordURL?.absoluteString, "https://kagi.com/search?q=swiftlang")

        // Fallback to built-in when unknown ID
        let fallbackURL = BrowserURLResolver.resolve(input: "hello", engineID: "nonexistent_id", customEngines: [])
        XCTAssertEqual(fallbackURL?.absoluteString, "https://duckduckgo.com/?q=hello")
    }

    // MARK: - 6. AppSettings Version 8 Migration & Search Engine Persistence

    func testAppSettingsVersion8Migration() throws {
        XCTAssertGreaterThanOrEqual(AppSettings.currentVersion, 8)

        // Simulate Version 7 JSON lacking customSearchEngines and activeSearchEngineID
        let v7JSON = """
        {
            "version": 7,
            "maxConcurrentDownloads": 3,
            "maxGlobalRequests": 12,
            "timeoutSeconds": 30,
            "allowCellular": true,
            "enableGlobalSpeedLimit": false,
            "globalSpeedLimitKBps": 2048,
            "maxConcurrentTorrents": 3,
            "defaultTorrentPriority": 2,
            "seedingMode": "Stop at Ratio",
            "targetRatio": 1.0,
            "targetDurationMinutes": 60,
            "isAdBlockerEnabled": true,
            "isTrackerBlockerEnabled": true,
            "isAnnoyanceBlockerEnabled": true,
            "cookiePolicy": "blockThirdParty",
            "isPopupBlockerEnabled": true,
            "adBlockerWhitelistedDomains": [],
            "isAutomaticCategorizationEnabled": true,
            "customCategoryFolders": {},
            "downloadSortOrder": "dateAddedDesc",
            "browserSearchEngine": "Brave",
            "browserHomepage": "https://brave.com",
            "restoreTabsOnLaunch": true,
            "readerTheme": "sepia",
            "readerFontFamily": "serif",
            "readerFontSize": 20.0
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(AppSettings.self, from: v7JSON)
        XCTAssertEqual(decoded.version, 7)
        XCTAssertEqual(decoded.browserSearchEngine, .brave)
        // Fallbacks properly synthesized
        XCTAssertEqual(decoded.activeSearchEngineID, BrowserSearchEngine.brave.rawValue)
        XCTAssertEqual(decoded.customSearchEngines, [])
        XCTAssertEqual(decoded.effectiveActiveSearchEngineName, "Brave")
        XCTAssertEqual(decoded.effectiveActiveSearchTemplate, BrowserSearchEngine.brave.urlTemplate)
    }

    func testAppSettingsCustomEnginesRoundTrip() throws {
        var settings = AppSettings.default
        let custom1 = CustomSearchEngine(id: "kagi", name: "Kagi", urlTemplate: "https://kagi.com/search?q=%s")
        let custom2 = CustomSearchEngine(id: "startpage", name: "Startpage", urlTemplate: "https://www.startpage.com/do/dsearch?query=%s")
        settings.customSearchEngines = [custom1, custom2]
        settings.activeSearchEngineID = custom1.id

        let encoded = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: encoded)

        XCTAssertEqual(decoded.customSearchEngines.count, 2)
        XCTAssertEqual(decoded.customSearchEngines[0], custom1)
        XCTAssertEqual(decoded.customSearchEngines[1], custom2)
        XCTAssertEqual(decoded.activeSearchEngineID, custom1.id)
        XCTAssertEqual(decoded.effectiveActiveSearchEngineName, "Kagi")
        XCTAssertEqual(decoded.effectiveActiveSearchTemplate, "https://kagi.com/search?q=%s")
    }

    // MARK: - 7. BrowserViewModel Search Engine Selection & Navigation

    @MainActor
    func testBrowserViewModelSearchEngineSelection() {
        let viewModel = BrowserViewModel()
        let custom = CustomSearchEngine(id: "custom-ecosia", name: "Ecosia", urlTemplate: "https://www.ecosia.org/search?q=%s")
        viewModel.customSearchEngines = [custom]

        // Default starts as DuckDuckGo
        XCTAssertEqual(viewModel.currentSearchEngineName, "DuckDuckGo")
        XCTAssertEqual(viewModel.currentSearchEngineTemplate, BrowserSearchEngine.duckDuckGo.urlTemplate)

        // Switch to Google
        viewModel.setSearchEngine(id: BrowserSearchEngine.google.rawValue)
        XCTAssertEqual(viewModel.activeSearchEngineID, BrowserSearchEngine.google.rawValue)
        XCTAssertEqual(viewModel.selectedSearchEngine, .google)
        XCTAssertEqual(viewModel.currentSearchEngineName, "Google")
        XCTAssertEqual(viewModel.currentSearchEngineTemplate, BrowserSearchEngine.google.urlTemplate)

        // Switch to Custom Ecosia
        viewModel.setSearchEngine(id: custom.id)
        XCTAssertEqual(viewModel.activeSearchEngineID, custom.id)
        XCTAssertEqual(viewModel.currentSearchEngineName, "Ecosia")
        XCTAssertEqual(viewModel.currentSearchEngineTemplate, "https://www.ecosia.org/search?q=%s")

        // Verify switching did NOT mutate currentURL or trigger loading
        XCTAssertNil(viewModel.currentURL)
        XCTAssertFalse(viewModel.isLoading)
    }
}
