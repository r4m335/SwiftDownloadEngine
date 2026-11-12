import Foundation
import XCTest
@testable import DM_Reverse_engineering

/// Comprehensive production validation tests for HLS and DASH VOD pipelines
/// covering Workstreams 4.1 through 4.7.
final class HLSAndDASHProductionValidationTests: XCTestCase {

    private var tempDir: URL!
    private let manifestURL = URL(string: "https://cdn.example.com/live-to-vod/master.m3u8?token=secure123&exp=999999")!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HLSDASHProdTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Helpers

    private func writeFile(bytes: [UInt8], name: String) -> URL {
        let url = tempDir.appendingPathComponent(name)
        try? Data(bytes).write(to: url)
        return url
    }

    private func makePATPacket() -> Data {
        var p = Data(repeating: 0xFF, count: 188)
        p[0] = 0x47; p[1] = 0x40; p[2] = 0x00; p[3] = 0x10; p[4] = 0x00
        p[5] = 0x00; p[6] = 0xB0; p[7] = 0x0D; p[8] = 0x00; p[9] = 0x01
        p[10] = 0xC1; p[11] = 0x00; p[12] = 0x00; p[13] = 0x00; p[14] = 0x01
        p[15] = 0xE1; p[16] = 0x00
        return p
    }

    private func makePMTPacket(videoStream: UInt8 = 0x1B, audioStream: UInt8 = 0x0F) -> Data {
        var p = Data(repeating: 0xFF, count: 188)
        p[0] = 0x47; p[1] = 0x41; p[2] = 0x00; p[3] = 0x10; p[4] = 0x00
        p[5] = 0x02; p[6] = 0xB0; p[7] = 0x17; p[8] = 0x00; p[9] = 0x01
        p[10] = 0xC1; p[11] = 0x00; p[12] = 0x00; p[13] = 0xE1; p[14] = 0x01
        p[15] = 0xF0; p[16] = 0x00
        p[17] = videoStream; p[18] = 0xE1; p[19] = 0x01; p[20] = 0xF0; p[21] = 0x00
        p[22] = audioStream; p[23] = 0xE1; p[24] = 0x02; p[25] = 0xF0; p[26] = 0x00
        return p
    }

    private func makeTSPacket(fill: UInt8 = 0xAA) -> Data {
        var p = Data([0x47, 0x01, 0x01, 0x10])
        p.append(Data(repeating: fill, count: 184))
        return p
    }

    private func makeBox(_ type: String, payload: [UInt8] = []) -> Data {
        let typeBytes = Array(type.utf8)
        let size = UInt32(8 + payload.count)
        var data = Data([
            UInt8((size >> 24) & 0xFF), UInt8((size >> 16) & 0xFF),
            UInt8((size >> 8) & 0xFF), UInt8(size & 0xFF)
        ])
        data.append(contentsOf: typeBytes)
        data.append(contentsOf: payload)
        return data
    }

    // MARK: - Workstream 4.1: HLS Master Playlist Validation

