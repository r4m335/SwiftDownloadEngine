import XCTest
@testable import DM_Reverse_engineering

final class BrowserTests: XCTestCase {

    // MARK: - 1. URL Normalization: Direct URLs

    func testDirectHTTPAndHTTPSURLs() {
        let httpsURL = "https://example.com/archive.zip"
        let resolvedHTTPS = BrowserURLResolver.resolve(input: httpsURL)
        XCTAssertEqual(resolvedHTTPS?.absoluteString, httpsURL)

        let httpURL = "http://example.com/data.bin?chunk=1"
        let resolvedHTTP = BrowserURLResolver.resolve(input: httpURL)
        XCTAssertEqual(resolvedHTTP?.absoluteString, httpURL)
    }

    func testBareDomainExpansionToHTTPS() {
        let bareDomain = "example.com"
        let resolved = BrowserURLResolver.resolve(input: bareDomain)
        XCTAssertEqual(resolved?.absoluteString, "https://example.com")

        let domainWithPath = "archive.org/details/classic-pc-games"
        let resolvedWithPath = BrowserURLResolver.resolve(input: domainWithPath)
        XCTAssertEqual(resolvedWithPath?.absoluteString, "https://archive.org/details/classic-pc-games")

        let subdomain = "sub.domain.co.uk/path/file.tar.gz"
        let resolvedSub = BrowserURLResolver.resolve(input: subdomain)
        XCTAssertEqual(resolvedSub?.absoluteString, "https://sub.domain.co.uk/path/file.tar.gz")
    }

    func testLocalhostExpansionToHTTP() {
        let lhPort = "localhost:8080"
        let resolvedPort = BrowserURLResolver.resolve(input: lhPort)
        XCTAssertEqual(resolvedPort?.absoluteString, "http://localhost:8080")

        let lhBare = "localhost"
        let resolvedBare = BrowserURLResolver.resolve(input: lhBare)
        XCTAssertEqual(resolvedBare?.absoluteString, "http://localhost")

        let lhPath = "localhost/api/test"
        let resolvedPath = BrowserURLResolver.resolve(input: lhPath)
        XCTAssertEqual(resolvedPath?.absoluteString, "http://localhost/api/test")
    }

    // MARK: - 2. Search Query Handling

    func testSpaceDelimitedInputGeneratesSearchURL() {
        let query = "swift download engine architecture"
        let resolved = BrowserURLResolver.resolve(input: query, searchEngine: .duckDuckGo)
        XCTAssertNotNil(resolved)
        XCTAssertTrue(resolved!.absoluteString.starts(with: "https://duckduckgo.com/?q="))
        XCTAssertTrue(resolved!.absoluteString.contains("swift%20download%20engine%20architecture") || resolved!.absoluteString.contains("swift+download+engine+architecture"))
    }

    func testGoogleAndBingSearchEngines() {
        let query = "open source download manager"

        let google = BrowserURLResolver.resolve(input: query, searchEngine: .google)
        XCTAssertNotNil(google)
        XCTAssertTrue(google!.absoluteString.starts(with: "https://www.google.com/search?q="))

        let bing = BrowserURLResolver.resolve(input: query, searchEngine: .bing)
        XCTAssertNotNil(bing)
        XCTAssertTrue(bing!.absoluteString.starts(with: "https://www.bing.com/search?q="))
    }

    func testSingleWordNonDomainGeneratesSearchQuery() {
        let singleWord = "documentation"
        let resolved = BrowserURLResolver.resolve(input: singleWord, searchEngine: .duckDuckGo)
        XCTAssertNotNil(resolved)
        XCTAssertEqual(resolved?.absoluteString, "https://duckduckgo.com/?q=documentation")
    }

    func testEmptyAndWhitespaceInputReturnsNil() {
        XCTAssertNil(BrowserURLResolver.resolve(input: ""))
        XCTAssertNil(BrowserURLResolver.resolve(input: "   "))
        XCTAssertNil(BrowserURLResolver.resolve(input: "\n\t"))
    }

    // MARK: - 3. Security: Disallowed Schemes

    func testDisallowedSchemesAreRejected() {
        XCTAssertNil(BrowserURLResolver.resolve(input: "javascript:alert(document.cookie)"))
        XCTAssertNil(BrowserURLResolver.resolve(input: "file:///etc/passwd"))
        XCTAssertNil(BrowserURLResolver.resolve(input: "ftp://files.example.com/archive.zip"))
        XCTAssertNil(BrowserURLResolver.resolve(input: "data:text/html,<h1>Injected</h1>"))
        XCTAssertNil(BrowserURLResolver.resolve(input: "blob:https://example.com/550e8400-e29b-41d4-a716-446655440000"))
        XCTAssertNil(BrowserURLResolver.resolve(input: "vbscript:msgbox(1)"))
    }

    func testAboutBlankIsPermittedForEmptyState() {
        let resolved = BrowserURLResolver.resolve(input: "about:blank")
        XCTAssertEqual(resolved?.absoluteString, "about:blank")
        XCTAssertTrue(BrowserURLResolver.isValidWebNavigationURL(resolved))
    }

    // MARK: - 4. Download URL Validation

