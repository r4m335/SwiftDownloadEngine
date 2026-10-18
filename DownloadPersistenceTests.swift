import XCTest
import Foundation
@testable import DM_Reverse_engineering

final class DownloadPersistenceTests: XCTestCase {
    private var tempStorageURL: URL!
    private var store: DownloadPersistenceStore!

    override func setUp() async throws {
        try await super.setUp()
        tempStorageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("1DM_Persistence_Tests_\(UUID().uuidString)", isDirectory: true)
        store = try DownloadPersistenceStore(storageDirectoryURL: tempStorageURL)
    }

    override func tearDown() async throws {
        if let tempStorageURL {
            try? FileManager.default.removeItem(at: tempStorageURL)
        }
        store = nil
        try await super.tearDown()
    }

    // MARK: - 1. Record Model Serialization & Roundtrip

    func testDownloadRecordJSONRoundtrip() throws {
        let originalURL = URL(string: "https://example.com/movie.mp4")!
        let resolvedURL = URL(string: "https://cdn.example.com/movie.mp4")!
        let destinationURL = URL(fileURLWithPath: "/tmp/movie.mp4")

        let segments = [
            SegmentRecord(id: 0, startOffset: 0, endOffset: 499, length: 500, completedBytes: 250),
            SegmentRecord(id: 1, startOffset: 500, endOffset: 999, length: 500, completedBytes: 500)
        ]

        let record = DownloadRecord(
            id: "dl-12345",
            originalURL: originalURL,
            resolvedURL: resolvedURL,
            destinationURL: destinationURL,
            totalSize: 1000,
            state: .downloading,
            storageMode: .directSeek,
            eTag: "\"v1-etag\"",
            lastModified: "Wed, 21 Oct 2025 07:28:00 GMT",
            suggestedFilename: "movie.mp4",
            mimeType: "video/mp4",
            headers: ["User-Agent": "1DM-iOS/1.0", "Cookie": "session=abc"],
            segments: segments
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DownloadRecord.self, from: data)

        XCTAssertEqual(decoded.id, "dl-12345")
        XCTAssertEqual(decoded.tag, "dl-12345")
        XCTAssertEqual(decoded.originalURL, originalURL)
        XCTAssertEqual(decoded.resolvedURL, resolvedURL)
        XCTAssertEqual(decoded.destinationURL, destinationURL)
        XCTAssertEqual(decoded.totalSize, 1000)
        XCTAssertEqual(decoded.state, .downloading)
        XCTAssertEqual(decoded.storageMode, .directSeek)
        XCTAssertEqual(decoded.eTag, "\"v1-etag\"")
        XCTAssertEqual(decoded.lastModified, "Wed, 21 Oct 2025 07:28:00 GMT")
        XCTAssertEqual(decoded.suggestedFilename, "movie.mp4")
        XCTAssertEqual(decoded.mimeType, "video/mp4")
        XCTAssertEqual(decoded.headers["User-Agent"], "1DM-iOS/1.0")
        XCTAssertEqual(decoded.segments.count, 2)
        XCTAssertEqual(decoded.completedBytes, 750)
        XCTAssertEqual(decoded.remainingBytes, 250)
        XCTAssertEqual(decoded.fractionCompleted, 0.75, accuracy: 0.001)
        XCTAssertFalse(decoded.isAllSegmentsCompleted)
    }

    // MARK: - 2. Store Save & Fetch

    func testSaveAndFetchRecord() async throws {
        let record = DownloadRecord(
            id: "task-001",
            originalURL: URL(string: "https://example.com/archive.zip")!,
            destinationURL: URL(fileURLWithPath: "/tmp/archive.zip"),
            totalSize: 2000,
            state: .pending,
            storageMode: .directSeek,
            segments: [
                SegmentRecord(id: 0, startOffset: 0, endOffset: 999, length: 1000),
                SegmentRecord(id: 1, startOffset: 1000, endOffset: 1999, length: 1000)
            ]
        )

        try await store.save(record)

        let fetched = try await store.fetch(tag: "task-001")
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.id, "task-001")
        XCTAssertEqual(fetched?.totalSize, 2000)
        XCTAssertEqual(fetched?.segments.count, 2)

