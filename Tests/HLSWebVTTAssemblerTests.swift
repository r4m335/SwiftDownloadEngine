import XCTest
@testable import DownloadEngineKit

final class HLSWebVTTAssemblerTests: XCTestCase {

    func testParseTimestampValidFormats() {
        XCTAssertEqual(HLSWebVTTAssembler.parseTimestamp("00:00.000"), 0.0)
        XCTAssertEqual(HLSWebVTTAssembler.parseTimestamp("00:01.500"), 1.5)
        XCTAssertEqual(HLSWebVTTAssembler.parseTimestamp("01:23.456"), 83.456)
        XCTAssertEqual(HLSWebVTTAssembler.parseTimestamp("00:00:01.500"), 1.5)
        XCTAssertEqual(HLSWebVTTAssembler.parseTimestamp("01:02:03.456"), 3723.456)
        XCTAssertEqual(HLSWebVTTAssembler.parseTimestamp("00:01,500"), 1.5)
        XCTAssertNil(HLSWebVTTAssembler.parseTimestamp("invalid"))
    }

    func testFormatTimestamp() {
        XCTAssertEqual(HLSWebVTTAssembler.formatTimestamp(0.0), "00:00:00.000")
        XCTAssertEqual(HLSWebVTTAssembler.formatTimestamp(1.5), "00:00:01.500")
        XCTAssertEqual(HLSWebVTTAssembler.formatTimestamp(83.456), "00:01:23.456")
        XCTAssertEqual(HLSWebVTTAssembler.formatTimestamp(3723.456), "01:02:03.456")
        XCTAssertEqual(HLSWebVTTAssembler.formatTimestamp(-5.0), "00:00:00.000")
    }

    func testParseTimestampMapHeader() {
        let line1 = "X-TIMESTAMP-MAP=MPEGTS:900000,LOCAL:00:00:00.000"
        let map1 = HLSWebVTTAssembler.parseTimestampMap(from: line1)
        XCTAssertNotNil(map1)
        XCTAssertEqual(map1?.mpegTS, 900_000)
        XCTAssertEqual(map1?.localTime, 0.0)

        let line2 = "X-TIMESTAMP-MAP=LOCAL:00:01:10.500,MPEGTS:1800000"
        let map2 = HLSWebVTTAssembler.parseTimestampMap(from: line2)
        XCTAssertNotNil(map2)
        XCTAssertEqual(map2?.mpegTS, 1_800_000)
        XCTAssertEqual(map2?.localTime, 70.5)

        let line3 = "X-TIMESTAMP-MAP = MPEGTS: 2700000 , LOCAL: 00:00.000 "
        let map3 = HLSWebVTTAssembler.parseTimestampMap(from: line3)
        XCTAssertNotNil(map3)
        XCTAssertEqual(map3?.mpegTS, 2_700_000)
        XCTAssertEqual(map3?.localTime, 0.0)

        let line4 = "NOTE comment"
        XCTAssertNil(HLSWebVTTAssembler.parseTimestampMap(from: line4))
    }

    func testMultiSegmentWithTimestampMapShiftsCuesCorrectly() {
        let seg1 = """
        WEBVTT
        X-TIMESTAMP-MAP=MPEGTS:900000,LOCAL:00:00:00.000

        00:00:01.000 --> 00:00:04.000
        First segment cue
        """

        let seg2 = """
        WEBVTT
        X-TIMESTAMP-MAP=MPEGTS:1800000,LOCAL:00:00:00.000

        00:00:02.000 --> 00:00:05.000
        Second segment cue
        """

        let assembled = HLSWebVTTAssembler.assemble(segments: [
            WebVTTSegmentInput(text: seg1, playlistStartTime: 0.0, duration: 10.0),
            WebVTTSegmentInput(text: seg2, playlistStartTime: 10.0, duration: 10.0)
        ])

        XCTAssertTrue(assembled.hasPrefix("WEBVTT"))
        XCTAssertTrue(assembled.contains("00:00:01.000 --> 00:00:04.000"))
        XCTAssertTrue(assembled.contains("First segment cue"))

        // Segment 2 cue must be shifted by +10.0s (PTS delta 900,000 / 90,000)
        XCTAssertTrue(assembled.contains("00:00:12.000 --> 00:00:15.000"), "Segment 2 cue must be shifted by +10s")
        XCTAssertTrue(assembled.contains("Second segment cue"))
        XCTAssertFalse(assembled.contains("00:00:02.000 --> 00:00:05.000"), "Unshifted repeated local cue time must not be present")
    }

