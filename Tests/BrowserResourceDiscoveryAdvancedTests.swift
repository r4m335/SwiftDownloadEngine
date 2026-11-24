import XCTest
@testable import DownloadEngineKit

final class BrowserResourceDiscoveryAdvancedTests: XCTestCase {

    // MARK: - 1. Document & Navigation Generation Isolation & Stale Observation Rejection

    @MainActor
    func testStaleDocumentGenerationObservationIsDropped() {
        let coordinator = BrowserResourceDiscoveryCoordinator()
        let tabID = UUID()

        // 1. Initial document generation is 1
        let docGen1 = coordinator.nextDocumentGeneration(for: tabID, documentID: "doc-1")
        coordinator.setNavigationGeneration(1, for: tabID)
        XCTAssertEqual(docGen1, 1)

        // Observation from doc 1
        let obs1 = BrowserMediaDiscoveryObservation(
            url: URL(string: "https://example.com/video1.mp4")!,
            rawURL: "https://example.com/video1.mp4",
            source: .domElement,
            tag: "video",
            declaredType: "video/mp4",
            documentID: "doc-1",
            pageOrigin: URL(string: "https://example.com")!,
            frameOrigin: URL(string: "https://example.com")!,
            mayUseBrowserCredentials: false,
            documentGeneration: 1,
            navigationGeneration: 1
        )
        coordinator.ingestMediaObservation(obs1, tabID: tabID, activeTabID: tabID)
        XCTAssertEqual(coordinator.telemetry.totalObservationsReceived, 1)
        XCTAssertEqual(coordinator.telemetry.droppedStaleDocumentObservationsCount, 0)
        XCTAssertEqual(coordinator.mediaCandidates.count, 1)

        // 2. Navigation commits to a new document (generation 2)
        let docGen2 = coordinator.nextDocumentGeneration(for: tabID, documentID: "doc-2")
        coordinator.setNavigationGeneration(2, for: tabID)
        XCTAssertEqual(docGen2, 2)

        // Late arriving observation from older doc 1 (e.g. async fetch resolving late)
        let lateObs = BrowserMediaDiscoveryObservation(
            url: URL(string: "https://example.com/old_stale_asset.mp4")!,
            rawURL: "https://example.com/old_stale_asset.mp4",
            source: .xhr,
            declaredType: "video/mp4",
            documentID: "doc-1",
            pageOrigin: URL(string: "https://example.com")!,
            frameOrigin: URL(string: "https://example.com")!,
            mayUseBrowserCredentials: false,
            documentGeneration: 1,
            navigationGeneration: 1
        )
        coordinator.ingestMediaObservation(lateObs, tabID: tabID, activeTabID: tabID)

        // Stale observation must be dropped
        XCTAssertEqual(coordinator.telemetry.totalObservationsReceived, 2)
        XCTAssertEqual(coordinator.telemetry.droppedStaleDocumentObservationsCount, 1)
        XCTAssertFalse(coordinator.mediaCandidates.contains(where: { $0.rawURL.contains("old_stale_asset") }))

        // Valid observation for generation 2 must succeed
        let validObs = BrowserMediaDiscoveryObservation(
            url: URL(string: "https://example.com/video2.mp4")!,
            rawURL: "https://example.com/video2.mp4",
            source: .domElement,
            tag: "video",
            declaredType: "video/mp4",
            documentID: "doc-2",
            pageOrigin: URL(string: "https://example.com")!,
            frameOrigin: URL(string: "https://example.com")!,
            mayUseBrowserCredentials: false,
            documentGeneration: 2,
            navigationGeneration: 2
        )
        coordinator.ingestMediaObservation(validObs, tabID: tabID, activeTabID: tabID)
        XCTAssertEqual(coordinator.telemetry.totalObservationsReceived, 3)
        XCTAssertEqual(coordinator.telemetry.droppedStaleDocumentObservationsCount, 1)
        XCTAssertTrue(coordinator.mediaCandidates.contains(where: { $0.rawURL.contains("video2.mp4") }))
    }

