import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import DM_Reverse_engineering

final class DownloadRequestEnricherTests: XCTestCase {

    override func setUp() {
        super.setUp()
        DownloadRequestEnricher.sharedSessionSnapshot.snapshot = nil
    }

    override func tearDown() {
        DownloadRequestEnricher.sharedSessionSnapshot.snapshot = nil
        super.tearDown()
    }

    private func makeCookie(name: String, value: String, domain: String, path: String = "/", isSecure: Bool = false) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: path
        ]
        if isSecure {
            properties[.secure] = "TRUE"
        }
        return HTTPCookie(properties: properties)!
    }

    func testHTTPCookieRFC6265Matching() {
        let cookie1 = makeCookie(name: "cf_clearance", value: "token123", domain: ".goplay.su")
        let cookie2 = makeCookie(name: "sub_token", value: "sub456", domain: "cdn.goplay.su")
        let cookie3 = makeCookie(name: "secure_token", value: "sec789", domain: "goplay.su", isSecure: true)

        let httpsRoot = URL(string: "https://goplay.su/video")!
        let httpsCDN = URL(string: "https://cdn.goplay.su/media/playlist.m3u8")!
        let httpRoot = URL(string: "http://goplay.su/video")!
        let otherDomain = URL(string: "https://example.com/video")!

        // cookie1 (.goplay.su) matches both root and subdomain
        XCTAssertTrue(cookie1.matches(url: httpsRoot))
        XCTAssertTrue(cookie1.matches(url: httpsCDN))
        XCTAssertFalse(cookie1.matches(url: otherDomain))

        // cookie2 (cdn.goplay.su) only matches cdn.goplay.su, NOT root goplay.su
        XCTAssertFalse(cookie2.matches(url: httpsRoot))
        XCTAssertTrue(cookie2.matches(url: httpsCDN))

        // cookie3 (secure) matches HTTPS only
        XCTAssertTrue(cookie3.matches(url: httpsRoot))
        XCTAssertFalse(cookie3.matches(url: httpRoot))
    }

    func testEnrichInjectsUserAgentAndCookiesForMatchingDomain() {
        let cookie1 = makeCookie(name: "cf_clearance", value: "abc123token", domain: ".goplay.su")
        let cookie2 = makeCookie(name: "__cf_bm", value: "bm456", domain: "goplay.su")
        let cookieOther = makeCookie(name: "other_session", value: "xyz", domain: "other.com")

        let snapshot = BrowserSessionSnapshot(
            userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15",
            acceptLanguage: "en-US",
            allCookies: [cookie1, cookie2, cookieOther]
        )

        let targetURL = URL(string: "https://cdn.goplay.su/media/playlist.m3u8")!
        var request = URLRequest(url: targetURL)
        request = DownloadRequestEnricher.enrich(request, snapshot: snapshot)

        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Language"), "en-US")
        let cookieHeader = request.value(forHTTPHeaderField: "Cookie") ?? ""
        XCTAssertTrue(cookieHeader.contains("cf_clearance=abc123token"))
        XCTAssertFalse(cookieHeader.contains("other_session"))
    }

    func testEnrichPreservesCallerSpecifiedHeaders() {
        let cookie = makeCookie(name: "cf_clearance", value: "snapshot_token", domain: "goplay.su")
        let snapshot = BrowserSessionSnapshot(
            userAgent: "Snapshot-UA",
            acceptLanguage: "en-US",
            allCookies: [cookie]
        )

        let targetURL = URL(string: "https://goplay.su/video.mp4")!
        var request = URLRequest(url: targetURL)
        request.setValue("Custom-Caller-UA/2.0", forHTTPHeaderField: "User-Agent")
        request.setValue("CustomCookie=existing", forHTTPHeaderField: "Cookie")

        request = DownloadRequestEnricher.enrich(request, snapshot: snapshot)

        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Custom-Caller-UA/2.0")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "CustomCookie=existing")
    }

    func testEnrichDoesNotAttachCookiesForUnrelatedDomain() {
        let cookie = makeCookie(name: "cf_clearance", value: "secret", domain: "goplay.su")
        let snapshot = BrowserSessionSnapshot(
            userAgent: "Test-UA",
            acceptLanguage: "en-US",
            allCookies: [cookie]
        )

        let targetURL = URL(string: "https://unrelated-domain.com/video.mp4")!
        var request = URLRequest(url: targetURL)
        request = DownloadRequestEnricher.enrich(request, snapshot: snapshot)

        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Test-UA")
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    }

    func testEnrichInjectsBrowserContextHeaders() {
        let pageURL = URL(string: "https://goplay.su/watch/movie-123")!
        let targetURL = URL(string: "https://cdn.goplay.su/media.m3u8")!
        let snapshot = BrowserSessionSnapshot(
            userAgent: "Mozilla/5.0",
            acceptLanguage: "en-US",
            allCookies: [],
            pageURL: pageURL
        )

        var request = URLRequest(url: targetURL)
        request = DownloadRequestEnricher.enrich(request, snapshot: snapshot)

        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "*/*")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://goplay.su")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://goplay.su/watch/movie-123")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Sec-Fetch-Dest"), "empty")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Sec-Fetch-Mode"), "cors")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Sec-Fetch-Site"), "same-site")
    }

    func testHandleRedirectPreservesRangeAndEnrichesTarget() {
        let originalURL = URL(string: "https://goplay.su/api/video")!
        let targetURL = URL(string: "https://cdn.goplay.su/media.m3u8")!
        var originalRequest = URLRequest(url: originalURL)
        originalRequest.setValue("bytes=0-1024", forHTTPHeaderField: "Range")

        let targetCookie = HTTPCookie(properties: [
            .domain: ".goplay.su",
            .path: "/",
            .name: "cf_clearance",
            .value: "clearance_token_123"
        ])!

        let snapshot = BrowserSessionSnapshot(
            userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)",
            acceptLanguage: "en-US",
            allCookies: [targetCookie],
            pageURL: URL(string: "https://goplay.su/watch/123")!
        )

        let task = URLSession.shared.dataTask(with: originalRequest)
        let response = HTTPURLResponse(
            url: originalURL,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": targetURL.absoluteString]
        )!

        let newRequest = URLRequest(url: targetURL)
        let enriched = DownloadRequestEnricher.handleRedirect(
            task: task,
            response: response,
            newRequest: newRequest,
            snapshot: snapshot
        )

        XCTAssertEqual(enriched.value(forHTTPHeaderField: "Range"), "bytes=0-1024")
        XCTAssertEqual(enriched.value(forHTTPHeaderField: "User-Agent"), "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)")
        XCTAssertTrue(enriched.value(forHTTPHeaderField: "Cookie")?.contains("cf_clearance=clearance_token_123") == true)
        XCTAssertEqual(enriched.value(forHTTPHeaderField: "Referer"), "https://goplay.su/watch/123")
    }

    func testBrowserSessionSnapshotCookiesByDomain() {
        let cookie1 = HTTPCookie(properties: [
            .domain: ".example.com",
            .path: "/",
            .name: "token",
            .value: "abc"
        ])!
        let cookie2 = HTTPCookie(properties: [
            .domain: "cdn.example.com",
            .path: "/",
            .name: "cf_clearance",
            .value: "xyz"
        ])!

        let snapshot = BrowserSessionSnapshot(
            userAgent: "Mozilla/5.0",
            acceptLanguage: "en-US",
            allCookies: [cookie1, cookie2]
        )

        XCTAssertEqual(snapshot.cookiesByDomain.count, 2)
        XCTAssertEqual(snapshot.cookiesByDomain[".example.com"]?.count, 1)
        XCTAssertEqual(snapshot.cookiesByDomain["cdn.example.com"]?.count, 1)
    }

    func testHTTPCookieRFC6265PathBoundaryMatching() {
        let cookie = makeCookie(name: "sid", value: "abc", domain: "example.com", path: "/account")

        // Exact match
        XCTAssertTrue(cookie.matches(url: URL(string: "https://example.com/account")!))
        // Trailing slash match
        XCTAssertTrue(cookie.matches(url: URL(string: "https://example.com/account/")!))
        // Subpath match with slash boundary
        XCTAssertTrue(cookie.matches(url: URL(string: "https://example.com/account/settings")!))
        XCTAssertTrue(cookie.matches(url: URL(string: "https://example.com/account/sub/path")!))

        // Non-boundary prefixes MUST NOT match (RFC 6265 §5.1.4)
        XCTAssertFalse(cookie.matches(url: URL(string: "https://example.com/accounting")!))
        XCTAssertFalse(cookie.matches(url: URL(string: "https://example.com/account-billing")!))
        XCTAssertFalse(cookie.matches(url: URL(string: "https://example.com/accountant")!))
        XCTAssertFalse(cookie.matches(url: URL(string: "https://example.com/other")!))
    }

    func testEnrichIsolatesBrowserRequestContextFromSharedSnapshot() {
        // Set up global snapshot with leaked credentials
        let globalCookie = makeCookie(name: "leak_cookie", value: "global_secret", domain: "example.com")
        DownloadRequestEnricher.sharedSessionSnapshot.snapshot = BrowserSessionSnapshot(
            userAgent: "Global-Shared-UA",
            acceptLanguage: "en-US",
            allCookies: [globalCookie]
        )

        // Set up isolated tab context with separate cookies and User-Agent
        let isolatedCookie = BrowserCookie(name: "tab_cookie", value: "tab_secret", domain: "example.com", path: "/")
        let tabContext = BrowserRequestContext(
            url: URL(string: "https://example.com/media/file.mp4")!,
            pageURL: URL(string: "https://example.com/page")!,
            userAgent: "Isolated-Tab-UA",
            cookies: [isolatedCookie],
            source: .webpageResource
        )

        let req = URLRequest(url: URL(string: "https://example.com/media/file.mp4")!)
        let enriched = DownloadRequestEnricher.enrich(req, context: tabContext)

        // Must use isolated tab User-Agent, NOT the global snapshot User-Agent
        XCTAssertEqual(enriched.value(forHTTPHeaderField: "User-Agent"), "Isolated-Tab-UA")
        // Must contain tab cookie, NOT global leak cookie
        let cookieHeader = enriched.value(forHTTPHeaderField: "Cookie") ?? ""
        XCTAssertTrue(cookieHeader.contains("tab_cookie=tab_secret"))
        XCTAssertFalse(cookieHeader.contains("leak_cookie"))
    }

    func testFilenameSanitizationEdgeCases() {
        // Dot-only and empty names must fall back safely
        XCTAssertEqual(HTTPRangeProbe.sanitizeFilename("."), "")
        XCTAssertEqual(HTTPRangeProbe.sanitizeFilename(".."), "")
        XCTAssertEqual(HTTPRangeProbe.sanitizeFilename("..."), "")
        XCTAssertEqual(HTTPRangeProbe.sanitizeFilename("   "), "")
        XCTAssertEqual(HTTPRangeProbe.sanitizeFilename(":::"), "")

        // Resolve filename with dot-only disposition falls back to URL component or "download"
        let fallbackUrl = URL(string: "https://example.com/downloads/my_archive.zip")!
        let resolved = HTTPRangeProbe.resolveFilename(contentDisposition: "filename=\"...\"", finalURL: fallbackUrl, mimeType: "application/zip")
        XCTAssertEqual(resolved, "my_archive.zip")

        // Content-Disposition with empty or invalid name and bare URL falls back to "download.<ext>"
        let rootUrl = URL(string: "https://example.com/")!
        let resolvedRoot = HTTPRangeProbe.resolveFilename(contentDisposition: "filename=\"???\"", finalURL: rootUrl, mimeType: "video/mp4")
        XCTAssertEqual(resolvedRoot, "download.mp4")
    }

    func testValidatedDownloadsDirectoryExcludesVolatileStorage() throws {
        let dir = try DownloadManagerViewModel.validatedDownloadsDirectory()
        // Must NOT be in Caches or Temporary directory
        XCTAssertFalse(dir.path.contains("/Caches/"))
        XCTAssertFalse(dir.path.contains("/tmp/"))
        XCTAssertFalse(dir.path.contains("/1DMDownloads"))
        XCTAssertTrue(FileManager.default.isWritableFile(atPath: dir.path))
    }

    func testIfRangeValidatorRFC7233Compliance() {
        // Strong ETag should be used directly
        let strong = "\"strong-etag-123\""
        XCTAssertEqual(
            DownloadRequestEnricher.ifRangeValidator(eTag: strong, lastModified: "Wed, 21 Oct 2026 07:28:00 GMT"),
            strong,
            "Strong ETag must take precedence and be preserved"
        )

        // Weak ETag (W/...) MUST NOT be used in If-Range (RFC 7233 §3.2); must fallback to Last-Modified
        let weak = "W/\"weak-etag-456\""
        let lastMod = "Wed, 21 Oct 2026 07:28:00 GMT"
        XCTAssertEqual(
            DownloadRequestEnricher.ifRangeValidator(eTag: weak, lastModified: lastMod),
            lastMod,
            "Weak ETag must be rejected for If-Range in favor of Last-Modified"
        )

        // Lowercase weak ETag (w/...) must also fallback
        let lowerWeak = "w/\"weak-etag-789\""
        XCTAssertEqual(
            DownloadRequestEnricher.ifRangeValidator(eTag: lowerWeak, lastModified: lastMod),
            lastMod,
            "Lowercase weak ETag must be rejected for If-Range"
        )

        // Weak ETag without Last-Modified must return nil (never emit a weak If-Range)
        XCTAssertNil(
            DownloadRequestEnricher.ifRangeValidator(eTag: weak, lastModified: nil),
            "Weak ETag without Last-Modified must return nil to prevent 200 OK degradation"
        )

        XCTAssertNil(
            DownloadRequestEnricher.ifRangeValidator(eTag: weak, lastModified: "   "),
            "Weak ETag with whitespace-only Last-Modified must return nil"
        )

        // Empty ETag with Last-Modified falls back to Last-Modified
        XCTAssertEqual(
            DownloadRequestEnricher.ifRangeValidator(eTag: "", lastModified: lastMod),
            lastMod,
            "Empty ETag must fallback to Last-Modified"
        )

        // Both nil/empty must return nil
        XCTAssertNil(DownloadRequestEnricher.ifRangeValidator(eTag: nil, lastModified: nil))
    }

    func testHandleRedirectStripsAuthorizationAndSensitiveHeadersOnCrossOriginRedirect() {
        let originalURL = URL(string: "https://auth.example.com/download/file.bin")!
        let crossOriginURL = URL(string: "https://cdn.thirdparty.com/file.bin")!

        var originalRequest = URLRequest(url: originalURL)
        originalRequest.setValue("Bearer secret_jwt_token", forHTTPHeaderField: "Authorization")
        originalRequest.setValue("my-secret-key", forHTTPHeaderField: "X-Api-Key")
        originalRequest.setValue("bytes=0-100", forHTTPHeaderField: "Range")

        var newRequest = URLRequest(url: crossOriginURL)
        newRequest.setValue("Bearer secret_jwt_token", forHTTPHeaderField: "Authorization")
        newRequest.setValue("my-secret-key", forHTTPHeaderField: "X-Api-Key")

        let session = URLSession(configuration: .default)
        let task = session.dataTask(with: originalRequest)
        let response = HTTPURLResponse(url: originalURL, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: [:])!

        let redirected = DownloadRequestEnricher.handleRedirect(
            task: task,
            response: response,
            newRequest: newRequest,
            snapshot: nil
        )

        // RFC 7235 §2.2 / RFC 9110 §15.4: Authorization and sensitive headers MUST be stripped across origins
        XCTAssertNil(redirected.value(forHTTPHeaderField: "Authorization"), "Authorization header must be stripped on cross-origin redirect")
        XCTAssertNil(redirected.value(forHTTPHeaderField: "X-Api-Key"), "Sensitive API key header must be stripped on cross-origin redirect")
        // Range must be preserved
        XCTAssertEqual(redirected.value(forHTTPHeaderField: "Range"), "bytes=0-100", "Range header must be preserved across redirect")
    }

    func testHandleRedirectIsolatesCookiesOnCrossSiteRedirect() {
        let originalURL = URL(string: "https://first-site.com/start")!
        let targetURL = URL(string: "https://second-site.com/finish")!

        let firstCookie = makeCookie(name: "first_token", value: "secret1", domain: "first-site.com")
        let secondCookie = makeCookie(name: "second_token", value: "secret2", domain: "second-site.com")

        let snapshot = BrowserSessionSnapshot(
            userAgent: "Test-Agent",
            acceptLanguage: "en-US",
            allCookies: [firstCookie, secondCookie]
        )

        var originalRequest = URLRequest(url: originalURL)
        originalRequest.setValue("first_token=secret1", forHTTPHeaderField: "Cookie")

        var newRequest = URLRequest(url: targetURL)
        // Simulate URLSession carrying over existing Cookie header
        newRequest.setValue("first_token=secret1", forHTTPHeaderField: "Cookie")

        let session = URLSession(configuration: .default)
        let task = session.dataTask(with: originalRequest)
        let response = HTTPURLResponse(url: originalURL, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: [:])!

        let redirected = DownloadRequestEnricher.handleRedirect(
            task: task,
            response: response,
            newRequest: newRequest,
            snapshot: snapshot
        )

        let cookieHeader = redirected.value(forHTTPHeaderField: "Cookie") ?? ""
        // RFC 6265 §5.4: first-site cookies must NOT leak to second-site!
        XCTAssertFalse(cookieHeader.contains("first_token"), "First-site cookie must not leak to second-site on cross-site redirect")
        XCTAssertTrue(cookieHeader.contains("second_token=secret2"), "Second-site matching cookie must be attached for target domain")
    }

    func testEnrichAndRedirectSuppressesRefererOnHTTPSDowngradeToHTTP() {
        let securePage = URL(string: "https://secure.example.com/watch/video")!
        let insecureTarget = URL(string: "http://insecure.example.com/stream.mp4")!

        let snapshot = BrowserSessionSnapshot(
            userAgent: "Secure-UA",
            acceptLanguage: "en-US",
            allCookies: [],
            pageURL: securePage
        )

        let req = URLRequest(url: insecureTarget)
        let enriched = DownloadRequestEnricher.enrich(req, snapshot: snapshot)

        // RFC 7231 §5.5.2: HTTPS referer MUST NOT be sent to HTTP target
        XCTAssertNil(enriched.value(forHTTPHeaderField: "Referer"), "HTTPS Referer must not be sent over insecure HTTP")
        XCTAssertNil(enriched.value(forHTTPHeaderField: "Origin"), "Origin must not be sent on HTTPS to HTTP downgrade")

        // Also test in handleRedirect
        var originalRequest = URLRequest(url: securePage)
        originalRequest.setValue("https://secure.example.com/watch/video", forHTTPHeaderField: "Referer")
        var newRequest = URLRequest(url: insecureTarget)
        newRequest.setValue("https://secure.example.com/watch/video", forHTTPHeaderField: "Referer")

        let session = URLSession(configuration: .default)
        let task = session.dataTask(with: originalRequest)
        let response = HTTPURLResponse(url: securePage, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: [:])!

        let redirected = DownloadRequestEnricher.handleRedirect(
            task: task,
            response: response,
            newRequest: newRequest,
            snapshot: snapshot
        )

        XCTAssertNil(redirected.value(forHTTPHeaderField: "Referer"), "Referer must be stripped on HTTPS to HTTP redirect downgrade")
    }
}
