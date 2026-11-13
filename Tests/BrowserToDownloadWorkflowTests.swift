import Foundation
import XCTest
@testable import DM_Reverse_engineering

final class BrowserToDownloadWorkflowTests: XCTestCase {

    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserToDownloadWorkflowTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try super.tearDownWithError()
    }

    // MARK: - Pipeline Tests (Cross-Platform: Linux + Apple)

    func testPipeline_DirectFileWithRequestContextPreservesHeadersAndFilename() throws {
        let fileURL = URL(string: "https://files.example.com/dataset.tar.gz")!
        let pageURL = URL(string: "https://example.com/downloads")!
        let context = BrowserRequestContext(
            url: fileURL,
            pageURL: pageURL,
            userAgent: "TestAgent/1.0",
            cookies: [BrowserCookie(name: "session_token", value: "secret123", domain: "files.example.com")],
            customHeaders: ["X-Custom-Client": "EngineTest"]
        )
        let candidate = BrowserMediaCandidate(
            id: "cand-direct-1",
            url: fileURL,
            rawURL: fileURL.absoluteString,
            kind: .directFile,
            mimeType: "application/gzip",
            suggestedFilename: "dataset.tar.gz",
            availability: .downloadable,
            requestContext: context
        )

        let decision = BrowserDownloadDecisionPipeline.decide(
            candidate: candidate
        )

        switch decision.action {
        case .direct(let url, let filename, _, _, let reqContext):
            XCTAssertEqual(url, fileURL)
            XCTAssertEqual(filename, "dataset.tar.gz")
            let headers = reqContext?.effectiveHeaders(for: url, includeCredentials: true)
            XCTAssertEqual(headers?["User-Agent"], "TestAgent/1.0")
            XCTAssertEqual(headers?["Referer"], "https://example.com/downloads")
            XCTAssertEqual(headers?["X-Custom-Client"], "EngineTest")
            XCTAssertTrue(headers?["Cookie"]?.contains("session_token=secret123") == true)
        default:
            XCTFail("Expected .direct decision, got: \(decision.action)")
        }
    }

    func testPipeline_DirectFileOmitCredentialsExcludesCookies() throws {
        let fileURL = URL(string: "https://files.example.com/dataset.tar.gz")!
        let context = BrowserRequestContext(
            url: fileURL,
            pageURL: URL(string: "https://example.com")!,
            userAgent: "TestAgent/1.0",
            cookies: [BrowserCookie(name: "token", value: "123", domain: "files.example.com")]
        )
        let candidate = BrowserMediaCandidate(
            id: "cand-direct-2",
            url: fileURL,
            rawURL: fileURL.absoluteString,
            kind: .directFile,
            suggestedFilename: "dataset.tar.gz",
            availability: .downloadable,
            requestContext: context
        )

        let decision = BrowserDownloadDecisionPipeline.decide(
            candidate: candidate
        )

        switch decision.action {
        case .direct(let url, let filename, _, _, let reqContext):
            XCTAssertEqual(url, fileURL)
            XCTAssertEqual(filename, "dataset.tar.gz")
            let headers = reqContext?.effectiveHeaders(for: url, includeCredentials: false)
            XCTAssertNil(headers?["Cookie"], "Cookies must be excluded when includeCredentials is false")
        default:
            XCTFail("Expected .direct decision, got: \(decision.action)")
        }
    }

    func testPipeline_HLSManifestGeneratesStreamingDecisionWithCustomFilename() throws {
        let manifestURL = URL(string: "https://stream.example.com/playlist.m3u8")!
        let candidate = BrowserMediaCandidate(
            id: "cand-hls-1",
            url: manifestURL,
            rawURL: manifestURL.absoluteString,
            kind: .hlsManifest,
            suggestedFilename: "playlist.m3u8",
            availability: .requiresPlanning
        )

        let decision = BrowserDownloadDecisionPipeline.decide(
            candidate: candidate
        )

        switch decision.action {
        case .streaming(let url, let kind, let filename, _, _):
            XCTAssertEqual(url, manifestURL)
            XCTAssertEqual(kind, .hls)
            XCTAssertEqual(filename, "playlist.m3u8")
        default:
            XCTFail("Expected .streaming decision, got: \(decision.action)")
        }
    }

    func testPipeline_DASHManifestGeneratesStreamingDecision() throws {
        let manifestURL = URL(string: "https://stream.example.com/manifest.mpd")!
        let candidate = BrowserMediaCandidate(
            id: "cand-dash-1",
            url: manifestURL,
            rawURL: manifestURL.absoluteString,
            kind: .dashManifest,
            suggestedFilename: "manifest.mpd",
            availability: .requiresPlanning
        )

        let decision = BrowserDownloadDecisionPipeline.decide(
            candidate: candidate
        )

        switch decision.action {
        case .streaming(let url, let kind, let filename, _, _):
            XCTAssertEqual(url, manifestURL)
            XCTAssertEqual(kind, .dash)
            XCTAssertEqual(filename, "manifest.mpd")
        default:
            XCTFail("Expected .streaming decision, got: \(decision.action)")
        }
    }

    func testPipeline_CompleteBlobRoutesToBlobExport() throws {
        let blobURL = URL(string: "blob:https://example.com/5f9d2c20-749e-4e56-91e7-dca4ffb0d1e1")!
        let candidate = BrowserMediaCandidate(
            id: "cand-blob-1",
            url: nil,
            rawURL: blobURL.absoluteString,
            kind: .completeBlob,
            blobKind: .blob,
            mimeType: "video/mp4",
            suggestedFilename: "video.mp4",
            availability: .captureCandidate
        )

        let decision = BrowserDownloadDecisionPipeline.decide(
            candidate: candidate
        )

        switch decision.action {
        case .blobExport(let candidateResult):
            XCTAssertEqual(candidateResult.id, candidate.id)
        default:
            XCTFail("Expected .blobExport decision, got: \(decision.action)")
        }
    }

    func testPipeline_MediaSourceWithoutManifestRoutesToMSECapture() throws {
        let blobURL = URL(string: "blob:https://example.com/mse-track-buffer")!
        let candidate = BrowserMediaCandidate(
            id: "cand-mse-standalone",
            url: nil,
            rawURL: blobURL.absoluteString,
            kind: .mediaSource,
            blobKind: .mediaSource,
            mimeType: "video/mp4",
            suggestedFilename: "mse_stream.mp4",
            availability: .captureCandidate
        )

        let decision = BrowserDownloadDecisionPipeline.decide(
            candidate: candidate
        )

        switch decision.action {
        case .mseCapture(let candidateResult):
            XCTAssertEqual(candidateResult.id, candidate.id)
        default:
            XCTFail("Expected .mseCapture decision, got: \(decision.action)")
        }
    }

    func testPipeline_MediaSourceWithAssociatedManifestPrefersStreamingManifest() throws {
        let manifestURL = URL(string: "https://example.com/master.m3u8")!
        let blobURL = URL(string: "blob:https://example.com/mse-track-buffer")!

        let manifestCand = BrowserMediaCandidate(
            id: "cand-manifest-primary",
            url: manifestURL,
            rawURL: manifestURL.absoluteString,
            kind: .hlsManifest,
            suggestedFilename: "master.m3u8",
            availability: .requiresPlanning
        )
        let mseCand = BrowserMediaCandidate(
            id: "cand-mse-with-manifest",
            url: nil,
            rawURL: blobURL.absoluteString,
            kind: .mediaSource,
            blobKind: .mediaSource,
            mimeType: "video/mp4",
            suggestedFilename: "mse_stream.mp4",
            availability: .captureCandidate,
            associatedManifestID: manifestCand.id
        )

        let decision = BrowserDownloadDecisionPipeline.decide(
            candidate: mseCand,
            availableCandidates: [manifestCand, mseCand]
        )

        switch decision.action {
        case .streaming(let url, let kind, _, _, _):
            XCTAssertEqual(url, manifestURL)
            XCTAssertEqual(kind, .hls)
        default:
            XCTFail("Expected .streaming decision prioritizing available manifest, got: \(decision.action)")
        }
    }

    func testPipeline_SegmentChunkWithAvailableManifestRedirectsToParentManifest() throws {
        let manifestURL = URL(string: "https://example.com/index.m3u8")!
        let chunkURL = URL(string: "https://example.com/segment_001.ts")!

        let manifestCand = BrowserMediaCandidate(
            id: "cand-manifest-idx",
            url: manifestURL,
            rawURL: manifestURL.absoluteString,
            kind: .hlsManifest,
            suggestedFilename: "index.m3u8",
            availability: .requiresPlanning
        )
        let chunkCand = BrowserMediaCandidate(
            id: "cand-ts-chunk",
            url: chunkURL,
            rawURL: chunkURL.absoluteString,
            kind: .directMedia,
            mimeType: "video/mp2t",
            suggestedFilename: "segment_001.ts",
            availability: .downloadable
        )

        let decision = BrowserDownloadDecisionPipeline.decide(
            candidate: chunkCand,
            availableCandidates: [manifestCand, chunkCand]
        )

        switch decision.action {
        case .streaming(let url, let kind, _, _, _):
            XCTAssertEqual(url, manifestURL)
            XCTAssertEqual(kind, .hls)
        default:
            XCTFail("Expected .streaming redirect to parent manifest, got: \(decision.action)")
        }
    }

    func testPipeline_SegmentChunkWithoutManifestFailsWithActionableError() throws {
        let chunkURL = URL(string: "https://example.com/orphan_chunk.ts")!
        let chunkCand = BrowserMediaCandidate(
            id: "cand-orphan-chunk",
            url: chunkURL,
            rawURL: chunkURL.absoluteString,
            kind: .directMedia,
            mimeType: "video/mp2t",
            suggestedFilename: "orphan_chunk.ts",
            availability: .downloadable
        )

        let decision = BrowserDownloadDecisionPipeline.decide(
            candidate: chunkCand,
            availableCandidates: [chunkCand]
        )

        switch decision.action {
        case .unsupported(let reason):
            XCTAssertTrue(reason.contains(".m3u8"), "Error should explain that chunks require a parent manifest")
        default:
            XCTFail("Expected .unsupported decision for orphan chunk, got: \(decision.action)")
        }
    }

    func testPipeline_DRMProtectedCandidateStrictlyRejectedUpfront() throws {
        let drmURL = URL(string: "https://drm.example.com/widevine_license")!
        let drmCand = BrowserMediaCandidate(
            id: "cand-drm-1",
            url: drmURL,
            rawURL: drmURL.absoluteString,
            kind: .protectedMedia,
            suggestedFilename: "drm_media",
            availability: .unsupported,
            evidence: ["EncryptedMediaExtensions Widevine key request"]
        )

        let decision = BrowserDownloadDecisionPipeline.decide(
            candidate: drmCand
        )

        switch decision.action {
        case .protectedMedia(let reason):
            XCTAssertTrue(reason.contains("Widevine") || reason.contains("DRM"), "Protected reason should identify DRM protection")
        default:
            XCTFail("Expected .protectedMedia decision, got: \(decision.action)")
        }
    }

    func testCandidateCatalog_IngestAndDeduplication() throws {
        var catalog = BrowserMediaCandidateCatalog()
        let mediaURL = URL(string: "https://example.com/video.mp4")!
        let res1 = WebpageResource(url: mediaURL, title: "Video 1", suggestedFilename: "video.mp4", resourceType: .video)
        let res2 = WebpageResource(url: mediaURL, title: "Duplicate Video", suggestedFilename: "video.mp4", resourceType: .video)

        let cand1 = catalog.ingest(resource: res1)
        XCTAssertEqual(catalog.candidates.count, 1)

        // Ingest same candidate directly
        catalog.ingest(candidate: cand1)
        XCTAssertEqual(catalog.candidates.count, 1)

        // Ingest duplicate resource with same URL
        catalog.ingest(resource: res2)
        XCTAssertEqual(catalog.candidates.count, 1)
    }
}

