import Foundation
import XCTest
@testable import DM_Reverse_engineering

final class DASHTransferPlannerTests: XCTestCase {

    private let manifestURL = URL(string: "https://video.example/path/manifest.mpd?sig=manifest-signed")!

    func testSegmentTemplateAndSegmentListProduceSeparateAudioAndVideoPlans() throws {
        let mpd = """
        <MPD type="static" mediaPresentationDuration="PT6S">
          <Period id="p0" duration="PT6S">
            <BaseURL>period/</BaseURL>
            <AdaptationSet id="video" contentType="video" mimeType="video/mp4" codecs="avc1">
              <Representation id="v1" bandwidth="1000">
                <BaseURL>video/</BaseURL>
                <SegmentTemplate timescale="1" duration="2" startNumber="5" initialization="init-$RepresentationID$.mp4" media="seg-$RepresentationID$-$Number$-$Bandwidth$.m4s"/>
              </Representation>
            </AdaptationSet>
            <AdaptationSet id="audio" contentType="audio" mimeType="audio/mp4" codecs="mp4a">
              <Representation id="a1" bandwidth="64">
                <SegmentList timescale="1" duration="2" startNumber="1">
                  <Initialization sourceURL="audio-init.mp4" range="0-99"/>
                  <SegmentURL media="audio-1.m4s" mediaRange="100-199"/>
                  <SegmentURL media="audio-2.m4s" mediaRange="200-299"/>
                </SegmentList>
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """

        let manifest = try DASHManifestParser.parse(mpd, baseURL: manifestURL)
        let plan = try DASHTransferPlanner.makeVODPlan(
            from: manifest,
            videoRepresentationID: "v1",
            audioRepresentationID: "a1"
        )

        XCTAssertEqual(plan.video?.resources.map(\.kind), [.initialization, .mediaSegment, .mediaSegment, .mediaSegment])
        XCTAssertEqual(plan.video?.resources.map(\.segmentNumber), [nil, 5, 6, 7])
        XCTAssertEqual(plan.video?.resources[0].url.absoluteString, "https://video.example/path/period/video/init-v1.mp4")
        XCTAssertEqual(plan.video?.resources[3].url.absoluteString, "https://video.example/path/period/video/seg-v1-7-1000.m4s")
        XCTAssertEqual(plan.video?.estimatedDurationSeconds, 6)

        XCTAssertEqual(plan.audio?.resources.map(\.kind), [.initialization, .mediaSegment, .mediaSegment])
        XCTAssertEqual(plan.audio?.resources[0].byteRange, DASHByteRange(start: 0, end: 99))
        XCTAssertEqual(plan.audio?.resources[1].byteRange, DASHByteRange(start: 100, end: 199))
        XCTAssertEqual(plan.audio?.estimatedTransferBytes, 300)
        XCTAssertEqual(plan.resources.count, 7)
    }

    func testSegmentTimelineExpandsRepeatedAndBoundedNegativeEntries() throws {
        let mpd = """
        <MPD type="static">
          <Period id="timeline" duration="PT6S">
            <AdaptationSet contentType="video" mimeType="video/mp4">
              <Representation id="timeline-video" bandwidth="10">
                <SegmentTemplate timescale="1" initialization="init.mp4" media="chunk-$Time$.m4s">
                  <SegmentTimeline>
                    <S t="0" d="2" r="1"/>
                    <S d="2" r="-1"/>
                  </SegmentTimeline>
                </SegmentTemplate>
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """

        let manifest = try DASHManifestParser.parse(mpd, baseURL: manifestURL)
        let plan = try DASHTransferPlanner.makeVODPlan(from: manifest)
        let media = try XCTUnwrap(plan.video?.resources.filter { $0.kind == .mediaSegment })

        XCTAssertEqual(media.map(\.segmentTime), [0, 2, 4])
        XCTAssertEqual(media.map(\.url.absoluteString), [
            "https://video.example/path/chunk-0.m4s",
            "https://video.example/path/chunk-2.m4s",
            "https://video.example/path/chunk-4.m4s"
        ])
    }

