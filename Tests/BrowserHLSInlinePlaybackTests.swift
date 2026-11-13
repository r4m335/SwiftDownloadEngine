import XCTest
@testable import DM_Reverse_engineering

final class BrowserHLSInlinePlaybackTests: XCTestCase {

    // MARK: - Classification & Interception Tests

    func testDirectM3U8MainFrameInterceptionForInlinePlayback() {
        let url = URL(string: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8")!

        let outcome = BrowserNavigationResponseClassifier.evaluate(
            url: url,
            statusCode: 200,
            contentType: "application/vnd.apple.mpegurl"
        )

        XCTAssertTrue(outcome.isStreamingManifest)
        XCTAssertEqual(outcome.manifestKind, .hls)
        XCTAssertTrue(outcome.shouldPlayHLSInline)
        XCTAssertFalse(outcome.shouldInterceptAsDownload)
        XCTAssertEqual(outcome.suggestedFilename, "x36xhzz.m3u8")

        let shouldIntercept = BrowserNavigationResponseClassifier.shouldInterceptForInlineHLS(
            isForMainFrame: true,
            url: url,
            statusCode: 200,
            contentType: "application/vnd.apple.mpegurl"
        )
        XCTAssertTrue(shouldIntercept)
    }

    func testHLSMIMETypeWithoutM3U8ExtensionInterception() {
        let appleMIMEURL = URL(string: "https://streaming.example.com/live/channel1?session=987")!
        let outcomeApple = BrowserNavigationResponseClassifier.evaluate(
            url: appleMIMEURL,
            statusCode: 200,
            contentType: "application/vnd.apple.mpegurl; charset=utf-8"
        )
        XCTAssertTrue(outcomeApple.isStreamingManifest)
        XCTAssertEqual(outcomeApple.manifestKind, .hls)
        XCTAssertTrue(outcomeApple.shouldPlayHLSInline)

        let xMIMEURL = URL(string: "https://streaming.example.com/stream/index")!
        let outcomeX = BrowserNavigationResponseClassifier.evaluate(
            url: xMIMEURL,
            statusCode: 200,
            contentType: "application/x-mpegurl"
        )
        XCTAssertTrue(outcomeX.isStreamingManifest)
        XCTAssertEqual(outcomeX.manifestKind, .hls)
        XCTAssertTrue(outcomeX.shouldPlayHLSInline)

        XCTAssertTrue(BrowserNavigationResponseClassifier.shouldInterceptForInlineHLS(
            isForMainFrame: true,
            url: xMIMEURL,
            statusCode: 200,
            contentType: "application/x-mpegurl"
        ))
    }

    func testNonMainFrameSubresourceIsNeverIntercepted() {
        let url = URL(string: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8")!

        // Subframe or subresource navigation (e.g., iframe or background load)
        let shouldIntercept = BrowserNavigationResponseClassifier.shouldInterceptForInlineHLS(
            isForMainFrame: false,
            url: url,
            statusCode: 200,
            contentType: "application/vnd.apple.mpegurl"
        )
        XCTAssertFalse(shouldIntercept, "Subframe HLS requests must not take over the main tab")
    }

    func testSegmentAndSubresourceRequestsAreNotStreamingManifests() {
        let testCases: [(String, String)] = [
            ("https://stream.example.com/segment_001.ts", "video/mp2t"),
            ("https://stream.example.com/chunk_001.m4s", "video/iso.segment"),
            ("https://stream.example.com/init.mp4", "video/mp4"),
            ("https://stream.example.com/enc.key", "application/octet-stream")
        ]

        for (urlString, mime) in testCases {
            let url = URL(string: urlString)!
            let outcome = BrowserNavigationResponseClassifier.evaluate(
                url: url,
                statusCode: 200,
                contentType: mime
            )
            XCTAssertFalse(outcome.isStreamingManifest, "Segment \(urlString) should not be classified as a manifest")
            XCTAssertFalse(outcome.shouldPlayHLSInline)
            XCTAssertFalse(BrowserNavigationResponseClassifier.shouldInterceptForInlineHLS(
                isForMainFrame: true,
                url: url,
                statusCode: 200,
                contentType: mime
            ))
        }
    }

    func testDASHManifestDoesNotTriggerHLSInlinePlayback() {
        let url = URL(string: "https://dash.example.com/manifest.mpd")!
        let outcome = BrowserNavigationResponseClassifier.evaluate(
            url: url,
            statusCode: 200,
            contentType: "application/dash+xml"
        )

        XCTAssertTrue(outcome.isStreamingManifest)
        XCTAssertEqual(outcome.manifestKind, .dash)
        XCTAssertFalse(outcome.shouldPlayHLSInline, "DASH manifests must not trigger the HLS inline player")

        let shouldIntercept = BrowserNavigationResponseClassifier.shouldInterceptForInlineHLS(
            isForMainFrame: true,
            url: url,
            statusCode: 200,
            contentType: "application/dash+xml"
        )
        XCTAssertFalse(shouldIntercept)
    }

    func testManifestResourceIngestionAndMetadataPreservation() {
        let url = URL(string: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8")!
        let outcome = BrowserNavigationResponseClassifier.evaluate(
            url: url,
            statusCode: 200,
            contentType: "application/vnd.apple.mpegurl"
        )

        guard let resource = outcome.resource else {
            XCTFail("Outcome must contain an ingested WebpageResource")
            return
        }

        XCTAssertEqual(resource.url, url)
        XCTAssertEqual(resource.resourceType, .video)
        XCTAssertTrue(resource.isStreamingManifest)
        XCTAssertEqual(resource.suggestedFilename, "x36xhzz.m3u8")
    }

    // MARK: - HTML Player Generation Tests

    func testInlineHTMLGenerationStructureAndPlaysInlineAttributes() {
        let streamURL = URL(string: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8")!
        let html = BrowserHLSInlinePlayer.html(for: streamURL, title: "Big Buck Bunny HLS")

        XCTAssertTrue(BrowserHLSInlinePlayer.isInlinePlayerHTML(html))
        XCTAssertTrue(html.contains("id=\"hls-player\""))
        XCTAssertTrue(html.contains("playsinline"))
        XCTAssertTrue(html.contains("webkit-playsinline"))
        XCTAssertTrue(html.contains("controls"))
        XCTAssertTrue(html.contains("type=\"application/vnd.apple.mpegurl\""))
        XCTAssertTrue(html.contains("type=\"application/x-mpegurl\""))
        XCTAssertTrue(html.contains("Big Buck Bunny HLS"))
        XCTAssertTrue(html.contains("test-streams.mux.dev"))
        XCTAssertTrue(html.contains("HLS Stream"))
        XCTAssertTrue(html.contains("id=\"error-banner\""))
        XCTAssertTrue(html.contains("Retry Playback"))
        XCTAssertTrue(html.contains("retryPlayback()"))
        XCTAssertTrue(html.contains("Tap Download in toolbar to save specific resolutions."))
        XCTAssertTrue(html.contains("#0b0f19"), "Must use LID dark background color")
    }

    func testHTMLEscapingPreventsInjection() {
        let streamURL = URL(string: "https://evil.example.com/play?q=<script>alert('xss')</script>")!
        let maliciousTitle = "Video <script>alert('hacked')</script> & More \"Quotes\""
        let html = BrowserHLSInlinePlayer.html(for: streamURL, title: maliciousTitle)

        XCTAssertFalse(html.contains("<script>alert('hacked')</script>"))
        XCTAssertTrue(html.contains("&lt;script&gt;alert(&#39;hacked&#39;)&lt;/script&gt;"))
        XCTAssertTrue(html.contains("&amp; More &quot;Quotes&quot;"))
    }

    func testOrdinaryWebpageAndDirectDownloadBypassInlineHLS() {
        let pageURL = URL(string: "https://example.com/article/123")!
        let pageOutcome = BrowserNavigationResponseClassifier.evaluate(
            url: pageURL,
            statusCode: 200,
            contentType: "text/html; charset=utf-8"
        )
        XCTAssertFalse(pageOutcome.isStreamingManifest)
        XCTAssertFalse(pageOutcome.shouldPlayHLSInline)
        XCTAssertFalse(pageOutcome.shouldInterceptAsDownload)

        let zipURL = URL(string: "https://example.com/release.zip")!
        let zipOutcome = BrowserNavigationResponseClassifier.evaluate(
            url: zipURL,
            statusCode: 200,
            contentType: "application/zip"
        )
        XCTAssertFalse(zipOutcome.isStreamingManifest)
        XCTAssertFalse(zipOutcome.shouldPlayHLSInline)
        XCTAssertTrue(zipOutcome.shouldInterceptAsDownload)
    }

    #if canImport(SwiftUI)
    @MainActor
    func testBrowserViewModelHLSResourceIngestion() {
        let browser = BrowserViewModel()
        let streamURL = URL(string: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8")!

        let outcome = BrowserNavigationResponseClassifier.evaluate(
            url: streamURL,
            statusCode: 200,
            contentType: "application/vnd.apple.mpegurl"
        )

        guard let resource = outcome.resource else {
            XCTFail("Expected resource in outcome")
            return
        }

        browser.ingestMediaResource(resource)
        XCTAssertTrue(browser.discoveredResources.contains(where: { $0.url == streamURL }))
        XCTAssertTrue(browser.mediaCandidates.contains(where: { $0.associatedManifestURL == streamURL || $0.url == streamURL }))
    }
    #endif
}