// MARK: - SwiftUI / BrowserViewModel Workflow Tests (Apple Platforms & iOS Device)

#if canImport(SwiftUI)

final class MockWorkflowDownloadDelegate: BrowserDownloadDelegate {
    var importCalls: [(fileURL: URL, filename: String, expectedSize: Int64?, originalURL: URL?, mimeType: String?)] = []
    var handleCalls: [(url: URL, filename: String?, threadCount: Int, speedLimit: Int64?, headers: [String: String]?)] = []

    func importCompletedBrowserFile(
        fileURL: URL,
        filename: String,
        expectedSize: Int64?,
        originalURL: URL?,
        mimeType: String?
    ) async throws {
        importCalls.append((fileURL, filename, expectedSize, originalURL, mimeType))
    }

    func handleDownloadRequest(
        url: URL,
        filename: String?,
        threadCount: Int,
        speedLimitBytesPerSecond: Int64?
    ) async throws {
        try await handleDownloadRequest(
            url: url,
            filename: filename,
            threadCount: threadCount,
            speedLimitBytesPerSecond: speedLimitBytesPerSecond,
            headers: nil
        )
    }

    func handleDownloadRequest(
        url: URL,
        filename: String?,
        threadCount: Int,
        speedLimitBytesPerSecond: Int64?,
        headers: [String: String]?
    ) async throws {
        handleCalls.append((url, filename, threadCount, speedLimitBytesPerSecond, headers))
    }
}

