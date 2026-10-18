import XCTest
import Foundation
@testable import DM_Reverse_engineering

final class DownloadFileWriterTests: XCTestCase {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DownloadFileWriterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testDirectSeekWritesAtRequestedOffset() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("out.bin")
        let writer = try DownloadFileWriter(destinationURL: destination, totalSize: 8)

        try await writer.writeDirect(Data([4, 5, 6]), at: 3)
        try await writer.synchronize()
        try await writer.close()

        let result = try Data(contentsOf: destination)
        XCTAssertEqual(Array(result[3..<6]), [4, 5, 6])
        XCTAssertEqual(result.count, 8)
    }

    func testDirectSeekRejectsOutOfBoundsWrite() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("out.bin")
        let writer = try DownloadFileWriter(destinationURL: destination, totalSize: 4)

        do {
            try await writer.writeDirect(Data([1, 2]), at: 3)
            XCTFail("Expected invalidOffset")
        } catch let error as DownloadFileWriterError {
            XCTAssertEqual(error, .invalidOffset)
        }
    }

    func testPartFilesMergeInSpecifiedOrder() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("merged.bin")
        let temp = root.appendingPathComponent(".tmp", isDirectory: true)
        let writer = try DownloadFileWriter(
            destinationURL: destination,
            totalSize: 6,
            mode: .partFiles,
            temporaryDirectoryURL: temp
        )

        try await writer.appendPart(Data([4, 5, 6]), segmentID: 1)
        try await writer.appendPart(Data([1, 2, 3]), segmentID: 0)
        try await writer.mergePartFiles(orderedSegmentIDs: [0, 1], expectedMergedSize: 6)

        XCTAssertEqual(try Data(contentsOf: destination), Data([1, 2, 3, 4, 5, 6]))
        try await writer.cleanupPartFiles()
        try await writer.close()
    }

    func testMergeRejectsWrongExpectedSize() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("merged.bin")
        let writer = try DownloadFileWriter(
            destinationURL: destination,
            totalSize: 3,
            mode: .partFiles,
            temporaryDirectoryURL: root.appendingPathComponent(".tmp", isDirectory: true)
        )
        try await writer.appendPart(Data([1, 2, 3]), segmentID: 0)

        do {
            try await writer.mergePartFiles(orderedSegmentIDs: [0], expectedMergedSize: 4)
            XCTFail("Expected mergeLengthMismatch")
        } catch let error as DownloadFileWriterError {
            XCTAssertEqual(error, .mergeLengthMismatch(expected: 4, actual: 3))
        }
        try await writer.close()
    }

    func testDirectSeekZeroOrNegativeSizeThrows() {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("zero.bin")
        XCTAssertThrowsError(try DownloadFileWriter(destinationURL: destination, totalSize: 0)) { error in
            XCTAssertEqual(error as? DownloadFileWriterError, .invalidTotalSize)
        }
    }

    func testPreflightDiskSpaceRejectsWhenAvailableCapacityExceeded() throws {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("excessive.bin")
        // Request an absurdly large allocation that exceeds any physical drive capacity
        let excessiveBytes: Int64 = Int64.max - 1024 * 1024

        XCTAssertThrowsError(
            try DownloadFileWriter.requireSufficientDiskSpace(
                for: destination,
                requiredBytes: excessiveBytes,
                reserveBytes: 1024 * 1024
            )
        ) { error in
            guard case DownloadFileWriterError.insufficientDiskSpace(let required, _) = error else {
                XCTFail("Expected insufficientDiskSpace, got: \(error)")
                return
            }
            XCTAssertGreaterThan(required, 0)
        }
    }

    func testPreflightDiskSpacePassesWhenCapacitySufficient() throws {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("reasonable.bin")
        // Request a modest 1 KiB
        XCTAssertNoThrow(
            try DownloadFileWriter.requireSufficientDiskSpace(
                for: destination,
                requiredBytes: 1024,
                reserveBytes: 1024
            )
        )
    }
}
