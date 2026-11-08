import Foundation
import XCTest
@testable import DM_Reverse_engineering

final class BrowserDownloadDecisionPipelineTests: XCTestCase {

    // MARK: - 1. Direct Media and Direct File

    func testDirectMediaResolvesToDirectActionWithPreservedContext() {
        let url = URL(string: "https://media.example.com/video.mp4")!
        let pageURL = URL(string: "https://media.example.com/watch")!
        let context = BrowserRequestContext(
            url: url,
            pageURL: pageURL,
            userAgent: "TestAgent/1.0",
            cookies: [BrowserCookie(name: "session", value: "xyz123", domain: "media.example.com", path: "/")]
        )
        let candidate = BrowserMediaCandidate(
            id: "cand-direct",
            url: url,
            rawURL: url.absoluteString,
            kind: .directMedia,
            mimeType: "video/mp4",
            suggestedFilename: "video.mp4",
            estimatedSize: 10_000_000,
            availability: .downloadable,
            evidence: ["direct media resource classification"],
            requestContext: context
        )

        let decision = BrowserDownloadDecisionPipeline.decide(candidate: candidate)
        switch decision.action {
        case .direct(let resolvedURL, let filename, let mime, let size, let resolvedContext):
            XCTAssertEqual(resolvedURL, url)
            XCTAssertEqual(filename, "video.mp4")
            XCTAssertEqual(mime, "video/mp4")
            XCTAssertEqual(size, 10_000_000)
            XCTAssertEqual(resolvedContext?.pageURL, context.pageURL)
            XCTAssertEqual(resolvedContext?.cookies.count, 1)
        default:
            XCTFail("Expected .direct action, got \(decision.action)")
        }
    }

    func testDirectFileResolvesToDirectAction() {
        let url = URL(string: "https://files.example.com/document.pdf")!
        let candidate = BrowserMediaCandidate(
            id: "cand-file",
            url: url,
            rawURL: url.absoluteString,
            kind: .directFile,
            mimeType: "application/pdf",
            suggestedFilename: "document.pdf",
            estimatedSize: 500_000,
            availability: .downloadable
        )

        let decision = BrowserDownloadDecisionPipeline.decide(candidate: candidate)
        switch decision.action {
        case .direct(let resolvedURL, let filename, _, _, _):
            XCTAssertEqual(resolvedURL, url)
            XCTAssertEqual(filename, "document.pdf")
        default:
            XCTFail("Expected .direct action, got \(decision.action)")
        }
    }

    // MARK: - 2. Streaming Manifests (HLS and DASH)

    func testHLSManifestResolvesToStreamingActionWithCachedTextAndContext() {
        let manifestURL = URL(string: "https://stream.example.com/master.m3u8")!
        let context = BrowserRequestContext(
            url: manifestURL,
            pageURL: URL(string: "https://stream.example.com/player")!,
            userAgent: "TestAgent/1.0"
        )
        let cachedManifest = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000\n720p.m3u8"
        let candidate = BrowserMediaCandidate(
            id: "cand-hls",
            url: manifestURL,
            rawURL: manifestURL.absoluteString,
            kind: .hlsManifest,
            mimeType: "application/vnd.apple.mpegurl",
            suggestedFilename: "stream.m3u8",
            availability: .requiresPlanning,
            requestContext: context,
            cachedManifestText: cachedManifest
        )

        let decision = BrowserDownloadDecisionPipeline.decide(candidate: candidate)
        switch decision.action {
        case .streaming(let resolvedURL, let kind, let filename, let cachedText, let resolvedContext):
            XCTAssertEqual(resolvedURL, manifestURL)
            XCTAssertEqual(kind, StreamingManifestKind.hls)
            XCTAssertEqual(filename, "stream.m3u8")
            XCTAssertEqual(cachedText, cachedManifest)
            XCTAssertEqual(resolvedContext?.pageURL, context.pageURL)
        default:
            XCTFail("Expected .streaming HLS action, got \(decision.action)")
        }
    }

    func testDASHManifestResolvesToStreamingAction() {
        let manifestURL = URL(string: "https://stream.example.com/manifest.mpd")!
        let candidate = BrowserMediaCandidate(
            id: "cand-dash",
            url: manifestURL,
            rawURL: manifestURL.absoluteString,
            kind: .dashManifest,
            mimeType: "application/dash+xml",
            suggestedFilename: "stream.mpd",
            availability: .requiresPlanning
        )

        let decision = BrowserDownloadDecisionPipeline.decide(candidate: candidate)
        switch decision.action {
        case .streaming(let resolvedURL, let kind, let filename, _, _):
            XCTAssertEqual(resolvedURL, manifestURL)
            XCTAssertEqual(kind, StreamingManifestKind.dash)
            XCTAssertEqual(filename, "stream.mpd")
        default:
            XCTFail("Expected .streaming DASH action, got \(decision.action)")
        }
    }

