import Foundation
import XCTest
@testable import DownloadEngineKit

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
            resourceType: .video,
            mimeType: "application/x-mediasource"
        )
        let candidate = BrowserMediaCandidateClassifier.classify(resource: youtubeBlob)
        XCTAssertEqual(candidate.kind, .mediaSource)
        XCTAssertEqual(candidate.blobKind, .mediaSource)
        XCTAssertEqual(candidate.availability, .metadataOnly)
    }

    func testGenericSocialMediaMSEBlobsAreClassifiedAsMediaSourceImmediately() {
        let sites = [
            "blob:https://twitter.com/x-stream-1",
            "blob:https://vimeo.com/v-stream-2",
            "blob:https://www.instagram.com/ig-stream-3",
            "blob:https://www.tiktok.com/tt-stream-4",
            "blob:https://twitch.tv/tw-stream-5",
            "blob:https://facebook.com/fb-stream-6"
        ]
        for site in sites {
            let blob = WebpageResource(
                url: URL(string: site)!,
                title: "Social Media Stream",
                suggestedFilename: "stream.mp4",
                resourceType: .video,
                mimeType: "application/x-mediasource"
            )
            let candidate = BrowserMediaCandidateClassifier.classify(resource: blob)
            XCTAssertEqual(candidate.kind, .mediaSource, "Failed for \(site)")
            XCTAssertEqual(candidate.blobKind, .mediaSource, "Failed for \(site)")
            XCTAssertEqual(candidate.availability, .metadataOnly, "Failed for \(site)")

            let support = WebpageResource.evaluateSupport(for: URL(string: site)!, rawURL: site, mimeType: "application/x-mediasource")
            XCTAssertFalse(support.isSupported, "Failed support for \(site)")
            XCTAssertEqual(support.reason, "This site uses MediaSource streaming. You must download the manifest (.m3u8 or .mpd) instead.")
        }
    }

    func testCandidateAndWebpageResourceBidirectionalConversionPreservingMediaSpecs() {
        let candidate = BrowserMediaCandidate(
            id: "cand-1080p",
            url: URL(string: "https://media.example.com/movie.mp4")!,
            rawURL: "https://media.example.com/movie.mp4",
            kind: .directMedia,
            mimeType: "video/mp4",
            suggestedFilename: "movie.mp4",
            estimatedSize: 52_428_800,
            availability: .downloadable,
            evidence: ["direct media element"],
            width: 1920,
            height: 1080,
            duration: 125.4,
            codecs: "avc1.640028,mp4a.40.2",
            audioLanguage: "en"
        )

        guard let resource = candidate.toWebpageResource() else {
            XCTFail("Candidate must successfully convert to WebpageResource")
            return
        }

        XCTAssertEqual(resource.resolutionText, "1920×1080")
        XCTAssertEqual(resource.duration, 125.4)
        XCTAssertEqual(resource.formattedDuration, "02:05")
        XCTAssertEqual(resource.codecs, "avc1.640028,mp4a.40.2")
        XCTAssertEqual(resource.audioLanguage, "en")
        XCTAssertEqual(resource.suggestedFilename, "movie.mp4")
        XCTAssertTrue(resource.isSupported)

        let roundTripCandidate = BrowserMediaCandidateClassifier.classify(resource: resource)
        XCTAssertEqual(roundTripCandidate.width, 1920)
        XCTAssertEqual(roundTripCandidate.height, 1080)
        XCTAssertEqual(roundTripCandidate.duration, 125.4)
        XCTAssertEqual(roundTripCandidate.codecs, "avc1.640028,mp4a.40.2")
        XCTAssertEqual(roundTripCandidate.audioLanguage, "en")
    }

    func testObservationDimensionsAndDurationClassifiedIntoCandidate() {
        let observation = BrowserMediaDiscoveryObservation(
            url: URL(string: "https://stream.example.com/video.mp4")!,
            rawURL: "https://stream.example.com/video.mp4",
            source: .mediaElement,
            tag: "video",
            declaredType: "video/mp4",
            contentLength: 104_857_600,
            pageOrigin: pageURL,
            frameOrigin: pageURL,
            mayUseBrowserCredentials: false,
            width: 3840,
            height: 2160,
            duration: 3665.0,
            codecs: "hev1.1.6.L93.B0"
        )

        guard let candidate = BrowserMediaCandidateClassifier.classify(observation: observation) else {
            XCTFail("Observation must classify into candidate")
            return
        }

        XCTAssertEqual(candidate.width, 3840)
        XCTAssertEqual(candidate.height, 2160)
        XCTAssertEqual(candidate.duration, 3665.0)
        XCTAssertEqual(candidate.codecs, "hev1.1.6.L93.B0")

        guard let resource = candidate.toWebpageResource() else {
            XCTFail("Candidate must convert to WebpageResource")
            return
        }
        XCTAssertEqual(resource.resolutionText, "3840×2160")
        XCTAssertEqual(resource.formattedDuration, "1:01:05")
    }

    func testResourceSortingAndGroupingOptions() {
        let r1 = WebpageResource(
            id: "r1",
            url: URL(string: "https://cdn.a.com/small.mp4")!,
            title: "Alpha Video",
            suggestedFilename: "alpha.mp4",
            resourceType: .video,
            estimatedSize: 1_000,
            discoveredAt: Date(timeIntervalSince1970: 100),
            resolutionText: "720×480"
        )
        let r2 = WebpageResource(
            id: "r2",
            url: URL(string: "https://cdn.b.com/large.mp4")!,
            title: "Beta Video",
            suggestedFilename: "beta.mp4",
            resourceType: .video,
            estimatedSize: 99_000,
            discoveredAt: Date(timeIntervalSince1970: 200),
            resolutionText: "1920×1080"
        )
        let r3 = WebpageResource(
            id: "r3",
            url: URL(string: "https://cdn.a.com/audio.mp3")!,
            title: "Audio Track",
            suggestedFilename: "track.mp3",
            resourceType: .audio,
            estimatedSize: 5_000,
            discoveredAt: Date(timeIntervalSince1970: 150)
        )

        let list = [r1, r2, r3]

        // Sort by Newest: r2 (200), r3 (150), r1 (100)
        let sortedNewest = BrowserResourceInspectorSheet.sortedResources(list, sortOption: .newest)
        XCTAssertEqual(sortedNewest.map(\.id), ["r2", "r3", "r1"])

        // Sort by Size: r2 (99000), r3 (5000), r1 (1000)
        let sortedSize = BrowserResourceInspectorSheet.sortedResources(list, sortOption: .size)
        XCTAssertEqual(sortedSize.map(\.id), ["r2", "r3", "r1"])

        // Sort by Name: alpha (r1), beta (r2), track (r3)
        let sortedName = BrowserResourceInspectorSheet.sortedResources(list, sortOption: .name)
        XCTAssertEqual(sortedName.map(\.id), ["r1", "r2", "r3"])

        // Sort by Quality: r2 (1080p), r1 (480p), r3 (nil)
        let sortedQuality = BrowserResourceInspectorSheet.sortedResources(list, sortOption: .quality)
        XCTAssertEqual(sortedQuality.first?.id, "r2")
    }
}