        let nonExistent = try await store.fetch(tag: "non-existent")
        XCTAssertNil(nonExistent)
    }

    // MARK: - 3. Segment Progress & State Transitions

    func testUpdateSegmentProgressAdvancesCompletion() async throws {
        let record = DownloadRecord(
            id: "progress-task",
            originalURL: URL(string: "https://example.com/data.bin")!,
            destinationURL: URL(fileURLWithPath: "/tmp/data.bin"),
            totalSize: 400,
            state: .downloading,
            segments: [
                SegmentRecord(id: 0, startOffset: 0, endOffset: 199, length: 200),
                SegmentRecord(id: 1, startOffset: 200, endOffset: 399, length: 200)
            ]
        )
        try await store.save(record)

        // Update segment 0 to 100 bytes
        let updated1 = try await store.updateSegmentProgress(tag: "progress-task", segmentID: 0, completedBytes: 100)
        XCTAssertEqual(updated1.completedBytes, 100)
        XCTAssertEqual(updated1.segments[0].completedBytes, 100)
        XCTAssertEqual(updated1.fractionCompleted, 0.25, accuracy: 0.001)
        XCTAssertFalse(updated1.isAllSegmentsCompleted)

        // Complete segment 0 and segment 1
        try await store.updateSegmentProgress(tag: "progress-task", segmentID: 0, completedBytes: 200)
        let updatedFinal = try await store.updateSegmentProgress(tag: "progress-task", segmentID: 1, completedBytes: 200)

        XCTAssertEqual(updatedFinal.completedBytes, 400)
        XCTAssertEqual(updatedFinal.fractionCompleted, 1.0, accuracy: 0.001)
        XCTAssertTrue(updatedFinal.isAllSegmentsCompleted)
        // Auto transitions to completed if downloading
        XCTAssertEqual(updatedFinal.state, .completed)
    }

    func testUpdateSegmentProgressBeyondLengthThrows() async throws {
        let record = DownloadRecord(
            id: "bounds-task",
            originalURL: URL(string: "https://example.com/data.bin")!,
            destinationURL: URL(fileURLWithPath: "/tmp/data.bin"),
            totalSize: 100,
            segments: [
                SegmentRecord(id: 0, startOffset: 0, endOffset: 99, length: 100)
            ]
        )
        try await store.save(record)

        do {
            try await store.updateSegmentProgress(tag: "bounds-task", segmentID: 0, completedBytes: 150)
            XCTFail("Expected invalidCompletedBytes error")
        } catch let error as DownloadPersistenceError {
            XCTAssertEqual(error, .invalidCompletedBytes(provided: 150, segmentLength: 100))
        }
    }

    func testUpdateStateTransition() async throws {
        let record = DownloadRecord(
            id: "state-task",
            originalURL: URL(string: "https://example.com/test.bin")!,
            destinationURL: URL(fileURLWithPath: "/tmp/test.bin"),
            totalSize: 100
        )
        try await store.save(record)

        let paused = try await store.updateState(tag: "state-task", state: .paused)
        XCTAssertEqual(paused.state, .paused)

        let failed = try await store.updateState(tag: "state-task", state: .failed(reason: "Network timeout"))
        XCTAssertEqual(failed.state, .failed(reason: "Network timeout"))
    }

    // MARK: - 4. Pre-Resume Validator Consistency Check

    func testValidateForResumeExactMatch() {
        let record = DownloadRecord(
            originalURL: URL(string: "https://example.com/file.bin")!,
            destinationURL: URL(fileURLWithPath: "/tmp/file.bin"),
            totalSize: 1000,
            eTag: "\"etag-123\"",
            lastModified: "Mon, 10 Oct 2026 12:00:00 GMT"
        )

        let result = record.validateForResume(
            remoteETag: "\"etag-123\"",
            remoteLastModified: "Mon, 10 Oct 2026 12:00:00 GMT",
            remoteTotalSize: 1000
        )
        XCTAssertEqual(result, .valid)
    }

    func testValidateForResumeNormalizedETagMatches() {
        let record = DownloadRecord(
            originalURL: URL(string: "https://example.com/file.bin")!,
            destinationURL: URL(fileURLWithPath: "/tmp/file.bin"),
            totalSize: 1000,
            eTag: "W/\"etag-123\"" // Weak ETag
        )

        // Remote returns strong or unquoted variant
        let result = record.validateForResume(
            remoteETag: "\"etag-123\"",
            remoteLastModified: nil,
            remoteTotalSize: 1000
        )
        XCTAssertEqual(result, .valid)
    }

    func testValidateForResumeSizeMismatch() {
        let record = DownloadRecord(
            originalURL: URL(string: "https://example.com/file.bin")!,
            destinationURL: URL(fileURLWithPath: "/tmp/file.bin"),
            totalSize: 1000,
            eTag: "\"etag-123\""
        )

        let result = record.validateForResume(
            remoteETag: "\"etag-123\"",
            remoteLastModified: nil,
            remoteTotalSize: 1500
        )
        XCTAssertEqual(result, .sizeMismatch(expected: 1000, actual: 1500))
    }

    func testValidateForResumeETagMismatch() {
        let record = DownloadRecord(
            originalURL: URL(string: "https://example.com/file.bin")!,
            destinationURL: URL(fileURLWithPath: "/tmp/file.bin"),
            totalSize: 1000,
            eTag: "\"old-etag\""
        )

        let result = record.validateForResume(
            remoteETag: "\"new-etag\"",
            remoteLastModified: nil,
            remoteTotalSize: 1000
        )
        XCTAssertEqual(
            result,
            .validatorMismatch(
                persistedETag: "\"old-etag\"",
                remoteETag: "\"new-etag\"",
                persistedLastModified: nil,
                remoteLastModified: nil
            )
        )
    }

    func testValidateForResumeLastModifiedFallback() {
        let record = DownloadRecord(
            originalURL: URL(string: "https://example.com/file.bin")!,
            destinationURL: URL(fileURLWithPath: "/tmp/file.bin"),
            totalSize: 1000,
            eTag: nil, // No ETag
            lastModified: "Mon, 10 Oct 2026 10:00:00 GMT"
        )

        let mismatch = record.validateForResume(
            remoteETag: nil,
            remoteLastModified: "Tue, 11 Oct 2026 15:00:00 GMT",
            remoteTotalSize: 1000
        )
        XCTAssertEqual(
            mismatch,
            .validatorMismatch(
                persistedETag: nil,
                remoteETag: nil,
                persistedLastModified: "Mon, 10 Oct 2026 10:00:00 GMT",
                remoteLastModified: "Tue, 11 Oct 2026 15:00:00 GMT"
            )
        )
    }

    // MARK: - 5. Collection Operations & Deletion

    func testFetchAllAndDeleteOperations() async throws {
        let r1 = DownloadRecord(
            id: "task-A",
            originalURL: URL(string: "https://example.com/a.bin")!,
            destinationURL: URL(fileURLWithPath: "/tmp/a.bin"),
            totalSize: 100
        )
        let r2 = DownloadRecord(
            id: "task-B",
            originalURL: URL(string: "https://example.com/b.bin")!,
            destinationURL: URL(fileURLWithPath: "/tmp/b.bin"),
            totalSize: 200
        )

        try await store.save(r1)
        try await store.save(r2)

        let all = try await store.fetchAll()
        XCTAssertEqual(all.count, 2)

        try await store.delete(tag: "task-A")
        let afterDelete = try await store.fetchAll()
        XCTAssertEqual(afterDelete.count, 1)
        XCTAssertEqual(afterDelete.first?.id, "task-B")

        try await store.deleteAll()
        let empty = try await store.fetchAll()
        XCTAssertTrue(empty.isEmpty)
    }

    // MARK: - 6. Export and Import JSON

    func testExportAndImportData() async throws {
        let original = DownloadRecord(
            id: "export-test",
            originalURL: URL(string: "https://example.com/doc.pdf")!,
            destinationURL: URL(fileURLWithPath: "/tmp/doc.pdf"),
            totalSize: 500,
            state: .paused,
            segments: [SegmentRecord(id: 0, startOffset: 0, endOffset: 499, length: 500, completedBytes: 120)]
        )
        try await store.save(original)

        let exportedData = try await store.exportToData(tag: "export-test")
        XCTAssertFalse(exportedData.isEmpty)

        // Clear store
        try await store.deleteAll()
        let clearedRecord = try await store.fetch(tag: "export-test")
        XCTAssertNil(clearedRecord)

        // Re-import
        let imported = try await store.importFromData(exportedData)
        XCTAssertEqual(imported.id, "export-test")
        XCTAssertEqual(imported.completedBytes, 120)
        XCTAssertEqual(imported.state, .paused)

        let fetchedAgain = try await store.fetch(tag: "export-test")
        XCTAssertNotNil(fetchedAgain)
    }
}
