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
        struct DownloadRequest {
            let url: URL
            let filename: String?
        }

        var recordedURL: URL?
        var recordedFilename: String?
        var recordedThreads: Int?
        var recordedSpeedLimit: Int64?
        var recordedHeaders: [String: String]?
        var downloadRequests: [DownloadRequest] = []
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
            downloadRequests.append(DownloadRequest(url: url, filename: filename))
        }

        func handleDownloadRequest(
            url: URL,
            filename: String?,
            threadCount: Int,
            speedLimitBytesPerSecond: Int64?,
            headers: [String: String]?
        ) async throws {
            didCallHandler = true
            recordedURL = url
            recordedFilename = filename
            recordedThreads = threadCount
            recordedSpeedLimit = speedLimitBytesPerSecond
            recordedHeaders = headers
            downloadRequests.append(DownloadRequest(url: url, filename: filename))
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

    // MARK: - 7E: Browser request context safety

    func testBrowserRequestContextMatchesCookiesAndFiltersHeaders() {
        let pageURL = URL(string: "https://example.com/account/view")!
        let resourceURL = URL(string: "https://cdn.example.com/private/file.zip")!
        let context = BrowserRequestContext(
            url: resourceURL,
            pageURL: pageURL,
            userAgent: "BrowserTest/1.0",
            cookies: [
                BrowserCookie(name: "session", value: "secret", domain: ".example.com", path: "/private", isSecure: true),
                BrowserCookie(name: "wrong-host", value: "must-not-forward", domain: "other.example", isSecure: true),
                BrowserCookie(name: "expired", value: "old", domain: ".example.com", expiresDate: Date(timeIntervalSince1970: 1)),
                BrowserCookie(name: "insecure", value: "no", domain: ".example.com", isSecure: false)
            ],
            customHeaders: [
                "X-Trace-ID": "trace-1",
                "Host": "attacker.example",
                "Range": "bytes=0-10",
                "Cookie": "forged=value",
                "Authorization": "Bearer secret-token"
            ],
            source: .webpageResource
        )

        let headers = context.effectiveHeaders()
        XCTAssertEqual(headers["Cookie"], "session=secret; insecure=no")
        XCTAssertEqual(headers["Referer"], pageURL.absoluteString)
        XCTAssertEqual(headers["User-Agent"], "BrowserTest/1.0")
        XCTAssertEqual(headers["X-Trace-ID"], "trace-1")
        XCTAssertEqual(headers["Authorization"], "Bearer secret-token")
        XCTAssertNil(headers["Host"])
        XCTAssertNil(headers["Range"])
        XCTAssertFalse(headers["Cookie"]?.contains("forged") == true)

        let publicHeaders = context.effectiveHeaders(includeCredentials: false)
        XCTAssertNil(publicHeaders["Cookie"])
        XCTAssertNil(publicHeaders["Authorization"])
        XCTAssertEqual(publicHeaders["User-Agent"], "BrowserTest/1.0")
    }

    func testBrowserRequestContextRedactsSensitiveValues() {
        let url = URL(string: "https://example.com/download.zip?token=private-value")!
        let context = BrowserRequestContext(
            url: url,
            cookies: [BrowserCookie(name: "session", value: "cookie-private", domain: "example.com")],
            customHeaders: ["Authorization": "Bearer header-private", "X-Trace": "safe"]
        )

        let redacted = context.redactedDescription
        XCTAssertFalse(redacted.contains("cookie-private"))
        XCTAssertFalse(redacted.contains("header-private"))
        XCTAssertFalse(redacted.contains("private-value"))
        XCTAssertTrue(redacted.contains("REDACTED"))
        XCTAssertTrue(redacted.contains("safe"))
        XCTAssertTrue(BrowserHeaderFilter.isApprovedForwardedHeader("Authorization"))
        XCTAssertTrue(BrowserHeaderFilter.isApprovedForwardedHeader("X-CSRF-Token"))
        XCTAssertFalse(BrowserHeaderFilter.isApprovedForwardedHeader("Sec-Fetch-Site"))
    }

    func testBrowserCredentialsAreRemovedOnCrossOriginRedirect() {
        let original = URL(string: "https://example.com/file.zip")!
        let sameOrigin = URL(string: "https://example.com:443/other.zip")!
        let crossOrigin = URL(string: "https://cdn.example.net/file.zip")!
        let headers = [
            "Cookie": "session=private",
            "Authorization": "Bearer private",
            "Referer": "https://example.com/account",
            "User-Agent": "BrowserTest/1.0",
            "X-Trace-ID": "trace-1"
        ]

        XCTAssertEqual(BrowserHeaderFilter.stripCredentialsOnRedirect(headers: headers, from: original, to: sameOrigin), headers)

        let stripped = BrowserHeaderFilter.stripCredentialsOnRedirect(headers: headers, from: original, to: crossOrigin)
        XCTAssertNil(stripped["Cookie"])
        XCTAssertNil(stripped["Authorization"])
        XCTAssertNil(stripped["Referer"])
        XCTAssertEqual(stripped["User-Agent"], "BrowserTest/1.0")
        XCTAssertEqual(stripped["X-Trace-ID"], "trace-1")
    }

    func testBrowserRequestContextCanBeAttachedToResourceAndHandoff() {
        let url = URL(string: "https://example.com/file.pdf")!
        let context = BrowserRequestContext(url: url, source: .webpageResource)
        let resource = WebpageResource(
            url: url,
            title: "Report",
            suggestedFilename: "file.pdf",
            resourceType: .document,
            requestContext: context
        )
        let handoff = BrowserDownloadInterceptionManager().prepareHandoff(
            originalURL: url,
            requestContext: resource.requestContext
        )

        XCTAssertEqual(resource.requestContext, context)
        XCTAssertEqual(handoff?.requestContext, context)
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

    // MARK: - 10. Milestone 7C: Native Download Interception & Handoff

    func testInterceptionManagerFilenameResolutionHierarchy() {
        let manager = BrowserDownloadInterceptionManager()
        let testURL = URL(string: "https://example.com/api/v1/download/resource")!

        // 1. Server-provided suggested filename takes highest precedence
        let resolvedServer = manager.resolveFilename(
            serverSuggested: "Official-Setup.dmg",
            contentDisposition: "attachment; filename=\"old_name.iso\"",
            url: testURL,
            mimeType: "application/octet-stream"
        )
        XCTAssertEqual(resolvedServer, "Official-Setup.dmg")

        // 2. Content-Disposition takes precedence when serverSuggested is nil or generic
        let resolvedDisposition = manager.resolveFilename(
            serverSuggested: nil,
            contentDisposition: "attachment; filename*=UTF-8''Invoice%202026.pdf",
            url: testURL,
            mimeType: "application/pdf"
        )
        XCTAssertEqual(resolvedDisposition, "Invoice 2026.pdf")

        // 3. URL path fallback when no header is present
        let pathURL = URL(string: "https://example.com/downloads/package-v1.tar.gz")!
        let resolvedPath = manager.resolveFilename(
            serverSuggested: nil,
            contentDisposition: nil,
            url: pathURL,
            mimeType: nil
        )
        XCTAssertEqual(resolvedPath, "package-v1.tar.gz")

        // 4. MIME type fallback when URL has no extension
        let noExtURL = URL(string: "https://example.com/stream/media_payload")!
        let resolvedMIME = manager.resolveFilename(
            serverSuggested: nil,
            contentDisposition: nil,
            url: noExtURL,
            mimeType: "video/mp4"
        )
        XCTAssertEqual(resolvedMIME, "media_payload.mp4")
    }

    func testInterceptionManagerPreparesValidHandoffWithRedirect() {
        let manager = BrowserDownloadInterceptionManager()
        let original = URL(string: "https://example.com/download/latest")!
        let finalRedirected = URL(string: "https://cdn.example.com/binaries/release-2026.iso")!

        let handoff = manager.prepareHandoff(
            originalURL: original,
            finalURL: finalRedirected,
            serverSuggestedFilename: "custom-ubuntu.iso",
            mimeType: "application/x-iso9660-image",
            expectedLength: 4_500_000_000,
            source: .nativeWebKitDownload
        )

        XCTAssertNotNil(handoff)
        XCTAssertEqual(handoff?.originalURL, original)
        XCTAssertEqual(handoff?.finalURL, finalRedirected)
        XCTAssertEqual(handoff?.suggestedFilename, "custom-ubuntu.iso")
        XCTAssertEqual(handoff?.mimeType, "application/x-iso9660-image")
        XCTAssertEqual(handoff?.expectedContentLength, 4_500_000_000)
        XCTAssertEqual(handoff?.source, .nativeWebKitDownload)
    }

    func testInterceptionManagerRejectsInvalidDownloadSchemes() {
        let manager = BrowserDownloadInterceptionManager()
        let fileURL = URL(string: "file:///private/var/mobile/secret.tar")!
        let handoffFile = manager.prepareHandoff(originalURL: fileURL)
        XCTAssertNil(handoffFile)

        let jsURL = URL(string: "javascript:void(0)")!
        let handoffJS = manager.prepareHandoff(originalURL: jsURL)
        XCTAssertNil(handoffJS)
    }

    func testIsIntentionalHandoffCancellation() {
        // WebKit download cancellation (WKErrorDomain code 2)
        let wkCancelledError = NSError(domain: "WKErrorDomain", code: 2, userInfo: nil)
        XCTAssertTrue(BrowserDownloadInterceptionManager.isIntentionalHandoffCancellation(wkCancelledError))

        // URLSession cancellation (NSURLErrorDomain code -999)
        let urlCancelledError = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled, userInfo: nil)
        XCTAssertTrue(BrowserDownloadInterceptionManager.isIntentionalHandoffCancellation(urlCancelledError))

        // Real network errors must NOT be identified as intentional cancellations
        let timeoutError = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: nil)
        XCTAssertFalse(BrowserDownloadInterceptionManager.isIntentionalHandoffCancellation(timeoutError))

        let cannotConnectError = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost, userInfo: nil)
        XCTAssertFalse(BrowserDownloadInterceptionManager.isIntentionalHandoffCancellation(cannotConnectError))
    }

    func testBrowserDownloadHandoffModelEquatability() {
        let url1 = URL(string: "https://example.com/archive.zip")!
        let url2 = URL(string: "https://cdn.example.com/archive.zip")!
        let fixedDate = Date(timeIntervalSince1970: 1700000000)

        let h1 = BrowserDownloadHandoff(
            originalURL: url1,
            finalURL: url2,
            suggestedFilename: "archive.zip",
            mimeType: "application/zip",
            expectedContentLength: 1048576,
            source: .nativeWebKitDownload,
            timestamp: fixedDate
        )

        let h2 = BrowserDownloadHandoff(
            originalURL: url1,
            finalURL: url2,
            suggestedFilename: "archive.zip",
            mimeType: "application/zip",
            expectedContentLength: 1048576,
            source: .nativeWebKitDownload,
            timestamp: fixedDate
        )

        XCTAssertEqual(h1, h2)
        XCTAssertEqual(h1.source.rawValue, "Native WebKit Download")
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

    // MARK: - Milestone 7D: Webpage Resource & Media Discovery Tests

    func testHTMLExtraction_VideoAudioImageAndLinks() {
        let baseURL = URL(string: "https://example.com/media/index.html")!
        let html = """
        <!DOCTYPE html>
        <html>
        <head><title>Test Media Gallery</title></head>
        <body>
            <video src="trailers/sample_1080p.mp4" controls></video>
            <audio src="podcast/episode42.mp3"></audio>
            <video>
                <source src="assets/highres_stream.webm" type="video/webm">
            </video>
            <a href="downloads/manual_v1.pdf">User Manual PDF</a>
            <a href="packages/installer_x64.zip">Windows Installer Archive</a>
            <a href="/about-us">Regular Webpage Navigation Link</a>
            <img src="images/banner_artwork.png" alt="Hero Banner Art">
        </body>
        </html>
        """

        let resources = WebpageResourceExtractor.extractResources(fromHTML: html, baseURL: baseURL)

        // Verify counts and categories
        XCTAssertTrue(resources.contains { $0.url.absoluteString == "https://example.com/media/trailers/sample_1080p.mp4" && $0.resourceType == .video })
        XCTAssertTrue(resources.contains { $0.url.absoluteString == "https://example.com/media/podcast/episode42.mp3" && $0.resourceType == .audio })
        XCTAssertTrue(resources.contains { $0.url.absoluteString == "https://example.com/media/assets/highres_stream.webm" && $0.resourceType == .video })
        XCTAssertTrue(resources.contains { $0.url.absoluteString == "https://example.com/media/downloads/manual_v1.pdf" && $0.resourceType == .document })
        XCTAssertTrue(resources.contains { $0.url.absoluteString == "https://example.com/media/packages/installer_x64.zip" && $0.resourceType == .archive })
        XCTAssertTrue(resources.contains { $0.url.absoluteString == "https://example.com/media/images/banner_artwork.png" && $0.resourceType == .image })

        // Non-download navigation link (/about-us) must NOT be extracted
        XCTAssertFalse(resources.contains { $0.url.absoluteString.contains("about-us") })
    }

    func testHTMLExtraction_RelativeAndProtocolRelativeURLs() {
        let baseURL = URL(string: "https://example.com/articles/2026/")!
        let html = """
        <div>
            <video src="../media/clip.mp4#t=30s"></video>
            <a href="//cdn.example.org/bundles/update.tar.gz#checksum=abc">CDN Package</a>
            <img src="/static/logo.webp">
        </div>
        """

        let resources = WebpageResourceExtractor.extractResources(fromHTML: html, baseURL: baseURL)

        let video = resources.first { $0.resourceType == .video }
        XCTAssertNotNil(video)
        XCTAssertEqual(video?.url.absoluteString, "https://example.com/articles/media/clip.mp4")

        let archive = resources.first { $0.resourceType == .archive }
        XCTAssertNotNil(archive)
        XCTAssertEqual(archive?.url.absoluteString, "https://cdn.example.org/bundles/update.tar.gz")

        let image = resources.first { $0.resourceType == .image }
        XCTAssertNotNil(image)
        XCTAssertEqual(image?.url.absoluteString, "https://example.com/static/logo.webp")
    }

    func testHTMLExtraction_DuplicateURLElimination() {
        let baseURL = URL(string: "https://example.com/gallery")!
        let html = """
        <div>
            <a href="file.zip">Download ZIP</a>
            <a href="file.zip#part1">Download ZIP Part 1</a>
            <a href="FILE.ZIP">Download Case Insensitive</a>
            <video src="movie.mp4"></video>
            <video src="movie.mp4#t=0"></video>
        </div>
        """

        let resources = WebpageResourceExtractor.extractResources(fromHTML: html, baseURL: baseURL)

        let zipMatches = resources.filter { $0.suggestedFilename.lowercased() == "file.zip" }
        XCTAssertEqual(zipMatches.count, 1, "Duplicate URLs with fragments or casing differences must be deduplicated")

        let movieMatches = resources.filter { $0.suggestedFilename.lowercased() == "movie.mp4" }
        XCTAssertEqual(movieMatches.count, 1, "Duplicate video URLs must be deduplicated")
    }

    func testWebpageResource_FilenameAndMIMETypeInference() {
        let baseURL = URL(string: "https://example.com/")!
        let candidates = [
            WebpageRawResourceCandidate(rawURL: "https://example.com/api/get_doc", tag: "a", text: "Report", declaredType: "application/pdf"),
            WebpageRawResourceCandidate(rawURL: "https://example.com/songs/track01.flac", tag: "audio", text: "Track 01", declaredType: "audio/flac"),
            WebpageRawResourceCandidate(rawURL: "https://example.com/archive.tar.bz2", tag: "a", text: "Source Code")
        ]

        let results = WebpageResourceExtractor.extractFromRawCandidates(candidates, baseURL: baseURL)

        XCTAssertEqual(results.count, 3)

        let doc = results.first { $0.title == "Report" }
        XCTAssertEqual(doc?.resourceType, .document)
        XCTAssertTrue(doc?.suggestedFilename.hasSuffix(".pdf") == true)

        let audio = results.first { $0.title == "Track 01" }
        XCTAssertEqual(audio?.resourceType, .audio)
        XCTAssertEqual(audio?.suggestedFilename, "track01.flac")

        let archive = results.first { $0.title == "Source Code" }
        XCTAssertEqual(archive?.resourceType, .archive)
        XCTAssertEqual(archive?.suggestedFilename, "archive.tar.bz2")
    }

    func testWebpageResource_HonestLimitations_UnsupportedSchemes() {
        let baseURL = URL(string: "https://example.com/")!
        let candidates = [
            WebpageRawResourceCandidate(rawURL: "blob:https://example.com/83bc537b-9447-4f67-a279-d6e06b3aa731", tag: "video"),
            WebpageRawResourceCandidate(rawURL: "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==", tag: "img"),
            WebpageRawResourceCandidate(rawURL: "https://example.com/live/master.m3u8", tag: "source", declaredType: "application/x-mpegURL"),
            WebpageRawResourceCandidate(rawURL: "https://example.com/streams/dash.mpd", tag: "source", declaredType: "application/dash+xml"),
            WebpageRawResourceCandidate(rawURL: "ftp://example.com/build.iso", tag: "a", text: "ISO File"),
            WebpageRawResourceCandidate(rawURL: "https://example.com/valid_release.dmg", tag: "a", text: "Mac Installer")
        ]

        let results = WebpageResourceExtractor.extractFromRawCandidates(candidates, baseURL: baseURL)

        // 1. Blob URL
        let blob = results.first { $0.url.absoluteString.hasPrefix("blob:") }
        XCTAssertNotNil(blob)
        XCTAssertFalse(blob!.isSupported)
        XCTAssertTrue(blob!.unsupportedReason?.contains("Blob URLs") == true)

        // 2. Data URI
        let dataURI = results.first { $0.url.absoluteString.hasPrefix("data:") }
        XCTAssertNotNil(dataURI)
        XCTAssertFalse(dataURI!.isSupported)
        XCTAssertTrue(dataURI!.unsupportedReason?.contains("Data URIs") == true)

        // 3. HLS m3u8 Manifest
        let hls = results.first { $0.url.absoluteString.contains("master.m3u8") }
        XCTAssertNotNil(hls)
        XCTAssertFalse(hls!.isSupported)
        XCTAssertTrue(hls!.unsupportedReason?.contains("manifest-aware") == true)

        // 4. DASH mpd Manifest
        let dash = results.first { $0.url.absoluteString.contains("dash.mpd") }
        XCTAssertNotNil(dash)
        XCTAssertFalse(dash!.isSupported)
        XCTAssertTrue(dash!.unsupportedReason?.contains("manifest-aware") == true)

        // 5. FTP scheme
        let ftp = results.first { $0.url.absoluteString.hasPrefix("ftp:") }
        XCTAssertNotNil(ftp)
        XCTAssertFalse(ftp!.isSupported)
        XCTAssertTrue(ftp!.unsupportedReason?.contains("Unsupported URL scheme") == true)

        // 6. Valid DMG download
        let dmg = results.first { $0.url.absoluteString.contains("valid_release.dmg") }
        XCTAssertNotNil(dmg)
        XCTAssertTrue(dmg!.isSupported)
        XCTAssertNil(dmg!.unsupportedReason)
    }

    func testWebpageResource_MalformedHTMLEmptyResults() {
        let baseURL = URL(string: "https://example.com/")!

        // Empty HTML
        let emptyResults = WebpageResourceExtractor.extractResources(fromHTML: "", baseURL: baseURL)
        XCTAssertTrue(emptyResults.isEmpty)

        // Malformed HTML without tags
        let malformed = "Just raw text with no tags or urls <<>> <tag without closing"
        let malformedResults = WebpageResourceExtractor.extractResources(fromHTML: malformed, baseURL: baseURL)
        XCTAssertTrue(malformedResults.isEmpty)

        // Broken anchor tag with valid URL inside
        let brokenTag = "<div><a href=\"broken_link.zip\" unclosed attribute... <p>Hello</p>"
        let brokenResults = WebpageResourceExtractor.extractResources(fromHTML: brokenTag, baseURL: baseURL)
        // NSRegularExpression handles partial content safely without crashing
        XCTAssertNotNil(brokenResults)
    }

    func testWebpageResource_CategorizationAccuracy() {
        XCTAssertEqual(WebpageResourceExtractor.categorize(extension: "mp4", mimeType: nil), .video)
        XCTAssertEqual(WebpageResourceExtractor.categorize(extension: "mkv", mimeType: nil), .video)
        XCTAssertEqual(WebpageResourceExtractor.categorize(extension: "mp3", mimeType: nil), .audio)
        XCTAssertEqual(WebpageResourceExtractor.categorize(extension: "flac", mimeType: nil), .audio)
        XCTAssertEqual(WebpageResourceExtractor.categorize(extension: "pdf", mimeType: nil), .document)
        XCTAssertEqual(WebpageResourceExtractor.categorize(extension: "docx", mimeType: nil), .document)
        XCTAssertEqual(WebpageResourceExtractor.categorize(extension: "zip", mimeType: nil), .archive)
        XCTAssertEqual(WebpageResourceExtractor.categorize(extension: "tar", mimeType: nil), .archive)
        XCTAssertEqual(WebpageResourceExtractor.categorize(extension: "dmg", mimeType: nil), .archive)
        XCTAssertEqual(WebpageResourceExtractor.categorize(extension: "png", mimeType: nil), .image)
        XCTAssertEqual(WebpageResourceExtractor.categorize(extension: "webp", mimeType: nil), .image)
        XCTAssertEqual(WebpageResourceExtractor.categorize(extension: "unknown", mimeType: "video/mp4"), .video)
        XCTAssertEqual(WebpageResourceExtractor.categorize(extension: "dat", mimeType: "application/pdf"), .document)
        XCTAssertEqual(WebpageResourceExtractor.categorize(extension: nil, mimeType: "application/zip"), .archive)
        XCTAssertEqual(WebpageResourceExtractor.categorize(extension: "html", mimeType: "text/html"), .other)
    }

    #if canImport(SwiftUI)
    @MainActor
    func testBrowserViewModel_ResourceInspectorState() async throws {
        let mockDelegate = MockDownloadDelegate()
        let vm = BrowserViewModel(downloadDelegate: mockDelegate)

        // Initial state
        XCTAssertFalse(vm.isShowingResourceInspector)
        XCTAssertFalse(vm.isScanningResources)
        XCTAssertTrue(vm.discoveredResources.isEmpty)
        XCTAssertTrue(vm.selectedResourceIDs.isEmpty)

        // Inspect with no URL
        vm.inspectCurrentPageResources()
        XCTAssertNotNil(vm.resourceScanError)

        // Mock populate discovered resources
        let res1 = WebpageResource(
            url: URL(string: "https://example.com/asset1.mp4")!,
            title: "Asset 1",
            suggestedFilename: "asset1.mp4",
            resourceType: .video,
            isSupported: true
        )
        let res2 = WebpageResource(
            url: URL(string: "https://example.com/asset2.pdf")!,
            title: "Asset 2",
            suggestedFilename: "asset2.pdf",
            resourceType: .document,
            isSupported: true
        )
        let unsupportedRes = WebpageResource(
            url: URL(string: "blob:https://example.com/uuid")!,
            title: "Blob Stream",
            suggestedFilename: "stream.blob",
            resourceType: .video,
            isSupported: false,
            unsupportedReason: "Blob URLs are unsupported."
        )

        vm.discoveredResources = [res1, res2, unsupportedRes]

        // Select supported resources and unsupported resource
        vm.selectedResourceIDs = [res1.id, res2.id, unsupportedRes.id]

        // Execute batch download
        try await vm.downloadSelectedResources()

        // Verify only supported resources were submitted to delegate
        XCTAssertEqual(mockDelegate.downloadRequests.count, 2)
        XCTAssertTrue(mockDelegate.downloadRequests.contains { $0.url == res1.url })
        XCTAssertTrue(mockDelegate.downloadRequests.contains { $0.url == res2.url })
        XCTAssertFalse(mockDelegate.downloadRequests.contains { $0.url == unsupportedRes.url })

        // Verify post-batch state
        XCTAssertTrue(vm.selectedResourceIDs.isEmpty)
        XCTAssertFalse(vm.isShowingResourceInspector)
        XCTAssertNotNil(vm.downloadSuccessNotification)
    }
    #endif
}
