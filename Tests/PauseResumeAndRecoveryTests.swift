import XCTest
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

@testable import DM_Reverse_engineering

final class PauseResumeAndRecoveryTests: XCTestCase {
    private var server: LocalHTTPRangeServer!
    private var tempDirectory: URL!
    private var persistenceStore: DownloadPersistenceStore!
    private var coordinator: DownloadCoordinator!

    override func setUp() async throws {
        try await super.setUp()
        #if os(Linux)
        signal(SIGPIPE, SIG_IGN)
        #endif
        server = LocalHTTPRangeServer()
        try server.start()

        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("1DM_PauseResume_Tests_\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - Helper Data Generator

    private func makePayload(size: Int, seed: UInt8 = 0x7E) -> Data {
        var data = Data(count: size)
        data.withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for i in 0..<size {
                base[i] = UInt8(((i &* 37) &+ Int(seed)) & 0xFF)
            }
        }
        return data
    }

    // MARK: - Phase 2A: Pause and Resume Tests

    func testPauseAndResumeSingleWorker() async throws {
        let size = 400 * 1024 // 400 KB
        let payload = makePayload(size: size, seed: 0x11)
        let expectedSHA = EngineSHA256.hash(data: payload)
        let path = "/pause_single.bin"
        // Introduce small 3ms delay per chunk so download can be paused midway
        server.register(path: path, data: payload, chunkDelayMs: 3)

        let destURL = tempDirectory.appendingPathComponent("pause_single.bin")
        let request = DownloadRequest(
            id: "pause-single",
            url: server.url(for: path),
            destinationURL: destURL,
            configuredThreadCount: 1,
            reserveDiskBytes: 1024,
            expectedSHA256: expectedSHA
        )

        // Launch download in background task
        let downloadTask = Task {
            try await coordinator.start(request)
        }

        // Wait until partial progress is made
        var paused = false
        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 20_000_000)
            if let prog = await coordinator.currentProgress(for: "pause-single"), prog.bytesReceived > 0 {
                try await coordinator.pause(id: "pause-single")
                paused = true
                break
            }
        }
        XCTAssertTrue(paused, "Failed to initiate pause during active download")

        // Await task completion (it throws CancellationError on cooperative pause)
        _ = try? await downloadTask.value

