import Foundation
import XCTest
@testable import DM_Reverse_engineering

final class MediaAssemblerTests: XCTestCase {
    private let outputURL = URL(fileURLWithPath: "/tmp/media-assembly/output.mp4")

    func testValidFragmentedMP4VODWithSeparateTracksProducesDeterministicReport() throws {
        let request = MediaAssemblyRequest(
            container: .fragmentedMP4,
            tracks: [
                makeTrack(.video, container: .fragmentedMP4, initializationName: "video-init.mp4", sizes: [100, 200]),
                makeTrack(.audio, container: .fragmentedMP4, initializationName: "audio-init.mp4", sizes: [50, 75])
            ],
            destinationURL: outputURL
        )

        let report = try MediaAssembler.validateInput(request)

        XCTAssertEqual(report.container, .fragmentedMP4)
        XCTAssertEqual(report.trackCount, 2)
        XCTAssertEqual(report.mediaSegmentCount, 4)
        XCTAssertEqual(report.totalInputBytes, 475)
        XCTAssertTrue(report.isReadyForAssembly)
    }

    func testValidMPEGTSDoesNotRequireInitializationSegment() throws {
        let request = MediaAssemblyRequest(
            container: .mpegTS,
            tracks: [makeTrack(.video, container: .mpegTS, initializationName: nil, sizes: [10, 20])],
            destinationURL: outputURL
        )

        XCTAssertNoThrow(try MediaAssembler.validateInput(request))
    }

    func testLiveSourceIsRejectedBeforeAssembly() {
        let request = MediaAssemblyRequest(
            sourceLifecycle: .live,
            container: .mpegTS,
            tracks: [makeTrack(.video, container: .mpegTS, initializationName: nil, sizes: [10])],
            destinationURL: outputURL
        )

        XCTAssertThrowsError(try MediaAssembler.validateInput(request)) { error in
            XCTAssertEqual(error as? MediaAssemblyError, .liveSourceNotSupported)
        }
    }

    func testEncryptedContentIsExplicitlyRejected() {
        let request = MediaAssemblyRequest(
            container: .fragmentedMP4,
            encryption: .drm,
            tracks: [makeTrack(.video, container: .fragmentedMP4, initializationName: "init.mp4", sizes: [10])],
            destinationURL: outputURL
        )

        XCTAssertThrowsError(try MediaAssembler.validateInput(request)) { error in
            XCTAssertEqual(error as? MediaAssemblyError, .encryptedMediaNotSupported(.drm))
        }
    }

    func testFragmentedMP4RequiresInitializationSegment() {
        let request = MediaAssemblyRequest(
            container: .fragmentedMP4,
            tracks: [makeTrack(.video, container: .fragmentedMP4, initializationName: nil, sizes: [10])],
            destinationURL: outputURL
        )

        XCTAssertThrowsError(try MediaAssembler.validateInput(request)) { error in
            XCTAssertEqual(error as? MediaAssemblyError, .missingInitializationSegment(.video))
        }
    }

    func testMissingOrderAndTruncatedSegmentFailSafely() {
        let missingOrderRequest = MediaAssemblyRequest(
            container: .mpegTS,
            tracks: [MediaAssemblyTrack(
                kind: .video,
                container: .mpegTS,
                mediaSegments: [
                    segment("one.ts", order: 0, size: 10),
                    segment("three.ts", order: 2, size: 10)
                ]
            )],
            destinationURL: outputURL
        )
        XCTAssertThrowsError(try MediaAssembler.validateInput(missingOrderRequest)) { error in
            XCTAssertEqual(error as? MediaAssemblyError, .invalidSegmentOrder(.video))
        }

        let truncatedRequest = MediaAssemblyRequest(
            container: .mpegTS,
            tracks: [MediaAssemblyTrack(
                kind: .video,
                container: .mpegTS,
                mediaSegments: [segment("short.ts", order: 0, expected: 20, actual: 10)]
            )],
            destinationURL: outputURL
        )
        XCTAssertThrowsError(try MediaAssembler.validateInput(truncatedRequest)) { error in
            XCTAssertEqual(error as? MediaAssemblyError, .invalidSegmentSize(.video, order: 0))
        }
    }

