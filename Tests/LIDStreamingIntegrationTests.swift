import XCTest
@testable import DownloadEngineKit

final class LIDStreamingIntegrationTests: XCTestCase {

    // MARK: - 1. HLS Variant Selection & Exact URI Preservation

    func testHLSVariantSelectionAndExactURIPreservation() throws {
        let masterM3U8 = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-STREAM-INF:BANDWIDTH=1280000,RESOLUTION=640x360
        http://example.com/360p.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2560000,RESOLUTION=960x540
        http://example.com/540p.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1280x720
        http://example.com/720p.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=8000000,RESOLUTION=1920x1080
        http://example.com/1080p.m3u8
        """

        let masterURL = URL(string: "http://example.com/master.m3u8")!
        let manifest = try HLSManifestParser.parse(masterM3U8, baseURL: masterURL)
        XCTAssertEqual(manifest.variants.count, 4)

        // Select exact 720p variant
        let exact720pURL = URL(string: "http://example.com/720p.m3u8")!
        let prefs = HLSVariantSelectionPreferences(exactURI: exact720pURL)
        let selected = try HLSVariantSelector.select(from: manifest, preferences: prefs)
        XCTAssertEqual(selected.uri, exact720pURL)
        XCTAssertEqual(selected.resolution?.height, 720)

        // Ensure LIDPlayerSource preserves exact variant URI in url and mediaIdentifier
        let hlsSource = LIDPlayerSource.hlsStream(
            url: masterURL,
            variantPreferences: prefs,
            title: "Tears of Steel (720p)"
        )
        XCTAssertEqual(hlsSource.url, exact720pURL)
        XCTAssertEqual(hlsSource.mediaIdentifier, exact720pURL.absoluteString)
        XCTAssertEqual(hlsSource.title, "Tears of Steel (720p)")
        XCTAssertTrue(hlsSource.isStreaming)
    }

    // MARK: - 2. HLS Request Header & BrowserRequestContext Integration

    func testHLSRequestContextHeaderPropagation() {
        let manifestURL = URL(string: "https://media.example.com/stream/index.m3u8")!
        let pageURL = URL(string: "https://media.example.com/watch?v=123")!

        let cookie = BrowserCookie(
            name: "SessionAuth",
            value: "secretToken12345",
            domain: "media.example.com",
            path: "/"
        )

        let context = BrowserRequestContext(
            url: manifestURL,
            pageURL: pageURL,
            userAgent: "LIDPlayer/2.0 (iOS)",
            cookies: [cookie],
            customHeaders: ["X-Custom-Client": "LID-Mobile"]
        )

        let headers = context.effectiveHeaders(for: manifestURL)
        XCTAssertEqual(headers["User-Agent"], "LIDPlayer/2.0 (iOS)")
        XCTAssertEqual(headers["Referer"], "https://media.example.com/watch?v=123")
        XCTAssertEqual(headers["X-Custom-Client"], "LID-Mobile")
        XCTAssertTrue(headers["Cookie"]?.contains("SessionAuth=secretToken12345") == true)

        let source = LIDPlayerSource.hlsStream(
            url: manifestURL,
            variantPreferences: nil,
            title: "Authenticated Stream",
            requestContext: context
        )
        XCTAssertEqual(source.requestContext, context)
        XCTAssertEqual(source.mediaIdentifier, manifestURL.absoluteString)
    }

    // MARK: - 3. DASH Manifest Parsing & Representation Selection

    func testClearDASHManifestParsingAndRepresentationSelection() throws {
        let mpdXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <MPD xmlns="urn:mpeg:dash:schema:mpd:2011"
             type="static"
             mediaPresentationDuration="PT180.0S"
             minBufferTime="PT2.0S">
            <Period id="period-0">
                <AdaptationSet id="video-set" contentType="video" mimeType="video/mp4">
                    <Representation id="vid-720p" bandwidth="2500000" width="1280" height="720" codecs="avc1.64001f">
                        <SegmentTemplate timescale="1000" duration="2000" media="segment_$Number$.m4s" initialization="init.mp4"/>
                    </Representation>
                    <Representation id="vid-1080p" bandwidth="5000000" width="1920" height="1080" codecs="avc1.640028">
                        <SegmentTemplate timescale="1000" duration="2000" media="segment_$Number$.m4s" initialization="init.mp4"/>
                    </Representation>
                </AdaptationSet>
            </Period>
        </MPD>
        """

        let baseURL = URL(string: "https://dash.example.com/vod/stream.mpd")!
        let inspection = try LIDDASHStreamAdapter.inspect(
            manifestData: Data(mpdXML.utf8),
            baseURL: baseURL,
            preferredRepresentationID: "vid-1080p"
        )

        XCTAssertFalse(inspection.hasDRM)
        XCTAssertNil(inspection.drmDetails)
        XCTAssertFalse(inspection.isDynamicLive)
        XCTAssertEqual(inspection.durationSeconds, 180.0)
        XCTAssertEqual(inspection.availableRepresentations.count, 2)
        XCTAssertEqual(inspection.selectedRepresentation?.id, "vid-1080p")
        XCTAssertEqual(inspection.selectedRepresentation?.bandwidth, 5000000)
        XCTAssertEqual(inspection.selectedRepresentation?.width, 1920)

        // Check playback validation succeeds for clear media
        let validated = try LIDDASHStreamAdapter.validateForPlayback(
            manifestData: Data(mpdXML.utf8),
            baseURL: baseURL,
            preferredRepresentationID: "vid-720p"
        )
        XCTAssertEqual(validated.selectedRepresentation?.id, "vid-720p")
    }

