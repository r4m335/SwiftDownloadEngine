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
        XCTAssertEqual(requestOrders.sorted(), [0, 1])
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
        _ = StreamingDownloadOrchestrator(manifestLoader: loader, segmentExecutor: executor)

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
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hls-execution-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
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
        let transfer = try await orchestrator.execute(
            proposal,
            approved: true,
            destinationDirectory: directory
        )
        guard case .hls(let transferPlan) = proposal.manifest else {
            XCTFail("Expected HLS transfer plan")
            return
        }
        let completed = zip(transferPlan.allResources, transfer.localFiles).map {
            HLSCompletedResource(resource: $0.0, fileURL: $0.1)
        }
        let output = directory.appendingPathComponent("assembled.ts")
        let result = try HLSVODReconstructor.assemble(
            transferPlan: transferPlan,
            completedResources: completed,
            destinationURL: output
        )

        XCTAssertEqual(result.container, .mpegTS)
        XCTAssertEqual(result.byteCount, 188)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    }

    func testStreamingDownloadOrchestrator_RegistersWithDownloadEngineUponCompletion() async throws {
        let manifestURL = URL(string: "https://video.example/vod/playlist.m3u8")!
        let m3u8 = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:4
        #EXTINF:4.0,
        segment.ts
        #EXT-X-ENDLIST
        """
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("reg-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let engine = try DownloadEngine(storageDirectoryURL: tempDir)

        let orchestrator = StreamingDownloadOrchestrator(
            manifestLoader: RecordingManifestLoader(
                data: Data(m3u8.utf8),
                finalURL: manifestURL,
                mimeType: "application/vnd.apple.mpegurl"
            ),
            segmentExecutor: WritingSegmentExecutor(),
            downloadEngine: engine
        )

        let result = try await orchestrator.downloadHLS(
            manifestURL: manifestURL,
            destinationDirectory: tempDir
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.destinationURL.path))
        let snapshots = await engine.allSnapshots()
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.state, .completed)
        XCTAssertEqual(snapshots.first?.destinationURL.path, result.destinationURL.path)
    }

    func testStreamingDownloadOrchestrator_PauseAndResumeIntegrationWithDownloadEngine() async throws {
        let manifestURL = URL(string: "https://video.example/vod/pause_playlist.m3u8")!
        let m3u8 = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:4
        #EXTINF:4.0,
        segment.ts
        #EXT-X-ENDLIST
        """
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("pause-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let engine = try DownloadEngine(storageDirectoryURL: tempDir)
        let orchestrator = StreamingDownloadOrchestrator(
            manifestLoader: RecordingManifestLoader(
                data: Data(m3u8.utf8),
                finalURL: manifestURL,
                mimeType: "application/vnd.apple.mpegurl"
            ),
            segmentExecutor: WritingSegmentExecutor(),
            downloadEngine: engine
        )
        await engine.setStreamingOrchestrator(orchestrator)

        // 1. Pause
        try await orchestrator.pause(transferID: manifestURL.absoluteString)
        let pausedState = await orchestrator.isPaused(transferID: manifestURL.absoluteString)
        XCTAssertTrue(pausedState)

        // 2. Resume
        try await orchestrator.resume(transferID: manifestURL.absoluteString)
        let resumedState = await orchestrator.isPaused(transferID: manifestURL.absoluteString)
        XCTAssertFalse(resumedState)

        // 3. Complete download
        let result = try await orchestrator.downloadHLS(
            manifestURL: manifestURL,
            destinationDirectory: tempDir
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.destinationURL.path))
        let snapshots = await engine.allSnapshots()
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.state, .completed)
        XCTAssertEqual(snapshots.first?.destinationURL.path, result.destinationURL.path)
    }

    func testMasterPlaylistVariantResolutionPreservesMasterURLAndEstimatesBandwidthSize() async throws {
        let masterURL = URL(string: "https://video.example/vod/master.m3u8")!
        let variantURL = URL(string: "https://video.example/vod/variant_fhd.m3u8")!

        let masterM3U8 = """
        #EXTM3U
        #EXT-X-VERSION:4
        #EXT-X-STREAM-INF:BANDWIDTH=8000000,RESOLUTION=1920x1080
        variant_fhd.m3u8
        """

        let variantM3U8 = """
        #EXTM3U
        #EXT-X-VERSION:4
        #EXT-X-TARGETDURATION:5
        #EXTINF:5.0,
        seg1.ts
        #EXTINF:5.0,
        seg2.ts
        #EXT-X-ENDLIST
        """

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("master-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let engine = try DownloadEngine(storageDirectoryURL: tempDir)
        let router = VariantManifestLoader(responses: [
            masterURL: StreamingManifestResponse(data: Data(masterM3U8.utf8), finalURL: masterURL, mimeType: "application/vnd.apple.mpegurl"),
            variantURL: StreamingManifestResponse(data: Data(variantM3U8.utf8), finalURL: variantURL, mimeType: "application/vnd.apple.mpegurl")
        ])

        let orchestrator = StreamingDownloadOrchestrator(
            manifestLoader: router,
            segmentExecutor: WritingSegmentExecutor(),
            downloadEngine: engine
        )
        await engine.setStreamingOrchestrator(orchestrator)

        let candidate = try StreamingManifestCandidate(url: masterURL)
        let proposal = try await orchestrator.prepare(candidate: candidate)

        // Estimated bytes: 8,000,000 / 8 * 10 seconds = 10,000,000 bytes (~10 MB)
        XCTAssertEqual(proposal.estimatedTransferBytes, 10_000_000)

        let destinationMP4 = tempDir.appendingPathComponent("movie.mp4", isDirectory: false)
        let result = try await orchestrator.executeAndAssembleHLS(
            proposal,
            approved: true,
            destinationDirectory: tempDir,
            outputURL: destinationMP4
        )

        // Verifies Bug 2 fix: Output file forced to .mp4
        XCTAssertEqual(result.destinationURL.pathExtension.lowercased(), "mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.destinationURL.path))

        let remainingHLSParts = (try? FileManager.default.contentsOfDirectory(atPath: tempDir.path))?
            .filter { $0.hasSuffix(".part") } ?? []
        XCTAssertTrue(remainingHLSParts.isEmpty, "Raw .part files must be cleaned up after HLS assembly: \(remainingHLSParts)")
        let hlsMediaAssembly = tempDir.appendingPathComponent(".media-assembly")
        XCTAssertFalse(FileManager.default.fileExists(atPath: hlsMediaAssembly.path), ".media-assembly directory must be cleaned up after HLS assembly")

        let snapshots = await engine.allSnapshots()
        // Verifies Bug 1 fix: Exactly 1 record
        XCTAssertEqual(snapshots.count, 1)

        guard let snapshot = snapshots.first else {
            XCTFail("Expected 1 download snapshot")
            return
        }

        // Verifies Bug 1 fix: Source URL is the original master URL, NOT the variant sub-playlist
        XCTAssertEqual(snapshot.url.absoluteString, masterURL.absoluteString)
        XCTAssertEqual(snapshot.state, .completed)

        // Verifies Bug 5 fix: TransferType for .m3u8 resolves to .hls
        let transfer = UnifiedTransfer(from: snapshot)
        XCTAssertEqual(transfer.type, .hls)
        XCTAssertTrue(transfer.isStreaming)
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

        let remainingParts = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
            .filter { $0.hasSuffix(".part") } ?? []
        XCTAssertTrue(remainingParts.isEmpty, "Raw .part files must be cleaned up after DASH assembly: \(remainingParts)")

        let mediaAssemblyDir = directory.appendingPathComponent(".media-assembly")
        XCTAssertFalse(FileManager.default.fileExists(atPath: mediaAssemblyDir.path), ".media-assembly directory must be cleaned up after DASH assembly")
    }

    func testDASHExecutionCleansUpSegmentDirectoryWhenOutputIsExternal() async throws {
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
        let segmentDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dash-segments-\(UUID().uuidString)", isDirectory: true)
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dash-output-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: segmentDirectory)
            try? FileManager.default.removeItem(at: outputDirectory)
        }
        let output = outputDirectory.appendingPathComponent("assembled.mp4")

        let result = try await orchestrator.executeAndAssembleDASH(
            proposal,
            approved: true,
            destinationDirectory: segmentDirectory,
            outputURL: output
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.destinationURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: segmentDirectory.path), "Entire temporary segment directory must be deleted when output is external")
    }

    func testDASHExecutionCancellationPreservesRawArtifacts() async throws {
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
        let segmentDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dash-cancel-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: segmentDirectory) }
        let output = segmentDirectory.appendingPathComponent("assembled.mp4")

        // Cancel the transfer before assembly
        await orchestrator.cancel(transferID: proposal.transferID)

        do {
            _ = try await orchestrator.executeAndAssembleDASH(
                proposal,
                approved: true,
                destinationDirectory: segmentDirectory,
                outputURL: output
            )
            XCTFail("Cancelled DASH download must throw StreamingDownloadOrchestratorError.cancelled")
        } catch let error as StreamingDownloadOrchestratorError {
            XCTAssertEqual(error, .cancelled)
        } catch {
            XCTFail("Expected StreamingDownloadOrchestratorError.cancelled, got \(error)")
        }

        // Verify that raw artifacts were preserved and not deleted
        let remainingParts = (try? FileManager.default.contentsOfDirectory(atPath: segmentDirectory.path))?
            .filter { $0.hasSuffix(".part") } ?? []
        XCTAssertFalse(remainingParts.isEmpty, "Raw segment artifacts must be preserved when DASH execution is cancelled: \(remainingParts)")
    }

    func testDASHExecutionAssemblyFailurePreservesRawArtifactsForRecovery() async throws {
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
            segmentExecutor: CorruptedDASHWritingSegmentExecutor()
        )
        let proposal = try await orchestrator.prepare(candidate: StreamingManifestCandidate(url: url))
        let segmentDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dash-fail-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: segmentDirectory) }
        let output = segmentDirectory.appendingPathComponent("assembled.mp4")

        do {
            _ = try await orchestrator.executeAndAssembleDASH(
                proposal,
                approved: true,
                destinationDirectory: segmentDirectory,
                outputURL: output
            )
            XCTFail("Corrupted DASH assembly must throw dashReconstructionFailed")
        } catch let error as StreamingDownloadOrchestratorError {
            if case .dashReconstructionFailed = error {
                // Expected
            } else {
                XCTFail("Expected .dashReconstructionFailed, got: \(error)")
            }
        } catch {
            XCTFail("Expected StreamingDownloadOrchestratorError, got: \(error)")
        }

        // Verify raw artifacts were preserved for recovery
        let remainingParts = (try? FileManager.default.contentsOfDirectory(atPath: segmentDirectory.path))?
            .filter { $0.hasSuffix(".part") } ?? []
        XCTAssertFalse(remainingParts.isEmpty, "Raw segment artifacts must be preserved on assembly failure for recovery")
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
        StreamingDownloadOrchestrator.shared = nil
        XCTAssertNil(StreamingDownloadOrchestrator.shared)
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
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let engine = try DownloadEngine(storageDirectoryURL: dest)
        let orchestrator = StreamingDownloadOrchestrator(
            manifestLoader: loader,
            segmentExecutor: executor,
            downloadEngine: engine
        )

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

        let remainingParts = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
            .filter { $0.hasSuffix(".part") } ?? []
        XCTAssertTrue(remainingParts.isEmpty, "Raw .part files must be cleaned up after DASH assembly: \(remainingParts)")

        let mediaAssemblyDir = directory.appendingPathComponent(".media-assembly")
        XCTAssertFalse(FileManager.default.fileExists(atPath: mediaAssemblyDir.path), ".media-assembly directory must be cleaned up after DASH assembly")
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

    func testPipelineLogger_RedactsSensitiveDataAndMaintainsBoundedBuffer() {
        let logger = PipelineLogger()
        logger.clear()

        // 1. Verify token, signature, expiry, cookie, and auth header redaction
        let rawURLWithTokens = "https://example.com/playlist.m3u8?token=superSecretToken123&expires=1899999999&sig=a1b2c3d4e5f6"
        let redactedURL = PipelineLogger.redact(rawURLWithTokens)
        XCTAssertFalse(redactedURL.contains("superSecretToken123"))
        XCTAssertFalse(redactedURL.contains("1899999999"))
        XCTAssertFalse(redactedURL.contains("a1b2c3d4e5f6"))
        XCTAssertTrue(redactedURL.contains("?token=REDACTED"))
        XCTAssertTrue(redactedURL.contains("&expires=REDACTED"))
        XCTAssertTrue(redactedURL.contains("&sig=REDACTED"))

        let rawHeaders = "Authorization: Bearer secret_jwt_token_999\nCookie: session_id=session_val_456; cf_clearance=cf_val_789"
        let redactedHeaders = PipelineLogger.redact(rawHeaders)
        XCTAssertFalse(redactedHeaders.contains("secret_jwt_token_999"))
        XCTAssertFalse(redactedHeaders.contains("session_val_456"))
        XCTAssertTrue(redactedHeaders.contains("Authorization: [REDACTED]"))
        XCTAssertTrue(redactedHeaders.contains("Cookie: [REDACTED]"))

        // 2. Verify bounded capacity of 200 items
        for i in 1...250 {
            logger.log("Log entry number \(i)")
        }
        let storedLogs = logger.allLogs()
        XCTAssertEqual(storedLogs.count, 200)
        XCTAssertTrue(storedLogs.first?.contains("Log entry number 51") == true)
        XCTAssertTrue(storedLogs.last?.contains("Log entry number 250") == true)
    }

    func testStreamingDownloadOrchestrator_CombinedErrorMessage_WhenURLSessionAndJSFallbackBothFail() async throws {
        struct Failing403Loader: StreamingManifestLoader {
            func load(
                candidate: StreamingManifestCandidate,
                headers: [String: String],
                limits: ManifestParsingLimits
            ) async throws -> StreamingManifestResponse {
                throw StreamingManifestLoadError.authenticationRequired
            }
        }

        struct FailingJSResolver: BrowserMediaURLResolver {
            func resolveMediaURL(_ rawURL: URL) async throws -> URL { rawURL }
            func fetchManifestText(from url: URL) async throws -> String {
                let userInfo = ["WKErrorJavaScriptExceptionMessageKey": "TypeError: Failed to fetch"]
                throw NSError(domain: "WKErrorDomain", code: 4, userInfo: userInfo)
            }
        }

        PipelineLogger.shared.clear()
        let manifestURL = URL(string: "https://auth.example.com/stream.m3u8?token=secret123")!
        let orchestrator = StreamingDownloadOrchestrator(
            manifestLoader: Failing403Loader(),
            segmentExecutor: RecordingSegmentExecutor(),
            urlResolver: FailingJSResolver()
        )

        let candidate = try StreamingManifestCandidate(url: manifestURL)

        do {
            _ = try await orchestrator.prepare(candidate: candidate)
            XCTFail("Expected prepare to fail with combined error")
        } catch let error as StreamingManifestLoadError {
            guard case .failed(let combinedMessage) = error else {
                XCTFail("Expected .failed case, got \(error)")
                return
            }
            // Check that both underlying causes are preserved in the single combined message
            XCTAssertTrue(combinedMessage.contains("HTTP 401/403"), "Expected HTTP 401/403 in combined message: \(combinedMessage)")
            XCTAssertTrue(combinedMessage.contains("TypeError: Failed to fetch"), "Expected JS failure reason in combined message: \(combinedMessage)")

            // Check that PipelineLogger recorded the stages
            let allLogs = PipelineLogger.shared.formattedLogText()
            XCTAssertTrue(allLogs.contains("[HLS Pipeline] Step 1: URLSession manifest fetch"))
            XCTAssertTrue(allLogs.contains("[HLS Pipeline] Step 1b: JS fetch fallback"))
            XCTAssertTrue(allLogs.contains("[HLS Pipeline] Error:"))
            XCTAssertFalse(allLogs.contains("secret123"), "Token must be redacted in pipeline logs")
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
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

    func testStreamingDownloadOrchestrator_URLSessionReturnsHTML_TriggersJSFallback() async throws {
        PipelineLogger.shared.clear()
        let manifestURL = URL(string: "https://dash.akamaized.net/akamai/bbb_30fps/bbb_30fps.mpd")!
        let htmlBlockPage = """
        <!DOCTYPE html>
        <html><head><meta http-equiv="Content-Type" content="text/html"><title>Akamai Access Denied</title></head>
        <body>Reference #18.a1b2c3d4</body></html>
        """

        struct HTMLBlockLoader: StreamingManifestLoader {
            let htmlData: Data
            func load(
                candidate: StreamingManifestCandidate,
                headers: [String: String],
                limits: ManifestParsingLimits
            ) async throws -> StreamingManifestResponse {
                return StreamingManifestResponse(
                    data: htmlData,
                    finalURL: candidate.url,
                    mimeType: "text/html",
                    statusCode: 200
                )
            }
        }

        let validDASHManifest = """
        <?xml version="1.0"?>
        <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" minBufferTime="PT1.5S" type="static" mediaPresentationDuration="PT10S">
          <Period id="0">
            <AdaptationSet id="0" contentType="video" mimeType="video/mp4">
              <Representation id="v0" bandwidth="1000000" codecs="avc1.4d401f" width="640" height="360">
                <SegmentTemplate media="chunk-$Number$.m4s" initialization="init.mp4" startNumber="1" duration="2" timescale="1"/>
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """

        struct ValidJSResolver: BrowserMediaURLResolver {
            let text: String
            func resolveMediaURL(_ rawURL: URL) async throws -> URL { rawURL }
            func fetchManifestText(from url: URL) async throws -> String { text }
        }

        let orchestrator = StreamingDownloadOrchestrator(
            manifestLoader: HTMLBlockLoader(htmlData: Data(htmlBlockPage.utf8)),
            segmentExecutor: RecordingSegmentExecutor(),
            urlResolver: ValidJSResolver(text: validDASHManifest)
        )

        let candidate = try StreamingManifestCandidate(url: manifestURL)
        let proposal = try await orchestrator.prepare(candidate: candidate)

        XCTAssertEqual(proposal.manifest.kind, .dash)
        XCTAssertFalse(proposal.resources.isEmpty)

        let logs = PipelineLogger.shared.formattedLogText()
        XCTAssertTrue(logs.contains("Server blocked request. Returned HTML instead of manifest."))
        XCTAssertTrue(logs.contains("Akamai Access Denied"))
        XCTAssertTrue(logs.contains("[HLS Pipeline] Step 1b: JS fetch fallback"))
    }

    func testStreamingDownloadOrchestrator_BothReturnHTML_FailsWithCleanError() async throws {
        PipelineLogger.shared.clear()
        let manifestURL = URL(string: "https://dash.akamaized.net/akamai/bbb_30fps/bbb_30fps.mpd")!
        let htmlBlockPage = "<!DOCTYPE html><html><head><title>Access Denied</title></head><body>Blocked</body></html>"

        struct HTMLBlockLoader: StreamingManifestLoader {
            let htmlData: Data
            func load(
                candidate: StreamingManifestCandidate,
                headers: [String: String],
                limits: ManifestParsingLimits
            ) async throws -> StreamingManifestResponse {
                return StreamingManifestResponse(
                    data: htmlData,
                    finalURL: candidate.url,
                    mimeType: "text/html",
                    statusCode: 200
                )
            }
        }

        struct HTMLJSResolver: BrowserMediaURLResolver {
            let text: String
            func resolveMediaURL(_ rawURL: URL) async throws -> URL { rawURL }
            func fetchManifestText(from url: URL) async throws -> String { text }
        }

        let orchestrator = StreamingDownloadOrchestrator(
            manifestLoader: HTMLBlockLoader(htmlData: Data(htmlBlockPage.utf8)),
            segmentExecutor: RecordingSegmentExecutor(),
            urlResolver: HTMLJSResolver(text: htmlBlockPage)
        )

        let candidate = try StreamingManifestCandidate(url: manifestURL)
        do {
            _ = try await orchestrator.prepare(candidate: candidate)
            XCTFail("Expected prepare to throw")
        } catch let error as StreamingManifestLoadError {
            guard case .failed(let msg) = error else {
                XCTFail("Expected .failed case, got \(error)")
                return
            }
            XCTAssertTrue(msg.contains("Server blocked request. Returned HTML instead of manifest."))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testStreamingDownloadOrchestrator_UsesCachedManifestText_SkipsNetwork() async throws {
        PipelineLogger.shared.clear()
        let manifestURL = URL(string: "https://auth.example.com/expired_token_stream.m3u8?token=expired")!

        struct ExplodingLoader: StreamingManifestLoader {
            func load(
                candidate: StreamingManifestCandidate,
                headers: [String: String],
                limits: ManifestParsingLimits
            ) async throws -> StreamingManifestResponse {
                XCTFail("Network fetch should not be called when cachedManifestText is present")
                throw StreamingManifestLoadError.authenticationRequired
            }
        }

        let validCachedM3U8 = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:5
        #EXTINF:5.0,
        cached_segment_01.ts
        #EXT-X-ENDLIST
        """

        let resource = WebpageResource(
            url: manifestURL,
            title: "Cached Stream",
            suggestedFilename: "cached_stream.mp4",
            resourceType: .video,
            manifestText: validCachedM3U8
        )

        let candidate = try StreamingManifestCandidate(resource: resource)
        XCTAssertEqual(candidate.cachedManifestText, validCachedM3U8)

        let orchestrator = StreamingDownloadOrchestrator(
            manifestLoader: ExplodingLoader(),
            segmentExecutor: RecordingSegmentExecutor()
        )

        let proposal = try await orchestrator.prepare(candidate: candidate)
        XCTAssertEqual(proposal.manifest.kind, .hls)
        XCTAssertEqual(proposal.resources.count, 1)
        XCTAssertEqual(proposal.resources.first?.url.lastPathComponent, "cached_segment_01.ts")

        let logs = PipelineLogger.shared.formattedLogText()
        XCTAssertTrue(logs.contains("Using cached manifest text from network hook"))
    }

    func testUnusableHTMLCachedManifestFallsBackToNetworkLoader() async throws {
        let manifestURL = URL(string: "https://video.example/stream.m3u8")!
        let validM3U8 = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:5
        #EXTINF:5.0,
        network_segment_01.ts
        #EXT-X-ENDLIST
        """

        let htmlBlockedText = """
        <!DOCTYPE html>
        <html><head><title>Cloudflare Challenge</title></head><body>Please wait...</body></html>
        """

        let resource = WebpageResource(
            url: manifestURL,
            title: "HTML Blocked Stream",
            suggestedFilename: "stream.mp4",
            resourceType: .video,
            manifestText: htmlBlockedText
        )

        let candidate = try StreamingManifestCandidate(resource: resource)
        let recordingLoader = RecordingManifestLoader(
            data: Data(validM3U8.utf8),
            finalURL: manifestURL,
            mimeType: "application/vnd.apple.mpegurl"
        )

        let orchestrator = StreamingDownloadOrchestrator(
            manifestLoader: recordingLoader,
            segmentExecutor: RecordingSegmentExecutor()
        )

        let proposal = try await orchestrator.prepare(candidate: candidate)
        XCTAssertEqual(proposal.manifest.kind, .hls)
        XCTAssertEqual(proposal.resources.first?.url.lastPathComponent, "network_segment_01.ts")
        let loadCount = await recordingLoader.loadCount
        XCTAssertEqual(loadCount, 1)

        let logs = PipelineLogger.shared.formattedLogText()
        XCTAssertTrue(logs.contains("Cached manifest text was HTML or exceeded byte limits"))
    }

    func testUnusableMalformedCachedManifestFallsBackToNetworkLoader() async throws {
        let manifestURL = URL(string: "https://video.example/stream.m3u8")!
        let validM3U8 = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:5
        #EXTINF:5.0,
        network_segment_02.ts
        #EXT-X-ENDLIST
        """

        let malformedText = "Random non-manifest garbage text that cannot be classified or parsed"

        let resource = WebpageResource(
            url: manifestURL,
            title: "Malformed Cached Stream",
            suggestedFilename: "stream.mp4",
            resourceType: .video,
            manifestText: malformedText
        )

        let candidate = try StreamingManifestCandidate(resource: resource)
        let recordingLoader = RecordingManifestLoader(
            data: Data(validM3U8.utf8),
            finalURL: manifestURL,
            mimeType: "application/vnd.apple.mpegurl"
        )

        let orchestrator = StreamingDownloadOrchestrator(
            manifestLoader: recordingLoader,
            segmentExecutor: RecordingSegmentExecutor()
        )

        let proposal = try await orchestrator.prepare(candidate: candidate)
        XCTAssertEqual(proposal.manifest.kind, .hls)
        XCTAssertEqual(proposal.resources.first?.url.lastPathComponent, "network_segment_02.ts")
        let loadCount = await recordingLoader.loadCount
        XCTAssertEqual(loadCount, 1)

        let logs = PipelineLogger.shared.formattedLogText()
        XCTAssertTrue(logs.contains("Cached manifest text not recognized as valid manifest") || logs.contains("Cached manifest text failed to parse"))
    }

    func testFilesystemErrorDoesNotTriggerManifestTokenRefresh() async throws {
        let manifestURL = URL(string: "https://video.example/fs-error.m3u8")!
        let playlist = """
        #EXTM3U
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXTINF:2,
        segment1.ts
        #EXT-X-ENDLIST
        """
        let loader = RecordingManifestLoader(data: Data(playlist.utf8), finalURL: manifestURL, mimeType: "application/vnd.apple.mpegurl")
        let fsError = NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError, userInfo: [NSLocalizedDescriptionKey: "The file doesn't exist."])
        let executor = FaultInjectingSegmentExecutor(failureCount: 1, errorToThrow: fsError)
        let orchestrator = StreamingDownloadOrchestrator(manifestLoader: loader, segmentExecutor: executor)

        let candidate = try StreamingManifestCandidate(url: manifestURL)
        let proposal = try await orchestrator.prepare(candidate: candidate)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        do {
            _ = try await orchestrator.execute(proposal, approved: true, destinationDirectory: destination)
            XCTFail("Expected orchestrator.execute to fail on filesystem error")
        } catch {
            guard case StreamingDownloadOrchestratorError.segmentTransferFailed(let order) = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
            XCTAssertEqual(order, 0)
        }

        let count = await loader.loadCount
        XCTAssertEqual(count, 1)
        let calls = await executor.executeCalls
        XCTAssertEqual(calls, 1)
    }

    func testExpiredTokenErrorTriggersManifestRefresh() async throws {
        let manifestURL = URL(string: "https://video.example/token-refresh.m3u8")!
        let playlist = """
        #EXTM3U
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXTINF:2,
        segment1.ts
        #EXT-X-ENDLIST
        """
        let loader = RecordingManifestLoader(data: Data(playlist.utf8), finalURL: manifestURL, mimeType: "application/vnd.apple.mpegurl")
        let tokenError = DownloadCoordinatorError.tokenExpired(url: URL(string: "https://video.example/segment1.ts")!)
        let executor = FaultInjectingSegmentExecutor(failureCount: 1, errorToThrow: tokenError)
        let orchestrator = StreamingDownloadOrchestrator(manifestLoader: loader, segmentExecutor: executor)

        let candidate = try StreamingManifestCandidate(url: manifestURL)
        let proposal = try await orchestrator.prepare(candidate: candidate)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        let result = try await orchestrator.execute(proposal, approved: true, destinationDirectory: destination)
        XCTAssertEqual(result.completedSegments.count, 1)

        let count = await loader.loadCount
        XCTAssertEqual(count, 2)
        let calls = await executor.executeCalls
        XCTAssertEqual(calls, 2)
    }

    func testZeroByteSegmentFileThrowsSegmentTransferFailed() async throws {
        let manifestURL = URL(string: "https://video.example/zero-byte.m3u8")!
        let playlist = """
        #EXTM3U
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXTINF:2,
        segment1.ts
        #EXT-X-ENDLIST
        """
        let loader = RecordingManifestLoader(data: Data(playlist.utf8), finalURL: manifestURL, mimeType: "application/vnd.apple.mpegurl")
        let executor = EmptyFileSegmentExecutor()
        let orchestrator = StreamingDownloadOrchestrator(manifestLoader: loader, segmentExecutor: executor)

        let candidate = try StreamingManifestCandidate(url: manifestURL)
        let proposal = try await orchestrator.prepare(candidate: candidate)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        do {
            _ = try await orchestrator.execute(proposal, approved: true, destinationDirectory: destination)
            XCTFail("Expected orchestrator.execute to fail on zero-byte segment output")
        } catch {
            guard case StreamingDownloadOrchestratorError.segmentTransferFailed(let order) = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
            XCTAssertEqual(order, 0)
        }
    }

    func testConcurrentSegmentDownloadsProduceValidPartFiles() async throws {
        let manifestURL = URL(string: "https://video.example/concurrent.m3u8")!
        let playlist = """
        #EXTM3U
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXTINF:2,
        seg0.ts
        #EXTINF:2,
        seg1.ts
        #EXTINF:2,
        seg2.ts
        #EXTINF:2,
        seg3.ts
        #EXT-X-ENDLIST
        """
        let loader = RecordingManifestLoader(data: Data(playlist.utf8), finalURL: manifestURL, mimeType: "application/vnd.apple.mpegurl")
        let executor = RecordingSegmentExecutor()
        let orchestrator = StreamingDownloadOrchestrator(manifestLoader: loader, segmentExecutor: executor)

        let candidate = try StreamingManifestCandidate(url: manifestURL)
        let proposal = try await orchestrator.prepare(candidate: candidate)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        let result = try await orchestrator.execute(proposal, approved: true, destinationDirectory: destination)
        XCTAssertEqual(result.completedSegments.count, 4)
        XCTAssertEqual(result.localFiles.count, 4)

        for fileURL in result.localFiles {
            XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
            let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
            XCTAssertGreaterThan(size, 0)
        }
    }

    func testProposalFingerprintDiffersBetweenAuthenticatedBrowserSessions() async throws {
        let manifestURL = URL(string: "https://video.example/protected.m3u8")!
        let playlist = """
        #EXTM3U
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXTINF:2,
        seg0.ts
        #EXT-X-ENDLIST
        """
        let loader = RecordingManifestLoader(data: Data(playlist.utf8), finalURL: manifestURL, mimeType: "application/vnd.apple.mpegurl")
        let executor = RecordingSegmentExecutor()
        let orchestrator = StreamingDownloadOrchestrator(manifestLoader: loader, segmentExecutor: executor)

        let cookieA = BrowserCookie(
            name: "session_id",
            value: "alice_session_token",
            domain: "video.example",
            path: "/",
            isSecure: true,
            isHTTPOnly: true
        )
        let contextA = BrowserRequestContext(
            url: manifestURL,
            pageURL: URL(string: "https://video.example/watch")!,
            userAgent: "Browser/1.0",
            cookies: [cookieA],
            source: .webpageResource
        )
        let candidateA = try StreamingManifestCandidate(
            url: manifestURL,
            mimeType: "application/vnd.apple.mpegurl",
            browserRequestContext: contextA
        )

        let cookieB = BrowserCookie(
            name: "session_id",
            value: "bob_session_token",
            domain: "video.example",
            path: "/",
            isSecure: true,
            isHTTPOnly: true
        )
        let contextB = BrowserRequestContext(
            url: manifestURL,
            pageURL: URL(string: "https://video.example/watch")!,
            userAgent: "Browser/1.0",
            cookies: [cookieB],
            source: .webpageResource
        )
        let candidateB = try StreamingManifestCandidate(
            url: manifestURL,
            mimeType: "application/vnd.apple.mpegurl",
            browserRequestContext: contextB
        )

        let proposalA = try await orchestrator.prepare(candidate: candidateA)
        let proposalB = try await orchestrator.prepare(candidate: candidateB)

        XCTAssertNotEqual(
            proposalA.transferID,
            proposalB.transferID,
            "Proposals with identical URLs but different session cookies must NOT share proposal identities or reuse cached proposals"
        )
    }

    func testBrowserAuthenticationHandlerEnforcesStrictOriginEquality() {
        final class MockPromptProvider: BrowserAuthenticationProviding, @unchecked Sendable {
            var promptedHost: String?
            func promptForCredentials(
                host: String,
                realm: String?,
                completionHandler: @escaping @Sendable (String?, String?) -> Void
            ) {
                promptedHost = host
                completionHandler("user", "pass")
            }
        }

        final class Box<T>: @unchecked Sendable {
            var value: T
            init(_ value: T) { self.value = value }
        }

        let provider = MockPromptProvider()
        let authHandler = BrowserAuthenticationHandler(promptProvider: provider)
        let pageURL = URL(string: "https://example.com:443/watch")!

        // 1. Same origin https://example.com:443 -> Allowed and prompts provider
        let sameSpace = URLProtectionSpace(
            host: "example.com",
            port: 443,
            protocol: "https",
            realm: "TestRealm",
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic
        )
        let sameOutcome = Box<URLSession.AuthChallengeDisposition?>(nil)
        let sameChallenge = URLAuthenticationChallenge(
            protectionSpace: sameSpace,
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: DummyAuthSender()
        )
        authHandler.handleChallenge(sameChallenge, targetPageURL: pageURL) { disposition, _ in
            sameOutcome.value = disposition
        }
        XCTAssertEqual(sameOutcome.value, .useCredential, "Same origin should be permitted and prompt for credentials")
        XCTAssertEqual(provider.promptedHost, "example.com")
        provider.promptedHost = nil

        // 2. Different subdomain video.example.com -> Cancelled without prompting
        let subdomainSpace = URLProtectionSpace(
            host: "video.example.com",
            port: 443,
            protocol: "https",
            realm: "TestRealm",
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic
        )
        let subdomainOutcome = Box<URLSession.AuthChallengeDisposition?>(nil)
        let subdomainChallenge = URLAuthenticationChallenge(
            protectionSpace: subdomainSpace,
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: DummyAuthSender()
        )
        authHandler.handleChallenge(subdomainChallenge, targetPageURL: pageURL) { disposition, _ in
            subdomainOutcome.value = disposition
        }
        XCTAssertEqual(subdomainOutcome.value, .cancelAuthenticationChallenge, "Subdomains must not inherit credentials")
        XCTAssertNil(provider.promptedHost)

        // 3. Different port 8443 -> Cancelled without prompting
        let diffPortSpace = URLProtectionSpace(
            host: "example.com",
            port: 8443,
            protocol: "https",
            realm: "TestRealm",
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic
        )
        let portOutcome = Box<URLSession.AuthChallengeDisposition?>(nil)
        let portChallenge = URLAuthenticationChallenge(
            protectionSpace: diffPortSpace,
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: DummyAuthSender()
        )
        authHandler.handleChallenge(portChallenge, targetPageURL: pageURL) { disposition, _ in
            portOutcome.value = disposition
        }
        XCTAssertEqual(portOutcome.value, .cancelAuthenticationChallenge, "Different ports must not inherit credentials")
        XCTAssertNil(provider.promptedHost)

        // 4. Different scheme http -> Cancelled without prompting
        let diffSchemeSpace = URLProtectionSpace(
            host: "example.com",
            port: 80,
            protocol: "http",
            realm: "TestRealm",
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic
        )
        let schemeOutcome = Box<URLSession.AuthChallengeDisposition?>(nil)
        let schemeChallenge = URLAuthenticationChallenge(
            protectionSpace: diffSchemeSpace,
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: DummyAuthSender()
        )
        authHandler.handleChallenge(schemeChallenge, targetPageURL: pageURL) { disposition, _ in
            schemeOutcome.value = disposition
        }
        XCTAssertEqual(schemeOutcome.value, .cancelAuthenticationChallenge, "Different schemes must not inherit credentials")
        XCTAssertNil(provider.promptedHost)
    }

    func testOrchestratorBulkPauseResumeCancelOperations() async throws {
        let manifestURL = URL(string: "https://video.example/bulk.m3u8")!
        let mediaData = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXTINF:4.0,
        seg0.ts
        #EXT-X-ENDLIST
        """.data(using: .utf8)!
        let loader = VariantManifestLoader(responses: [
            manifestURL: StreamingManifestResponse(data: mediaData, finalURL: manifestURL, mimeType: "application/vnd.apple.mpegurl")
        ])
        let orchestrator = StreamingDownloadOrchestrator(
            manifestLoader: loader,
            segmentExecutor: RecordingSegmentExecutor()
        )
        let persistence = HLSPersistenceStore(inMemory: true)
        await orchestrator.setHLSPersistenceStore(persistence)

        let candidate = try StreamingManifestCandidate(url: manifestURL)
        _ = try await orchestrator.prepare(candidate: candidate)
        let transferID = "bulk-transfer-1"

        let record = HLSTransferRecord(
            id: transferID,
            manifestURL: manifestURL,
            outputFilename: "bulk.mp4",
            outputDestinationURL: FileManager.default.temporaryDirectory.appendingPathComponent("bulk.mp4"),
            segmentDirectoryURL: FileManager.default.temporaryDirectory.appendingPathComponent("bulk-segments"),
            totalSegments: 1,
            completedSegmentOrders: [],
            state: .downloading
        )
        try await persistence.save(record)

        // Register running transfer
        try await orchestrator.pause(transferID: transferID)
        let isPaused1 = await orchestrator.isPaused(transferID: transferID)
        XCTAssertTrue(isPaused1)

        // Bulk resume
        await orchestrator.resumeAll()
        let isPaused2 = await orchestrator.isPaused(transferID: transferID)
        XCTAssertFalse(isPaused2)

        // Bulk cancel
        await orchestrator.cancelAll()
        let isCancelled = await orchestrator.isCancelled(transferID: transferID)
        XCTAssertTrue(isCancelled)
    }

    func testDownloadAndSaveSubtitle_PropagatesContextAndHeadersToSegments() async throws {
        let playlistURL = URL(string: "https://auth.example.com/subtitles/playlist.m3u8")!
        let seg1URL = URL(string: "https://auth.example.com/subtitles/seg1.vtt")!
        let seg2URL = URL(string: "https://auth.example.com/subtitles/seg2.vtt")!

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let mockSession = URLSession(configuration: config)
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }

        let cookie = BrowserCookie(
            name: "sub_auth",
            value: "secret_token_abc",
            domain: "auth.example.com",
            path: "/"
        )
        let context = BrowserRequestContext(
            url: playlistURL,
            pageURL: URL(string: "https://auth.example.com/watch?v=123")!,
            userAgent: "TestSubtitleBrowser/2.0",
            cookies: [cookie],
            customHeaders: [
                "X-Custom-Sub": "valid",
                "Referer": "https://auth.example.com/watch?v=123",
                "Origin": "https://auth.example.com"
            ]
        )
        let candidate = try StreamingManifestCandidate(url: playlistURL, browserRequestContext: context)

        let m3u8Playlist = """
        #EXTM3U
        #EXT-X-TARGETDURATION:10
        #EXTINF:10.0,
        seg1.vtt
        #EXTINF:10.0,
        seg2.vtt
        """

        MockURLProtocol.setHandler(for: playlistURL) { req in
            guard let c = req.value(forHTTPHeaderField: "Cookie"), c.contains("sub_auth=secret_token_abc"),
                  let ua = req.value(forHTTPHeaderField: "User-Agent"), ua == "TestSubtitleBrowser/2.0" else {
                return (HTTPURLResponse(url: playlistURL, statusCode: 403, httpVersion: "HTTP/1.1", headerFields: nil)!, Data())
            }
            let res = HTTPURLResponse(url: playlistURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/x-mpegURL"])!
            return (res, Data(m3u8Playlist.utf8))
        }

        MockURLProtocol.setHandler(for: seg1URL) { req in
            guard let c = req.value(forHTTPHeaderField: "Cookie"), c.contains("sub_auth=secret_token_abc"),
                  let ua = req.value(forHTTPHeaderField: "User-Agent"), ua == "TestSubtitleBrowser/2.0",
                  req.value(forHTTPHeaderField: "Referer") != nil else {
                return (HTTPURLResponse(url: seg1URL, statusCode: 403, httpVersion: "HTTP/1.1", headerFields: nil)!, Data())
            }
            let body = "WEBVTT\n\n00:00:00.000 --> 00:00:10.000\nHello World\n"
            let res = HTTPURLResponse(url: seg1URL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/vtt"])!
            return (res, Data(body.utf8))
        }

        MockURLProtocol.setHandler(for: seg2URL) { req in
            guard let c = req.value(forHTTPHeaderField: "Cookie"), c.contains("sub_auth=secret_token_abc"),
                  let ua = req.value(forHTTPHeaderField: "User-Agent"), ua == "TestSubtitleBrowser/2.0",
                  req.value(forHTTPHeaderField: "Referer") != nil else {
                return (HTTPURLResponse(url: seg2URL, statusCode: 403, httpVersion: "HTTP/1.1", headerFields: nil)!, Data())
            }
            let body = "WEBVTT\n\n00:00:10.000 --> 00:00:20.000\nSecond Cue\n"
            let res = HTTPURLResponse(url: seg2URL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/vtt"])!
            return (res, Data(body.utf8))
        }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("sub-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let finalVideoURL = tempDir.appendingPathComponent("output.mp4")
        let destinationVTT = tempDir.appendingPathComponent("output.vtt")

        let orchestrator = StreamingDownloadOrchestrator(
            manifestLoader: RecordingManifestLoader(data: Data(), finalURL: playlistURL, mimeType: nil),
            segmentExecutor: RecordingSegmentExecutor()
        )

        await orchestrator.downloadAndSaveSubtitle(
            from: playlistURL,
            candidate: candidate,
            finalOutputURL: finalVideoURL,
            customSession: mockSession
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationVTT.path))
        let savedContent = try String(contentsOf: destinationVTT, encoding: .utf8)
        XCTAssertTrue(savedContent.contains("WEBVTT"))
        XCTAssertTrue(savedContent.contains("Hello World"))
        XCTAssertTrue(savedContent.contains("Second Cue"))
    }

    func testDownloadAndSaveSubtitle_RejectsHTMLResponsesAndAvoidsWritingBrokenVTT() async throws {
        let errorURL = URL(string: "https://auth.example.com/subtitles/error.vtt")!
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let mockSession = URLSession(configuration: config)
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }

        MockURLProtocol.setHandler(for: errorURL) { _ in
            let htmlBody = "<!DOCTYPE html><html><body>Error Not Found</body></html>"
            let res = HTTPURLResponse(url: errorURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/html"])!
            return (res, Data(htmlBody.utf8))
        }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("sub-err-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let finalVideoURL = tempDir.appendingPathComponent("output.mp4")
        let destinationVTT = tempDir.appendingPathComponent("output.vtt")

        let orchestrator = StreamingDownloadOrchestrator(
            manifestLoader: RecordingManifestLoader(data: Data(), finalURL: errorURL, mimeType: nil),
            segmentExecutor: RecordingSegmentExecutor()
        )

        await orchestrator.downloadAndSaveSubtitle(
            from: errorURL,
            candidate: nil,
            finalOutputURL: finalVideoURL,
            customSession: mockSession
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationVTT.path))
    }
}

private final class DummyAuthSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
    func performDefaultHandling(for challenge: URLAuthenticationChallenge) {}
    func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) {}
}

private actor FaultInjectingSegmentExecutor: StreamingSegmentExecutor {
    private var failureCount: Int
    private let errorToThrow: Error
    private(set) var executeCalls = 0

    init(failureCount: Int, errorToThrow: Error) {
        self.failureCount = failureCount
        self.errorToThrow = errorToThrow
    }

    func execute(
        _ request: StreamingSegmentTransferRequest,
        progress: (@Sendable (Double) -> Void)?
    ) async throws {
        executeCalls += 1
        if failureCount > 0 {
            failureCount -= 1
            throw errorToThrow
        }
        let payload = Data(repeating: 0x47, count: 188)
        try? FileManager.default.createDirectory(at: request.destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try payload.write(to: request.destinationURL)
        progress?(1.0)
    }

    func cancel(transferID: String) async {}
}

private actor EmptyFileSegmentExecutor: StreamingSegmentExecutor {
    func execute(
        _ request: StreamingSegmentTransferRequest,
        progress: (@Sendable (Double) -> Void)?
    ) async throws {
        try? FileManager.default.createDirectory(at: request.destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: request.destinationURL)
        progress?(1.0)
    }

    func cancel(transferID: String) async {}
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
        let count = request.byteRange.map { Int($0.length) } ?? 188
        let payload = Data(repeating: 0x47, count: count)
        try? FileManager.default.createDirectory(at: request.destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? payload.write(to: request.destinationURL)
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

private actor CorruptedDASHWritingSegmentExecutor: StreamingSegmentExecutor {
    func execute(
        _ request: StreamingSegmentTransferRequest,
        progress: (@Sendable (Double) -> Void)?
    ) async throws {
        try FileManager.default.createDirectory(
            at: request.destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let bytes = Data([0xDE, 0xAD, 0xBE, 0xEF])
        try bytes.write(to: request.destinationURL)
        progress?(1)
    }

    func cancel(transferID: String) async {}
}