    func testMultiSegmentWithTimestampMapWhereLocalIsAlreadyOffset() {
        let seg1 = """
        WEBVTT
        X-TIMESTAMP-MAP=MPEGTS:900000,LOCAL:00:00:00.000

        00:00:01.000 --> 00:00:04.000
        First segment cue
        """

        let seg2 = """
        WEBVTT
        X-TIMESTAMP-MAP=MPEGTS:1800000,LOCAL:00:00:10.000

        00:00:12.000 --> 00:00:15.000
        Second segment cue
        """

        let assembled = HLSWebVTTAssembler.assemble(segments: [
            WebVTTSegmentInput(text: seg1, playlistStartTime: 0.0, duration: 10.0),
            WebVTTSegmentInput(text: seg2, playlistStartTime: 10.0, duration: 10.0)
        ])

        // Must not double shift
        XCTAssertTrue(assembled.contains("00:00:12.000 --> 00:00:15.000"))
        XCTAssertFalse(assembled.contains("00:00:22.000 --> 00:00:25.000"))
    }

    func testMultiSegmentWithoutTimestampMapShiftsSegmentRelativeCues() {
        let seg1 = """
        WEBVTT

        00:00:02.000 --> 00:00:05.000
        Cue in segment 1
        """

        let seg2 = """
        WEBVTT

        00:00:01.000 --> 00:00:04.000
        Cue in segment 2
        """

        let assembled = HLSWebVTTAssembler.assemble(segments: [
            WebVTTSegmentInput(text: seg1, playlistStartTime: 0.0, duration: 10.0),
            WebVTTSegmentInput(text: seg2, playlistStartTime: 10.0, duration: 10.0)
        ])

        XCTAssertTrue(assembled.contains("00:00:02.000 --> 00:00:05.000"))
        // Segment 2 started at 10.0s, so 1.0s -> 11.0s and 4.0s -> 14.0s
        XCTAssertTrue(assembled.contains("00:00:11.000 --> 00:00:14.000"))
        XCTAssertFalse(assembled.contains("00:00:01.000 --> 00:00:04.000"))
    }

    func testMultiSegmentWithoutTimestampMapPreservesAlreadyAbsoluteCues() {
        let seg1 = """
        WEBVTT

        00:00:02.000 --> 00:00:05.000
        Cue in segment 1
        """

        let seg2 = """
        WEBVTT

        00:00:12.000 --> 00:00:15.000
        Cue in segment 2
        """

        let assembled = HLSWebVTTAssembler.assemble(segments: [
            WebVTTSegmentInput(text: seg1, playlistStartTime: 0.0, duration: 10.0),
            WebVTTSegmentInput(text: seg2, playlistStartTime: 10.0, duration: 10.0)
        ])

        XCTAssertTrue(assembled.contains("00:00:02.000 --> 00:00:05.000"))
        XCTAssertTrue(assembled.contains("00:00:12.000 --> 00:00:15.000"))
        XCTAssertFalse(assembled.contains("00:00:22.000 --> 00:00:25.000"))
    }

