import XCTest
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@testable import DM_Reverse_engineering

final class EndToEndHTTPRangeTests: XCTestCase {
    private var server: LocalHTTPRangeServer!
    private var tempDirectory: URL!
    private var persistenceStore: DownloadPersistenceStore!
    private var coordinator: DownloadCoordinator!

    override func setUp() async throws {
        try await super.setUp()
        server = LocalHTTPRangeServer()
        try server.start()

        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("1DM_E2E_Tests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let storeURL = tempDirectory.appendingPathComponent("Store", isDirectory: true)
        persistenceStore = try DownloadPersistenceStore(storageDirectoryURL: storeURL)
        coordinator = try DownloadCoordinator(session: .shared, persistenceStore: persistenceStore)
    }

    override func tearDown() async throws {
        server?.stop()
        server = nil
        coordinator = nil
        persistenceStore = nil
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try await super.tearDown()
    }

    // MARK: - Deterministic Data Generator

    private func makePayload(size: Int, seed: UInt8 = 0x5A) -> Data {
        var data = Data(count: size)
        data.withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for i in 0..<size {
                base[i] = UInt8(((i &* 31) &+ Int(seed)) & 0xFF)
            }
        }
        return data
    }

    private final class ProgressCollector: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var snapshots: [CoordinatorProgress] = []