    // MARK: - 4. DASH DRM Detection & Error Reporting

    func testDASHWidevineDRMDetectionTriggersUnsupportedError() throws {
        let drmMPDXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <MPD xmlns="urn:mpeg:dash:schema:mpd:2011"
             type="static"
             mediaPresentationDuration="PT3600S"
             minBufferTime="PT4.0S">
            <Period id="p0">
                <AdaptationSet id="protected-video" contentType="video" mimeType="video/mp4">
                    <ContentProtection schemeIdUri="urn:uuid:edef8ba9-79d6-4ace-a3c8-27dcd51d21ed"/>
                    <Representation id="rep-1" bandwidth="3000000" width="1280" height="720">
                        <SegmentTemplate timescale="1" duration="4" media="chunk_$Number$.m4s"/>
                    </Representation>
                </AdaptationSet>
            </Period>
        </MPD>
        """

        let baseURL = URL(string: "https://secure.example.com/drm/manifest.mpd")!
        let inspection = try LIDDASHStreamAdapter.inspect(manifestData: Data(drmMPDXML.utf8), baseURL: baseURL)
        XCTAssertTrue(inspection.hasDRM)
        XCTAssertNotNil(inspection.drmDetails)

        // validateForPlayback must fail with actionable DRM error
        XCTAssertThrowsError(
            try LIDDASHStreamAdapter.validateForPlayback(manifestData: Data(drmMPDXML.utf8), baseURL: baseURL)
        ) { error in
            guard let playbackError = error as? LIDPlaybackError else {
                XCTFail("Expected LIDPlaybackError, got \(error)")
                return
            }
            if case .drmProtectedDASHUnsupported(let details) = playbackError {
                XCTAssertTrue(details.contains("ContentProtection"), "Error details should mention ContentProtection")
            } else {
                XCTFail("Expected drmProtectedDASHUnsupported case, got \(playbackError)")
            }
            XCTAssertTrue(playbackError.localizedDescription.contains("Widevine/PlayReady"))
        }
    }

    // MARK: - 5. BitTorrent Sequential Swarm Piece Mapping & Moov Atom Prioritization

    func testBitTorrentPieceMappingAndMoovAtomPrioritization() {
        // 50 MB MP4 file, 1 MB piece length, single file at offset 0
        let fileSize: Int64 = 50 * 1024 * 1024
        let pieceLength: Int = 1024 * 1024 // 1 MB
        let requestedOffset: Int64 = 10 * 1024 * 1024 // 10 MB seek target
        let requestedLength: Int = 2 * 1024 * 1024 // 2 MB

        let mapping = LIDTorrentStreamAdapter.calculatePieceMapping(
            fileOffsetInTorrent: 0,
            fileSize: fileSize,
            requestedOffset: requestedOffset,
            requestedLength: requestedLength,
            pieceLength: pieceLength
        )

        // Pieces covering 10MB to 12MB
        XCTAssertEqual(mapping.startPieceIndex, 10)
        XCTAssertEqual(mapping.endPieceIndex, 11)
        XCTAssertEqual(mapping.totalPiecesCount, 50)

        // Head moov pieces: first 2 MB (pieces 0, 1)
        XCTAssertEqual(mapping.headMoovPieceIndices, [0, 1])

        // Tail moov pieces: last 2 MB (pieces 48, 49)
        XCTAssertEqual(mapping.tailMoovPieceIndices, [48, 49])
    }

    func testBitTorrentPieceMappingMultiFileOffset() {
        // File 2 in a multi-file torrent, preceded by 100 MB of prior files
        let priorFilesOffset: Int64 = 100 * 1024 * 1024
        let fileSize: Int64 = 20 * 1024 * 1024
        let pieceLength: Int = 2 * 1024 * 1024 // 2 MB pieces

        let mapping = LIDTorrentStreamAdapter.calculatePieceMapping(
            fileOffsetInTorrent: priorFilesOffset,
            fileSize: fileSize,
            requestedOffset: 0,
            requestedLength: 4 * 1024 * 1024,
            pieceLength: pieceLength
        )

        // 100 MB / 2 MB = piece 50
        XCTAssertEqual(mapping.startPieceIndex, 50)
        // 104 MB - 1 byte = piece 51
        XCTAssertEqual(mapping.endPieceIndex, 51)
        XCTAssertEqual(mapping.totalPiecesCount, 10)
        XCTAssertEqual(mapping.headMoovPieceIndices, [50])
    }

    // MARK: - 6. Content Type Classification

    func testContentTypeClassification() {
        XCTAssertEqual(LIDTorrentStreamAdapter.contentType(for: "movie.mp4"), "public.mpeg-4")
        XCTAssertEqual(LIDTorrentStreamAdapter.contentType(for: "video.m4v"), "public.mpeg-4")
        XCTAssertEqual(LIDTorrentStreamAdapter.contentType(for: "clip.mov"), "com.apple.quicktime-movie")
        XCTAssertEqual(LIDTorrentStreamAdapter.contentType(for: "film.mkv"), "video/x-matroska")
        XCTAssertEqual(LIDTorrentStreamAdapter.contentType(for: "song.mp3"), "public.mp3")
        XCTAssertEqual(LIDTorrentStreamAdapter.contentType(for: "audio.m4a"), "public.audio")
        XCTAssertEqual(LIDTorrentStreamAdapter.contentType(for: "stream.ts"), "public.mpeg-2-transport-stream")
        XCTAssertEqual(LIDTorrentStreamAdapter.contentType(for: "generic.bin"), "public.movie")
    }

    // MARK: - 7. Stream Context & Error Hierarchy

    func testStreamContextInfoDefaultsAndUpdates() {
        var context = LIDStreamContextInfo.empty
        XCTAssertFalse(context.isLive)
        XCTAssertFalse(context.isDVRSeekable)
        XCTAssertFalse(context.drmProtectionDetected)

        context.isLive = true
        context.isDVRSeekable = true
        context.dvrWindowDurationSeconds = 7200.0
        context.swarmDownloadSpeed = 3_500_000
        context.swarmConnectedPeers = 24
        context.swarmProgressFraction = 0.42

        XCTAssertTrue(context.isLive)
        XCTAssertTrue(context.isDVRSeekable)
        XCTAssertEqual(context.dvrWindowDurationSeconds, 7200.0)
        XCTAssertEqual(context.swarmDownloadSpeed, 3_500_000)
        XCTAssertEqual(context.swarmConnectedPeers, 24)
        XCTAssertEqual(context.swarmProgressFraction, 0.42)
    }
}