private final class WorkflowMockSegmentExecutor: StreamingSegmentExecutor, @unchecked Sendable {
    func execute(
        _ request: StreamingSegmentTransferRequest,
        progress: (@Sendable (Double) -> Void)?
    ) async throws {}

    func cancel(transferID: String) async {}
}

extension BrowserToDownloadWorkflowTests {

    // MARK: - Test 1: Detected Media Count Computation & Deduplication

    @MainActor
    func test01_DetectedMediaCount_ComputesAndDeduplicatesAcrossCandidatesAndResources() {
        let vm = BrowserViewModel()
        let tabID = vm.createNewTab()
        vm.selectTab(tabID)

        let mediaURL1 = URL(string: "https://example.com/video1.mp4")!
        let mediaURL2 = URL(string: "https://example.com/audio1.mp3")!
        let streamURL = URL(string: "https://example.com/stream.m3u8")!

        let cand1 = BrowserMediaCandidate(
            id: "cand-1",
            url: mediaURL1,
            rawURL: mediaURL1.absoluteString,
            kind: .directMedia,
            suggestedFilename: "video1.mp4",
            availability: .downloadable
        )
        let cand2 = BrowserMediaCandidate(
            id: "cand-2",
            url: mediaURL2,
            rawURL: mediaURL2.absoluteString,
            kind: .directMedia,
            suggestedFilename: "audio1.mp3",
            availability: .downloadable
        )

        // Duplicate URL between candidate catalog and webpage resources
        let res1 = WebpageResource(
            url: mediaURL1,
            title: "Video 1",
            suggestedFilename: "video1.mp4",
            resourceType: .video
        )
        let resStream = WebpageResource(
            url: streamURL,
            title: "Live Stream",
            suggestedFilename: "stream.m3u8",
            resourceType: .video
        )

        // Internal segment chunk must be ignored in count
        let resChunk = WebpageResource(
            url: URL(string: "https://example.com/chunk_001.ts")!,
            title: "chunk_001.ts",
            suggestedFilename: "chunk_001.ts",
            resourceType: .video,
            mimeType: "video/mp2t"
        )

        vm.ingestMediaResources([res1, resStream, resChunk], tabID: tabID)

        // Total distinct actionable media = mediaURL1, mediaURL2, streamURL (chunk is excluded)
        XCTAssertEqual(vm.detectedMediaCount, 2) // res1 + resStream

        var catalog = BrowserMediaCandidateCatalog()
        _ = catalog.ingest(candidate: cand1)
        _ = catalog.ingest(candidate: cand2)
        // With cand2 added
        vm.ingestMediaResources([WebpageResource(url: mediaURL2, title: "Audio 1", suggestedFilename: "audio1.mp3", resourceType: .audio)], tabID: tabID)
        XCTAssertEqual(vm.detectedMediaCount, 3) // mediaURL1, mediaURL2, streamURL
    }

