import Foundation
import XCTest
#if canImport(WebKit)
import WebKit
#endif
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

    func testCrossOriginAndInvalidFrameMessagesAreRejected() throws {
        let bridge = BrowserMediaDiscoveryBridge()

        // 1. Invalid frame scheme (about:blank, javascript:, data:)
        let invalidFrameURLs = [
            URL(string: "about:blank")!,
            URL(string: "javascript:void(0)")!,
            URL(string: "data:text/html,test")!
        ]
        for frameURL in invalidFrameURLs {
            XCTAssertThrowsError(try bridge.accept(
                payload: ["rawURL": "https://cdn.example/video.mp4", "source": "fetch"],
                pageURL: pageURL,
                frameURL: frameURL
            )) { error in
                XCTAssertEqual(error as? BrowserMediaDiscoveryBridgeError, .invalidFrameOrigin)
            }
        }

        // 2. Cross-origin frame claiming isMainFrame: true
        let crossOriginFrame = URL(string: "https://untrusted-embed.example/player")!
        XCTAssertThrowsError(try bridge.accept(
            payload: ["rawURL": "https://cdn.example/video.mp4", "source": "fetch"],
            pageURL: pageURL,
            frameURL: crossOriginFrame,
            isMainFrame: true
        )) { error in
            XCTAssertEqual(error as? BrowserMediaDiscoveryBridgeError, .invalidFrameOrigin)
        }

        // 3. Cross-origin frame reporting candidate targeting parent page origin
        XCTAssertThrowsError(try bridge.accept(
            payload: ["rawURL": "https://video.example/protected/stream.m3u8", "source": "fetch"],
            pageURL: pageURL,
            frameURL: crossOriginFrame,
            isMainFrame: false
        )) { error in
            XCTAssertEqual(error as? BrowserMediaDiscoveryBridgeError, .crossOriginFrameRejected)
        }

        // 4. Cross-origin frame relative candidate resolves against frameURL, not pageURL
        let subframeRelativeObservation = try XCTUnwrap(bridge.accept(
            payload: ["rawURL": "/media/playlist.m3u8", "source": "fetch"],
            pageURL: pageURL,
            frameURL: crossOriginFrame,
            isMainFrame: false
        ))
        XCTAssertEqual(
            subframeRelativeObservation.url?.absoluteString,
            "https://untrusted-embed.example/media/playlist.m3u8"
        )
        XCTAssertFalse(subframeRelativeObservation.mayUseBrowserCredentials)
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
        XCTAssertTrue(script.contains("mediaSourceObjectURLs"))
        XCTAssertTrue(script.contains("__lidMediaDocumentID"))
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

    // MARK: - User Script Manager & URL Resolution Hook Tests

    func testUserScriptManagerLoadsDefaultScriptAtDocumentStart() {
        let manager = BrowserMediaDiscoveryBridge.UserScriptManager()
        XCTAssertEqual(manager.count, 1)
        XCTAssertTrue(manager.hasScript(id: BrowserMediaDiscoveryBridge.UserScriptManager.defaultURLResolutionScriptID))

        let defaultScript = manager.script(withID: BrowserMediaDiscoveryBridge.UserScriptManager.defaultURLResolutionScriptID)
        XCTAssertNotNil(defaultScript)
        XCTAssertEqual(defaultScript?.injectionTime, .atDocumentStart)
        XCTAssertFalse(defaultScript?.forMainFrameOnly ?? true)
        XCTAssertTrue(defaultScript?.source.contains("window.resolvePlayerURL") ?? false)
        XCTAssertTrue(defaultScript?.source.contains("transforms.sig") ?? false)
        XCTAssertTrue(defaultScript?.source.contains("transforms.n") ?? false)

        let emptyManager = BrowserMediaDiscoveryBridge.UserScriptManager(loadDefaultScript: false)
        XCTAssertEqual(emptyManager.count, 0)
    }

    func testUserScriptManagerLoadsAndManagesCustomScripts() {
        let manager = BrowserMediaDiscoveryBridge.UserScriptManager(loadDefaultScript: false)
        XCTAssertEqual(manager.count, 0)

        let scriptSource = """
        window.resolvePlayerURL = function(url) {
            return url + "&token=resolved";
        };
        """
        let customScript = manager.loadCustomScript(scriptSource, id: "player-resolver")

        XCTAssertEqual(customScript.id, "player-resolver")
        XCTAssertEqual(customScript.source, scriptSource)
        XCTAssertEqual(customScript.injectionTime, .atDocumentStart)
        XCTAssertFalse(customScript.forMainFrameOnly)
        XCTAssertEqual(manager.count, 1)
        XCTAssertTrue(manager.hasScript(id: "player-resolver"))
        XCTAssertEqual(manager.script(withID: "player-resolver")?.source, scriptSource)

        // Registering another script via BrowserUserScript
        let secondScript = BrowserUserScript(
            id: "analytics-blocker",
            source: "console.log('injected');",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        manager.registerScript(secondScript)
        XCTAssertEqual(manager.count, 2)

        let all = manager.allScripts()
        XCTAssertEqual(all.count, 2)
        XCTAssertTrue(all.contains { $0.id == "player-resolver" })
        XCTAssertTrue(all.contains { $0.id == "analytics-blocker" })

        // Unregister
        let removed = manager.unregisterScript(id: "player-resolver")
        XCTAssertEqual(removed?.id, "player-resolver")
        XCTAssertEqual(manager.count, 1)
        XCTAssertFalse(manager.hasScript(id: "player-resolver"))

        manager.removeAllScripts()
        XCTAssertEqual(manager.count, 0)
    }

    func testBridgeIntegratesUserScriptManagerAndHookScript() {
        let bridge = BrowserMediaDiscoveryBridge()
        XCTAssertTrue(bridge.userScriptManager.hasScript(id: BrowserMediaDiscoveryBridge.UserScriptManager.defaultURLResolutionScriptID))
        XCTAssertEqual(bridge.userScriptManager.count, 1)

        let customJS = "window.resolvePlayerURL = function(url) { return url.replace('raw', 'authorized'); };"
        bridge.userScriptManager.loadCustomScript(customJS, id: "custom-hook")

        XCTAssertEqual(bridge.userScriptManager.count, 2)
        XCTAssertTrue(bridge.userScriptManager.hasScript(id: "custom-hook"))

        // Verify base urlResolutionHookScript establishes safe default that allows custom override
        XCTAssertTrue(BrowserMediaDiscoveryBridge.urlResolutionHookScript.contains("window.resolvePlayerURL"))
        XCTAssertTrue(BrowserMediaDiscoveryBridge.urlResolutionHookScript.contains("typeof window.resolvePlayerURL !== \"function\""))
    }

    #if canImport(WebKit)
    func testBridgeInstallRegistersScriptsOnWKWebViewConfiguration() {
        let bridge = BrowserMediaDiscoveryBridge()
        bridge.userScriptManager.loadCustomScript("window.resolvePlayerURL = function(url) { return url; };", id: "hook-test")

        let config = WKWebViewConfiguration()
        bridge.install(on: config)

        let scripts = config.userContentController.userScripts
        // Should contain urlResolutionHookScript, custom script, and observerScript
        XCTAssertGreaterThanOrEqual(scripts.count, 3)

        // First script should be urlResolutionHookScript at .atDocumentStart
        XCTAssertEqual(scripts.first?.injectionTime, WKUserScriptInjectionTime.atDocumentStart)
        XCTAssertFalse(scripts.first?.isForMainFrameOnly ?? true)

        // Custom script should be present at .atDocumentStart
        let hasCustom = scripts.contains { $0.source.contains("window.resolvePlayerURL = function(url)") }
        XCTAssertTrue(hasCustom)

        // Observer script should also be present
        let hasObserver = scripts.contains { $0.source.contains("__lidMediaDiscoveryInstalled") }
        XCTAssertTrue(hasObserver)
    }
    #endif

    func testURLResolutionFallbackReturnsOriginalURL() async {
        let bridge = BrowserMediaDiscoveryBridge()
        let originalURL = URL(string: "https://video.example/segment-001.ts?raw=1")!

        #if canImport(WebKit)
        let webView = await MainActor.run { WKWebView() }
        let resolved = await bridge.resolveMediaURL(originalURL, on: webView)
        XCTAssertEqual(resolved, originalURL)
        #else
        let resolved = await bridge.resolveMediaURL(originalURL, on: nil)
        XCTAssertEqual(resolved, originalURL)
        #endif
    }

    func testObservationWithManifestPrefixPassesEvenIfURLSeenEarlierWithoutPrefix() throws {
        let bridge = BrowserMediaDiscoveryBridge()
        let targetURL = "https://video.example/live/playlist.m3u8"

        // 1. First observation without manifest prefix (e.g. DOM or PerformanceObserver)
        let firstPayload: [String: Any] = [
            "rawURL": targetURL,
            "source": "domMutation",
            "tag": "video"
        ]
        let firstObservation = try XCTUnwrap(
            bridge.accept(payload: firstPayload, pageURL: pageURL, frameURL: pageURL)
        )
        XCTAssertNil(firstObservation.manifestPrefix)

        // 2. Second observation for same URL WITH manifest prefix (e.g. from player fetch/XHR hook)
        let secondPayload: [String: Any] = [
            "rawURL": targetURL,
            "source": "fetch",
            "declaredType": "application/vnd.apple.mpegurl",
            "manifestPrefix": "#EXTM3U\n#EXT-X-VERSION:3\n#EXTINF:4,\nsegment1.ts"
        ]
        let secondObservation = try XCTUnwrap(
            bridge.accept(payload: secondPayload, pageURL: pageURL, frameURL: pageURL)
        )
        XCTAssertEqual(secondObservation.url?.absoluteString, targetURL)
        XCTAssertNotNil(secondObservation.manifestPrefix)
        XCTAssertTrue(secondObservation.manifestPrefix!.contains("#EXTM3U"))

        // 3. Third observation with identical prefix should be deduplicated
        let duplicateObservation = try bridge.accept(payload: secondPayload, pageURL: pageURL, frameURL: pageURL)
        XCTAssertNil(duplicateObservation)
    }

    func testCandidateCatalogMergePreservesCachedManifestText() {
        var catalog = BrowserMediaCandidateCatalog()
        let manifestURL = URL(string: "https://video.example/stream.m3u8")!
        let manifestText = "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\nsegment.ts"

        let candidateA = BrowserMediaCandidate(
            id: "cand-1",
            url: manifestURL,
            rawURL: manifestURL.absoluteString,
            kind: .hlsManifest,
            suggestedFilename: "stream.m3u8",
            availability: .requiresPlanning,
            cachedManifestText: manifestText
        )
        let mergedFirst = catalog.merge(candidateA)
        XCTAssertEqual(mergedFirst.cachedManifestText, manifestText)

        // Merge an update without cachedManifestText; the existing text should be preserved!
        let candidateB = BrowserMediaCandidate(
            id: "cand-1",
            url: manifestURL,
            rawURL: manifestURL.absoluteString,
            kind: .hlsManifest,
            suggestedFilename: "stream.m3u8",
            availability: .requiresPlanning,
            cachedManifestText: nil
        )
        let mergedSecond = catalog.merge(candidateB)
        XCTAssertEqual(mergedSecond.cachedManifestText, manifestText)
        XCTAssertEqual(catalog.candidates.first?.cachedManifestText, manifestText)
    }

    func testBrowserRequestContextComputesOriginAndHeaders() {
        let manifestURL = URL(string: "https://cdn.example.com:8443/hls/master.m3u8?token=123")!
        let pageURL = URL(string: "https://mysite.example:443/watch?v=xyz#frag")!

        let context = BrowserRequestContext(
            url: manifestURL,
            pageURL: pageURL,
            userAgent: "Mozilla/5.0 TestBrowser",
            cookies: []
        )

        XCTAssertEqual(context.origin, "https://mysite.example:443")
        XCTAssertEqual(context.referer, "https://mysite.example:443/watch?v=xyz")

        let effective = context.effectiveHeaders(for: manifestURL)
        XCTAssertEqual(effective["Origin"], "https://mysite.example:443")
        XCTAssertEqual(effective["Referer"], "https://mysite.example:443/watch?v=xyz")
        XCTAssertEqual(effective["User-Agent"], "Mozilla/5.0 TestBrowser")
    }

    func testDownloadRequestEnricherAttachesOriginAndRefererFromContext() {
        let reqURL = URL(string: "https://cdn.example.com/segment0.ts")!
        var request = URLRequest(url: reqURL)
        request.httpMethod = "GET"

        let context = BrowserRequestContext(
            url: reqURL,
            pageURL: URL(string: "https://mysite.example/watch")!,
            userAgent: "CustomEnricherUA",
            cookies: []
        )

        let enriched = DownloadRequestEnricher.enrich(request, context: context)
        XCTAssertEqual(enriched.value(forHTTPHeaderField: "Origin"), "https://mysite.example")
        XCTAssertEqual(enriched.value(forHTTPHeaderField: "Referer"), "https://mysite.example/watch")
        XCTAssertEqual(enriched.value(forHTTPHeaderField: "User-Agent"), "CustomEnricherUA")
    }

    #if canImport(WebKit)
    func testFetchManifestTextThrowsOnUnreachableURL() async {
        let bridge = BrowserMediaDiscoveryBridge()
        let webView = await MainActor.run { WKWebView() }
        let url = URL(string: "https://127.0.0.1:59999/manifest.m3u8")!
        do {
            _ = try await bridge.fetchManifestText(from: url, on: webView)
            XCTFail("Expected error on unreachable webview fetch")
        } catch {
            XCTAssertNotNil(error)
        }
    }
    #endif

    func testObserverScriptContainsIncrementalBoundedReaderAndCancellation() {
        let script = BrowserMediaDiscoveryBridge.observerScript
        XCTAssertTrue(script.contains("getReader"))
        XCTAssertTrue(script.contains("readNextChunk"))
        XCTAssertTrue(script.contains("reader.cancel"))
    }

    func testUserDownloadStartingWithSegIsNotClassifiedAsInternalStreamingSegment() {
        let userRecord = DownloadRecord(
            id: "seg-user-video.mp4",
            originalURL: URL(string: "https://example.com/seg-user-video.mp4")!,
            destinationURL: URL(fileURLWithPath: "/tmp/seg-user-video.mp4"),
            totalSize: 1024
        )
        XCTAssertFalse(userRecord.isStreamingSegment, "A user download whose ID starts with seg- must NOT be classified as internal streaming segment")
        XCTAssertFalse(DownloadCoordinator.isInternalStreamingSegmentID("seg-user-video.mp4"))

        let internalRecord = DownloadRecord(
            id: "\(InternalStreamingConstants.segmentIDPrefix)abc12345",
            originalURL: URL(string: "https://example.com/chunk.ts")!,
            destinationURL: URL(fileURLWithPath: "/tmp/chunk.ts"),
            totalSize: 1024,
            isInternalStreamingSegment: true
        )
        XCTAssertTrue(internalRecord.isStreamingSegment)
        XCTAssertTrue(DownloadCoordinator.isInternalStreamingSegmentID(internalRecord.id))
    }

    func testDASHSegmentIdentificationDoesNotMisclassifyNormalM4A() {
        let dashAudioSegment1 = WebpageResource(
            url: URL(string: "https://dash.akamaized.net/akamai/bbb_30fps/bbb_a64k/bbb_a64k_24.m4a")!,
            title: "bbb_a64k_24.m4a",
            suggestedFilename: "bbb_a64k_24.m4a",
            resourceType: .audio,
            mimeType: "audio/mp4"
        )
        let dashAudioSegment2 = WebpageResource(
            url: URL(string: "https://dash.akamaized.net/akamai/bbb_30fps/bbb_a64k/bbb_a64k_25.m4a")!,
            title: "bbb_a64k_25.m4a",
            suggestedFilename: "bbb_a64k_25.m4a",
            resourceType: .audio,
            mimeType: "audio/mp4"
        )
        let dashVideoSegment = WebpageResource(
            url: URL(string: "https://dash.akamaized.net/akamai/bbb_30fps/bbb_30fps_3840x2160_1200k/bbb_30fps_3840x2160_1200k_1.mp4")!,
            title: "bbb_30fps_3840x2160_1200k_1.mp4",
            suggestedFilename: "bbb_30fps_3840x2160_1200k_1.mp4",
            resourceType: .video,
            mimeType: "video/mp4"
        )
        let initSegment = WebpageResource(
            url: URL(string: "https://dash.akamaized.net/akamai/bbb_30fps/bbb_a64k/init.m4a")!,
            title: "init.m4a",
            suggestedFilename: "init.m4a",
            resourceType: .audio
        )
        let normalAudio = WebpageResource(
            url: URL(string: "https://example.com/music/song.m4a")!,
            title: "song.m4a",
            suggestedFilename: "song.m4a",
            resourceType: .audio,
            mimeType: "audio/m4a"
        )
        let normalPodcast = WebpageResource(
            url: URL(string: "https://example.com/podcasts/episode_complete.m4a")!,
            title: "episode_complete.m4a",
            suggestedFilename: "episode_complete.m4a",
            resourceType: .audio
        )

        // Segment chunks identified
        XCTAssertTrue(dashAudioSegment1.isSegmentChunk)
        XCTAssertTrue(dashAudioSegment2.isSegmentChunk)
        XCTAssertTrue(dashVideoSegment.isSegmentChunk)
        XCTAssertTrue(initSegment.isSegmentChunk)

        // Normal audio resources preserved
        XCTAssertFalse(normalAudio.isSegmentChunk)
        XCTAssertFalse(normalPodcast.isSegmentChunk)

        // Support evaluation rejects DASH segments
        let dashSupport = WebpageResource.evaluateSupport(
            for: dashAudioSegment1.url,
            rawURL: dashAudioSegment1.url.absoluteString,
            mimeType: "audio/mp4"
        )
        XCTAssertFalse(dashSupport.isSupported)
        XCTAssertTrue(dashSupport.reason?.contains("Streaming segment chunk") ?? false)

        // Support evaluation accepts normal audio files
        let normalSupport = WebpageResource.evaluateSupport(
            for: normalAudio.url,
            rawURL: normalAudio.url.absoluteString,
            mimeType: "audio/m4a"
        )
        XCTAssertTrue(normalSupport.isSupported)
        XCTAssertNil(normalSupport.reason)
    }

    func testSequentialSegmentChunkDetectionAcrossResources() {
        let chunk1 = WebpageResource(
            url: URL(string: "https://example.com/stream/track_1.m4a")!,
            title: "track_1.m4a",
            suggestedFilename: "track_1.m4a",
            resourceType: .audio
        )
        let chunk2 = WebpageResource(
            url: URL(string: "https://example.com/stream/track_2.m4a")!,
            title: "track_2.m4a",
            suggestedFilename: "track_2.m4a",
            resourceType: .audio
        )
        let independent = WebpageResource(
            url: URL(string: "https://example.com/downloads/other.m4a")!,
            title: "other.m4a",
            suggestedFilename: "other.m4a",
            resourceType: .audio
        )

        let sequentialIDs = WebpageResourceExtractor.detectSequentialSegmentChunks(in: [chunk1, chunk2, independent])
        XCTAssertTrue(sequentialIDs.contains(chunk1.id))
        XCTAssertTrue(sequentialIDs.contains(chunk2.id))
        XCTAssertFalse(sequentialIDs.contains(independent.id))
    }

    func testDASHManifestReliablyClassifiedCaseInsensitiveAndXML() {
        let lowercaseMPDContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <mpd xmlns="urn:mpeg:dash:schema:mpd:2011" minBufferTime="PT1.5S" type="static" mediaPresentationDuration="PT30S">
            <Period id="0">
            </Period>
        </mpd>
        """
        let classification = StreamingManifestClassifier.classify(
            url: URL(string: "https://example.com/video/manifest")!,
            mimeType: "application/xml",
            content: lowercaseMPDContent
        )
        XCTAssertEqual(classification.kind, .dash)
        XCTAssertTrue(classification.isManifest)

        let queryMPDClassification = StreamingManifestClassifier.classify(
            url: URL(string: "https://example.com/manifest.mpd?auth=token123")!,
            mimeType: "video/vnd.mpeg.dash.mpd"
        )
        XCTAssertEqual(queryMPDClassification.kind, .dash)
        XCTAssertTrue(queryMPDClassification.isManifest)
        XCTAssertTrue(queryMPDClassification.isDASH)
        XCTAssertFalse(queryMPDClassification.isHLS)
    }

    func testDirectDASHManifestNavigationResponseClassification() {
        let directMPDURL = URL(string: "https://dash.akamaized.net/envivio/EnvivioDash3/manifest.mpd")!

        let outcome = BrowserNavigationResponseClassifier.evaluate(
            url: directMPDURL,
            statusCode: 200,
            contentDisposition: nil,
            contentType: "application/dash+xml",
            canShowMIMEType: false
        )

        XCTAssertTrue(outcome.isStreamingManifest)
        XCTAssertEqual(outcome.manifestKind, .dash)
        XCTAssertFalse(outcome.shouldInterceptAsDownload, "DASH manifest must not be intercepted as ordinary download")
        XCTAssertEqual(outcome.suggestedFilename, "manifest.mpd")
        XCTAssertNotNil(outcome.resource)

        let resource = outcome.resource!
        XCTAssertEqual(resource.url, directMPDURL)
        XCTAssertEqual(resource.suggestedFilename, "manifest.mpd")
        XCTAssertEqual(resource.resourceType, .video)
        XCTAssertTrue(resource.isStreamingManifest)
    }

    func testDirectDASHManifestWithAttachmentDispositionIsNotInterceptedAsFlatDownload() {
        let directMPDURL = URL(string: "https://example.com/live/stream.mpd?token=secure")!

        // Server sends Content-Disposition: attachment which would normally force a single-file download
        let outcome = BrowserNavigationResponseClassifier.evaluate(
            url: directMPDURL,
            statusCode: 200,
            contentDisposition: "attachment; filename=\"stream.mpd\"",
            contentType: "application/dash+xml",
            canShowMIMEType: false
        )

        XCTAssertTrue(outcome.isStreamingManifest)
        XCTAssertEqual(outcome.manifestKind, .dash)
        XCTAssertFalse(outcome.shouldInterceptAsDownload, "Streaming manifest must never be intercepted as a flat single-file download")
        XCTAssertNotNil(outcome.resource)
        XCTAssertTrue(outcome.resource!.isStreamingManifest)
    }

    func testDirectHLSManifestNavigationResponseClassification() {
        let directHLSURL = URL(string: "https://example.com/live/master.m3u8")!

        let outcome = BrowserNavigationResponseClassifier.evaluate(
            url: directHLSURL,
            statusCode: 200,
            contentDisposition: nil,
            contentType: "application/vnd.apple.mpegurl",
            canShowMIMEType: true
        )

        XCTAssertTrue(outcome.isStreamingManifest)
        XCTAssertEqual(outcome.manifestKind, .hls)
        XCTAssertFalse(outcome.shouldInterceptAsDownload)
        XCTAssertEqual(outcome.suggestedFilename, "master.m3u8")
        XCTAssertNotNil(outcome.resource)
        XCTAssertTrue(outcome.resource!.isStreamingManifest)
    }

    func testOrdinaryBinaryDownloadNavigationResponseClassification() {
        let zipURL = URL(string: "https://example.com/release/archive.zip")!

        let outcome = BrowserNavigationResponseClassifier.evaluate(
            url: zipURL,
            statusCode: 200,
            contentDisposition: "attachment; filename=\"archive.zip\"",
            contentType: "application/zip",
            canShowMIMEType: false
        )

        XCTAssertFalse(outcome.isStreamingManifest)
        XCTAssertEqual(outcome.manifestKind, .unknown)
        XCTAssertTrue(outcome.shouldInterceptAsDownload)
        XCTAssertEqual(outcome.suggestedFilename, "archive.zip")
        XCTAssertNil(outcome.resource)
    }

    #if canImport(SwiftUI)
    @MainActor
    func testBrowserViewModelIngestMediaResourcePopulatesDiscoveredResourcesAndSelectsManifest() {
        let vm = BrowserViewModel()
        let mpdURL = URL(string: "https://dash.akamaized.net/envivio/EnvivioDash3/manifest.mpd")!
        let resource = WebpageResource(
            url: mpdURL,
            title: "manifest.mpd",
            suggestedFilename: "manifest.mpd",
            resourceType: .video,
            mimeType: "application/dash+xml"
        )

        XCTAssertTrue(vm.discoveredResources.isEmpty)
        XCTAssertTrue(vm.selectedResourceIDs.isEmpty)

        vm.ingestMediaResource(resource, tabID: nil)

        XCTAssertEqual(vm.discoveredResources.count, 1)
        XCTAssertEqual(vm.discoveredResources.first?.url, mpdURL)
        XCTAssertTrue(vm.discoveredResources.first?.isStreamingManifest == true)
        XCTAssertEqual(vm.selectedResourceIDs, [resource.id], "Streaming manifest should be automatically selected for download")
    }
    #endif
}


