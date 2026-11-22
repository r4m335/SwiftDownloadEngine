import Foundation
import XCTest
@testable import DownloadEngineKit

final class DASHMultiPeriodAndSegmentBaseTests: XCTestCase {

    private let manifestURL = URL(string: "https://streaming.example/vod/dash/manifest.mpd")!

    // MARK: - Multi-Period Tests

    func testMultiPeriodManifestProducesUnifiedSequentialPlans() throws {
        let multiPeriodMPD = """
        <MPD type="static" mediaPresentationDuration="PT10S">
          <Period id="period-1" duration="PT4S">
            <AdaptationSet id="v-set" contentType="video" mimeType="video/mp4" codecs="avc1">
              <Representation id="v1" bandwidth="2000000">
                <SegmentTemplate timescale="1" duration="2" initialization="init-v1.mp4" media="p1-seg-$Number$.m4s"/>
              </Representation>
            </AdaptationSet>
            <AdaptationSet id="a-set" contentType="audio" mimeType="audio/mp4" codecs="mp4a">
              <Representation id="a1" bandwidth="128000">
                <SegmentTemplate timescale="1" duration="2" initialization="init-a1.mp4" media="p1-audio-$Number$.m4s"/>
              </Representation>
            </AdaptationSet>
          </Period>
          <Period id="period-2" duration="PT6S">
            <AdaptationSet id="v-set" contentType="video" mimeType="video/mp4" codecs="avc1">
              <Representation id="v1" bandwidth="2000000">
                <SegmentTemplate timescale="1" duration="2" initialization="init-v1.mp4" media="p2-seg-$Number$.m4s"/>
              </Representation>
            </AdaptationSet>
            <AdaptationSet id="a-set" contentType="audio" mimeType="audio/mp4" codecs="mp4a">
              <Representation id="a1" bandwidth="128000">
                <SegmentTemplate timescale="1" duration="2" initialization="init-a1.mp4" media="p2-audio-$Number$.m4s"/>
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """

        let manifest = try DASHManifestParser.parse(multiPeriodMPD, baseURL: manifestURL)
        XCTAssertEqual(manifest.periods.count, 2)
        XCTAssertEqual(manifest.periods[0].duration, 4.0)
        XCTAssertEqual(manifest.periods[1].duration, 6.0)

        let plan = try DASHTransferPlanner.makeVODPlan(from: manifest)

        // Video plan verification:
        // Period 1 (4s, duration=2s): 2 media segments + 1 initialization segment
        // Period 2 (6s, duration=2s): 3 media segments
        // Total video resources: 1 init + 5 media = 6 resources
        let videoResources = try XCTUnwrap(plan.video?.resources)
        XCTAssertEqual(videoResources.count, 6)
        XCTAssertEqual(videoResources[0].kind, .initialization)
        XCTAssertEqual(videoResources[0].order, 0)
        XCTAssertEqual(videoResources[0].url.lastPathComponent, "init-v1.mp4")

        XCTAssertEqual(videoResources[1].kind, .mediaSegment)
        XCTAssertEqual(videoResources[1].order, 1)
        XCTAssertEqual(videoResources[1].url.lastPathComponent, "p1-seg-1.m4s")

        XCTAssertEqual(videoResources[2].kind, .mediaSegment)
        XCTAssertEqual(videoResources[2].order, 2)
        XCTAssertEqual(videoResources[2].url.lastPathComponent, "p1-seg-2.m4s")

        XCTAssertEqual(videoResources[3].kind, .mediaSegment)
        XCTAssertEqual(videoResources[3].order, 3)
        XCTAssertEqual(videoResources[3].url.lastPathComponent, "p2-seg-1.m4s")

        XCTAssertEqual(videoResources[4].kind, .mediaSegment)
        XCTAssertEqual(videoResources[4].order, 4)
        XCTAssertEqual(videoResources[4].url.lastPathComponent, "p2-seg-2.m4s")

        XCTAssertEqual(videoResources[5].kind, .mediaSegment)
        XCTAssertEqual(videoResources[5].order, 5)
        XCTAssertEqual(videoResources[5].url.lastPathComponent, "p2-seg-3.m4s")

        XCTAssertEqual(plan.video?.estimatedDurationSeconds, 10.0)
        XCTAssertEqual(plan.video?.estimatedSegmentCount, 5)

        // Audio plan verification:
        let audioResources = try XCTUnwrap(plan.audio?.resources)
        XCTAssertEqual(audioResources.count, 6)
        XCTAssertEqual(audioResources[0].kind, .initialization)
        XCTAssertEqual(audioResources[0].order, 0)
        XCTAssertEqual(audioResources[0].url.lastPathComponent, "init-a1.mp4")
        XCTAssertEqual(plan.audio?.estimatedDurationSeconds, 10.0)
        XCTAssertEqual(plan.audio?.estimatedSegmentCount, 5)
    }

    func testMultiPeriodDurationDerivedFromPeriodStarts() throws {
        let mpd = """
        <MPD type="static" mediaPresentationDuration="PT15S">
          <Period id="p1" start="PT0S">
            <AdaptationSet contentType="video" mimeType="video/mp4" codecs="avc1">
              <Representation id="v1" bandwidth="1000">
                <SegmentTemplate timescale="1" duration="5" initialization="init.mp4" media="p1-$Number$.m4s"/>
              </Representation>
            </AdaptationSet>
          </Period>
          <Period id="p2" start="PT5S">
            <AdaptationSet contentType="video" mimeType="video/mp4" codecs="avc1">
              <Representation id="v1" bandwidth="1000">
                <SegmentTemplate timescale="1" duration="5" initialization="init.mp4" media="p2-$Number$.m4s"/>
              </Representation>
            </AdaptationSet>
          </Period>
          <Period id="p3" start="PT10S">
            <AdaptationSet contentType="video" mimeType="video/mp4" codecs="avc1">
              <Representation id="v1" bandwidth="1000">
                <SegmentTemplate timescale="1" duration="5" initialization="init.mp4" media="p3-$Number$.m4s"/>
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """

        let manifest = try DASHManifestParser.parse(mpd, baseURL: manifestURL)
        let plan = try DASHTransferPlanner.makeVODPlan(from: manifest)

        XCTAssertEqual(plan.video?.estimatedDurationSeconds, 15.0)
        XCTAssertEqual(plan.video?.estimatedSegmentCount, 3)
        XCTAssertEqual(plan.video?.resources.count, 4) // 1 init + 3 segments
    }

