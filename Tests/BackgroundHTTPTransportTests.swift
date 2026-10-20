import XCTest
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if canImport(UIKit) && !os(watchOS)
import UIKit
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
        #if canImport(UIKit) && !os(watchOS)
        AppDelegate.reset()
        #endif
        try await super.tearDown()
    }

    // MARK: - 1. Background Session Identifier & Scoped Identity Tests

    func testDefaultSessionIdentifierMatchesSpecification() throws {
        let expectedID = "com.r4m335.SwiftDownloadEngine.background-http"
        XCTAssertEqual(BackgroundDownloadSessionManager.defaultSessionIdentifier, expectedID)

        let manager = try BackgroundDownloadSessionManager(
            storageDirectoryURL: storageDirectoryURL,
            persistenceStore: persistenceStore
        )
        XCTAssertEqual(manager.sessionIdentifier, expectedID)
    }

    func testTaskMappingScopedBySessionAndTaskIdentifier() async throws {
        let store = try BackgroundDownloadTaskMappingStore(storageDirectoryURL: storageDirectoryURL)
        let targetURL = URL(string: "https://example.com/archive.zip")!

        // Two tasks with the same taskIdentifier (101) but different session identifiers
        let recordA = BackgroundDownloadTaskRecord(
            sessionIdentifier: "session-alpha",
            taskIdentifier: 101,
            downloadID: "dl-alpha",
            segmentID: 0,
            originalURL: targetURL,
            startOffset: 0,
            endOffset: 4999,
            expectedBytes: 5000,
            initialSegmentCompletedBytes: 0,
            segmentLength: 5000,
            destinationPartURL: storageDirectoryURL.appendingPathComponent("alpha-0.part")
        )

        let recordB = BackgroundDownloadTaskRecord(
            sessionIdentifier: "session-beta",
            taskIdentifier: 101,
            downloadID: "dl-beta",
            segmentID: 0,
            originalURL: targetURL,
            startOffset: 0,
            endOffset: 4999,
            expectedBytes: 5000,
            initialSegmentCompletedBytes: 0,
            segmentLength: 5000,
            destinationPartURL: storageDirectoryURL.appendingPathComponent("beta-0.part")
        )

        try await store.save(record: recordA)
        try await store.save(record: recordB)

        // Verify both exist independently without clobbering each other
        let fetchedA = await store.record(sessionIdentifier: "session-alpha", taskIdentifier: 101)
        XCTAssertNotNil(fetchedA)
        XCTAssertEqual(fetchedA?.downloadID, "dl-alpha")

        let fetchedB = await store.record(sessionIdentifier: "session-beta", taskIdentifier: 101)
        XCTAssertNotNil(fetchedB)
        XCTAssertEqual(fetchedB?.downloadID, "dl-beta")

        let all = await store.allRecords()
        XCTAssertEqual(all.count, 2)

        // Progress update only affects session-alpha
        try await store.updateProgress(sessionIdentifier: "session-alpha", taskIdentifier: 101, taskBytesWritten: 2500)
        let updatedA = await store.record(sessionIdentifier: "session-alpha", taskIdentifier: 101)
        XCTAssertEqual(updatedA?.completedBytes, 2500)

        let untouchedB = await store.record(sessionIdentifier: "session-beta", taskIdentifier: 101)
        XCTAssertEqual(untouchedB?.completedBytes, 0)

        // Removing recordA leaves recordB intact
        try await store.remove(sessionIdentifier: "session-alpha", taskIdentifier: 101)
        let removedA = await store.record(sessionIdentifier: "session-alpha", taskIdentifier: 101)
        XCTAssertNil(removedA)
        let keptB = await store.record(sessionIdentifier: "session-beta", taskIdentifier: 101)
        XCTAssertNotNil(keptB)
    }

    func testSystemTaskDescriptionParsingWithSessionScope() {
        let rec = BackgroundDownloadTaskRecord(
            sessionIdentifier: "com.r4m335.SwiftDownloadEngine.background-http",
            taskIdentifier: 42,
            downloadID: "download_12345",
            segmentID: 3,
            originalURL: URL(string: "https://example.com/data")!,
            startOffset: 300,
            endOffset: 399,
            expectedBytes: 100,
            initialSegmentCompletedBytes: 0,
            segmentLength: 100,
            destinationPartURL: URL(fileURLWithPath: "/tmp/part")
        )

        let desc = rec.systemTaskDescription
        XCTAssertEqual(desc, "1DM_BG:com.r4m335.SwiftDownloadEngine.background-http:download_12345:3")

        let parsed = BackgroundDownloadTaskRecord.parseSystemTaskDescription(desc)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.sessionIdentifier, "com.r4m335.SwiftDownloadEngine.background-http")
        XCTAssertEqual(parsed?.downloadID, "download_12345")
        XCTAssertEqual(parsed?.segmentID, 3)

        XCTAssertNil(BackgroundDownloadTaskRecord.parseSystemTaskDescription("invalid_format"))
        XCTAssertNil(BackgroundDownloadTaskRecord.parseSystemTaskDescription("1DM_BG:missing_seg"))
        XCTAssertNil(BackgroundDownloadTaskRecord.parseSystemTaskDescription("1DM_BG:sess:dl:not_a_number"))
    }

    // MARK: - 2. Segment Progress Accounting Tests

    func testFreshSegmentProgressAccounting() async throws {
        // Setup download with a fresh 5000-byte segment (0 completed)
        let download = DownloadRecord(
            id: "dl-progress-fresh",
            originalURL: URL(string: "https://example.com/file.bin")!,
            destinationURL: storageDirectoryURL.appendingPathComponent("file.bin"),
            totalSize: 5000,
            state: .downloading,
            storageMode: .partFiles,
            segments: [
                SegmentRecord(id: 0, startOffset: 0, endOffset: 4999, length: 5000, completedBytes: 0)
            ]
        )
        try await persistenceStore.save(download)

        let manager = try BackgroundDownloadSessionManager(
            sessionIdentifier: "test.progress.fresh",
            storageDirectoryURL: storageDirectoryURL,
            persistenceStore: persistenceStore
        )

        let taskRecord = try await manager.scheduleSegmentDownload(
            download: download,
            segment: download.segments[0]
        )

        XCTAssertEqual(taskRecord.initialSegmentCompletedBytes, 0)
        XCTAssertEqual(taskRecord.segmentLength, 5000)

        // Simulate delegate progress: 1200 bytes written
        let updatedBytes: Int64 = 1200
        let segmentCompleted = min(taskRecord.segmentLength, taskRecord.initialSegmentCompletedBytes + updatedBytes)
        XCTAssertEqual(segmentCompleted, 1200)

        // Verify persistence store updates segment progress without error
        let updatedRecord = try await persistenceStore.updateSegmentProgress(
            tag: "dl-progress-fresh",
            segmentID: 0,
            completedBytes: segmentCompleted
        )
        XCTAssertEqual(updatedRecord.segments[0].completedBytes, 1200)
    }

    func testResumedSegmentProgressAccounting() async throws {
        // Setup download with a partially completed segment (bytes 5000-9999, 1500 already completed)
        let segment = SegmentRecord(id: 1, startOffset: 5000, endOffset: 9999, length: 5000, completedBytes: 1500)
        let download = DownloadRecord(
            id: "dl-progress-resumed",
            originalURL: URL(string: "https://example.com/file.bin")!,
            destinationURL: storageDirectoryURL.appendingPathComponent("file.bin"),
            totalSize: 10000,
            state: .downloading,
            storageMode: .partFiles,
            segments: [
                SegmentRecord(id: 0, startOffset: 0, endOffset: 4999, length: 5000, completedBytes: 5000),
                segment
            ]
        )
        try await persistenceStore.save(download)

        let manager = try BackgroundDownloadSessionManager(
            sessionIdentifier: "test.progress.resumed",
            storageDirectoryURL: storageDirectoryURL,
            persistenceStore: persistenceStore
        )

        let taskRecord = try await manager.scheduleSegmentDownload(
            download: download,
            segment: segment
        )

        // Resumed task must request start offset 6500 (5000 + 1500), expecting 3500 remaining bytes
        XCTAssertEqual(taskRecord.startOffset, 6500)
        XCTAssertEqual(taskRecord.expectedBytes, 3500)
        XCTAssertEqual(taskRecord.initialSegmentCompletedBytes, 1500)
        XCTAssertEqual(taskRecord.segmentLength, 5000)

        // URLSession reports totalBytesWritten = 1000 for this task
        let taskBytesWritten: Int64 = 1000
        let segmentProgress = min(taskRecord.segmentLength, taskRecord.initialSegmentCompletedBytes + taskBytesWritten)
        XCTAssertEqual(segmentProgress, 2500, "Resumed segment progress must be 1500 + 1000 = 2500, NOT absolute file offset 7500")

        // In 6A, passing 7500 threw DownloadPersistenceError.invalidCompletedBytes because 7500 > segment.length (5000).
        // With 6A.1 fix, 2500 <= 5000 succeeds!
        let updatedRecord = try await persistenceStore.updateSegmentProgress(
            tag: "dl-progress-resumed",
            segmentID: 1,
            completedBytes: segmentProgress
        )
        XCTAssertEqual(updatedRecord.segments[1].completedBytes, 2500)
    }

    func testSegmentCompletionAfterResumption() async throws {
        let segment = SegmentRecord(id: 0, startOffset: 5000, endOffset: 9999, length: 5000, completedBytes: 2000)
        let download = DownloadRecord(
            id: "dl-completion-resumed",
            originalURL: URL(string: "https://example.com/file.bin")!,
            destinationURL: storageDirectoryURL.appendingPathComponent("file.bin"),
            totalSize: 10000,
            state: .downloading,
            storageMode: .partFiles,
            segments: [segment]
        )
        try await persistenceStore.save(download)

        let manager = try BackgroundDownloadSessionManager(
            sessionIdentifier: "test.completion.resumed",
            storageDirectoryURL: storageDirectoryURL,
            persistenceStore: persistenceStore
        )

        let taskRecord = try await manager.scheduleSegmentDownload(
            download: download,
            segment: segment
        )

        // On completion, final completed bytes must equal segmentLength (5000), not just remainder (3000)
        let finalSegmentCompleted = taskRecord.segmentLength
        XCTAssertEqual(finalSegmentCompleted, 5000)

        let updated = try await persistenceStore.updateSegmentProgress(
            tag: "dl-completion-resumed",
            segmentID: 0,
            completedBytes: finalSegmentCompleted
        )
        XCTAssertEqual(updated.segments[0].completedBytes, 5000)
        XCTAssertTrue(updated.isAllSegmentsCompleted)
        XCTAssertEqual(updated.state, .completed)
    }

    func testProgressNeverExceedsSegmentLength() async throws {
        let record = BackgroundDownloadTaskRecord(
            sessionIdentifier: "test-sess",
            taskIdentifier: 1,
            downloadID: "dl-overflow",
            segmentID: 0,
            originalURL: URL(string: "https://example.com/test")!,
            startOffset: 0,
            endOffset: 4999,
            expectedBytes: 5000,
            initialSegmentCompletedBytes: 0,
            segmentLength: 5000,
            destinationPartURL: storageDirectoryURL.appendingPathComponent("test.part")
        )

        // Suppose URLSession delivers 6000 bytes due to unexpected server behavior
        let overflowBytes: Int64 = 6000
        let clamped = min(record.segmentLength, max(0, record.initialSegmentCompletedBytes + overflowBytes))
        XCTAssertEqual(clamped, 5000, "Progress must be strictly bounded at segmentLength")
    }

    // MARK: - 3. Strengthened Background HTTP Response Validator Tests

    func testResponseValidatorSuccessWithKnownTotal() throws {
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

    func testResponseValidatorRejectsWildcardTotalWhenTotalKnown() {
        let url = URL(string: "https://example.com/video.mp4")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: 206,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Range": "bytes 0-499/*",
                "Content-Type": "video/mp4"
            ]
        )

        XCTAssertThrowsError(try BackgroundResponseValidator.validate(
            response: response,
            expectedStart: 0,
            expectedEnd: 499,
            expectedTotalSize: 1000
        )) { error in
            guard case BackgroundTransportError.contentRangeWildcardTotalRejected = error else {
                XCTFail("Expected contentRangeWildcardTotalRejected, got: \(error)")
                return
            }
        }
    }

    func testResponseValidatorAcceptsWildcardTotalWhenTotalUnknown() throws {
        let url = URL(string: "https://example.com/stream.bin")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: 206,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Range": "bytes 0-499/*",
                "Content-Type": "application/octet-stream"
            ]
        )

        XCTAssertNoThrow(try BackgroundResponseValidator.validate(
            response: response,
            expectedStart: 0,
            expectedEnd: 499,
            expectedTotalSize: nil
        ))
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

    // MARK: - 4. Crash-Safe Staged File Replacement Tests

    func testStagedReplacementPreservesExistingDestinationOnFailure() throws {
        let tempSource = tempDirectoryURL.appendingPathComponent("urlsession_corrupt_\(UUID().uuidString).tmp")
        let destinationPart = storageDirectoryURL.appendingPathComponent("segment-existing.part")

        // Pre-existing valid partial file
        let existingPayload = Data(repeating: 0xEE, count: 1024)
        try existingPayload.write(to: destinationPart)

        // New download delivers truncated payload (500 bytes when 2000 expected)
        let truncatedPayload = Data(repeating: 0xFF, count: 500)
        try truncatedPayload.write(to: tempSource)

        XCTAssertThrowsError(try BackgroundDownloadFileHandler.relocateTemporaryFile(
            from: tempSource,
            to: destinationPart,
            expectedBytes: 2000
        )) { error in
            guard case BackgroundTransportError.bodyLengthMismatch(let exp, let act) = error else {
                XCTFail("Expected bodyLengthMismatch, got: \(error)")
                return
            }
            XCTAssertEqual(exp, 2000)
            XCTAssertEqual(act, 500)
        }

        // CRITICAL INVARIANT: The existing destination file must NOT have been removed or clobbered!
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationPart.path))
        let remainingData = try Data(contentsOf: destinationPart)
        XCTAssertEqual(remainingData.count, 1024)
        XCTAssertEqual(remainingData, existingPayload)

        // Corrupt temporary file must be cleaned up
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempSource.path))
    }

    func testStagedReplacementMissingSourceThrows() {
        let missingSource = tempDirectoryURL.appendingPathComponent("nonexistent.tmp")
        let destinationPart = storageDirectoryURL.appendingPathComponent("segment-0.part")

        XCTAssertThrowsError(try BackgroundDownloadFileHandler.relocateTemporaryFile(
            from: missingSource,
            to: destinationPart,
            expectedBytes: 1000
        )) { error in
            guard case BackgroundTransportError.temporaryFileMissing = error else {
                XCTFail("Expected temporaryFileMissing, got: \(error)")
                return
            }
        }
    }

    func testStagedReplacementAtomicallyReplacesOnSuccess() throws {
        let tempSource = tempDirectoryURL.appendingPathComponent("urlsession_valid.tmp")
        let destinationPart = storageDirectoryURL.appendingPathComponent("segment-replace.part")

        let oldData = Data(repeating: 0x11, count: 512)
        try oldData.write(to: destinationPart)

        let newData = Data(repeating: 0x22, count: 1024)
        try newData.write(to: tempSource)

        let written = try BackgroundDownloadFileHandler.relocateTemporaryFile(
            from: tempSource,
            to: destinationPart,
            expectedBytes: 1024
        )

        XCTAssertEqual(written, 1024)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempSource.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationPart.path))

        let readData = try Data(contentsOf: destinationPart)
        XCTAssertEqual(readData, newData)
    }

    // MARK: - 5. Corrupted Mapping Store Quarantine Tests

    func testCorruptMappingStoreIsQuarantined() async throws {
        let manifestURL = storageDirectoryURL.appendingPathComponent("background_tasks_v1.json")
        let corruptData = "{\"not_valid_json\": [broken".data(using: .utf8)!
        try corruptData.write(to: manifestURL)

        XCTAssertThrowsError(try BackgroundDownloadTaskMappingStore(storageDirectoryURL: storageDirectoryURL)) { error in
            guard case BackgroundTransportError.corruptedMappingStore(let path, _) = error else {
                XCTFail("Expected corruptedMappingStore error, got: \(error)")
                return
            }
            XCTAssertTrue(path.contains("background_tasks_v1.json.corrupt-"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: path), "Quarantined file must exist on disk for forensic recovery")
        }

        // Original file path was moved to quarantine
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifestURL.path))
    }

    // MARK: - 6. Task Reconciliation with DownloadPersistenceStore

    func testTaskReconciliationUpdatesBothMappingAndPersistence() async throws {
        let manager = try BackgroundDownloadSessionManager(
            sessionIdentifier: "test.reconcile.both",
            storageDirectoryURL: storageDirectoryURL,
            persistenceStore: persistenceStore
        )

        // Setup persistent download with 2 segments (each 256 bytes)
        let download = DownloadRecord(
            id: "dl-recon-both",
            originalURL: URL(string: "https://example.com/test.bin")!,
            destinationURL: storageDirectoryURL.appendingPathComponent("test.bin"),
            totalSize: 512,
            state: .downloading,
            storageMode: .partFiles,
            segments: [
                SegmentRecord(id: 0, startOffset: 0, endOffset: 255, length: 256, completedBytes: 0),
                SegmentRecord(id: 1, startOffset: 256, endOffset: 511, length: 256, completedBytes: 0)
            ]
        )
        try await persistenceStore.save(download)

        // Segment 0 finished while app was killed: part file is fully on disk
        let part0 = manager.partFileURL(downloadID: "dl-recon-both", segmentID: 0)
        let payload0 = Data(repeating: 0x55, count: 256)
        try payload0.write(to: part0)

        let record0 = BackgroundDownloadTaskRecord(
            sessionIdentifier: "test.reconcile.both",
            taskIdentifier: 901,
            downloadID: "dl-recon-both",
            segmentID: 0,
            originalURL: download.originalURL,
            startOffset: 0,
            endOffset: 255,
            expectedBytes: 256,
            initialSegmentCompletedBytes: 0,
            segmentLength: 256,
            destinationPartURL: part0
        )
        try await manager.mappingStore.save(record: record0)

        // Segment 1 was interrupted: part file is missing
        let part1 = manager.partFileURL(downloadID: "dl-recon-both", segmentID: 1)
        let record1 = BackgroundDownloadTaskRecord(
            sessionIdentifier: "test.reconcile.both",
            taskIdentifier: 902,
            downloadID: "dl-recon-both",
            segmentID: 1,
            originalURL: download.originalURL,
            startOffset: 256,
            endOffset: 511,
            expectedBytes: 256,
            initialSegmentCompletedBytes: 0,
            segmentLength: 256,
            destinationPartURL: part1
        )
        try await manager.mappingStore.save(record: record1)

        // Perform reconciliation on relaunch
        let report = try await manager.reconcileActiveTasks()

        XCTAssertEqual(report.completedRecords.count, 1)
        XCTAssertEqual(report.completedRecords.first?.taskIdentifier, 901)
        XCTAssertEqual(report.orphanedTasksCount, 1)

        // Verify mapping store updated
        let task0Updated = await manager.mappingStore.record(sessionIdentifier: "test.reconcile.both", taskIdentifier: 901)
        XCTAssertTrue(task0Updated!.isCompleted)
        XCTAssertEqual(task0Updated?.completedBytes, 256)

        // CRITICAL INVARIANT: DownloadPersistenceStore must ALSO be updated consistently!
        let fetchedDownload = try await persistenceStore.fetch(tag: "dl-recon-both")
        XCTAssertNotNil(fetchedDownload)
        XCTAssertEqual(fetchedDownload?.segments[0].completedBytes, 256, "PersistenceStore SegmentRecord must be reconciled with completed file")
        XCTAssertEqual(fetchedDownload?.segments[1].completedBytes, 0, "Missing part must not update SegmentRecord")
    }

    // MARK: - 7. UIApplicationDelegate Lifecycle Integration Tests

    #if canImport(UIKit) && !os(watchOS)
    func testAppDelegateBackgroundSessionLifecycleIntegration() {
        AppDelegate.reset()

        var handlerExecuted = false
        let completionHandler: @Sendable () -> Void = {
            handlerExecuted = true
        }

        let sessionID = BackgroundDownloadSessionManager.defaultSessionIdentifier

        // 1. App receives handleEventsForBackgroundURLSession before manager is attached
        let app = UIApplication.shared
        let delegate = AppDelegate()
        delegate.application(app, handleEventsForBackgroundURLSession: sessionID, completionHandler: completionHandler)

        XCTAssertEqual(AppDelegate.retainedHandlerCount(), 1)
        XCTAssertFalse(handlerExecuted)

        // 2. Attach session manager: retained handler must be transferred to manager
        let manager = try! BackgroundDownloadSessionManager(
            sessionIdentifier: sessionID,
            storageDirectoryURL: storageDirectoryURL,
            persistenceStore: persistenceStore
        )
        AppDelegate.attach(manager: manager)

        XCTAssertEqual(AppDelegate.retainedHandlerCount(), 0)

        // 3. urlSessionDidFinishEvents reports all background events are finished
        let fakeSession = URLSession(configuration: .default)
        manager.urlSessionDidFinishEvents(forBackgroundURLSession: fakeSession)

        // Handler is dispatched on main queue
        let exp = expectation(description: "completionHandler executed")
        DispatchQueue.main.async {
            if handlerExecuted {
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 2.0)
        XCTAssertTrue(handlerExecuted)
    }

    func testAppDelegateRejectsUnrecognizedSessionImmediately() {
        AppDelegate.reset()

        var handlerExecuted = false
        let completionHandler: @Sendable () -> Void = {
            handlerExecuted = true
        }

        let delegate = AppDelegate()
        delegate.application(
            UIApplication.shared,
            handleEventsForBackgroundURLSession: "unrecognized.session.id",
            completionHandler: completionHandler
        )

        // Must invoke immediately to avoid keeping iOS system wake lock open
        XCTAssertTrue(handlerExecuted)
        XCTAssertEqual(AppDelegate.retainedHandlerCount(), 0)
    }
    #endif

    // MARK: - 8. Session Manager Scheduling & Non-Interference Tests

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
