import Foundation
import XCTest
@testable import DownloadEngineKit

final class StreamingManifestTests: XCTestCase {

    private let hlsURL = URL(string: "https://example.com/video/master.m3u8?session=redacted")!
    private let dashURL = URL(string: "https://example.com/video/manifest")!

    func testClassifierUsesContentForExtensionlessAndMisleadingURLs() {
        let hls = "#EXTM3U\n#EXT-X-VERSION:3\n"
        let dash = "<MPD xmlns=\"urn:mpeg:dash:schema:mpd:2011\"></MPD>"

        XCTAssertEqual(
            StreamingManifestClassifier.classify(url: dashURL, content: hls).kind,
            .hls
        )
        XCTAssertEqual(
            StreamingManifestClassifier.classify(url: hlsURL, mimeType: "video/mp4", content: "ordinary file").kind,
            .unknown
        )
        XCTAssertEqual(
            StreamingManifestClassifier.classify(url: dashURL, mimeType: "application/dash+xml").kind,
            .dash
        )
        XCTAssertEqual(
            StreamingManifestClassifier.classify(url: hlsURL, mimeType: "application/dash+xml").kind,
            .unsupported
        )
        XCTAssertEqual(
            StreamingManifestClassifier.classify(url: dashURL, content: dash).kind,
            .dash
        )
    }

    func testClassifierRejectsOversizedInspectionInput() {
        let limits = ManifestParsingLimits(maxBytes: 16)
        let result = StreamingManifestClassifier.classify(
            url: dashURL,
            content: Data(repeating: 0x20, count: 17),
            limits: limits
        )
        XCTAssertEqual(result.kind, .unsupported)
        XCTAssertEqual(result.evidence, .content)
    }

    func testHLSMasterPlaylistParsesVariantsAndRenditions() throws {
        let playlist = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-INDEPENDENT-SEGMENTS
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="English",DEFAULT=YES,AUTOSELECT=YES,URI="audio/index.m3u8?lang=en"
        #EXT-X-STREAM-INF:BANDWIDTH=2800000,AVERAGE-BANDWIDTH=2400000,RESOLUTION=1280x720,CODECS="avc1.64001f,mp4a.40.2",AUDIO="audio"
        variants/720p.m3u8?token=private
        #EXT-X-STREAM-INF:BANDWIDTH=900000,RESOLUTION=640x360,CODECS="avc1.4d401e"
        variants/360p.m3u8
        """

        let manifest = try HLSManifestParser.parse(playlist, baseURL: hlsURL)
        XCTAssertEqual(manifest.playlistType, .master)
        XCTAssertEqual(manifest.version, 7)
        XCTAssertTrue(manifest.independentSegments)
        XCTAssertEqual(manifest.variants.count, 2)
        XCTAssertEqual(manifest.variants[0].bandwidth, 2_800_000)
        XCTAssertEqual(manifest.variants[0].resolution, HLSResolution(width: 1280, height: 720))
        XCTAssertEqual(manifest.variants[0].uri.absoluteString, "https://example.com/video/variants/720p.m3u8?token=private&session=redacted")
        XCTAssertEqual(manifest.variants[1].uri.absoluteString, "https://example.com/video/variants/360p.m3u8?session=redacted")
        XCTAssertEqual(manifest.renditions.first?.uri?.absoluteString, "https://example.com/video/audio/index.m3u8?lang=en&session=redacted")
    }

    func testHLSMediaPlaylistParsesVODSegmentsMapAndEncryption() throws {
        let playlist = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-TARGETDURATION:6
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXT-X-MEDIA-SEQUENCE:10
        #EXT-X-MAP:URI="init.mp4",BYTERANGE="720@0"
        #EXTINF:5.5,Opening
        #EXT-X-BYTERANGE:1200@720
        segment-10.m4s?part=1
        #EXT-X-KEY:METHOD=AES-128,URI="keys/key.bin",IV=0x00000000000000000000000000000001
        #EXTINF:5.0
        segment-11.m4s
        #EXT-X-ENDLIST
        """

        let manifest = try HLSManifestParser.parse(playlist, baseURL: hlsURL)
        XCTAssertEqual(manifest.playlistType, .media)
        XCTAssertEqual(manifest.lifecycle, .vod)
        XCTAssertEqual(manifest.segments.map(\.sequenceNumber), [10, 11])
        XCTAssertEqual(manifest.segments[0].duration, 5.5, accuracy: 0.001)
        XCTAssertEqual(manifest.segments[0].initializationMap?.uri.absoluteString, "https://example.com/video/init.mp4?session=redacted")
        XCTAssertEqual(manifest.segments[0].uri.absoluteString, "https://example.com/video/segment-10.m4s?part=1&session=redacted")
        XCTAssertEqual(manifest.segments[1].uri.absoluteString, "https://example.com/video/segment-11.m4s?session=redacted")
        XCTAssertEqual(manifest.segments[1].encryption?.keyURL?.absoluteString, "https://example.com/video/keys/key.bin?session=redacted")
        XCTAssertEqual(manifest.segments[0].byteRange, HLSByteRange(length: 1200, offset: 720))
        XCTAssertEqual(manifest.segments[1].encryption?.classification, .aes128)
        XCTAssertEqual(manifest.encryption, .aes128)
    }

