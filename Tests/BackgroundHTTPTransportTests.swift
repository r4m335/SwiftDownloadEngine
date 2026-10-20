import XCTest
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@testable import DM_Reverse_engineering

final class BackgroundHTTPTransportTests: XCTestCase {

    private var tempDirectoryURL: URL!
    private var storageDirectoryURL: URL!
    private var persistenceStore: DownloadPersistenceStore!

    override func setUp() async throws {
        try await super.setUp()
        tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackgroundHTTPTransportTests_\(UUID().uuidString)", isDirectory: true)
        storageDirectoryURL = tempDirectoryURL.appendingPathComponent("Storage", isDirectory: true)
        try FileManager.default.createDirectory(at: storageDirectoryURL, withIntermediateDirectories: true)
        persistenceStore = try DownloadPersistenceStore(storageDirectoryURL: storageDirectoryURL.appendingPathComponent("Meta", isDirectory: true))
    }

    override func tearDown() async throws {
        if let temp = tempDirectoryURL {
            try? FileManager.default.removeItem(at: temp)
        }
        persistenceStore = nil
        try await super.tearDown()
    }

    // MARK: - 1. Persistent Task Mapping Store Tests

    func testTaskMappingPersistenceAndRoundtrip() async throws {
        let store = try BackgroundDownloadTaskMappingStore(storageDirectoryURL: storageDirectoryURL)

        let targetURL = URL(string: "https://example.com/archive.zip")!
        let partURL = storageDirectoryURL.appendingPathComponent("test_segment-0.part")

        let record1 = BackgroundDownloadTaskRecord(
            taskIdentifier: 101,
            downloadID: "dl-alpha",
            segmentID: 0,
            originalURL: targetURL,
            startOffset: 0,
            endOffset: 4999,
            expectedBytes: 5000,
            destinationPartURL: partURL,
            completedBytes: 1500
        )

        let record2 = BackgroundDownloadTaskRecord(
            taskIdentifier: 102,
            downloadID: "dl-alpha",
            segmentID: 1,
            originalURL: targetURL,
            startOffset: 5000,
            endOffset: 9999,
            expectedBytes: 5000,
            destinationPartURL: storageDirectoryURL.appendingPathComponent("test_segment-1.part"),
            completedBytes: 0
        )

        try await store.save(record: record1)
        try await store.save(record: record2)

        // Lookup tests
        let fetched1 = await store.record(forTaskIdentifier: 101)
        XCTAssertNotNil(fetched1)
        XCTAssertEqual(fetched1?.downloadID, "dl-alpha")
        XCTAssertEqual(fetched1?.segmentID, 0)
        XCTAssertEqual(fetched1?.completedBytes, 1500)

        let forDownload = await store.records(forDownloadID: "dl-alpha")
        XCTAssertEqual(forDownload.count, 2)

        let specific = await store.record(forDownloadID: "dl-alpha", segmentID: 1)
        XCTAssertEqual(specific?.taskIdentifier, 102)

        // Progress update
        try await store.updateProgress(taskIdentifier: 101, completedBytes: 3000)
        let updated1 = await store.record(forTaskIdentifier: 101)
        XCTAssertEqual(updated1?.completedBytes, 3000)

        // Mark completed
        try await store.markCompleted(taskIdentifier: 101, finalBytes: 5000)
        let completed1 = await store.record(forTaskIdentifier: 101)
        XCTAssertTrue(completed1!.isCompleted)
        XCTAssertEqual(completed1?.completedBytes, 5000)

        // Recreate store from disk to verify atomic persistence
        let reloadedStore = try BackgroundDownloadTaskMappingStore(storageDirectoryURL: storageDirectoryURL)
        let reloaded1 = await reloadedStore.record(forTaskIdentifier: 101)
        XCTAssertNotNil(reloaded1)
        XCTAssertEqual(reloaded1?.completedBytes, 5000)
        XCTAssertTrue(reloaded1!.isCompleted)

        let reloaded2 = await reloadedStore.record(forTaskIdentifier: 102)
        XCTAssertNotNil(reloaded2)
        XCTAssertEqual(reloaded2?.segmentID, 1)

        // Remove records
        try await store.remove(taskIdentifier: 101)
        let removed101 = await store.record(forTaskIdentifier: 101)
        XCTAssertNil(removed101)

        try await store.removeRecords(forDownloadID: "dl-alpha")
        let remainingAlpha = await store.records(forDownloadID: "dl-alpha")
        XCTAssertTrue(remainingAlpha.isEmpty)
    }

