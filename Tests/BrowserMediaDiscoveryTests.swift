import Foundation
import XCTest
@testable import DM_Reverse_engineering

final class BrowserMediaDiscoveryTests: XCTestCase {
    private let pageURL = URL(string: "https://video.example/watch?id=private")!

    func testValidManifestObservationIsResolvedDeduplicatedAndRedactsOriginMetadata() throws {
        let bridge = BrowserMediaDiscoveryBridge()
        let payload: [String: Any] = [
            "rawURL": "/player/manifest?sig=signed-value",
            "source": "fetch",
            "tag": "script",
            "declaredType": "application/vnd.apple.mpegurl"
        ]

        let observation = try XCTUnwrap(
            bridge.accept(payload: payload, pageURL: pageURL, frameURL: pageURL)
        )

        XCTAssertEqual(
            observation.url?.absoluteString,
            "https://video.example/player/manifest?sig=signed-value"
        )
        XCTAssertEqual(observation.source, .fetch)
        XCTAssertTrue(observation.mayUseBrowserCredentials)
        XCTAssertEqual(observation.pageOrigin.absoluteString, "https://video.example")
        XCTAssertEqual(observation.frameOrigin.absoluteString, "https://video.example")

        let resources = WebpageResourceExtractor.extractFromRawCandidates(
            [WebpageRawResourceCandidate(
                rawURL: observation.url!.absoluteString,
                tag: observation.tag,
                declaredType: observation.declaredType
            )],
            baseURL: pageURL
        )
        XCTAssertEqual(resources.first?.resourceType, .video)
        XCTAssertFalse(resources.first?.isSupported ?? true)
        XCTAssertTrue(resources.first?.unsupportedReason?.contains("transfer execution") ?? false)

        let duplicate = try bridge.accept(payload: payload, pageURL: pageURL, frameURL: pageURL)
        XCTAssertNil(duplicate)
    }

    func testCrossOriginFrameCannotInheritBrowserCredentials() throws {
        let bridge = BrowserMediaDiscoveryBridge()
        let frameURL = URL(string: "https://embed.example/player")!
        let payload: [String: Any] = [
            "rawURL": "https://cdn.example/stream.m3u8",
            "source": "mediaElement",
            "tag": "video"
        ]

        let observation = try XCTUnwrap(
            bridge.accept(payload: payload, pageURL: pageURL, frameURL: frameURL)
        )

        XCTAssertFalse(observation.mayUseBrowserCredentials)
        XCTAssertEqual(observation.frameOrigin.absoluteString, "https://embed.example")
        XCTAssertEqual(observation.pageOrigin.absoluteString, "https://video.example")
    }

    func testBlobIsRetainedAsSignalButHasNoDownloadURL() throws {
        let bridge = BrowserMediaDiscoveryBridge()
        let payload: [String: Any] = [
            "rawURL": "blob:https://video.example/1234",
            "source": "mediaElement",
            "tag": "video"
        ]

        let observation = try XCTUnwrap(
            bridge.accept(payload: payload, pageURL: pageURL, frameURL: pageURL)
        )

        XCTAssertTrue(observation.isBlobSignal)
        XCTAssertNil(observation.url)
        XCTAssertFalse(observation.mayUseBrowserCredentials)
    }

    func testUnsupportedSchemesAndCredentialBearingURLsAreRejected() {
        let bridge = BrowserMediaDiscoveryBridge()
        let cases: [[String: Any]] = [
            ["rawURL": "javascript:alert(1)", "source": "fetch"],
            ["rawURL": "data:application/vnd.apple.mpegurl,playlist", "source": "fetch"],
            ["rawURL": "https://user:password@example.com/video.mp4", "source": "fetch"]
        ]

        XCTAssertThrowsError(try bridge.accept(payload: cases[0], pageURL: pageURL)) { error in
            XCTAssertEqual(error as? BrowserMediaDiscoveryBridgeError, .unsupportedCandidateScheme)
        }
        XCTAssertThrowsError(try bridge.accept(payload: cases[1], pageURL: pageURL)) { error in
            XCTAssertEqual(error as? BrowserMediaDiscoveryBridgeError, .unsupportedCandidateScheme)
        }
        XCTAssertThrowsError(try bridge.accept(payload: cases[2], pageURL: pageURL)) { error in
            XCTAssertEqual(error as? BrowserMediaDiscoveryBridgeError, .credentialedCandidateURL)
            XCTAssertFalse(error.localizedDescription.contains("password"))
        }
    }

    func testMalformedMessagesAndInvalidOriginsFailSafely() {
        let bridge = BrowserMediaDiscoveryBridge()
        let malformed: [String: Any] = ["rawURL": "https://example.com/video.mp4"]

        XCTAssertThrowsError(try bridge.accept(payload: malformed, pageURL: pageURL)) { error in
            XCTAssertEqual(error as? BrowserMediaDiscoveryBridgeError, .malformedMessage)
        }

        let invalidPage = URL(string: "about:blank")!
        XCTAssertThrowsError(try bridge.accept(
            payload: ["rawURL": "https://example.com/video.mp4", "source": "fetch"],
            pageURL: invalidPage
        )) { error in
            XCTAssertEqual(error as? BrowserMediaDiscoveryBridgeError, .invalidPageOrigin)
        }
    }

    func testObserverScriptContainsRequiredHooksWithoutCredentialAccess() {
        let script = BrowserMediaDiscoveryBridge.observerScript

        XCTAssertTrue(script.contains("window.fetch"))
        XCTAssertTrue(script.contains("XMLHttpRequest.prototype.open"))
        XCTAssertTrue(script.contains("MutationObserver"))
        XCTAssertTrue(script.contains("PerformanceObserver"))
        XCTAssertTrue(script.contains("video, audio, source"))
        XCTAssertFalse(script.contains("document.cookie"))
        XCTAssertFalse(script.contains("Authorization"))
    }
}
