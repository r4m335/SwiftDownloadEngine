import Foundation
import XCTest
@testable import DM_Reverse_engineering

final class StreamingDownloadOrchestratorTests: XCTestCase {

    func testDiscoveredHLSProducesOneStableProposalAndExecutesOrderedResources() async throws {
        let url = URL(string: "https://video.example/watch/index.m3u8?sig=manifest-signed")!
        let playlist = """
        #EXTM3U
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXT-X-BYTERANGE:4@0
        #EXTINF:2,
        media.bin?sig=segment-signed
        #EXT-X-BYTERANGE:3
        #EXTINF:2,
        media.bin?sig=segment-signed
        #EXT-X-ENDLIST
        """
        let loader = RecordingManifestLoader(data: Data(playlist.utf8), finalURL: url, mimeType: "application/vnd.apple.mpegurl")
        let executor = RecordingSegmentExecutor()
        let orchestrator = StreamingDownloadOrchestrator(manifestLoader: loader, segmentExecutor: executor)
        let candidate = try StreamingManifestCandidate(
            url: url,
            mimeType: "application/vnd.apple.mpegurl"
        )

        let first = try await orchestrator.prepare(candidate: candidate)
        let second = try await orchestrator.prepare(candidate: candidate)
        XCTAssertEqual(first, second)
        let loadCount = await loader.loadCount
        XCTAssertEqual(loadCount, 1)
        let expectedRanges: [StreamingByteRange?] = [
            try StreamingByteRange(start: 0, end: 3),
            try StreamingByteRange(start: 4, end: 6)
        ]
        XCTAssertEqual(first.resources.map(\.byteRange), expectedRanges)

        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let result = try await orchestrator.execute(first, approved: true, destinationDirectory: destination)
        XCTAssertEqual(result.completedSegments.map(\.order), [0, 1])
        let recordedRequests = await executor.requests
        let requestOrders = recordedRequests.map(\.identity.order)
        XCTAssertEqual(requestOrders, [0, 1])
    }

    func testCrossOriginSegmentDoesNotReceiveBrowserCredentials() async throws {
        let manifestURL = URL(string: "https://video.example/watch/index.m3u8?sig=manifest-signed")!
        let playlist = """
        #EXTM3U
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXTINF:2,
        https://cdn.example/media/part.m4s?sig=segment-signed
        #EXT-X-ENDLIST
        """
        let context = BrowserRequestContext(
            url: manifestURL,
            pageURL: URL(string: "https://video.example/watch")!,
            cookies: [BrowserCookie(name: "session", value: "cookie-secret", domain: "video.example")],
            customHeaders: ["Authorization": "Bearer header-secret", "X-Trace-ID": "safe"]
        )
        let loader = RecordingManifestLoader(data: Data(playlist.utf8), finalURL: manifestURL, mimeType: "application/vnd.apple.mpegurl")
        let executor = RecordingSegmentExecutor()
        let orchestrator = StreamingDownloadOrchestrator(manifestLoader: loader, segmentExecutor: executor)
        let candidate = try StreamingManifestCandidate(url: manifestURL, browserRequestContext: context)
        let proposal = try await orchestrator.prepare(candidate: candidate)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        _ = try await orchestrator.execute(proposal, approved: true, destinationDirectory: destination)

        let recordedRequests = await executor.requests
        let request = try XCTUnwrap(recordedRequests.first)
        XCTAssertNil(request.headers["Cookie"])
        XCTAssertNil(request.headers["Authorization"])
        XCTAssertNil(request.headers["Referer"])
        XCTAssertEqual(request.headers["X-Trace-ID"], "safe")
    }

    func testUnsupportedHLSEncryptionIsExplicit() async throws {
        let url = URL(string: "https://video.example/index.m3u8")!
        let playlist = """
        #EXTM3U
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXT-X-KEY:METHOD=SAMPLE-AES,URI="key.bin"
        #EXTINF:2,
        segment.ts
        #EXT-X-ENDLIST
        """
        let orchestrator = StreamingDownloadOrchestrator(
            manifestLoader: RecordingManifestLoader(data: Data(playlist.utf8), finalURL: url, mimeType: "application/vnd.apple.mpegurl"),
            segmentExecutor: RecordingSegmentExecutor()
        )
        let candidate = try StreamingManifestCandidate(url: url)

        do {
            _ = try await orchestrator.prepare(candidate: candidate)
            XCTFail("Expected unsupported encryption")
        } catch let error as StreamingDownloadOrchestratorError {
            XCTAssertEqual(error, .unsupportedEncryption)
        }
    }