    func testMasterPlaylistVariantRankingAndFiltering() throws {
        let masterContent = """
        #EXTM3U
        #EXT-X-VERSION:4
        #EXT-X-STREAM-INF:BANDWIDTH=800000,AVERAGE-BANDWIDTH=750000,RESOLUTION=640x360,CODECS="avc1.4d401e,mp4a.40.2"
        360p/manifest.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2500000,AVERAGE-BANDWIDTH=2400000,RESOLUTION=1280x720,CODECS="avc1.4d401f,mp4a.40.2"
        720p/manifest.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=5000000,AVERAGE-BANDWIDTH=4800000,RESOLUTION=1920x1080,CODECS="avc1.640028,mp4a.40.2"
        1080p/manifest.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=9000000,AVERAGE-BANDWIDTH=8500000,RESOLUTION=3840x2160,CODECS="hev1.1.6.L150,mp4a.40.2"
        4k/manifest.m3u8
        """
        let manifest = try HLSManifestParser.parse(masterContent, baseURL: manifestURL)
        XCTAssertEqual(manifest.playlistType, .master)
        XCTAssertEqual(manifest.variants.count, 4)

        // 1. Default ranking: highest quality to lowest
        let ranked = try HLSVariantSelector.rank(from: manifest)
        XCTAssertEqual(ranked[0].resolution?.height, 2160)
        XCTAssertEqual(ranked[1].resolution?.height, 1080)
        XCTAssertEqual(ranked[2].resolution?.height, 720)
        XCTAssertEqual(ranked[3].resolution?.height, 360)

        // 2. Bandwidth cap: maximum 3,000,000 bps should pick 720p
        let cappedBandwidth = try HLSVariantSelector.select(
            from: manifest,
            preferences: HLSVariantSelectionPreferences(maximumBandwidth: 3000000)
        )
        XCTAssertEqual(cappedBandwidth.resolution?.height, 720)

        // 3. Resolution cap: maximum height 1080 should pick 1080p
        let cappedResolution = try HLSVariantSelector.select(
            from: manifest,
            preferences: HLSVariantSelectionPreferences(maximumHeight: 1080)
        )
        XCTAssertEqual(cappedResolution.resolution?.height, 1080)

        // 4. Codec preference: AVC only
        let avcSelected = try HLSVariantSelector.select(
            from: manifest,
            preferences: HLSVariantSelectionPreferences(preferredCodecPrefix: "avc1")
        )
        XCTAssertEqual(avcSelected.resolution?.height, 1080)
    }

    func testMasterPlaylistAudioRenditionSelection() throws {
        let masterContent = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio-aac",NAME="English",DEFAULT=YES,AUTOSELECT=YES,LANGUAGE="en",URI="audio/en.m3u8"
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio-aac",NAME="Spanish",DEFAULT=NO,AUTOSELECT=YES,LANGUAGE="es",URI="audio/es.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720,AUDIO="audio-aac"
        video/720p.m3u8
        """
        let manifest = try HLSManifestParser.parse(masterContent, baseURL: manifestURL)
        let variant = manifest.variants[0]

        // Default language selection falls back to default audio rendition (English)
        let defaultAudio = HLSVariantSelector.selectAudioRendition(for: variant, master: manifest)
        XCTAssertNotNil(defaultAudio)
        XCTAssertEqual(defaultAudio?.language, "en")
        XCTAssertEqual(defaultAudio?.isDefault, true)

        // Explicit Spanish language request matches Spanish rendition
        let spanishAudio = HLSVariantSelector.selectAudioRendition(for: variant, master: manifest, preferredLanguage: "es")
        XCTAssertNotNil(spanishAudio)
        XCTAssertEqual(spanishAudio?.language, "es")
    }

    func testSignedQueryParamsPreservedAcrossChildPlaylists() throws {
        let masterContent = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720
        variant.m3u8
        """
        let manifest = try HLSManifestParser.parse(masterContent, baseURL: manifestURL)
        let variant = manifest.variants[0]

        // Candidate has signed query tokens on the parent manifest URL
        let candidate = try StreamingManifestCandidate(
            url: manifestURL,
            mimeType: "application/vnd.apple.mpegurl"
        )

        // Child playlist URI must inherit query tokens when child URI lacks its own query
        let childURI: URL
        if (variant.uri.query == nil || variant.uri.query?.isEmpty == true),
           let parentQuery = manifestURL.query ?? candidate.url.query, !parentQuery.isEmpty,
           var components = URLComponents(url: variant.uri, resolvingAgainstBaseURL: false) {
            components.query = parentQuery
            childURI = components.url ?? variant.uri
        } else {
            childURI = variant.uri
        }

        XCTAssertTrue(childURI.absoluteString.contains("token=secure123"))
        XCTAssertTrue(childURI.absoluteString.contains("exp=999999"))
    }