    // MARK: - SegmentBase & Sidx Tests

    func testDASHSidxParserParsesV0AndV1Boxes() throws {
        // Build synthetic v0 sidx box:
        // 2 entries:
        // Entry 1: size=10000, duration=2000 (timescale 1000 -> 2.0s)
        // Entry 2: size=12000, duration=3000 (timescale 1000 -> 3.0s)
        let v0Data = DASHSidxParser.makeSidxBox(
            version: 0,
            referenceID: 1,
            timescale: 1000,
            earliestPresentationTime: 0,
            firstOffset: 0,
            entries: [
                (size: 10000, duration: 2000),
                (size: 12000, duration: 3000)
            ]
        )

        let v0Segments = try DASHSidxParser.parse(data: v0Data, sidxOffset: 800)
        XCTAssertEqual(v0Segments.count, 2)

        let expectedAnchor = 800 + Int64(v0Data.count)
        XCTAssertEqual(v0Segments[0].byteRange.start, expectedAnchor)
        XCTAssertEqual(v0Segments[0].byteRange.end, expectedAnchor + 10000 - 1)
        XCTAssertEqual(v0Segments[0].duration, 2.0)
        XCTAssertEqual(v0Segments[0].presentationTime, 0.0)

        XCTAssertEqual(v0Segments[1].byteRange.start, expectedAnchor + 10000)
        XCTAssertEqual(v0Segments[1].byteRange.end, expectedAnchor + 10000 + 12000 - 1)
        XCTAssertEqual(v0Segments[1].duration, 3.0)
        XCTAssertEqual(v0Segments[1].presentationTime, 2.0)

        // Build synthetic v1 sidx box (64-bit timestamps):
        let v1Data = DASHSidxParser.makeSidxBox(
            version: 1,
            referenceID: 2,
            timescale: 1000,
            earliestPresentationTime: 5000,
            firstOffset: 100,
            entries: [
                (size: 8000, duration: 1500)
            ]
        )

        let v1Segments = try DASHSidxParser.parse(data: v1Data, sidxOffset: 0)
        XCTAssertEqual(v1Segments.count, 1)
        let v1Anchor = Int64(v1Data.count) + 100
        XCTAssertEqual(v1Segments[0].byteRange.start, v1Anchor)
        XCTAssertEqual(v1Segments[0].byteRange.end, v1Anchor + 8000 - 1)
        XCTAssertEqual(v1Segments[0].duration, 1.5)
        XCTAssertEqual(v1Segments[0].presentationTime, 5.0)
    }

    func testSegmentBaseAddressingWithSidxDataExpansion() throws {
        let mpd = """
        <MPD type="static" mediaPresentationDuration="PT4S">
          <Period id="p0" duration="PT4S">
            <AdaptationSet id="video" contentType="video" mimeType="video/mp4" codecs="avc1">
              <Representation id="v0" bandwidth="1500000">
                <BaseURL>video.mp4</BaseURL>
                <SegmentBase indexRange="835-1200" timescale="1000">
                  <Initialization range="0-834"/>
                </SegmentBase>
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """

        let manifest = try DASHManifestParser.parse(mpd, baseURL: manifestURL)
        let rep = try XCTUnwrap(manifest.periods[0].adaptationSets[0].representations[0])
        XCTAssertNotNil(rep.segmentBase)
        XCTAssertEqual(rep.segmentBase?.indexRange, "835-1200")
        XCTAssertEqual(rep.segmentBase?.initialization?.range, "0-834")

        // Create sidx data for 2 subsegments:
        let sidxData = DASHSidxParser.makeSidxBox(
            version: 0,
            timescale: 1000,
            entries: [
                (size: 50000, duration: 2000),
                (size: 60000, duration: 2000)
            ]
        )

        let plan = try DASHTransferPlanner.makeVODPlan(
            from: manifest,
            sidxDataByRepresentationID: ["v0": sidxData]
        )

        let video = try XCTUnwrap(plan.video)
        XCTAssertEqual(video.resources.count, 3) // 1 init + 2 media segments
        XCTAssertEqual(video.resources[0].kind, .initialization)
        XCTAssertEqual(video.resources[0].byteRange, DASHByteRange(start: 0, end: 834))

        XCTAssertEqual(video.resources[1].kind, .mediaSegment)
        XCTAssertEqual(video.resources[1].byteRange?.length, 50000)

        XCTAssertEqual(video.resources[2].kind, .mediaSegment)
        XCTAssertEqual(video.resources[2].byteRange?.length, 60000)
        XCTAssertEqual(video.estimatedDurationSeconds, 4.0)
    }

    func testSegmentBaseWithDirectMediaRange() throws {
        let mpd = """
        <MPD type="static" mediaPresentationDuration="PT5S">
          <Period id="p0" duration="PT5S">
            <AdaptationSet id="audio" contentType="audio" mimeType="audio/mp4" codecs="mp4a">
              <Representation id="a0" bandwidth="128000">
                <BaseURL>audio.mp4</BaseURL>
                <SegmentBase mediaRange="1000-50000" timescale="1">
                  <Initialization range="0-999"/>
                </SegmentBase>
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """

        let manifest = try DASHManifestParser.parse(mpd, baseURL: manifestURL)
        let plan = try DASHTransferPlanner.makeVODPlan(from: manifest)

        let audio = try XCTUnwrap(plan.audio)
        XCTAssertEqual(audio.resources.count, 2)
        XCTAssertEqual(audio.resources[0].kind, .initialization)
        XCTAssertEqual(audio.resources[0].byteRange, DASHByteRange(start: 0, end: 999))
        XCTAssertEqual(audio.resources[1].kind, .mediaSegment)
        XCTAssertEqual(audio.resources[1].byteRange, DASHByteRange(start: 1000, end: 50000))
        XCTAssertEqual(audio.estimatedTransferBytes, 1000 + 49001)
    }

    // MARK: - Attribute Inheritance Tests