    func testHLSLiveAndUnsupportedEncryptionAreClassifiedWithoutFetching() throws {
        let live = """
        #EXTM3U
        #EXT-X-TARGETDURATION:4
        #EXTINF:4,
        segment.ts
        """
        let encrypted = """
        #EXTM3U
        #EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://license.example/key",KEYFORMAT="com.apple.streamingkeydelivery"
        #EXTINF:4,
        segment.ts
        #EXT-X-ENDLIST
        """

        let liveManifest = try HLSManifestParser.parse(live, baseURL: hlsURL)
        XCTAssertEqual(liveManifest.lifecycle, .live)
        XCTAssertFalse(liveManifest.lifecycle.isFinite)

        let encryptedManifest = try HLSManifestParser.parse(encrypted, baseURL: hlsURL)
        XCTAssertEqual(encryptedManifest.encryption, .sampleEncrypted)
        XCTAssertEqual(encryptedManifest.segments[0].encryption?.keyURL?.scheme, "skd")
    }

    func testHLSMalformedPlaylistFailsActionably() {
        let malformed = """
        #EXTM3U
        #EXT-X-STREAM-INF:RESOLUTION=not-a-resolution
        only.m3u8
        """
        XCTAssertThrowsError(try HLSManifestParser.parse(malformed, baseURL: hlsURL)) { error in
            XCTAssertTrue(error.localizedDescription.contains("BANDWIDTH"))
        }
    }

