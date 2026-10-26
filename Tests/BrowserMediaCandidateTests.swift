import Foundation
import XCTest
@testable import DM_Reverse_engineering

final class BrowserMediaCandidateTests: XCTestCase {
    private let pageURL = URL(string: "https://video.example/watch")!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testBlobResourceIsAnActionableCaptureCandidate() throws {
        let resource = WebpageResource(
            url: URL(string: "blob:https://video.example/blob-1")!,
            title: "captured video",
            suggestedFilename: "blob_stream.mp4",
            resourceType: .video,
            mimeType: "video/mp4",
            isSupported: false,
            unsupportedReason: "Blob URLs are not HTTP downloads"
        )

        let candidate = BrowserMediaCandidateClassifier.classify(resource: resource, now: now)

        XCTAssertEqual(candidate.kind, .completeBlob)
        XCTAssertEqual(candidate.availability, .captureCandidate)
        XCTAssertEqual(candidate.suggestedFilename, "blob_stream.mp4")
    }

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

        let mseWithoutObjectURL = try XCTUnwrap(BrowserMediaCandidateClassifier.classify(
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
        XCTAssertEqual(mseWithoutObjectURL.kind, .mediaSource)
        XCTAssertEqual(mseWithoutObjectURL.availability, .metadataOnly)
        XCTAssertNil(mseWithoutObjectURL.url)

        let mse = try XCTUnwrap(BrowserMediaCandidateClassifier.classify(
            observation: BrowserMediaDiscoveryObservation(
                url: nil,
                rawURL: "blob:https://video.example/ms-1",
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
        XCTAssertEqual(mse.availability, .captureCandidate)
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

    func testClassifyMediaSourceObservationSetsBlobKindAndMetadataOnly() throws {
        let observation = BrowserMediaDiscoveryObservation(
            url: nil,
            rawURL: "blob:https://www.youtube.com/watch-feed-1",
            source: .mediaElement,
            tag: "video",
            pageOrigin: URL(string: "https://www.youtube.com")!,
            frameOrigin: URL(string: "https://www.youtube.com")!,
            mayUseBrowserCredentials: true,
            blobKind: .mediaSource
        )

        let candidate = try XCTUnwrap(BrowserMediaCandidateClassifier.classify(observation: observation, now: now))
        XCTAssertEqual(candidate.kind, .mediaSource)
        XCTAssertEqual(candidate.blobKind, .mediaSource)
        XCTAssertEqual(candidate.availability, .metadataOnly)
        XCTAssertNil(candidate.url)
    }

    func testClassifyTrueBlobObservationSetsBlobKindAndCaptureCandidate() throws {
        let observation = BrowserMediaDiscoveryObservation(
            url: nil,
            rawURL: "blob:https://example.com/recording-1",
            source: .blob,
            tag: "blob",
            declaredType: "video/mp4",
            contentLength: 10_000_000,
            pageOrigin: URL(string: "https://example.com")!,
            frameOrigin: URL(string: "https://example.com")!,
            mayUseBrowserCredentials: true,
            blobKind: .blob
        )

        let candidate = try XCTUnwrap(BrowserMediaCandidateClassifier.classify(observation: observation, now: now))
        XCTAssertEqual(candidate.kind, .completeBlob)
        XCTAssertEqual(candidate.blobKind, .blob)
        XCTAssertEqual(candidate.availability, .captureCandidate)
    }

    func testCatalogMergesMediaSourceOverDOMAndAssociatesManifestURL() {
        var catalog = BrowserMediaCandidateCatalog()
        let blobURL = "blob:https://example.com/stream-123"

        // Step 1: DOM observer sees generic <video src="blob:..."> without knowing it's MediaSource yet
        let domResource = WebpageResource(
            url: URL(string: blobURL)!,
            title: "Streaming Video",
            suggestedFilename: "video.mp4",
            resourceType: .video
        )
        _ = catalog.ingest(resource: domResource, now: now)
        XCTAssertEqual(catalog.candidates.first?.kind, .completeBlob)

        // Step 2: JavaScript bridge emits MediaSource origin observation
        let mseObservation = BrowserMediaDiscoveryObservation(
            url: nil,
            rawURL: blobURL,
            source: .mediaSource,
            tag: "video",
            pageOrigin: URL(string: "https://example.com")!,
            frameOrigin: URL(string: "https://example.com")!,
            mayUseBrowserCredentials: true,
            blobKind: .mediaSource
        )
        _ = catalog.ingest(observation: mseObservation, now: now)
        XCTAssertEqual(catalog.candidates.first?.kind, .mediaSource)
        XCTAssertEqual(catalog.candidates.first?.blobKind, .mediaSource)
        XCTAssertEqual(catalog.candidates.first?.availability, .metadataOnly)

        // Step 3: Fetch interceptor discovers DASH/HLS manifest
        let manifestURL = URL(string: "https://example.com/api/manifest/dash/id/xyz.mpd")!
        let manifestObservation = BrowserMediaDiscoveryObservation(
            url: manifestURL,
            rawURL: manifestURL.absoluteString,
            source: .fetch,
            manifestKind: .dash,
            pageOrigin: URL(string: "https://example.com")!,
            frameOrigin: URL(string: "https://example.com")!,
            mayUseBrowserCredentials: true
        )
        _ = catalog.ingest(observation: manifestObservation, now: now)

        let updatedMediaSource = catalog.candidates.first(where: { $0.rawURL == blobURL })
        XCTAssertEqual(updatedMediaSource?.associatedManifestURL, manifestURL)
    }

    func testYouTubeBlobResourceIsClassifiedAsMediaSourceImmediately() {
        let youtubeBlob = WebpageResource(
            url: URL(string: "blob:https://www.youtube.com/abc-123")!,
            title: "YouTube Video",
            suggestedFilename: "youtube.mp4",
            resourceType: .video
        )
        let candidate = BrowserMediaCandidateClassifier.classify(resource: youtubeBlob)
        XCTAssertEqual(candidate.kind, .mediaSource)
        XCTAssertEqual(candidate.blobKind, .mediaSource)
        XCTAssertEqual(candidate.availability, .metadataOnly)
    }
}