    // MARK: - 2. Canonical Identity Normalization and Aggressive Deduplication

    @MainActor
    func testCanonicalIdentityNormalizesVolatileParamsAndUpgradesMetadata() {
        var catalog = BrowserMediaCandidateCatalog()

        let baseMediaURL = "https://cdn.provider.com/media/stream_720p.mp4"
        let urlWithVolatileTokens1 = "\(baseMediaURL)?sig=token123&_nocache=9999&t=1600000000"
        let urlWithVolatileTokens2 = "\(baseMediaURL)?token=xyz987&cb=555&t=1600000050"

        // Candidate 1: Initial observation with partial metadata
        let cand1 = BrowserMediaCandidate(
            id: BrowserMediaCandidateClassifier.stableIdentity(rawURL: urlWithVolatileTokens1, url: URL(string: urlWithVolatileTokens1)),
            url: URL(string: urlWithVolatileTokens1),
            rawURL: urlWithVolatileTokens1,
            kind: .directMedia,
            suggestedFilename: "videoplayback",
            availability: .downloadable,
            evidence: ["network response"],
            width: 1280,
            height: 720,
            duration: 120.0
        )
        let merged1 = catalog.merge(cand1)
        XCTAssertEqual(catalog.candidates.count, 1)
        XCTAssertEqual(merged1.width, 1280)

        // Candidate 2: Subsequent observation with different ephemeral tokens and higher quality / descriptive filename
        let cand2 = BrowserMediaCandidate(
            id: BrowserMediaCandidateClassifier.stableIdentity(rawURL: urlWithVolatileTokens2, url: URL(string: urlWithVolatileTokens2)),
            url: URL(string: urlWithVolatileTokens2),
            rawURL: urlWithVolatileTokens2,
            kind: .directMedia,
            suggestedFilename: "Nature_Documentary_720p.mp4",
            availability: .downloadable,
            evidence: ["media element observation"],
            width: 1280,
            height: 720,
            duration: 125.0,
            codecs: "avc1.640028,mp4a.40.2"
        )
        let merged2 = catalog.merge(cand2)

        // Must be deduplicated into the same candidate
        XCTAssertEqual(catalog.candidates.count, 1, "Candidates differing only by volatile query params must deduplicate")
        XCTAssertEqual(catalog.deduplicatedCandidatesCount, 1)
        XCTAssertEqual(merged2.id, merged1.id)
        XCTAssertEqual(merged2.suggestedFilename, "Nature_Documentary_720p.mp4", "Generic filename should upgrade to descriptive filename")
        XCTAssertEqual(merged2.codecs, "avc1.640028,mp4a.40.2")
        XCTAssertEqual(merged2.duration, 125.0)
    }

    // MARK: - 3. Catalog Retention Budgets & Per-Domain Eviction Caps

    @MainActor
    func testCatalogRetentionBudgetsAndPerDomainEviction() {
        var catalog = BrowserMediaCandidateCatalog(maxTotalCandidates: 10, maxCandidatesPerDomain: 3)

        // Insert 5 candidates for domain-a.com
        for i in 1...5 {
            let u = "https://domain-a.com/item_\(i).mp4"
            let c = BrowserMediaCandidate(
                id: "domain-a-\(i)",
                url: URL(string: u),
                rawURL: u,
                kind: .directMedia,
                suggestedFilename: "item_\(i).mp4",
                availability: .downloadable,
                evidence: ["dom"]
            )
            catalog.merge(c)
        }

        // domain-a.com has 5 items but max per domain is 3, so 2 should be evicted
        XCTAssertEqual(catalog.candidates.count, 3)
        XCTAssertEqual(catalog.evictedCandidatesCount, 2)

        // Insert a live stream candidate: live streams must never be evicted
        let liveCand = BrowserMediaCandidate(
            id: "domain-a-live",
            url: URL(string: "https://domain-a.com/live/broadcast.m3u8"),
            rawURL: "https://domain-a.com/live/broadcast.m3u8",
            kind: .hlsManifest,
            suggestedFilename: "broadcast.m3u8",
            availability: .requiresPlanning,
            evidence: ["live stream detected"],
            isLive: true
        )
        catalog.merge(liveCand)
        XCTAssertTrue(catalog.candidates.contains(where: { $0.id == "domain-a-live" }))

        // Insert items from another domain
        for j in 1...3 {
            let u = "https://domain-b.com/clip_\(j).mp4"
            let c = BrowserMediaCandidate(
                id: "domain-b-\(j)",
                url: URL(string: u),
                rawURL: u,
                kind: .directMedia,
                suggestedFilename: "clip_\(j).mp4",
                availability: .downloadable,
                evidence: ["network"]
            )
            catalog.merge(c)
        }

        // Domain B items exist without exceeding domain-b's cap
        XCTAssertEqual(catalog.candidates.filter { $0.url?.host == "domain-b.com" }.count, 3)
    }