    func testHLSInvalidNumericAttributeFailsSafely() {
        let malformed = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=1000,AVERAGE-BANDWIDTH=not-a-number
        video.m3u8
        """
        XCTAssertThrowsError(try HLSManifestParser.parse(malformed, baseURL: hlsURL)) { error in
            XCTAssertTrue(error.localizedDescription.contains("AVERAGE-BANDWIDTH"))
        }
    }

    func testDASHNamespaceQualifiedMPDParsesInheritedBasesAndTimelines() throws {
        let mpd = """
        <?xml version="1.0"?>
        <mpd:MPD xmlns:mpd="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT10S" minBufferTime="PT1.5S">
          <mpd:BaseURL>https://cdn.example/media/</mpd:BaseURL>
          <mpd:Period id="p0" start="PT0S" duration="PT10S">
            <mpd:BaseURL>period/</mpd:BaseURL>
            <mpd:AdaptationSet id="video" contentType="video" mimeType="video/mp4" codecs="avc1.64001f">
              <mpd:BaseURL>video/</mpd:BaseURL>
              <mpd:SegmentTemplate timescale="1000" media="seg-$Number$.m4s" initialization="init.mp4" startNumber="1">
                <mpd:SegmentTimeline>
                  <mpd:S t="0" d="5000" r="1"/>
                </mpd:SegmentTimeline>
              </mpd:SegmentTemplate>
              <mpd:Representation id="v720" bandwidth="2500000" width="1280" height="720"/>
            </mpd:AdaptationSet>
            <mpd:AdaptationSet id="audio" contentType="audio" mimeType="audio/mp4">
              <mpd:SegmentList timescale="48000" duration="480000">
                <mpd:Initialization sourceURL="audio-init.mp4" range="0-99"/>
                <mpd:SegmentURL media="audio-1.m4s?track=a" mediaRange="100-199"/>
              </mpd:SegmentList>
              <mpd:Representation id="a128" bandwidth="128000"/>
            </mpd:AdaptationSet>
          </mpd:Period>
        </mpd:MPD>
        """

        let manifest = try DASHManifestParser.parse(mpd, baseURL: dashURL)
        XCTAssertEqual(manifest.presentationType, .staticPresentation)
        XCTAssertTrue(manifest.isFinite)
        XCTAssertEqual(manifest.mediaPresentationDuration ?? -1, 10.0, accuracy: 0.001)
        XCTAssertEqual(manifest.periods.count, 1)
        XCTAssertEqual(manifest.periods[0].adaptationSets.count, 2)

        let video = manifest.periods[0].adaptationSets[0]
        XCTAssertEqual(video.representations[0].baseURL?.absoluteString, "https://cdn.example/media/period/video/")
        XCTAssertEqual(video.representations[0].segmentTemplate?.timeline, [
            DASHSegmentTimelineEntry(start: 0, duration: 5000, repeatCount: 1)
        ])
        XCTAssertEqual(video.representations[0].segmentTemplate?.initialization, "init.mp4")

        let audio = manifest.periods[0].adaptationSets[1]
        XCTAssertEqual(audio.segmentList?.initialization?.sourceURL?.absoluteString, "https://cdn.example/media/period/audio-init.mp4")
        XCTAssertEqual(audio.segmentList?.segmentURLs[0].mediaURL?.absoluteString, "https://cdn.example/media/period/audio-1.m4s?track=a")
    }

    func testDASHDynamicAndUnsupportedStructures() throws {
        let dynamic = """
        <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="dynamic">
          <Period><AdaptationSet><Representation id="v" bandwidth="1"><SegmentList><SegmentURL media="a.m4s"/></SegmentList></Representation></AdaptationSet></Period>
        </MPD>
        """
        let parsed = try DASHManifestParser.parse(dynamic, baseURL: dashURL)
        XCTAssertEqual(parsed.presentationType, .dynamicPresentation)
        XCTAssertFalse(parsed.isFinite)

        let doctype = "<!DOCTYPE MPD [<!ENTITY xxe SYSTEM \"file:///etc/passwd\">]><MPD><Period/></MPD>"
        XCTAssertThrowsError(try DASHManifestParser.parse(doctype, baseURL: dashURL)) { error in
            XCTAssertTrue(error.localizedDescription.contains("DOCTYPE"))
        }

        let unsupported = "<MPD><Period><AdaptationSet><Representation><SegmentBase/></Representation></AdaptationSet></Period></MPD>"
        XCTAssertThrowsError(try DASHManifestParser.parse(unsupported, baseURL: dashURL)) { error in
            XCTAssertTrue(error.localizedDescription.contains("SegmentBase"))
        }

        let invalidTimeline = """
        <MPD><Period><AdaptationSet><Representation>
          <SegmentTemplate><SegmentTimeline><S d="0"/></SegmentTimeline></SegmentTemplate>
        </Representation></AdaptationSet></Period></MPD>
        """
        XCTAssertThrowsError(try DASHManifestParser.parse(invalidTimeline, baseURL: dashURL)) { error in
            XCTAssertTrue(error.localizedDescription.contains("positive"))
        }
    }

    func testDASHLimitsRejectOversizedAndDeepInputs() {
        let oversized = Data(repeating: 0x20, count: 100)
        XCTAssertThrowsError(try DASHManifestParser.parse(
            oversized,
            baseURL: dashURL,
            limits: ManifestParsingLimits(maxBytes: 99)
        ))

        let deep = "<MPD>" + String(repeating: "<Period>", count: 5) + "</Period>" + String(repeating: "</Period>", count: 4) + "</MPD>"
        XCTAssertThrowsError(try DASHManifestParser.parse(
            deep,
            baseURL: dashURL,
            limits: ManifestParsingLimits(maxNestingDepth: 3)
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("nesting") || error.localizedDescription.contains("XML"))
        }
    }

    func testDASHManifestParserRejectsHTMLBlockPageWithCleanError() {
        let htmlBlockPage = """
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="utf-8">
            <title>Access Denied</title>
        </head>
        <body>
            <h1>403 Forbidden</h1>
            <p>Request blocked by security policy.</p>
        </body>
        </html>
        """
        XCTAssertThrowsError(try DASHManifestParser.parse(htmlBlockPage, baseURL: dashURL)) { error in
            guard case ManifestParserError.malformed(let reason) = error else {
                XCTFail("Expected ManifestParserError.malformed, got: \(error)")
                return
            }
            XCTAssertEqual(reason, "Server blocked request. Returned HTML instead of manifest.")
        }
    }

    func testHLSManifestParserRejectsHTMLBlockPageWithCleanError() {
        let htmlBlockPage = """
        <!DOCTYPE html>
        <html>
        <head><title>Cloudflare Challenge</title></head>
        <body>Attention Required!</body>
        </html>
        """
        XCTAssertThrowsError(try HLSManifestParser.parse(htmlBlockPage, baseURL: hlsURL)) { error in
            guard case ManifestParserError.malformed(let reason) = error else {
                XCTFail("Expected ManifestParserError.malformed, got: \(error)")
                return
            }
            XCTAssertEqual(reason, "Server blocked request. Returned HTML instead of manifest.")
        }
    }

    func testStreamingManifestClassifierRejectsHTMLResponse() {
        let html = "<html><head><title>Block</title></head><body>Blocked</body></html>"
        let classification = StreamingManifestClassifier.classify(
            url: URL(string: "https://dash.akamaized.net/akamai/bbb_30fps/bbb_30fps.mpd")!,
            content: html
        )
        XCTAssertFalse(classification.isManifest)
        XCTAssertEqual(classification.kind, .unknown)
    }

    func testHLSManifestParserExtractsSubtitles() throws {
        let master = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="English",DEFAULT=YES,URI="audio.m3u8"
        #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",DEFAULT=YES,AUTOSELECT=YES,FORCED=NO,LANGUAGE="en",URI="subs/en.vtt"
        #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="Spanish",DEFAULT=NO,AUTOSELECT=YES,FORCED=NO,LANGUAGE="es",URI="subs/es.vtt"
        #EXT-X-STREAM-INF:BANDWIDTH=1500000,AUDIO="audio",SUBTITLES="subs"
        video.m3u8
        """

        let manifest = try HLSManifestParser.parse(master, baseURL: URL(string: "https://example.com/master.m3u8")!)
        XCTAssertEqual(manifest.subtitleRenditions.count, 2)
        XCTAssertEqual(manifest.subtitleRenditions[0].name, "English")
        XCTAssertEqual(manifest.subtitleRenditions[0].language, "en")
        XCTAssertTrue(manifest.subtitleRenditions[0].isDefault)
        XCTAssertEqual(manifest.subtitleURIs.count, 2)
        XCTAssertEqual(manifest.subtitleURIs[0].absoluteString, "https://example.com/subs/en.vtt")
        XCTAssertEqual(manifest.subtitleURIs[1].absoluteString, "https://example.com/subs/es.vtt")

        let extracted = HLSManifestParser.extractSubtitles(from: manifest)
        XCTAssertEqual(extracted.count, 2)
    }

