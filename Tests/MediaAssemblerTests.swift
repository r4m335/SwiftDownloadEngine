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
}
