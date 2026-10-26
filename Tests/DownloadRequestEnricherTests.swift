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
}
