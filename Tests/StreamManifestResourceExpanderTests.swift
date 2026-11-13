import XCTest
@testable import DM_Reverse_engineering

final class StreamManifestResourceExpanderTests: XCTestCase {

    // Matches the 5-variant Mux test stream from the physical device execution logs:
    // https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8
    private let muxMasterManifest = """
    #EXTM3U
    #EXT-X-STREAM-INF:PROGRAM-ID=1,BANDWIDTH=6221600,RESOLUTION=1920x1080,CODECS="avc1.640028,mp4a.40.2"
    url_0/1920x1080.m3u8
    #EXT-X-STREAM-INF:PROGRAM-ID=1,BANDWIDTH=3361600,RESOLUTION=1280x720,CODECS="avc1.4d401f,mp4a.40.2"
    url_2/1280x720.m3u8
    #EXT-X-STREAM-INF:PROGRAM-ID=1,BANDWIDTH=1980800,RESOLUTION=960x540,CODECS="avc1.4d401f,mp4a.40.2"
    url_4/960x540.m3u8
    #EXT-X-STREAM-INF:PROGRAM-ID=1,BANDWIDTH=1220800,RESOLUTION=640x360,CODECS="avc1.4d401e,mp4a.40.2"
    url_6/640x360.m3u8
    #EXT-X-STREAM-INF:PROGRAM-ID=1,BANDWIDTH=694400,RESOLUTION=416x234,CODECS="avc1.42c00d,mp4a.40.2"
    url_8/416x234.m3u8
    """