    func testAES128HLSEncryptionIsPlannedWithKeyAndSegments() async throws {
        let url = URL(string: "https://video.example/index.m3u8")!
        let playlist = """
        #EXTM3U
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXT-X-KEY:METHOD=AES-128,URI="key.bin"
        #EXTINF:2,
        segment.ts
        #EXT-X-ENDLIST
        """
        let orchestrator = StreamingDownloadOrchestrator(
            manifestLoader: RecordingManifestLoader(data: Data(playlist.utf8), finalURL: url, mimeType: "application/vnd.apple.mpegurl"),
            segmentExecutor: RecordingSegmentExecutor()
        )
        let candidate = try StreamingManifestCandidate(url: url)
        let proposal = try await orchestrator.prepare(candidate: candidate)
        XCTAssertEqual(proposal.resources.count, 2)
        XCTAssertEqual(proposal.resources[0].url, URL(string: "https://video.example/key.bin")!)
        XCTAssertEqual(proposal.resources[1].url, URL(string: "https://video.example/segment.ts")!)
    }

    func testInvalidManifestURLRejectedBeforeLoaderRuns() async throws {
        let loader = RecordingManifestLoader(data: Data(), finalURL: URL(string: "https://example.com/file")!, mimeType: nil)
        let executor = RecordingSegmentExecutor()
        let orchestrator = StreamingDownloadOrchestrator(manifestLoader: loader, segmentExecutor: executor)

        XCTAssertThrowsError(try StreamingManifestCandidate(url: URL(string: "file:///tmp/index.m3u8")!)) { error in
            XCTAssertEqual(error as? StreamingDownloadOrchestratorError, .invalidManifestURL)
        }
        let loadCount = await loader.loadCount
        XCTAssertEqual(loadCount, 0)
    }

