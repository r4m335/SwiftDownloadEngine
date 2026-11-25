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

    @MainActor
    func testBidirectionalBridgingBetweenCandidateAndResource() {
        let candidate = BrowserMediaCandidate(
            id: "cand-bidirectional",
            url: URL(string: "https://example.com/video.mp4")!,
            rawURL: "https://example.com/video.mp4",
            kind: .directMedia,
            mimeType: "video/mp4",
            suggestedFilename: "test_video.mp4",
            estimatedSize: 25_000_000,
            availability: .downloadable,
            evidence: ["test"],
            width: 1920,
            height: 1080,
            duration: 180.0,
            codecs: "avc1.640028,mp4a.40.2",
            audioLanguage: "en"
        )

        // 1. Candidate -> WebpageResource via initializer and property
        let resourceFromInit = WebpageResource(candidate: candidate)
        XCTAssertNotNil(resourceFromInit)
        XCTAssertEqual(resourceFromInit?.url, candidate.url)
        XCTAssertEqual(resourceFromInit?.suggestedFilename, "test_video.mp4")
        XCTAssertEqual(resourceFromInit?.resolutionText, "1920×1080")
        XCTAssertEqual(resourceFromInit?.duration, 180.0)

        let resourceFromProp = candidate.webpageResource
        XCTAssertEqual(resourceFromProp?.url, candidate.url)
        XCTAssertEqual(resourceFromProp?.suggestedFilename, "test_video.mp4")

        // 2. WebpageResource -> Candidate via initializer and property
        guard let validRes = resourceFromInit else {
            XCTFail("Must have valid resource")
            return
        }

        let candFromInit = BrowserMediaCandidate(resource: validRes)
        XCTAssertEqual(candFromInit.url, validRes.url)
        XCTAssertEqual(candFromInit.suggestedFilename, validRes.suggestedFilename)
        XCTAssertEqual(candFromInit.width, 1920)
        XCTAssertEqual(candFromInit.height, 1080)
        XCTAssertEqual(candFromInit.duration, 180.0)

        let candFromProp = validRes.mediaCandidate
        XCTAssertEqual(candFromProp.url, validRes.url)
        XCTAssertEqual(candFromProp.suggestedFilename, validRes.suggestedFilename)
    }

    @MainActor
    func testBrowserViewModelCandidateWorkflowsAndCatalogSync() {
        let viewModel = BrowserViewModel()
        let tabID = viewModel.activeTabID ?? viewModel.createNewTab()

        let candidate = BrowserMediaCandidate(
            id: "cand-sync-1",
            url: URL(string: "https://example.com/stream.m3u8")!,
            rawURL: "https://example.com/stream.m3u8",
            kind: .hlsManifest,
            mimeType: "application/vnd.apple.mpegurl",
            suggestedFilename: "stream.m3u8",
            availability: .requiresPlanning,
            evidence: ["hls"]
        )

        // 1. Ingest candidate directly
        viewModel.ingestMediaCandidates([candidate], tabID: tabID)

        // Verifies candidate is in mediaCandidates and synchronized into discoveredResources
        XCTAssertTrue(viewModel.discoveredResources.contains(where: { $0.url == candidate.url }))

        // 2. Candidate-first download workflow triggers
        viewModel.promptDownload(for: candidate)
        XCTAssertTrue(viewModel.isShowingDownloadSheet)
        XCTAssertEqual(viewModel.downloadCandidateFilename, "stream.m3u8")

        // 3. Candidate-first Inspector prompt
        viewModel.promptDownloadFromInspector(for: candidate)
        XCTAssertNotNil(viewModel.activeDownloadResource)

        // 4. Candidate-first quality picker
        viewModel.presentQualityPicker(for: candidate)
        XCTAssertTrue(viewModel.isShowingQualityPicker)
        XCTAssertEqual(viewModel.qualityPickerTargetCandidate?.id, candidate.id)
    }

    func testOrdinaryLiveCandidateClassificationAndProperties() {
        // 1. Explicit isLive flag
        let liveCand = BrowserMediaCandidate(
            id: "cand-live-1",
            url: URL(string: "https://example.com/live/broadcast.m3u8")!,
            rawURL: "https://example.com/live/broadcast.m3u8",
            kind: .hlsManifest,
            suggestedFilename: "broadcast.m3u8",
            availability: .requiresPlanning,
            isLive: true
        )
        XCTAssertTrue(liveCand.isLive)
        XCTAssertTrue(liveCand.isLiveStream)

        // WebpageResource conversion preserves isLive
        let resource = liveCand.toWebpageResource()
        XCTAssertNotNil(resource)
        XCTAssertTrue(resource?.isLive == true)

        // Reverse conversion preserves isLive
        if let res = resource {
            let roundtrip = res.toMediaCandidate()
            XCTAssertTrue(roundtrip.isLive)
            XCTAssertTrue(roundtrip.isLiveStream)
        }

        // 2. Manifest without EXT-X-ENDLIST triggers live stream detection
        let liveManifestText = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:10
        #EXT-X-MEDIA-SEQUENCE:100
        #EXTINF:10.0,
        seg100.ts
        #EXTINF:10.0,
        seg101.ts
        """
        let manifestCand = BrowserMediaCandidate(
            id: "cand-live-2",
            url: URL(string: "https://example.com/stream.m3u8")!,
            rawURL: "https://example.com/stream.m3u8",
            kind: .hlsManifest,
            suggestedFilename: "stream.m3u8",
            availability: .requiresPlanning,
            cachedManifestText: liveManifestText
        )
        XCTAssertTrue(manifestCand.isLiveStream)

        // 3. Finite VOD manifest does not trigger live stream detection
        let vodManifestText = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:10
        #EXTINF:10.0,
        seg1.ts
        #EXT-X-ENDLIST
        """
        let vodCand = BrowserMediaCandidate(
            id: "cand-vod-1",
            url: URL(string: "https://example.com/vod.m3u8")!,
            rawURL: "https://example.com/vod.m3u8",
            kind: .hlsManifest,
            suggestedFilename: "vod.m3u8",
            availability: .requiresPlanning,
            cachedManifestText: vodManifestText
        )
        XCTAssertFalse(vodCand.isLive)
        XCTAssertFalse(vodCand.isLiveStream)
    }

    @MainActor
    func testRescanPreservesOrdinaryLiveResultsAndMSEBlobCandidates() {
        let viewModel = BrowserViewModel()
        let tabID = viewModel.activeTabID ?? viewModel.createNewTab()

        let mseRawURL = "blob:https://example.com/mse-uuid"
        let mseID = BrowserMediaCandidateClassifier.stableIdentity(rawURL: mseRawURL, url: nil)
        let mseCand = BrowserMediaCandidate(
            id: mseID,
            url: nil,
            rawURL: mseRawURL,
            kind: .mediaSource,
            blobKind: .mediaSource,
            mimeType: "video/mp4",
            suggestedFilename: "media_source_capture.mp4",
            availability: .captureCandidate
        )

        let blobRawURL = "blob:https://example.com/blob-uuid"
        let blobID = BrowserMediaCandidateClassifier.stableIdentity(rawURL: blobRawURL, url: nil)
        let blobCand = BrowserMediaCandidate(
            id: blobID,
            url: nil,
            rawURL: blobRawURL,
            kind: .completeBlob,
            blobKind: .blob,
            mimeType: "video/mp4",
            suggestedFilename: "blob_export.mp4",
            availability: .captureCandidate
        )

        let assocURL = URL(string: "https://example.com/chunk.mp4")!
        let assocID = BrowserMediaCandidateClassifier.stableIdentity(rawURL: assocURL.absoluteString, url: assocURL)
        let assocManifestCand = BrowserMediaCandidate(
            id: assocID,
            url: assocURL,
            rawURL: assocURL.absoluteString,
            kind: .directMedia,
            suggestedFilename: "chunk.mp4",
            availability: .downloadable,
            associatedManifestURL: URL(string: "https://example.com/stream.m3u8")!
        )

        let liveHLSURL = URL(string: "https://example.com/live_broadcast.m3u8")!
        let liveHLSID = BrowserMediaCandidateClassifier.stableIdentity(rawURL: liveHLSURL.absoluteString, url: liveHLSURL)
        let ordinaryLiveManifestCand = BrowserMediaCandidate(
            id: liveHLSID,
            url: liveHLSURL,
            rawURL: liveHLSURL.absoluteString,
            kind: .hlsManifest,
            suggestedFilename: "live_broadcast.m3u8",
            availability: .requiresPlanning,
            isLive: true
        )

        let liveDirectURL = URL(string: "https://example.com/live/feed.flv")!
        let liveDirectID = BrowserMediaCandidateClassifier.stableIdentity(rawURL: liveDirectURL.absoluteString, url: liveDirectURL)
        let ordinaryLiveDirectCand = BrowserMediaCandidate(
            id: liveDirectID,
            url: liveDirectURL,
            rawURL: liveDirectURL.absoluteString,
            kind: .directMedia,
            suggestedFilename: "feed.flv",
            availability: .downloadable,
            isLive: true
        )

        let staticDocURL = URL(string: "https://example.com/manual.pdf")!
        let staticDocID = BrowserMediaCandidateClassifier.stableIdentity(rawURL: staticDocURL.absoluteString, url: staticDocURL)
        let normalStaticFileCand = BrowserMediaCandidate(
            id: staticDocID,
            url: staticDocURL,
            rawURL: staticDocURL.absoluteString,
            kind: .directFile,
            suggestedFilename: "manual.pdf",
            availability: .downloadable,
            isLive: false
        )

        viewModel.ingestMediaCandidates(
            [mseCand, blobCand, assocManifestCand, ordinaryLiveManifestCand, ordinaryLiveDirectCand, normalStaticFileCand],
            tabID: tabID
        )

        // Verify all 6 ingested
        XCTAssertEqual(viewModel.mediaCandidates.count, 6)

        // Rescan / catalog reset
        viewModel.resetMediaCandidateCatalog(for: tabID)

        // Verify ordinary live streams, manifests, MSE, and blob candidates are all preserved, while ordinary static file is dropped
        let remainingIDs = Set(viewModel.mediaCandidates.map(\.id))
        XCTAssertTrue(remainingIDs.contains(mseID), "MSE candidate must be preserved")
        XCTAssertTrue(remainingIDs.contains(blobID), "Complete blob candidate must be preserved")
        XCTAssertTrue(remainingIDs.contains(assocID), "Candidate with associated manifest must be preserved")
        XCTAssertTrue(remainingIDs.contains(liveHLSID), "Ordinary live HLS manifest candidate must be preserved")
        XCTAssertTrue(remainingIDs.contains(liveDirectID), "Ordinary live direct stream candidate must be preserved")
        XCTAssertFalse(remainingIDs.contains(staticDocID), "Ordinary static non-live file must be dropped")
    }

    @MainActor
    func testResetMediaDiscoveryClearsOldResourcesAndVariants() {
        let viewModel = BrowserViewModel()
        let tabID = viewModel.activeTabID ?? viewModel.createNewTab()

        let liveRes = WebpageResource(
            id: "res-live",
            url: URL(string: "https://example.com/live/stream.m3u8")!,
            title: "Live News Stream",
            suggestedFilename: "stream.m3u8",
            resourceType: .video,
            isLive: true
        )
        let nonLiveRes = WebpageResource(
            id: "res-static",
            url: URL(string: "https://example.com/document.pdf")!,
            title: "Static Document",
            suggestedFilename: "document.pdf",
            resourceType: .other,
            isLive: false
        )

        let liveVariant = HLSVariantStreamItem(
            id: "var-live",
            masterURL: URL(string: "https://example.com/live/stream.m3u8")!,
            variantURL: URL(string: "https://example.com/live/1080p.m3u8")!,
            bandwidth: 5_000_000,
            resolution: HLSResolution(width: 1920, height: 1080),
            qualityLabel: "1080p Live",
            bitrateText: "5.0 Mbps",
            codecs: "avc1.640028",
            isLive: true
        )
        let nonLiveVariant = HLSVariantStreamItem(
            id: "var-vod",
            masterURL: URL(string: "https://example.com/vod/master.m3u8")!,
            variantURL: URL(string: "https://example.com/vod/720p.m3u8")!,
            bandwidth: 2_500_000,
            resolution: HLSResolution(width: 1280, height: 720),
            qualityLabel: "720p VOD",
            bitrateText: "2.5 Mbps",
            codecs: "avc1.4d401f",
            isLive: false
        )

        viewModel.setDiscoveredResources([liveRes, nonLiveRes], for: tabID)
        viewModel.setVariantStreamItems([liveVariant, nonLiveVariant], for: tabID)

        // Resetting media discovery clears all old resources and variants on page/site change
        viewModel.resetMediaDiscovery(for: tabID)

        let discovered = viewModel.discoveredResources(for: tabID)
        XCTAssertTrue(discovered.isEmpty)

        let variants = viewModel.variantStreamItems(for: tabID)
        XCTAssertTrue(variants.isEmpty)

        // Explicit rescan APIs remain callable
        viewModel.rescanResources(includeNonVideo: false)
        viewModel.rescanCurrentPageResources(includeNonVideo: true)
    }

    // MARK: - Resource & Candidate Explicit Sorting Tests (Newest, Size, Quality, Name)

    func testResourceSortingByNewest() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let t1 = Date(timeIntervalSince1970: 2_000)
        let t2 = Date(timeIntervalSince1970: 3_000)

        let rOld = WebpageResource(
            id: "old",
            url: URL(string: "https://example.com/old.mp4")!,
            title: "Old Video",
            suggestedFilename: "old.mp4",
            resourceType: .video,
            discoveredAt: t0
        )
        let rMid = WebpageResource(
            id: "mid",
            url: URL(string: "https://example.com/mid.mp4")!,
            title: "Mid Video",
            suggestedFilename: "mid.mp4",
            resourceType: .video,
            discoveredAt: t1
        )
        let rNew = WebpageResource(
            id: "new",
            url: URL(string: "https://example.com/new.mp4")!,
            title: "New Video",
            suggestedFilename: "new.mp4",
            resourceType: .video,
            discoveredAt: t2
        )

        let sorted = BrowserResourceInspectorSheet.sortedResources(
            [rOld, rNew, rMid],
            sortOption: .newest
        )
        XCTAssertEqual(sorted.map { $0.id }, ["new", "mid", "old"], "Newest sort must order by discoveredAt descending")
    }

    func testResourceSortingBySize() {
        let rSmall = WebpageResource(
            id: "small",
            url: URL(string: "https://example.com/small.mp4")!,
            title: "Small",
            suggestedFilename: "small.mp4",
            resourceType: .video,
            estimatedSize: 10_000_000 // 10 MB
        )
        let rMedium = WebpageResource(
            id: "med",
            url: URL(string: "https://example.com/med.mp4")!,
            title: "Medium",
            suggestedFilename: "med.mp4",
            resourceType: .video,
            estimatedSize: 250_000_000 // 250 MB
        )
        let rLarge = WebpageResource(
            id: "large",
            url: URL(string: "https://example.com/large.mp4")!,
            title: "Large",
            suggestedFilename: "large.mp4",
            resourceType: .video,
            estimatedSize: 1_500_000_000 // 1.5 GB
        )

        let sorted = BrowserResourceInspectorSheet.sortedResources(
            [rSmall, rLarge, rMedium],
            sortOption: .size
        )
        XCTAssertEqual(sorted.map { $0.id }, ["large", "med", "small"], "Size sort must order by estimated size descending")
    }

    func testResourceSortingByName() {
        let rZ = WebpageResource(
            id: "z",
            url: URL(string: "https://example.com/zebra.mp4")!,
            title: "Zebra",
            suggestedFilename: "zebra.mp4",
            resourceType: .video
        )
        let rA = WebpageResource(
            id: "a",
            url: URL(string: "https://example.com/apple.mp4")!,
            title: "Apple",
            suggestedFilename: "apple.mp4",
            resourceType: .video
        )
        let rM = WebpageResource(
            id: "m",
            url: URL(string: "https://example.com/mango.mp4")!,
            title: "Mango",
            suggestedFilename: "mango.mp4",
            resourceType: .video
        )

        let sorted = BrowserResourceInspectorSheet.sortedResources(
            [rZ, rM, rA],
            sortOption: .name
        )
        XCTAssertEqual(sorted.map { $0.id }, ["a", "m", "z"], "Name sort must order alphabetically by filename")
    }

    func testResourceSortingByQuality() {
        let r360 = WebpageResource(
            id: "360",
            url: URL(string: "https://example.com/video.m3u8")!,
            title: "360p",
            suggestedFilename: "360.mp4",
            resourceType: .video,
            hlsVariantPreferences: HLSVariantSelectionPreferences(maximumBandwidth: 800_000, maximumHeight: 360)
        )
        let r720 = WebpageResource(
            id: "720",
            url: URL(string: "https://example.com/video.m3u8")!,
            title: "720p",
            suggestedFilename: "720.mp4",
            resourceType: .video,
            hlsVariantPreferences: HLSVariantSelectionPreferences(maximumBandwidth: 2_500_000, maximumHeight: 720)
        )
        let r1080 = WebpageResource(
            id: "1080",
            url: URL(string: "https://example.com/video.m3u8")!,
            title: "1080p",
            suggestedFilename: "1080.mp4",
            resourceType: .video,
            hlsVariantPreferences: HLSVariantSelectionPreferences(maximumBandwidth: 6_000_000, maximumHeight: 1080)
        )

        let sorted = BrowserResourceInspectorSheet.sortedResources(
            [r360, r1080, r720],
            sortOption: .quality
        )
        XCTAssertEqual(sorted.map { $0.id }, ["1080", "720", "360"], "Quality sort must order by highest resolution/bandwidth first")
    }

    @MainActor
    func testBrowserViewModelSortingControls() {
        let viewModel = BrowserViewModel()
        let tabID = viewModel.activeTabID ?? viewModel.createNewTab()

        let rSmall = WebpageResource(
            id: "b-small",
            url: URL(string: "https://example.com/b_small.mp4")!,
            title: "B Small",
            suggestedFilename: "b_small.mp4",
            resourceType: .video,
            estimatedSize: 10_000_000,
            discoveredAt: Date(timeIntervalSince1970: 100)
        )
        let rLarge = WebpageResource(
            id: "a-large",
            url: URL(string: "https://example.com/a_large.mp4")!,
            title: "A Large",
            suggestedFilename: "a_large.mp4",
            resourceType: .video,
            estimatedSize: 900_000_000,
            discoveredAt: Date(timeIntervalSince1970: 500)
        )

        viewModel.setDiscoveredResources([rSmall, rLarge], for: tabID)

        // 1. Newest
        viewModel.resourceSortOption = .newest
        let newestSorted = viewModel.sortedDiscoveredResources()
        XCTAssertEqual(newestSorted.map { $0.id }, ["a-large", "b-small"])

        // 2. Size
        viewModel.resourceSortOption = .size
        let sizeSorted = viewModel.sortedDiscoveredResources()
        XCTAssertEqual(sizeSorted.map { $0.id }, ["a-large", "b-small"])

        // 3. Name (a_large < b_small)
        viewModel.resourceSortOption = .name
        let nameSorted = viewModel.sortedDiscoveredResources()
        XCTAssertEqual(nameSorted.map { $0.id }, ["a-large", "b-small"])

        // Test sorted candidates
        let candidates = viewModel.sortedMediaCandidates(by: .name)
        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates[0].suggestedFilename, "a_large.mp4")
        XCTAssertEqual(candidates[1].suggestedFilename, "b_small.mp4")
    }

    func testBrowserMediaCandidateDirectSorting() {
        let c1 = BrowserMediaCandidate(
            id: "c1",
            url: URL(string: "https://example.com/1.mp4"),
            rawURL: "https://example.com/1.mp4",
            kind: .directMedia,
            suggestedFilename: "zebra.mp4",
            estimatedSize: 50_000,
            availability: .downloadable,
            lastObserved: Date(timeIntervalSince1970: 100)
        )
        let c2 = BrowserMediaCandidate(
            id: "c2",
            url: URL(string: "https://example.com/2.mp4"),
            rawURL: "https://example.com/2.mp4",
            kind: .directMedia,
            suggestedFilename: "alpha.mp4",
            estimatedSize: 500_000,
            availability: .downloadable,
            lastObserved: Date(timeIntervalSince1970: 200)
        )

        // Sort by name
        let byName = BrowserMediaCandidate.sorted([c1, c2], by: .name)
        XCTAssertEqual(byName.map { $0.id }, ["c2", "c1"])

        // Sort by size
        let bySize = BrowserMediaCandidate.sorted([c1, c2], by: .size)
        XCTAssertEqual(bySize.map { $0.id }, ["c2", "c1"])

        // Sort by newest
        let byNewest = BrowserMediaCandidate.sorted([c1, c2], by: .newest)
        XCTAssertEqual(byNewest.map { $0.id }, ["c2", "c1"])
    }

    func testResourceGroupingOptionsEnumAndDisplay() {
        XCTAssertEqual(ResourceGroupingOption.none.rawValue, "None")
        XCTAssertEqual(ResourceGroupingOption.domain.rawValue, "Domain")
        XCTAssertEqual(ResourceGroupingOption.category.rawValue, "Category")
        XCTAssertEqual(ResourceGroupingOption.manifest.rawValue, "Manifest")
        XCTAssertEqual(ResourceGroupingOption.streamType.rawValue, "Stream Type")
        XCTAssertEqual(ResourceGroupingOption.trackType.rawValue, "Track Type")
        XCTAssertEqual(ResourceGroupingOption.quality.rawValue, "Quality")
        XCTAssertEqual(ResourceGroupingOption.type, .category)

        XCTAssertEqual(ResourceGroupingOption.none.displayName, "None (Flat List)")
        XCTAssertEqual(ResourceGroupingOption.domain.displayName, "By Domain")
        XCTAssertEqual(ResourceGroupingOption.category.displayName, "By Category")
        XCTAssertEqual(ResourceGroupingOption.manifest.displayName, "By Manifest")
        XCTAssertEqual(ResourceGroupingOption.streamType.displayName, "By Stream Type")
        XCTAssertEqual(ResourceGroupingOption.trackType.displayName, "By Track Type")
        XCTAssertEqual(ResourceGroupingOption.quality.displayName, "By Quality")

        XCTAssertFalse(ResourceGroupingOption.none.iconName.isEmpty)
        XCTAssertFalse(ResourceGroupingOption.domain.iconName.isEmpty)
        XCTAssertFalse(ResourceGroupingOption.category.iconName.isEmpty)
        XCTAssertFalse(ResourceGroupingOption.manifest.iconName.isEmpty)
        XCTAssertFalse(ResourceGroupingOption.streamType.iconName.isEmpty)
        XCTAssertFalse(ResourceGroupingOption.trackType.iconName.isEmpty)
        XCTAssertFalse(ResourceGroupingOption.quality.iconName.isEmpty)

        XCTAssertEqual(ResourceGroupingOption.allCases.count, 7)
    }

    func testResourceGroupingByDomainAndCategory() {
        let r1 = WebpageResource(
            id: "r1",
            url: URL(string: "https://video.example.com/movie.mp4")!,
            title: "Movie Video",
            suggestedFilename: "movie.mp4",
            resourceType: .video,
            discoveredAt: Date(timeIntervalSince1970: 100)
        )
        let r2 = WebpageResource(
            id: "r2",
            url: URL(string: "https://audio.example.com/track.mp3")!,
            title: "Music Track",
            suggestedFilename: "track.mp3",
            resourceType: .audio,
            discoveredAt: Date(timeIntervalSince1970: 200)
        )
        let r3 = WebpageResource(
            id: "r3",
            url: URL(string: "https://video.example.com/clip.mp4")!,
            title: "Clip Video",
            suggestedFilename: "clip.mp4",
            resourceType: .video,
            discoveredAt: Date(timeIntervalSince1970: 150)
        )
        let r4 = WebpageResource(
            id: "r4",
            url: URL(string: "https://assets.cdn.net/poster.jpg")!,
            title: "Poster Image",
            suggestedFilename: "poster.jpg",
            resourceType: .image,
            discoveredAt: Date(timeIntervalSince1970: 300)
        )

        let list = [r1, r2, r3, r4]

        // Group by Domain
        let domainGroups = WebpageResource.groupedByDomain(list)
        // Domains sorted alphabetically: assets.cdn.net, audio.example.com, video.example.com
        XCTAssertEqual(domainGroups.count, 3)
        XCTAssertEqual(domainGroups[0].domain, "assets.cdn.net")
        XCTAssertEqual(domainGroups[0].resources.map(\.id), ["r4"])
        XCTAssertEqual(domainGroups[1].domain, "audio.example.com")
        XCTAssertEqual(domainGroups[1].resources.map(\.id), ["r2"])
        XCTAssertEqual(domainGroups[2].domain, "video.example.com")
        XCTAssertEqual(domainGroups[2].resources.map(\.id), ["r1", "r3"])

        // Group by Category
        let categoryGroups = WebpageResource.groupedByCategory(list)
        let groupCategories = categoryGroups.map(\.category)
        XCTAssertTrue(groupCategories.contains(.video))
        XCTAssertTrue(groupCategories.contains(.audio))
        XCTAssertTrue(groupCategories.contains(.image))

        let videoGroup = categoryGroups.first { $0.category == .video }
        XCTAssertEqual(videoGroup?.resources.map(\.id), ["r1", "r3"])

        let audioGroup = categoryGroups.first { $0.category == .audio }
        XCTAssertEqual(audioGroup?.resources.map(\.id), ["r2"])

        let imageGroup = categoryGroups.first { $0.category == .image }
        XCTAssertEqual(imageGroup?.resources.map(\.id), ["r4"])
    }

    func testBrowserMediaCandidateDirectGrouping() {
        let c1 = BrowserMediaCandidate(
            id: "c1",
            url: URL(string: "https://cdn.movies.com/v1.mp4"),
            rawURL: "https://cdn.movies.com/v1.mp4",
            kind: .directMedia,
            suggestedFilename: "v1.mp4",
            availability: .downloadable
        )
        let c2 = BrowserMediaCandidate(
            id: "c2",
            url: URL(string: "https://cdn.audio.com/a1.mp3"),
            rawURL: "https://cdn.audio.com/a1.mp3",
            kind: .directFile,
            mimeType: "audio/mpeg",
            suggestedFilename: "a1.mp3",
            availability: .downloadable
        )
        let c3 = BrowserMediaCandidate(
            id: "c3",
            url: URL(string: "https://cdn.movies.com/v2.mp4"),
            rawURL: "https://cdn.movies.com/v2.mp4",
            kind: .directMedia,
            suggestedFilename: "v2.mp4",
            availability: .downloadable
        )

        let candidates = [c1, c2, c3]

        // Check resourceType mapping
        XCTAssertEqual(c1.resourceType, .video)
        XCTAssertEqual(c2.resourceType, .audio)
        XCTAssertEqual(c3.resourceType, .video)

        // Group by Domain
        let domainGroups = BrowserMediaCandidate.groupedByDomain(candidates)
        XCTAssertEqual(domainGroups.count, 2)
        XCTAssertEqual(domainGroups[0].domain, "cdn.audio.com")
        XCTAssertEqual(domainGroups[0].candidates.map(\.id), ["c2"])
        XCTAssertEqual(domainGroups[1].domain, "cdn.movies.com")
        XCTAssertEqual(domainGroups[1].candidates.map(\.id), ["c1", "c3"])

        // Group by Category
        let categoryGroups = BrowserMediaCandidate.groupedByCategory(candidates)
        XCTAssertEqual(categoryGroups.count, 2)
        let videoCat = categoryGroups.first { $0.category == .video }
        let audioCat = categoryGroups.first { $0.category == .audio }
        XCTAssertEqual(videoCat?.candidates.map(\.id), ["c1", "c3"])
        XCTAssertEqual(audioCat?.candidates.map(\.id), ["c2"])
    }

    @MainActor
    func testBrowserViewModelGroupingControlsAndTabPersistence() {
        let vm = BrowserViewModel()
        XCTAssertEqual(vm.resourceGroupingOption, .none)

        let r1 = WebpageResource(
            id: "r1",
            url: URL(string: "https://cdn.stream.com/video.m3u8")!,
            title: "Master Stream",
            suggestedFilename: "video.m3u8",
            resourceType: .video,
            discoveredAt: Date(timeIntervalSince1970: 200)
        )
        let r2 = WebpageResource(
            id: "r2",
            url: URL(string: "https://static.cdn.com/sound.mp3")!,
            title: "Theme Song",
            suggestedFilename: "sound.mp3",
            resourceType: .audio,
            discoveredAt: Date(timeIntervalSince1970: 100)
        )

        vm.discoveredResources = [r1, r2]

        // Domain grouping query
        let domainGroups = vm.groupedDiscoveredResourcesByDomain()
        XCTAssertEqual(domainGroups.count, 2)
        XCTAssertEqual(domainGroups[0].domain, "cdn.stream.com")
        XCTAssertEqual(domainGroups[1].domain, "static.cdn.com")

        // Category grouping query
        let categoryGroups = vm.groupedDiscoveredResourcesByCategory()
        XCTAssertEqual(categoryGroups.count, 2)

        // Candidate grouping queries
        let candidateDomainGroups = vm.groupedMediaCandidatesByDomain()
        XCTAssertEqual(candidateDomainGroups.count, 2)

        let candidateCatGroups = vm.groupedMediaCandidatesByCategory()
        XCTAssertEqual(candidateCatGroups.count, 2)

        // Test state updates & tab switching persistence
        let tab1 = vm.activeTabID ?? vm.createNewTab()
        vm.resourceGroupingOption = .domain
        vm.resourceSortOption = .size
        vm.saveActiveTabResourceState()

        let state1 = vm.resourceState(for: tab1)
        XCTAssertEqual(state1.groupingOption, .domain)
        XCTAssertEqual(state1.sortOption, .size)

        let tab2 = vm.createNewTab()
        vm.restoreTabResourceState(for: tab2)
        XCTAssertEqual(vm.resourceGroupingOption, .none)

        _ = vm.selectTab(tab1)
        vm.restoreTabResourceState(for: tab1)
        XCTAssertEqual(vm.resourceGroupingOption, .domain)
        XCTAssertEqual(vm.resourceSortOption, .size)
    }

    func testResourceInspectorTenOutOfTenActions() {
        let r1 = WebpageResource(
            id: "r1",
            url: URL(string: "https://stream.media.org/video_1080p.m3u8")!,
            title: "Movie HD",
            suggestedFilename: "movie_1080p.mp4",
            resourceType: .video,
            mimeType: "video/mp4",
            estimatedSize: 800_000_000,
            discoveredAt: Date(timeIntervalSince1970: 300),
            resolutionText: "1920x1080",
            duration: 7200,
            codecs: "avc1.640028",
            audioLanguage: "en",
            isAudioVideoSplit: false,
            bitrate: 4_500_000,
            container: "MP4",
            trackType: .muxed
        )

        let r2 = WebpageResource(
            id: "r2",
            url: URL(string: "https://audio.media.org/soundtrack.m4a")!,
            title: "OST Audio",
            suggestedFilename: "soundtrack.m4a",
            resourceType: .audio,
            mimeType: "audio/mp4",
            estimatedSize: 80_000_000,
            discoveredAt: Date(timeIntervalSince1970: 200),
            duration: 3600,
            codecs: "mp4a.40.2",
            audioLanguage: "fr",
            bitrate: 320_000,
            container: "M4A",
            trackType: .audioOnly
        )

        let r3 = WebpageResource(
            id: "r3",
            url: URL(string: "https://subs.media.org/captions.vtt")!,
            title: "Subtitles EN",
            suggestedFilename: "captions.vtt",
            resourceType: .other,
            mimeType: "text/vtt",
            estimatedSize: 50_000,
            discoveredAt: Date(timeIntervalSince1970: 100),
            duration: 7200,
            audioLanguage: "en",
            container: "VTT",
            trackType: .subtitles
        )

        let r4 = WebpageResource(
            id: "r4",
            url: URL(string: "https://stream.media.org/video_4k.mpd")!,
            title: "Movie 4K UHD",
            suggestedFilename: "movie_4k.mpd",
            resourceType: .video,
            mimeType: "application/dash+xml",
            estimatedSize: 2_500_000_000,
            discoveredAt: Date(timeIntervalSince1970: 400),
            resolutionText: "3840x2160",
            duration: 7200,
            codecs: "hev1.1.6.L150.90",
            bitrate: 15_000_000,
            container: "MPD",
            trackType: .videoOnly
        )

        let all = [r1, r2, r3, r4]

        // 1. Metadata Verification
        XCTAssertEqual(r1.trackType, .muxed)
        XCTAssertEqual(r2.trackType, .audioOnly)
        XCTAssertEqual(r3.trackType, .subtitles)
        XCTAssertEqual(r4.trackType, .videoOnly)
        XCTAssertEqual(r1.container, "MP4")
        XCTAssertEqual(r2.container, "M4A")
        XCTAssertEqual(r3.container, "VTT")
        XCTAssertEqual(r4.container, "MPD")
        XCTAssertEqual(r1.bitrate, 4_500_000)
        XCTAssertEqual(r4.bitrate, 15_000_000)

        // 2. Sorting by Resolution (Descending & Ascending)
        let byResDesc = BrowserResourceInspectorSheet.sortedResources(all, sortOption: .resolution, direction: .descending)
        XCTAssertEqual(byResDesc.first?.id, "r4") // 2160p
        XCTAssertEqual(byResDesc[1].id, "r1")    // 1080p

        let byResAsc = BrowserResourceInspectorSheet.sortedResources(all, sortOption: .resolution, direction: .ascending)
        XCTAssertEqual(byResAsc.last?.id, "r4")

        // 3. Sorting by Bitrate
        let byBitrate = BrowserResourceInspectorSheet.sortedResources(all, sortOption: .bitrate, direction: .descending)
        XCTAssertEqual(byBitrate.first?.id, "r4") // 15 Mbps
        XCTAssertEqual(byBitrate[1].id, "r1")    // 4.5 Mbps
        XCTAssertEqual(byBitrate[2].id, "r2")    // 320 kbps

        // 4. Sorting by Duration
        let byDur = BrowserResourceInspectorSheet.sortedResources(all, sortOption: .duration, direction: .descending)
        XCTAssertTrue(byDur[0].duration == 7200)

        // 5. Grouping by Manifest, Stream Type, Track Type, Quality
        let manifestGroups = WebpageResource.groupedByManifest(all)
        XCTAssertFalse(manifestGroups.isEmpty)

        let streamTypeGroups = WebpageResource.groupedByStreamType(all)
        let streamTypes = streamTypeGroups.map(\.streamType)
        XCTAssertTrue(streamTypes.contains("HLS Stream (.m3u8)"))
        XCTAssertTrue(streamTypes.contains("DASH Stream (.mpd)"))
        XCTAssertTrue(streamTypes.contains("Direct Audio"))

        let trackTypeGroups = WebpageResource.groupedByTrackType(all)
        let trackTypes = trackTypeGroups.map(\.trackType)
        XCTAssertTrue(trackTypes.contains(.muxed))
        XCTAssertTrue(trackTypes.contains(.audioOnly))
        XCTAssertTrue(trackTypes.contains(.subtitles))
        XCTAssertTrue(trackTypes.contains(.videoOnly))

        let qualityGroups = WebpageResource.groupedByQuality(all)
        let qualityLabels = qualityGroups.map(\.quality)
        XCTAssertTrue(qualityLabels.contains("4K UHD (2160p)"))
        XCTAssertTrue(qualityLabels.contains("Full HD (1080p)"))
        XCTAssertTrue(qualityLabels.contains("Audio Tracks"))

        // 6. Multi-Filtering
        // Search by codec: "hev1"
        let filteredCodec = BrowserResourceInspectorSheet.filteredResources(
            in: all,
            showsAllResources: true,
            searchText: "hev1"
        )
        XCTAssertEqual(filteredCodec.map(\.id), ["r4"])

        // Search by domain: "audio.media.org"
        let filteredDomain = BrowserResourceInspectorSheet.filteredResources(
            in: all,
            showsAllResources: true,
            searchText: "audio.media.org"
        )
        XCTAssertEqual(filteredDomain.map(\.id), ["r2"])

        // Search by container: "VTT"
        let filteredContainer = BrowserResourceInspectorSheet.filteredResources(
            in: all,
            showsAllResources: true,
            searchText: "VTT"
        )
        XCTAssertEqual(filteredContainer.map(\.id), ["r3"])

        // Filter by track type: .audioOnly
        let filteredAudioOnly = BrowserResourceInspectorSheet.filteredResources(
            in: all,
            selectedTrackType: .audioOnly,
            showsAllResources: true
        )
        XCTAssertEqual(filteredAudioOnly.map(\.id), ["r2"])
    }
}

