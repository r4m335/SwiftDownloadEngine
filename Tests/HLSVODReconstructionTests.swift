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
        let firstData = makePATPacket()
        let secondData = makePMTPacket()
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
        XCTAssertTrue(HLSVODReconstructionPlanner.suggestedFilename(for: transferPlan).hasSuffix(".mp4"))
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

    func testSeparateAudioRenditionGeneratesMultiTrackAssemblyPlan() throws {
        let videoPlaylist = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXT-X-MAP:URI="video-init.mp4"
        #EXTINF:2,
        video-1.m4s
        #EXT-X-ENDLIST
        """
        let audioPlaylist = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXT-X-MAP:URI="audio-init.mp4"
        #EXTINF:2,
        audio-1.m4s
        #EXT-X-ENDLIST
        """
        let videoManifest = try HLSManifestParser.parse(videoPlaylist, baseURL: manifestURL)
        let audioManifest = try HLSManifestParser.parse(audioPlaylist, baseURL: manifestURL)
        let videoPlan = try HLSTransferPlanner.makeVODPlan(from: videoManifest)
        let audioPlan = try HLSTransferPlanner.makeVODPlan(from: audioManifest)

        let combinedPlan = HLSVODTransferPlan(
            manifestURL: videoPlan.manifestURL,
            resources: videoPlan.resources,
            browserRequestContext: nil,
            estimatedTransferBytes: nil,
            audioPlan: audioPlan.resources
        )

        XCTAssertEqual(combinedPlan.allResources.count, 4)
        XCTAssertEqual(HLSVODReconstructionPlanner.suggestedFilename(for: combinedPlan), "index.mp4")

        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let initData = box("ftyp", [1]) + box("moov", [2])
        let mediaData = box("moof", [3]) + box("mdat", [4])
        let files = ["v-init.mp4", "v-1.m4s", "a-init.mp4", "a-1.m4s"].map { directory.appendingPathComponent($0) }
        try initData.write(to: files[0])
        try mediaData.write(to: files[1])
        try initData.write(to: files[2])
        try mediaData.write(to: files[3])

        let completed = zip(combinedPlan.allResources, files).map {
            HLSCompletedResource(resource: $0.0, fileURL: $0.1)
        }

        let plan = try HLSVODReconstructionPlanner.makePlan(
            from: combinedPlan,
            completedResources: completed,
            destinationURL: directory.appendingPathComponent("output.mp4")
        )

        XCTAssertEqual(plan.assemblyRequest.tracks.count, 2)
        XCTAssertEqual(plan.assemblyRequest.tracks[0].kind, .video)
        XCTAssertEqual(plan.assemblyRequest.tracks[1].kind, .audio)
    }

    func testEncryptedVideoWithSeparateAudioReconstruction() throws {
        #if canImport(CommonCrypto)
        let videoPlaylist = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXT-X-KEY:METHOD=AES-128,URI="https://video.example/vod/key.bin"
        #EXTINF:2,
        video-1.ts
        #EXTINF:2,
        video-2.ts
        #EXT-X-ENDLIST
        """
        let audioPlaylist = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXTINF:2,
        audio-1.ts
        #EXTINF:2,
        audio-2.ts
        #EXT-X-ENDLIST
        """
        let videoManifest = try HLSManifestParser.parse(videoPlaylist, baseURL: manifestURL)
        let audioManifest = try HLSManifestParser.parse(audioPlaylist, baseURL: manifestURL)
        let videoPlan = try HLSTransferPlanner.makeVODPlan(from: videoManifest)
        let audioPlan = try HLSTransferPlanner.makeVODPlan(from: audioManifest)

        let combinedPlan = HLSVODTransferPlan(
            manifestURL: videoPlan.manifestURL,
            resources: videoPlan.resources,
            browserRequestContext: nil,
            estimatedTransferBytes: nil,
            audioPlan: audioPlan.resources
        )

        // videoPlan has 3 resources (key + 2 segments), audioPlan has 2 segments -> total 5 resources
        XCTAssertEqual(combinedPlan.allResources.count, 5)

        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let key = Data((0..<16).map { UInt8($0 + 10) })
        let keyFile = directory.appendingPathComponent("key.bin")
        try key.write(to: keyFile)

        let videoData1 = packet(fill: 0x11)
        let videoData2 = packet(fill: 0x22)
        let audioData1 = packet(fill: 0x33)
        let audioData2 = packet(fill: 0x44)

        let iv1 = HLSSegmentDecryptor.ivForSequenceNumber(combinedPlan.allResources[1].sequenceNumber ?? 0)
        let iv2 = HLSSegmentDecryptor.ivForSequenceNumber(combinedPlan.allResources[2].sequenceNumber ?? 1)

        let encVideo1 = try HLSSegmentDecryptor.encrypt(data: videoData1, key: key, iv: iv1)
        let encVideo2 = try HLSSegmentDecryptor.encrypt(data: videoData2, key: key, iv: iv2)

        let v1File = directory.appendingPathComponent("v-1.ts")
        let v2File = directory.appendingPathComponent("v-2.ts")
        let a1File = directory.appendingPathComponent("a-1.ts")
        let a2File = directory.appendingPathComponent("a-2.ts")

        try encVideo1.write(to: v1File)
        try encVideo2.write(to: v2File)
        try audioData1.write(to: a1File)
        try audioData2.write(to: a2File)

        let completed = [
            HLSCompletedResource(resource: combinedPlan.allResources[0], fileURL: keyFile),
            HLSCompletedResource(resource: combinedPlan.allResources[1], fileURL: v1File),
            HLSCompletedResource(resource: combinedPlan.allResources[2], fileURL: v2File),
            HLSCompletedResource(resource: combinedPlan.allResources[3], fileURL: a1File),
            HLSCompletedResource(resource: combinedPlan.allResources[4], fileURL: a2File)
        ]

        let output = directory.appendingPathComponent("output.ts")
        // Multi-track assembly must NOT return a single-track fallback success when muxing fails
        XCTAssertThrowsError(
            try HLSVODReconstructor.assemble(
                transferPlan: combinedPlan,
                completedResources: completed,
                destinationURL: output
            )
        ) { error in
            guard case let HLSVODReconstructionError.assemblyFailed(mediaErr) = error else {
                XCTFail("Expected assemblyFailed error, got \(error)")
                return
            }
            XCTAssertTrue(mediaErr is MediaAssemblyError)
        }

        // Incomplete single-track fallback must not be published as success
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))

        let mediaAssemblyDir = directory.appendingPathComponent(".media-assembly")
        if FileManager.default.fileExists(atPath: mediaAssemblyDir.path) {
            let decryptedFiles = (try? FileManager.default.contentsOfDirectory(atPath: mediaAssemblyDir.path))?
                .filter { $0.hasPrefix("decrypted_seg_") } ?? []
            XCTAssertTrue(decryptedFiles.isEmpty, "Decrypted segment files must be cleaned up after assembly: \(decryptedFiles)")
        }

        // Failed multi-track inputs must be preserved in quarantine
        let quarantined = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
            .filter { $0.contains(".media-quarantine-") } ?? []
        XCTAssertFalse(quarantined.isEmpty, "Failed multi-track inputs must be quarantined for diagnosis")
        #endif
    }

    private func makePATPacket() -> Data {
        var p = Data(repeating: 0xFF, count: 188)
        p[0] = 0x47; p[1] = 0x40; p[2] = 0x00; p[3] = 0x10; p[4] = 0x00
        p[5] = 0x00; p[6] = 0xB0; p[7] = 0x0D; p[8] = 0x00; p[9] = 0x01
        p[10] = 0xC1; p[11] = 0x00; p[12] = 0x00; p[13] = 0x00; p[14] = 0x01
        p[15] = 0xE1; p[16] = 0x00
        return p
    }

    private func makePMTPacket(videoStream: UInt8 = 0x1B) -> Data {
        var p = Data(repeating: 0xFF, count: 188)
        p[0] = 0x47; p[1] = 0x41; p[2] = 0x00; p[3] = 0x10; p[4] = 0x00
        p[5] = 0x02; p[6] = 0xB0; p[7] = 0x12; p[8] = 0x00; p[9] = 0x01
        p[10] = 0xC1; p[11] = 0x00; p[12] = 0x00; p[13] = 0xE1; p[14] = 0x01
        p[15] = 0xF0; p[16] = 0x00
        p[17] = videoStream; p[18] = 0xE1; p[19] = 0x01; p[20] = 0xF0; p[21] = 0x00
        return p
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
