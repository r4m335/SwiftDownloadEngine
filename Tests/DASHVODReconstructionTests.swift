import Foundation
import XCTest
@testable import DM_Reverse_engineering

final class DASHVODReconstructionTests: XCTestCase {
    private let manifestURL = URL(string: "https://video.example/vod/manifest.mpd?sig=manifest")!

    func testPlannerBuildsSeparateVideoAndAudioAssemblyTracks() throws {
        let manifest = try DASHManifestParser.parse(twoTrackMPD, baseURL: manifestURL)
        let transferPlan = try DASHTransferPlanner.makeVODPlan(
            from: manifest,
            videoRepresentationID: "v1",
            audioRepresentationID: "a1"
        )
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let completed = try makeCompletedResources(
            transferPlan: transferPlan,
            directory: directory
        )
        let reconstruction = try DASHVODReconstructionPlanner.makePlan(
            from: transferPlan,
            completedResources: completed,
            destinationURL: directory.appendingPathComponent("movie.mp4")
        )

        XCTAssertEqual(reconstruction.assemblyRequest.container, .fragmentedMP4)
        XCTAssertEqual(reconstruction.assemblyRequest.tracks.map(\.kind), [.video, .audio])
        XCTAssertEqual(reconstruction.assemblyRequest.tracks[0].metadata.codec, "avc1")
        XCTAssertEqual(reconstruction.assemblyRequest.tracks[1].metadata.codec, "mp4a")
        XCTAssertEqual(reconstruction.assemblyRequest.tracks[0].mediaSegments.map(\.order), [0, 1])
        XCTAssertEqual(reconstruction.assemblyRequest.tracks[1].mediaSegments.map(\.order), [0, 1])
    }

    func testSingleVideoDASHVODAssemblyPublishesOrderedFragments() throws {
        let manifest = try DASHManifestParser.parse(singleVideoMPD, baseURL: manifestURL)
        let transferPlan = try DASHTransferPlanner.makeVODPlan(from: manifest)
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let completed = try makeCompletedResources(
            transferPlan: transferPlan,
            directory: directory
        )
        let output = directory.appendingPathComponent("movie.mp4")
        let result = try DASHVODReconstructor.assemble(
            transferPlan: transferPlan,
            completedResources: completed,
            destinationURL: output
        )

        XCTAssertEqual(result.container, .fragmentedMP4)
        XCTAssertEqual(result.trackCount, 1)
        XCTAssertEqual(try Data(contentsOf: output),
                       initBytes + mediaBytes(fill: 2) + mediaBytes(fill: 3))
    }

    func testPlannerRejectsMismatchedOrderAndIncompleteResources() throws {
        let manifest = try DASHManifestParser.parse(singleVideoMPD, baseURL: manifestURL)
        let transferPlan = try DASHTransferPlanner.makeVODPlan(from: manifest)
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let completed = try makeCompletedResources(transferPlan: transferPlan, directory: directory)

        XCTAssertThrowsError(try DASHVODReconstructionPlanner.makePlan(
            from: transferPlan,
            completedResources: Array(completed.dropFirst()),
            destinationURL: directory.appendingPathComponent("movie.mp4")
        )) { error in
            XCTAssertEqual(error as? DASHVODReconstructionError, .resourceCountMismatch)
        }

        var reordered = completed
        reordered.swapAt(0, 1)
        XCTAssertThrowsError(try DASHVODReconstructionPlanner.makePlan(
            from: transferPlan,
            completedResources: reordered,
            destinationURL: directory.appendingPathComponent("movie.mp4")
        )) { error in
            XCTAssertEqual(error as? DASHVODReconstructionError, .resourceOrderMismatch)
        }
    }

    private func makeCompletedResources(
        transferPlan: DASHVODTransferPlan,
        directory: URL
    ) throws -> [DASHCompletedResource] {
        try transferPlan.resources.enumerated().map { index, resource in
            let fileURL = directory.appendingPathComponent("resource-\(index).bin")
            let bytes: Data
            switch resource.kind {
            case .initialization:
                bytes = initBytes
            case .mediaSegment:
                bytes = mediaBytes(fill: UInt8(index + 1))
            }
            try bytes.write(to: fileURL)
            return DASHCompletedResource(resource: resource, fileURL: fileURL)
        }
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dash-reconstruction-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private var singleVideoMPD: String {
        """
        <MPD type="static" mediaPresentationDuration="PT4S">
          <Period id="p0" duration="PT4S">
            <AdaptationSet contentType="video" mimeType="video/mp4" codecs="avc1">
              <Representation id="v1" bandwidth="1000">
                <SegmentTemplate timescale="1" duration="2" initialization="init.mp4" media="segment-$Number$.m4s"/>
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """
    }

    private var twoTrackMPD: String {
        """
        <MPD type="static" mediaPresentationDuration="PT4S">
          <Period id="p0" duration="PT4S">
            <AdaptationSet id="video" contentType="video" mimeType="video/mp4" codecs="avc1">
              <Representation id="v1" bandwidth="1000">
                <SegmentTemplate timescale="1" duration="2" initialization="video-init.mp4" media="video-$Number$.m4s"/>
              </Representation>
            </AdaptationSet>
            <AdaptationSet id="audio" contentType="audio" mimeType="audio/mp4" codecs="mp4a">
              <Representation id="a1" bandwidth="64">
                <SegmentTemplate timescale="1" duration="2" initialization="audio-init.mp4" media="audio-$Number$.m4s"/>
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """
    }

    private var initBytes: Data {
        isoBox("ftyp", payload: Data([0, 0, 0, 1])) + isoBox("moov", payload: Data([0, 0, 0, 2]))
    }

    private func mediaBytes(fill: UInt8) -> Data {
        isoBox("moof", payload: Data([fill])) + isoBox("mdat", payload: Data([fill, fill]))
    }

    private func isoBox(_ type: String, payload: Data) -> Data {
        let typeBytes = Array(type.utf8)
        precondition(typeBytes.count == 4)
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