    func testSpanningCueAcrossSegmentBoundaryIsMerged() {
        let seg1 = """
        WEBVTT
        X-TIMESTAMP-MAP=MPEGTS:900000,LOCAL:00:00:00.000

        00:00:08.000 --> 00:00:12.000
        Spanning speech across segments
        """

        // In segment 2 (starting at 10s), the same speech was active from local 0s to 2s (10s to 12s in presentation time)
        let seg2 = """
        WEBVTT
        X-TIMESTAMP-MAP=MPEGTS:1800000,LOCAL:00:00:00.000

        00:00:00.000 --> 00:00:02.000
        Spanning speech across segments
        """

        let assembled = HLSWebVTTAssembler.assemble(segments: [
            WebVTTSegmentInput(text: seg1, playlistStartTime: 0.0, duration: 10.0),
            WebVTTSegmentInput(text: seg2, playlistStartTime: 10.0, duration: 10.0)
        ])

        // There should be only ONE merged cue covering 00:00:08.000 to 00:00:12.000
        let occurrences = assembled.components(separatedBy: "Spanning speech across segments").count - 1
        XCTAssertEqual(occurrences, 1, "Spanning cue must be merged into a single cue without duplicate occurrences")
        XCTAssertTrue(assembled.contains("00:00:08.000 --> 00:00:12.000"))
    }

    func testRepeatedIdenticalCuesAreDeduplicated() {
        let seg1 = """
        WEBVTT
        X-TIMESTAMP-MAP=MPEGTS:900000,LOCAL:00:00:00.000

        00:00:08.000 --> 00:00:12.000
        Identical cue
        """

        let seg2 = """
        WEBVTT
        X-TIMESTAMP-MAP=MPEGTS:900000,LOCAL:00:00:00.000

        00:00:08.000 --> 00:00:12.000
        Identical cue
        """

        let assembled = HLSWebVTTAssembler.assemble(segments: [
            WebVTTSegmentInput(text: seg1, playlistStartTime: 0.0, duration: 10.0),
            WebVTTSegmentInput(text: seg2, playlistStartTime: 10.0, duration: 10.0)
        ])

        let occurrences = assembled.components(separatedBy: "Identical cue").count - 1
        XCTAssertEqual(occurrences, 1)
    }

    func testPTS33BitRolloverHandled() {
        // MPEGTS ticks near 2^33 (8,589,934,592): 1 second (90,000 ticks) before 33-bit rollover
        let ptsNearRollover: Int64 = 8_589_934_592 - 90_000
        // Segment 2 PTS wrapped around: 10 seconds (900,000 ticks) after segment 1
        let ptsAfterRollover: Int64 = 810_000

        let seg1 = """
        WEBVTT
        X-TIMESTAMP-MAP=MPEGTS:\(ptsNearRollover),LOCAL:00:00:00.000

        00:00:01.000 --> 00:00:04.000
        Before rollover
        """

        let seg2 = """
        WEBVTT
        X-TIMESTAMP-MAP=MPEGTS:\(ptsAfterRollover),LOCAL:00:00:00.000

        00:00:02.000 --> 00:00:05.000
        After rollover
        """

        let assembled = HLSWebVTTAssembler.assemble(segments: [
            WebVTTSegmentInput(text: seg1, playlistStartTime: 0.0, duration: 10.0),
            WebVTTSegmentInput(text: seg2, playlistStartTime: 10.0, duration: 10.0)
        ])

        XCTAssertTrue(assembled.contains("Before rollover"))
        XCTAssertTrue(assembled.contains("After rollover"))
        // After rollover, cue should be at 12.0s to 15.0s, not negative or early
        XCTAssertTrue(assembled.contains("00:00:12.000 --> 00:00:15.000"))
    }

    func testPreservesCueSettings() {
        let seg = """
        WEBVTT

        00:00:01.000 --> 00:00:04.000 line:50% position:20% align:start
        Custom positioned cue
        """

        let assembled = HLSWebVTTAssembler.assemble(segments: [
            WebVTTSegmentInput(text: seg, playlistStartTime: 0.0, duration: 5.0)
        ])

        XCTAssertTrue(assembled.contains("line:50% position:20% align:start"))
    }
}