    // MARK: - 3. Standalone Blob Export

    func testCompleteBlobResolvesToBlobExport() {
        let rawURL = "blob:https://app.example.com/00000000-0000-0000-0000-000000000001"
        let candidate = BrowserMediaCandidate(
            id: "cand-blob",
            url: nil,
            rawURL: rawURL,
            kind: .completeBlob,
            blobKind: .blob,
            mimeType: "video/mp4",
            suggestedFilename: "generated_video.mp4",
            estimatedSize: 2_048_000,
            availability: .captureCandidate,
            documentID: "doc-main"
        )

        let decision = BrowserDownloadDecisionPipeline.decide(candidate: candidate)
        switch decision.action {
        case .blobExport(let resolvedCandidate):
            XCTAssertEqual(resolvedCandidate.rawURL, rawURL)
            XCTAssertEqual(resolvedCandidate.kind, .completeBlob)
            XCTAssertEqual(resolvedCandidate.suggestedFilename, "generated_video.mp4")
            XCTAssertEqual(resolvedCandidate.documentID, "doc-main")
        default:
            XCTFail("Expected .blobExport action, got \(decision.action)")
        }
    }

    // MARK: - 4. MediaSource (MSE)

    func testMediaSourceWithNoManifestResolvesToMSECapture() {
        let rawURL = "blob:https://video.example.com/12345678-1234-1234-1234-123456789abc"
        let candidate = BrowserMediaCandidate(
            id: "cand-mse",
            url: nil,
            rawURL: rawURL,
            kind: .mediaSource,
            blobKind: .mediaSource,
            mimeType: "video/mp4; codecs=\"avc1.4d401f\"",
            suggestedFilename: "mse_stream.mp4",
            availability: .captureCandidate,
            documentID: "doc-player"
        )

        let decision = BrowserDownloadDecisionPipeline.decide(
            candidate: candidate,
            availableResources: [],
            availableCandidates: []
        )
        switch decision.action {
        case .mseCapture(let resolvedCandidate):
            XCTAssertEqual(resolvedCandidate.rawURL, rawURL)
            XCTAssertEqual(resolvedCandidate.kind, .mediaSource)
            XCTAssertEqual(resolvedCandidate.documentID, "doc-player")
        default:
            XCTFail("Expected .mseCapture action, got \(decision.action)")
        }
    }

    // MARK: - 5. Manifest Precedence and Fallback

    func testMediaSourceWithAvailableManifestPrefersStreamingManifest() {
        let mseURL = "blob:https://video.example.com/mse-buffer"
        let manifestURL = URL(string: "https://video.example.com/playlist.m3u8")!

        let mseCandidate = BrowserMediaCandidate(
            id: "cand-mse-with-hls",
            url: nil,
            rawURL: mseURL,
            kind: .mediaSource,
            blobKind: .mediaSource,
            mimeType: "video/mp4; codecs=\"avc1.4d401f\"",
            suggestedFilename: "stream.mp4",
            availability: .captureCandidate,
            associatedManifestURL: manifestURL
        )

        let decision = BrowserDownloadDecisionPipeline.decide(
            candidate: mseCandidate,
            preferManifestIfAvailable: true
        )
        switch decision.action {
        case .streaming(let resolvedURL, let kind, _, _, _):
            XCTAssertEqual(resolvedURL, manifestURL)
            XCTAssertEqual(kind, StreamingManifestKind.hls)
        default:
            XCTFail("Expected .streaming precedence for MSE candidate with manifest, got \(decision.action)")
        }

        // When manifest preference is disabled, explicit MSE capture is respected
        let explicitMSEDecision = BrowserDownloadDecisionPipeline.decide(
            candidate: mseCandidate,
            preferManifestIfAvailable: false
        )
        switch explicitMSEDecision.action {
        case .mseCapture(let resolvedCandidate):
            XCTAssertEqual(resolvedCandidate.rawURL, mseURL)
        default:
            XCTFail("Expected explicit .mseCapture when preferManifestIfAvailable is false, got \(explicitMSEDecision.action)")
        }
    }

    // MARK: - 6. Segment Chunk Routing