    func testMasterPlaylistSelectsFiniteVariantAndLoadsItsMediaPlaylist() async throws {
        let masterURL = URL(string: "https://video.example/vod/master.m3u8?sig=master")!
        let variantURL = URL(string: "https://video.example/vod/low/index.m3u8?sig=variant")!
        let master = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=100000,RESOLUTION=640x360
        low/index.m3u8?sig=variant
        #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=1280x720
        high/index.m3u8?sig=high
        """
        let media = """
        #EXTM3U
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXTINF:2,
        part.ts?sig=segment
        #EXT-X-ENDLIST
        """
        let loader = VariantManifestLoader(
            responses: [
                masterURL: StreamingManifestResponse(
                    data: Data(master.utf8),
                    finalURL: masterURL,
                    mimeType: "application/vnd.apple.mpegurl"
                ),
                variantURL: StreamingManifestResponse(
                    data: Data(media.utf8),
                    finalURL: variantURL,
                    mimeType: "application/vnd.apple.mpegurl"
                )
            ]
        )
        let orchestrator = StreamingDownloadOrchestrator(
            manifestLoader: loader,
            segmentExecutor: RecordingSegmentExecutor()
        )
        let candidate = try StreamingManifestCandidate(
            url: masterURL,
            hlsVariantPreferences: HLSVariantSelectionPreferences(maximumWidth: 700)
        )

        let proposal = try await orchestrator.prepare(candidate: candidate)
        XCTAssertEqual(proposal.resources.count, 1)
        XCTAssertEqual(proposal.resources.first?.url.absoluteString, "https://video.example/vod/low/part.ts?sig=segment")
        let loadCount = await loader.loadCount
        XCTAssertEqual(loadCount, 2)
    }

    func testHLSExecutionAssemblesDownloadedResourcesIntoOneOutput() async throws {
        let url = URL(string: "https://video.example/vod/index.m3u8")!
        let playlist = """
        #EXTM3U
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXTINF:2,
        segment.ts
        #EXT-X-ENDLIST
        """
        let orchestrator = StreamingDownloadOrchestrator(
            manifestLoader: RecordingManifestLoader(
                data: Data(playlist.utf8),
                finalURL: url,
                mimeType: "application/vnd.apple.mpegurl"
            ),
            segmentExecutor: WritingSegmentExecutor()
        )
        let candidate = try StreamingManifestCandidate(url: url)
        let proposal = try await orchestrator.prepare(candidate: candidate)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hls-execution-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("assembled.ts")

        let result = try await orchestrator.executeAndAssembleHLS(
            proposal,
            approved: true,
            destinationDirectory: directory,
            outputURL: output
        )

        XCTAssertEqual(result.container, .mpegTS)
        XCTAssertEqual(result.byteCount, 188)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    }

    func testDASHExecutionAssemblesSingleVideoThroughExistingExecutor() async throws {
        let url = URL(string: "https://video.example/vod/manifest.mpd")!
        let mpd = """
        <MPD type="static" mediaPresentationDuration="PT2S">
          <Period duration="PT2S">
            <AdaptationSet contentType="video" mimeType="video/mp4" codecs="avc1">
              <Representation id="v1" bandwidth="1000">
                <SegmentTemplate timescale="1" duration="2" initialization="init.mp4" media="segment-$Number$.m4s"/>
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """
        let orchestrator = StreamingDownloadOrchestrator(
            manifestLoader: RecordingManifestLoader(
                data: Data(mpd.utf8),
                finalURL: url,
                mimeType: "application/dash+xml"
            ),
            segmentExecutor: DASHWritingSegmentExecutor()
        )
        let proposal = try await orchestrator.prepare(candidate: StreamingManifestCandidate(url: url))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dash-execution-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("assembled.mp4")

        let result = try await orchestrator.executeAndAssembleDASH(
            proposal,
            approved: true,
            destinationDirectory: directory,
            outputURL: output
        )

        XCTAssertEqual(result.container, .fragmentedMP4)
        XCTAssertEqual(result.trackCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    }

    func testStreamingDownloadOrchestrator_UsesURLResolverWhenAvailable() async throws {
        final class MockURLResolver: BrowserMediaURLResolver {
            @MainActor
            func resolveMediaURL(_ rawURL: URL) async throws -> URL {
                var comp = URLComponents(url: rawURL, resolvingAgainstBaseURL: false)!
                var items = comp.queryItems ?? []
                items.append(URLQueryItem(name: "resolved", value: "true"))
                comp.queryItems = items
                return comp.url!
            }
        }

        let resolver = MockURLResolver()
        let executor = RecordingSegmentExecutor()
        let manifestData = Data("""
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:5
        #EXTINF:5.0,
        segment-0.ts
        #EXT-X-ENDLIST
        """.utf8)
        let orchestrator = StreamingDownloadOrchestrator(
            manifestLoader: RecordingManifestLoader(
                data: manifestData,
                finalURL: URL(string: "https://example.com/vod.m3u8")!,
                mimeType: "application/vnd.apple.mpegurl"
            ),
            segmentExecutor: executor,
            urlResolver: resolver
        )
        let candidate = try StreamingManifestCandidate(url: URL(string: "https://example.com/vod.m3u8")!)
        let proposal = try await orchestrator.prepare(candidate: candidate)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try await orchestrator.execute(
            proposal,
            approved: true,
            destinationDirectory: dir
        )
        let requests = await executor.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(requests[0].url.absoluteString.contains("resolved=true"))
    }

    @MainActor
    func testStreamingDownloadOrchestrator_SharedInstanceIsInitializedByDefault() {
        XCTAssertNotNil(StreamingDownloadOrchestrator.shared)
    }

    func testStreamingDownloadOrchestrator_RecursiveVariantResolution() async throws {
        let master1URL = URL(string: "https://example.com/master1.m3u8")!
        let master2URL = URL(string: "https://example.com/master2.m3u8")!
        let mediaURL = URL(string: "https://example.com/media.m3u8")!

        let master1Data = Data("""
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=2000000
        master2.m3u8
        """.utf8)

        let master2Data = Data("""
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=3000000
        media.m3u8
        """.utf8)

        let mediaData = Data("""
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:6
        #EXTINF:6.0,
        segment1.ts
        #EXTINF:6.0,
        segment2.ts
        #EXT-X-ENDLIST
        """.utf8)

        let loader = VariantManifestLoader(responses: [
            master1URL: StreamingManifestResponse(data: master1Data, finalURL: master1URL, mimeType: "application/vnd.apple.mpegurl"),
            master2URL: StreamingManifestResponse(data: master2Data, finalURL: master2URL, mimeType: "application/vnd.apple.mpegurl"),
            mediaURL: StreamingManifestResponse(data: mediaData, finalURL: mediaURL, mimeType: "application/vnd.apple.mpegurl")
        ])

        let executor = RecordingSegmentExecutor()
        let orchestrator = StreamingDownloadOrchestrator(
            manifestLoader: loader,
            segmentExecutor: executor
        )

        let candidate = try StreamingManifestCandidate(url: master1URL)
        let proposal = try await orchestrator.prepare(candidate: candidate)

        guard case .hls(let plan) = proposal.manifest else {
            XCTFail("Expected HLS manifest plan")
            return
        }

        XCTAssertEqual(plan.resources.count, 2)
        XCTAssertEqual(plan.manifestURL, mediaURL)
    }

    func testStreamingDownloadOrchestrator_downloadHLSSucceedsWithWritingExecutor() async throws {
        let mediaURL = URL(string: "https://example.com/stream.m3u8")!
        let mediaData = Data("""
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:6
        #EXTINF:6.0,
        segment1.ts
        #EXT-X-ENDLIST
        """.utf8)

        let loader = VariantManifestLoader(responses: [
            mediaURL: StreamingManifestResponse(data: mediaData, finalURL: mediaURL, mimeType: "application/vnd.apple.mpegurl")
        ])
        let executor = WritingSegmentExecutor()
        let orchestrator = StreamingDownloadOrchestrator(
            manifestLoader: loader,
            segmentExecutor: executor
        )

        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let out = dest.appendingPathComponent("stream_output.mp4")
        defer { try? FileManager.default.removeItem(at: dest) }

        let result = try await orchestrator.downloadHLS(
            manifestURL: mediaURL,
            destinationDirectory: dest,
            outputURL: out
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.destinationURL.path))
    }

    func testStreamingDownloadOrchestrator_downloadDASHSucceedsWithWritingExecutor() async throws {
        let url = URL(string: "https://video.example/dash/manifest.mpd")!
        let mpd = """
        <MPD type="static" mediaPresentationDuration="PT2S">
          <Period id="p0" duration="PT2S">
            <AdaptationSet contentType="video" mimeType="video/mp4" codecs="avc1">
              <Representation id="v1" bandwidth="1000">
                <SegmentTemplate timescale="1" duration="2" initialization="init.mp4" media="segment-$Number$.m4s"/>
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """
        let orchestrator = StreamingDownloadOrchestrator(
            manifestLoader: RecordingManifestLoader(
                data: Data(mpd.utf8),
                finalURL: url,
                mimeType: "application/dash+xml"
            ),
            segmentExecutor: DASHWritingSegmentExecutor()
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dash-direct-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("direct_dash_assembled.mp4")

        let result = try await orchestrator.downloadDASH(
            manifestURL: url,
            destinationDirectory: directory,
            outputURL: output
        )

        XCTAssertEqual(result.container, .fragmentedMP4)
        XCTAssertEqual(result.trackCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    }

    func testStreamingDownloadOrchestrator_fallsBackToJSFetchWhenURLSessionFailsWith403() async throws {
        final class JSFallbackURLResolver: BrowserMediaURLResolver {
            let manifestText: String
            init(manifestText: String) { self.manifestText = manifestText }

            @MainActor
            func resolveMediaURL(_ rawURL: URL) async throws -> URL { rawURL }

            @MainActor
            func fetchManifestText(from url: URL) async throws -> String {
                manifestText
            }
        }

        let manifestURL = URL(string: "https://auth.example.com/protected.m3u8")!
        struct Failing403ManifestLoader: StreamingManifestLoader {
            func load(
                candidate: StreamingManifestCandidate,
                headers: [String: String],
                limits: ManifestParsingLimits
            ) async throws -> StreamingManifestResponse {
                throw StreamingManifestLoadError.authenticationRequired
            }
        }

        let fallbackM3U8 = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:4
        #EXTINF:4.0,
        segment-auth.ts
        #EXT-X-ENDLIST
        """

        let resolver = JSFallbackURLResolver(manifestText: fallbackM3U8)
        let orchestrator = StreamingDownloadOrchestrator(
            manifestLoader: Failing403ManifestLoader(),
            segmentExecutor: RecordingSegmentExecutor(),
            urlResolver: resolver
        )

        let candidate = try StreamingManifestCandidate(url: manifestURL)
        let proposal = try await orchestrator.prepare(candidate: candidate)

        XCTAssertEqual(proposal.resources.count, 1)
        XCTAssertEqual(proposal.resources.first?.url.lastPathComponent, "segment-auth.ts")
    }