    func testMasterPlaylistContainingOnlyIFrameVariantsParsesCleanly() throws {
        let playlist = """
        #EXTM3U
        #EXT-X-VERSION:4
        #EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=860000,AVERAGE-BANDWIDTH=750000,RESOLUTION=1920x1080,CODECS="avc1.640028",URI="iframe_1080p.m3u8"
        #EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=420000,RESOLUTION=1280x720,CODECS="avc1.4d401f",FRAME-RATE=29.97,URI="iframe_720p.m3u8"
        """

        let manifest = try HLSManifestParser.parse(playlist, baseURL: hlsURL)
        XCTAssertEqual(manifest.playlistType, .master)
        XCTAssertEqual(manifest.variants.count, 2)
        XCTAssertTrue(manifest.primaryVariants.isEmpty)
        XCTAssertEqual(manifest.iFrameVariants.count, 2)
        XCTAssertTrue(manifest.variants.allSatisfy(\.isIFrameOnly))

        let first = manifest.variants[0]
        XCTAssertEqual(first.bandwidth, 860_000)
        XCTAssertEqual(first.averageBandwidth, 750_000)
        XCTAssertEqual(first.resolution, HLSResolution(width: 1920, height: 1080))
        XCTAssertEqual(first.codecs, "avc1.640028")
        XCTAssertEqual(first.uri.absoluteString, "https://example.com/video/iframe_1080p.m3u8?session=redacted")
        XCTAssertTrue(first.isIFrameOnly)

        let second = manifest.variants[1]
        XCTAssertEqual(second.bandwidth, 420_000)
        XCTAssertEqual(second.resolution, HLSResolution(width: 1280, height: 720))
        XCTAssertEqual(second.frameRate ?? 0, 29.97, accuracy: 0.01)
        XCTAssertEqual(second.uri.absoluteString, "https://example.com/video/iframe_720p.m3u8?session=redacted")
        XCTAssertTrue(second.isIFrameOnly)
    }

    func testMixedMasterPlaylistRanksPrimaryBeforeIFrameVariants() throws {
        let playlist = """
        #EXTM3U
        #EXT-X-VERSION:4
        #EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=1920x1080,URI="iframe_1080.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080,CODECS="avc1.640028"
        video_1080.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720,CODECS="avc1.4d401f"
        video_720.m3u8
        #EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=500000,RESOLUTION=1280x720,URI="iframe_720.m3u8"
        """

        let manifest = try HLSManifestParser.parse(playlist, baseURL: hlsURL)
        XCTAssertEqual(manifest.variants.count, 4)
        XCTAssertEqual(manifest.primaryVariants.count, 2)
        XCTAssertEqual(manifest.iFrameVariants.count, 2)

        let ranked = try HLSVariantSelector.rank(from: manifest)
        XCTAssertEqual(ranked.count, 4)
        // Primary streams must come before I-frame streams
        XCTAssertFalse(ranked[0].isIFrameOnly)
        XCTAssertEqual(ranked[0].bandwidth, 5_000_000)
        XCTAssertFalse(ranked[1].isIFrameOnly)
        XCTAssertEqual(ranked[1].bandwidth, 2_500_000)
        XCTAssertTrue(ranked[2].isIFrameOnly)
        XCTAssertEqual(ranked[2].bandwidth, 1_000_000)
        XCTAssertTrue(ranked[3].isIFrameOnly)
        XCTAssertEqual(ranked[3].bandwidth, 500_000)

        // Select without preferences must select primary stream
        let selected = try HLSVariantSelector.select(from: manifest)
        XCTAssertFalse(selected.isIFrameOnly)
        XCTAssertEqual(selected.bandwidth, 5_000_000)

        // Deduplication must preserve both 1080p primary and 1080p iframe variant
        let deduplicated = HLSVariantSelector.deduplicate(ranked)
        XCTAssertEqual(deduplicated.count, 4)
    }

