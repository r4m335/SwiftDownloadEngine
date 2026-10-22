import Foundation
import XCTest
@testable import DM_Reverse_engineering

final class HLSVODReconstructionTests: XCTestCase {
    private let manifestURL = URL(string: "https://video.example/vod/index.m3u8?sig=manifest")!

    func testClearMPEGTSVODProducesOrderedOutput() throws {
        let playlist = """
        #EXTM3U
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXTINF:2,
        first.ts?sig=one
        #EXTINF:2,
        second.ts?sig=two
        #EXT-X-ENDLIST
        """
        let manifest = try HLSManifestParser.parse(playlist, baseURL: manifestURL)
        let transferPlan = try HLSTransferPlanner.makeVODPlan(from: manifest)
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = directory.appendingPathComponent("first.part")
        let second = directory.appendingPathComponent("second.part")
        let firstData = packet(fill: 0x11)
        let secondData = packet(fill: 0x22)
        try firstData.write(to: first)
        try secondData.write(to: second)
        let completed = [
            HLSCompletedResource(resource: transferPlan.resources[0], fileURL: first),
            HLSCompletedResource(resource: transferPlan.resources[1], fileURL: second)
        ]
        let output = directory.appendingPathComponent("vod.ts")
        let result = try HLSVODReconstructor.assemble(
            transferPlan: transferPlan,
            completedResources: completed,
            destinationURL: output
        )

        XCTAssertEqual(result.container, .mpegTS)
        XCTAssertEqual(try Data(contentsOf: output), firstData + secondData)
        XCTAssertTrue(HLSVODReconstructionPlanner.suggestedFilename(for: transferPlan).hasSuffix(".ts"))
    }

    func testFragmentedMP4VODPreservesInitializationMapAndSegmentOrder() throws {
        let playlist = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXT-X-MAP:URI="init.mp4?sig=init"
        #EXTINF:2,
        part-1.m4s?sig=one
        #EXTINF:2,
        part-2.m4s?sig=two
        #EXT-X-ENDLIST
        """
        let manifest = try HLSManifestParser.parse(playlist, baseURL: manifestURL)
        let transferPlan = try HLSTransferPlanner.makeVODPlan(from: manifest)
        XCTAssertEqual(transferPlan.resources.map(\.kind), [.initializationMap, .mediaSegment, .mediaSegment])
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let initData = box("ftyp", [1]) + box("moov", [2])
        let firstData = box("moof", [3]) + box("mdat", [4])
        let secondData = box("moof", [5]) + box("mdat", [6])
        let files = ["init.part", "first.part", "second.part"].map { directory.appendingPathComponent($0) }
        try initData.write(to: files[0])
        try firstData.write(to: files[1])
        try secondData.write(to: files[2])
        let completed = zip(transferPlan.resources, files).map {
            HLSCompletedResource(resource: $0.0, fileURL: $0.1)
        }
        let output = directory.appendingPathComponent("vod.mp4")
        let result = try HLSVODReconstructor.assemble(
            transferPlan: transferPlan,
            completedResources: completed,
            destinationURL: output
        )

        XCTAssertEqual(result.container, .fragmentedMP4)
        XCTAssertEqual(try Data(contentsOf: output), initData + firstData + secondData)
    }

    func testMissingResourcesAndEncryptionFailBeforeOutput() throws {
        let playlist = """
        #EXTM3U
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXT-X-KEY:METHOD=AES-128,URI="key.bin"
        #EXTINF:2,
        segment.ts
        #EXT-X-ENDLIST
        """
        let manifest = try HLSManifestParser.parse(playlist, baseURL: manifestURL)
        let transferPlan = try HLSTransferPlanner.makeVODPlan(from: manifest)
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let keyFile = directory.appendingPathComponent("key.part")
        let segmentFile = directory.appendingPathComponent("segment.part")
        try Data([1]).write(to: keyFile)
        try packet(fill: 0x33).write(to: segmentFile)
        let completed = [
            HLSCompletedResource(resource: transferPlan.resources[0], fileURL: keyFile),
            HLSCompletedResource(resource: transferPlan.resources[1], fileURL: segmentFile)
        ]

        XCTAssertThrowsError(try HLSVODReconstructionPlanner.makePlan(
            from: transferPlan,
            completedResources: completed,
            destinationURL: directory.appendingPathComponent("output.ts")
        )) { error in
            XCTAssertEqual(error as? HLSVODReconstructionError, .unsupportedEncryption)
        }
    }

    func testVariantSelectionIsDeterministicAndHonorsLimits() throws {
        let master = try HLSManifestParser.parse("""
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=100000,RESOLUTION=640x360,CODECS="avc1.4d401e"
        low/index.m3u8?sig=low
        #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=1280x720,CODECS="avc1.4d401f"
        high/index.m3u8?sig=high
        """, baseURL: manifestURL)

        let selected = try HLSVariantSelector.select(
            from: master,
            preferences: HLSVariantSelectionPreferences(maximumWidth: 700)
        )
        XCTAssertEqual(selected.uri.absoluteString, "https://video.example/vod/low/index.m3u8?sig=low")
        XCTAssertThrowsError(try HLSVariantSelector.select(
            from: master,
            preferences: HLSVariantSelectionPreferences(preferredCodecPrefix: "hev1")
        )) { error in
            XCTAssertEqual(error as? HLSVariantSelectionError, .noVariantMatchesPreferences)
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hls-reconstruction-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func packet(fill: UInt8) -> Data {
        var result = Data([0x47])
        result.append(Data(repeating: fill, count: 187))
        return result
    }

    private func box(_ type: String, _ payload: [UInt8]) -> Data {
        let bytes = Array(type.utf8)
        let size = UInt32(bytes.count + payload.count + 4)
        var result = Data([
            UInt8((size >> 24) & 0xff), UInt8((size >> 16) & 0xff),
            UInt8((size >> 8) & 0xff), UInt8(size & 0xff)
        ])
        result.append(contentsOf: bytes)
        result.append(contentsOf: payload)
        return result
    }
}