    func testSignedQueriesSurviveResolutionAndCrossOriginCredentialsAreStripped() throws {
        let mpd = """
        <MPD type="static">
          <Period duration="PT2S">
            <BaseURL>https://cdn.example/media/?base=signed</BaseURL>
            <AdaptationSet contentType="video" mimeType="video/mp4">
              <Representation id="v" bandwidth="1">
                <SegmentTemplate duration="2" initialization="init.mp4?sig=init-signed" media="segment-$Number$.m4s?sig=segment-signed"/>
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """
        let context = BrowserRequestContext(
            url: manifestURL,
            pageURL: URL(string: "https://video.example/watch")!,
            userAgent: "BrowserTest/1.0",
            cookies: [BrowserCookie(name: "session", value: "cookie-secret", domain: "video.example")],
            customHeaders: ["Authorization": "Bearer header-secret", "X-Trace-ID": "safe"]
        )

        let manifest = try DASHManifestParser.parse(mpd, baseURL: manifestURL)
        let plan = try DASHTransferPlanner.makeVODPlan(from: manifest, browserRequestContext: context)
        let resource = try XCTUnwrap(plan.video?.resources.first(where: { $0.kind == .mediaSegment }))
        let headers = plan.requestHeaders(for: resource)

        XCTAssertTrue(resource.url.absoluteString.contains("sig=segment-signed"))
        XCTAssertNil(headers["Cookie"])
        XCTAssertNil(headers["Authorization"])
        XCTAssertNil(headers["Referer"])
        XCTAssertEqual(headers["X-Trace-ID"], "safe")
    }

    func testPlannerRejectsDynamicDRMMalformedMissingAndUnboundedContent() throws {
        let dynamic = DASHManifest(
            url: manifestURL,
            presentationType: .dynamicPresentation,
            periods: []
        )
        XCTAssertThrowsError(try DASHTransferPlanner.makeVODPlan(from: dynamic)) { error in
            XCTAssertEqual(error as? DASHVODTransferPlanError, .dynamicMPD)
        }

        let drmMPD = """
        <MPD type="static">
          <Period duration="PT2S">
            <AdaptationSet contentType="video" mimeType="video/mp4">
              <ContentProtection schemeIdUri="urn:uuid:example"/>
              <Representation id="drm" bandwidth="1">
                <SegmentTemplate duration="2" initialization="init.mp4" media="segment-$Number$.m4s"/>
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """
        let drm = try DASHManifestParser.parse(drmMPD, baseURL: manifestURL)
        XCTAssertThrowsError(try DASHTransferPlanner.makeVODPlan(from: drm)) { error in
            XCTAssertEqual(error as? DASHVODTransferPlanError, .drmProtectedRepresentation)
        }

        let malformedMPD = """
        <MPD type="static">
          <Period duration="PT2S">
            <AdaptationSet contentType="video" mimeType="video/mp4">
              <Representation id="bad" bandwidth="1">
                <SegmentTemplate duration="2" initialization="init.mp4" media="segment-$Unknown$.m4s"/>
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """
        let malformed = try DASHManifestParser.parse(malformedMPD, baseURL: manifestURL)
        XCTAssertThrowsError(try DASHTransferPlanner.makeVODPlan(from: malformed)) { error in
            XCTAssertEqual(error as? DASHVODTransferPlanError, .malformedTemplate)
        }

        let unbounded = DASHManifest(
            url: manifestURL,
            presentationType: .staticPresentation,
            periods: [DASHPeriod(
                duration: 2,
                baseURL: manifestURL,
                adaptationSets: [DASHAdaptationSet(
                    contentType: "video",
                    mimeType: "video/mp4",
                    baseURL: manifestURL,
                    representations: [DASHRepresentation(
                        id: "unbounded",
                        bandwidth: 1,
                        baseURL: manifestURL,
                        segmentTemplate: DASHSegmentTemplate(media: "segment-$Number$.m4s", initialization: "init.mp4")
                    )]
                )]
            )]
        )
        XCTAssertThrowsError(try DASHTransferPlanner.makeVODPlan(from: unbounded)) { error in
            XCTAssertEqual(error as? DASHVODTransferPlanError, .unboundedTimeline)
        }
    }

