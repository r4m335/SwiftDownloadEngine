import Foundation
import XCTest
@testable import DM_Reverse_engineering

final class BrowserMediaCandidateTests: XCTestCase {
    private let pageURL = URL(string: "https://video.example/watch")!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testDirectMediaAndManifestObservationsUseDistinctStrategies() throws {
        let direct = try XCTUnwrap(BrowserMediaCandidateClassifier.classify(
            observation: BrowserMediaDiscoveryObservation(
                url: URL(string: "https://cdn.example/video.mp4")!,
                rawURL: "https://cdn.example/video.mp4",
                source: .mediaElement,
                tag: "video",
                declaredType: "video/mp4",
                pageOrigin: pageURL,
                frameOrigin: pageURL,
                mayUseBrowserCredentials: false
            ),
            now: now
        ))
        XCTAssertEqual(direct.kind, .directMedia)
        XCTAssertEqual(direct.availability, .downloadable)
        XCTAssertTrue(direct.evidence.contains("supported media MIME type"))

        let manifest = try XCTUnwrap(BrowserMediaCandidateClassifier.classify(
            observation: BrowserMediaDiscoveryObservation(
                url: URL(string: "https://cdn.example/play?sig=signed")!,
                rawURL: "https://cdn.example/play?sig=signed",
                source: .fetch,
                declaredType: "application/vnd.apple.mpegurl",
                manifestKind: .hls,
                pageOrigin: pageURL,
                frameOrigin: pageURL,
                mayUseBrowserCredentials: false
            ),
            now: now
        ))
        XCTAssertEqual(manifest.kind, .hlsManifest)
        XCTAssertEqual(manifest.availability, .requiresPlanning)
        XCTAssertTrue(manifest.rawURL.contains("sig=signed"))
    }

    func testBlobMSEAndProtectionSignalsNeverBecomeHTTPCandidates() throws {
        let blob = try XCTUnwrap(BrowserMediaCandidateClassifier.classify(
            observation: BrowserMediaDiscoveryObservation(
                url: nil,
                rawURL: "blob:https://video.example/blob-1",
                source: .blob,
                declaredType: "video/mp4",
                contentLength: 4_096,
                documentID: "doc-1",
                pageOrigin: pageURL,
                frameOrigin: pageURL,
                mayUseBrowserCredentials: false
            ),
            now: now
        ))
        XCTAssertEqual(blob.kind, .completeBlob)
        XCTAssertEqual(blob.availability, .captureCandidate)
        XCTAssertNil(blob.url)

        let mse = try XCTUnwrap(BrowserMediaCandidateClassifier.classify(
            observation: BrowserMediaDiscoveryObservation(
                url: nil,
                rawURL: pageURL.absoluteString,
                source: .mediaSource,
                declaredType: "video/mp4",
                documentID: "doc-1",
                appendedByteCount: 8_192,
                pageOrigin: pageURL,
                frameOrigin: pageURL,
                mayUseBrowserCredentials: false
            ),
            now: now
        ))
        XCTAssertEqual(mse.kind, .mediaSource)
        XCTAssertEqual(mse.availability, .metadataOnly)
        XCTAssertNil(mse.url)

        let protected = try XCTUnwrap(BrowserMediaCandidateClassifier.classify(
            observation: BrowserMediaDiscoveryObservation(
                url: nil,
                rawURL: pageURL.absoluteString,
                source: .protection,
                declaredType: "com.example.key-system",
                documentID: "doc-1",
                pageOrigin: pageURL,
                frameOrigin: pageURL,
                mayUseBrowserCredentials: false
            ),
            now: now
        ))
        XCTAssertEqual(protected.kind, .protectedMedia)
        XCTAssertEqual(protected.availability, .unsupported)
        XCTAssertNil(protected.url)
    }

    func testOrdinaryHTMLObservationIsFilteredOut() {
        let candidate = BrowserMediaCandidateClassifier.classify(
            observation: BrowserMediaDiscoveryObservation(
                url: URL(string: "https://example.com/index")!,
                rawURL: "https://example.com/index",
                source: .fetch,
                declaredType: "text/html",
                pageOrigin: pageURL,
                frameOrigin: pageURL,
                mayUseBrowserCredentials: false
            ),
            now: now
        )
        XCTAssertNil(candidate)
    }

    func testCatalogDeduplicatesAndPreservesSafeSameOriginContext() {
        let target = URL(string: "https://cdn.example/video.mp4")!
        let context = BrowserRequestContext(
            url: target,
            pageURL: pageURL,
            cookies: [BrowserCookie(name: "sid", value: "private", domain: "cdn.example")],
            source: .webpageResource
        )
        let resource = WebpageResource(
            url: target,
            title: "Video",
            suggestedFilename: "video.mp4",
            resourceType: .video,
            mimeType: "video/mp4",
            requestContext: context
        )

        var catalog = BrowserMediaCandidateCatalog()
        _ = catalog.ingest(resource: resource, now: now)
        _ = catalog.ingest(resource: resource, now: now.addingTimeInterval(1))

        XCTAssertEqual(catalog.candidates.count, 1)
        XCTAssertEqual(catalog.candidates.first?.requestContext, context)
        XCTAssertEqual(catalog.candidates.first?.lastObserved, now.addingTimeInterval(1))
    }

    func testCatalogAssociatesObservedSegmentsWithManifest() {
        let segmentURL = URL(string: "https://cdn.example/segments/0001.m4s?sig=abc")!
        let resource = WebpageResource(
            url: segmentURL,
            title: "segment",
            suggestedFilename: "0001.m4s",
            resourceType: .video,
            mimeType: "video/iso.segment"
        )
        var catalog = BrowserMediaCandidateCatalog()
        _ = catalog.ingest(resource: resource, now: now)

        catalog.associateManifestSegments(
            manifestID: "url:https://cdn.example/playlist.m3u8",
            segmentURLs: [segmentURL]
        )

        XCTAssertEqual(
            catalog.candidates.first?.associatedManifestID,
            "url:https://cdn.example/playlist.m3u8"
        )
        XCTAssertTrue(catalog.candidates.first?.evidence.contains("associated with a recognized manifest") == true)
    }
}
