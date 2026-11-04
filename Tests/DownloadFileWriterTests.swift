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

    func testFailedMergePreservesExistingDestinationFile() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("existing_complete.bin")
        let originalData = Data([0xAA, 0xBB, 0xCC, 0xDD])
        try originalData.write(to: destination)

        let part1 = root.appendingPathComponent("part1.tmp")
        try Data([1, 2, 3]).write(to: part1)

        // Merge with expected size 10 (which fails because part1 only has 3 bytes)
        XCTAssertThrowsError(
            try DownloadFileWriter.mergeFiles(
                partURLs: [part1],
                destinationURL: destination,
                expectedMergedSize: 10
            )
        )

        // Existing destination MUST still be intact and uncorrupted!
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        let restoredData = try Data(contentsOf: destination)
        XCTAssertEqual(restoredData, originalData, "Failed merge must not delete or corrupt existing completed destination")
    }

    func testFailedMergePartFilesPreservesExistingDestinationFile() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("existing_complete_part.bin")
        let originalData = Data([0x11, 0x22, 0x33, 0x44])
        try originalData.write(to: destination)

        let writer = try DownloadFileWriter(
            destinationURL: destination,
            totalSize: 4,
            mode: .partFiles,
            temporaryDirectoryURL: root.appendingPathComponent(".tmp", isDirectory: true)
        )

        try await writer.appendPart(Data([1, 2]), segmentID: 0)

        // Failing merge with length mismatch
        do {
            try await writer.mergePartFiles(orderedSegmentIDs: [0], expectedMergedSize: 10)
            XCTFail("Expected mergeLengthMismatch error")
        } catch {
            // Error expected
        }

        // Destination must remain intact with original data
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        let restoredData = try Data(contentsOf: destination)
        XCTAssertEqual(restoredData, originalData, "Failed mergePartFiles must not destroy existing destination")
        try await writer.close()
    }

    func testFileManagerFileSizeExtensionCrossPlatform() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("testfile.bin")
        let data = Data(repeating: 0x55, count: 1234)
        try data.write(to: file)

        let sizeFromPath = FileManager.default.fileSize(atPath: file.path)
        let sizeFromURL = FileManager.default.fileSize(at: file)
        XCTAssertEqual(sizeFromPath, 1234)
        XCTAssertEqual(sizeFromURL, 1234)

        let nonexistent = FileManager.default.fileSize(atPath: root.appendingPathComponent("missing.bin").path)
        XCTAssertNil(nonexistent)
    }

    // MARK: - Bug #21: Preallocation, Indeterminate Capacity & Merge Durability Tests

    func testEmptyPartListRejectsMerge() throws {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("empty_merge.bin")
        XCTAssertThrowsError(
            try DownloadFileWriter.mergeFiles(
                partURLs: [],
                destinationURL: destination
            )
        ) { error in
            XCTAssertEqual(error as? DownloadFileWriterError, .unsupportedOperationForMode)
        }
    }

    func testMergePartFilesRejectsEmptySegments() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("empty_parts.bin")
        let writer = try DownloadFileWriter(
            destinationURL: destination,
            totalSize: 10,
            mode: .partFiles,
            temporaryDirectoryURL: root.appendingPathComponent(".tmp", isDirectory: true)
        )
        do {
            try await writer.mergePartFiles(orderedSegmentIDs: [])
            XCTFail("Expected unsupportedOperationForMode on empty segment list")
        } catch let error as DownloadFileWriterError {
            XCTAssertEqual(error, .unsupportedOperationForMode)
        }
        try await writer.close()
    }

    func testIndeterminateDiskSpaceReportAllowsDownloadToProceed() throws {
        // When capacity cannot be determined, isCapacityDetermined is false
        let report = DiskSpaceReport(requiredBytes: 10_000_000, availableBytes: 0, isCapacityDetermined: false)
        XCTAssertTrue(report.hasEnoughSpace, "Indeterminate disk capacity must allow download to proceed")

        // In contrast, when capacity is genuinely 0 bytes (full disk), hasEnoughSpace is false
        let fullDiskReport = DiskSpaceReport(requiredBytes: 10_000_000, availableBytes: 0, isCapacityDetermined: true)
        XCTAssertFalse(fullDiskReport.hasEnoughSpace, "Determined 0 bytes available must reject insufficient space")
    }

    func testDirectSeekPreallocationCleanupOnFailure() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("dir_conflict.bin")
        // Create directory at destination path so FileHandle(forWritingTo:) fails
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        XCTAssertThrowsError(
            try DownloadFileWriter(destinationURL: destination, totalSize: 1024, mode: .directSeek)
        )
    }

    func testMergeFilesSynchronizesDestinationDurably() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("synced_dest.bin")
        let part1 = root.appendingPathComponent("part1.part")
        let part2 = root.appendingPathComponent("part2.part")

        let chunk1 = Data(repeating: 0x11, count: 512)
        let chunk2 = Data(repeating: 0x22, count: 512)
        try chunk1.write(to: part1)
        try chunk2.write(to: part2)

        try DownloadFileWriter.mergeFiles(
            partURLs: [part1, part2],
            destinationURL: destination,
            expectedMergedSize: 1024
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        let merged = try Data(contentsOf: destination)
        XCTAssertEqual(merged.count, 1024)
        XCTAssertEqual(merged.prefix(512), chunk1)
        XCTAssertEqual(merged.suffix(512), chunk2)
    }
}