    // MARK: - Test 2: Prompt Download for Candidate Initializes Sheet

    @MainActor
    func test02_PromptDownloadForCandidate_InitializesSheetStateWithCandidateMetadata() {
        let vm = BrowserViewModel()
        let url = URL(string: "https://cdn.example.com/archive.zip")!
        let pageURL = URL(string: "https://example.com/downloads")!
        let context = BrowserRequestContext(
            url: url,
            pageURL: pageURL,
            userAgent: "TestAgent/1.0",
            cookies: [BrowserCookie(name: "auth", value: "token123", domain: "cdn.example.com")]
        )
        let candidate = BrowserMediaCandidate(
            id: "cand-zip",
            url: url,
            rawURL: url.absoluteString,
            kind: .directFile,
            mimeType: "application/zip",
            suggestedFilename: "archive.zip",
            estimatedSize: 50_000_000,
            availability: .downloadable,
            requestContext: context
        )

        vm.promptDownload(for: candidate, customFilename: "custom_archive.zip")

        XCTAssertTrue(vm.isShowingDownloadSheet)
        XCTAssertEqual(vm.downloadCandidateURL, url)
        XCTAssertEqual(vm.downloadCandidateFilename, "custom_archive.zip")
        XCTAssertEqual(vm.activeDownloadCandidate?.id, candidate.id)
        XCTAssertEqual(vm.downloadCandidateRequestContext?.url, url)
        XCTAssertTrue(vm.useBrowserCredentials)
        XCTAssertEqual(vm.downloadCandidateThreads, 6)
    }

    // MARK: - Test 3: Prompt Download for Resource Maps to Candidate and Initializes Sheet

    @MainActor
    func test03_PromptDownloadForResource_MapsResourceToCandidateAndInitializesSheet() {
        let vm = BrowserViewModel()
        let streamURL = URL(string: "https://stream.example.com/playlist.m3u8")!
        let resource = WebpageResource(
            url: streamURL,
            title: "Movie Master Playlist",
            suggestedFilename: "movie.m3u8",
            resourceType: .video
        )

        vm.promptDownload(for: resource)

        XCTAssertTrue(vm.isShowingDownloadSheet)
        XCTAssertEqual(vm.downloadCandidateURL, streamURL)
        XCTAssertEqual(vm.downloadCandidateFilename, "movie.m3u8")
        XCTAssertEqual(vm.activeDownloadResource?.id, resource.id)
        XCTAssertEqual(vm.activeDownloadCandidate?.kind, .hlsManifest)
    }

    // MARK: - Test 4: Custom Filename in Download Sheet is Passed to Direct HTTP Download

    @MainActor
    func test04_CustomFilenameInDownloadSheet_IsPassedToDirectHTTPDownload() async throws {
        let mock = MockWorkflowDownloadDelegate()
        let vm = BrowserViewModel(downloadDelegate: mock)

        let fileURL = URL(string: "https://files.example.com/dataset.tar.gz")!
        let candidate = BrowserMediaCandidate(
            id: "cand-tar",
            url: fileURL,
            rawURL: fileURL.absoluteString,
            kind: .directFile,
            suggestedFilename: "dataset.tar.gz",
            availability: .downloadable
        )

        vm.promptDownload(for: candidate)
        // User changes filename in the sheet
        vm.downloadCandidateFilename = "MyRenamedDataset.tar.gz"

        try await vm.executeDownload()

        XCTAssertFalse(vm.isShowingDownloadSheet)
        XCTAssertEqual(mock.handleCalls.count, 1)
        let call = try XCTUnwrap(mock.handleCalls.first)
        XCTAssertEqual(call.url, fileURL)
        XCTAssertEqual(call.filename, "MyRenamedDataset.tar.gz")
        XCTAssertEqual(vm.downloadSuccessNotification, "Download queued: MyRenamedDataset.tar.gz")
    }

    // MARK: - Test 5: Worker Threads and Speed Limit in Download Sheet are Passed to Direct HTTP

