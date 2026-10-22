import Foundation
import XCTest
@testable import DM_Reverse_engineering

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
        XCTAssertEqual(manifest.variants[0].uri.absoluteString, "https://example.com/video/variants/720p.m3u8?token=private")
        XCTAssertEqual(manifest.renditions.first?.uri?.absoluteString, "https://example.com/video/audio/index.m3u8?lang=en")
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
        XCTAssertEqual(manifest.segments[0].initializationMap?.uri.absoluteString, "https://example.com/video/init.mp4")
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
}
