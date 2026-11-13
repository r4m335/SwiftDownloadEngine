import Foundation
import XCTest
@testable import DM_Reverse_engineering

final class BatchURLExpanderTests: XCTestCase {

    // MARK: - 1. Numeric Pattern Expansion

    func testNumericPatternExpansionWithZeroPadding() throws {
        let pattern = "https://example.com/downloads/file[001-050].zip"
        let urls = try BatchURLExpander.expandPattern(pattern)

        XCTAssertEqual(urls.count, 50, "Pattern [001-050] must generate exactly 50 URLs")
        XCTAssertEqual(urls.first?.absoluteString, "https://example.com/downloads/file001.zip")
        XCTAssertEqual(urls[24].absoluteString, "https://example.com/downloads/file025.zip")
        XCTAssertEqual(urls.last?.absoluteString, "https://example.com/downloads/file050.zip")
    }

    func testNumericPatternExpansionWithoutPadding() throws {
        let pattern = "https://cdn.example.com/episodes/ep[1-10].mp4"
        let urls = try BatchURLExpander.expandPattern(pattern)

        XCTAssertEqual(urls.count, 10)
        XCTAssertEqual(urls.first?.absoluteString, "https://cdn.example.com/episodes/ep1.mp4")
        XCTAssertEqual(urls[8].absoluteString, "https://cdn.example.com/episodes/ep9.mp4")
        XCTAssertEqual(urls.last?.absoluteString, "https://cdn.example.com/episodes/ep10.mp4")
    }

    func testNumericPatternExpansionTwoDigitPadding() throws {
        let pattern = "https://site.org/data/chunk_[01-20]_v2.bin"
        let urls = try BatchURLExpander.expandPattern(pattern)

        XCTAssertEqual(urls.count, 20)
        XCTAssertEqual(urls.first?.absoluteString, "https://site.org/data/chunk_01_v2.bin")
        XCTAssertEqual(urls[8].absoluteString, "https://site.org/data/chunk_09_v2.bin")
        XCTAssertEqual(urls[9].absoluteString, "https://site.org/data/chunk_10_v2.bin")
        XCTAssertEqual(urls.last?.absoluteString, "https://site.org/data/chunk_20_v2.bin")
    }

    func testPatternExpansionPreservesPortAndQueryParameters() throws {
        let pattern = "https://example.com:8443/api/v1/export[1-3].csv?format=raw&auth=token123"
        let urls = try BatchURLExpander.expandPattern(pattern)

        XCTAssertEqual(urls.count, 3)
        XCTAssertEqual(urls[0].absoluteString, "https://example.com:8443/api/v1/export1.csv?format=raw&auth=token123")
        XCTAssertEqual(urls[1].absoluteString, "https://example.com:8443/api/v1/export2.csv?format=raw&auth=token123")
        XCTAssertEqual(urls[2].absoluteString, "https://example.com:8443/api/v1/export3.csv?format=raw&auth=token123")
    }

    // MARK: - 2. Alphabetic Pattern Expansion

    func testAlphabeticPatternExpansionLowercase() throws {
        let pattern = "https://example.com/archive/part[a-e].tar.gz"
        let urls = try BatchURLExpander.expandPattern(pattern)

        XCTAssertEqual(urls.count, 5)
        XCTAssertEqual(urls[0].absoluteString, "https://example.com/archive/parta.tar.gz")
        XCTAssertEqual(urls[1].absoluteString, "https://example.com/archive/partb.tar.gz")
        XCTAssertEqual(urls[2].absoluteString, "https://example.com/archive/partc.tar.gz")
        XCTAssertEqual(urls[3].absoluteString, "https://example.com/archive/partd.tar.gz")
        XCTAssertEqual(urls[4].absoluteString, "https://example.com/archive/parte.tar.gz")
    }

    func testAlphabeticPatternExpansionUppercase() throws {
        let pattern = "https://example.com/documents/section_[A-C].pdf"
        let urls = try BatchURLExpander.expandPattern(pattern)

        XCTAssertEqual(urls.count, 3)
        XCTAssertEqual(urls[0].absoluteString, "https://example.com/documents/section_A.pdf")
        XCTAssertEqual(urls[1].absoluteString, "https://example.com/documents/section_B.pdf")
        XCTAssertEqual(urls[2].absoluteString, "https://example.com/documents/section_C.pdf")
    }

    // MARK: - 3. Multi-Bracket Cartesian Product Expansion

