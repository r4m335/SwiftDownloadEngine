import XCTest
import Foundation
@testable import DownloadEngineKit

final class DASHLifecycleTests: XCTestCase {

    func testDASHTransferRecordRoundTrip() async throws {
        let store = DASHPersistenceStore(inMemory: true)

        let record = DASHTransferRecord(
            id: "dash-rt-1",
            manifestURL: URL(string: "https://example.com/dash/manifest.mpd")!,
            outputFilename: "dash_movie.mp4",
            outputDestinationURL: URL(fileURLWithPath: "/tmp/dash_movie.mp4"),
            segmentDirectoryURL: URL(fileURLWithPath: "/tmp/dash-rt-1"),
            videoRepresentationID: "v1080",
            audioRepresentationID: "a128",
            textRepresentationID: nil,
            isTextOnly: false,
            isTTML: false,
            totalSegments: 10,
            completedSegmentOrders: [0, 1, 2],
            state: .downloading,
            assemblyState: .notStarted
        )

        try await store.save(record)

        let loaded = try await store.load(id: "dash-rt-1")
        let unwrapped = try XCTUnwrap(loaded)

        XCTAssertEqual(unwrapped.id, record.id)
        XCTAssertEqual(unwrapped.manifestURL, record.manifestURL)
        XCTAssertEqual(unwrapped.outputFilename, record.outputFilename)
        XCTAssertEqual(unwrapped.outputDestinationURL, record.outputDestinationURL)
        XCTAssertEqual(unwrapped.segmentDirectoryURL, record.segmentDirectoryURL)
        XCTAssertEqual(unwrapped.videoRepresentationID, "v1080")
        XCTAssertEqual(unwrapped.audioRepresentationID, "a128")
        XCTAssertNil(unwrapped.textRepresentationID)
        XCTAssertFalse(unwrapped.isTextOnly)
        XCTAssertEqual(unwrapped.totalSegments, 10)
        XCTAssertEqual(unwrapped.completedSegmentOrders, [0, 1, 2])
        XCTAssertEqual(unwrapped.state, .downloading)
        XCTAssertEqual(unwrapped.assemblyState, .notStarted)
        XCTAssertEqual(unwrapped.completedSegmentCount, 3)
        XCTAssertFalse(unwrapped.allSegmentsDownloaded)
        XCTAssertEqual(unwrapped.downloadFraction, 0.3, accuracy: 0.001)
    }

    func testDASHTransferRecordTextTrack() async throws {
        let store = DASHPersistenceStore(inMemory: true)

        let record = DASHTransferRecord(
            id: "dash-ttml-1",
            manifestURL: URL(string: "https://example.com/dash/subtitles.mpd")!,
            outputFilename: "subs.ttml",
            outputDestinationURL: URL(fileURLWithPath: "/tmp/subs.ttml"),
            segmentDirectoryURL: URL(fileURLWithPath: "/tmp/dash-ttml-1"),
            textRepresentationID: "sub_en",
            isTextOnly: true,
            isTTML: true,
            totalSegments: 4,
            completedSegmentOrders: [0, 1, 2, 3],
            state: .completed,
            assemblyState: .completed
        )

        try await store.save(record)

        let loaded = try await store.load(id: "dash-ttml-1")
        let unwrapped = try XCTUnwrap(loaded)

        XCTAssertTrue(unwrapped.isTextOnly)
        XCTAssertTrue(unwrapped.isTTML)
        XCTAssertTrue(unwrapped.allSegmentsDownloaded)
        XCTAssertEqual(unwrapped.downloadFraction, 1.0, accuracy: 0.001)
        XCTAssertTrue(unwrapped.isTerminal)
    }

