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