    func testAdaptationSetAttributeInheritanceToRepresentations() throws {
        let mpd = """
        <MPD type="static" mediaPresentationDuration="PT2S">
          <Period duration="PT2S">
            <AdaptationSet id="inherited" contentType="video" mimeType="video/mp4" codecs="avc1.640028">
              <SegmentTemplate timescale="1" duration="2" initialization="init-$RepresentationID$.mp4" media="seg-$RepresentationID$-$Number$.m4s"/>
              <Representation id="v_inherited_1" bandwidth="1000000" width="1280" height="720"/>
              <Representation id="v_inherited_2" bandwidth="2000000" width="1920" height="1080"/>
            </AdaptationSet>
          </Period>
        </MPD>
        """

        let manifest = try DASHManifestParser.parse(mpd, baseURL: manifestURL)
        let adaptation = manifest.periods[0].adaptationSets[0]

        // Check both representations inherited SegmentTemplate, mimeType, and codecs:
        for rep in adaptation.representations {
            XCTAssertEqual(rep.mimeType, "video/mp4")
            XCTAssertEqual(rep.codecs, "avc1.640028")
            XCTAssertNotNil(rep.segmentTemplate)
            XCTAssertEqual(rep.segmentTemplate?.duration, 2)
        }

        let plan = try DASHTransferPlanner.makeVODPlan(from: manifest)
        // Automatically picks highest bitrate (v_inherited_2)
        XCTAssertEqual(plan.video?.representationID, "v_inherited_2")
        XCTAssertEqual(plan.video?.codecs, "avc1.640028")
        XCTAssertEqual(plan.video?.resources[0].url.lastPathComponent, "init-v_inherited_2.mp4")
    }

    // MARK: - DRM ContentProtection Rejection Tests

    func testDRMContentProtectionExplicitlyIdentifiedAndRejected() throws {
        // Widevine scheme
        let widevineMPD = """
        <MPD type="static" mediaPresentationDuration="PT2S">
          <Period duration="PT2S">
            <AdaptationSet contentType="video" mimeType="video/mp4" codecs="avc1">
              <ContentProtection schemeIdUri="urn:uuid:edef8ba9-79d6-4ace-a3c8-27dcd51d21ed"/>
              <Representation id="wv" bandwidth="1000">
                <SegmentTemplate duration="2" initialization="init.mp4" media="seg-$Number$.m4s"/>
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """

        let wvManifest = try DASHManifestParser.parse(widevineMPD, baseURL: manifestURL)
        XCTAssertTrue(wvManifest.periods[0].adaptationSets[0].hasContentProtection)
        XCTAssertTrue(wvManifest.periods[0].adaptationSets[0].contentProtections.first?.isDRM == true)
        XCTAssertThrowsError(try DASHTransferPlanner.makeVODPlan(from: wvManifest)) { error in
            XCTAssertEqual(error as? DASHVODTransferPlanError, .drmProtectedRepresentation)
        }

        // PlayReady scheme
        let playreadyMPD = """
        <MPD type="static" mediaPresentationDuration="PT2S">
          <Period duration="PT2S">
            <AdaptationSet contentType="video" mimeType="video/mp4" codecs="avc1">
              <ContentProtection schemeIdUri="urn:uuid:9a04f079-9840-4286-ab92-e65be0885f95"/>
              <Representation id="pr" bandwidth="1000">
                <SegmentTemplate duration="2" initialization="init.mp4" media="seg-$Number$.m4s"/>
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """

        let prManifest = try DASHManifestParser.parse(playreadyMPD, baseURL: manifestURL)
        XCTAssertThrowsError(try DASHTransferPlanner.makeVODPlan(from: prManifest)) { error in
            XCTAssertEqual(error as? DASHVODTransferPlanError, .drmProtectedRepresentation)
        }
    }

    // MARK: - End-to-End Multi-Period Reconstruction Test

    func testMultiPeriodReconstructionPlanBuildsOrderedAssemblyTrack() throws {
        let multiPeriodMPD = """
        <MPD type="static" mediaPresentationDuration="PT4S">
          <Period id="p1" duration="PT2S">
            <AdaptationSet contentType="video" mimeType="video/mp4" codecs="avc1">
              <Representation id="v" bandwidth="1000">
                <SegmentTemplate timescale="1" duration="1" initialization="init.mp4" media="p1-s$Number$.m4s"/>
              </Representation>
            </AdaptationSet>
          </Period>
          <Period id="p2" duration="PT2S">
            <AdaptationSet contentType="video" mimeType="video/mp4" codecs="avc1">
              <Representation id="v" bandwidth="1000">
                <SegmentTemplate timescale="1" duration="1" initialization="init.mp4" media="p2-s$Number$.m4s"/>
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """

        let manifest = try DASHManifestParser.parse(multiPeriodMPD, baseURL: manifestURL)
        let transferPlan = try DASHTransferPlanner.makeVODPlan(from: manifest)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dash-multiperiod-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Populate mock completed resources
        let completed = try transferPlan.resources.enumerated().map { index, resource in
            let fileURL = directory.appendingPathComponent("res-\(index).bin")
            let data: Data
            if resource.kind == .initialization {
                data = isoBox("ftyp", payload: Data([0, 0, 0, 1])) + isoBox("moov", payload: Data([0, 0, 0, 2]))
            } else {
                data = isoBox("moof", payload: Data([UInt8(index)])) + isoBox("mdat", payload: Data([UInt8(index)]))
            }
            try data.write(to: fileURL)
            return DASHCompletedResource(resource: resource, fileURL: fileURL)
        }

        let outputURL = directory.appendingPathComponent("assembled.mp4")
        let reconPlan = try DASHVODReconstructionPlanner.makePlan(
            from: transferPlan,
            completedResources: completed,
            destinationURL: outputURL
        )

        XCTAssertEqual(reconPlan.assemblyRequest.container, .fragmentedMP4)
        XCTAssertEqual(reconPlan.assemblyRequest.tracks.count, 1)
        // 4 media segments across 2 periods
        XCTAssertEqual(reconPlan.assemblyRequest.tracks[0].mediaSegments.count, 4)
        XCTAssertEqual(reconPlan.assemblyRequest.tracks[0].mediaSegments.map(\.order), [0, 1, 2, 3])
    }

    // MARK: - Multi-Period Differing Representations Tests

