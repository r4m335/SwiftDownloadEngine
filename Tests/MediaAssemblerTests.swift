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
        let firstBytes = mpegTSPacket(fill: 0x11)
        let secondBytes = mpegTSPacket(fill: 0x22)
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