    func testRemoteURLsAndInvalidMetadataAreRejectedWithoutLoggingURLValues() {
        let remoteRequest = MediaAssemblyRequest(
            container: .mpegTS,
            tracks: [MediaAssemblyTrack(
                kind: .video,
                container: .mpegTS,
                mediaSegments: [MediaAssemblySegment(
                    fileURL: URL(string: "https://cdn.example/video.ts?sig=secret")!,
                    order: 0,
                    actualByteCount: 10
                )]
            )],
            destinationURL: outputURL
        )
        XCTAssertThrowsError(try MediaAssembler.validateInput(remoteRequest)) { error in
            XCTAssertEqual(error as? MediaAssemblyError, .invalidSegmentFileURL(.video, order: 0))
            XCTAssertFalse(error.localizedDescription.contains("sig=secret"))
        }

        let invalidMetadataRequest = MediaAssemblyRequest(
            container: .mpegTS,
            tracks: [MediaAssemblyTrack(
                kind: .audio,
                container: .mpegTS,
                metadata: MediaAssemblyTrackMetadata(timescale: 0),
                mediaSegments: [segment("audio.ts", order: 0, size: 10)]
            )],
            destinationURL: outputURL
        )
        XCTAssertThrowsError(try MediaAssembler.validateInput(invalidMetadataRequest)) { error in
            XCTAssertEqual(error as? MediaAssemblyError, .invalidTrackMetadata(.audio))
        }
    }

    func testTemporaryAndDestinationURLsMustBeLocalFiles() {
        let remoteDestinationRequest = MediaAssemblyRequest(
            container: .mpegTS,
            tracks: [makeTrack(.video, container: .mpegTS, initializationName: nil, sizes: [10])],
            destinationURL: URL(string: "https://example.com/output.ts")!
        )
        XCTAssertThrowsError(try MediaAssembler.validateInput(remoteDestinationRequest)) { error in
            XCTAssertEqual(error as? MediaAssemblyError, .invalidDestinationURL)
        }

        let remoteTemporaryRequest = MediaAssemblyRequest(
            container: .mpegTS,
            tracks: [makeTrack(.video, container: .mpegTS, initializationName: nil, sizes: [10])],
            destinationURL: outputURL,
            temporaryDirectoryURL: URL(string: "https://example.com/tmp")!
        )
        XCTAssertThrowsError(try MediaAssembler.validateInput(remoteTemporaryRequest)) { error in
            XCTAssertEqual(error as? MediaAssemblyError, .invalidTemporaryDirectoryURL)
        }
    }

    func testMPEGTSAssemblyPublishesOrderedValidatedBytes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("media-assembler-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = directory.appendingPathComponent("first.ts")
        let second = directory.appendingPathComponent("second.ts")
        let output = directory.appendingPathComponent("movie.ts")
        let firstBytes = makePATPacket()
        let secondBytes = makePMTPacket()
        try firstBytes.write(to: first)
        try secondBytes.write(to: second)

        let request = MediaAssemblyRequest(
            container: .mpegTS,
            tracks: [MediaAssemblyTrack(
                kind: .video,
                container: .mpegTS,
                mediaSegments: [
                    MediaAssemblySegment(fileURL: first, order: 0, actualByteCount: 188),
                    MediaAssemblySegment(fileURL: second, order: 1, actualByteCount: 188)
                ]
            )],
            destinationURL: output
        )
        let result = try MediaAssembler.assemble(request)

        XCTAssertEqual(result.container, .mpegTS)
        XCTAssertEqual(result.byteCount, 376)
        XCTAssertEqual(try Data(contentsOf: output), firstBytes + secondBytes)
    }