    func testMultiPeriodRequestedVideoRepresentationAbsentFromPeriod0SucceedsWithFallback() throws {
        let multiPeriodMPD = """
        <MPD type="static" mediaPresentationDuration="PT10S">
          <Period id="p0-ad" duration="PT4S">
            <AdaptationSet id="v-ad" contentType="video" mimeType="video/mp4" codecs="avc1">
              <Representation id="v_intro" bandwidth="500000">
                <SegmentTemplate timescale="1" duration="2" initialization="init-intro.mp4" media="intro-$Number$.m4s"/>
              </Representation>
            </AdaptationSet>
            <AdaptationSet id="a-ad" contentType="audio" mimeType="audio/mp4" codecs="mp4a">
              <Representation id="a_intro" bandwidth="64000">
                <SegmentTemplate timescale="1" duration="2" initialization="init-a-intro.mp4" media="intro-audio-$Number$.m4s"/>
              </Representation>
            </AdaptationSet>
          </Period>
          <Period id="p1-main" duration="PT6S">
            <AdaptationSet id="v-main" contentType="video" mimeType="video/mp4" codecs="avc1">
              <Representation id="v_720p" bandwidth="2000000">
                <SegmentTemplate timescale="1" duration="2" initialization="init-720.mp4" media="p1-720-$Number$.m4s"/>
              </Representation>
              <Representation id="v_1080p" bandwidth="5000000">
                <SegmentTemplate timescale="1" duration="2" initialization="init-1080.mp4" media="p1-1080-$Number$.m4s"/>
              </Representation>
            </AdaptationSet>
            <AdaptationSet id="a-main" contentType="audio" mimeType="audio/mp4" codecs="mp4a">
              <Representation id="a_main" bandwidth="128000">
                <SegmentTemplate timescale="1" duration="2" initialization="init-main-a.mp4" media="p1-audio-$Number$.m4s"/>
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """

        let manifest = try DASHManifestParser.parse(multiPeriodMPD, baseURL: manifestURL)
        let plan = try DASHTransferPlanner.makeVODPlan(
            from: manifest,
            videoRepresentationID: "v_1080p"
        )

        let videoPlan = try XCTUnwrap(plan.video)
        XCTAssertEqual(videoPlan.representationID, "v_1080p")
        XCTAssertEqual(videoPlan.bandwidth, 5000000)

        // Period 0 (4s / 2s = 2 segs) + Period 1 (6s / 2s = 3 segs) + 2 inits = 7 total resources
        let videoResources = videoPlan.resources
        XCTAssertEqual(videoResources.count, 7)
        XCTAssertEqual(videoResources[0].kind, .initialization)
        XCTAssertEqual(videoResources[0].url.lastPathComponent, "init-intro.mp4")
        XCTAssertEqual(videoResources[1].url.lastPathComponent, "intro-1.m4s")
        XCTAssertEqual(videoResources[2].url.lastPathComponent, "intro-2.m4s")
        XCTAssertEqual(videoResources[3].kind, .initialization)
        XCTAssertEqual(videoResources[3].url.lastPathComponent, "init-1080.mp4")
        XCTAssertEqual(videoResources[4].url.lastPathComponent, "p1-1080-1.m4s")
        XCTAssertEqual(videoResources[5].url.lastPathComponent, "p1-1080-2.m4s")
        XCTAssertEqual(videoResources[6].url.lastPathComponent, "p1-1080-3.m4s")
    }

    func testMultiPeriodRequestedAudioRepresentationAbsentFromPeriod0SucceedsWithFallback() throws {
        let multiPeriodMPD = """
        <MPD type="static" mediaPresentationDuration="PT10S">
          <Period id="p0-ad" duration="PT4S">
            <AdaptationSet id="v-ad" contentType="video" mimeType="video/mp4" codecs="avc1">
              <Representation id="v1" bandwidth="1000000">
                <SegmentTemplate timescale="1" duration="2" initialization="init-v.mp4" media="p0-v-$Number$.m4s"/>
              </Representation>
            </AdaptationSet>
            <AdaptationSet id="a-ad" contentType="audio" mimeType="audio/mp4" codecs="mp4a" lang="en">
              <Representation id="a_en_ad" bandwidth="64000">
                <SegmentTemplate timescale="1" duration="2" initialization="init-a-en.mp4" media="p0-a-$Number$.m4s"/>
              </Representation>
            </AdaptationSet>
          </Period>
          <Period id="p1-main" duration="PT6S">
            <AdaptationSet id="v-main" contentType="video" mimeType="video/mp4" codecs="avc1">
              <Representation id="v1" bandwidth="1000000">
                <SegmentTemplate timescale="1" duration="2" initialization="init-v.mp4" media="p1-v-$Number$.m4s"/>
              </Representation>
            </AdaptationSet>
            <AdaptationSet id="a-en" contentType="audio" mimeType="audio/mp4" codecs="mp4a" lang="en">
              <Representation id="a_en" bandwidth="128000">
                <SegmentTemplate timescale="1" duration="2" initialization="init-a-en.mp4" media="p1-a-en-$Number$.m4s"/>
              </Representation>
            </AdaptationSet>
            <AdaptationSet id="a-es" contentType="audio" mimeType="audio/mp4" codecs="mp4a" lang="es">
              <Representation id="a_es" bandwidth="128000">
                <SegmentTemplate timescale="1" duration="2" initialization="init-a-es.mp4" media="p1-a-es-$Number$.m4s"/>
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """

        let manifest = try DASHManifestParser.parse(multiPeriodMPD, baseURL: manifestURL)
        let plan = try DASHTransferPlanner.makeVODPlan(
            from: manifest,
            audioRepresentationID: "a_es"
        )

        let audioPlan = try XCTUnwrap(plan.audio)
        XCTAssertEqual(audioPlan.representationID, "a_es")
        XCTAssertEqual(audioPlan.bandwidth, 128000)

        // Period 0 falls back to a_en_ad (1 init + 2 media segments), Period 1 uses requested a_es (1 init + 3 media segments) = 7
        let audioResources = audioPlan.resources
        XCTAssertEqual(audioResources.count, 7)
        XCTAssertEqual(audioResources[0].kind, .initialization)
        XCTAssertEqual(audioResources[0].url.lastPathComponent, "init-a-en.mp4")
        XCTAssertEqual(audioResources[1].url.lastPathComponent, "p0-a-1.m4s")
        XCTAssertEqual(audioResources[2].url.lastPathComponent, "p0-a-2.m4s")
        XCTAssertEqual(audioResources[3].kind, .initialization)
        XCTAssertEqual(audioResources[3].url.lastPathComponent, "init-a-es.mp4")
        XCTAssertEqual(audioResources[4].url.lastPathComponent, "p1-a-es-1.m4s")
        XCTAssertEqual(audioResources[5].url.lastPathComponent, "p1-a-es-2.m4s")
        XCTAssertEqual(audioResources[6].url.lastPathComponent, "p1-a-es-3.m4s")
    }

