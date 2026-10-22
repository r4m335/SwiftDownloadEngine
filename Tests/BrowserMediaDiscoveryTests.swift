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
        XCTAssertTrue(resources.first?.unsupportedReason?.contains("manifest-aware") ?? false)

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
        XCTAssertTrue(script.contains("getReader"))
        XCTAssertTrue(script.contains("responseURL"))
        XCTAssertTrue(script.contains("contentLength"))
        XCTAssertTrue(script.contains("documentID"))
        XCTAssertTrue(script.contains("createObjectURL"))
        XCTAssertTrue(script.contains("requestMediaKeySystemAccess"))
        XCTAssertTrue(script.contains("addSourceBuffer"))
        XCTAssertTrue(script.contains("appendBuffer"))
        XCTAssertFalse(script.contains("document.cookie"))
        XCTAssertFalse(script.contains("Authorization"))
    }

    func testBlobMetadataIsRetainedWithoutCopyingBlobBytes() throws {
        let bridge = BrowserMediaDiscoveryBridge()
        let observation = try XCTUnwrap(bridge.accept(
            payload: [
                "rawURL": "blob:https://video.example/1234",
                "source": "blob",
                "tag": "blob",
                "declaredType": "video/mp4",
                "contentLength": 4096,
                "documentID": "document-1"
            ],
            pageURL: pageURL
        ))

        XCTAssertTrue(observation.isBlobSignal)
        XCTAssertNil(observation.url)
        XCTAssertEqual(observation.declaredType, "video/mp4")
        XCTAssertEqual(observation.contentLength, 4096)
        XCTAssertEqual(observation.documentID, "document-1")
        XCTAssertFalse(observation.mayUseBrowserCredentials)
    }

    func testMSEAndProtectionObservationsAreMetadataOnly() throws {
        let bridge = BrowserMediaDiscoveryBridge()
        let mse = try XCTUnwrap(bridge.accept(
            payload: [
                "rawURL": pageURL.absoluteString,
                "source": "mediaSource",
                "tag": "appendBuffer",
                "declaredType": "video/mp4; codecs=\"avc1.4d401f\"",
                "contentLength": 1024,
                "appendedByteCount": 4096,
                "eventID": "mse-1",
                "documentID": "document-1"
            ],
            pageURL: pageURL
        ))

        XCTAssertTrue(mse.isMetadataOnlySignal)
        XCTAssertNil(mse.url)
        XCTAssertEqual(mse.appendedByteCount, 4096)
        XCTAssertFalse(mse.isPotentiallyProtected)

        let protection = try XCTUnwrap(bridge.accept(
            payload: [
                "rawURL": pageURL.absoluteString,
                "source": "protection",
                "tag": "eme",
                "declaredType": "com.widevine.alpha",
                "isPotentiallyProtected": true,
                "eventID": "eme-1",
                "documentID": "document-1"
            ],
            pageURL: pageURL
        ))

        XCTAssertTrue(protection.isMetadataOnlySignal)
        XCTAssertNil(protection.url)
        XCTAssertTrue(protection.isPotentiallyProtected)
        XCTAssertFalse(protection.mayUseBrowserCredentials)
    }

    func testManifestMetadataIsBoundedAndClassifiedWithoutFetching() throws {
        let bridge = BrowserMediaDiscoveryBridge()
        let payload: [String: Any] = [
            "rawURL": "/play?token=signed-value",
            "source": "fetch",
            "method": "GET",
            "status": 200,
            "responseURL": "https://video.example/play?token=signed-value",
            "contentLength": 42,
            "declaredType": "application/vnd.apple.mpegurl; charset=utf-8",
            "manifestPrefix": "#EXTM3U\n#EXT-X-ENDLIST"
        ]

        let observation = try XCTUnwrap(bridge.accept(payload: payload, pageURL: pageURL))
        XCTAssertEqual(observation.method, "GET")
        XCTAssertEqual(observation.statusCode, 200)
        XCTAssertEqual(observation.contentLength, 42)
        XCTAssertEqual(observation.responseURL?.absoluteString, "https://video.example/play?token=signed-value")
        XCTAssertEqual(observation.manifestKind, .hls)
        XCTAssertEqual(observation.manifestPrefix, "#EXTM3U\n#EXT-X-ENDLIST")
        XCTAssertTrue(observation.isManifestSignal)
    }

    func testNonGETAndOversizedInspectionMetadataAreRejected() {
        let bridge = BrowserMediaDiscoveryBridge()
        let postPayload: [String: Any] = [
            "rawURL": "https://video.example/manifest.m3u8",
            "source": "fetch",
            "method": "POST"
        ]
        XCTAssertThrowsError(try bridge.accept(payload: postPayload, pageURL: pageURL)) { error in
            XCTAssertEqual(error as? BrowserMediaDiscoveryBridgeError, .unsupportedHTTPMethod)
        }

        let oversizedPayload: [String: Any] = [
            "rawURL": "https://video.example/manifest.m3u8",
            "source": "fetch",
            "manifestPrefix": String(repeating: "x", count: BrowserMediaDiscoveryBridge.maximumMetadataLength + 1)
        ]
        XCTAssertThrowsError(try bridge.accept(payload: oversizedPayload, pageURL: pageURL)) { error in
            XCTAssertEqual(error as? BrowserMediaDiscoveryBridgeError, .metadataTooLong)
        }
    }
}