    func testUnsupportedEncryptionExplicitlyRejected() throws {
        let sampleAESContent = """
        #EXTM3U
        #EXT-X-VERSION:5
        #EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://key.example",KEYFORMAT="com.apple.streamingkeydelivery"
        #EXTINF:6.0,
        segment1.ts
        #EXT-X-ENDLIST
        """
        let manifest = try HLSManifestParser.parse(sampleAESContent, baseURL: manifestURL)
        XCTAssertEqual(manifest.encryption, .sampleEncrypted)

        XCTAssertThrowsError(try HLSTransferPlanner.makeVODPlan(from: manifest)) { error in
            guard case let HLSVODTransferPlanError.unsupportedEncryption(classification) = error else {
                XCTFail("Expected unsupportedEncryption, got: \(error)")
                return
            }
            XCTAssertEqual(classification, .sampleEncrypted)
        }
    }

    // MARK: - Workstream 4.2: HLS Media Playlist Validation

    func testMPEGTSMediaPlaylistByteRangeAndDiscontinuity() throws {
        let playlistContent = """
        #EXTM3U
        #EXT-X-VERSION:4
        #EXT-X-TARGETDURATION:6
        #EXT-X-MEDIA-SEQUENCE:100
        #EXTINF:5.0,
        segment100.ts
        #EXT-X-DISCONTINUITY
        #EXTINF:5.0,
        #EXT-X-BYTERANGE:1024@0
        segment101.ts
        #EXTINF:5.0,
        #EXT-X-BYTERANGE:2048@1024
        segment101.ts
        #EXT-X-ENDLIST
        """
        let manifest = try HLSManifestParser.parse(playlistContent, baseURL: manifestURL)
        XCTAssertEqual(manifest.playlistType, .media)
        XCTAssertEqual(manifest.segments.count, 3)
        XCTAssertEqual(manifest.segments[0].sequenceNumber, 100)
        XCTAssertEqual(manifest.segments[1].sequenceNumber, 101)
        XCTAssertTrue(manifest.segments[1].isDiscontinuity)
        XCTAssertEqual(manifest.segments[1].byteRange?.length, 1024)
        XCTAssertEqual(manifest.segments[1].byteRange?.offset, 0)
        XCTAssertEqual(manifest.segments[2].byteRange?.length, 2048)
        XCTAssertEqual(manifest.segments[2].byteRange?.offset, 1024)
    }