    func testStreamingDownloadOrchestrator_EnrichedManifestFetch_RejectsNakedRequestWith403_AcceptsEnrichedWith200() async throws {
        let manifestURL = URL(string: "https://auth.example.com/hls/manifest.m3u8?token=xyz123&expires=1999999999")!
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let mockSession = URLSession(configuration: config)
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }

        MockURLProtocol.setHandler(for: manifestURL) { request in
            let cookie = request.value(forHTTPHeaderField: "Cookie")
            let ua = request.value(forHTTPHeaderField: "User-Agent")
            let referer = request.value(forHTTPHeaderField: "Referer")
            // Require session cookie, User-Agent, and Referer headers supplied by DownloadRequestEnricher
            guard let cookie, cookie.contains("session_id=authorized_user_777"),
                  let ua, !ua.isEmpty,
                  let referer, referer.contains("auth.example.com") else {
                let forbiddenResponse = HTTPURLResponse(
                    url: manifestURL,
                    statusCode: 403,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "text/plain"]
                )!
                return (forbiddenResponse, Data("403 Forbidden".utf8))
            }

            let playlist = """
            #EXTM3U
            #EXT-X-VERSION:3
            #EXT-X-TARGETDURATION:4
            #EXT-X-MEDIA-SEQUENCE:0
            #EXTINF:4.0,
            segment0.ts
            #EXT-X-ENDLIST
            """.data(using: .utf8)!
            let successResponse = HTTPURLResponse(
                url: manifestURL,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/vnd.apple.mpegurl"]
            )!
            return (successResponse, playlist)
        }

        let loader = URLSessionStreamingManifestLoader(session: mockSession)
        let orchestrator = StreamingDownloadOrchestrator(
            manifestLoader: loader,
            segmentExecutor: WritingSegmentExecutor()
        )

        // 1. Naked request (missing cookies/headers) -> Must throw authenticationRequired (403)
        let nakedSnapshot = BrowserSessionSnapshot(
            userAgent: "",
            acceptLanguage: "",
            allCookies: [],
            pageURL: nil
        )
        let nakedCandidate = try StreamingManifestCandidate(
            url: manifestURL,
            browserSessionSnapshot: nakedSnapshot
        )

        do {
            _ = try await orchestrator.prepare(candidate: nakedCandidate)
            XCTFail("Expected naked request to be rejected with authenticationRequired (HTTP 403)")
        } catch let error as StreamingManifestLoadError {
            XCTAssertEqual(error, .authenticationRequired)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // 2. Enriched request with session snapshot -> Must succeed with HTTP 200 and return proposal
        let sessionCookie = HTTPCookie(properties: [
            .name: "session_id",
            .value: "authorized_user_777",
            .domain: "auth.example.com",
            .path: "/"
        ])!
        let enrichedSnapshot = BrowserSessionSnapshot(
            userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15",
            acceptLanguage: "en-US",
            allCookies: [sessionCookie],
            pageURL: URL(string: "https://auth.example.com/watch/video1")
        )
        let enrichedCandidate = try StreamingManifestCandidate(
            url: manifestURL,
            browserSessionSnapshot: enrichedSnapshot
        )

        let proposal = try await orchestrator.prepare(candidate: enrichedCandidate)
        XCTAssertEqual(proposal.resources.count, 1)
        XCTAssertTrue(proposal.resources.first?.url.absoluteString.contains("segment0.ts") == true)
    }

    func testStreamingDownloadOrchestrator_PreservesQueryParametersAndTokensAcrossVariants() async throws {
        // 1. DownloadRequestEnricher preserves query parameters on outbound requests
        let signedURL = URL(string: "https://cdn.example.com/live/master.m3u8?token=AUTH_SEC_99&expires=1850000000")!
        let request = URLRequest(url: signedURL)
        let enriched = DownloadRequestEnricher.enrich(request)
        XCTAssertEqual(enriched.url?.query, "token=AUTH_SEC_99&expires=1850000000")

        // 2. Variant resolution in StreamingDownloadOrchestrator inherits parent token
        let masterData = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=1280000,RESOLUTION=1280x720
        variant_720p.m3u8
        """.data(using: .utf8)!

        let subVariantURL = URL(string: "https://cdn.example.com/live/variant_720p.m3u8?token=AUTH_SEC_99&expires=1850000000")!
        let mediaData = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:4
        #EXT-X-MEDIA-SEQUENCE:0
        #EXTINF:4.0,
        chunk0.ts
        #EXT-X-ENDLIST
        """.data(using: .utf8)!

        let loader = VariantManifestLoader(responses: [
            signedURL: StreamingManifestResponse(data: masterData, finalURL: signedURL, mimeType: "application/vnd.apple.mpegurl"),
            subVariantURL: StreamingManifestResponse(data: mediaData, finalURL: subVariantURL, mimeType: "application/vnd.apple.mpegurl")
        ])

        let orchestrator = StreamingDownloadOrchestrator(
            manifestLoader: loader,
            segmentExecutor: RecordingSegmentExecutor()
        )
        let candidate = try StreamingManifestCandidate(url: signedURL)
        let proposal = try await orchestrator.prepare(candidate: candidate)
        XCTAssertEqual(proposal.resources.count, 1)
        let loadedCount = await loader.loadCount
        XCTAssertEqual(loadedCount, 2)
    }
}