    func testDASHPersistenceStoreUpdateOperations() async throws {
        let store = DASHPersistenceStore(inMemory: true)

        let record = DASHTransferRecord(
            id: "dash-update-test",
            manifestURL: URL(string: "https://example.com/stream.mpd")!,
            outputFilename: "stream.mp4",
            outputDestinationURL: URL(fileURLWithPath: "/tmp/stream.mp4"),
            segmentDirectoryURL: URL(fileURLWithPath: "/tmp/dash-update-test"),
            totalSegments: 5
        )

        try await store.save(record)

        // Checkpoint segment updates
        try await store.updateCompletedSegmentOrders(id: "dash-update-test", completedOrders: [0, 1])
        try await store.updateCompletedSegmentOrders(id: "dash-update-test", completedOrders: [2])

        var loaded = try await store.load(id: "dash-update-test")
        XCTAssertEqual(loaded?.completedSegmentOrders, [0, 1, 2])

        // Update state
        try await store.updateState(id: "dash-update-test", state: .paused)
        loaded = try await store.load(id: "dash-update-test")
        XCTAssertEqual(loaded?.state, .paused)

        // Update assembly state
        try await store.updateAssemblyState(id: "dash-update-test", assemblyState: .inProgress)
        loaded = try await store.load(id: "dash-update-test")
        XCTAssertEqual(loaded?.assemblyState, .inProgress)

        // Delete
        try await store.delete(id: "dash-update-test")
        loaded = try await store.load(id: "dash-update-test")
        XCTAssertNil(loaded)
    }

    func testDASHPersistenceStoreLoadAll() async throws {
        let store = DASHPersistenceStore(inMemory: true)

        for i in 1...3 {
            let record = DASHTransferRecord(
                id: "dash-item-\(i)",
                manifestURL: URL(string: "https://example.com/manifest_\(i).mpd")!,
                outputFilename: "video_\(i).mp4",
                outputDestinationURL: URL(fileURLWithPath: "/tmp/video_\(i).mp4"),
                segmentDirectoryURL: URL(fileURLWithPath: "/tmp/dir_\(i)"),
                totalSegments: 10
            )
            try await store.save(record)
        }

        let all = try await store.loadAll()
        XCTAssertEqual(all.count, 3)

        try await store.deleteAll()
        let empty = try await store.loadAll()
        XCTAssertTrue(empty.isEmpty)
    }

    func testOrchestratorSetDASHPersistenceStore() async {
        let orchestrator = StreamingDownloadOrchestrator.createDefault()
        let store = DASHPersistenceStore(inMemory: true)
        await orchestrator.setDASHPersistenceStore(store)
    }

    func testHandleSegmentCompletedUpdatesDASHCheckpoint() async throws {
        let store = DASHPersistenceStore(inMemory: true)
        let transferID = "dash-bg-complete-\(UUID().uuidString)"
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(transferID, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let record = DASHTransferRecord(
            id: transferID,
            manifestURL: URL(string: "https://example.com/stream.mpd")!,
            outputFilename: "stream.mp4",
            outputDestinationURL: tempDir.appendingPathComponent("stream.mp4"),
            segmentDirectoryURL: tempDir,
            totalSegments: 3,
            completedSegmentOrders: []
        )
        try await store.save(record)

        let orchestrator = StreamingDownloadOrchestrator(
            segmentExecutor: URLSessionStreamingSegmentExecutor(),
            dashPersistenceStore: store
        )

        let chunkURL = tempDir.appendingPathComponent("chunk-0.part")
        try Data(repeating: 0x00, count: 512).write(to: chunkURL)

        await orchestrator.handleSegmentCompleted(transferID: transferID, order: 0, partURL: chunkURL)

        let loaded = try await store.load(id: transferID)
        XCTAssertEqual(loaded?.completedSegmentOrders, Set([0]), "Segment 0 must be added to completedSegmentOrders")
    }

    func testBackgroundStreamingSegmentExecutorFastPath() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("bg_exec_fast_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let chunkFile = tempDir.appendingPathComponent("seg-1.part")
        let dummyData = Data(repeating: 0xAA, count: 1024)
        try dummyData.write(to: chunkFile)

        let manager = try BackgroundDownloadSessionManager(
            sessionIdentifier: "test.bg.fast.\(UUID().uuidString)",
            storageDirectoryURL: tempDir
        )
        let executor = BackgroundStreamingSegmentExecutor(backgroundSessionManager: manager)

        let req = StreamingSegmentTransferRequest(
            identity: StreamingSegmentIdentity(transferID: "test-fast", order: 1, value: "seg-1"),
            url: URL(string: "https://example.com/seg1.mp4")!,
            headers: [:],
            byteRange: nil,
            destinationURL: chunkFile,
            transportPolicy: .background
        )

        var reportedProgress: Double?
        try await executor.execute(req) { p in
            reportedProgress = p
        }

        XCTAssertEqual(reportedProgress, 1.0, "Fast path must immediately report 1.0 progress for existing chunk")
    }
}