        // Verify state is .paused
        let record = try await persistenceStore.fetch(tag: "pause-single")
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.state, .paused)
        XCTAssertGreaterThan(record?.completedBytes ?? 0, 0)
        XCTAssertLessThan(record?.completedBytes ?? 0, Int64(size))

        // Resume download to completion
        try await coordinator.resume(request)

        // Verify final file size and SHA-256
        let writtenData = try Data(contentsOf: destURL)
        XCTAssertEqual(writtenData.count, size)
        XCTAssertEqual(writtenData, payload)
        XCTAssertEqual(EngineSHA256.hash(data: writtenData), expectedSHA)

        let finalRecord = try await persistenceStore.fetch(tag: "pause-single")
        XCTAssertEqual(finalRecord?.state, .completed)
        XCTAssertEqual(finalRecord?.completedBytes, Int64(size))
    }

    func testPauseAndResumeMultiWorkerConcurrent() async throws {
        let size = 4 * 1024 * 1024 // 4 MiB (2 segments of 2 MiB)
        let payload = makePayload(size: size, seed: 0x22)
        let expectedSHA = EngineSHA256.hash(data: payload)
        let path = "/pause_multi.bin"
        server.register(path: path, data: payload, chunkDelayMs: 2)

        let destURL = tempDirectory.appendingPathComponent("pause_multi.bin")
        let request = DownloadRequest(
            id: "pause-multi",
            url: server.url(for: path),
            destinationURL: destURL,
            configuredThreadCount: 4,
            reserveDiskBytes: 1024,
            expectedSHA256: expectedSHA
        )

        let downloadTask = Task {
            try await coordinator.start(request)
        }

        // Wait for workers to begin writing slices
        var paused = false
        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 30_000_000)
            if let prog = await coordinator.currentProgress(for: "pause-multi"), prog.bytesReceived > 100_000 {
                try await coordinator.pause(id: "pause-multi")
                paused = true
                break
            }
        }
        XCTAssertTrue(paused)

        _ = try? await downloadTask.value

        let intermediateRecord = try await persistenceStore.fetch(tag: "pause-multi")
        XCTAssertEqual(intermediateRecord?.state, .paused)
        XCTAssertGreaterThan(intermediateRecord?.completedBytes ?? 0, 0)

        // Resume multi-worker download
        try await coordinator.resume(request)

        let finalData = try Data(contentsOf: destURL)
        XCTAssertEqual(finalData.count, size)
        XCTAssertEqual(finalData, payload)
        XCTAssertEqual(EngineSHA256.hash(data: finalData), expectedSHA)

        let finalRecord = try await persistenceStore.fetch(tag: "pause-multi")
        XCTAssertEqual(finalRecord?.state, .completed)
        XCTAssertEqual(finalRecord?.isAllSegmentsCompleted, true)
    }

    func testPauseImmediatelyAfterStarting() async throws {
        let size = 100 * 1024 // 100 KB
        let payload = makePayload(size: size, seed: 0x33)
        let expectedSHA = EngineSHA256.hash(data: payload)
        let path = "/pause_immediate.bin"
        server.register(path: path, data: payload, chunkDelayMs: 5)

        let destURL = tempDirectory.appendingPathComponent("pause_immediate.bin")
        let request = DownloadRequest(
            id: "pause-immediate",
            url: server.url(for: path),
            destinationURL: destURL,
            configuredThreadCount: 2,
            reserveDiskBytes: 1024,
            expectedSHA256: expectedSHA
        )

        let downloadTask = Task {
            try await coordinator.start(request)
        }

        // Immediately request pause
        try await coordinator.pause(id: "pause-immediate")
        _ = try? await downloadTask.value

        let record = try await persistenceStore.fetch(tag: "pause-immediate")
        XCTAssertNotNil(record)
        // Must settle in .paused without deadlock or invalid state
        XCTAssertTrue(record?.state == .paused || record?.state == .completed)

        // Resuming must still complete properly
        try await coordinator.resume(request)

        let writtenData = try Data(contentsOf: destURL)
        XCTAssertEqual(writtenData.count, size)
        XCTAssertEqual(EngineSHA256.hash(data: writtenData), expectedSHA)
    }

    func testPauseAndResumeNearlyCompleted() async throws {
        let size = 800 * 1024 // 800 KB
        let payload = makePayload(size: size, seed: 0x44)
        let expectedSHA = EngineSHA256.hash(data: payload)
        let path = "/nearly_done.bin"
        server.register(path: path, data: payload, chunkDelayMs: 6)

        let destURL = tempDirectory.appendingPathComponent("nearly_done.bin")
        let request = DownloadRequest(
            id: "nearly-done",
            url: server.url(for: path),
            destinationURL: destURL,
            configuredThreadCount: 1,
            reserveDiskBytes: 1024,
            expectedSHA256: expectedSHA
        )

        let downloadTask = Task {
            try await coordinator.start(request)
        }

        // Wait until at least 65% completed
        var pausedNearEnd = false
        for _ in 0..<100 {
            try await Task.sleep(nanoseconds: 10_000_000)
            if let prog = await coordinator.currentProgress(for: "nearly-done"),
               prog.fractionCompleted >= 0.65 && prog.fractionCompleted < 0.95 {
                try await coordinator.pause(id: "nearly-done")
                pausedNearEnd = true
                break
            }
        }
        XCTAssertTrue(pausedNearEnd)

        _ = try? await downloadTask.value

        let partialRecord = try await persistenceStore.fetch(tag: "nearly-done")
        XCTAssertEqual(partialRecord?.state, .paused)
        XCTAssertGreaterThanOrEqual(partialRecord?.fractionCompleted ?? 0, 0.60)
        XCTAssertLessThan(partialRecord?.fractionCompleted ?? 0, 1.0)

        // Resume remaining bytes to completion
        server.register(path: path, data: payload, chunkDelayMs: 0)
        try await coordinator.resume(request)

        let finalData = try Data(contentsOf: destURL)
        XCTAssertEqual(finalData.count, size)
        XCTAssertEqual(finalData, payload)
        XCTAssertEqual(EngineSHA256.hash(data: finalData), expectedSHA)
    }

    func testRepeatedPauseAndResumeCycles() async throws {
        let size = 600 * 1024 // 600 KB
        let payload = makePayload(size: size, seed: 0x55)
        let expectedSHA = EngineSHA256.hash(data: payload)
        let path = "/pause_cycles.bin"
        server.register(path: path, data: payload, chunkDelayMs: 2)

        let destURL = tempDirectory.appendingPathComponent("pause_cycles.bin")
        let request = DownloadRequest(
            id: "pause-cycles",
            url: server.url(for: path),
            destinationURL: destURL,
            configuredThreadCount: 2,
            reserveDiskBytes: 1024,
            expectedSHA256: expectedSHA
        )

        // Perform 3 consecutive pause/resume cycles
        for cycle in 1...3 {
            let task = Task {
                try await coordinator.resume(request)
            }

            try await Task.sleep(nanoseconds: 25_000_000)
            try? await coordinator.pause(id: "pause-cycles")
            _ = try? await task.value

            let rec = try await persistenceStore.fetch(tag: "pause-cycles")
            XCTAssertTrue(rec?.state == .paused || rec?.state == .completed, "Cycle \(cycle) left invalid state")
        }

        // Final resume to completion
        try await coordinator.resume(request)

        let finalData = try Data(contentsOf: destURL)
        XCTAssertEqual(finalData.count, size)
        XCTAssertEqual(finalData, payload)
        XCTAssertEqual(EngineSHA256.hash(data: finalData), expectedSHA)
    }

    func testCancelOneDownloadWhileAnotherRunsConcurrently() async throws {
        let size = 400 * 1024
        let payloadA = makePayload(size: size, seed: 0xAA)
        let payloadB = makePayload(size: size, seed: 0xBB)
        let expectedSHAB = EngineSHA256.hash(data: payloadB)

        server.register(path: "/task_a.bin", data: payloadA, chunkDelayMs: 4)
        server.register(path: "/task_b.bin", data: payloadB, chunkDelayMs: 2)

        let destA = tempDirectory.appendingPathComponent("task_a.bin")
        let destB = tempDirectory.appendingPathComponent("task_b.bin")

        let reqA = DownloadRequest(id: "task-A", url: server.url(for: "/task_a.bin"), destinationURL: destA)
        let reqB = DownloadRequest(id: "task-B", url: server.url(for: "/task_b.bin"), destinationURL: destB, expectedSHA256: expectedSHAB)

        let taskA = Task { try await coordinator.start(reqA) }
        let taskB = Task { try await coordinator.start(reqB) }

        try await Task.sleep(nanoseconds: 30_000_000)

        // Cancel task A while task B is still running
        try await coordinator.cancel(id: "task-A", deleteDestinationFile: false)
        _ = try? await taskA.value

        // Task B must continue and finish successfully
        try await taskB.value

        // Verify Task A was cancelled
        let recA = try await persistenceStore.fetch(tag: "task-A")
        XCTAssertEqual(recA?.state, .cancelled)

        // Verify Task B completed cleanly
        let recB = try await persistenceStore.fetch(tag: "task-B")
        XCTAssertEqual(recB?.state, .completed)
        let dataB = try Data(contentsOf: destB)
        XCTAssertEqual(dataB, payloadB)
    }

    func testCompletedDownloadCannotBePausedOrCancelled() async throws {
        let size = 10 * 1024
        let payload = makePayload(size: size, seed: 0x66)
        let path = "/completed_guard.bin"
        server.register(path: path, data: payload)

        let destURL = tempDirectory.appendingPathComponent("completed_guard.bin")
        let request = DownloadRequest(id: "completed-guard", url: server.url(for: path), destinationURL: destURL)

        try await coordinator.start(request)

        let recBefore = try await persistenceStore.fetch(tag: "completed-guard")
        XCTAssertEqual(recBefore?.state, .completed)

        // Attempt pause on already-completed download
        try await coordinator.pause(id: "completed-guard")
        let recAfterPause = try await persistenceStore.fetch(tag: "completed-guard")
        XCTAssertEqual(recAfterPause?.state, .completed, "Pause altered completed download state!")

        // Attempt cancel on already-completed download (without delete)
        try await coordinator.cancel(id: "completed-guard", deleteDestinationFile: false)
        let recAfterCancel = try await persistenceStore.fetch(tag: "completed-guard")
        XCTAssertEqual(recAfterCancel?.state, .completed, "Cancel altered completed download state!")
    }

    // MARK: - Phase 2B: Process Interruption & Recovery

    func testInterruptedProcessRecoveryFromPersistedCheckpoint() async throws {
        let size = 4 * 1024 * 1024 // 4 MiB
        let payload = makePayload(size: size, seed: 0x77)
        let expectedSHA = EngineSHA256.hash(data: payload)
        let path = "/interrupted_process.bin"
        server.register(path: path, data: payload)

        let destURL = tempDirectory.appendingPathComponent("interrupted_process.bin")
        let storeDir = tempDirectory.appendingPathComponent("InterruptedStore", isDirectory: true)

        // 1. Simulate process 1: writing checkpoint with state = .downloading (unhandled crash/kill)
        let seg0 = SegmentRecord(id: 0, startOffset: 0, endOffset: 2 * 1024 * 1024 - 1, length: 2 * 1024 * 1024, completedBytes: 2 * 1024 * 1024)
        let seg1 = SegmentRecord(id: 1, startOffset: 2 * 1024 * 1024, endOffset: 4 * 1024 * 1024 - 1, length: 2 * 1024 * 1024, completedBytes: 500 * 1024)

        let interruptedRecord = DownloadRecord(
            id: "proc-recover",
            originalURL: server.url(for: path),
            resolvedURL: server.url(for: path),
            destinationURL: destURL,
            totalSize: Int64(size),
            state: .downloading, // Mid-download crash marker
            storageMode: .directSeek,
            eTag: "\"etag-\(expectedSHA.prefix(12))\"",
            segments: [seg0, seg1]
        )

        let initialStore = try DownloadPersistenceStore(storageDirectoryURL: storeDir)
        try await initialStore.save(interruptedRecord)

        // Write partial file on disk: seg0 complete, seg1 first 500 KB written
        let writer = try DownloadFileWriter(destinationURL: destURL, totalSize: Int64(size))
        try await writer.writeDirect(payload.subdata(in: 0..<Int(seg0.length)), at: 0)
        try await writer.writeDirect(payload.subdata(in: Int(seg1.startOffset)..<Int(seg1.startOffset) + 500 * 1024), at: seg1.startOffset)
        try await writer.synchronize()
        try await writer.close()

        // 2. Simulate process 2 (Fresh Process Launch):
        // Fresh store and fresh coordinator with zero in-memory active tasks
        let freshStore = try DownloadPersistenceStore(storageDirectoryURL: storeDir)
        let freshCoordinator = try DownloadCoordinator(session: .shared, persistenceStore: freshStore)

        let resumeRequest = DownloadRequest(
            id: "proc-recover",
            url: server.url(for: path),
            destinationURL: destURL,
            configuredThreadCount: 2,
            reserveDiskBytes: 1024,
            expectedSHA256: expectedSHA
        )

        // Resume download
        try await freshCoordinator.resume(resumeRequest)

        // 3. Verify final assembled output matches exact source
        let finalData = try Data(contentsOf: destURL)
        XCTAssertEqual(finalData.count, size)
        XCTAssertEqual(finalData, payload)
        XCTAssertEqual(EngineSHA256.hash(data: finalData), expectedSHA)

        let finalRecord = try await freshStore.fetch(tag: "proc-recover")
        XCTAssertEqual(finalRecord?.state, .completed)
        XCTAssertEqual(finalRecord?.isAllSegmentsCompleted, true)
    }

    func testInterruptedProcessRestartsCleanlyWhenDestinationDeleted() async throws {
        let size = 200 * 1024
        let payload = makePayload(size: size, seed: 0x88)
        let expectedSHA = EngineSHA256.hash(data: payload)
        let path = "/dest_deleted.bin"
        server.register(path: path, data: payload)

        let destURL = tempDirectory.appendingPathComponent("dest_deleted.bin")
        let storeDir = tempDirectory.appendingPathComponent("StoreDeleted", isDirectory: true)

        let partialSeg = SegmentRecord(id: 0, startOffset: 0, endOffset: Int64(size - 1), length: Int64(size), completedBytes: 100 * 1024)
        let record = DownloadRecord(
            id: "dest-deleted",
            originalURL: server.url(for: path),
            destinationURL: destURL,
            totalSize: Int64(size),
            state: .paused,
            segments: [partialSeg]
        )
        let store = try DownloadPersistenceStore(storageDirectoryURL: storeDir)
        try await store.save(record)

        // Destination file does NOT exist on disk!
        XCTAssertFalse(FileManager.default.fileExists(atPath: destURL.path))

        let freshCoordinator = try DownloadCoordinator(session: .shared, persistenceStore: store)
        let request = DownloadRequest(
            id: "dest-deleted",
            url: server.url(for: path),
            destinationURL: destURL,
            expectedSHA256: expectedSHA
        )

        // Resuming must detect missing destination, restart from scratch cleanly, and succeed
        try await freshCoordinator.resume(request)

        let writtenData = try Data(contentsOf: destURL)
        XCTAssertEqual(writtenData.count, size)
        XCTAssertEqual(writtenData, payload)
        XCTAssertEqual(EngineSHA256.hash(data: writtenData), expectedSHA)
    }

    func testRealProcessTerminationViaSIGKILLAndRecovery() async throws {
        let cwd = FileManager.default.currentDirectoryPath
        let candidatePaths = [
            "\(cwd)/.build/debug/DM_InterruptionTestCLI",
            "\(cwd)/.build/x86_64-unknown-linux-gnu/debug/DM_InterruptionTestCLI",
            "./.build/debug/DM_InterruptionTestCLI",
            "./.build/x86_64-unknown-linux-gnu/debug/DM_InterruptionTestCLI"
        ]
        guard let executablePath = candidatePaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            print("Skipping child process test: DM_InterruptionTestCLI binary not found at candidate paths.")
            return
        }

        let size = 2 * 1024 * 1024 // 2 MiB
        let payload = makePayload(size: size, seed: 0x99)
        let expectedSHA = EngineSHA256.hash(data: payload)
        let path = "/child_process_kill.bin"
        // Throttled slightly so child process is guaranteed in-flight when killed
        server.register(path: path, data: payload, chunkDelayMs: 4)

        let destURL = tempDirectory.appendingPathComponent("child_process_kill.bin")
        let storeDir = tempDirectory.appendingPathComponent("ChildProcessStore", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = [
            "sigkill-download",
            server.url(for: path).absoluteString,
            destURL.path,
            storeDir.path,
            "2"
        ]

        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()

        // Wait until child process has initialized and made progress
        let store = try DownloadPersistenceStore(storageDirectoryURL: storeDir)
        var persisted = false
        for _ in 0..<100 {
            try await Task.sleep(nanoseconds: 20_000_000) // 20ms
            if let _ = try await store.fetch(tag: "sigkill-download"),
               FileManager.default.fileExists(atPath: destURL.path),
               let attr = try? FileManager.default.attributesOfItem(atPath: destURL.path),
               let currentSize = attr[.size] as? Int64,
               currentSize > 0 {
                persisted = true
                break
            }
        }
        XCTAssertTrue(persisted, "Child process did not write partial file and persistence state in time")

        // Hard terminate child process using SIGKILL (kill -9)
        // This instantly destroys the process with NO orderly shutdown, flush, or cleanup
        #if os(Linux)
        Glibc.kill(process.processIdentifier, SIGKILL)
        #else
        Darwin.kill(process.processIdentifier, SIGKILL)
        #endif
        process.waitUntilExit()

        XCTAssertFalse(process.isRunning)

        // Validate partial state after ungraceful crash:
        // The persisted state is still .downloading and canResume is true
        let postCrashRecord = try await store.fetch(tag: "sigkill-download")
        XCTAssertNotNil(postCrashRecord)
        XCTAssertTrue(postCrashRecord?.state.canResume == true)

        // Remove chunk delay on server so resume finishes quickly
        server.register(path: path, data: payload, chunkDelayMs: 0)

        // Launch fresh coordinator in parent process (simulating application restart)
        let recoveryCoordinator = try DownloadCoordinator(session: .shared, persistenceStore: store)
        let resumeReq = DownloadRequest(
            id: "sigkill-download",
            url: server.url(for: path),
            destinationURL: destURL,
            configuredThreadCount: 2,
            expectedSHA256: expectedSHA
        )

        try await recoveryCoordinator.resume(resumeReq)

        // Verify final file size, byte content, and SHA-256 match expected exactly
        let recoveredData = try Data(contentsOf: destURL)
        XCTAssertEqual(recoveredData.count, size)
        XCTAssertEqual(recoveredData, payload)
        XCTAssertEqual(EngineSHA256.hash(data: recoveredData), expectedSHA)

        let finalRecord = try await store.fetch(tag: "sigkill-download")
        XCTAssertEqual(finalRecord?.state, .completed)
    }

    // MARK: - Phase 2C: Source Resource Changes & ETag Invalidation

    func testSourceResourceETagChangedRestartsDownloadFresh() async throws {
        let size = 300 * 1024
        let payloadA = makePayload(size: size, seed: 0xAA)
        let payloadB = makePayload(size: size, seed: 0xBB)
        let expectedSHAB = EngineSHA256.hash(data: payloadB)
        let path = "/resource_change.bin"

        // Server initially serves Version A with ETag "etag-v1"
        server.register(path: path, data: payloadA, eTag: "\"etag-v1\"")

        let destURL = tempDirectory.appendingPathComponent("resource_change.bin")

        // Simulate paused download from Version A (halfway completed)
        let seg = SegmentRecord(id: 0, startOffset: 0, endOffset: Int64(size - 1), length: Int64(size), completedBytes: 150 * 1024)
        let recordA = DownloadRecord(
            id: "etag-change",
            originalURL: server.url(for: path),
            destinationURL: destURL,
            totalSize: Int64(size),
            state: .paused,
            eTag: "\"etag-v1\"",
            segments: [seg]
        )
        try await persistenceStore.save(recordA)

        // Pre-fill destination file with Version A partial bytes
        let writer = try DownloadFileWriter(destinationURL: destURL, totalSize: Int64(size))
        try await writer.writeDirect(payloadA.subdata(in: 0..<150 * 1024), at: 0)
        try await writer.synchronize()
        try await writer.close()

        // SERVER UPDATES RESOURCE TO VERSION B (different ETag & payload)
        server.updateResource(path: path, data: payloadB, eTag: "\"etag-v2\"")

        // Resume download
        let resumeReq = DownloadRequest(
            id: "etag-change",
            url: server.url(for: path),
            destinationURL: destURL,
            expectedSHA256: expectedSHAB
        )
        try await coordinator.resume(resumeReq)

        // VERIFY: The engine MUST NOT have combined bytes of Version A and B!
        // Output must match 100% of Version B!
        let finalData = try Data(contentsOf: destURL)
        XCTAssertEqual(finalData.count, size)
        XCTAssertEqual(finalData, payloadB)
        XCTAssertEqual(EngineSHA256.hash(data: finalData), expectedSHAB)

        let finalRecord = try await persistenceStore.fetch(tag: "etag-change")
        XCTAssertEqual(finalRecord?.eTag, "\"etag-v2\"")
        XCTAssertEqual(finalRecord?.state, .completed)
    }

    func testSourceResourceLastModifiedChangedRestartsFresh() async throws {
        let size = 200 * 1024
        let payloadA = makePayload(size: size, seed: 0x12)
        let payloadB = makePayload(size: size, seed: 0x34)
        let path = "/lm_change.bin"

        // Server hosts without ETag, but with Last-Modified
        server.register(path: path, data: payloadA, eTag: nil, lastModified: "Mon, 10 Oct 2026 10:00:00 GMT")

        let destURL = tempDirectory.appendingPathComponent("lm_change.bin")
        let recordA = DownloadRecord(
            id: "lm-change",
            originalURL: server.url(for: path),
            destinationURL: destURL,
            totalSize: Int64(size),
            state: .paused,
            eTag: nil,
            lastModified: "Mon, 10 Oct 2026 10:00:00 GMT",
            segments: [SegmentRecord(id: 0, startOffset: 0, endOffset: Int64(size - 1), length: Int64(size), completedBytes: 50 * 1024)]
        )
        try await persistenceStore.save(recordA)

        // Write partial Version A file
        let writer = try DownloadFileWriter(destinationURL: destURL, totalSize: Int64(size))
        try await writer.writeDirect(payloadA.subdata(in: 0..<50 * 1024), at: 0)
        try await writer.synchronize()
        try await writer.close()

        // Server modifies resource timestamp
        server.updateResource(path: path, data: payloadB, eTag: nil, lastModified: "Tue, 11 Oct 2026 10:00:00 GMT")

        let request = DownloadRequest(
            id: "lm-change",
            url: server.url(for: path),
            destinationURL: destURL,
            expectedSHA256: EngineSHA256.hash(data: payloadB)
        )
        try await coordinator.resume(request)

        let finalData = try Data(contentsOf: destURL)
        XCTAssertEqual(finalData, payloadB)
    }

    func testSourceResourceSizeMismatchRestartsFresh() async throws {
        let sizeA = 100 * 1024
        let sizeB = 150 * 1024
        let payloadA = makePayload(size: sizeA, seed: 0x11)
        let payloadB = makePayload(size: sizeB, seed: 0x22)
        let path = "/size_mismatch.bin"

        server.register(path: path, data: payloadA)
        let destURL = tempDirectory.appendingPathComponent("size_mismatch.bin")

        let recordA = DownloadRecord(
            id: "size-mismatch",
            originalURL: server.url(for: path),
            destinationURL: destURL,
            totalSize: Int64(sizeA),
            state: .paused,
            segments: [SegmentRecord(id: 0, startOffset: 0, endOffset: Int64(sizeA - 1), length: Int64(sizeA), completedBytes: 50 * 1024)]
        )
        try await persistenceStore.save(recordA)

        // Server size changes to 150 KB
        server.updateResource(path: path, data: payloadB)

        let request = DownloadRequest(
            id: "size-mismatch",
            url: server.url(for: path),
            destinationURL: destURL,
            expectedSHA256: EngineSHA256.hash(data: payloadB)
        )
        try await coordinator.resume(request)

        let finalData = try Data(contentsOf: destURL)
        XCTAssertEqual(finalData.count, sizeB)
        XCTAssertEqual(finalData, payloadB)
    }

    func testSourceResourceNoValidatorsAllowsResumeWhenSizeMatches() async throws {
        let size = 200 * 1024
        let payload = makePayload(size: size, seed: 0x99)
        let expectedSHA = EngineSHA256.hash(data: payload)
        let path = "/no_validators.bin"

        // Server serves file with NO ETag and NO Last-Modified
        server.register(path: path, data: payload, eTag: nil, lastModified: nil)

        let destURL = tempDirectory.appendingPathComponent("no_validators.bin")
        let record = DownloadRecord(
            id: "no-val",
            originalURL: server.url(for: path),
            destinationURL: destURL,
            totalSize: Int64(size),
            state: .paused,
            eTag: nil,
            lastModified: nil,
            segments: [SegmentRecord(id: 0, startOffset: 0, endOffset: Int64(size - 1), length: Int64(size), completedBytes: 100 * 1024)]
        )
        try await persistenceStore.save(record)

        let writer = try DownloadFileWriter(destinationURL: destURL, totalSize: Int64(size))
        try await writer.writeDirect(payload.subdata(in: 0..<100 * 1024), at: 0)
        try await writer.synchronize()
        try await writer.close()

        let request = DownloadRequest(
            id: "no-val",
            url: server.url(for: path),
            destinationURL: destURL,
            expectedSHA256: expectedSHA
        )

        // Resumes without error based on size match
        try await coordinator.resume(request)

        let finalData = try Data(contentsOf: destURL)
        XCTAssertEqual(finalData.count, size)
        XCTAssertEqual(finalData, payload)
        XCTAssertEqual(EngineSHA256.hash(data: finalData), expectedSHA)
    }

    func testServerIgnoresIfRangeAndSends200DuringResume() async throws {
        let size = 150 * 1024
        let payload = makePayload(size: size, seed: 0x55)
        let path = "/ignore_if_range.bin"

        server.register(path: path, data: payload, eTag: "\"etag-current\"")
        let destURL = tempDirectory.appendingPathComponent("ignore_if_range.bin")

        // Persisted checkpoint had old ETag
        let record = DownloadRecord(
            id: "ignore-if-range",
            originalURL: server.url(for: path),
            destinationURL: destURL,
            totalSize: Int64(size),
            state: .paused,
            eTag: "\"etag-old\"",
            segments: [SegmentRecord(id: 0, startOffset: 0, endOffset: Int64(size - 1), length: Int64(size), completedBytes: 50 * 1024)]
        )
        try await persistenceStore.save(record)

        let request = DownloadRequest(
            id: "ignore-if-range",
            url: server.url(for: path),
            destinationURL: destURL,
            expectedSHA256: EngineSHA256.hash(data: payload)
        )

        try await coordinator.resume(request)

        let finalData = try Data(contentsOf: destURL)
        XCTAssertEqual(finalData, payload)
    }

    // MARK: - Phase 2D: Interrupted Connections & Bounded Retries

    func testTransientServerErrorRecoversViaExponentialBackoff() async throws {
        let size = 100 * 1024
        let payload = makePayload(size: size, seed: 0x33)
        let expectedSHA = EngineSHA256.hash(data: payload)
        let path = "/transient_500.bin"

        server.register(path: path, data: payload)
        // Configure server to fail the first request with 500, then succeed
        server.failNextRequests(path: path, count: 1, statusCode: 500)

        let destURL = tempDirectory.appendingPathComponent("transient_500.bin")
        let request = DownloadRequest(
            id: "transient-500",
            url: server.url(for: path),
            destinationURL: destURL,
            retryCount: 2,
            expectedSHA256: expectedSHA
        )

        try await coordinator.start(request)

        let finalData = try Data(contentsOf: destURL)
        XCTAssertEqual(finalData.count, size)
        XCTAssertEqual(EngineSHA256.hash(data: finalData), expectedSHA)
    }

    func testRepeatedServerErrorExhaustsRetriesWithClearTerminalFailure() async throws {
        let size = 100 * 1024
        let payload = makePayload(size: size, seed: 0x44)
        let path = "/exhaust_500.bin"

        server.register(path: path, data: payload)
        // Configure server to fail 10 consecutive requests with 503
        server.failNextRequests(path: path, count: 10, statusCode: 503)

        let destURL = tempDirectory.appendingPathComponent("exhaust_500.bin")
        let request = DownloadRequest(
            id: "exhaust-500",
            url: server.url(for: path),
            destinationURL: destURL,
            retryCount: 2
        )

        do {
            try await coordinator.start(request)
            XCTFail("Expected retry exhaustion error")
        } catch {
            // Expected
        }

        let record = try await persistenceStore.fetch(tag: "exhaust-500")
        XCTAssertNotNil(record)
        if case .failed = record?.state {
            // Success
        } else {
            XCTFail("Expected record state to be .failed, but got \(String(describing: record?.state))")
        }
    }

    func testConnectionDroppedMidwayRecoversOnRetry() async throws {
        let size = 200 * 1024
        let payload = makePayload(size: size, seed: 0x77)
        let expectedSHA = EngineSHA256.hash(data: payload)
        let path = "/drop_conn.bin"

        // Drops connection abruptly after 32 KB on the first attempt
        server.register(path: path, data: payload, dropConnectionAfterBytes: 32 * 1024)

        let destURL = tempDirectory.appendingPathComponent("drop_conn.bin")
        let request = DownloadRequest(
            id: "drop-conn",
            url: server.url(for: path),
            destinationURL: destURL,
            retryCount: 3,
            expectedSHA256: expectedSHA
        )

        // Launch download; it should encounter the socket drop, retry, and complete
        // After 1 dropped attempt, remove drop limit so retry succeeds
        let task = Task {
            try await coordinator.start(request)
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        // Restore normal stream
        server.register(path: path, data: payload, dropConnectionAfterBytes: nil)

        try await task.value

        let finalData = try Data(contentsOf: destURL)
        XCTAssertEqual(finalData.count, size)
        XCTAssertEqual(EngineSHA256.hash(data: finalData), expectedSHA)
    }
}