    func testMultiPeriodRequestedTextRepresentationAbsentFromPeriod0Succeeds() throws {
        let multiPeriodMPD = """
        <MPD type="static" mediaPresentationDuration="PT10S">
          <Period id="p0-ad" duration="PT4S">
            <AdaptationSet id="v-ad" contentType="video" mimeType="video/mp4" codecs="avc1">
              <Representation id="v1" bandwidth="1000000">
                <SegmentTemplate timescale="1" duration="2" initialization="init-v.mp4" media="p0-v-$Number$.m4s"/>
              </Representation>
            </AdaptationSet>
          </Period>
          <Period id="p1-main" duration="PT6S">
            <AdaptationSet id="v-main" contentType="video" mimeType="video/mp4" codecs="avc1">
              <Representation id="v1" bandwidth="1000000">
                <SegmentTemplate timescale="1" duration="2" initialization="init-v.mp4" media="p1-v-$Number$.m4s"/>
              </Representation>
            </AdaptationSet>
            <AdaptationSet id="t-main" contentType="text" mimeType="text/vtt" lang="es">
              <Representation id="sub_es" bandwidth="500">
                <SegmentTemplate timescale="1" duration="2" media="p1-sub-es-$Number$.vtt"/>
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """

        let manifest = try DASHManifestParser.parse(multiPeriodMPD, baseURL: manifestURL)
        let plan = try DASHTransferPlanner.makeVODPlan(
            from: manifest,
            textRepresentationID: "sub_es"
        )

        let textPlan = try XCTUnwrap(plan.text)
        XCTAssertEqual(textPlan.representationID, "sub_es")
        XCTAssertEqual(textPlan.bandwidth, 500)
        // Period 0 has no text, Period 1 has 3 segments (6s / 2s = 3)
        XCTAssertEqual(textPlan.resources.count, 3)
        XCTAssertEqual(textPlan.resources[0].url.lastPathComponent, "p1-sub-es-1.vtt")
        XCTAssertEqual(textPlan.resources[1].url.lastPathComponent, "p1-sub-es-2.vtt")
        XCTAssertEqual(textPlan.resources[2].url.lastPathComponent, "p1-sub-es-3.vtt")
    }

    func testMultiPeriodRequestedRepresentationAbsentFromAllPeriodsThrows() throws {
        let multiPeriodMPD = """
        <MPD type="static" mediaPresentationDuration="PT6S">
          <Period id="p1" duration="PT6S">
            <AdaptationSet contentType="video" mimeType="video/mp4" codecs="avc1">
              <Representation id="v1" bandwidth="1000000">
                <SegmentTemplate timescale="1" duration="2" initialization="init.mp4" media="seg-$Number$.m4s"/>
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """

        let manifest = try DASHManifestParser.parse(multiPeriodMPD, baseURL: manifestURL)
        XCTAssertThrowsError(try DASHTransferPlanner.makeVODPlan(from: manifest, videoRepresentationID: "v_missing")) { error in
            XCTAssertEqual(error as? DASHVODTransferPlanError, .representationNotFound)
        }
        XCTAssertThrowsError(try DASHTransferPlanner.makeVODPlan(from: manifest, audioRepresentationID: "a_missing")) { error in
            XCTAssertEqual(error as? DASHVODTransferPlanError, .representationNotFound)
        }
        XCTAssertThrowsError(try DASHTransferPlanner.makeVODPlan(from: manifest, textRepresentationID: "sub_missing")) { error in
            XCTAssertEqual(error as? DASHVODTransferPlanError, .representationNotFound)
        }
    }

    func testMultiPeriodMediaStartingInLaterPeriodIncludesInitializationSegment() throws {
        let multiPeriodMPD = """
        <MPD type="static" mediaPresentationDuration="PT10S">
          <Period id="p0-audio-only" duration="PT4S">
            <AdaptationSet id="a0" contentType="audio" mimeType="audio/mp4" codecs="mp4a">
              <Representation id="a0" bandwidth="64000">
                <SegmentTemplate timescale="1" duration="2" initialization="init-a0.mp4" media="a0-$Number$.m4s"/>
              </Representation>
            </AdaptationSet>
          </Period>
          <Period id="p1-av" duration="PT6S">
            <AdaptationSet id="v1" contentType="video" mimeType="video/mp4" codecs="avc1">
              <Representation id="v1" bandwidth="2000000">
                <SegmentTemplate timescale="1" duration="2" initialization="init-v1.mp4" media="v1-$Number$.m4s"/>
              </Representation>
            </AdaptationSet>
            <AdaptationSet id="a1" contentType="audio" mimeType="audio/mp4" codecs="mp4a">
              <Representation id="a1" bandwidth="128000">
                <SegmentTemplate timescale="1" duration="2" initialization="init-a1.mp4" media="a1-$Number$.m4s"/>
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """

        let manifest = try DASHManifestParser.parse(multiPeriodMPD, baseURL: manifestURL)
        let plan = try DASHTransferPlanner.makeVODPlan(from: manifest)

        let videoPlan = try XCTUnwrap(plan.video)
        XCTAssertEqual(videoPlan.representationID, "v1")
        // Video only started in Period 1, so its initialization segment must be present!
        XCTAssertEqual(videoPlan.resources.first?.kind, .initialization)
        XCTAssertEqual(videoPlan.resources.first?.url.lastPathComponent, "init-v1.mp4")
        XCTAssertEqual(videoPlan.resources.count, 4) // 1 init + 3 segments (6s / 2s = 3)
    }