    func testSegmentChunkRedirectsToManifestWhenManifestIsAvailable() {
        let chunkURL = URL(string: "https://stream.example.com/segments/segment_001.ts")!
        let manifestURL = URL(string: "https://stream.example.com/playlist.m3u8")!

        let chunkCandidate = BrowserMediaCandidate(
            id: "cand-chunk",
            url: chunkURL,
            rawURL: chunkURL.absoluteString,
            kind: .directMedia,
            mimeType: "video/mp2t",
            suggestedFilename: "segment_001.ts",
            availability: .downloadable
        )
        let manifestResource = WebpageResource(
            url: manifestURL,
            title: "Main Stream",
            suggestedFilename: "playlist.m3u8",
            resourceType: .video
        )

        let decision = BrowserDownloadDecisionPipeline.decide(
            candidate: chunkCandidate,
            availableResources: [manifestResource]
        )
        switch decision.action {
        case .streaming(let resolvedURL, let kind, _, _, _):
            XCTAssertEqual(resolvedURL, manifestURL)
            XCTAssertEqual(kind, StreamingManifestKind.hls)
        default:
            XCTFail("Expected segment chunk to redirect to streaming manifest, got \(decision.action)")
        }
    }

    func testSegmentChunkWithoutManifestIsRejectedAsUnsupported() {
        let chunkURL = URL(string: "https://stream.example.com/segment_005.m4s")!
        let chunkCandidate = BrowserMediaCandidate(
            id: "cand-chunk-alone",
            url: chunkURL,
            rawURL: chunkURL.absoluteString,
            kind: .directMedia,
            suggestedFilename: "segment_005.m4s",
            availability: .downloadable
        )

        let decision = BrowserDownloadDecisionPipeline.decide(
            candidate: chunkCandidate,
            availableResources: []
        )
        switch decision.action {
        case .unsupported(let reason):
            XCTAssertTrue(reason.contains("internal streaming segment chunk"))
        default:
            XCTFail("Expected unsupported rejection for isolated segment chunk, got \(decision.action)")
        }
    }

    // MARK: - 7. DRM Protection

    func testDRMProtectedCandidateIsStrictlyRejected() {
        let protectedCandidate = BrowserMediaCandidate(
            id: "cand-drm",
            url: nil,
            rawURL: "blob:https://secure.example.com/protected",
            kind: .protectedMedia,
            mimeType: "video/mp4",
            suggestedFilename: "protected.mp4",
            availability: .unsupported,
            evidence: ["Encrypted media extension observed (com.widevine.alpha)"]
        )

        let decision = BrowserDownloadDecisionPipeline.decide(candidate: protectedCandidate)
        switch decision.action {
        case .protectedMedia(let reason):
            XCTAssertTrue(reason.contains("widevine") || reason.contains("protected") || reason.contains("DRM"))
        default:
            XCTFail("Expected .protectedMedia action, got \(decision.action)")
        }
    }

    // MARK: - 8. Blob and MSE Separation (Never Routed to HTTP)

    func testBlobAndMSESchemesAreNeverRoutedToHTTP() {
        let blobURL = "blob:https://app.example.com/data"
        let candidate = BrowserMediaCandidate(
            id: "cand-generic-blob",
            url: nil,
            rawURL: blobURL,
            kind: .completeBlob,
            blobKind: .blob,
            mimeType: "application/octet-stream",
            suggestedFilename: "data.bin",
            availability: .captureCandidate
        )

        let decision = BrowserDownloadDecisionPipeline.decide(candidate: candidate)
        switch decision.action {
        case .direct:
            XCTFail("Blob URL must NEVER be routed to .direct HTTP action")
        case .blobExport:
            break
        default:
            XCTFail("Unexpected action: \(decision.action)")
        }
    }

    // MARK: - 9. WebpageResource Decision Mapping

    func testWebpageResourceDecisionMappingPreservesContext() {
        let resourceURL = URL(string: "https://cdn.example.com/video.mp4")!
        let context = BrowserRequestContext(
            url: resourceURL,
            pageURL: URL(string: "https://example.com")!,
            userAgent: "TestAgent/2.0",
            cookies: [BrowserCookie(name: "auth", value: "tok", domain: "example.com", path: "/")]
        )
        let resource = WebpageResource(
            id: "res-1",
            url: resourceURL,
            title: "Test Video",
            suggestedFilename: "video.mp4",
            resourceType: .video,
            mimeType: "video/mp4",
            estimatedSize: 1_000_000,
            isSupported: true,
            requestContext: context
        )

        let decision = BrowserDownloadDecisionPipeline.decide(
            resource: resource,
            availableResources: [resource]
        )
        switch decision.action {
        case .direct(let url, let filename, let mime, let size, let resolvedContext):
            XCTAssertEqual(url, resourceURL)
            XCTAssertEqual(filename, "video.mp4")
            XCTAssertEqual(mime, "video/mp4")
            XCTAssertEqual(size, 1_000_000)
            XCTAssertEqual(resolvedContext?.pageURL, context.pageURL)
            XCTAssertEqual(resolvedContext?.cookies.first?.value, "tok")
        default:
            XCTFail("Expected .direct action, got \(decision.action)")
        }
    }
}