    func testMediaPlaylistWithIFramesOnlyTag() throws {
        let playlist = """
        #EXTM3U
        #EXT-X-VERSION:4
        #EXT-X-TARGETDURATION:6
        #EXT-X-I-FRAMES-ONLY
        #EXT-X-BYTERANGE:34000@0
        #EXTINF:6.0,
        segment.ts
        #EXT-X-BYTERANGE:28000
        #EXTINF:6.0,
        segment.ts
        #EXT-X-ENDLIST
        """

        let manifest = try HLSManifestParser.parse(playlist, baseURL: hlsURL)
        XCTAssertEqual(manifest.playlistType, .media)
        XCTAssertTrue(manifest.isIFramesOnly)
        XCTAssertEqual(manifest.segments.count, 2)
        XCTAssertEqual(manifest.segments[0].byteRange, HLSByteRange(length: 34000, offset: 0))
        XCTAssertEqual(manifest.segments[1].byteRange, HLSByteRange(length: 28000, offset: 34000))
    }

    func testIFrameStreamInfValidationErrors() {
        let missingURI = """
        #EXTM3U
        #EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=500000,RESOLUTION=1920x1080
        """
        XCTAssertThrowsError(try HLSManifestParser.parse(missingURI, baseURL: hlsURL)) { error in
            guard case ManifestParserError.malformed(let reason) = error else {
                XCTFail("Expected malformed error, got: \(error)")
                return
            }
            XCTAssertTrue(reason.contains("requires a valid URI"))
        }

        let missingBandwidth = """
        #EXTM3U
        #EXT-X-I-FRAME-STREAM-INF:URI="iframe.m3u8",RESOLUTION=1920x1080
        """
        XCTAssertThrowsError(try HLSManifestParser.parse(missingBandwidth, baseURL: hlsURL)) { error in
            guard case ManifestParserError.malformed(let reason) = error else {
                XCTFail("Expected malformed error, got: \(error)")
                return
            }
            XCTAssertTrue(reason.contains("requires a positive BANDWIDTH"))
        }

        let danglingStreamInf = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720
        #EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=500000,URI="iframe.m3u8"
        """
        XCTAssertThrowsError(try HLSManifestParser.parse(danglingStreamInf, baseURL: hlsURL)) { error in
            guard case ManifestParserError.malformed(let reason) = error else {
                XCTFail("Expected malformed error, got: \(error)")
                return
            }
            XCTAssertTrue(reason.contains("variant is missing its URI"))
        }
    }

    func testLLHLSPlaylistWithOnlyPartialSegmentsParsesCleanly() throws {
        let playlist = """
        #EXTM3U
        #EXT-X-VERSION:6
        #EXT-X-TARGETDURATION:2
        #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=1.004000,CAN-SKIP-UNTIL=12.0
        #EXT-X-PART-INF:PART-TARGET=0.33334
        #EXT-X-MEDIA-SEQUENCE:100
        #EXT-X-PART:DURATION=0.33334,URI="part100.0.ts",INDEPENDENT=YES,BYTERANGE=1000@0
        #EXT-X-PART:DURATION=0.33334,URI="part100.0.ts",BYTERANGE=2000
        #EXT-X-PART:DURATION=0.33334,URI="part100.1.ts",GAP=YES
        #EXT-X-PRELOAD-HINT:TYPE=PART,URI="part100.2.ts",BYTERANGE-START=0,BYTERANGE-LENGTH=1500
        """

        let manifest = try HLSManifestParser.parse(playlist, baseURL: hlsURL)
        XCTAssertEqual(manifest.playlistType, .media)
        XCTAssertEqual(manifest.lifecycle, .live)
        XCTAssertTrue(manifest.isLowLatency)
        XCTAssertTrue(manifest.hasSynthesizedSegmentsFromParts)

        // Server control
        XCTAssertNotNil(manifest.serverControl)
        XCTAssertTrue(manifest.serverControl?.canBlockReload == true)
        XCTAssertEqual(manifest.serverControl?.partHoldBack ?? 0, 1.004, accuracy: 0.001)
        XCTAssertEqual(manifest.serverControl?.canSkipUntil ?? 0, 12.0, accuracy: 0.001)

        // Part target duration
        XCTAssertEqual(manifest.partTargetDuration ?? 0, 0.33334, accuracy: 0.00001)

        // Parts
        XCTAssertEqual(manifest.parts.count, 3)
        XCTAssertEqual(manifest.parts[0].uri.absoluteString, "https://example.com/video/part100.0.ts?session=redacted")
        XCTAssertTrue(manifest.parts[0].isIndependent)
        XCTAssertEqual(manifest.parts[0].byteRange, HLSByteRange(length: 1000, offset: 0))

        // Implicit offset continuation on same URI
        XCTAssertEqual(manifest.parts[1].byteRange, HLSByteRange(length: 2000, offset: 1000))

        // Gap flag
        XCTAssertTrue(manifest.parts[2].isGap)

        // Preload hint
        XCTAssertEqual(manifest.preloadHints.count, 1)
        XCTAssertEqual(manifest.preloadHints[0].type, .part)
        XCTAssertEqual(manifest.preloadHints[0].uri.absoluteString, "https://example.com/video/part100.2.ts?session=redacted")
        XCTAssertEqual(manifest.preloadHints[0].byteRangeStart, 0)
        XCTAssertEqual(manifest.preloadHints[0].byteRangeLength, 1500)

        // Synthesized segments for downstream recorders
        XCTAssertEqual(manifest.segments.count, 3)
        XCTAssertEqual(manifest.segments[0].sequenceNumber, 100)
        XCTAssertEqual(manifest.segments[0].duration, 0.33334, accuracy: 0.00001)
        XCTAssertEqual(manifest.segments[0].uri.absoluteString, "https://example.com/video/part100.0.ts?session=redacted")
        XCTAssertEqual(manifest.segments[1].sequenceNumber, 101)
        XCTAssertEqual(manifest.segments[2].sequenceNumber, 102)
    }

    func testLLHLSPlaylistWithBothCompleteSegmentsAndTrailingParts() throws {
        let playlist = """
        #EXTM3U
        #EXT-X-VERSION:6
        #EXT-X-TARGETDURATION:4
        #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=1.0
        #EXT-X-PART-INF:PART-TARGET=0.5
        #EXT-X-MEDIA-SEQUENCE:50
        #EXT-X-PART:DURATION=0.5,URI="seg50.part0.ts",INDEPENDENT=YES
        #EXT-X-PART:DURATION=0.5,URI="seg50.part1.ts"
        #EXTINF:1.0,Opening
        seg50.ts
        #EXT-X-PART:DURATION=0.5,URI="seg51.part0.ts",INDEPENDENT=YES
        #EXT-X-PRELOAD-HINT:TYPE=PART,URI="seg51.part1.ts"
        """

        let manifest = try HLSManifestParser.parse(playlist, baseURL: hlsURL)
        XCTAssertEqual(manifest.playlistType, .media)
        XCTAssertTrue(manifest.isLowLatency)
        XCTAssertFalse(manifest.hasSynthesizedSegmentsFromParts)

        // 1 complete media segment
        XCTAssertEqual(manifest.segments.count, 1)
        XCTAssertEqual(manifest.segments[0].sequenceNumber, 50)
        XCTAssertEqual(manifest.segments[0].duration, 1.0, accuracy: 0.001)
        XCTAssertEqual(manifest.segments[0].title, "Opening")
        XCTAssertEqual(manifest.segments[0].parts.count, 2)

        // All parts: 2 in seg50, 1 trailing for seg51
        XCTAssertEqual(manifest.parts.count, 3)

        // Trailing parts
        XCTAssertEqual(manifest.trailingParts.count, 1)
        XCTAssertEqual(manifest.trailingParts[0].uri.absoluteString, "https://example.com/video/seg51.part0.ts?session=redacted")

        // Preload hint
        XCTAssertEqual(manifest.preloadHints.count, 1)
    }

    func testLLHLSPlaylistWithOnlyPreloadHintSynthesizesSegment() throws {
        let playlist = """
        #EXTM3U
        #EXT-X-VERSION:6
        #EXT-X-TARGETDURATION:2
        #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES
        #EXT-X-PART-INF:PART-TARGET=0.5
        #EXT-X-MEDIA-SEQUENCE:1
        #EXT-X-PRELOAD-HINT:TYPE=PART,URI="part0.ts"
        """

        let manifest = try HLSManifestParser.parse(playlist, baseURL: hlsURL)
        XCTAssertEqual(manifest.playlistType, .media)
        XCTAssertTrue(manifest.isLowLatency)
        XCTAssertTrue(manifest.hasSynthesizedSegmentsFromParts)
        XCTAssertEqual(manifest.segments.count, 1)
        XCTAssertEqual(manifest.segments[0].uri.absoluteString, "https://example.com/video/part0.ts?session=redacted")
        XCTAssertEqual(manifest.segments[0].duration, 0.5, accuracy: 0.001)
    }

    func testStreamingManifestClassifierClassifiesLLHLSQueriesAndContent() {
        let llHlsURL = URL(string: "https://example.com/live/stream?_HLS_msn=100&_HLS_part=2")!
        let classification = StreamingManifestClassifier.classify(url: llHlsURL)
        XCTAssertEqual(classification.kind, .hls)

        let llHlsContent = """
        #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES
        #EXT-X-PART:DURATION=0.5,URI="part0.ts"
        """
        let contentClassification = StreamingManifestClassifier.classify(url: dashURL, content: llHlsContent)
        XCTAssertEqual(contentClassification.kind, .hls)
    }

    func testLLHLSValidationErrors() {
        let missingURI = """
        #EXTM3U
        #EXT-X-VERSION:6
        #EXT-X-PART:DURATION=0.5
        """
        XCTAssertThrowsError(try HLSManifestParser.parse(missingURI, baseURL: hlsURL)) { error in
            guard case ManifestParserError.malformed(let reason) = error else {
                XCTFail("Expected malformed error, got: \(error)")
                return
            }
            XCTAssertTrue(reason.contains("requires a valid URI"))
        }

        let missingDuration = """
        #EXTM3U
        #EXT-X-VERSION:6
        #EXT-X-PART:URI="part.ts"
        """
        XCTAssertThrowsError(try HLSManifestParser.parse(missingDuration, baseURL: hlsURL)) { error in
            guard case ManifestParserError.malformed(let reason) = error else {
                XCTFail("Expected malformed error, got: \(error)")
                return
            }
            XCTAssertTrue(reason.contains("requires a non-negative DURATION"))
        }

        let invalidPreloadHint = """
        #EXTM3U
        #EXT-X-VERSION:6
        #EXT-X-PRELOAD-HINT:TYPE=UNKNOWN,URI="part.ts"
        """
        XCTAssertThrowsError(try HLSManifestParser.parse(invalidPreloadHint, baseURL: hlsURL)) { error in
            guard case ManifestParserError.malformed(let reason) = error else {
                XCTFail("Expected malformed error, got: \(error)")
                return
            }
            XCTAssertTrue(reason.contains("requires a valid TYPE"))
        }
    }

    func testHLSMasterPlaylistSkipsMalformedVariantAndKeepsValidVariants() throws {
        let manifest = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080
        1080p.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=not-a-number,RESOLUTION=1280x720
        720p_bad.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=badxres
        480p_bad.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
        360p.m3u8
        """
        let parsed = try HLSManifestParser.parse(manifest, baseURL: hlsURL)
        XCTAssertEqual(parsed.playlistType, .master)
        XCTAssertEqual(parsed.variants.count, 2)
        XCTAssertEqual(parsed.variants[0].bandwidth, 5000000)
        XCTAssertEqual(parsed.variants[0].resolution?.width, 1920)
        XCTAssertEqual(parsed.variants[0].uri.lastPathComponent, "1080p.m3u8")
        XCTAssertEqual(parsed.variants[1].bandwidth, 800000)
        XCTAssertEqual(parsed.variants[1].resolution?.width, 640)
        XCTAssertEqual(parsed.variants[1].uri.lastPathComponent, "360p.m3u8")
    }