private actor RecordingManifestLoader: StreamingManifestLoader {
    private let data: Data
    private let finalURL: URL
    private let mimeType: String?
    private(set) var loadCount = 0

    init(data: Data, finalURL: URL, mimeType: String?) {
        self.data = data
        self.finalURL = finalURL
        self.mimeType = mimeType
    }

    func load(
        candidate: StreamingManifestCandidate,
        headers: [String: String],
        limits: ManifestParsingLimits
    ) async throws -> StreamingManifestResponse {
        loadCount += 1
        return StreamingManifestResponse(data: data, finalURL: finalURL, mimeType: mimeType)
    }
}

private actor RecordingSegmentExecutor: StreamingSegmentExecutor {
    private(set) var requests: [StreamingSegmentTransferRequest] = []

    func execute(
        _ request: StreamingSegmentTransferRequest,
        progress: (@Sendable (Double) -> Void)?
    ) async throws {
        requests.append(request)
        progress?(1)
    }

    func cancel(transferID: String) async {}
}

private actor VariantManifestLoader: StreamingManifestLoader {
    let responses: [URL: StreamingManifestResponse]
    private(set) var loadCount = 0

    init(responses: [URL: StreamingManifestResponse]) {
        self.responses = responses
    }

    func load(
        candidate: StreamingManifestCandidate,
        headers: [String: String],
        limits: ManifestParsingLimits
    ) async throws -> StreamingManifestResponse {
        loadCount += 1
        guard let response = responses[candidate.url] else {
            throw StreamingManifestLoadError.expiredOrMissing
        }
        return response
    }
}