    func testMultiPeriodReconstructionWithDifferentInitializationSegmentsBuildsOrderedAssemblyTrack() throws {
        let multiPeriodMPD = """
        <MPD type="static" mediaPresentationDuration="PT4S">
          <Period id="p1" duration="PT2S">
            <AdaptationSet contentType="video" mimeType="video/mp4" codecs="avc1">
              <Representation id="v1" bandwidth="1000">
                <SegmentTemplate timescale="1" duration="1" initialization="init-p1.mp4" media="p1-s$Number$.m4s"/>
              </Representation>
            </AdaptationSet>
          </Period>
          <Period id="p2" duration="PT2S">
            <AdaptationSet contentType="video" mimeType="video/mp4" codecs="avc1">
              <Representation id="v2" bandwidth="2000">
                <SegmentTemplate timescale="1" duration="1" initialization="init-p2.mp4" media="p2-s$Number$.m4s"/>
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """

        let manifest = try DASHManifestParser.parse(multiPeriodMPD, baseURL: manifestURL)
        let transferPlan = try DASHTransferPlanner.makeVODPlan(from: manifest)

        let videoResources = try XCTUnwrap(transferPlan.video?.resources)
        // Period 1 (init-p1 + 2 segs) + Period 2 (init-p2 + 2 segs) = 6 resources
        XCTAssertEqual(videoResources.count, 6)
        XCTAssertEqual(videoResources[0].kind, .initialization)
        XCTAssertEqual(videoResources[0].url.lastPathComponent, "init-p1.mp4")
        XCTAssertEqual(videoResources[1].kind, .mediaSegment)
        XCTAssertEqual(videoResources[1].url.lastPathComponent, "p1-s1.m4s")
        XCTAssertEqual(videoResources[2].kind, .mediaSegment)
        XCTAssertEqual(videoResources[2].url.lastPathComponent, "p1-s2.m4s")
        XCTAssertEqual(videoResources[3].kind, .initialization)
        XCTAssertEqual(videoResources[3].url.lastPathComponent, "init-p2.mp4")
        XCTAssertEqual(videoResources[4].kind, .mediaSegment)
        XCTAssertEqual(videoResources[4].url.lastPathComponent, "p2-s1.m4s")
        XCTAssertEqual(videoResources[5].kind, .mediaSegment)
        XCTAssertEqual(videoResources[5].url.lastPathComponent, "p2-s2.m4s")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dash-multiperiod-diff-inits-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Populate mock completed resources
        let completed = try transferPlan.resources.enumerated().map { index, resource in
            let fileURL = directory.appendingPathComponent("res-\(index).bin")
            let data: Data
            if resource.kind == .initialization {
                data = isoBox("ftyp", payload: Data([0, 0, 0, UInt8(index + 1)])) + isoBox("moov", payload: Data([0, 0, 0, UInt8(index + 2)]))
            } else {
                data = isoBox("moof", payload: Data([UInt8(index)])) + isoBox("mdat", payload: Data([UInt8(index)]))
            }
            try data.write(to: fileURL)
            return DASHCompletedResource(resource: resource, fileURL: fileURL)
        }

        let outputURL = directory.appendingPathComponent("assembled-diff-inits.mp4")
        let reconPlan = try DASHVODReconstructionPlanner.makePlan(
            from: transferPlan,
            completedResources: completed,
            destinationURL: outputURL
        )

        XCTAssertEqual(reconPlan.assemblyRequest.container, .fragmentedMP4)
        XCTAssertEqual(reconPlan.assemblyRequest.tracks.count, 1)

        let track = reconPlan.assemblyRequest.tracks[0]
        // Primary initializationSegment is init-p1.mp4
        XCTAssertEqual(track.initializationSegment?.fileURL.lastPathComponent, "res-0.bin")
        XCTAssertEqual(track.initializationSegment?.role, .initialization)

        // mediaSegments contains: p1-s1, p1-s2, init-p2.mp4 (role: .initialization), p2-s1, p2-s2
        XCTAssertEqual(track.mediaSegments.count, 5)
        XCTAssertEqual(track.mediaSegments.map(\.order), [0, 1, 2, 3, 4])
        XCTAssertEqual(track.mediaSegments[0].role, .media)
        XCTAssertEqual(track.mediaSegments[0].fileURL.lastPathComponent, "res-1.bin")
        XCTAssertEqual(track.mediaSegments[1].role, .media)
        XCTAssertEqual(track.mediaSegments[1].fileURL.lastPathComponent, "res-2.bin")
        XCTAssertEqual(track.mediaSegments[2].role, .initialization)
        XCTAssertEqual(track.mediaSegments[2].fileURL.lastPathComponent, "res-3.bin")
        XCTAssertEqual(track.mediaSegments[3].role, .media)
        XCTAssertEqual(track.mediaSegments[3].fileURL.lastPathComponent, "res-4.bin")
        XCTAssertEqual(track.mediaSegments[4].role, .media)
        XCTAssertEqual(track.mediaSegments[4].fileURL.lastPathComponent, "res-5.bin")

        // Also verify track.periods decomposition
        XCTAssertEqual(track.periods.count, 2)
        XCTAssertEqual(track.periods[0].periodIndex, 0)
        XCTAssertEqual(track.periods[0].initializationSegment?.fileURL.lastPathComponent, "res-0.bin")
        XCTAssertEqual(track.periods[0].mediaSegments.count, 2)
        XCTAssertEqual(track.periods[0].mediaSegments.map(\.fileURL.lastPathComponent), ["res-1.bin", "res-2.bin"])
        XCTAssertEqual(track.periods[1].periodIndex, 1)
        XCTAssertEqual(track.periods[1].initializationSegment?.fileURL.lastPathComponent, "res-3.bin")
        XCTAssertEqual(track.periods[1].mediaSegments.count, 2)
        XCTAssertEqual(track.periods[1].mediaSegments.map(\.fileURL.lastPathComponent), ["res-4.bin", "res-5.bin"])
    }