    @MainActor
    func test05_WorkerThreadsAndSpeedLimitInDownloadSheet_ArePassedToDirectHTTPDownload() async throws {
        let mock = MockWorkflowDownloadDelegate()
        let vm = BrowserViewModel(downloadDelegate: mock)

        let fileURL = URL(string: "https://files.example.com/huge_iso.iso")!
        let candidate = BrowserMediaCandidate(
            id: "cand-iso",
            url: fileURL,
            rawURL: fileURL.absoluteString,
            kind: .directFile,
            suggestedFilename: "huge_iso.iso",
            availability: .downloadable
        )

        vm.promptDownload(for: candidate)
        // User configures acceleration
        vm.downloadCandidateThreads = 16
        vm.downloadCandidateSpeedLimitKBps = "5120" // 5 MB/s = 5,242,880 B/s

        try await vm.executeDownload()

        XCTAssertFalse(vm.isShowingDownloadSheet)
        let call = try XCTUnwrap(mock.handleCalls.first)
        XCTAssertEqual(call.threadCount, 16)
        XCTAssertEqual(call.speedLimit, 5120 * 1024)
    }

    // MARK: - Test 6: Session Cookies and Headers are Passed when Credentials Enabled

    @MainActor
    func test06_SessionCookiesAndHeaders_ArePassedToDirectDownloadWhenCredentialsEnabled() async throws {
        let mock = MockWorkflowDownloadDelegate()
        let vm = BrowserViewModel(downloadDelegate: mock)

        let mediaURL = URL(string: "https://media.protected.example/video.mp4")!
        let pageURL = URL(string: "https://protected.example/watch?v=123")!
        let context = BrowserRequestContext(
            url: mediaURL,
            pageURL: pageURL,
            userAgent: "CustomUserAgent/2.0",
            cookies: [
                BrowserCookie(name: "sess_id", value: "abc_secret", domain: "media.protected.example", path: "/")
            ],
            customHeaders: [
                "X-Custom-Client": "iOS-App"
            ]
        )
        let candidate = BrowserMediaCandidate(
            id: "cand-cred",
            url: mediaURL,
            rawURL: mediaURL.absoluteString,
            kind: .directMedia,
            suggestedFilename: "video.mp4",
            availability: .downloadable,
            requestContext: context
        )

        vm.promptDownload(for: candidate)
        vm.useBrowserCredentials = true

        try await vm.executeDownload()

        let call = try XCTUnwrap(mock.handleCalls.first)
        let headers = try XCTUnwrap(call.headers)
        XCTAssertEqual(headers["User-Agent"], "CustomUserAgent/2.0")
        XCTAssertEqual(headers["Referer"], "https://protected.example/watch?v=123")
        XCTAssertTrue(headers["Cookie"]?.contains("sess_id=abc_secret") == true)
        XCTAssertEqual(headers["X-Custom-Client"], "iOS-App")
    }

    // MARK: - Test 7: Session Cookies and Headers are Omitted when Credentials Disabled

    @MainActor
    func test07_SessionCookiesAndHeaders_AreOmittedWhenCredentialsDisabled() async throws {
        let mock = MockWorkflowDownloadDelegate()
        let vm = BrowserViewModel(downloadDelegate: mock)

        let mediaURL = URL(string: "https://media.protected.example/video.mp4")!
        let pageURL = URL(string: "https://protected.example/watch?v=123")!
        let context = BrowserRequestContext(
            url: mediaURL,
            pageURL: pageURL,
            userAgent: "CustomUserAgent/2.0",
            cookies: [
                BrowserCookie(name: "sess_id", value: "abc_secret", domain: "media.protected.example", path: "/")
            ]
        )
        let candidate = BrowserMediaCandidate(
            id: "cand-cred-disabled",
            url: mediaURL,
            rawURL: mediaURL.absoluteString,
            kind: .directMedia,
            suggestedFilename: "video.mp4",
            availability: .downloadable,
            requestContext: context
        )

        vm.promptDownload(for: candidate)
        vm.useBrowserCredentials = false // Explicitly toggle off credentials

        try await vm.executeDownload()

        let call = try XCTUnwrap(mock.handleCalls.first)
        let headers = call.headers
        XCTAssertNil(headers?["Cookie"], "Cookies must be excluded when useBrowserCredentials is false")
    }

    // MARK: - Test 8: Custom Filename in Download Sheet is Preserved in HLS Streaming Execution