    // MARK: - 4. Deterministic Merge Precedence (DOM Scan vs. Network Discovery)

    @MainActor
    func testDeterministicMergePrecedenceDOMVsNetwork() {
        var catalog = BrowserMediaCandidateCatalog()
        let targetURL = URL(string: "https://video.example.org/stream.mp4")!

        // DOM observation: has element title and video dimensions, but generic MIME / size
        let domObs = BrowserMediaCandidate(
            id: "cand-target",
            url: targetURL,
            rawURL: targetURL.absoluteString,
            kind: .directMedia,
            mimeType: nil,
            suggestedFilename: "Awesome Trailer.mp4",
            estimatedSize: nil,
            availability: .downloadable,
            evidence: ["media element observation"],
            width: 1920,
            height: 1080,
            duration: 180.0
        )
        catalog.merge(domObs)

        // Network observation: has authoritative MIME type and verified Content-Length
        let networkObs = BrowserMediaCandidate(
            id: "cand-target",
            url: targetURL,
            rawURL: targetURL.absoluteString,
            kind: .directMedia,
            mimeType: "video/mp4",
            suggestedFilename: "videoplayback",
            estimatedSize: 45_000_000,
            availability: .downloadable,
            evidence: ["network response", "supported media MIME type"]
        )
        let merged = catalog.merge(networkObs)

        // Precedence checks:
        // 1. Network authority for MIME and Content-Length
        XCTAssertEqual(merged.mimeType, "video/mp4")
        XCTAssertEqual(merged.estimatedSize, 45_000_000)

        // 2. DOM authority for descriptive title and element dimensions
        XCTAssertEqual(merged.suggestedFilename, "Awesome Trailer.mp4")
        XCTAssertEqual(merged.width, 1920)
        XCTAssertEqual(merged.height, 1080)
        XCTAssertEqual(merged.duration, 180.0)

        // 3. Evidence combined and deterministically sorted
        XCTAssertTrue(merged.evidence.contains("media element observation"))
        XCTAssertTrue(merged.evidence.contains("network response"))
        XCTAssertEqual(merged.evidence, merged.evidence.sorted())
    }

    // MARK: - 5. Strict Manifest Corruption & Expiry Cleanup