    func testHLSMasterPlaylistSkipsMalformedTagAttributesAndKeepsValidVariants() throws {
        let manifest = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH="unterminated
        bad_attr.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=1280x720
        720p.m3u8
        """
        let parsed = try HLSManifestParser.parse(manifest, baseURL: hlsURL)
        XCTAssertEqual(parsed.playlistType, .master)
        XCTAssertEqual(parsed.variants.count, 1)
        XCTAssertEqual(parsed.variants[0].bandwidth, 3000000)
        XCTAssertEqual(parsed.variants[0].uri.lastPathComponent, "720p.m3u8")
    }

    func testHLSMasterPlaylistSkipsMalformedIFrameVariantsAndKeepsValidVariants() throws {
        let manifest = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080
        1080p.m3u8
        #EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=500000,RESOLUTION=1920x1080
        #EXT-X-I-FRAME-STREAM-INF:URI="iframe.m3u8",BANDWIDTH=0
        #EXT-X-I-FRAME-STREAM-INF:URI="iframe_valid.m3u8",BANDWIDTH=600000,RESOLUTION=1280x720
        """
        let parsed = try HLSManifestParser.parse(manifest, baseURL: hlsURL)
        XCTAssertEqual(parsed.playlistType, .master)
        XCTAssertEqual(parsed.variants.count, 2)
        XCTAssertEqual(parsed.variants[0].bandwidth, 5000000)
        XCTAssertFalse(parsed.variants[0].isIFrameOnly)
        XCTAssertEqual(parsed.variants[1].bandwidth, 600000)
        XCTAssertTrue(parsed.variants[1].isIFrameOnly)
        XCTAssertEqual(parsed.variants[1].uri.lastPathComponent, "iframe_valid.m3u8")
    }