    func testMultiBracketCartesianProduct() throws {
        let pattern = "https://example.com/s[01-02]/ep[1-3].mp4"
        let urls = try BatchURLExpander.expandPattern(pattern)

        XCTAssertEqual(urls.count, 6)
        XCTAssertEqual(urls[0].absoluteString, "https://example.com/s01/ep1.mp4")
        XCTAssertEqual(urls[1].absoluteString, "https://example.com/s01/ep2.mp4")
        XCTAssertEqual(urls[2].absoluteString, "https://example.com/s01/ep3.mp4")
        XCTAssertEqual(urls[3].absoluteString, "https://example.com/s02/ep1.mp4")
        XCTAssertEqual(urls[4].absoluteString, "https://example.com/s02/ep2.mp4")
        XCTAssertEqual(urls[5].absoluteString, "https://example.com/s02/ep3.mp4")
    }

    // MARK: - 4. Pattern Validation & Malformed Input Handling

    func testInvertedNumericRangeThrowsError() {
        let pattern = "https://example.com/file[50-10].zip"
        XCTAssertThrowsError(try BatchURLExpander.expandPattern(pattern)) { error in
            guard let batchError = error as? BatchExpansionError else {
                XCTFail("Expected BatchExpansionError")
                return
            }
            if case .invalidRange = batchError {
                // Expected
            } else {
                XCTFail("Expected invalidRange error, got: \(batchError)")
            }
        }
    }

    func testInvertedAlphabeticRangeThrowsError() {
        let pattern = "https://example.com/file[z-a].zip"
        XCTAssertThrowsError(try BatchURLExpander.expandPattern(pattern)) { error in
            guard let batchError = error as? BatchExpansionError else {
                XCTFail("Expected BatchExpansionError")
                return
            }
            if case .invalidRange = batchError {
                // Expected
            } else {
                XCTFail("Expected invalidRange error, got: \(batchError)")
            }
        }
    }

    func testMismatchedBracketThrowsError() {
        let unclosed = "https://example.com/file[001-050.zip"
        XCTAssertThrowsError(try BatchURLExpander.expandPattern(unclosed))

        let extraBracket = "https://example.com/file[001-050]].zip"
        XCTAssertThrowsError(try BatchURLExpander.expandPattern(extraBracket))
    }

    func testInvalidRangeSyntaxThrowsError() {
        let malformed = "https://example.com/file[001-050-100].zip"
        XCTAssertThrowsError(try BatchURLExpander.expandPattern(malformed))

        let negative = "https://example.com/file[-1-10].zip"
        XCTAssertThrowsError(try BatchURLExpander.expandPattern(negative))

        let mixedCase = "https://example.com/file[a-Z].zip"
        XCTAssertThrowsError(try BatchURLExpander.expandPattern(mixedCase))
    }

    func testRangeExceedingSafetyLimitThrowsError() {
        let huge = "https://example.com/file[1-5000].zip"
        XCTAssertThrowsError(try BatchURLExpander.expandPattern(huge, maxCount: 100)) { error in
            guard let batchError = error as? BatchExpansionError else {
                XCTFail("Expected BatchExpansionError")
                return
            }
            if case .rangeTooLarge(let count, let limit) = batchError {
                XCTAssertEqual(count, 5000)
                XCTAssertEqual(limit, 100)
            } else {
                XCTFail("Expected rangeTooLarge error, got: \(batchError)")
            }
        }
    }

    func testEmptyPatternThrowsError() {
        XCTAssertThrowsError(try BatchURLExpander.expandPattern("   ")) { error in
            XCTAssertEqual(error as? BatchExpansionError, .emptyInput)
        }
    }

    // MARK: - 5. Multi-Link Text Import & Deduplication

    func testParseMultiLineTextIgnoresCommentsAndBlankLines() {
        let text = """
        # Software Release Downloads
        https://example.com/installer.dmg

        // Mirror link
        https://example.com/checksums.txt
        # End of list
        """

        let result = BatchURLExpander.parseMultiLineText(text)
        XCTAssertEqual(result.validURLs.count, 2)
        XCTAssertEqual(result.validURLs[0].absoluteString, "https://example.com/installer.dmg")
        XCTAssertEqual(result.validURLs[1].absoluteString, "https://example.com/checksums.txt")
        XCTAssertEqual(result.duplicateCount, 0)
        XCTAssertTrue(result.rejectedEntries.isEmpty)
    }

