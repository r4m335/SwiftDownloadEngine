import XCTest
@testable import DownloadEngineKit

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
        // Master should remain selected, NOT silently replaced with highest-ranked variant
        XCTAssertTrue(vm.selectedResourceIDs.contains(master.id))
        if let highest = expanded.first {
            XCTAssertFalse(vm.selectedResourceIDs.contains(highest.id))
        }
    }

    @MainActor
    func testManifestExpansionDoesNotAutoSelectHighestQualityVariant() async {
        let master = makeMasterResource()
        let vm = BrowserViewModel()
        vm.discoveredResources = [master]
        vm.selectedResourceIDs = [master.id]

        await StreamManifestResourceExpander.shared.clearCache()
        let expanded = await StreamManifestResourceExpander.shared.expand(manifestResource: master)
        guard let highest = expanded.first else {
            XCTFail("Expected expanded variants")
            return
        }

        vm.expandStreamingManifests()
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Master must remain selected, NOT automatically replaced by highest-ranked (1080p/4K) variant
        XCTAssertTrue(vm.selectedResourceIDs.contains(master.id))
        XCTAssertFalse(vm.selectedResourceIDs.contains(highest.id))
    }

    func testSignedVariantExpirationEvaluation() {
        let masterURL = URL(string: "https://example.com/master.m3u8")!
        let expiredTimestamp = Int(Date().timeIntervalSince1970 - 1000)
        let expiredVariantURL = URL(string: "https://cdn.example.com/stream_1080p.m3u8?Expires=\(expiredTimestamp)&Signature=xyz")!

        let prefs = HLSVariantSelectionPreferences(exactURI: expiredVariantURL)
        let resource = WebpageResource(
            url: masterURL,
            title: "HLS 1080p",
            suggestedFilename: "test-1080p.mp4",
            resourceType: .video,
            hlsVariantPreferences: prefs
        )

        XCTAssertTrue(resource.isExpired())
        XCTAssertEqual(resource.expirationDate, Date(timeIntervalSince1970: Double(expiredTimestamp)))
    }

    func testSignedVariantExpiringSoonEvaluation() {
        let masterURL = URL(string: "https://example.com/master.m3u8")!
        let soonTimestamp = Int(Date().timeIntervalSince1970 + 120) // expires in 2 minutes
        let soonVariantURL = URL(string: "https://cdn.example.com/stream_720p.m3u8?Expires=\(soonTimestamp)&Signature=xyz")!

        let prefs = HLSVariantSelectionPreferences(exactURI: soonVariantURL)
        let resource = WebpageResource(
            url: masterURL,
            title: "HLS 720p",
            suggestedFilename: "test-720p.mp4",
            resourceType: .video,
            hlsVariantPreferences: prefs
        )

        XCTAssertFalse(resource.isExpired())
        XCTAssertTrue(resource.isExpiringSoon(thresholdSeconds: 300))
        XCTAssertEqual(resource.expirationDate, Date(timeIntervalSince1970: Double(soonTimestamp)))
    }

    func testSignedVariantEarliestExpirationResolution() {
        let masterTimestamp = Int(Date().timeIntervalSince1970 + 600) // expires in 10 minutes
        let masterURL = URL(string: "https://example.com/master.m3u8?Expires=\(masterTimestamp)")!
        let variantTimestamp = Int(Date().timeIntervalSince1970 + 180) // expires in 3 minutes (earlier)
        let variantURL = URL(string: "https://cdn.example.com/variant.m3u8?Expires=\(variantTimestamp)")!

        let prefs = HLSVariantSelectionPreferences(exactURI: variantURL)
        let resource = WebpageResource(
            url: masterURL,
            title: "HLS 1080p",
            suggestedFilename: "test.mp4",
            resourceType: .video,
            hlsVariantPreferences: prefs
        )

        // The earliest expiration deadline should be chosen
        XCTAssertEqual(resource.expirationDate, Date(timeIntervalSince1970: Double(variantTimestamp)))
    }
    #endif

    // MARK: - 14. Browser Context Cache Isolation Tests

    func testManifestCacheIsolatesDifferentBrowserContexts() async {
        let expander = StreamManifestResourceExpander()

        let sharedURL = URL(string: "https://auth.example.com/stream/master.m3u8?token=shared")!
        let pageURL = URL(string: "https://auth.example.com/watch")!

        let contextA = BrowserRequestContext(
            url: sharedURL,
            pageURL: pageURL,
            userAgent: "Browser/UserA",
            cookies: [BrowserCookie(name: "session", value: "userA", domain: "auth.example.com")],
            customHeaders: ["Authorization": "Bearer tokenA"]
        )

        let contextB = BrowserRequestContext(
            url: sharedURL,
            pageURL: pageURL,
            userAgent: "Browser/UserB",
            cookies: [BrowserCookie(name: "session", value: "userB", domain: "auth.example.com")],
            customHeaders: ["Authorization": "Bearer tokenB"]
        )

        let manifestA = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080
        1080p.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720
        720p.m3u8
        """

        let manifestB = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
        360p.m3u8
        """

        let resourceA = WebpageResource(
            url: sharedURL,
            title: "User A Stream",
            suggestedFilename: "master.m3u8",
            resourceType: .video,
            mimeType: "application/vnd.apple.mpegurl",
            requestContext: contextA,
            manifestText: manifestA
        )

        let resourceB = WebpageResource(
            url: sharedURL,
            title: "User B Stream",
            suggestedFilename: "master.m3u8",
            resourceType: .video,
            mimeType: "application/vnd.apple.mpegurl",
            requestContext: contextB,
            manifestText: manifestB
        )

        // Expand resource A for user A
        let variantsA = await expander.expand(manifestResource: resourceA)
        XCTAssertEqual(variantsA.count, 2)
        XCTAssertTrue(variantsA.contains(where: { $0.title.contains("1080p") }))

        // Cache for context B must be empty and must NOT reuse user A's manifest
        let cachedBBefore = await expander.cachedResult(for: sharedURL, requestContext: contextB)
        XCTAssertNil(cachedBBefore, "User B context must not reuse User A's cached manifest result")

        // Expand resource B for user B
        let variantsB = await expander.expand(manifestResource: resourceB)
        XCTAssertEqual(variantsB.count, 1)
        XCTAssertTrue(variantsB.contains(where: { $0.title.contains("360p") }))

        // Verify both cached results remain isolated
        let cachedA = await expander.cachedResult(for: sharedURL, requestContext: contextA)
        XCTAssertEqual(cachedA?.variants.count, 2)

        let cachedB = await expander.cachedResult(for: sharedURL, requestContext: contextB)
        XCTAssertEqual(cachedB?.variants.count, 1)
    }

    func testManifestCachePreservesIsolationForCaseSensitiveURLs() async {
        let expander = StreamManifestResourceExpander()

        let urlUpper = URL(string: "https://cdn.example.com/hls/Stream_ABC/master.m3u8?Signature=Token123")!
        let urlLower = URL(string: "https://cdn.example.com/hls/Stream_abc/master.m3u8?Signature=token123")!

        let manifestUpper = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080
        1080p.m3u8
        """

        let manifestLower = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720
        720p.m3u8
        """

        let resourceUpper = WebpageResource(
            url: urlUpper,
            title: "Upper Stream",
            suggestedFilename: "master.m3u8",
            resourceType: .video,
            mimeType: "application/vnd.apple.mpegurl",
            manifestText: manifestUpper
        )

        let resourceLower = WebpageResource(
            url: urlLower,
            title: "Lower Stream",
            suggestedFilename: "master.m3u8",
            resourceType: .video,
            mimeType: "application/vnd.apple.mpegurl",
            manifestText: manifestLower
        )

        // Expand upper stream
        let variantsUpper = await expander.expand(manifestResource: resourceUpper)
        XCTAssertEqual(variantsUpper.count, 1)
        XCTAssertTrue(variantsUpper.contains(where: { $0.title.contains("1080p") }))

        // Cache lookup for lower stream must be nil (must not collide with upper stream)
        let cachedLowerBefore = await expander.cachedResult(for: urlLower)
        XCTAssertNil(cachedLowerBefore, "Case-sensitive CDN URL must not reuse cached result of differently cased URL")

        // Expand lower stream
        let variantsLower = await expander.expand(manifestResource: resourceLower)
        XCTAssertEqual(variantsLower.count, 1)
        XCTAssertTrue(variantsLower.contains(where: { $0.title.contains("720p") }))

        // Both must remain independently cached
        let cachedUpper = await expander.cachedResult(for: urlUpper)
        XCTAssertEqual(cachedUpper?.variants.first?.title.contains("1080p"), true)

        let cachedLower = await expander.cachedResult(for: urlLower)
        XCTAssertEqual(cachedLower?.variants.first?.title.contains("720p"), true)
    }

    // MARK: - 15. Manifest Cache Expiration & In-Flight Cancellation Tests

    func testManifestCacheExpirationWithSignedURLAndTTL() async {
        let expander = StreamManifestResourceExpander()

        // 1. URL with expired signature timestamp
        let expiredURL = URL(string: "https://auth.example.com/stream/index.m3u8?exp=1577836800")! // 2020-01-01
        let expiredResource = WebpageResource(
            url: expiredURL,
            title: "Expired Stream",
            suggestedFilename: "index.m3u8",
            resourceType: .video,
            mimeType: "application/vnd.apple.mpegurl",
            manifestText: "#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXTINF:2.0,\nseg1.ts\n#EXT-X-ENDLIST"
        )

        let variants = await expander.expand(manifestResource: expiredResource)
        XCTAssertEqual(variants.count, 1)

        // Cached result lookup must detect expired signed timestamp and return nil
        let cached = await expander.cachedResult(for: expiredURL)
        XCTAssertNil(cached, "Expired signed URL must not return a cached expansion result")

        // 2. ExpansionResult TTL test
        let futureURL = URL(string: "https://example.com/stream/live.m3u8")!
        let staleCachedAt = Date().addingTimeInterval(-400) // 400s ago (beyond 300s TTL)
        let result = StreamManifestResourceExpander.ExpansionResult(
            masterURL: futureURL,
            manifestText: "#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXTINF:2.0,\nseg1.ts\n#EXT-X-ENDLIST",
            options: [],
            variants: [],
            variantStreamItems: [],
            isExpanded: false,
            cachedAt: staleCachedAt
        )
        XCTAssertTrue(result.isExpired(), "Result older than maxTTL must be expired")
    }

    func testClearCacheCancelsInFlightTasks() async {
        let expander = StreamManifestResourceExpander()
        let testURL = URL(string: "https://example.com/slow/master.m3u8")!

        // Clear cache should cleanly execute and cancel any active background tasks
        await expander.clearCache(for: testURL)
        let cached = await expander.cachedResult(for: testURL)
        XCTAssertNil(cached)
    }

    // MARK: - Live Stream Identification & Grabber Presentation Tests

    func testLiveManifestExpansionDisablesVODAndLabelsVariants() {
        let liveMasterManifest = """
        #EXTM3U
        #EXT-X-PLAYLIST-TYPE:EVENT
        #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080,CODECS="avc1.640028,mp4a.40.2"
        1080p.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720,CODECS="avc1.4d401f,mp4a.40.2"
        720p.m3u8
        """
        let liveMasterURL = URL(string: "https://live.example.com/master.m3u8")!
        let liveMaster = WebpageResource(
            url: liveMasterURL,
            title: "Breaking News Live",
            suggestedFilename: "master.m3u8",
            resourceType: .video,
            mimeType: "application/vnd.apple.mpegurl",
            manifestText: liveMasterManifest
        )

        let (variants, items) = StreamManifestResourceExpander.expandSynchronously(
            masterResource: liveMaster,
            manifestText: liveMasterManifest
        )

        XCTAssertEqual(variants.count, 2)
        XCTAssertEqual(items.count, 2)

        for res in variants {
            XCTAssertTrue(res.isLive, "Live variant resource must have isLive=true")
            XCTAssertFalse(res.isSupported, "Live variant resource must have isSupported=false for VOD download")
            XCTAssertNotNil(res.unsupportedReason)
            XCTAssertTrue(res.unsupportedReason?.contains("Live stream recording required") == true)
            XCTAssertTrue(res.title.hasPrefix("[LIVE]"), "Live variant title must have [LIVE] prefix: \(res.title)")
        }

        for item in items {
            XCTAssertTrue(item.isLive, "Live item must have isLive=true")
            XCTAssertEqual(item.estimatedSizeText, "Live Broadcast")
        }
    }

    func testLiveSingleMediaPlaylistExpansionDisablesVODAndLabelsResource() {
        let liveMediaManifest = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:6
        #EXT-X-MEDIA-SEQUENCE:100
        #EXTINF:6.0,
        seg100.ts
        #EXTINF:6.0,
        seg101.ts
        """
        let liveMediaURL = URL(string: "https://live.example.com/live.m3u8")!
        let liveMedia = WebpageResource(
            url: liveMediaURL,
            title: "Live Stream",
            suggestedFilename: "live.m3u8",
            resourceType: .video,
            mimeType: "application/vnd.apple.mpegurl",
            manifestText: liveMediaManifest
        )

        let (variants, items) = StreamManifestResourceExpander.expandSynchronously(
            masterResource: liveMedia,
            manifestText: liveMediaManifest
        )

        XCTAssertEqual(variants.count, 1)
        XCTAssertTrue(items.isEmpty)
        let res = variants[0]
        XCTAssertTrue(res.isLive, "Single media live stream must have isLive=true")
        XCTAssertFalse(res.isSupported, "Single media live stream must have isSupported=false")
        XCTAssertNotNil(res.unsupportedReason)
        XCTAssertTrue(res.title.hasPrefix("[LIVE]"))
    }

    func testVODManifestExpansionRemainsSupportedWithoutLiveLabel() {
        let master = makeMasterResource()
        let (variants, items) = StreamManifestResourceExpander.expandSynchronously(
            masterResource: master,
            manifestText: muxMasterManifest
        )

        XCTAssertEqual(variants.count, 5)
        for res in variants {
            XCTAssertFalse(res.isLive, "VOD variant must not be marked isLive")
            XCTAssertTrue(res.isSupported, "VOD variant must remain supported for finite download")
            XCTAssertNil(res.unsupportedReason)
            XCTAssertFalse(res.title.hasPrefix("[LIVE]"))
        }
        for item in items {
            XCTAssertFalse(item.isLive)
            XCTAssertNotEqual(item.estimatedSizeText, "Live Broadcast")
        }
    }

    func testMixedMasterPlaylistExcludesIFrameVariantsFromFullDownload() {
        let mixedManifest = """
        #EXTM3U
        #EXT-X-VERSION:4
        #EXT-X-STREAM-INF:BANDWIDTH=4000000,RESOLUTION=1920x1080,CODECS="avc1.640028,mp4a.40.2"
        1080p.m3u8
        #EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=800000,RESOLUTION=1920x1080,URI="iframe_1080p.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720,CODECS="avc1.4d401f,mp4a.40.2"
        720p.m3u8
        """

        let master = WebpageResource(
            id: "mixed-master",
            url: URL(string: "https://video.example.com/master.m3u8")!,
            title: "Mixed Video",
            suggestedFilename: "mixed.m3u8",
            resourceType: .video,
            mimeType: "application/vnd.apple.mpegurl",
            manifestText: mixedManifest
        )

        let (variants, items) = StreamManifestResourceExpander.expandSynchronously(
            masterResource: master,
            manifestText: mixedManifest
        )

        // Variants for full download must ONLY include the 2 primary video streams (1080p and 720p)
        XCTAssertEqual(variants.count, 2, "I-frame variants must be excluded from full download variants when primary video variants exist")
        XCTAssertEqual(variants[0].title, "HLS 1080p")
        XCTAssertEqual(variants[0].resourceType, .video)
        XCTAssertTrue(variants[0].isSupported)
        XCTAssertEqual(variants[1].title, "HLS 720p")
        XCTAssertEqual(variants[1].resourceType, .video)
        XCTAssertTrue(variants[1].isSupported)

        // Presentation items still retain all 3 items for inspection metadata
        XCTAssertEqual(items.count, 3)
        XCTAssertFalse(items[0].isIFrameOnly)
        XCTAssertFalse(items[1].isIFrameOnly)
        XCTAssertTrue(items[2].isIFrameOnly)
        XCTAssertEqual(items[2].qualityLabel, "1080p (I-Frame)")
    }

    func testIFrameOnlyMasterPlaylistProvidesDistinctThumbnailVariantsNotCompleteVideo() {
        let iframeOnlyManifest = """
        #EXTM3U
        #EXT-X-VERSION:4
        #EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=800000,RESOLUTION=1920x1080,URI="iframe_1080p.m3u8"
        #EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=400000,RESOLUTION=1280x720,URI="iframe_720p.m3u8"
        """

        let master = WebpageResource(
            id: "iframe-master",
            url: URL(string: "https://video.example.com/iframe_master.m3u8")!,
            title: "Trickplay Only",
            suggestedFilename: "iframe_master.m3u8",
            resourceType: .video,
            mimeType: "application/vnd.apple.mpegurl",
            manifestText: iframeOnlyManifest
        )

        let (variants, items) = StreamManifestResourceExpander.expandSynchronously(
            masterResource: master,
            manifestText: iframeOnlyManifest
        )

        XCTAssertEqual(variants.count, 2)
        for variant in variants {
            // Must NOT be classified as complete video (.video)
            XCTAssertEqual(variant.resourceType, .other, "I-frame variants must not be classified as complete video")
            XCTAssertTrue(variant.title.contains("Thumbnails/Seek"), "Title must indicate thumbnail/seek variant")
            XCTAssertTrue(variant.suggestedFilename.hasSuffix("-thumbnails.m3u8"), "Filename must indicate thumbnails rather than .mp4 video")
            XCTAssertFalse(variant.isSupported, "I-frame variant must not be marked isSupported for full download")
            XCTAssertNotNil(variant.unsupportedReason)
        }

        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items[0].isIFrameOnly)
        XCTAssertTrue(items[1].isIFrameOnly)
    }

    func testStandaloneIFramesOnlyPlaylistExpandedAsUnsupportedThumbnailVariant() async {
        let expander = StreamManifestResourceExpander()

        let iframeMediaPlaylist = """
        #EXTM3U
        #EXT-X-VERSION:4
        #EXT-X-I-FRAMES-ONLY
        #EXT-X-TARGETDURATION:5
        #EXTINF:5.0,
        segment1.ts
        #EXTINF:5.0,
        segment2.ts
        #EXT-X-ENDLIST
        """

        let master = WebpageResource(
            id: "standalone-iframe",
            url: URL(string: "https://video.example.com/standalone_iframe.m3u8")!,
            title: "Standalone Trickplay",
            suggestedFilename: "standalone_iframe.m3u8",
            resourceType: .video,
            mimeType: "application/vnd.apple.mpegurl",
            manifestText: iframeMediaPlaylist
        )

        // 1. Asynchronous expansion
        let asyncVariants = await expander.expand(manifestResource: master)
        XCTAssertEqual(asyncVariants.count, 1)
        let asyncVariant = asyncVariants[0]
        XCTAssertEqual(asyncVariant.resourceType, .other, "Standalone I-frame playlist must not be classified as complete video")
        XCTAssertFalse(asyncVariant.isSupported, "Standalone I-frame playlist must not be marked isSupported for full download")
        XCTAssertNotNil(asyncVariant.unsupportedReason)
        XCTAssertTrue(asyncVariant.title.contains("Thumbnails/Seek"))
        XCTAssertTrue(asyncVariant.suggestedFilename.hasSuffix("-thumbnails.m3u8"))

        // 2. Synchronous expansion
        let (syncVariants, _) = StreamManifestResourceExpander.expandSynchronously(
            masterResource: master,
            manifestText: iframeMediaPlaylist
        )
        XCTAssertEqual(syncVariants.count, 1)
        let syncVariant = syncVariants[0]
        XCTAssertEqual(syncVariant.resourceType, .other)
        XCTAssertFalse(syncVariant.isSupported)
        XCTAssertNotNil(syncVariant.unsupportedReason)
        XCTAssertTrue(syncVariant.title.contains("Thumbnails/Seek"))
        XCTAssertTrue(syncVariant.suggestedFilename.hasSuffix("-thumbnails.m3u8"))
    }

    // MARK: - Probe Concurrency & Cancellation Tests

    func testProbeConcurrencyConfiguration() async {
        let expander = StreamManifestResourceExpander(maxConcurrentProbes: 4)
        let maxProbes = await expander.maxConcurrentProbes
        XCTAssertEqual(maxProbes, 4)
        let defaultExpander = StreamManifestResourceExpander()
        let defaultMaxProbes = await defaultExpander.maxConcurrentProbes
        XCTAssertEqual(defaultMaxProbes, 3)
    }

    func testCancelInFlightForTabCancelsUnderlyingTasks() async {
        let expander = StreamManifestResourceExpander(maxConcurrentProbes: 2)
        let tab1 = UUID()
        let tab2 = UUID()

        let res1 = WebpageResource(
            id: "m1",
            url: URL(string: "https://example.com/tab1_manifest.m3u8")!,
            title: "Tab 1 Stream",
            suggestedFilename: "tab1.m3u8",
            resourceType: .video,
            mimeType: "application/vnd.apple.mpegurl"
        )
        let res2 = WebpageResource(
            id: "m2",
            url: URL(string: "https://example.com/tab2_manifest.m3u8")!,
            title: "Tab 2 Stream",
            suggestedFilename: "tab2.m3u8",
            resourceType: .video,
            mimeType: "application/vnd.apple.mpegurl",
            manifestText: muxMasterManifest
        )

        let task1 = Task {
            await expander.expand(manifestResource: res1, tabID: tab1)
        }

        await Task.yield()

        // Cancel Tab 1
        await expander.cancelInFlight(for: tab1)
        let hasInFlightTab1 = await expander.hasInFlightTasks(for: tab1)
        XCTAssertFalse(hasInFlightTab1)

        let result1 = await task1.value
        XCTAssertTrue(result1.isEmpty || result1.count == 1)

        // Tab 2 with valid manifest succeeds
        let result2 = await expander.expand(manifestResource: res2, tabID: tab2)
        XCTAssertEqual(result2.count, 5)
    }

    func testCallerCancellationAbortsInFlightTask() async {
        let expander = StreamManifestResourceExpander(maxConcurrentProbes: 2)
        let tabID = UUID()

        let res = WebpageResource(
            id: "caller-cancel-manifest",
            url: URL(string: "https://example.com/caller_cancel.m3u8")!,
            title: "Cancel Stream",
            suggestedFilename: "cancel.m3u8",
            resourceType: .video,
            mimeType: "application/vnd.apple.mpegurl"
        )

        let callerTask = Task {
            await expander.expand(manifestResource: res, tabID: tabID)
        }

        await Task.yield()
        callerTask.cancel()

        let variants = await callerTask.value
        XCTAssertTrue(variants.isEmpty || variants.count == 1)
        let hasInFlight = await expander.hasInFlightTasks(for: tabID)
        XCTAssertFalse(hasInFlight)
    }

    func testProbeConcurrencySlotAcquisitionAndRelease() async {
        let expander = StreamManifestResourceExpander(maxConcurrentProbes: 2)
        let master = makeMasterResource()

        async let exp1 = expander.expand(manifestResource: master)
        async let exp2 = expander.expand(manifestResource: master)
        async let exp3 = expander.expand(manifestResource: master)

        let (r1, r2, r3) = await (exp1, exp2, exp3)
        XCTAssertEqual(r1.count, 5)
        XCTAssertEqual(r2.count, 5)
        XCTAssertEqual(r3.count, 5)

        let activeCount = await expander.currentActiveProbeCount
        let pendingCount = await expander.currentPendingProbeCount
        XCTAssertEqual(activeCount, 0)
        XCTAssertEqual(pendingCount, 0)
    }

    @MainActor
    func testBrowserViewModelCancelsProbesOnNavigationAndCloseTab() async {
        let expander = StreamManifestResourceExpander(maxConcurrentProbes: 2)
        let vm = BrowserViewModel(streamManifestExpander: expander)
        let tabID = vm.activeTabID ?? vm.createNewTab()

        let res = WebpageResource(
            id: "nav-test-manifest",
            url: URL(string: "https://example.com/nav_manifest.m3u8")!,
            title: "Nav Test Stream",
            suggestedFilename: "nav.m3u8",
            resourceType: .video,
            mimeType: "application/vnd.apple.mpegurl"
        )

        vm.expandStreamingManifests(in: [res], tabID: tabID)
        await Task.yield()

        // Navigating to a new URL cancels probes for active tab
        vm.load(url: URL(string: "https://example.com/page2")!)
        for _ in 0..<30 {
            if !(await expander.hasInFlightTasks(for: tabID)) { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        let hasInFlight = await expander.hasInFlightTasks(for: tabID)
        XCTAssertFalse(hasInFlight)
    }

    func testGenericStream360DoesNotMatchDifferentVideoAndDerivesRealName() {
        let matcher = BrowserDownloadMatcher()
        let existingTransfer = UnifiedTransfer(
            id: "t-stream-360",
            type: .hls,
            name: "stream-360p.mp4",
            source: "https://cdn-one.example/video1/master.m3u8",
            state: .completed,
            totalBytes: 50_000_000,
            completedBytes: 50_000_000,
            downloadSpeedBytesPerSecond: 0
        )

        let differentHostResource = WebpageResource(
            id: "res-other-site",
            url: URL(string: "https://cdn-two.example/video99/master.m3u8")!,
            title: "HLS 360p",
            suggestedFilename: "stream-360p.mp4",
            resourceType: .video,
            mimeType: "application/vnd.apple.mpegurl",
            hlsVariantPreferences: HLSVariantSelectionPreferences(maximumHeight: 360)
        )
        XCTAssertNil(matcher.match(resource: differentHostResource, transfers: [existingTransfer]))

        let sameHostDifferentPath = WebpageResource(
            id: "res-same-host-other-video",
            url: URL(string: "https://cdn-one.example/video2/master.m3u8")!,
            title: "HLS 360p",
            suggestedFilename: "stream-360p.mp4",
            resourceType: .video,
            mimeType: "application/vnd.apple.mpegurl",
            hlsVariantPreferences: HLSVariantSelectionPreferences(maximumHeight: 360)
        )
        XCTAssertNil(matcher.match(resource: sameHostDifferentPath, transfers: [existingTransfer]))

        // Real video name from pageTitle when manifest filename is generic ("stream.m3u8" or "manifest.mpd")
        let genericHLS = WebpageResource(
            url: URL(string: "https://cdn.example/hls/master.m3u8")!,
            title: "HLS Master Playlist",
            suggestedFilename: "stream.m3u8",
            resourceType: .video
        )
        XCTAssertEqual(
            StreamManifestResourceExpander.meaningfulBaseStem(for: genericHLS, pageTitle: "Big Buck Bunny - Watch Online"),
            "Big_Buck_Bunny"
        )

        let genericDASH = WebpageResource(
            url: URL(string: "https://cdn.example/dash/big_buck_bunny/manifest.mpd")!,
            title: "DASH Manifest",
            suggestedFilename: "manifest.mpd",
            resourceType: .video
        )
        XCTAssertEqual(
            StreamManifestResourceExpander.meaningfulBaseStem(for: genericDASH, pageTitle: "Example"),
            "big_buck_bunny"
        )
    }
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