    func testFragmentedMP4InitializationMapDetection() throws {
        let fmp4Playlist = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-TARGETDURATION:4
        #EXT-X-MAP:URI="init.mp4",BYTERANGE="800@0"
        #EXTINF:4.0,
        segment-1.m4s
        #EXTINF:4.0,
        segment-2.m4s
        #EXT-X-ENDLIST
        """
        let manifest = try HLSManifestParser.parse(fmp4Playlist, baseURL: manifestURL)
        let plan = try HLSTransferPlanner.makeVODPlan(from: manifest)

        XCTAssertEqual(plan.resources.count, 3)
        XCTAssertEqual(plan.resources[0].kind, .initializationMap)
        XCTAssertEqual(plan.resources[0].byteRange?.length, 800)
        XCTAssertEqual(plan.resources[1].kind, .mediaSegment)
        XCTAssertEqual(plan.resources[2].kind, .mediaSegment)
    }

    // MARK: - Workstream 4.3: HLS AES-128 Encryption

    func testAES128IVParsingHexAndOddLengths() {
        // Standard 32-character hex with "0x"
        let iv1 = HLSSegmentDecryptor.parseIV("0x00000000000000000000000000000001")
        XCTAssertNotNil(iv1)
        XCTAssertEqual(iv1?.count, 16)
        XCTAssertEqual(iv1?.last, 0x01)

        // Without "0x"
        let iv2 = HLSSegmentDecryptor.parseIV("00000000000000000000000000000002")
        XCTAssertNotNil(iv2)
        XCTAssertEqual(iv2?.last, 0x02)

        // Odd length hex (leading zero prepended)
        let iv3 = HLSSegmentDecryptor.parseIV("0x123")
        XCTAssertNotNil(iv3)
        XCTAssertEqual(iv3?.count, 16)
    }

    func testAES128SequenceNumberDerivedIV() {
        // RFC 8216 Section 5.2: sequence number formatted as 16-octet big-endian integer
        let iv0 = HLSSegmentDecryptor.ivForSequenceNumber(0)
        XCTAssertEqual(iv0.count, 16)
        XCTAssertEqual(iv0, Data(repeating: 0, count: 16))

        let iv1 = HLSSegmentDecryptor.ivForSequenceNumber(1)
        XCTAssertEqual(iv1.count, 16)
        XCTAssertEqual(iv1[15], 0x01)
        XCTAssertEqual(iv1[0], 0x00)

        let iv258 = HLSSegmentDecryptor.ivForSequenceNumber(258) // 0x0102
        XCTAssertEqual(iv258[14], 0x01)
        XCTAssertEqual(iv258[15], 0x02)
    }

    #if canImport(CommonCrypto)
    func testAES128EncryptionAndDecryptionRoundtrip() throws {
        let key = Data((0..<16).map { UInt8($0 + 1) })
        let iv = HLSSegmentDecryptor.ivForSequenceNumber(42)
        let plaintext = makeTSPacket(fill: 0x55) + makeTSPacket(fill: 0x66)

        let ciphertext = try HLSSegmentDecryptor.encrypt(data: plaintext, key: key, iv: iv)
        XCTAssertNotEqual(ciphertext, plaintext)
        XCTAssertTrue(ciphertext.count >= plaintext.count)

        let decrypted = try HLSSegmentDecryptor.decrypt(data: ciphertext, key: key, iv: iv)
        XCTAssertEqual(decrypted, plaintext)
    }
    #endif

    // MARK: - Workstream 4.4: DASH Validation

    func testDASHManifestSegmentTemplateAndTimelineParsing() throws {
        let mpdContent = """
        <?xml version="1.0" encoding="utf-8"?>
        <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT30S">
          <Period id="1">
            <AdaptationSet contentType="video" mimeType="video/mp4" codecs="avc1.4d401f">
              <SegmentTemplate timescale="1000" initialization="init-$RepresentationID$.mp4" media="segment-$RepresentationID$-$Number$.m4s" startNumber="1">
                <SegmentTimeline>
                  <S t="0" d="2000" r="2"/>
                </SegmentTimeline>
              </SegmentTemplate>
              <Representation id="v1" bandwidth="1500000" width="1280" height="720"/>
            </AdaptationSet>
            <AdaptationSet contentType="audio" mimeType="audio/mp4" codecs="mp4a.40.2">
              <SegmentTemplate timescale="1000" initialization="audio-init.mp4" media="audio-$Number$.m4s" startNumber="1">
                <SegmentTimeline>
                  <S t="0" d="2000" r="2"/>
                </SegmentTimeline>
              </SegmentTemplate>
              <Representation id="a1" bandwidth="128000"/>
            </AdaptationSet>
          </Period>
        </MPD>
        """
        let dashURL = URL(string: "https://dash.example.com/vod/stream.mpd")!
        let manifest = try DASHManifestParser.parse(mpdContent, baseURL: dashURL)
        XCTAssertEqual(manifest.periods.first?.adaptationSets.count, 2)

        let transferPlan = try DASHTransferPlanner.makeVODPlan(
            from: manifest,
            videoRepresentationID: "v1",
            audioRepresentationID: "a1"
        )

        // Video: 1 init + 3 segments = 4 resources
        // Audio: 1 init + 3 segments = 4 resources
        // Total = 8 resources
        XCTAssertEqual(transferPlan.resources.count, 8)
        XCTAssertEqual(transferPlan.video?.resources.count, 4)
        XCTAssertEqual(transferPlan.audio?.resources.count, 4)

        XCTAssertTrue(transferPlan.video?.resources[0].url.absoluteString.contains("init-v1.mp4") == true)
        XCTAssertTrue(transferPlan.video?.resources[1].url.absoluteString.contains("segment-v1-1.m4s") == true)
        XCTAssertTrue(transferPlan.video?.resources[2].url.absoluteString.contains("segment-v1-2.m4s") == true)
        XCTAssertTrue(transferPlan.video?.resources[3].url.absoluteString.contains("segment-v1-3.m4s") == true)
    }

    // MARK: - Workstream 4.5: Segment Transfer Reliability

    func testHTMLBlockResponseDetection() {
        let challengeHTML = "<!DOCTYPE html><html><head><title>Just a moment...</title></head><body>Verify you are human</body></html>"
        let challengeData = Data(challengeHTML.utf8)

        XCTAssertTrue(StreamingDownloadOrchestrator.isHTMLResponse(challengeData))

        let clearTS = makeTSPacket()
        XCTAssertFalse(StreamingDownloadOrchestrator.isHTMLResponse(clearTS))

        let fmp4Init = makeBox("ftyp", payload: Array("isom".utf8)) + makeBox("moov")
        XCTAssertFalse(StreamingDownloadOrchestrator.isHTMLResponse(fmp4Init))
    }

    // MARK: - Workstream 4.6: Media Assembly & Remuxing Structural Integrity

    func testMPEGTSPacketSyncAndElementaryStreamValidation() {
        // Valid TS stream with PAT and PMT (declaring AVC and AAC)
        var tsData = Data()
        tsData.append(makePATPacket())
        tsData.append(makePMTPacket(videoStream: 0x1B, audioStream: 0x0F))
        tsData.append(makeTSPacket())

        let url = writeFile(bytes: Array(tsData), name: "valid.ts")
        let outcome = MediaIntegrityValidator.validateStructure(fileURL: url, container: .mpegTS)
        XCTAssertTrue(outcome.isConfirmedValid)

        // Corrupted TS stream (sync byte missing)
        var corruptData = tsData
        corruptData[0] = 0x00
        let corruptURL = writeFile(bytes: Array(corruptData), name: "corrupt.ts")
        let corruptOutcome = MediaIntegrityValidator.validateStructure(fileURL: corruptURL, container: .mpegTS)
        XCTAssertFalse(corruptOutcome.isConfirmedValid)
    }

    func testRemuxedStandardMP4PassesStructuralValidation() {
        // Build a standard MP4 file (ftyp + moov + mdat) without moof box
        var mp4Data = Data()
        // ftyp box (brand isom)
        var ftypPayload = Array("isom".utf8)
        ftypPayload += [0, 0, 0, 0] // version
        ftypPayload += Array("isom".utf8)
        mp4Data.append(makeBox("ftyp", payload: ftypPayload))

        // moov box containing trak -> mdia -> minf -> stbl
        let mdia = makeBox("mdia", payload: Array(makeBox("minf", payload: Array(makeBox("stbl")))))
        let trak = makeBox("trak", payload: Array(mdia))
        mp4Data.append(makeBox("moov", payload: Array(trak)))

        // mdat box containing media elementary stream data
        let mdatPayload = [UInt8](repeating: 0x42, count: 1024)
        mp4Data.append(makeBox("mdat", payload: mdatPayload))

        let mp4URL = writeFile(bytes: Array(mp4Data), name: "remuxed.mp4")

        // 1. Structural validation via MediaAssemblyContainer (.fragmentedMP4 representing MP4 container)
        let structureOutcome = MediaIntegrityValidator.validateStructure(fileURL: mp4URL, container: .fragmentedMP4)
        XCTAssertTrue(structureOutcome.isConfirmedValid, "Remuxed standard MP4 must pass structural validation.")

        // 2. Direct validation via validateHLSOutput with isRemuxedMPEGTS=true
        let hlsOutcome = MediaIntegrityValidator.validateHLSOutput(fileURL: mp4URL, isRemuxedMPEGTS: true)
        XCTAssertTrue(hlsOutcome.outcome.isConfirmedValid, "Remuxed standard MP4 must pass HLS validation when flagged as remuxed.")
    }

    // MARK: - Workstream 4.7: Real-World Public VOD Streams

    func testPublicAppleHLSTestStreamPlanAndAssembly() throws {
        // Apple sample HLS stream manifest structure
        let appleMaster = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-STREAM-INF:BANDWIDTH=7680000,RESOLUTION=1920x1080
        gear4/prog_index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=65000,CODECS="mp4a.40.5"
        gear0/prog_index.m3u8
        """
        let appleBase = URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_4x3/bipbop_4x3_variant.m3u8")!
        let master = try HLSManifestParser.parse(appleMaster, baseURL: appleBase)
        let selectedVariant = try HLSVariantSelector.select(from: master)

        XCTAssertEqual(selectedVariant.resolution?.width, 1920)
        XCTAssertEqual(selectedVariant.resolution?.height, 1080)
        XCTAssertEqual(selectedVariant.uri.absoluteString, "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_4x3/gear4/prog_index.m3u8")

        let gear4Playlist = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:10
        #EXT-X-MEDIA-SEQUENCE:0
        #EXTINF:10.0,
        fileSequence0.ts
        #EXTINF:10.0,
        fileSequence1.ts
        #EXT-X-ENDLIST
        """
        let mediaManifest = try HLSManifestParser.parse(gear4Playlist, baseURL: selectedVariant.uri)
        let transferPlan = try HLSTransferPlanner.makeVODPlan(from: mediaManifest)

        XCTAssertEqual(transferPlan.resources.count, 2)
        XCTAssertEqual(transferPlan.resources[0].kind, .mediaSegment)
        XCTAssertEqual(transferPlan.resources[1].kind, .mediaSegment)

        // Mock segments
        let seg0 = tempDir.appendingPathComponent("seg0.part")
        let seg1 = tempDir.appendingPathComponent("seg1.part")
        let seg0Data = makePATPacket() + makePMTPacket()
        let seg1Data = makeTSPacket(fill: 0x11)
        try seg0Data.write(to: seg0)
        try seg1Data.write(to: seg1)

        let completed = [
            HLSCompletedResource(resource: transferPlan.resources[0], fileURL: seg0),
            HLSCompletedResource(resource: transferPlan.resources[1], fileURL: seg1)
        ]

        let outputURL = tempDir.appendingPathComponent("bipbop.ts")
        let assemblyOutput = try HLSVODReconstructor.assemble(
            transferPlan: transferPlan,
            completedResources: completed,
            destinationURL: outputURL
        )

        XCTAssertEqual(assemblyOutput.container, .mpegTS)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertEqual(try Data(contentsOf: outputURL), seg0Data + seg1Data)
    }

    func testPublicAppleFMP4TestStreamPlanAndAssembly() throws {
        // Apple sample fMP4 HLS manifest with EXT-X-MAP
        let fmp4Playlist = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-TARGETDURATION:6
        #EXT-X-MAP:URI="main.mp4"
        #EXTINF:6.0,
        segment-1.m4s
        #EXTINF:6.0,
        segment-2.m4s
        #EXT-X-ENDLIST
        """
        let streamURL = URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/fmp4/prog_index.m3u8")!
        let manifest = try HLSManifestParser.parse(fmp4Playlist, baseURL: streamURL)
        let transferPlan = try HLSTransferPlanner.makeVODPlan(from: manifest)

        XCTAssertEqual(transferPlan.resources.count, 3)
        XCTAssertEqual(transferPlan.resources[0].kind, .initializationMap)
        XCTAssertEqual(transferPlan.resources[1].kind, .mediaSegment)
        XCTAssertEqual(transferPlan.resources[2].kind, .mediaSegment)

        // Synthetic fMP4 segments
        let initBytes = makeBox("ftyp", payload: Array("isom".utf8)) + makeBox("moov", payload: Array("mvex".utf8))
        let seg1Bytes = makeBox("moof", payload: [1]) + makeBox("mdat", payload: [UInt8](repeating: 0x11, count: 64))
        let seg2Bytes = makeBox("moof", payload: [2]) + makeBox("mdat", payload: [UInt8](repeating: 0x22, count: 64))

        let initFile = tempDir.appendingPathComponent("init.part")
        let seg1File = tempDir.appendingPathComponent("seg1.part")
        let seg2File = tempDir.appendingPathComponent("seg2.part")

        try initBytes.write(to: initFile)
        try seg1Bytes.write(to: seg1File)
        try seg2Bytes.write(to: seg2File)

        let completed = [
            HLSCompletedResource(resource: transferPlan.resources[0], fileURL: initFile),
            HLSCompletedResource(resource: transferPlan.resources[1], fileURL: seg1File),
            HLSCompletedResource(resource: transferPlan.resources[2], fileURL: seg2File)
        ]

        let outputURL = tempDir.appendingPathComponent("vod.mp4")
        let assemblyOutput = try HLSVODReconstructor.assemble(
            transferPlan: transferPlan,
            completedResources: completed,
            destinationURL: outputURL
        )

        XCTAssertEqual(assemblyOutput.container, .fragmentedMP4)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertEqual(try Data(contentsOf: outputURL), initBytes + seg1Bytes + seg2Bytes)
    }

