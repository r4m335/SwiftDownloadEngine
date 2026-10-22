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

        do {
            _ = try await orchestrator.prepare(candidate: candidate)
            XCTFail("Expected unsupported encryption")
        } catch let error as StreamingDownloadOrchestratorError {
            XCTAssertEqual(error, .unsupportedEncryption)
        }
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