    func testMultiPeriodMediaWithDifferingInitSegmentsAcrossPeriodsThrowsWhenStructuralRemuxingFails() async throws {
        let multiPeriodMPD = """
        <MPD type="static" mediaPresentationDuration="PT4S">
          <Period id="p1" duration="PT2S">
            <AdaptationSet contentType="video" mimeType="video/mp4" codecs="avc1">
              <Representation id="v1" bandwidth="1000">
                <SegmentTemplate timescale="1" duration="1" initialization="init-p1.mp4" media="p1-s$Number$.m4s"/>
              </Representation>
            </AdaptationSet>
          </Period>
          <Period id="p2" duration="PT2S">
            <AdaptationSet contentType="video" mimeType="video/mp4" codecs="avc1">
              <Representation id="v2" bandwidth="2000">
                <SegmentTemplate timescale="1" duration="1" initialization="init-p2.mp4" media="p2-s$Number$.m4s"/>
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """

        let manifest = try DASHManifestParser.parse(multiPeriodMPD, baseURL: manifestURL)
        let transferPlan = try DASHTransferPlanner.makeVODPlan(from: manifest)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dash-multiperiod-diff-inits-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let completed = try transferPlan.resources.enumerated().map { index, resource in
            let fileURL = directory.appendingPathComponent("res-\(index).bin")
            let data: Data
            if resource.kind == .initialization {
                data = isoBox("ftyp", payload: Data([0, 0, 0, UInt8(index + 1)])) + isoBox("moov", payload: Data([0, 0, 0, UInt8(index + 2)]))
            } else {
                data = isoBox("moof", payload: Data([UInt8(index)])) + isoBox("mdat", payload: Data([UInt8(index)]))
            }
            try data.write(to: fileURL)
            return DASHCompletedResource(resource: resource, fileURL: fileURL)
        }

        let outputURL = directory.appendingPathComponent("assembled-diff-inits.mp4")
        let reconPlan = try DASHVODReconstructionPlanner.makePlan(
            from: transferPlan,
            completedResources: completed,
            destinationURL: outputURL
        )

        // Must NOT fall back to concatenating Period 0's initialization with Period 1's media segments!
        await assertThrowsAsyncError(try await MediaAssembler.assemble(reconPlan.assemblyRequest)) { error in
            #if canImport(AVFoundation)
            XCTAssertEqual(error as? MediaAssemblyError, .differingInitializationSegmentsNotSupported(.video))
            #else
            XCTAssertEqual(error as? MediaAssemblyError, .muxingUnavailable)
            #endif
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
    }

    func testMultiPeriodMediaWithIdenticalInitSegmentsAcrossPeriodsAssemblesWithoutMidStreamInitBoxes() async throws {
        let multiPeriodMPD = """
        <MPD type="static" mediaPresentationDuration="PT4S">
          <Period id="p1" duration="PT2S">
            <AdaptationSet contentType="video" mimeType="video/mp4" codecs="avc1">
              <Representation id="v1" bandwidth="1000">
                <SegmentTemplate timescale="1" duration="1" initialization="init-p1.mp4" media="p1-s$Number$.m4s"/>
              </Representation>
            </AdaptationSet>
          </Period>
          <Period id="p2" duration="PT2S">
            <AdaptationSet contentType="video" mimeType="video/mp4" codecs="avc1">
              <Representation id="v2" bandwidth="2000">
                <SegmentTemplate timescale="1" duration="1" initialization="init-p2.mp4" media="p2-s$Number$.m4s"/>
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """

        let manifest = try DASHManifestParser.parse(multiPeriodMPD, baseURL: manifestURL)
        let transferPlan = try DASHTransferPlanner.makeVODPlan(from: manifest)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dash-multiperiod-same-inits-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sharedInitData = isoBox("ftyp", payload: Data([0, 0, 0, 1])) + isoBox("moov", payload: Data([0, 0, 0, 2]))
        let completed = try transferPlan.resources.enumerated().map { index, resource in
            let fileURL = directory.appendingPathComponent("res-\(index).bin")
            let data: Data
            if resource.kind == .initialization {
                data = sharedInitData
            } else {
                data = isoBox("moof", payload: Data([UInt8(index)])) + isoBox("mdat", payload: Data([UInt8(index)]))
            }
            try data.write(to: fileURL)
            return DASHCompletedResource(resource: resource, fileURL: fileURL)
        }

        let outputURL = directory.appendingPathComponent("assembled-same-inits.mp4")
        let reconPlan = try DASHVODReconstructionPlanner.makePlan(
            from: transferPlan,
            completedResources: completed,
            destinationURL: outputURL
        )

        let assemblyOutput = try await MediaAssembler.assemble(reconPlan.assemblyRequest)
        XCTAssertEqual(assemblyOutput.container, .fragmentedMP4)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))

        // Validate ISOBMFF structure: must have ftyp, moov, moof, mdat and NO duplicate/midstream init boxes
        let validation = MediaIntegrityValidator.validateISOBMFF(fileURL: outputURL, requiredBoxes: ["ftyp", "moov", "moof", "mdat"])
        XCTAssertTrue(validation.isConfirmedValid)

        // Read all top-level box types in order from the assembled file
        guard let handle = try? FileHandle(forReadingFrom: outputURL) else {
            XCTFail("Could not open assembled file")
            return
        }
        defer { try? handle.close() }

        var boxOrder: [String] = []
        let fileSize = UInt64(FileManager.default.fileSize(atPath: outputURL.path) ?? 0)
        var offset: UInt64 = 0
        while offset < fileSize {
            try handle.seek(toOffset: offset)
            guard let header = try handle.read(upToCount: 8), header.count == 8 else { break }
            let size = UInt64(header[0]) << 24 | UInt64(header[1]) << 16 | UInt64(header[2]) << 8 | UInt64(header[3])
            let type = String(bytes: Array(header[4...7]), encoding: .ascii) ?? ""
            boxOrder.append(type)
            offset += size
        }