    func testTruncatedMPEGTSNeverPublishesOutput() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("media-assembler-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let segment = directory.appendingPathComponent("truncated.ts")
        let output = directory.appendingPathComponent("movie.ts")
        try Data(repeating: 0x47, count: 187).write(to: segment)
        let request = MediaAssemblyRequest(
            container: .mpegTS,
            tracks: [MediaAssemblyTrack(
                kind: .video,
                container: .mpegTS,
                mediaSegments: [MediaAssemblySegment(fileURL: segment, order: 0, actualByteCount: 187)]
            )],
            destinationURL: output
        )

        XCTAssertThrowsError(try MediaAssembler.assemble(request)) { error in
            XCTAssertEqual(error as? MediaAssemblyError, .invalidMediaData(.mpegTS))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testFragmentedMP4AssemblyRequiresInitializationAndMediaFragments() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("media-assembler-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let initialization = directory.appendingPathComponent("init.mp4")
        let media = directory.appendingPathComponent("segment.m4s")
        let output = directory.appendingPathComponent("movie.mp4")
        let initBytes = isoBox("ftyp", payload: Data([0, 0, 0, 1])) + isoBox("moov", payload: Data([0, 0, 0, 2]))
        let mediaBytes = isoBox("moof", payload: Data([0, 0, 0, 3])) + isoBox("mdat", payload: Data([0, 0, 0, 4]))
        try initBytes.write(to: initialization)
        try mediaBytes.write(to: media)

        let request = MediaAssemblyRequest(
            container: .fragmentedMP4,
            tracks: [MediaAssemblyTrack(
                kind: .video,
                container: .fragmentedMP4,
                initializationSegment: MediaAssemblySegment(
                    fileURL: initialization,
                    role: .initialization,
                    order: 0,
                    actualByteCount: Int64(initBytes.count)
                ),
                mediaSegments: [MediaAssemblySegment(
                    fileURL: media,
                    order: 0,
                    actualByteCount: Int64(mediaBytes.count)
                )]
            )],
            destinationURL: output
        )
        let result = try MediaAssembler.assemble(request)

        XCTAssertEqual(result.container, .fragmentedMP4)
        XCTAssertEqual(try Data(contentsOf: output), initBytes + mediaBytes)
    }

    func testInvalidFragmentedMP4NeverReplacesExistingOutput() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("media-assembler-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let initialization = directory.appendingPathComponent("init.mp4")
        let media = directory.appendingPathComponent("segment.m4s")
        let output = directory.appendingPathComponent("movie.mp4")
        try (isoBox("ftyp", payload: Data([1])) + isoBox("moov", payload: Data([2]))).write(to: initialization)
        try isoBox("mdat", payload: Data([3])).write(to: media)
        let existing = Data([9, 9, 9])
        try existing.write(to: output)

        let request = MediaAssemblyRequest(
            container: .fragmentedMP4,
            tracks: [MediaAssemblyTrack(
                kind: .video,
                container: .fragmentedMP4,
                initializationSegment: MediaAssemblySegment(fileURL: initialization, role: .initialization, order: 0, actualByteCount: 18),
                mediaSegments: [MediaAssemblySegment(fileURL: media, order: 0, actualByteCount: 9)]
            )],
            destinationURL: output
        )

        XCTAssertThrowsError(try MediaAssembler.assemble(request)) { error in
            XCTAssertEqual(error as? MediaAssemblyError, .invalidMediaData(.fragmentedMP4))
        }
        XCTAssertEqual(try Data(contentsOf: output), existing)
    }

    func testAssembleMultipleTracksFragmentedMP4() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("media-assembler-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let videoInit = directory.appendingPathComponent("video-init.mp4")
        let videoMedia = directory.appendingPathComponent("video-segment.m4s")
        let audioInit = directory.appendingPathComponent("audio-init.mp4")
        let audioMedia = directory.appendingPathComponent("audio-segment.m4s")
        let output = directory.appendingPathComponent("muxed.mp4")

        let vInitBytes = isoBox("ftyp", payload: Data([1])) + isoBox("moov", payload: Data([2]))
        let vMediaBytes = isoBox("moof", payload: Data([3])) + isoBox("mdat", payload: Data([4]))
        let aInitBytes = isoBox("ftyp", payload: Data([5])) + isoBox("moov", payload: Data([6]))
        let aMediaBytes = isoBox("moof", payload: Data([7])) + isoBox("mdat", payload: Data([8]))

        try vInitBytes.write(to: videoInit)
        try vMediaBytes.write(to: videoMedia)
        try aInitBytes.write(to: audioInit)
        try aMediaBytes.write(to: audioMedia)

        let request = MediaAssemblyRequest(
            container: .fragmentedMP4,
            tracks: [
                MediaAssemblyTrack(
                    kind: .video,
                    container: .fragmentedMP4,
                    initializationSegment: MediaAssemblySegment(fileURL: videoInit, role: .initialization, order: 0, actualByteCount: Int64(vInitBytes.count)),
                    mediaSegments: [MediaAssemblySegment(fileURL: videoMedia, order: 0, actualByteCount: Int64(vMediaBytes.count))]
                ),
                MediaAssemblyTrack(
                    kind: .audio,
                    container: .fragmentedMP4,
                    initializationSegment: MediaAssemblySegment(fileURL: audioInit, role: .initialization, order: 0, actualByteCount: Int64(aInitBytes.count)),
                    mediaSegments: [MediaAssemblySegment(fileURL: audioMedia, order: 0, actualByteCount: Int64(aMediaBytes.count))]
                )
            ],
            destinationURL: output
        )

#if canImport(AVFoundation)
        let result = try MediaAssembler.assemble(request)
        XCTAssertEqual(result.container, .fragmentedMP4)
        XCTAssertEqual(result.trackCount, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
#else
        XCTAssertThrowsError(try MediaAssembler.assemble(request)) { error in
            XCTAssertEqual(error as? MediaAssemblyError, .muxingUnavailable)
        }
#endif
    }

    func testAssembleMultipleTracksFailsAndQuarantinesWhenMuxingFails() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("media-assembler-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let videoSegment = directory.appendingPathComponent("video.ts")
        let audioSegment = directory.appendingPathComponent("audio.ts")
        let destination = directory.appendingPathComponent("stream.mp4")

        let videoBytes = makePATPacket() + makePMTPacket()
        let audioBytes = makePATPacket() + makePMTPacket()
        try videoBytes.write(to: videoSegment)
        try audioBytes.write(to: audioSegment)

        let request = MediaAssemblyRequest(
            container: .mpegTS,
            tracks: [
                MediaAssemblyTrack(
                    kind: .video,
                    container: .mpegTS,
                    mediaSegments: [
                        MediaAssemblySegment(fileURL: videoSegment, order: 0, actualByteCount: Int64(videoBytes.count))
                    ]
                ),
                MediaAssemblyTrack(
                    kind: .audio,
                    container: .mpegTS,
                    mediaSegments: [
                        MediaAssemblySegment(fileURL: audioSegment, order: 0, actualByteCount: Int64(audioBytes.count))
                    ]
                )
            ],
            destinationURL: destination
        )

#if canImport(AVFoundation)
        // Multi-track assembly must NOT return a successful 1-track output when muxing fails!
        XCTAssertThrowsError(try MediaAssembler.assemble(request)) { error in
            XCTAssertTrue(error is MediaAssemblyError)
        }
        // Incomplete single-track fallback must NOT be published at destination
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        // Verify quarantine directory was created to preserve inputs
        let parentDir = destination.deletingLastPathComponent()
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: parentDir.path)) ?? []
        let quarantineDirName = contents.first { $0.contains(".media-quarantine-") }
        XCTAssertNotNil(quarantineDirName, "Quarantine directory must be created when muxing fails")
#else
        XCTAssertThrowsError(try MediaAssembler.assemble(request)) { error in
            XCTAssertEqual(error as? MediaAssemblyError, .muxingUnavailable)
        }
#endif
    }

    func testAssemblySynchronizesAndReplacesExistingDestinationDurably() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("media-assembler-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = directory.appendingPathComponent("first.ts")
        let second = directory.appendingPathComponent("second.ts")
        let output = directory.appendingPathComponent("movie.ts")

        let firstBytes = makePATPacket()
        let secondBytes = makePMTPacket()
        try firstBytes.write(to: first)
        try secondBytes.write(to: second)

        // Existing destination file to replace
        let oldBytes = Data(repeating: 0x99, count: 500)
        try oldBytes.write(to: output)

        let request = MediaAssemblyRequest(
            container: .mpegTS,
            tracks: [MediaAssemblyTrack(
                kind: .video,
                container: .mpegTS,
                mediaSegments: [
                    MediaAssemblySegment(fileURL: first, order: 0, actualByteCount: 188),
                    MediaAssemblySegment(fileURL: second, order: 1, actualByteCount: 188)
                ]
            )],
            destinationURL: output
        )
        let result = try MediaAssembler.assemble(request)

        XCTAssertEqual(result.container, .mpegTS)
        XCTAssertEqual(result.byteCount, 376)
        XCTAssertEqual(FileManager.default.fileSize(atPath: output.path), 376)
        XCTAssertEqual(try Data(contentsOf: output), firstBytes + secondBytes)
    }

    func testAssemblyFailsGracefullyWhenTemporaryFileCreationFails() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("media-assembler-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let segmentFile = directory.appendingPathComponent("seg.ts")
        try mpegTSPacket(fill: 0x55).write(to: segmentFile)

        // Point temporary directory to a non-directory file so directory/file creation fails
        let invalidTempDir = directory.appendingPathComponent("not-a-dir")
        try Data([1, 2, 3]).write(to: invalidTempDir)

        let output = directory.appendingPathComponent("movie.ts")
        let request = MediaAssemblyRequest(
            container: .mpegTS,
            tracks: [MediaAssemblyTrack(
                kind: .video,
                container: .mpegTS,
                mediaSegments: [MediaAssemblySegment(fileURL: segmentFile, order: 0, actualByteCount: 188)]
            )],
            destinationURL: output,
            temporaryDirectoryURL: invalidTempDir
        )

        XCTAssertThrowsError(try MediaAssembler.assemble(request)) { error in
            XCTAssertEqual(error as? MediaAssemblyError, .fileOperationFailed)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testAssemblyPreservesExistingDestinationWhenStagedOutputCorrupted() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("media-assembler-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Corrupted TS segment (invalid sync byte)
        let segmentFile = directory.appendingPathComponent("bad.ts")
        var badPacket = Data(repeating: 0x00, count: 188)
        badPacket[0] = 0x00 // Should be 0x47
        try badPacket.write(to: segmentFile)

        let output = directory.appendingPathComponent("movie.ts")
        let originalBytes = Data([0xAA, 0xBB, 0xCC, 0xDD])
        try originalBytes.write(to: output)

        let request = MediaAssemblyRequest(
            container: .mpegTS,
            tracks: [MediaAssemblyTrack(
                kind: .video,
                container: .mpegTS,
                mediaSegments: [MediaAssemblySegment(fileURL: segmentFile, order: 0, actualByteCount: 188)]
            )],
            destinationURL: output
        )

        XCTAssertThrowsError(try MediaAssembler.assemble(request)) { error in
            XCTAssertEqual(error as? MediaAssemblyError, .invalidMediaData(.mpegTS))
        }
        // Original destination must remain completely untouched
        XCTAssertEqual(try Data(contentsOf: output), originalBytes)
    }

    private func makeTrack(
        _ kind: MediaAssemblyTrackKind,
        container: MediaAssemblyContainer,
        initializationName: String?,
        sizes: [Int64]
    ) -> MediaAssemblyTrack {
        let initialization = initializationName.map {
            MediaAssemblySegment(
                fileURL: URL(fileURLWithPath: "/tmp/media-assembly/\($0)"),
                role: .initialization,
                order: 0,
                actualByteCount: 25
            )
        }
        return MediaAssemblyTrack(
            kind: kind,
            container: container,
            initializationSegment: initialization,
            mediaSegments: sizes.enumerated().map { index, size in
                segment("\(kind.rawValue)-\(index).media", order: index, size: size)
            }
        )
    }

    private func segment(
        _ name: String,
        order: Int,
        size: Int64? = nil,
        expected: Int64? = nil,
        actual: Int64? = nil
    ) -> MediaAssemblySegment {
        MediaAssemblySegment(
            fileURL: URL(fileURLWithPath: "/tmp/media-assembly/\(name)"),
            order: order,
            expectedByteCount: expected ?? size,
            actualByteCount: actual ?? size
        )
    }

    private func mpegTSPacket(fill: UInt8) -> Data {
        var bytes = Data([0x47])
        bytes.append(Data(repeating: fill, count: 187))
        return bytes
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

    // MARK: - Regression Tests for Item 4

    func testMPEGTSMissingPATPMTRejectedDuringAssemblyValidation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("media-assembler-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let segment = directory.appendingPathComponent("no_pat.ts")
        let output = directory.appendingPathComponent("output.ts")
        // Headerless packets with 0x47 sync bytes only (no PAT/PMT)
        let data = mpegTSPacket(fill: 0x11) + mpegTSPacket(fill: 0x22)
        try data.write(to: segment)

        let request = MediaAssemblyRequest(
            container: .mpegTS,
            tracks: [MediaAssemblyTrack(
                kind: .video,
                container: .mpegTS,
                mediaSegments: [MediaAssemblySegment(fileURL: segment, order: 0, actualByteCount: Int64(data.count))]
            )],
            destinationURL: output
        )

        XCTAssertThrowsError(try MediaAssembler.assemble(request)) { error in
            XCTAssertTrue(error is MediaAssemblyError)
        }
    }

    func testMPEGTSDeclaringNoMediaStreamsRejected() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("media-assembler-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let segment = directory.appendingPathComponent("no_streams.ts")
        let output = directory.appendingPathComponent("output.ts")
        // PMT with 0x00 for both streams (unsupported / no media)
        let data = makePATPacket() + makePMTPacket(videoStream: 0x00, audioStream: 0x00)
        try data.write(to: segment)

        let request = MediaAssemblyRequest(
            container: .mpegTS,
            tracks: [MediaAssemblyTrack(
                kind: .video,
                container: .mpegTS,
                mediaSegments: [MediaAssemblySegment(fileURL: segment, order: 0, actualByteCount: Int64(data.count))]
            )],
            destinationURL: output
        )

        XCTAssertThrowsError(try MediaAssembler.assemble(request)) { error in
            XCTAssertTrue(error is MediaAssemblyError)
        }
    }

    func testMediaAssemblyStatesRecordedInValidationReport() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("media-assembler-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let initialization = directory.appendingPathComponent("init.mp4")
        let media = directory.appendingPathComponent("segment.m4s")
        let output = directory.appendingPathComponent("movie.mp4")
        let initBytes = isoBox("ftyp", payload: Data([0, 0, 0, 1])) + isoBox("moov", payload: Data([0, 0, 0, 2]))
        let mediaBytes = isoBox("moof", payload: Data([0, 0, 0, 3])) + isoBox("mdat", payload: Data([0, 0, 0, 4]))
        try initBytes.write(to: initialization)
        try mediaBytes.write(to: media)

        let request = MediaAssemblyRequest(
            container: .fragmentedMP4,
            tracks: [MediaAssemblyTrack(
                kind: .video,
                container: .fragmentedMP4,
                initializationSegment: MediaAssemblySegment(
                    fileURL: initialization,
                    role: .initialization,
                    order: 0,
                    actualByteCount: Int64(initBytes.count)
                ),
                mediaSegments: [MediaAssemblySegment(
                    fileURL: media,
                    order: 0,
                    actualByteCount: Int64(mediaBytes.count)
                )]
            )],
            destinationURL: output
        )
        let result = try MediaAssembler.assemble(request)

        XCTAssertEqual(result.validation.state, .outputValidated)
        XCTAssertTrue(result.validation.isStructurallyValid)
        XCTAssertNotNil(result.validation.validationDetails)
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