    func testSystemTaskDescriptionParsing() {
        let rec = BackgroundDownloadTaskRecord(
            taskIdentifier: 42,
            downloadID: "download_12345",
            segmentID: 3,
            originalURL: URL(string: "https://example.com/data")!,
            startOffset: 300,
            endOffset: 399,
            expectedBytes: 100,
            destinationPartURL: URL(fileURLWithPath: "/tmp/part")
        )

        let desc = rec.systemTaskDescription
        XCTAssertEqual(desc, "1DM_BG:download_12345:3")

        let parsed = BackgroundDownloadTaskRecord.parseSystemTaskDescription(desc)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.downloadID, "download_12345")
        XCTAssertEqual(parsed?.segmentID, 3)

        XCTAssertNil(BackgroundDownloadTaskRecord.parseSystemTaskDescription("invalid_format"))
        XCTAssertNil(BackgroundDownloadTaskRecord.parseSystemTaskDescription("1DM_BG:missing_seg"))
        XCTAssertNil(BackgroundDownloadTaskRecord.parseSystemTaskDescription("1DM_BG:dl:not_a_number"))
    }

    // MARK: - 2. Background HTTP Response Validator Tests

    func testResponseValidatorSuccess() throws {
        let url = URL(string: "https://example.com/video.mp4")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: 206,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Range": "bytes 0-499/1000",
                "Content-Type": "video/mp4"
            ]
        )

        XCTAssertNoThrow(try BackgroundResponseValidator.validate(
            response: response,
            expectedStart: 0,
            expectedEnd: 499,
            expectedTotalSize: 1000
        ))
    }

    func testResponseValidatorRejects200OKForRangeRequest() {
        let url = URL(string: "https://example.com/video.mp4")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Length": "1000",
                "Content-Type": "video/mp4"
            ]
        )

        XCTAssertThrowsError(try BackgroundResponseValidator.validate(
            response: response,
            expectedStart: 0,
            expectedEnd: 499,
            expectedTotalSize: 1000
        )) { error in
            guard case BackgroundTransportError.unexpectedStatus(let expected, let actual) = error else {
                XCTFail("Expected unexpectedStatus error, got: \(error)")
                return
            }
            XCTAssertEqual(expected, 206)
            XCTAssertEqual(actual, 200)
        }
    }

    func testResponseValidatorDetectsBoundaryMismatch() {
        let url = URL(string: "https://example.com/video.mp4")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: 206,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Range": "bytes 100-599/1000",
                "Content-Type": "application/octet-stream"
            ]
        )

        XCTAssertThrowsError(try BackgroundResponseValidator.validate(
            response: response,
            expectedStart: 0,
            expectedEnd: 499,
            expectedTotalSize: 1000
        )) { error in
            guard case BackgroundTransportError.contentRangeMismatch(let expS, let expE, let actS, let actE) = error else {
                XCTFail("Expected contentRangeMismatch, got: \(error)")
                return
            }
            XCTAssertEqual(expS, 0)
            XCTAssertEqual(expE, 499)
            XCTAssertEqual(actS, 100)
            XCTAssertEqual(actE, 599)
        }
    }

    func testResponseValidatorDetectsTotalSizeMismatch() {
        let url = URL(string: "https://example.com/video.mp4")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: 206,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Range": "bytes 0-499/2000",
                "Content-Type": "application/octet-stream"
            ]
        )

        XCTAssertThrowsError(try BackgroundResponseValidator.validate(
            response: response,
            expectedStart: 0,
            expectedEnd: 499,
            expectedTotalSize: 1000
        )) { error in
            guard case BackgroundTransportError.totalSizeMismatch(let exp, let act) = error else {
                XCTFail("Expected totalSizeMismatch, got: \(error)")
                return
            }
            XCTAssertEqual(exp, 1000)
            XCTAssertEqual(act, 2000)
        }
    }

    func testResponseValidatorDetectsHTMLErrorPage() {
        let url = URL(string: "https://example.com/download")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: 206,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Range": "bytes 0-499/1000",
                "Content-Type": "text/html; charset=utf-8"
            ]
        )

        XCTAssertThrowsError(try BackgroundResponseValidator.validate(
            response: response,
            expectedStart: 0,
            expectedEnd: 499,
            expectedTotalSize: 1000
        )) { error in
            guard case BackgroundTransportError.htmlErrorPageReceived(let ct) = error else {
                XCTFail("Expected htmlErrorPageReceived, got: \(error)")
                return
            }
            XCTAssertTrue(ct.contains("text/html"))
        }
    }

    // MARK: - 3. Crash-Safe File Handler Tests

    func testCrashSafeFileRelocationSuccess() throws {
        let tempSource = tempDirectoryURL.appendingPathComponent("urlsession_temp_\(UUID().uuidString).tmp")
        let destinationPart = storageDirectoryURL.appendingPathComponent("segment-0.part")

        let payload = Data(repeating: 0xAA, count: 4096)
        try payload.write(to: tempSource)

        let written = try BackgroundDownloadFileHandler.relocateTemporaryFile(
            from: tempSource,
            to: destinationPart,
            expectedBytes: 4096
        )

        XCTAssertEqual(written, 4096)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempSource.path), "Source temp file must be moved")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationPart.path), "Destination part file must exist")

        let readData = try Data(contentsOf: destinationPart)
        XCTAssertEqual(readData.count, 4096)
        XCTAssertEqual(readData, payload)
    }

    func testCrashSafeFileRelocationReplacesExistingPart() throws {
        let tempSource = tempDirectoryURL.appendingPathComponent("urlsession_temp_new.tmp")
        let destinationPart = storageDirectoryURL.appendingPathComponent("segment-0.part")

        // Pre-create an old partial file
        let oldPayload = Data(repeating: 0xBB, count: 1024)
        try oldPayload.write(to: destinationPart)

        // New payload
        let newPayload = Data(repeating: 0xCC, count: 2048)
        try newPayload.write(to: tempSource)

        let written = try BackgroundDownloadFileHandler.relocateTemporaryFile(
            from: tempSource,
            to: destinationPart,
            expectedBytes: 2048
        )

        XCTAssertEqual(written, 2048)
        let readData = try Data(contentsOf: destinationPart)
        XCTAssertEqual(readData.count, 2048)
        XCTAssertEqual(readData, newPayload)
    }

    func testCrashSafeFileRelocationRejectsSizeMismatch() throws {
        let tempSource = tempDirectoryURL.appendingPathComponent("urlsession_corrupt.tmp")
        let destinationPart = storageDirectoryURL.appendingPathComponent("segment-0.part")

        // Only 500 bytes downloaded when 1000 expected
        let truncatedPayload = Data(repeating: 0xDD, count: 500)
        try truncatedPayload.write(to: tempSource)

        XCTAssertThrowsError(try BackgroundDownloadFileHandler.relocateTemporaryFile(
            from: tempSource,
            to: destinationPart,
            expectedBytes: 1000
        )) { error in
            guard case BackgroundTransportError.bodyLengthMismatch(let exp, let act) = error else {
                XCTFail("Expected bodyLengthMismatch, got: \(error)")
                return
            }
            XCTAssertEqual(exp, 1000)
            XCTAssertEqual(act, 500)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationPart.path), "Destination must not exist on corrupt mismatch")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempSource.path), "Corrupt source must be cleaned up")
    }

    // MARK: - 4. Task Reconciliation Tests

    func testTaskReconciliationWithCompletedAndOrphanedParts() async throws {
        let manager = try BackgroundDownloadSessionManager(
            sessionIdentifier: "test.reconciliation.\(UUID().uuidString)",
            storageDirectoryURL: storageDirectoryURL,
            persistenceStore: persistenceStore
        )

        // 1. Setup a record whose part file is complete on disk
        let part1 = manager.partFileURL(downloadID: "dl-recon", segmentID: 0)
        let payload1 = Data(repeating: 0x11, count: 256)
        try payload1.write(to: part1)

        let recordCompletedOnDisk = BackgroundDownloadTaskRecord(
            taskIdentifier: 901,
            downloadID: "dl-recon",
            segmentID: 0,
            originalURL: URL(string: "https://example.com/test")!,
            startOffset: 0,
            endOffset: 255,
            expectedBytes: 256,
            destinationPartURL: part1,
            completedBytes: 256
        )
        try await manager.mappingStore.save(record: recordCompletedOnDisk)

        // 2. Setup an orphaned record whose part file was missing/interrupted
        let part2 = manager.partFileURL(downloadID: "dl-recon", segmentID: 1)
        let recordMissingPart = BackgroundDownloadTaskRecord(
            taskIdentifier: 902,
            downloadID: "dl-recon",
            segmentID: 1,
            originalURL: URL(string: "https://example.com/test")!,
            startOffset: 256,
            endOffset: 511,
            expectedBytes: 256,
            destinationPartURL: part2,
            completedBytes: 50
        )
        try await manager.mappingStore.save(record: recordMissingPart)

        // 3. Reconcile
        let report = try await manager.reconcileActiveTasks()

        // Since tasks 901 and 902 are not running in a live session:
        // - 901 has full part file on disk -> reconciled as completed
        // - 902 has no part file -> identified as orphaned
        XCTAssertEqual(report.completedRecords.count, 1)
        XCTAssertEqual(report.completedRecords.first?.taskIdentifier, 901)
        XCTAssertEqual(report.orphanedTasksCount, 1)

        let updated901 = await manager.mappingStore.record(forTaskIdentifier: 901)
        XCTAssertTrue(updated901!.isCompleted)
    }

    // MARK: - 5. Session Manager Scheduling & Non-Interference Tests

    func testScheduleSegmentDownloadAndTaskLifecycle() async throws {
        let manager = try BackgroundDownloadSessionManager(
            sessionIdentifier: "test.scheduling.\(UUID().uuidString)",
            storageDirectoryURL: storageDirectoryURL,
            persistenceStore: persistenceStore
        )

        let download = DownloadRecord(
            id: "dl-test-sched",
            originalURL: URL(string: "https://example.com/sample.bin")!,
            destinationURL: storageDirectoryURL.appendingPathComponent("sample.bin"),
            totalSize: 1024,
            state: .downloading,
            storageMode: .partFiles,
            segments: [
                SegmentRecord(id: 0, startOffset: 0, endOffset: 511, length: 512, completedBytes: 0),
                SegmentRecord(id: 1, startOffset: 512, endOffset: 1023, length: 512, completedBytes: 0)
            ]
        )
        try await persistenceStore.save(download)

        // Schedule segment 0
        let taskRecord = try await manager.scheduleSegmentDownload(
            download: download,
            segment: download.segments[0]
        )

        XCTAssertEqual(taskRecord.downloadID, "dl-test-sched")
        XCTAssertEqual(taskRecord.segmentID, 0)
        XCTAssertEqual(taskRecord.startOffset, 0)
        XCTAssertEqual(taskRecord.endOffset, 511)
        XCTAssertEqual(taskRecord.expectedBytes, 512)

        // Assert mapping is persisted
        let active = await manager.activeTasks(for: "dl-test-sched")
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active.first?.segmentID, 0)

        // Cancel tasks
        await manager.cancelTasks(for: "dl-test-sched")
        let activeAfterCancel = await manager.activeTasks(for: "dl-test-sched")
        XCTAssertTrue(activeAfterCancel.isEmpty)
    }

    func testAlreadyCompletedSegmentReturnsCompletedRecordWithoutNetworkTask() async throws {
        let manager = try BackgroundDownloadSessionManager(
            sessionIdentifier: "test.already.completed.\(UUID().uuidString)",
            storageDirectoryURL: storageDirectoryURL,
            persistenceStore: persistenceStore
        )

        let download = DownloadRecord(
            id: "dl-already-done",
            originalURL: URL(string: "https://example.com/done.bin")!,
            destinationURL: storageDirectoryURL.appendingPathComponent("done.bin"),
            totalSize: 500,
            state: .downloading,
            storageMode: .partFiles,
            segments: [
                SegmentRecord(id: 0, startOffset: 0, endOffset: 499, length: 500, completedBytes: 500)
            ]
        )

        let rec = try await manager.scheduleSegmentDownload(
            download: download,
            segment: download.segments[0]
        )

        XCTAssertTrue(rec.isCompleted)
        XCTAssertEqual(rec.completedBytes, 500)
        XCTAssertEqual(rec.taskIdentifier, -1)
    }
}