        // Expected sequence: ftyp, moov (from Period 1 init), then moof, mdat for all 4 segments across both periods
        // NO ftyp or moov from Period 2 initialization must appear mid-stream!
        XCTAssertEqual(boxOrder.filter { $0 == "ftyp" }.count, 1)
        XCTAssertEqual(boxOrder.filter { $0 == "moov" }.count, 1)
        XCTAssertEqual(boxOrder.first, "ftyp")
        XCTAssertEqual(boxOrder[1], "moov")
        XCTAssertEqual(boxOrder.filter { $0 == "moof" }.count, 4)
        XCTAssertEqual(boxOrder.filter { $0 == "mdat" }.count, 4)
    }

    func testMultiPeriodTextSubtitleSegmentTimeOffsetByPeriodStart() throws {
        let multiPeriodMPD = """
        <MPD type="static" mediaPresentationDuration="PT10S">
          <Period id="p0" duration="PT4S">
            <AdaptationSet id="v0" contentType="video" mimeType="video/mp4" codecs="avc1">
              <Representation id="v1" bandwidth="1000000">
                <SegmentTemplate timescale="1" duration="2" initialization="init-v.mp4" media="p0-v-$Number$.m4s"/>
              </Representation>
            </AdaptationSet>
            <AdaptationSet id="t0" contentType="text" mimeType="text/vtt" lang="en">
              <Representation id="sub_en" bandwidth="500">
                <SegmentTemplate timescale="1" duration="2" media="p0-sub-$Number$.vtt"/>
              </Representation>
            </AdaptationSet>
          </Period>
          <Period id="p1" duration="PT6S">
            <AdaptationSet id="v1" contentType="video" mimeType="video/mp4" codecs="avc1">
              <Representation id="v1" bandwidth="1000000">
                <SegmentTemplate timescale="1" duration="2" initialization="init-v.mp4" media="p1-v-$Number$.m4s"/>
              </Representation>
            </AdaptationSet>
            <AdaptationSet id="t1" contentType="text" mimeType="text/vtt" lang="en">
              <Representation id="sub_en" bandwidth="500">
                <SegmentTemplate timescale="1" duration="2" media="p1-sub-$Number$.vtt"/>
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """

        let manifest = try DASHManifestParser.parse(multiPeriodMPD, baseURL: manifestURL)
        let plan = try DASHTransferPlanner.makeVODPlan(from: manifest, textRepresentationID: "sub_en")
        let textPlan = try XCTUnwrap(plan.text)

        // 2 segments from Period 0 (0..4s) + 3 segments from Period 1 (4..10s) = 5 media segments
        XCTAssertEqual(textPlan.resources.count, 5)
        XCTAssertEqual(textPlan.resources.map(\.segmentTime), [0, 2, 4, 6, 8])
        XCTAssertEqual(textPlan.resources.map(\.url.lastPathComponent), [
            "p0-sub-1.vtt",
            "p0-sub-2.vtt",
            "p1-sub-1.vtt",
            "p1-sub-2.vtt",
            "p1-sub-3.vtt"
        ])

        // Verify that assembling these segments offsets Period 1 cues by Period 0 duration (4.0s)
        let p0Sub1 = """
        WEBVTT

        00:00:00.500 --> 00:00:01.500
        First period greeting
        """
        let p1Sub1 = """
        WEBVTT

        00:00:00.250 --> 00:00:01.750
        Second period response
        """

        let input0 = WebVTTSegmentInput(
            text: p0Sub1,
            playlistStartTime: Double(textPlan.resources[0].segmentTime!) / Double(textPlan.resources[0].timescale),
            duration: Double(textPlan.resources[0].duration!) / Double(textPlan.resources[0].timescale)
        )
        let input2 = WebVTTSegmentInput(
            text: p1Sub1,
            playlistStartTime: Double(textPlan.resources[2].segmentTime!) / Double(textPlan.resources[2].timescale),
            duration: Double(textPlan.resources[2].duration!) / Double(textPlan.resources[2].timescale)
        )

        let assembled = HLSWebVTTAssembler.assemble(segments: [input0, input2])
        XCTAssertTrue(assembled.contains("00:00:00.500 --> 00:00:01.500"))
        XCTAssertTrue(assembled.contains("First period greeting"))
        // Period 1 cue started at 0.250 relative to Period 1, shifted by 4.0s = 00:00:04.250 --> 00:00:05.750
        XCTAssertTrue(assembled.contains("00:00:04.250 --> 00:00:05.750"))
        XCTAssertTrue(assembled.contains("Second period response"))
    }

    func testMultiPeriodExplicitPeriodStartOffsetsSegmentTime() throws {
        let multiPeriodMPD = """
        <MPD type="static" mediaPresentationDuration="PT20S">
          <Period id="p0" start="PT0S" duration="PT5S">
            <AdaptationSet id="v0" contentType="video" mimeType="video/mp4" codecs="avc1">
              <Representation id="v1" bandwidth="1000000">
                <SegmentTemplate timescale="1000" duration="5000" initialization="init-v.mp4" media="p0-v-$Number$.m4s"/>
              </Representation>
            </AdaptationSet>
          </Period>
          <Period id="p1" start="PT10S" duration="PT6S">
            <AdaptationSet id="v1" contentType="video" mimeType="video/mp4" codecs="avc1">
              <Representation id="v1" bandwidth="1000000">
                <SegmentTemplate timescale="1000" duration="2000" initialization="init-v.mp4" media="p1-v-$Number$.m4s"/>
              </Representation>
            </AdaptationSet>
            <AdaptationSet id="t1" contentType="text" mimeType="text/vtt" lang="en">
              <Representation id="sub_p1" bandwidth="500">
                <SegmentTemplate timescale="1000" duration="3000" media="p1-sub-$Number$.vtt"/>
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """

        let manifest = try DASHManifestParser.parse(multiPeriodMPD, baseURL: manifestURL)
        let plan = try DASHTransferPlanner.makeVODPlan(from: manifest, textRepresentationID: "sub_p1")
        let textPlan = try XCTUnwrap(plan.text)

        // Period 1 starts at 10s (10000ms), 2 segments of 3000ms: 10000ms, 13000ms
        XCTAssertEqual(textPlan.resources.count, 2)
        XCTAssertEqual(textPlan.resources.map(\.segmentTime), [10000, 13000])
        XCTAssertEqual(textPlan.resources.map(\.timescale), [1000, 1000])
    }

    func testMultiPeriodSingleContiguousResourceOffsetByPeriodStart() throws {
        let multiPeriodMPD = """
        <MPD type="static" mediaPresentationDuration="PT12S">
          <Period id="p0" duration="PT4S">
            <AdaptationSet id="v0" contentType="video" mimeType="video/mp4" codecs="avc1">
              <Representation id="v1" bandwidth="1000000">
                <SegmentTemplate timescale="1" duration="2" initialization="init-v.mp4" media="p0-v-$Number$.m4s"/>
              </Representation>
            </AdaptationSet>
          </Period>
          <Period id="p1" duration="PT8S">
            <AdaptationSet id="v1" contentType="video" mimeType="video/mp4" codecs="avc1">
              <Representation id="v1" bandwidth="1000000">
                <SegmentTemplate timescale="1" duration="2" initialization="init-v.mp4" media="p1-v-$Number$.m4s"/>
              </Representation>
            </AdaptationSet>
            <AdaptationSet id="t1" contentType="text" mimeType="text/vtt" lang="en">
              <Representation id="sub_sidecar" bandwidth="500">
                <BaseURL>p1-subtitles.vtt</BaseURL>
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """

        let manifest = try DASHManifestParser.parse(multiPeriodMPD, baseURL: manifestURL)
        let plan = try DASHTransferPlanner.makeVODPlan(from: manifest, textRepresentationID: "sub_sidecar")
        let textPlan = try XCTUnwrap(plan.text)

        XCTAssertEqual(textPlan.resources.count, 1)
        let res = textPlan.resources[0]
        XCTAssertEqual(res.url.lastPathComponent, "p1-subtitles.vtt")
        // Period 0 is 4s, so Period 1 single file starts at 4000ms with timescale 1000
        XCTAssertEqual(res.segmentTime, 4000)
        XCTAssertEqual(res.timescale, 1000)
        XCTAssertEqual(res.duration, 8000)
    }

    private func isoBox(_ type: String, payload: Data) -> Data {
        let size = UInt32(8 + payload.count).bigEndian
        var data = Data()
        data.append(contentsOf: withUnsafeBytes(of: size) { Array($0) })
        data.append(contentsOf: type.utf8)
        data.append(payload)
        return data
    }
}