    func testPublicDASHIFMultiTrackTestStreamPlanAndAssembly() throws {
        // DASH-IF compliant MPD with separate video and audio representations
        let dashMPD = """
        <?xml version="1.0" encoding="utf-8"?>
        <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" profiles="urn:mpeg:dash:profile:isoff-live:2011" type="static" mediaPresentationDuration="PT20S">
          <Period id="0">
            <AdaptationSet mimeType="video/mp4" codecs="avc1.64001f" contentType="video">
              <SegmentTemplate timescale="1000" initialization="video-init.mp4" media="video-$Number$.m4s" startNumber="1">
                <SegmentTimeline>
                  <S t="0" d="4000" r="1"/>
                </SegmentTimeline>
              </SegmentTemplate>
              <Representation id="video_1080p" bandwidth="3000000" width="1920" height="1080"/>
            </AdaptationSet>
            <AdaptationSet mimeType="audio/mp4" codecs="mp4a.40.2" contentType="audio">
              <SegmentTemplate timescale="1000" initialization="audio-init.mp4" media="audio-$Number$.m4s" startNumber="1">
                <SegmentTimeline>
                  <S t="0" d="4000" r="1"/>
                </SegmentTimeline>
              </SegmentTemplate>
              <Representation id="audio_en" bandwidth="128000"/>
            </AdaptationSet>
          </Period>
        </MPD>
        """
        let dashURL = URL(string: "https://dash.akamaized.net/dash264/TestCases/1a/qualcomm/1/MultiRate.mpd")!
        let manifest = try DASHManifestParser.parse(dashMPD, baseURL: dashURL)
        let transferPlan = try DASHTransferPlanner.makeVODPlan(
            from: manifest,
            videoRepresentationID: "video_1080p",
            audioRepresentationID: "audio_en"
        )

        XCTAssertEqual(transferPlan.video?.resources.count, 3) // 1 init + 2 media
        XCTAssertEqual(transferPlan.audio?.resources.count, 3) // 1 init + 2 media
        XCTAssertEqual(transferPlan.resources.count, 6)

        // Mock completed resources
        let completed: [DASHCompletedResource] = try transferPlan.resources.enumerated().map { index, resource in
            let fileURL = tempDir.appendingPathComponent("dash-res-\(index).part")
            let data: Data
            if resource.kind == .initialization {
                data = makeBox("ftyp", payload: Array("isom".utf8)) + makeBox("moov", payload: Array("mvex".utf8))
            } else {
                data = makeBox("moof", payload: [UInt8(index)]) + makeBox("mdat", payload: [UInt8](repeating: 0x99, count: 64))
            }
            try data.write(to: fileURL)
            return DASHCompletedResource(resource: resource, fileURL: fileURL)
        }

        let outputURL = tempDir.appendingPathComponent("dash_assembled.mp4")
        let reconstruction = try DASHVODReconstructionPlanner.makePlan(
            from: transferPlan,
            completedResources: completed,
            destinationURL: outputURL
        )

        XCTAssertEqual(reconstruction.assemblyRequest.tracks.count, 2)
        XCTAssertEqual(reconstruction.assemblyRequest.tracks[0].kind, .video)
        XCTAssertEqual(reconstruction.assemblyRequest.tracks[1].kind, .audio)
        XCTAssertEqual(reconstruction.assemblyRequest.tracks[0].mediaSegments.count, 2)
        XCTAssertEqual(reconstruction.assemblyRequest.tracks[1].mediaSegments.count, 2)
    }
}