    func testParseMultiLineTextDeduplicatesRepeatedURLs() {
        let text = """
        https://example.com/file1.zip
        https://example.com/file2.zip
        https://example.com/file1.zip
        https://example.com/file2.zip
        https://example.com/file3.zip
        """

        let result = BatchURLExpander.parseMultiLineText(text)
        XCTAssertEqual(result.validURLs.count, 3)
        XCTAssertEqual(result.duplicateCount, 2)
        XCTAssertEqual(result.validURLs.map(\.absoluteString), [
            "https://example.com/file1.zip",
            "https://example.com/file2.zip",
            "https://example.com/file3.zip"
        ])
    }

    func testParseMultiLineTextCapturesRejectedEntries() {
        let text = """
        https://valid.com/file.zip
        ftp://unsupported.com/file.bin
        not a url at all
        https://valid.com/image.png
        """

        let result = BatchURLExpander.parseMultiLineText(text)
        XCTAssertEqual(result.validURLs.count, 2)
        XCTAssertEqual(result.rejectedEntries.count, 2)
        XCTAssertTrue(result.rejectedEntries.contains(where: { $0.rawText.contains("ftp://") }))
        XCTAssertTrue(result.rejectedEntries.contains(where: { $0.rawText.contains("not a url at all") }))
    }

    func testParseMultiLineTextExpandsEmbeddedPatterns() {
        let text = """
        https://example.com/file[01-03].zip
        https://example.com/single.mp4
        """

        let result = BatchURLExpander.parseMultiLineText(text, expandPatterns: true)
        XCTAssertEqual(result.validURLs.count, 4)
        XCTAssertEqual(result.validURLs[0].absoluteString, "https://example.com/file01.zip")
        XCTAssertEqual(result.validURLs[1].absoluteString, "https://example.com/file02.zip")
        XCTAssertEqual(result.validURLs[2].absoluteString, "https://example.com/file03.zip")
        XCTAssertEqual(result.validURLs[3].absoluteString, "https://example.com/single.mp4")
    }

    // MARK: - 6. BatchDownloadItem & Category Classification

    func testBatchDownloadItemClassification() {
        let videoURL = URL(string: "https://example.com/movie.mp4")!
        let musicURL = URL(string: "https://example.com/song.mp3")!
        let docURL = URL(string: "https://example.com/document.pdf")!
        let archiveURL = URL(string: "https://example.com/data.tar.gz")!

        let videoItem = BatchDownloadItem(url: videoURL)
        let musicItem = BatchDownloadItem(url: musicURL)
        let docItem = BatchDownloadItem(url: docURL)
        let archiveItem = BatchDownloadItem(url: archiveURL)

        XCTAssertEqual(videoItem.filename, "movie.mp4")
        XCTAssertEqual(videoItem.category, .videos)

        XCTAssertEqual(musicItem.filename, "song.mp3")
        XCTAssertEqual(musicItem.category, .audio)

        XCTAssertEqual(docItem.filename, "document.pdf")
        XCTAssertEqual(docItem.category, .documents)

        XCTAssertEqual(archiveItem.filename, "data.tar.gz")
        XCTAssertEqual(archiveItem.category, .archives)
    }

    // MARK: - 7. ViewModel Batch Add Integration

    #if canImport(SwiftUI)
    @MainActor
    func testViewModelBatchAddDownloads() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("batch_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storeURL = tempDir.appendingPathComponent("Store", isDirectory: true)
        let downloadsDir = tempDir.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: storeURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)

        let engine = try DownloadEngine(storageDirectoryURL: storeURL, maxConcurrentDownloads: 4)
        let viewModel = DownloadManagerViewModel(engine: engine, downloadsDirectory: downloadsDir)

        let items = [
            BatchDownloadItem(url: URL(string: "https://example.com/part1.bin")!, isSelected: true),
            BatchDownloadItem(url: URL(string: "https://example.com/part2.bin")!, isSelected: true),
            BatchDownloadItem(url: URL(string: "https://example.com/part3.bin")!, isSelected: false) // Unselected
        ]

        let snapshots = try await viewModel.addBatchDownloads(items: items, autoStart: false)
        XCTAssertEqual(snapshots.count, 2, "Only selected items must be enqueued")

        // Both part1 and part2 should be tracked in viewModel
        let snapshotFilenames = snapshots.map { $0.destinationURL.lastPathComponent }
        XCTAssertTrue(snapshotFilenames.contains("part1.bin"))
        XCTAssertTrue(snapshotFilenames.contains("part2.bin"))
    }
    #endif
}