        func add(_ p: CoordinatorProgress) {
            lock.lock()
            snapshots.append(p)
            lock.unlock()
        }
    }

    // MARK: - 1. 1 KB File (Basic Download Correctness)

    func testE2EDownload1KB_SingleWorker() async throws {
        let size = 1024 // 1 KB
        let payload = makePayload(size: size, seed: 0x11)
        let expectedSHA = EngineSHA256.hash(data: payload)
        let path = "/file_1kb.bin"
        server.register(path: path, data: payload)

        let destURL = tempDirectory.appendingPathComponent("output_1kb.bin")
        let request = DownloadRequest(
            id: "e2e-1kb",
            url: server.url(for: path),
            destinationURL: destURL,
            configuredThreadCount: 1,
            reserveDiskBytes: 1024,
            expectedSHA256: expectedSHA
        )

        let collector = ProgressCollector()
        try await coordinator.start(request) { progress in
            collector.add(progress)
        }

        // 1. Verify physical file on disk
        let writtenData = try Data(contentsOf: destURL)
        XCTAssertEqual(writtenData.count, size)
        XCTAssertEqual(writtenData, payload)

        // 2. Verify SHA-256 checksum
        let actualSHA = EngineSHA256.hash(data: writtenData)
        XCTAssertEqual(actualSHA, expectedSHA)

        // 3. Verify persistence state
        let record = try await persistenceStore.fetch(tag: "e2e-1kb")
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.state, .completed)
        XCTAssertEqual(record?.completedBytes, Int64(size))
        XCTAssertEqual(record?.isAllSegmentsCompleted, true)
    }

    // MARK: - 2. 100 KB File (Small-File Handling)

    func testE2EDownload100KB_SmallFile() async throws {
        let size = 100 * 1024 // 100 KB
        let payload = makePayload(size: size, seed: 0x22)
        let expectedSHA = EngineSHA256.hash(data: payload)
        let path = "/file_100kb.bin"
        server.register(path: path, data: payload)

        let destURL = tempDirectory.appendingPathComponent("output_100kb.bin")
        let request = DownloadRequest(
            id: "e2e-100kb",
            url: server.url(for: path),
            destinationURL: destURL,
            configuredThreadCount: 4,
            reserveDiskBytes: 1024,
            expectedSHA256: expectedSHA
        )

        try await coordinator.start(request)

        // Verify physical file size and checksum
        let writtenData = try Data(contentsOf: destURL)
        XCTAssertEqual(writtenData.count, size)
        XCTAssertEqual(writtenData, payload)
        XCTAssertEqual(EngineSHA256.hash(data: writtenData), expectedSHA)

        let record = try await persistenceStore.fetch(tag: "e2e-100kb")
        XCTAssertEqual(record?.state, .completed)
        XCTAssertEqual(record?.completedBytes, Int64(size))
    }

    // MARK: - 3. 10 MB File (Multi-Segment Concurrency & Verification)

    func testE2EDownload10MB_MultiSegmentConcurrency() async throws {
        let size = 10 * 1024 * 1024 // 10 MiB
        let payload = makePayload(size: size, seed: 0x33)
        let expectedSHA = EngineSHA256.hash(data: payload)
        let path = "/file_10mb.bin"
        server.register(path: path, data: payload)

        let destURL = tempDirectory.appendingPathComponent("output_10mb.bin")
        let request = DownloadRequest(
            id: "e2e-10mb",
            url: server.url(for: path),
            destinationURL: destURL,
            configuredThreadCount: 10,
            reserveDiskBytes: 1024 * 1024,
            expectedSHA256: expectedSHA
        )

        try await coordinator.start(request)

        // 1. Verify physical file size and exact bytes
        let writtenData = try Data(contentsOf: destURL)
        XCTAssertEqual(writtenData.count, size)
        XCTAssertEqual(writtenData, payload)

        // 2. Verify SHA-256 checksum
        let actualSHA = EngineSHA256.hash(data: writtenData)
        XCTAssertEqual(actualSHA, expectedSHA)

        // 3. Verify segment partition integrity in persistence store
        let record = try await persistenceStore.fetch(tag: "e2e-10mb")
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.state, .completed)
        XCTAssertEqual(record?.completedBytes, Int64(size))

        // In 1DM+, 10MB file with 2MB minimum chunk threshold produces 5 segments
        let segments = record?.segments ?? []
        XCTAssertEqual(segments.count, 5)

        // Verify all segments completed and cover 0..<size without gaps or overlaps
        var expectedCursor: Int64 = 0
        for segment in segments {
            XCTAssertEqual(segment.startOffset, expectedCursor, "Gap or overlap detected at segment \(segment.id)")
            XCTAssertEqual(segment.completedBytes, segment.length, "Segment \(segment.id) was not fully downloaded")
            expectedCursor = segment.endOffset + 1
        }
        XCTAssertEqual(expectedCursor, Int64(size), "Final segment does not align with total file size")
    }

    // MARK: - 4. Multithreading Worker Count Equivalence (1, 2, 4, 10 workers)

    func testMultithreadingWorkerCountEquivalence() async throws {
        // 6 MiB file allows 3 segments with 1, 2, 4, or 10 configured workers
        let size = 6 * 1024 * 1024
        let payload = makePayload(size: size, seed: 0x44)
        let expectedSHA = EngineSHA256.hash(data: payload)
        let path = "/file_multithread.bin"
        server.register(path: path, data: payload)

        let workerCounts = [1, 2, 4, 10]

        for workers in workerCounts {
            let runID = "e2e-worker-\(workers)"
            let destURL = tempDirectory.appendingPathComponent("output_worker_\(workers).bin")

            let request = DownloadRequest(
                id: runID,
                url: server.url(for: path),
                destinationURL: destURL,
                configuredThreadCount: workers,
                reserveDiskBytes: 1024,
                expectedSHA256: expectedSHA
            )

            try await coordinator.start(request)

            let writtenData = try Data(contentsOf: destURL)
            XCTAssertEqual(writtenData.count, size, "Worker count \(workers) produced incorrect file size")
            XCTAssertEqual(writtenData, payload, "Worker count \(workers) produced corrupted bytes")

            let actualSHA = EngineSHA256.hash(data: writtenData)
            XCTAssertEqual(actualSHA, expectedSHA, "Worker count \(workers) produced mismatched SHA-256")

            let record = try await persistenceStore.fetch(tag: runID)
            XCTAssertEqual(record?.state, .completed)
            XCTAssertEqual(record?.completedBytes, Int64(size))
        }
    }

    // MARK: - 5. Zero-Byte File (Empty-File Edge Case)

    func testE2EDownloadZeroByteFile() async throws {
        let payload = Data()
        let expectedSHA = EngineSHA256.hash(data: payload)
        let path = "/empty.bin"
        server.register(path: path, data: payload)

        let destURL = tempDirectory.appendingPathComponent("output_empty.bin")
        let request = DownloadRequest(
            id: "e2e-empty",
            url: server.url(for: path),
            destinationURL: destURL,
            configuredThreadCount: 10,
            reserveDiskBytes: 1024,
            expectedSHA256: expectedSHA
        )

        try await coordinator.start(request)

        // 1. Verify physical file is 0 bytes
        let writtenData = try Data(contentsOf: destURL)
        XCTAssertEqual(writtenData.count, 0)

        // 2. Verify SHA-256 matches empty string hash
        let actualSHA = EngineSHA256.hash(data: writtenData)
        XCTAssertEqual(actualSHA, expectedSHA)
        XCTAssertEqual(actualSHA, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")

        // 3. Verify persistence state
        let record = try await persistenceStore.fetch(tag: "e2e-empty")
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.state, .completed)
        XCTAssertEqual(record?.completedBytes, 0)
    }

    // MARK: - 6. Safe Single-Stream Fallback Over Real TCP

    func testE2EServerIgnoresRangeFallbackOverRealTCP() async throws {
        let size = 200 * 1024 // 200 KB
        let payload = makePayload(size: size, seed: 0x66)
        let expectedSHA = EngineSHA256.hash(data: payload)
        let path = "/ignore_range.bin"

        // Register resource with ignoresRange = true (returns 200 OK for any request)
        server.register(path: path, data: payload, ignoresRange: true)

        let destURL = tempDirectory.appendingPathComponent("output_fallback.bin")
        let request = DownloadRequest(
            id: "e2e-fallback",
            url: server.url(for: path),
            destinationURL: destURL,
            configuredThreadCount: 4,
            reserveDiskBytes: 1024,
            expectedSHA256: expectedSHA
        )

        try await coordinator.start(request)

        let writtenData = try Data(contentsOf: destURL)
        XCTAssertEqual(writtenData.count, size)
        XCTAssertEqual(writtenData, payload)
        XCTAssertEqual(EngineSHA256.hash(data: writtenData), expectedSHA)

        let record = try await persistenceStore.fetch(tag: "e2e-fallback")
        XCTAssertEqual(record?.state, .completed)
    }

    // MARK: - 7. 64 MB File (Large File & Segment Coordination)

    func testE2EDownload64MB_LargeFileCoordination() async throws {
        let size = 64 * 1024 * 1024 // 64 MiB
        let payload = makePayload(size: size, seed: 0x77)
        let expectedSHA = EngineSHA256.hash(data: payload)
        let path = "/file_64mb.bin"
        server.register(path: path, data: payload)

        let destURL = tempDirectory.appendingPathComponent("output_64mb.bin")
        let request = DownloadRequest(
            id: "e2e-64mb",
            url: server.url(for: path),
            destinationURL: destURL,
            configuredThreadCount: 10,
            advancedMode: false,
            reserveDiskBytes: 1024 * 1024,
            expectedSHA256: expectedSHA
        )

        try await coordinator.start(request)

        // 1. Verify physical file size
        let diskAttrs = try FileManager.default.attributesOfItem(atPath: destURL.path)
        let diskSize = diskAttrs[.size] as? Int64
        XCTAssertEqual(diskSize, Int64(size))

        // 2. Verify SHA-256 checksum
        let writtenData = try Data(contentsOf: destURL)
        XCTAssertEqual(writtenData.count, size)
        let actualSHA = EngineSHA256.hash(data: writtenData)
        XCTAssertEqual(actualSHA, expectedSHA)

        // 3. Verify segment partition integrity: 10 segments in standard mode
        let record = try await persistenceStore.fetch(tag: "e2e-64mb")
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.state, .completed)
        XCTAssertEqual(record?.completedBytes, Int64(size))

        let segments = record?.segments ?? []
        XCTAssertEqual(segments.count, 10)

        var expectedCursor: Int64 = 0
        for segment in segments {
            XCTAssertEqual(segment.startOffset, expectedCursor, "Gap or overlap detected at segment \(segment.id)")
            XCTAssertEqual(segment.completedBytes, segment.length, "Segment \(segment.id) incomplete")
            expectedCursor = segment.endOffset + 1
        }
        XCTAssertEqual(expectedCursor, Int64(size))
    }
}