private actor WritingSegmentExecutor: StreamingSegmentExecutor {
    func execute(
        _ request: StreamingSegmentTransferRequest,
        progress: (@Sendable (Double) -> Void)?
    ) async throws {
        try FileManager.default.createDirectory(
            at: request.destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var packet = Data([0x47])
        packet.append(Data(repeating: 0x44, count: 187))
        try packet.write(to: request.destinationURL)
        progress?(1)
    }

    func cancel(transferID: String) async {}
}

private actor DASHWritingSegmentExecutor: StreamingSegmentExecutor {
    func execute(
        _ request: StreamingSegmentTransferRequest,
        progress: (@Sendable (Double) -> Void)?
    ) async throws {
        try FileManager.default.createDirectory(
            at: request.destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let bytes: Data
        if request.url.path.contains("init") {
            bytes = isoBox("ftyp", payload: Data([1])) + isoBox("moov", payload: Data([2]))
        } else {
            bytes = isoBox("moof", payload: Data([3])) + isoBox("mdat", payload: Data([4]))
        }
        try bytes.write(to: request.destinationURL)
        progress?(1)
    }

    func cancel(transferID: String) async {}

    private func isoBox(_ type: String, payload: Data) -> Data {
        let typeBytes = Array(type.utf8)
        let size = UInt32(8 + payload.count)
        var data = Data([
            UInt8((size >> 24) & 0xff),
            UInt8((size >> 16) & 0xff),
            UInt8((size >> 8) & 0xff),
            UInt8(size & 0xff)
        ])
        data.append(contentsOf: typeBytes)
        data.append(payload)
        return data
    }
}
