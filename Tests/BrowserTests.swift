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

    // MARK: - 9. Milestone 7B: Download Resource Classification

    func testDownloadClassifierRecognizesCommonExtensions() {
        let extensions = [
            "zip", "7z", "rar", "tar", "gz", "pdf", "epub", "apk", "ipa",
            "exe", "msi", "dmg", "pkg", "iso", "img", "mp3", "m4a", "wav",
            "flac", "mp4", "mkv", "avi", "mov", "webm", "torrent", "bin"
        ]

        for ext in extensions {
            let url = URL(string: "https://example.com/files/download_target.\(ext)")!
            let classification = BrowserDownloadClassifier.classify(url: url, canShowMIMEType: false)
            XCTAssertTrue(classification.isDownload, "Extension .\(ext) should be recognized as a downloadable resource")
            XCTAssertNotNil(classification.suggestedFilename)
            XCTAssertTrue(classification.suggestedFilename!.hasSuffix(".\(ext)"))
        }
    }

    func testDownloadClassifierRejectsUnknownExtensions() {
        let unknownUrls = [
            URL(string: "https://example.com/page.unknown")!,
            URL(string: "https://example.com/asset.xyz")!,
            URL(string: "https://example.com/data.custom")!
        ]

        for url in unknownUrls {
            let classification = BrowserDownloadClassifier.classify(url: url)
            XCTAssertFalse(classification.isDownload)
            XCTAssertEqual(classification.confidence, .none)
        }
    }

    func testCaseInsensitiveExtensionMatching() {
        let upperURLs = [
            (URL(string: "https://example.com/ARCHIVE.ZIP")!, "ARCHIVE.ZIP"),
            (URL(string: "https://example.com/Video.MP4")!, "Video.MP4"),
            (URL(string: "https://example.com/System.ISO")!, "System.ISO"),
            (URL(string: "https://example.com/Package.DMG")!, "Package.DMG")
        ]

        for (url, expectedName) in upperURLs {
            let classification = BrowserDownloadClassifier.classify(url: url, canShowMIMEType: false)
            XCTAssertTrue(classification.isDownload)
            XCTAssertEqual(classification.suggestedFilename, expectedName)
        }
    }

    func testURLWithQueryParametersAfterExtension() {
        let urlWithQuery = URL(string: "https://cdn.example.com/build-v2.5.zip?token=secret123&auth_signature=abcdef&download=true")!
        let classification = BrowserDownloadClassifier.classify(url: urlWithQuery, canShowMIMEType: false)

        XCTAssertTrue(classification.isDownload)
        XCTAssertEqual(classification.suggestedFilename, "build-v2.5.zip")
    }

    func testContentDispositionAttachmentStandard() {
        let url = URL(string: "https://example.com/api/get_file")!
        let disposition = "attachment; filename=\"Quarterly Report.pdf\""

        let classification = BrowserDownloadClassifier.classify(
            url: url,
            statusCode: 200,
            contentDisposition: disposition,
            mimeType: "application/pdf"
        )

        XCTAssertTrue(classification.isDownload)
        XCTAssertEqual(classification.confidence, .high)
        XCTAssertEqual(classification.suggestedFilename, "Quarterly Report.pdf")
    }

    func testContentDispositionRFC5987StarFilename() {
        let url = URL(string: "https://example.com/download")!
        let disposition = "attachment; filename*=UTF-8''Quarterly%20Report%202026.pdf"

        let classification = BrowserDownloadClassifier.classify(
            url: url,
            statusCode: 200,
            contentDisposition: disposition
        )

        XCTAssertTrue(classification.isDownload)
        XCTAssertEqual(classification.confidence, .high)
        XCTAssertEqual(classification.suggestedFilename, "Quarterly Report 2026.pdf")
    }

    func testContentDispositionRFC6266Precedence() {
        // RFC 6266 section 4.3: filename* MUST take precedence over filename
        let url = URL(string: "https://example.com/download")!
        let disposition = "attachment; filename=\"fallback.pdf\"; filename*=UTF-8''preferred_name.pdf"

        let classification = BrowserDownloadClassifier.classify(
            url: url,
            statusCode: 200,
            contentDisposition: disposition
        )

        XCTAssertTrue(classification.isDownload)
        XCTAssertEqual(classification.suggestedFilename, "preferred_name.pdf")
    }

    func testContentDispositionWithLanguageTag() {
        let url = URL(string: "https://example.com/docs")!
        let disposition = "attachment; filename*=utf-8'en'User%20Manual.epub"

        let classification = BrowserDownloadClassifier.classify(
            url: url,
            statusCode: 200,
            contentDisposition: disposition
        )

        XCTAssertTrue(classification.isDownload)
        XCTAssertEqual(classification.suggestedFilename, "User Manual.epub")
    }

    func testURLWithoutExtensionWithAttachmentHeader() {
        let url = URL(string: "https://analytics.example.com/export/csv?team=engineers")!
        let disposition = "attachment; filename=\"metrics-2026.csv\""

        let classification = BrowserDownloadClassifier.classify(
            url: url,
            statusCode: 200,
            contentDisposition: disposition,
            mimeType: "text/csv"
        )

        XCTAssertTrue(classification.isDownload)
        XCTAssertEqual(classification.confidence, .high)
        XCTAssertEqual(classification.suggestedFilename, "metrics-2026.csv")
    }

    func testNormalWebpagesAreNotClassifiedAsDownloads() {
        let webURLs = [
            (URL(string: "https://example.com/index.html")!, "text/html"),
            (URL(string: "https://example.com/about")!, "text/html; charset=utf-8"),
            (URL(string: "https://example.com/app.xhtml")!, "application/xhtml+xml"),
            (URL(string: "https://example.com/styles.css")!, "text/css"),
            (URL(string: "https://example.com/bundle.js")!, "application/javascript"),
            (URL(string: "https://example.com/api/status")!, "application/json")
        ]

        for (url, mime) in webURLs {
            let classification = BrowserDownloadClassifier.classify(
                url: url,
                statusCode: 200,
                contentDisposition: nil,
                mimeType: mime,
                canShowMIMEType: true
            )
            XCTAssertFalse(classification.isDownload, "Web resource \(url) with mime \(mime) should not be classified as a download")
            XCTAssertEqual(classification.confidence, .none)
        }
    }

    func testRedirectStatusCodesAreNotClassifiedAsDownloads() {
        let redirectCodes = [301, 302, 303, 307, 308]
        let downloadURL = URL(string: "https://example.com/download.zip")!

        for code in redirectCodes {
            let classification = BrowserDownloadClassifier.classify(
                url: downloadURL,
                statusCode: code,
                contentDisposition: "attachment; filename=\"download.zip\"",
                mimeType: "application/zip"
            )
            XCTAssertFalse(classification.isDownload, "HTTP redirect status \(code) must not be intercepted as a download")
        }
    }

    func testErrorStatusCodesAreNotClassifiedAsDownloads() {
        let errorCodes = [400, 401, 403, 404, 500, 502, 503]
        let downloadURL = URL(string: "https://example.com/missing.zip")!

        for code in errorCodes {
            let classification = BrowserDownloadClassifier.classify(
                url: downloadURL,
                statusCode: code,
                mimeType: "application/zip"
            )
            XCTAssertFalse(classification.isDownload, "HTTP error status \(code) must not be intercepted as a download")
        }
    }

    func testMIMETypesClassification() {
        let url = URL(string: "https://example.com/download/file")!

        let zipClassification = BrowserDownloadClassifier.classify(
            url: url,
            statusCode: 200,
            mimeType: "application/zip"
        )
        XCTAssertTrue(zipClassification.isDownload)
        XCTAssertEqual(zipClassification.suggestedFilename, "file.zip")

        let dmgClassification = BrowserDownloadClassifier.classify(
            url: url,
            statusCode: 200,
            mimeType: "application/x-apple-diskimage"
        )
        XCTAssertTrue(dmgClassification.isDownload)
        XCTAssertEqual(dmgClassification.suggestedFilename, "file.dmg")

        let torrentClassification = BrowserDownloadClassifier.classify(
            url: url,
            statusCode: 200,
            mimeType: "application/x-bittorrent"
        )
        XCTAssertTrue(torrentClassification.isDownload)
        XCTAssertEqual(torrentClassification.suggestedFilename, "file.torrent")
    }

    func testFilenameSanitizationAndTraversalPrevention() {
        // Path traversal in filename header
        let traversalHeader = "attachment; filename=\"../../../../etc/passwd.zip\""
        let (_, traversalName) = BrowserDownloadClassifier.parseContentDisposition(traversalHeader)
        XCTAssertEqual(traversalName, "passwd.zip")

        // Illegal characters in filename header
        let illegalHeader = "attachment; filename=\"my:special*file?name<test>|demo.tar.gz\""
        let (_, illegalName) = BrowserDownloadClassifier.parseContentDisposition(illegalHeader)
        XCTAssertEqual(illegalName, "my_special_file_name_test_demo.tar.gz")

        // Windows-style backslash traversal
        let winTraversalHeader = "attachment; filename=\"..\\..\\Windows\\System32\\file.iso\""
        let (_, winName) = BrowserDownloadClassifier.parseContentDisposition(winTraversalHeader)
        XCTAssertEqual(winName, "file.iso")
    }

    func testUnsupportedSchemesRejectedByClassifier() {
        let unsupportedURLs = [
            URL(string: "javascript:alert(1)")!,
            URL(string: "file:///private/var/mobile/file.zip")!,
            URL(string: "ftp://mirror.example.com/file.iso")!,
            URL(string: "data:application/zip;base64,UEsDBA==")!
        ]

        for url in unsupportedURLs {
            let classification = BrowserDownloadClassifier.classify(
                url: url,
                contentDisposition: "attachment; filename=\"file.zip\"",
                mimeType: "application/zip"
            )
            XCTAssertFalse(classification.isDownload)
        }
    }

    func testSanitizeURLForDisplayMasksSensitiveParameters() {
        let signedURL = URL(string: "https://download.server.com/files/archive.zip?X-Amz-Signature=abcd1234ef56&X-Amz-Credential=key789&user_id=42")!
        let displayString = BrowserURLResolver.sanitizeURLForDisplay(signedURL)

        XCTAssertFalse(displayString.contains("abcd1234ef56"))
        XCTAssertFalse(displayString.contains("key789"))
        XCTAssertTrue(displayString.contains("REDACTED"))
        XCTAssertTrue(displayString.contains("user_id=42"))
    }

    #if canImport(SwiftUI)
    @MainActor
    func testBrowserViewModelDuplicatePromptSuppression() {
        let vm = BrowserViewModel()
        let testURL = URL(string: "https://example.com/test.zip")!

        XCTAssertFalse(vm.shouldSuppressDuplicatePrompt(for: testURL))

        // Trigger prompt
        vm.promptDownload(for: testURL, suggestedFilename: "test.zip")
        XCTAssertTrue(vm.isShowingDownloadSheet)
        XCTAssertEqual(vm.downloadCandidateURL, testURL)
        XCTAssertEqual(vm.downloadCandidateFilename, "test.zip")

        // Repeated prompt immediately while sheet is showing must be suppressed
        XCTAssertTrue(vm.shouldSuppressDuplicatePrompt(for: testURL))

        // Close sheet
        vm.isShowingDownloadSheet = false

        // Repeated prompt within cooldown window must still be suppressed
        XCTAssertTrue(vm.shouldSuppressDuplicatePrompt(for: testURL))

        // Different URL should NOT be suppressed
        let otherURL = URL(string: "https://example.com/another.zip")!
        XCTAssertFalse(vm.shouldSuppressDuplicatePrompt(for: otherURL))
    }
    #endif
}