    func testHLSMasterPlaylistAllVariantsMalformedFailsActionably() {
        let allMalformed = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=-500,RESOLUTION=1920x1080
        1080p.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=0,RESOLUTION=1280x720
        720p.m3u8
        """
        XCTAssertThrowsError(try HLSManifestParser.parse(allMalformed, baseURL: hlsURL)) { error in
            XCTAssertTrue(error.localizedDescription.contains("BANDWIDTH"))
        }
    }

    func testHLSVariantDeduplicationPreservesCaseSensitiveDistinctPlaylists() {
        let variantA = HLSVariant(
            uri: URL(string: "https://cdn.example.com/hls/Stream_720p.m3u8?token=AbC")!,
            bandwidth: 2000000,
            resolution: HLSResolution(width: 1280, height: 720),
            codecs: "avc1.4d401f"
        )
        let variantB = HLSVariant(
            uri: URL(string: "https://cdn.example.com/hls/stream_720p.m3u8?token=AbC")!,
            bandwidth: 2500000,
            resolution: HLSResolution(width: 1920, height: 1080),
            codecs: "avc1.640028"
        )
        let variantC = HLSVariant(
            uri: URL(string: "https://cdn.example.com/hls/stream_720p.m3u8?token=abc")!,
            bandwidth: 1500000,
            resolution: HLSResolution(width: 854, height: 480),
            codecs: "avc1.4d401e"
        )
        // Truly duplicate URI with uppercase scheme and host
        let variantDuplicate = HLSVariant(
            uri: URL(string: "HTTPS://CDN.EXAMPLE.COM/hls/Stream_720p.m3u8?token=AbC")!,
            bandwidth: 3000000,
            resolution: HLSResolution(width: 2560, height: 1440),
            codecs: "avc1.64002a"
        )

        let deduplicated = HLSVariantSelector.deduplicate([variantA, variantB, variantC, variantDuplicate])
        // variantDuplicate has identical canonical URI to variantA (differing only in scheme/host case),
        // so it must be deduplicated out.
        // variantA, variantB, and variantC have case-differing paths/queries and must all be retained.
        XCTAssertEqual(deduplicated.count, 3)
        XCTAssertTrue(deduplicated.contains(where: { $0.uri.absoluteString == "https://cdn.example.com/hls/Stream_720p.m3u8?token=AbC" }))
        XCTAssertTrue(deduplicated.contains(where: { $0.uri.absoluteString == "https://cdn.example.com/hls/stream_720p.m3u8?token=AbC" }))
        XCTAssertTrue(deduplicated.contains(where: { $0.uri.absoluteString == "https://cdn.example.com/hls/stream_720p.m3u8?token=abc" }))
    }

    func testHLSMasterPlaylistDeduplicationWithCaseSensitiveURLs() throws {
        let master = """
        #EXTM3U
        #EXT-X-VERSION:4
        #EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=1920x1080,CODECS="avc1.640028"
        https://cdn.example.com/live/Stream_A/playlist.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720,CODECS="avc1.4d401f"
        https://cdn.example.com/live/stream_a/playlist.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=854x480,CODECS="avc1.4d401f"
        HTTPS://CDN.EXAMPLE.COM/live/stream_a/playlist.m3u8
        """
        let parsed = try HLSManifestParser.parse(master, baseURL: URL(string: "https://cdn.example.com/live/master.m3u8")!)
        let ranked = try HLSVariantSelector.rank(from: parsed, deduplicate: true)
        XCTAssertEqual(ranked.count, 2)
        XCTAssertEqual(ranked[0].uri.absoluteString, "https://cdn.example.com/live/Stream_A/playlist.m3u8")
        XCTAssertEqual(ranked[1].uri.absoluteString, "https://cdn.example.com/live/stream_a/playlist.m3u8")
    }
}
