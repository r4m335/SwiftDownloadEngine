import Foundation
import XCTest
@testable import SwiftDownloadEngine

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

    private func isoBox(_ type: String, payload: Data) -> Data {
        let size = UInt32(8 + payload.count).bigEndian
        var data = Data()
        data.append(contentsOf: withUnsafeBytes(of: size) { Array($0) })
        data.append(contentsOf: type.utf8)
        data.append(payload)
        return data
    }
}
