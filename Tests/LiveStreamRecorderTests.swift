import XCTest
@testable import DM_Reverse_engineering

final class LiveStreamRecorderTests: XCTestCase {

    private var temporaryTestDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let tempBase = FileManager.default.temporaryDirectory
        temporaryTestDirectory = tempBase.appendingPathComponent("LiveStreamRecorderTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryTestDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir = temporaryTestDirectory {
            try? FileManager.default.removeItem(at: dir)
        }
        try super.tearDownWithError()
    }

    // MARK: - 1. Live HLS Manifest Parsing & Sliding Window Discovery

    func testLiveHLSManifestParsingWithTargetDuration() throws {
        let liveM3U8 = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:6
        #EXT-X-MEDIA-SEQUENCE:101
        #EXTINF:6.000,
        segment_101.ts
        #EXTINF:6.000,
        segment_102.ts
        #EXTINF:6.000,
        segment_103.ts
        """

        let baseURL = URL(string: "https://stream.example.com/live/index.m3u8")!
        let manifest = try HLSManifestParser.parse(liveM3U8, baseURL: baseURL)

        XCTAssertEqual(manifest.playlistType, .media)
        XCTAssertEqual(manifest.lifecycle, .live)
        XCTAssertEqual(manifest.targetDuration, 6.0)
        XCTAssertEqual(manifest.segments.count, 3)
        XCTAssertEqual(manifest.segments[0].sequenceNumber, 101)
        XCTAssertEqual(manifest.segments[0].uri, URL(string: "https://stream.example.com/live/segment_101.ts")!)
        XCTAssertEqual(manifest.segments[1].sequenceNumber, 102)
        XCTAssertEqual(manifest.segments[2].sequenceNumber, 103)
    }

    // MARK: - 2. Sliding Window Segment Deduplication

    func testSlidingWindowSegmentDeduplication() throws {
        let poll1 = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:4
        #EXT-X-MEDIA-SEQUENCE:50
        #EXTINF:4.000,
        chunk_50.ts
        #EXTINF:4.000,
        chunk_51.ts
        #EXTINF:4.000,
        chunk_52.ts
        """

        let poll2 = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:4
        #EXT-X-MEDIA-SEQUENCE:52
        #EXTINF:4.000,
        chunk_52.ts
        #EXTINF:4.000,
        chunk_53.ts
        #EXTINF:4.000,
        chunk_54.ts
        """

        let baseURL = URL(string: "https://live.example.com/hls/channel.m3u8")!
        let manifest1 = try HLSManifestParser.parse(poll1, baseURL: baseURL)
        let manifest2 = try HLSManifestParser.parse(poll2, baseURL: baseURL)

        var seenKeys = Set<String>()
        var capturedSegments: [HLSMediaSegment] = []

        // Poll 1
        for seg in manifest1.segments {
            let key = seg.uri.absoluteString
            if !seenKeys.contains(key) {
                seenKeys.insert(key)
                capturedSegments.append(seg)
            }
        }
        XCTAssertEqual(capturedSegments.count, 3)
        XCTAssertEqual(capturedSegments.map { $0.sequenceNumber }, [50, 51, 52])

        // Poll 2 (sliding window advanced: chunk_50 and chunk_51 dropped, chunk_52 repeated, chunk_53 and 54 newly added)
        var newDiscoveredInPoll2: [HLSMediaSegment] = []
        for seg in manifest2.segments {
            let key = seg.uri.absoluteString
            if !seenKeys.contains(key) {
                seenKeys.insert(key)
                capturedSegments.append(seg)
                newDiscoveredInPoll2.append(seg)
            }
        }

        // chunk_52 was skipped because it was already captured!
        XCTAssertEqual(newDiscoveredInPoll2.count, 2)
        XCTAssertEqual(newDiscoveredInPoll2.map { $0.sequenceNumber }, [53, 54])
        XCTAssertEqual(capturedSegments.count, 5)
        XCTAssertEqual(capturedSegments.map { $0.sequenceNumber }, [50, 51, 52, 53, 54])
    }

    // MARK: - 3. Quality Option Live Flag & UI Identification

    func testStreamQualityOptionLiveFlagPropagation() throws {
        let liveMasterM3U8 = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=1280x720
        720p.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=6000000,RESOLUTION=1920x1080
        1080p.m3u8
        """

        let baseURL = URL(string: "https://live.example.com/hls/master.m3u8")!
        let options = try StreamQualityInspector.inspectHLS(manifestText: liveMasterM3U8, baseURL: baseURL)

        XCTAssertEqual(options.count, 2)
        XCTAssertTrue(options[0].isLive, "Live master playlist variants must have isLive=true")
        XCTAssertTrue(options[1].isLive)
    }

    // MARK: - 4. Live Stream Recording State Machine & Finalization

    @MainActor
    func testLiveStreamRecorderStateTransitions() async throws {
        let recorder = LiveStreamRecorder()
        XCTAssertEqual(recorder.state, .idle)

        let destURL = temporaryTestDirectory.appendingPathComponent("live_output.ts")
        let manifestURL = URL(string: "https://live.example.com/stream.m3u8")!

        let req = LiveRecordingRequest(
            manifestURL: manifestURL,
            destinationURL: destURL,
            title: "Test Live Stream",
            temporaryDirectoryURL: temporaryTestDirectory
        )

        try recorder.startRecording(request: req)
        guard case .preparing = recorder.state else {
            XCTFail("Expected preparing state, got: \(recorder.state)")
            return
        }

        // Test cancel
        recorder.cancelRecording()
        XCTAssertEqual(recorder.state, .cancelled)
        XCTAssertNil(recorder.activeRequest)
    }

    // MARK: - 5. Segment Assembly & Packet Concatenation

    func testLiveSegmentOrderedAssembly() throws {
        let destURL = temporaryTestDirectory.appendingPathComponent("assembled_live.ts")
        let seg1URL = temporaryTestDirectory.appendingPathComponent("seg_000000.ts")
        let seg2URL = temporaryTestDirectory.appendingPathComponent("seg_000001.ts")

        // Create synthetic MPEG-TS packets (188 bytes starting with 0x47 sync byte)
        var packet1 = Data([0x47]) + Data(repeating: 0x11, count: 187)
        var packet2 = Data([0x47]) + Data(repeating: 0x22, count: 187)
        try packet1.write(to: seg1URL)
        try packet2.write(to: seg2URL)

        // Concatenate
        FileManager.default.createFile(atPath: destURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destURL)
        handle.write(packet1)
        handle.write(packet2)
        try handle.close()

        let assembledData = try Data(contentsOf: destURL)
        XCTAssertEqual(assembledData.count, 376)
        XCTAssertEqual(assembledData[0], 0x47)
        XCTAssertEqual(assembledData[188], 0x47)
        XCTAssertTrue(LIDPlaybackEngine.validateTSHeader(url: destURL))
    }

    // MARK: - 6. Dynamic DASH Live Stream Inspection

    func testDynamicDASHInspection() throws {
        let dynamicMPD = """
        <?xml version="1.0" encoding="UTF-8"?>
        <MPD xmlns="urn:mpeg:dash:schema:mpd:2011"
             type="dynamic"
             minimumUpdatePeriod="PT2S"
             availabilityStartTime="2026-11-18T00:00:00Z">
            <Period id="p0">
                <AdaptationSet id="v0" contentType="video" mimeType="video/mp4">
                    <Representation id="v_720p" bandwidth="3000000" width="1280" height="720"/>
                </AdaptationSet>
            </Period>
        </MPD>
        """

        let baseURL = URL(string: "https://dash.example.com/live/live.mpd")!
        let inspection = try LIDDASHStreamAdapter.inspect(
            manifestData: Data(dynamicMPD.utf8),
            baseURL: baseURL
        )

        XCTAssertTrue(inspection.isDynamicLive)
        XCTAssertFalse(inspection.hasDRM)
        XCTAssertEqual(inspection.availableRepresentations.count, 1)
        XCTAssertEqual(inspection.availableRepresentations[0].id, "v_720p")
    }

    // MARK: - 7. DRM Rejection in DASH Playback

    func testDRMProtectedDASHStreamRejection() {
        let drmMPD = """
        <?xml version="1.0" encoding="UTF-8"?>
        <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static">
            <Period id="p0">
                <AdaptationSet id="v0" contentType="video">
                    <ContentProtection schemeIdUri="urn:uuid:edef8ba9-79d6-4ace-a3c8-27dcd51d21ed"/>
                    <Representation id="v1" bandwidth="2000000" width="1920" height="1080"/>
                </AdaptationSet>
            </Period>
        </MPD>
        """

        let baseURL = URL(string: "https://drm.example.com/dash/vod.mpd")!
        XCTAssertThrowsError(
            try LIDDASHStreamAdapter.validateForPlayback(manifestData: Data(drmMPD.utf8), baseURL: baseURL)
        ) { error in
            guard case LIDPlaybackError.drmProtectedDASHUnsupported = error else {
                XCTFail("Expected drmProtectedDASHUnsupported, got: \(error)")
                return
            }
        }
    }

    // MARK: - 8. Media Player Backend Routing

    @MainActor
    func testDeterministicBackendRouting() {
        let engine = LIDPlaybackEngine.shared

        // Native formats (MP4, MOV, M4V, MP3, AAC, M4A) should route to AVFoundation
        let mp4Source = LIDPlayerSource.localFile(url: URL(fileURLWithPath: "/tmp/movie.mp4"), title: "Movie")
        let movSource = LIDPlayerSource.localFile(url: URL(fileURLWithPath: "/tmp/clip.mov"), title: "Clip")
        let mp3Source = LIDPlayerSource.localFile(url: URL(fileURLWithPath: "/tmp/song.mp3"), title: "Song")
        let hlsSource = LIDPlayerSource.hlsStream(url: URL(string: "https://example.com/live.m3u8")!, variantPreferences: nil, title: "HLS")
        let torrentSource = LIDPlayerSource.torrentSwarm(infoHash: "0123456789abcdef0123456789abcdef01234567", fileIndex: 0, title: "Torrent")

        XCTAssertEqual(engine.selectBackend(for: mp4Source), .avFoundation)
        XCTAssertEqual(engine.selectBackend(for: movSource), .avFoundation)
        XCTAssertEqual(engine.selectBackend(for: mp3Source), .avFoundation)
        XCTAssertEqual(engine.selectBackend(for: hlsSource), .avFoundation)
        XCTAssertEqual(engine.selectBackend(for: torrentSource), .avFoundation)

        // Native extension detection helper
        XCTAssertTrue(LIDPlaybackEngine.isNativeSupportedExtension("mp4"))
        XCTAssertTrue(LIDPlaybackEngine.isNativeSupportedExtension("mov"))
        XCTAssertTrue(LIDPlaybackEngine.isNativeSupportedExtension("m4a"))
        XCTAssertTrue(LIDPlaybackEngine.isNativeSupportedExtension("mp3"))
        XCTAssertTrue(LIDPlaybackEngine.isNativeSupportedExtension("m3u8"))
        XCTAssertFalse(LIDPlaybackEngine.isNativeSupportedExtension("mkv"))
        XCTAssertFalse(LIDPlaybackEngine.isNativeSupportedExtension("avi"))
        XCTAssertFalse(LIDPlaybackEngine.isNativeSupportedExtension("webm"))
    }

    // MARK: - 9. BitTorrent Sequential Swarm Stream Piece Prioritization

    func testBitTorrentSequentialPieceMapping() {
        // 100 MB file, 1 MB pieces -> 100 pieces
        let mapping = LIDTorrentStreamAdapter.calculatePieceMapping(
            fileOffsetInTorrent: 0,
            fileSize: 100 * 1024 * 1024,
            requestedOffset: 10 * 1024 * 1024,
            requestedLength: 2 * 1024 * 1024,
            pieceLength: 1024 * 1024
        )

        // Requested range is pieces 10 and 11
        XCTAssertEqual(mapping.startPieceIndex, 10)
        XCTAssertEqual(mapping.endPieceIndex, 11)

        // Head moov pieces: first 2 MB (pieces 0 and 1)
        XCTAssertEqual(mapping.headMoovPieceIndices, [0, 1])

        // Tail moov pieces: last 2 MB (pieces 98 and 99)
        XCTAssertEqual(mapping.tailMoovPieceIndices, [98, 99])
        XCTAssertEqual(mapping.totalPiecesCount, 100)
    }

    // MARK: - 10. Audio Track and Subtitle Track Language Preference Matching

    @MainActor
    func testLanguagePreferenceMatching() {
        // English
        XCTAssertTrue(LIDTrackManager.matchesLanguage(languageCode: "en", displayName: "English", preferredLanguage: "English"))
        XCTAssertTrue(LIDTrackManager.matchesLanguage(languageCode: "eng", displayName: "English Audio", preferredLanguage: "English"))

        // Spanish
        XCTAssertTrue(LIDTrackManager.matchesLanguage(languageCode: "es", displayName: "Español", preferredLanguage: "Spanish"))
        XCTAssertFalse(LIDTrackManager.matchesLanguage(languageCode: "en", displayName: "English", preferredLanguage: "Spanish"))

        // Japanese
        XCTAssertTrue(LIDTrackManager.matchesLanguage(languageCode: "ja", displayName: "Japanese (Original)", preferredLanguage: "Japanese"))

        // Any language matches all
        XCTAssertTrue(LIDTrackManager.matchesLanguage(languageCode: "fr", displayName: "French", preferredLanguage: "Any"))
    }
}
