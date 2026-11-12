import XCTest
import Foundation
@testable import DM_Reverse_engineering

final class DownloadPersistenceAndRecoveryTests: XCTestCase {
    var tempDirectory: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersistenceTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let temp = tempDirectory {
            try? FileManager.default.removeItem(at: temp)
        }
        try await super.tearDown()
    }

    private func makeEngines(concurrency: Int = 3) throws -> (DownloadEngine, DownloadPersistenceStore, DownloadQueueManager, URL) {
        let storeDir = tempDirectory.appendingPathComponent("Metadata", isDirectory: true)
        let persistenceStore = try DownloadPersistenceStore(storageDirectoryURL: storeDir)
        let coordinator = try DownloadCoordinator(persistenceStore: persistenceStore)
        let queueStoreURL = storeDir.appendingPathComponent("queue_manifest.json")
        let queueManager = DownloadQueueManager(
            coordinator: coordinator,
            persistenceStore: persistenceStore,
            queueStoreURL: queueStoreURL,
            maxConcurrentDownloads: concurrency
        )
        let engine = DownloadEngine(
            queueManager: queueManager,
            coordinator: coordinator,
            persistenceStore: persistenceStore
        )
        return (engine, persistenceStore, queueManager, storeDir)
    }

    // MARK: - Test 1: HTTP download survives simulated app relaunch
    func test1_HTTPDownloadSurvivesSimulatedAppRelaunch() async throws {
        let (engine1, _, _, storeDir) = try makeEngines()
        let destURL = tempDirectory.appendingPathComponent("test1.bin")
        let request = DownloadRequest(
            id: "http-download-1",
            url: URL(string: "https://example.com/test1.bin")!,
            destinationURL: destURL
        )
        _ = try await engine1.addDownload(request, priority: .normal, autoStart: false)

        // Simulate app relaunch: initialize new engine pointing to same storeDir
        let persistenceStore2 = try DownloadPersistenceStore(storageDirectoryURL: storeDir)
        let coordinator2 = try DownloadCoordinator(persistenceStore: persistenceStore2)
        let queueStoreURL = storeDir.appendingPathComponent("queue_manifest.json")
        let queueManager2 = DownloadQueueManager(
            coordinator: coordinator2,
            persistenceStore: persistenceStore2,
            queueStoreURL: queueStoreURL
        )
        let engine2 = DownloadEngine(
            queueManager: queueManager2,
            coordinator: coordinator2,
            persistenceStore: persistenceStore2
        )

        try await engine2.restoreQueue(autoStart: false)
        let snapshot = await engine2.snapshot(for: "http-download-1")
        XCTAssertNotNil(snapshot, "Download must survive app relaunch")
        XCTAssertEqual(snapshot?.id, "http-download-1")
        XCTAssertEqual(snapshot?.url, URL(string: "https://example.com/test1.bin")!)
        XCTAssertEqual(snapshot?.destinationURL, destURL)
    }

    // MARK: - Test 2: Completed download remains visible after relaunch
    func test2_CompletedDownloadRemainsVisibleAfterRelaunch() async throws {
        let (engine1, _, _, storeDir) = try makeEngines()
        let destURL = tempDirectory.appendingPathComponent("completed.bin")
        let dummyData = Data(repeating: 0x42, count: 1024)
        try dummyData.write(to: destURL)

        _ = try await engine1.importCompletedFile(
            fileURL: destURL,
            originalURL: URL(string: "https://example.com/completed.bin")!,
            filename: "completed.bin"
        )

        // Simulate app relaunch
        let persistenceStore2 = try DownloadPersistenceStore(storageDirectoryURL: storeDir)
        let coordinator2 = try DownloadCoordinator(persistenceStore: persistenceStore2)
        let queueStoreURL = storeDir.appendingPathComponent("queue_manifest.json")
        let queueManager2 = DownloadQueueManager(
            coordinator: coordinator2,
            persistenceStore: persistenceStore2,
            queueStoreURL: queueStoreURL
        )
        let engine2 = DownloadEngine(
            queueManager: queueManager2,
            coordinator: coordinator2,
            persistenceStore: persistenceStore2
        )

        try await engine2.restoreQueue(autoStart: false)
        let snaps = await engine2.allSnapshots()
        let completed = snaps.first(where: { $0.destinationURL == destURL })
        XCTAssertNotNil(completed, "Completed download must remain visible in library after relaunch")
        XCTAssertEqual(completed?.state, .completed)
        XCTAssertEqual(completed?.completedBytes, 1024)
    }

    // MARK: - Test 3: Paused download remains paused
    func test3_PausedDownloadRemainsPaused() async throws {
        let (engine1, _, _, storeDir) = try makeEngines()
        let destURL = tempDirectory.appendingPathComponent("paused.bin")
        let request = DownloadRequest(
            id: "paused-download",
            url: URL(string: "https://example.com/paused.bin")!,
            destinationURL: destURL
        )
        _ = try await engine1.addDownload(request, priority: .normal, autoStart: false)
        try await engine1.pauseDownload(id: "paused-download")

        // Simulate app relaunch with autoStart: true
        let persistenceStore2 = try DownloadPersistenceStore(storageDirectoryURL: storeDir)
        let coordinator2 = try DownloadCoordinator(persistenceStore: persistenceStore2)
        let queueStoreURL = storeDir.appendingPathComponent("queue_manifest.json")
        let queueManager2 = DownloadQueueManager(
            coordinator: coordinator2,
            persistenceStore: persistenceStore2,
            queueStoreURL: queueStoreURL
        )
        let engine2 = DownloadEngine(
            queueManager: queueManager2,
            coordinator: coordinator2,
            persistenceStore: persistenceStore2
        )

        try await engine2.restoreQueue(autoStart: true)
        let snapshot = await engine2.snapshot(for: "paused-download")
        XCTAssertEqual(snapshot?.state, .paused, "Paused download must remain paused even when autoStart is true")
    }

    // MARK: - Test 4: Interrupted download restores recoverable progress
    func test4_InterruptedDownloadRestoresRecoverableProgress() async throws {
        let storeDir = tempDirectory.appendingPathComponent("Metadata", isDirectory: true)
        let persistenceStore = try DownloadPersistenceStore(storageDirectoryURL: storeDir)

        let destURL = tempDirectory.appendingPathComponent("interrupted.bin")
        let partialData = Data(repeating: 0xAA, count: 512)
        try partialData.write(to: destURL)

        // Save a record that was in .downloading state when process was terminated
        let record = DownloadRecord(
            id: "interrupted-download",
            originalURL: URL(string: "https://example.com/interrupted.bin")!,
            destinationURL: destURL,
            totalSize: 1024,
            state: .downloading,
            storageMode: .directSeek,
            segments: [
                SegmentRecord(id: 0, startOffset: 0, endOffset: 1023, length: 1024, completedBytes: 512)
            ]
        )
        try await persistenceStore.save(record)

        // Relaunch and restore
        let coordinator = try DownloadCoordinator(persistenceStore: persistenceStore)
        let queueStoreURL = storeDir.appendingPathComponent("queue_manifest.json")
        let queueManager = DownloadQueueManager(
            coordinator: coordinator,
            persistenceStore: persistenceStore,
            queueStoreURL: queueStoreURL
        )
        let engine = DownloadEngine(
            queueManager: queueManager,
            coordinator: coordinator,
            persistenceStore: persistenceStore
        )

        try await engine.restoreQueue(autoStart: false)
        let snapshot = await engine.snapshot(for: "interrupted-download")
        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.state, .paused, "Interrupted download must be restored safely as .paused")
        XCTAssertEqual(snapshot?.completedBytes, 512, "Recoverable progress must be preserved")
    }

    // MARK: - Test 5: Missing partial file is reconciled correctly
    func test5_MissingPartialFileIsReconciledCorrectly() async throws {
        let storeDir = tempDirectory.appendingPathComponent("Metadata", isDirectory: true)
        let persistenceStore = try DownloadPersistenceStore(storageDirectoryURL: storeDir)

        let destURL = tempDirectory.appendingPathComponent("missing_partial.bin")
        // Note: Do not write the partial file to disk, simulating it being deleted/missing

        let record = DownloadRecord(
            id: "missing-partial-download",
            originalURL: URL(string: "https://example.com/missing_partial.bin")!,
            destinationURL: destURL,
            totalSize: 2000,
            state: .downloading,
            storageMode: .directSeek,
            segments: [
                SegmentRecord(id: 0, startOffset: 0, endOffset: 1999, length: 2000, completedBytes: 1000)
            ]
        )
        try await persistenceStore.save(record)

        let coordinator = try DownloadCoordinator(persistenceStore: persistenceStore)
        let queueStoreURL = storeDir.appendingPathComponent("queue_manifest.json")
        let queueManager = DownloadQueueManager(
            coordinator: coordinator,
            persistenceStore: persistenceStore,
            queueStoreURL: queueStoreURL
        )
        let engine = DownloadEngine(
            queueManager: queueManager,
            coordinator: coordinator,
            persistenceStore: persistenceStore
        )

        try await engine.restoreQueue(autoStart: false)
        let reconciled = try await persistenceStore.fetch(tag: "missing-partial-download")
        XCTAssertEqual(reconciled?.completedBytes, 0, "Missing partial file must be reconciled to 0 bytes to prevent corrupted Range requests")
    }

    // MARK: - Test 6: Missing completed file does not remain falsely marked as available
    func test6_MissingCompletedFileDoesNotRemainFalselyMarkedAsAvailable() async throws {
        let storeDir = tempDirectory.appendingPathComponent("Metadata", isDirectory: true)
        let persistenceStore = try DownloadPersistenceStore(storageDirectoryURL: storeDir)

        let destURL = tempDirectory.appendingPathComponent("deleted_completed.bin")
        // Completed file was deleted from disk by the user/system
        let record = DownloadRecord(
            id: "deleted-completed-download",
            originalURL: URL(string: "https://example.com/deleted_completed.bin")!,
            destinationURL: destURL,
            totalSize: 5000,
            state: .completed,
            storageMode: .directSeek,
            segments: [
                SegmentRecord(id: 0, startOffset: 0, endOffset: 4999, length: 5000, completedBytes: 5000)
            ]
        )
        try await persistenceStore.save(record)

        let coordinator = try DownloadCoordinator(persistenceStore: persistenceStore)
        let queueStoreURL = storeDir.appendingPathComponent("queue_manifest.json")
        let queueManager = DownloadQueueManager(
            coordinator: coordinator,
            persistenceStore: persistenceStore,
            queueStoreURL: queueStoreURL
        )
        let engine = DownloadEngine(
            queueManager: queueManager,
            coordinator: coordinator,
            persistenceStore: persistenceStore
        )

        try await engine.restoreQueue(autoStart: false)
        let snapshot = await engine.snapshot(for: "deleted-completed-download")
        XCTAssertNotNil(snapshot)
        XCTAssertNotEqual(snapshot?.state, .completed, "Missing completed file must not remain falsely marked as completed")
        XCTAssertEqual(snapshot?.state, .failed(reason: "Downloaded file missing from disk"))
    }

    // MARK: - Test 7: HLS parent record survives relaunch
    func test7_HLSParentRecordSurvivesRelaunch() async throws {
        let (engine1, _, _, storeDir) = try makeEngines()
        let hlsStore = try HLSPersistenceStore(storageDirectoryURL: storeDir)
        let hlsID = "hls-parent-1"
        let manifestURL = URL(string: "https://example.com/stream/master.m3u8")!
        let outputURL = tempDirectory.appendingPathComponent("output.mp4")
        let segDir = tempDirectory.appendingPathComponent("hls_segments", isDirectory: true)

        let hlsRecord = HLSTransferRecord(
            id: hlsID,
            manifestURL: manifestURL,
            outputFilename: "output.mp4",
            outputDestinationURL: outputURL,
            segmentDirectoryURL: segDir,
            totalSegments: 10,
            completedSegmentOrders: [0, 1, 2],
            state: .downloading
        )
        try await hlsStore.save(hlsRecord)

        _ = try await engine1.registerStreamingDownload(
            id: hlsID,
            manifestURL: manifestURL,
            destinationURL: outputURL,
            filename: "output.mp4",
            totalBytes: 50_000
        )

        // Relaunch
        let persistenceStore2 = try DownloadPersistenceStore(storageDirectoryURL: storeDir)
        let coordinator2 = try DownloadCoordinator(persistenceStore: persistenceStore2)
        let queueStoreURL = storeDir.appendingPathComponent("queue_manifest.json")
        let queueManager2 = DownloadQueueManager(
            coordinator: coordinator2,
            persistenceStore: persistenceStore2,
            queueStoreURL: queueStoreURL
        )
        let engine2 = DownloadEngine(
            queueManager: queueManager2,
            coordinator: coordinator2,
            persistenceStore: persistenceStore2
        )
        try await engine2.restoreQueue(autoStart: false)

        let snap = await engine2.snapshot(for: hlsID)
        XCTAssertNotNil(snap, "HLS parent transfer record must survive relaunch in DownloadEngine")
        XCTAssertEqual(snap?.url, manifestURL)

        let hlsStore2 = try HLSPersistenceStore(storageDirectoryURL: storeDir)
        let loadedHLSRecord = try await hlsStore2.load(id: hlsID)
        XCTAssertNotNil(loadedHLSRecord, "HLS transfer record must survive relaunch in HLSPersistenceStore")
        XCTAssertEqual(loadedHLSRecord?.completedSegmentOrders, [0, 1, 2])
    }

    // MARK: - Test 8: DASH parent record survives relaunch
    func test8_DASHParentRecordSurvivesRelaunch() async throws {
        let (engine1, _, _, storeDir) = try makeEngines()
        let dashID = "dash-parent-1"
        let manifestURL = URL(string: "https://example.com/dash/manifest.mpd")!
        let outputURL = tempDirectory.appendingPathComponent("dash_output.mp4")

        _ = try await engine1.registerStreamingDownload(
            id: dashID,
            manifestURL: manifestURL,
            destinationURL: outputURL,
            filename: "dash_output.mp4",
            totalBytes: 80_000
        )

        // Relaunch
        let persistenceStore2 = try DownloadPersistenceStore(storageDirectoryURL: storeDir)
        let coordinator2 = try DownloadCoordinator(persistenceStore: persistenceStore2)
        let queueStoreURL = storeDir.appendingPathComponent("queue_manifest.json")
        let queueManager2 = DownloadQueueManager(
            coordinator: coordinator2,
            persistenceStore: persistenceStore2,
            queueStoreURL: queueStoreURL
        )
        let engine2 = DownloadEngine(
            queueManager: queueManager2,
            coordinator: coordinator2,
            persistenceStore: persistenceStore2
        )
        try await engine2.restoreQueue(autoStart: false)

        let snap = await engine2.snapshot(for: dashID)
        XCTAssertNotNil(snap, "DASH parent transfer record must survive relaunch")
        XCTAssertEqual(snap?.url, manifestURL)
    }

    // MARK: - Test 9: Blob interrupted capture retains staging metadata
    func test9_BlobInterruptedCaptureRetainsStagingMetadata() async throws {
        let blobService = BrowserBlobCaptureService(
            destinationDirectoryURL: tempDirectory,
            limits: .default
        )
        let transferID = "blob-transfer-1"
        let tabID = UUID().uuidString
        await blobService.authorize(
            transferID: transferID,
            tabID: tabID,
            documentID: nil,
            candidateID: "candidate-1",
            suggestedFilename: "test_blob.bin"
        )

        let metaAck = await blobService.receive(payload: [
            "version": 1,
            "kind": "metadata",
            "transferID": transferID,
            "tabID": tabID,
            "candidateID": "candidate-1",
            "url": "blob:https://example.com/blob-1",
            "mimeType": "application/octet-stream",
            "size": 100,
            "readable": true,
            "resourceKind": "completeBlobCandidate"
        ])
        XCTAssertTrue(metaAck.accepted)

        let payload = Data([0x01, 0x02, 0x03, 0x04])
        let hash = EngineSHA256.hash(data: payload)
        let chunkAck = await blobService.receive(payload: [
            "version": 1,
            "kind": "chunk",
            "transferID": transferID,
            "tabID": tabID,
            "candidateID": "candidate-1",
            "chunkIndex": 0,
            "offset": 0,
            "base64": payload.base64EncodedString(),
            "sha256": hash
        ])
        XCTAssertTrue(chunkAck.accepted)

        // Simulate WebContent process termination
        let diagnostics = await blobService.handleWebContentProcessTermination(tabID: tabID)
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertTrue(diagnostics[0].isInterruptedByProcessTermination)
        XCTAssertEqual(diagnostics[0].transferState, BlobTransferState.interrupted)

        // Verify recovery at launch
        let recovered = await blobService.recoverIncompleteTransfers()
        let matching = recovered.first(where: { $0.transferID == transferID })
        XCTAssertNotNil(matching, "Interrupted Blob capture must retain staging metadata")
        XCTAssertEqual(matching?.state, BlobTransferState.interrupted)
        XCTAssertEqual(matching?.bytesWritten, 4)
        XCTAssertTrue(FileManager.default.fileExists(atPath: matching!.stagingURL.path), "Staging file must be retained")
    }

    // MARK: - Test 10: MSE interrupted capture retains recovery metadata
    func test10_MSEInterruptedCaptureRetainsRecoveryMetadata() async throws {
        let mseService = BrowserMSECaptureService(destinationDirectoryURL: tempDirectory)
        let captureID = "mse-capture-1"
        let docID = "doc-123"
        await mseService.register(captureID: captureID, documentID: docID)

        let metaAck = await mseService.receive(payload: [
            "version": 1,
            "kind": "metadata",
            "captureID": captureID,
            "documentID": docID,
            "mediaSourceURL": "blob:https://example.com/stream-1",
            "mimeTypes": ["video/mp4; codecs=\"avc1.4d401f\""]
        ])
        XCTAssertTrue(metaAck.accepted)

        let chunkData = Data([0x00, 0x00, 0x00, 0x20, 0x66, 0x74, 0x79, 0x70]) // ftyp box header
        let chunkHash = EngineSHA256.hash(data: chunkData)
        let chunkAck = await mseService.receive(payload: [
            "version": 1,
            "kind": "chunk",
            "captureID": captureID,
            "documentID": docID,
            "chunkIndex": 0,
            "offset": 0,
            "trackIndex": 0,
            "segmentIndex": 0,
            "base64": chunkData.base64EncodedString(),
            "sha256": chunkHash,
            "isSegmentEnd": false
        ])
        XCTAssertTrue(chunkAck.accepted)

        // Simulate WebContent process termination
        let termRecords = await mseService.handleWebContentProcessTermination(captureID: captureID)
        XCTAssertEqual(termRecords.count, 1)
        XCTAssertEqual(termRecords[0].lifecycle, .interrupted)
        XCTAssertEqual(termRecords[0].bytesCaptured, Int64(chunkData.count))

        // Reconcile / recover at launch
        let recovered = await mseService.recoverIncompleteCaptures()
        let matching = recovered.first(where: { $0.captureID == captureID })
        XCTAssertNotNil(matching, "MSE interrupted capture must retain recovery metadata")
        XCTAssertEqual(matching?.lifecycle, .interrupted)
        XCTAssertEqual(matching?.bytesCaptured, Int64(chunkData.count))
    }

    // MARK: - Test 11: Internal streaming segments never appear as library entries
    func test11_InternalStreamingSegmentsNeverAppearAsLibraryEntries() async throws {
        let (engine, persistenceStore, queueManager, _) = try makeEngines()

        // Normal download
        let normalReq = DownloadRequest(
            id: "user-visible-download",
            url: URL(string: "https://example.com/video.mp4")!,
            destinationURL: tempDirectory.appendingPathComponent("video.mp4")
        )
        _ = try await engine.addDownload(normalReq, priority: .normal, autoStart: false)

        // Internal streaming segment record directly saved in persistence store
        let internalSegID = InternalStreamingConstants.segmentIDPrefix + "chunk_01"
        let internalRecord = DownloadRecord(
            id: internalSegID,
            originalURL: URL(string: "https://example.com/segment1.ts")!,
            destinationURL: tempDirectory.appendingPathComponent("segment1.ts"),
            totalSize: 500,
            state: .completed,
            isInternalStreamingSegment: true
        )
        try await persistenceStore.save(internalRecord)

        // Restore queue
        try await queueManager.restoreQueue(autoStart: false)

        let snapshots = await engine.allSnapshots()
        XCTAssertTrue(snapshots.contains(where: { $0.id == "user-visible-download" }))
        XCTAssertFalse(snapshots.contains(where: { $0.id == internalSegID }), "Internal streaming segment must never appear in library snapshots")

        let allItems = await queueManager.allItems()
        XCTAssertFalse(allItems.contains(where: { $0.id == internalSegID }), "Internal streaming segment must never appear in queue manager items")
    }

    // MARK: - Test 12: Removing a record does not delete its file by default
    func test12_RemovingRecordDoesNotDeleteFileByDefault() async throws {
        let (engine, _, _, _) = try makeEngines()
        let fileURL = tempDirectory.appendingPathComponent("keep_file.txt")
        let content = Data("Important User Content".utf8)
        try content.write(to: fileURL)

        _ = try await engine.importCompletedFile(
            fileURL: fileURL,
            originalURL: URL(string: "https://example.com/keep_file.txt")!,
            filename: "keep_file.txt"
        )

        let snapshots = await engine.allSnapshots()
        guard let item = snapshots.first(where: { $0.destinationURL == fileURL }) else {
            XCTFail("Failed to register completed file")
            return
        }

        // Remove record without deleting file
        try await engine.removeDownload(id: item.id, deleteFile: false)

        let remainingSnapshots = await engine.allSnapshots()
        XCTAssertFalse(remainingSnapshots.contains(where: { $0.id == item.id }), "Record must be removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path), "Physical file must remain intact when deleteFile is false")
    }

    // MARK: - Test 13: Explicit file deletion removes the file and updates its record
    func test13_ExplicitFileDeletionRemovesFileAndUpdatesRecord() async throws {
        let (engine, persistenceStore, _, _) = try makeEngines()
        let fileURL = tempDirectory.appendingPathComponent("delete_file.txt")
        let content = Data("Disposable Content".utf8)
        try content.write(to: fileURL)

        _ = try await engine.importCompletedFile(
            fileURL: fileURL,
            originalURL: URL(string: "https://example.com/delete_file.txt")!,
            filename: "delete_file.txt"
        )

        let snapshots = await engine.allSnapshots()
        guard let item = snapshots.first(where: { $0.destinationURL == fileURL }) else {
            XCTFail("Failed to register completed file")
            return
        }

        // Explicitly delete file while keeping record
        try await engine.deleteDownloadedFile(id: item.id, keepRecord: true)

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path), "Physical file must be deleted")
        let updatedSnap = await engine.snapshot(for: item.id)
        XCTAssertNotNil(updatedSnap, "Record must be retained when keepRecord is true")
        XCTAssertEqual(updatedSnap?.state, .failed(reason: "Downloaded file missing from disk"))

        let persisted = try await persistenceStore.fetch(tag: item.id)
        XCTAssertEqual(persisted?.state, .failed(reason: "Downloaded file missing from disk"))
    }

    // MARK: - Test 14: Repeated restoration does not create duplicates
    func test14_RepeatedRestorationDoesNotCreateDuplicates() async throws {
        let (engine, _, queueManager, _) = try makeEngines()

        let req1 = DownloadRequest(
            id: "dup-test-1",
            url: URL(string: "https://example.com/file1.bin")!,
            destinationURL: tempDirectory.appendingPathComponent("file1.bin")
        )
        let req2 = DownloadRequest(
            id: "dup-test-2",
            url: URL(string: "https://example.com/file2.bin")!,
            destinationURL: tempDirectory.appendingPathComponent("file2.bin")
        )
        _ = try await engine.addDownload(req1, priority: .normal, autoStart: false)
        _ = try await engine.addDownload(req2, priority: .normal, autoStart: false)

        // Multiple restoration calls in succession
        try await queueManager.restoreQueue(autoStart: false)
        try await queueManager.restoreQueue(autoStart: false)
        try await queueManager.restoreQueue(autoStart: false)

        let allItems = await queueManager.allItems()
        XCTAssertEqual(allItems.count, 2, "Repeated restoration must not duplicate queue items")
        let snapshots = await engine.allSnapshots()
        XCTAssertEqual(snapshots.count, 2, "Repeated restoration must not duplicate snapshots")
    }

    // MARK: - Test 15: Corrupted persistence metadata does not silently wipe all records
    func test15_CorruptedPersistenceMetadataDoesNotSilentlyWipeAllRecords() async throws {
        let storeDir = tempDirectory.appendingPathComponent("Metadata", isDirectory: true)
        let persistenceStore = try DownloadPersistenceStore(storageDirectoryURL: storeDir)

        // Save 3 valid records
        for i in 1...3 {
            let record = DownloadRecord(
                id: "valid-record-\(i)",
                originalURL: URL(string: "https://example.com/file\(i).bin")!,
                destinationURL: tempDirectory.appendingPathComponent("file\(i).bin"),
                totalSize: 1000,
                state: .paused
            )
            try await persistenceStore.save(record)
        }

        // Inject 1 corrupted JSON file into storeDir
        let corruptedFile = storeDir.appendingPathComponent("corrupted-record.json")
        try Data("NOT_A_VALID_JSON{{{}}}".utf8).write(to: corruptedFile)

        let fetched = try await persistenceStore.fetchAll()
        XCTAssertEqual(fetched.count, 3, "Corrupted record must be skipped without wiping the 3 valid records")

        // Also test queue restore with corrupted manifest
        let queueStoreURL = storeDir.appendingPathComponent("queue_manifest.json")
        try Data("CORRUPTED_MANIFEST_GARBAGE".utf8).write(to: queueStoreURL)

        let coordinator = try DownloadCoordinator(persistenceStore: persistenceStore)
        let queueManager = DownloadQueueManager(
            coordinator: coordinator,
            persistenceStore: persistenceStore,
            queueStoreURL: queueStoreURL
        )
        try await queueManager.restoreQueue(autoStart: false)

        let items = await queueManager.allItems()
        XCTAssertEqual(items.count, 3, "Queue restore must reconstruct from persistence store when manifest is corrupted")
    }

    // MARK: - Test 16: Concurrent updates do not corrupt the persistent store
    func test16_ConcurrentUpdatesDoNotCorruptPersistentStore() async throws {
        let storeDir = tempDirectory.appendingPathComponent("Metadata", isDirectory: true)
        let persistenceStore = try DownloadPersistenceStore(storageDirectoryURL: storeDir)

        let downloadID = "concurrent-download"
        let initialRecord = DownloadRecord(
            id: downloadID,
            originalURL: URL(string: "https://example.com/concurrent.bin")!,
            destinationURL: tempDirectory.appendingPathComponent("concurrent.bin"),
            totalSize: 10_000,
            state: .downloading,
            segments: [
                SegmentRecord(id: 0, startOffset: 0, endOffset: 9999, length: 10_000, completedBytes: 0)
            ]
        )
        try await persistenceStore.save(initialRecord)

        // Perform 50 concurrent progress updates
        await withTaskGroup(of: Void.self) { group in
            for i in 1...50 {
                group.addTask {
                    let progress = Int64(i * 100)
                    _ = try? await persistenceStore.updateSegmentProgress(
                        tag: downloadID,
                        segmentID: 0,
                        completedBytes: progress
                    )
                }
            }
        }

        // Verify record on disk can be fetched and decoded cleanly
        let finalRecord = try await persistenceStore.fetch(tag: downloadID)
        XCTAssertNotNil(finalRecord, "Record must be intact after concurrent updates")
        XCTAssertGreaterThan(finalRecord!.completedBytes, 0)

        // Ensure persistence file on disk is valid JSON
        let rawData = try await persistenceStore.exportToData(tag: downloadID)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DownloadRecord.self, from: rawData)
        XCTAssertEqual(decoded.id, downloadID)
    }
}

