import XCTest
@testable import DM_Reverse_engineering

final class BrowserPlaybackRoutingTests: XCTestCase {
    func testHLSIsRecognizedAsStreamingWhileDASHRemainsDASH() {
        let hls = BrowserNavigationResponseClassifier.evaluate(
            url: URL(string: "https://media.example.com/master.m3u8")!,
            statusCode: 200,
            contentType: "application/vnd.apple.mpegurl"
        )
        let dash = BrowserNavigationResponseClassifier.evaluate(
            url: URL(string: "https://media.example.com/manifest.mpd")!,
            statusCode: 200,
            contentType: "application/dash+xml"
        )

        XCTAssertTrue(hls.isStreamingManifest)
        XCTAssertEqual(hls.manifestKind, .hls)
        XCTAssertTrue(dash.isStreamingManifest)
        XCTAssertEqual(dash.manifestKind, .dash)
    }

    #if canImport(SwiftUI)
    @MainActor
    func testOrdinaryFileHandoffPrefillsAddRouteButRejectsStreamingURLs() {
        var handedOffURL: URL?
        let browser = BrowserViewModel(onOpenAddDownload: { handedOffURL = $0 })

        browser.openAddDownload(for: URL(string: "https://example.com/movie.mp4")!)
        XCTAssertEqual(handedOffURL?.absoluteString, "https://example.com/movie.mp4")

        browser.openAddDownload(for: URL(string: "https://example.com/master.m3u8")!)
        XCTAssertEqual(handedOffURL?.absoluteString, "https://example.com/movie.mp4")
    }
    #endif
}