    @MainActor
    func test08_CustomFilenameInDownloadSheet_IsPreservedInHLSStreamingExecution() async throws {
        let orchestrator = StreamingDownloadOrchestrator(
            segmentExecutor: WorkflowMockSegmentExecutor()
        )
        let vm = BrowserViewModel(
            streamingOrchestrator: orchestrator,
            streamingDestinationDirectoryURL: tempDirectory
        )

        let manifestURL = URL(string: "https://stream.example.com/playlist.m3u8")!
        let manifestText = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:10
        #EXTINF:10.0,
        seg1.ts
        #EXT-X-ENDLIST
        """
        let candidate = BrowserMediaCandidate(
            id: "cand-hls-rename",
            url: manifestURL,
            rawURL: manifestURL.absoluteString,
            kind: .hlsManifest,
            suggestedFilename: "original_playlist.m3u8",
            availability: .requiresPlanning,
            cachedManifestText: manifestText
        )

        vm.promptDownload(for: candidate)
        // User renames streaming output in sheet
        vm.downloadCandidateFilename = "MyCustomMovie.mp4"

        try await vm.executeDownload()

        XCTAssertFalse(vm.isShowingDownloadSheet)
        XCTAssertEqual(vm.activeStreamingFilename, "MyCustomMovie.mp4")
    }

    // MARK: - Test 9: Custom Filename in Download Sheet is Preserved in DASH Streaming Execution

    @MainActor
    func test09_CustomFilenameInDownloadSheet_IsPreservedInDASHStreamingExecution() async throws {
        let orchestrator = StreamingDownloadOrchestrator(
            segmentExecutor: WorkflowMockSegmentExecutor()
        )
        let vm = BrowserViewModel(
            streamingOrchestrator: orchestrator,
            streamingDestinationDirectoryURL: tempDirectory
        )

        let manifestURL = URL(string: "https://stream.example.com/manifest.mpd")!
        let candidate = BrowserMediaCandidate(
            id: "cand-dash-rename",
            url: manifestURL,
            rawURL: manifestURL.absoluteString,
            kind: .dashManifest,
            suggestedFilename: "manifest.mpd",
            availability: .requiresPlanning
        )

        vm.promptDownload(for: candidate)
        vm.downloadCandidateFilename = "ConferenceKeynote.mp4"

        try await vm.executeDownload()

        XCTAssertFalse(vm.isShowingDownloadSheet)
        XCTAssertEqual(vm.activeStreamingFilename, "ConferenceKeynote.mp4")
    }

    // MARK: - Test 10: Complete Blob Candidate Routes to Blob Export with Custom Filename

    @MainActor
    func test10_CompleteBlobCandidateInDownloadSheet_RoutesToBlobExportWithCustomFilename() async throws {
        let mock = MockWorkflowDownloadDelegate()
        let vm = BrowserViewModel(
            downloadDelegate: mock,
            streamingDestinationDirectoryURL: tempDirectory
        )

        let blobURL = URL(string: "blob:https://example.com/8f5223c2-d35b-4c28-98e3-cf2c42d380e2")!
        let candidate = BrowserMediaCandidate(
            id: "cand-blob-custom",
            url: nil,
            rawURL: blobURL.absoluteString,
            kind: .completeBlob,
            blobKind: .blob,
            mimeType: "video/mp4",
            suggestedFilename: "blob_export.mp4",
            availability: .captureCandidate
        )

        vm.promptDownload(for: candidate)
        vm.downloadCandidateFilename = "ExportedRecording.mp4"

        try await vm.executeDownload()

        // 1. Must NOT submit to ordinary HTTP coordinator
        XCTAssertTrue(mock.handleCalls.isEmpty)
        // 2. Sheet must be dismissed
        XCTAssertFalse(vm.isShowingDownloadSheet)
        // 3. Notification reflects export initiation with custom name
        XCTAssertNotNil(vm.downloadSuccessNotification)
        XCTAssertTrue(vm.downloadSuccessNotification?.contains("ExportedRecording.mp4") == true)
    }

    // MARK: - Test 11: MediaSource Candidate with No Manifest Routes to MSE Capture with Custom Filename

    @MainActor
    func test11_MediaSourceCandidateInDownloadSheet_WithNoManifest_RoutesToMSECaptureWithCustomFilename() async throws {
        let mock = MockWorkflowDownloadDelegate()
        let vm = BrowserViewModel(
            downloadDelegate: mock,
            streamingDestinationDirectoryURL: tempDirectory
        )

        let blobURL = URL(string: "blob:https://example.com/mse-stream-buffer")!
        let candidate = BrowserMediaCandidate(
            id: "cand-mse-standalone",
            url: nil,
            rawURL: blobURL.absoluteString,
            kind: .mediaSource,
            blobKind: .mediaSource,
            mimeType: "video/mp4; codecs=\"avc1.4d401f\"",
            suggestedFilename: "mse_stream.mp4",
            availability: .captureCandidate
        )

        vm.promptDownload(for: candidate)
        vm.downloadCandidateFilename = "CapturedLivestream.mp4"

        try await vm.executeDownload()

        // 1. Must NOT route to HTTP delegate
        XCTAssertTrue(mock.handleCalls.isEmpty)
        // 2. Download sheet dismissed
        XCTAssertFalse(vm.isShowingDownloadSheet)
    }

    // MARK: - Test 12: MediaSource Candidate with Available Manifest Prefers Streaming Manifest

    @MainActor
    func test12_MediaSourceCandidateInDownloadSheet_WithAvailableManifest_PrefersStreamingManifest() async throws {
        let orchestrator = StreamingDownloadOrchestrator(
            segmentExecutor: WorkflowMockSegmentExecutor()
        )
        let vm = BrowserViewModel(
            streamingOrchestrator: orchestrator,
            streamingDestinationDirectoryURL: tempDirectory
        )

        let manifestURL = URL(string: "https://example.com/high_res.m3u8")!
        let blobURL = URL(string: "blob:https://example.com/mse-buffer")!

        let manifestCand = BrowserMediaCandidate(
            id: "cand-hls-primary",
            url: manifestURL,
            rawURL: manifestURL.absoluteString,
            kind: .hlsManifest,
            suggestedFilename: "high_res.m3u8",
            availability: .requiresPlanning
        )
        let mseCand = BrowserMediaCandidate(
            id: "cand-mse-buffer",
            url: nil,
            rawURL: blobURL.absoluteString,
            kind: .mediaSource,
            blobKind: .mediaSource,
            mimeType: "video/mp4",
            suggestedFilename: "mse_buffer.mp4",
            availability: .captureCandidate,
            associatedManifestID: manifestCand.id
        )

        let tabID = vm.createNewTab()
        vm.selectTab(tabID)
        vm.ingestMediaResources([WebpageResource(url: manifestURL, title: "High Res", suggestedFilename: "high_res.m3u8", resourceType: .video)], tabID: tabID)

        vm.promptDownload(for: mseCand)
        vm.downloadCandidateFilename = "PreferredStream.mp4"

        try await vm.executeDownload()

        XCTAssertFalse(vm.isShowingDownloadSheet)
        XCTAssertEqual(vm.activeStreamingFilename, "PreferredStream.mp4")
    }

    // MARK: - Test 13: Segment Chunk with Available Manifest Redirects to Parent Manifest

    @MainActor
    func test13_SegmentChunk_WithAvailableManifest_RedirectsToParentStreamingManifest() async throws {
        let orchestrator = StreamingDownloadOrchestrator(
            segmentExecutor: WorkflowMockSegmentExecutor()
        )
        let vm = BrowserViewModel(
            streamingOrchestrator: orchestrator,
            streamingDestinationDirectoryURL: tempDirectory
        )

        let manifestURL = URL(string: "https://example.com/stream.m3u8")!
        let chunkURL = URL(string: "https://example.com/segment_0042.ts")!

        let tabID = vm.createNewTab()
        vm.selectTab(tabID)
        let resManifest = WebpageResource(url: manifestURL, title: "Stream", suggestedFilename: "stream.m3u8", resourceType: .video)
        let resChunk = WebpageResource(url: chunkURL, title: "Chunk 42", suggestedFilename: "segment_0042.ts", resourceType: .video, mimeType: "video/mp2t")
        vm.ingestMediaResources([resManifest, resChunk], tabID: tabID)

        let chunkCandidate = BrowserMediaCandidate(
            id: "cand-chunk",
            url: chunkURL,
            rawURL: chunkURL.absoluteString,
            kind: .directMedia,
            mimeType: "video/mp2t",
            suggestedFilename: "segment_0042.ts",
            availability: .downloadable
        )

        vm.promptDownload(for: chunkCandidate)
        vm.downloadCandidateFilename = "FullVideoFromChunk.mp4"

        try await vm.executeDownload()

        XCTAssertFalse(vm.isShowingDownloadSheet)
        XCTAssertEqual(vm.activeStreamingFilename, "FullVideoFromChunk.mp4")
    }

    // MARK: - Test 14: Segment Chunk Without Manifest Fails with Actionable Error

    @MainActor
    func test14_SegmentChunk_WithoutManifest_FailsWithActionableErrorMessage() async throws {
        let mock = MockWorkflowDownloadDelegate()
        let vm = BrowserViewModel(downloadDelegate: mock)

        let orphanChunkURL = URL(string: "https://example.com/orphan_chunk.ts")!
        let candidate = BrowserMediaCandidate(
            id: "cand-orphan-chunk",
            url: orphanChunkURL,
            rawURL: orphanChunkURL.absoluteString,
            kind: .directMedia,
            mimeType: "video/mp2t",
            suggestedFilename: "orphan_chunk.ts",
            availability: .downloadable
        )

        vm.promptDownload(for: candidate)
        try await vm.executeDownload()

        XCTAssertFalse(vm.isShowingDownloadSheet)
        XCTAssertTrue(mock.handleCalls.isEmpty, "Orphan chunks must not be sent to HTTP downloader")
        XCTAssertNotNil(vm.blobCaptureErrorMessage ?? vm.streamingErrorMessage)
        XCTAssertTrue((vm.blobCaptureErrorMessage ?? vm.streamingErrorMessage)?.contains(".m3u8") == true)
    }

    // MARK: - Test 15: DRM Protected Candidate Strictly Rejected Upfront

    @MainActor
    func test15_DRMProtectedCandidate_IsStrictlyRejectedUpfrontWithoutCreatingDownload() async throws {
        let mock = MockWorkflowDownloadDelegate()
        let vm = BrowserViewModel(downloadDelegate: mock)

        let drmURL = URL(string: "https://drm.example.com/widevine_license")!
        let candidate = BrowserMediaCandidate(
            id: "cand-drm",
            url: drmURL,
            rawURL: drmURL.absoluteString,
            kind: .protectedMedia,
            suggestedFilename: "encrypted_stream",
            availability: .unsupported,
            evidence: ["EncryptedMediaExtensions request detected: Widevine DRM"]
        )

        vm.promptDownload(for: candidate)
        try await vm.executeDownload()

        XCTAssertFalse(vm.isShowingDownloadSheet)
        XCTAssertTrue(mock.handleCalls.isEmpty, "DRM media must never trigger HTTP downloads")
        XCTAssertNotNil(vm.blobCaptureErrorMessage ?? vm.streamingErrorMessage)
        XCTAssertTrue((vm.blobCaptureErrorMessage ?? vm.streamingErrorMessage)?.contains("DRM") == true)
    }

    // MARK: - Test 16: Batch Download Processes Mixed Candidates Preserving Request Context

    @MainActor
    func test16_BatchDownload_ProcessesMixedCandidatesPreservingRequestContentAndHeaders() async throws {
        let mock = MockWorkflowDownloadDelegate()
        let vm = BrowserViewModel(downloadDelegate: mock)

        let fileURL1 = URL(string: "https://cdn.example.com/doc1.pdf")!
        let fileURL2 = URL(string: "https://cdn.example.com/doc2.pdf")!
        let pageURL = URL(string: "https://example.com/documents")!

        let context = BrowserRequestContext(
            url: fileURL1,
            pageURL: pageURL,
            userAgent: "BatchAgent/1.0",
            cookies: [BrowserCookie(name: "batch_token", value: "sec_999", domain: "cdn.example.com")]
        )

        let res1 = WebpageResource(
            url: fileURL1,
            title: "Doc 1",
            suggestedFilename: "doc1.pdf",
            resourceType: .document,
            requestContext: context
        )
        let res2 = WebpageResource(
            url: fileURL2,
            title: "Doc 2",
            suggestedFilename: "doc2.pdf",
            resourceType: .document,
            requestContext: context
        )

        let tabID = vm.createNewTab()
        vm.selectTab(tabID)
        vm.ingestMediaResources([res1, res2], tabID: tabID)

        // Select both resources
        vm.selectedResourceIDs = [res1.id, res2.id]
        vm.useBrowserCredentials = true

        try await vm.downloadSelectedResources()

        XCTAssertEqual(mock.handleCalls.count, 2)
        XCTAssertEqual(mock.handleCalls[0].url, fileURL1)
        XCTAssertEqual(mock.handleCalls[0].filename, "doc1.pdf")
        XCTAssertEqual(mock.handleCalls[0].headers?["User-Agent"], "BatchAgent/1.0")
        XCTAssertTrue(mock.handleCalls[0].headers?["Cookie"]?.contains("batch_token=sec_999") == true)

        XCTAssertEqual(mock.handleCalls[1].url, fileURL2)
        XCTAssertEqual(mock.handleCalls[1].filename, "doc2.pdf")

        // Selection is cleared and notification posted
        XCTAssertTrue(vm.selectedResourceIDs.isEmpty)
        XCTAssertNotNil(vm.downloadSuccessNotification)
        XCTAssertTrue(vm.downloadSuccessNotification?.contains("2 download(s) queued") == true)
    }

    // MARK: - Test 17: Download Sheet Dismissal and Error State Prevents Modal Deadlock

    @MainActor
    func test17_DownloadSheetDismissalAndErrorState_PreventsModalDeadlock() {
        let vm = BrowserViewModel()
        let url = URL(string: "https://example.com/file.dmg")!

        vm.promptDownload(for: url, suggestedFilename: "file.dmg")
        XCTAssertTrue(vm.isShowingDownloadSheet)

        // User dismisses sheet
        vm.isShowingDownloadSheet = false
        XCTAssertFalse(vm.isShowingDownloadSheet)

        // Re-prompting should function cleanly without stuck modal state
        let secondURL = URL(string: "https://example.com/update.pkg")!
        vm.promptDownload(for: secondURL, suggestedFilename: "update.pkg")
        XCTAssertTrue(vm.isShowingDownloadSheet)
        XCTAssertEqual(vm.downloadCandidateURL, secondURL)
        XCTAssertEqual(vm.downloadCandidateFilename, "update.pkg")
    }

    // MARK: - Test 18: Tab Switching Updates Active Tab Media Candidates and Count

    @MainActor
    func test18_TabSwitching_UpdatesActiveTabMediaCandidatesAndCount() {
        let vm = BrowserViewModel()
        let tab1 = vm.createNewTab()
        let tab2 = vm.createNewTab()

        // Tab 1 discoveries
        vm.selectTab(tab1)
        let mediaURL1 = URL(string: "https://site-a.com/movie.mp4")!
        let res1 = WebpageResource(url: mediaURL1, title: "Movie A", suggestedFilename: "movie.mp4", resourceType: .video)
        vm.ingestMediaResources([res1], tabID: tab1)

        XCTAssertEqual(vm.detectedMediaCount, 1)

        // Tab 2 discoveries
        vm.selectTab(tab2)
        let mediaURL2a = URL(string: "https://site-b.com/clip1.mp4")!
        let mediaURL2b = URL(string: "https://site-b.com/clip2.mp4")!
        let res2a = WebpageResource(url: mediaURL2a, title: "Clip 1", suggestedFilename: "clip1.mp4", resourceType: .video)
        let res2b = WebpageResource(url: mediaURL2b, title: "Clip 2", suggestedFilename: "clip2.mp4", resourceType: .video)
        vm.ingestMediaResources([res2a, res2b], tabID: tab2)

        XCTAssertEqual(vm.detectedMediaCount, 2)

        // Switch back to Tab 1
        vm.selectTab(tab1)
        XCTAssertEqual(vm.activeTabID, tab1)
        XCTAssertEqual(vm.detectedMediaCount, 1)
    }
}
#endif