    func testPlannerBoundsTimelineExpansionAndRejectsUnsafeAddressing() throws {
        let bounded = DASHManifest(
            url: manifestURL,
            presentationType: .staticPresentation,
            periods: [DASHPeriod(
                duration: 2,
                baseURL: manifestURL,
                adaptationSets: [DASHAdaptationSet(
                    contentType: "video",
                    mimeType: "video/mp4",
                    baseURL: manifestURL,
                    representations: [DASHRepresentation(
                        id: "bounded",
                        bandwidth: 1,
                        baseURL: manifestURL,
                        segmentTemplate: DASHSegmentTemplate(
                            media: "segment-$Number$.m4s",
                            initialization: "init.mp4",
                            timeline: [DASHSegmentTimelineEntry(start: 0, duration: 1, repeatCount: 10)]
                        )
                    )]
                )]
            )]
        )
        XCTAssertThrowsError(try DASHTransferPlanner.makeVODPlan(
            from: bounded,
            limits: DASHTransferPlanningLimits(maxSegmentsPerRepresentation: 3, maxTotalSegments: 3)
        )) { error in
            XCTAssertEqual(error as? DASHVODTransferPlanError, .timelineExpansionLimitExceeded)
        }

        let unsafe = DASHManifest(
            url: manifestURL,
            presentationType: .staticPresentation,
            periods: [DASHPeriod(
                duration: 2,
                baseURL: URL(string: "file:///private/manifest")!,
                adaptationSets: [DASHAdaptationSet(
                    contentType: "video",
                    mimeType: "video/mp4",
                    baseURL: URL(string: "file:///private/media")!,
                    representations: [DASHRepresentation(
                        id: "unsafe",
                        bandwidth: 1,
                        baseURL: URL(string: "file:///private/media")!,
                        segmentTemplate: DASHSegmentTemplate(media: "segment-$Number$.m4s", initialization: "init.mp4", duration: 2)
                    )]
                )]
            )]
        )
        XCTAssertThrowsError(try DASHTransferPlanner.makeVODPlan(from: unsafe)) { error in
            XCTAssertEqual(error as? DASHVODTransferPlanError, .invalidResourceURL)
        }
    }

    func testHighestBitrateRepresentationAutoSelectionAndMPDParserAlias() throws {
        let multiQualityMPD = """
        <MPD type="static" mediaPresentationDuration="PT4S">
          <Period id="p0" duration="PT4S">
            <AdaptationSet id="video" contentType="video" mimeType="video/mp4" codecs="avc1">
              <Representation id="v_360p" bandwidth="800000" width="640" height="360">
                <SegmentTemplate timescale="1" duration="2" initialization="init-360p.mp4" media="seg-360p-$Number$.m4s"/>
              </Representation>
              <Representation id="v_1080p" bandwidth="5000000" width="1920" height="1080">
                <SegmentTemplate timescale="1" duration="2" initialization="init-1080p.mp4" media="seg-1080p-$Number$.m4s"/>
              </Representation>
              <Representation id="v_720p" bandwidth="2500000" width="1280" height="720">
                <SegmentTemplate timescale="1" duration="2" initialization="init-720p.mp4" media="seg-720p-$Number$.m4s"/>
              </Representation>
            </AdaptationSet>
            <AdaptationSet id="audio" contentType="audio" mimeType="audio/mp4" codecs="mp4a">
              <Representation id="a_low" bandwidth="64000">
                <SegmentTemplate timescale="1" duration="2" initialization="audio-low.mp4" media="audio-low-$Number$.m4s"/>
              </Representation>
              <Representation id="a_high" bandwidth="256000">
                <SegmentTemplate timescale="1" duration="2" initialization="audio-high.mp4" media="audio-high-$Number$.m4s"/>
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """

        let manifest = try MPDManifestParser.parse(multiQualityMPD, baseURL: manifestURL)
        let plan = try DASHTransferPlanner.makeVODPlan(from: manifest)

        // Verifies highest bitrate is automatically selected (1080p @ 5Mbps for video, 256kbps for audio)
        XCTAssertEqual(plan.video?.representationID, "v_1080p")
        XCTAssertEqual(plan.video?.bandwidth, 5000000)
        XCTAssertEqual(plan.video?.resources.first?.url.absoluteString, "https://video.example/path/init-1080p.mp4")

        XCTAssertEqual(plan.audio?.representationID, "a_high")
        XCTAssertEqual(plan.audio?.bandwidth, 256000)
        XCTAssertEqual(plan.audio?.resources.first?.url.absoluteString, "https://video.example/path/audio-high.mp4")
    }
}