    @MainActor
    func testManifestCorruptionAndExpiryCleanup() {
        let coordinator = BrowserResourceDiscoveryCoordinator()
        let tabID = UUID()

        // 1. Valid HLS manifest
        let validHLS = BrowserMediaCandidate(
            id: "hls-valid",
            url: URL(string: "https://example.com/master.m3u8")!,
            rawURL: "https://example.com/master.m3u8",
            kind: .hlsManifest,
            suggestedFilename: "master.m3u8",
            availability: .requiresPlanning,
            cachedManifestText: "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-STREAM-INF:BANDWIDTH=800000\nv.m3u8"
        )

        // 2. Corrupt HLS manifest (missing EXTM3U header / HTML 404 response payload)
        let corruptHLS = BrowserMediaCandidate(
            id: "hls-corrupt",
            url: URL(string: "https://example.com/bad.m3u8")!,
            rawURL: "https://example.com/bad.m3u8",
            kind: .hlsManifest,
            suggestedFilename: "bad.m3u8",
            availability: .requiresPlanning,
            cachedManifestText: "<html><body>404 Not Found</body></html>"
        )

        // 3. Expired token manifest (expired timestamp in query)
        let expiredURL = URL(string: "https://example.com/signed.m3u8?expires=1000000000")!
        let expiredCand = BrowserMediaCandidate(
            id: "hls-expired",
            url: expiredURL,
            rawURL: expiredURL.absoluteString,
            kind: .hlsManifest,
            suggestedFilename: "signed.m3u8",
            availability: .requiresPlanning,
            cachedManifestText: "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000\nv.m3u8"
        )

        coordinator.ingestMediaCandidates([validHLS, corruptHLS, expiredCand], tabID: tabID, activeTabID: tabID)
        XCTAssertEqual(coordinator.mediaCandidates.count, 3)

        // Execute cleanup
        let pruned = coordinator.pruneExpiredAndCorruptManifests(for: tabID, activeTabID: tabID)
        XCTAssertEqual(pruned, 2, "Both the corrupt HTML manifest and the expired manifest must be pruned")
        XCTAssertEqual(coordinator.telemetry.prunedCorruptedOrExpiredManifestsCount, 2)

        // Only valid HLS survives
        XCTAssertEqual(coordinator.mediaCandidates.count, 1)
        XCTAssertEqual(coordinator.mediaCandidates.first?.id, "hls-valid")
    }

    // MARK: - 6. Rapid SPA Navigation and Fuzzing Test

    @MainActor
    func testRapidSPANavigationAndAsyncObservationsFuzzing() {
        let coordinator = BrowserResourceDiscoveryCoordinator()
        let tabID = UUID()

        // Simulate 20 rapid SPA route changes and intermixed async responses
        for step in 1...20 {
            let docGen = coordinator.nextDocumentGeneration(for: tabID, documentID: "route-\(step)")
            coordinator.setNavigationGeneration(UInt64(step), for: tabID)

            // Emit a current observation
            let currentObs = BrowserMediaDiscoveryObservation(
                url: URL(string: "https://spa-app.io/video_\(step).mp4")!,
                rawURL: "https://spa-app.io/video_\(step).mp4",
                source: .domElement,
                tag: "video",
                declaredType: "video/mp4",
                documentID: "route-\(step)",
                pageOrigin: URL(string: "https://spa-app.io")!,
                frameOrigin: URL(string: "https://spa-app.io")!,
                mayUseBrowserCredentials: false,
                documentGeneration: docGen,
                navigationGeneration: UInt64(step)
            )
            coordinator.ingestMediaObservation(currentObs, tabID: tabID, activeTabID: tabID)

            // Randomly emit a stale async observation from an older step
            if step > 2 {
                let staleStep = step - 2
                let staleObs = BrowserMediaDiscoveryObservation(
                    url: URL(string: "https://spa-app.io/video_stale_\(staleStep).mp4")!,
                    rawURL: "https://spa-app.io/video_stale_\(staleStep).mp4",
                    source: .xhr,
                    declaredType: "video/mp4",
                    documentID: "route-\(staleStep)",
                    pageOrigin: URL(string: "https://spa-app.io")!,
                    frameOrigin: URL(string: "https://spa-app.io")!,
                    mayUseBrowserCredentials: false,
                    documentGeneration: UInt64(staleStep),
                    navigationGeneration: UInt64(staleStep)
                )
                coordinator.ingestMediaObservation(staleObs, tabID: tabID, activeTabID: tabID)
            }
        }

        // Verify telemetry captured all dropped stale observations
        XCTAssertGreaterThan(coordinator.telemetry.droppedStaleDocumentObservationsCount, 15)
        XCTAssertEqual(coordinator.telemetry.totalObservationsReceived, 20 + 18)

        // Cancel probes and verify probe counter
        coordinator.recordProbeTimeout(for: tabID)
        XCTAssertEqual(coordinator.telemetry.probeTimeoutsCount, 1)
        coordinator.cancelInFlightProbes(for: tabID)
    }
}