    private let masterURL = URL(string: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8")!

    private func makeMasterResource(
        requestContext: BrowserRequestContext? = nil
    ) -> WebpageResource {
        WebpageResource(
            url: masterURL,
            title: "Mux Big Buck Bunny",
            suggestedFilename: "x36xhzz.m3u8",
            resourceType: .video,
            mimeType: "application/vnd.apple.mpegurl",
            requestContext: requestContext,
            manifestText: muxMasterManifest
        )
    }

    // MARK: - 1. Master Playlist Expansion into Five Resources

    func testMasterPlaylistExpansionIntoFiveResources() {
        let master = makeMasterResource()
        let (variants, items) = StreamManifestResourceExpander.expandSynchronously(
            masterResource: master,
            manifestText: muxMasterManifest
        )

        XCTAssertEqual(variants.count, 5, "Mux master playlist must expand into exactly five variant resources")
        XCTAssertEqual(items.count, 5, "Metadata items must be created for all five variants")

        let expectedBadges = ["1080p", "720p", "540p", "360p", "234p"]
        for (idx, badge) in expectedBadges.enumerated() {
            XCTAssertEqual(variants[idx].title, "HLS \(badge)")
            XCTAssertEqual(items[idx].qualityLabel, badge)
            XCTAssertTrue(variants[idx].isStreamingManifest)
            XCTAssertEqual(variants[idx].url, masterURL)
            XCTAssertEqual(variants[idx].suggestedFilename, "x36xhzz-\(badge).mp4")
        }
    }

    // MARK: - 2. Correct Resolution and Bitrate

    func testCorrectResolutionAndBitrate() {
        let master = makeMasterResource()
        let (variants, items) = StreamManifestResourceExpander.expandSynchronously(
            masterResource: master,
            manifestText: muxMasterManifest
        )

        // 1080p
        XCTAssertEqual(variants[0].hlsVariantPreferences?.maximumWidth, 1920)
        XCTAssertEqual(variants[0].hlsVariantPreferences?.maximumHeight, 1080)
        XCTAssertEqual(items[0].bitrateText, "6.2 Mbps")
        XCTAssertEqual(items[0].resolutionText, "1920 × 1080")
        XCTAssertEqual(items[0].videoCodec, "H.264")

        // 720p
        XCTAssertEqual(variants[1].hlsVariantPreferences?.maximumWidth, 1280)
        XCTAssertEqual(variants[1].hlsVariantPreferences?.maximumHeight, 720)
        XCTAssertEqual(items[1].bitrateText, "3.4 Mbps")
        XCTAssertEqual(items[1].resolutionText, "1280 × 720")

        // 540p
        XCTAssertEqual(variants[2].hlsVariantPreferences?.maximumWidth, 960)
        XCTAssertEqual(variants[2].hlsVariantPreferences?.maximumHeight, 540)
        XCTAssertEqual(items[2].bitrateText, "2.0 Mbps")

        // 360p
        XCTAssertEqual(variants[3].hlsVariantPreferences?.maximumWidth, 640)
        XCTAssertEqual(variants[3].hlsVariantPreferences?.maximumHeight, 360)
        XCTAssertEqual(items[3].bitrateText, "1.2 Mbps")

        // 234p
        XCTAssertEqual(variants[4].hlsVariantPreferences?.maximumWidth, 416)
        XCTAssertEqual(variants[4].hlsVariantPreferences?.maximumHeight, 234)
        XCTAssertEqual(items[4].bitrateText, "694 Kbps")
    }

    // MARK: - 3. Correct Relative URI Resolution

    func testCorrectRelativeURIResolution() {
        let master = makeMasterResource()
        let (variants, items) = StreamManifestResourceExpander.expandSynchronously(
            masterResource: master,
            manifestText: muxMasterManifest
        )

        let expectedURIs = [
            "https://test-streams.mux.dev/x36xhzz/url_0/1920x1080.m3u8",
            "https://test-streams.mux.dev/x36xhzz/url_2/1280x720.m3u8",
            "https://test-streams.mux.dev/x36xhzz/url_4/960x540.m3u8",
            "https://test-streams.mux.dev/x36xhzz/url_6/640x360.m3u8",
            "https://test-streams.mux.dev/x36xhzz/url_8/416x234.m3u8"
        ]

        for (idx, expected) in expectedURIs.enumerated() {
            XCTAssertEqual(variants[idx].hlsVariantPreferences?.exactURI?.absoluteString, expected)
            XCTAssertEqual(items[idx].variantURL.absoluteString, expected)
        }
    }

    // MARK: - 4. Correct Exact Variant Download Selection

    func testExactVariantDownloadSelection() throws {
        let master = makeMasterResource()
        let (variants, _) = StreamManifestResourceExpander.expandSynchronously(
            masterResource: master,
            manifestText: muxMasterManifest
        )

        // Select 720p variant (index 1)
        let selected720p = variants[1]
        guard let prefs = selected720p.hlsVariantPreferences else {
            XCTFail("720p variant must contain HLSVariantSelectionPreferences")
            return
        }

        let parsedManifest = try HLSManifestParser.parse(muxMasterManifest, baseURL: masterURL)
        let ranked = try HLSVariantSelector.rank(from: parsedManifest, preferences: prefs)

        XCTAssertFalse(ranked.isEmpty)
        let chosen = ranked[0]
        XCTAssertEqual(chosen.resolution?.height, 720)
        XCTAssertEqual(chosen.resolution?.width, 1280)
        XCTAssertEqual(chosen.bandwidth, 3361600)
        XCTAssertEqual(chosen.uri.absoluteString, "https://test-streams.mux.dev/x36xhzz/url_2/1280x720.m3u8")
    }

    // MARK: - 5. Estimated Size Display When Duration Known

    func testEstimatedSizeDisplayWhenDurationKnown() {
        let master = makeMasterResource()
        let duration: Double = 600.0 // 10 minutes
        let (variants, items) = StreamManifestResourceExpander.expandSynchronously(
            masterResource: master,
            manifestText: muxMasterManifest,
            durationSeconds: duration
        )

        // 1080p: 6,221,600 * 600 / 8 = 466,620,000 bytes (~466 MB)
        XCTAssertNotNil(variants[0].estimatedSize)
        XCTAssertEqual(variants[0].estimatedSize, Int64(Double(6221600) * 600.0 / 8.0))
        XCTAssertTrue(items[0].estimatedSizeText?.contains("~") == true)
        XCTAssertFalse(items[0].estimatedSizeText?.contains("Size unavailable") == true)
    }

    // MARK: - 6. Missing Duration ("Size unavailable")

    func testMissingDurationDisplaysSizeUnavailable() {
        let master = makeMasterResource()
        let (variants, items) = StreamManifestResourceExpander.expandSynchronously(
            masterResource: master,
            manifestText: muxMasterManifest,
            durationSeconds: nil
        )

        for variant in variants {
            XCTAssertNil(variant.estimatedSize)
        }
        for item in items {
            XCTAssertEqual(item.estimatedSizeText, "Size unavailable")
        }
    }

    // MARK: - 7. Single-Variant Media Playlist (No Multiple Expansion)

    func testSingleVariantMediaPlaylistIsNotExpanded() {
        let mediaManifest = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:10
        #EXTINF:10.0,
        segment0.ts
        #EXTINF:10.0,
        segment1.ts
        #EXT-X-ENDLIST
        """

        let singleResource = WebpageResource(
            url: URL(string: "https://example.com/media.m3u8")!,
            title: "Single Media Playlist",
            suggestedFilename: "media.m3u8",
            resourceType: .video,
            mimeType: "application/vnd.apple.mpegurl",
            manifestText: mediaManifest
        )

        let (variants, _) = StreamManifestResourceExpander.expandSynchronously(
            masterResource: singleResource,
            manifestText: mediaManifest
        )

        XCTAssertEqual(variants.count, 1)
        XCTAssertEqual(variants[0].id, singleResource.id)
    }

    // MARK: - 8. Malformed Master Playlist Graceful Fallback

    func testMalformedMasterPlaylistGracefulFallback() {
        let badManifest = "This is not an HLS playlist at all"
        let master = WebpageResource(
            url: masterURL,
            title: "Broken Manifest",
            suggestedFilename: "broken.m3u8",
            resourceType: .video,
            manifestText: badManifest
        )

        let (variants, _) = StreamManifestResourceExpander.expandSynchronously(
            masterResource: master,
            manifestText: badManifest
        )

        XCTAssertEqual(variants.count, 1)
        XCTAssertEqual(variants[0].id, master.id)
    }

    // MARK: - 9. Failed Child Playlist Fetch (Handled Gracefully)

    func testFailedChildPlaylistFetchLeavesVariantsWithUnavailableSize() async {
        let master = makeMasterResource()
        // Expand using the asynchronous expander with a dummy session that fails network requests
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FailingURLProtocol.self]
        let session = URLSession(configuration: config)

        let variants = await StreamManifestResourceExpander.shared.expand(
            manifestResource: master,
            session: session
        )

        // When child playlist network fetch fails, master manifest is still parsed from initialText
        // and all 5 variants are returned with size nil / "Size unavailable"
        XCTAssertEqual(variants.count, 5)
        for v in variants {
            XCTAssertNil(v.estimatedSize)
        }
    }

    // MARK: - 10. Multiple Selected Qualities

    func testMultipleSelectedQualitiesMaintainUniqueFilenamesAndPreferences() {
        let master = makeMasterResource()
        let (variants, _) = StreamManifestResourceExpander.expandSynchronously(
            masterResource: master,
            manifestText: muxMasterManifest
        )

        let q1080 = variants[0]
        let q720 = variants[1]

        XCTAssertNotEqual(q1080.id, q720.id)
        XCTAssertNotEqual(q1080.suggestedFilename, q720.suggestedFilename)
        XCTAssertEqual(q1080.suggestedFilename, "x36xhzz-1080p.mp4")
        XCTAssertEqual(q720.suggestedFilename, "x36xhzz-720p.mp4")
        XCTAssertNotEqual(q1080.hlsVariantPreferences?.exactURI, q720.hlsVariantPreferences?.exactURI)
    }

    // MARK: - 11. Browser Credentials Propagation

    func testBrowserCredentialsPropagation() {
        let context = BrowserRequestContext(
            url: masterURL,
            pageURL: URL(string: "https://test-streams.mux.dev/test.html")!,
            userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X)",
            cookies: [BrowserCookie(name: "session_token", value: "secret123", domain: "test-streams.mux.dev")],
            source: .webpageResource
        )

        let master = makeMasterResource(requestContext: context)
        let (variants, _) = StreamManifestResourceExpander.expandSynchronously(
            masterResource: master,
            manifestText: muxMasterManifest
        )

        for variant in variants {
            XCTAssertNotNil(variant.requestContext)
            XCTAssertEqual(variant.requestContext?.userAgent, "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X)")
            XCTAssertEqual(variant.requestContext?.cookies.first?.value, "secret123")
        }
    }

    // MARK: - 12. No Duplicate Master Playlist Download

    func testNoDuplicateMasterPlaylistDownload() {
        let master = makeMasterResource()
        let (variants, _) = StreamManifestResourceExpander.expandSynchronously(
            masterResource: master,
            manifestText: muxMasterManifest
        )

        for variant in variants {
            // Evaluated as streaming manifest, never as direct download
            XCTAssertTrue(variant.isStreamingManifest)
            XCTAssertTrue(variant.suggestedFilename.hasSuffix(".mp4"))
            XCTAssertFalse(variant.suggestedFilename.hasSuffix(".m3u8"))
            let decision = BrowserDownloadDecisionPipeline.decide(
                resource: variant,
                availableResources: variants,
                availableCandidates: [],
                preferManifestIfAvailable: true
            )
            if case .streaming(let manifestURL, let kind, _, _, _) = decision.action {
                XCTAssertEqual(manifestURL, masterURL)
                XCTAssertEqual(kind, .hls)
            } else {
                XCTFail("Variant must route to .streaming action")
            }
        }
    }

    // MARK: - 13. Existing Blob and Ordinary HTTP Resources Unaffected

    func testExistingBlobAndOrdinaryHTTPResourcesUnaffected() {
        let blobURL = URL(string: "blob:https://example.com/d944e4bf-9407-4e78-9f17-b7d87bc4eb65")!
        let blobResource = WebpageResource(
            url: blobURL,
            title: "Blob Video",
            suggestedFilename: "export.mp4",
            resourceType: .video,
            mimeType: "video/mp4"
        )

        let httpURL = URL(string: "https://example.com/archive.zip")!
        let httpResource = WebpageResource(
            url: httpURL,
            title: "Software Archive",
            suggestedFilename: "archive.zip",
            resourceType: .archive,
            mimeType: "application/zip"
        )

        XCTAssertFalse(blobResource.isStreamingManifest)
        XCTAssertFalse(httpResource.isStreamingManifest)

        let blobDecision = BrowserDownloadDecisionPipeline.decide(
            resource: blobResource,
            availableResources: [blobResource, httpResource],
            availableCandidates: []
        )
        if case .blobExport = blobDecision.action {
            // Correct
        } else {
            XCTFail("Blob resource must route to blobExport")
        }

        let httpDecision = BrowserDownloadDecisionPipeline.decide(
            resource: httpResource,
            availableResources: [blobResource, httpResource],
            availableCandidates: []
        )
        if case .direct(let url, _, _, _, _) = httpDecision.action {
            XCTAssertEqual(url, httpURL)
        } else {
            XCTFail("HTTP zip resource must route to direct download")
        }
    }

    #if canImport(SwiftUI)
    @MainActor
    func testBrowserViewModelManifestExpansion() async {
        let master = makeMasterResource()
        let vm = BrowserViewModel()
        vm.discoveredResources = [master]
        vm.selectedResourceIDs = [master.id]

        // Clear cache and expand
        await StreamManifestResourceExpander.shared.clearCache()
        let expanded = await StreamManifestResourceExpander.shared.expand(manifestResource: master)
        XCTAssertEqual(expanded.count, 5)

        // Test synchronous expansion logic in BrowserViewModel
        vm.expandStreamingManifests()
        // Wait for async task on MainActor
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(vm.discoveredResources.count >= 5)
        XCTAssertTrue(vm.discoveredResources.contains(where: { $0.title == "HLS 1080p" }))
        XCTAssertTrue(vm.discoveredResources.contains(where: { $0.title == "HLS 720p" }))
    }
    #endif
}

// MARK: - Failing URL Protocol Helper for Error Testing

private final class FailingURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))
    }
    override func stopLoading() {}
}