    func testDownloadURLValidation() {
        let validHTTPS = URL(string: "https://cdn.example.com/file.dmg")
        XCTAssertTrue(BrowserURLResolver.isValidDownloadURL(validHTTPS))

        let validHTTP = URL(string: "http://speedtest.server.org/100mb.bin")
        XCTAssertTrue(BrowserURLResolver.isValidDownloadURL(validHTTP))

        let blankURL = URL(string: "about:blank")
        XCTAssertFalse(BrowserURLResolver.isValidDownloadURL(blankURL))

        let fileURL = URL(string: "file:///private/var/mobile/file.zip")
        XCTAssertFalse(BrowserURLResolver.isValidDownloadURL(fileURL))

        let ftpURL = URL(string: "ftp://ftp.gnu.org/gnu/gcc/gcc.tar.gz")
        XCTAssertFalse(BrowserURLResolver.isValidDownloadURL(ftpURL))

        XCTAssertFalse(BrowserURLResolver.isValidDownloadURL(nil))
    }

    // MARK: - 5. URL Sanitization for Telemetry & Logging

    func testSensitiveQueryParamSanitization() {
        let sensitiveURL = URL(string: "https://s3.amazonaws.com/downloads/bundle.zip?AWSAccessKeyId=AKIAIOSFODNN7EXAMPLE&Signature=vjbyPxybdZaNmGa%2ByT272YEAiv4%3D&Expires=1700000000&fileId=98765")!
        let sanitized = BrowserURLResolver.sanitizeURLForLogging(sensitiveURL)

        XCTAssertFalse(sanitized.contains("vjbyPxybdZaNmGa"))
        XCTAssertFalse(sanitized.contains("AKIAIOSFODNN7EXAMPLE"))
        XCTAssertTrue(sanitized.contains("REDACTED"))
        XCTAssertTrue(sanitized.contains("fileId=98765"))
    }

    func testTokenAndSecretRedaction() {
        let tokenURL = URL(string: "https://api.example.com/v1/download?token=secret_jwt_token_12345&version=2.0")!
        let sanitized = BrowserURLResolver.sanitizeURLForLogging(tokenURL)

        XCTAssertFalse(sanitized.contains("secret_jwt_token_12345"))
        XCTAssertTrue(sanitized.contains("token=REDACTED"))
        XCTAssertTrue(sanitized.contains("version=2.0"))
    }

    func testCleanURLRemainsUnchanged() {
        let cleanURL = URL(string: "https://opensource.apple.com/tarballs/xnu/xnu-7195.141.2.tar.gz")!
        let sanitized = BrowserURLResolver.sanitizeURLForLogging(cleanURL)
        XCTAssertEqual(sanitized, cleanURL.absoluteString)
    }

    // MARK: - 6. Filename Suggestion

    func testSuggestedFilenameExtraction() {
        let zipURL = URL(string: "https://example.com/releases/v1.0.0/App-Release.zip")!
        XCTAssertEqual(BrowserURLResolver.suggestedFilename(from: zipURL), "App-Release.zip")

        let urlWithQuery = URL(string: "https://example.com/download.tar.gz?token=abc")!
        XCTAssertEqual(BrowserURLResolver.suggestedFilename(from: urlWithQuery), "download.tar.gz")

        let rootURL = URL(string: "https://example.com/")!
        let fallback = BrowserURLResolver.suggestedFilename(from: rootURL)
        XCTAssertTrue(fallback.contains("example_com") || fallback.contains(".bin"))
    }

    // MARK: - 7. BrowserDownloadDelegate Boundary

    private final class MockDownloadDelegate: BrowserDownloadDelegate {
        var recordedURL: URL?
        var recordedFilename: String?
        var recordedThreads: Int?
        var recordedSpeedLimit: Int64?
        var didCallHandler = false

        func handleDownloadRequest(
            url: URL,
            filename: String?,
            threadCount: Int,
            speedLimitBytesPerSecond: Int64?
        ) async throws {
            didCallHandler = true
            recordedURL = url
            recordedFilename = filename
            recordedThreads = threadCount
            recordedSpeedLimit = speedLimitBytesPerSecond
        }
    }

    func testDownloadDelegateReceivesCorrectParameters() async throws {
        let mock = MockDownloadDelegate()
        let testURL = URL(string: "https://example.com/large_archive.iso")!

        try await mock.handleDownloadRequest(
            url: testURL,
            filename: "custom_archive.iso",
            threadCount: 8,
            speedLimitBytesPerSecond: 10 * 1024 * 1024
        )

        XCTAssertTrue(mock.didCallHandler)
        XCTAssertEqual(mock.recordedURL, testURL)
        XCTAssertEqual(mock.recordedFilename, "custom_archive.iso")
        XCTAssertEqual(mock.recordedThreads, 8)
        XCTAssertEqual(mock.recordedSpeedLimit, 10 * 1024 * 1024)
    }

    // MARK: - 8. Browser Navigation State & Quick Links

    func testBrowserNavigationStateDefaults() {
        let state = BrowserNavigationState()
        XCTAssertNil(state.currentURL)
        XCTAssertEqual(state.title, "")
        XCTAssertFalse(state.canGoBack)
        XCTAssertFalse(state.canGoForward)
        XCTAssertFalse(state.isLoading)
        XCTAssertEqual(state.estimatedProgress, 0.0)
        XCTAssertNil(state.errorMessage)
    }

    func testQuickLinksContainValidURLs() {
        let defaults = BrowserQuickLink.defaults
        XCTAssertFalse(defaults.isEmpty)

        for link in defaults {
            XCTAssertFalse(link.title.isEmpty)
            XCTAssertFalse(link.urlString.isEmpty)
            let url = URL(string: link.urlString)
            XCTAssertNotNil(url)
            XCTAssertTrue(BrowserURLResolver.isValidWebNavigationURL(url))
        }
    }
}
