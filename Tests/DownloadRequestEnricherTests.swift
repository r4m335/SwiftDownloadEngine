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

    func testRegistrableDomainExtraction() {
        XCTAssertEqual(DownloadRequestEnricher.registrableDomain("goplay.su"), "goplay.su")
        XCTAssertEqual(DownloadRequestEnricher.registrableDomain("cdn.goplay.su"), "goplay.su")
        XCTAssertEqual(DownloadRequestEnricher.registrableDomain("v3.stream.goplay.su"), "goplay.su")
        XCTAssertEqual(DownloadRequestEnricher.registrableDomain(".goplay.su"), "goplay.su")
        XCTAssertEqual(DownloadRequestEnricher.registrableDomain("localhost"), "localhost")
    }

    func testEnrichInjectsUserAgentAndCookiesForMatchingDomain() {
        let snapshot = BrowserSessionSnapshot(
            userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15",
            acceptLanguage: "en-US",
            cookiesByDomain: [
                "goplay.su": "cf_clearance=abc123token; __cf_bm=bm456",
                "other.com": "session=xyz"
            ]
        )

        let targetURL = URL(string: "https://cdn.goplay.su/media/playlist.m3u8")!
        var request = URLRequest(url: targetURL)
        request = DownloadRequestEnricher.enrich(request, snapshot: snapshot)

        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Language"), "en-US")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "cf_clearance=abc123token; __cf_bm=bm456")
    }

    func testEnrichPreservesCallerSpecifiedHeaders() {
        let snapshot = BrowserSessionSnapshot(
            userAgent: "Snapshot-UA",
            acceptLanguage: "en-US",
            cookiesByDomain: [
                "goplay.su": "cf_clearance=snapshot_token"
            ]
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
        let snapshot = BrowserSessionSnapshot(
            userAgent: "Test-UA",
            acceptLanguage: "en-US",
            cookiesByDomain: [
                "goplay.su": "cf_clearance=secret"
            ]
        )

        let targetURL = URL(string: "https://unrelated-domain.com/video.mp4")!
        var request = URLRequest(url: targetURL)
        request = DownloadRequestEnricher.enrich(request, snapshot: snapshot)

        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Test-UA")
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    }
}
