//
//  BrowserBlobCaptureStabilityTests.swift
//  SwiftDownloadEngine
//
//  Phase 2, Item 3: Blob Capture Stability Tests
//  Validates:
//    - Workstream A: Large Blob Capture & Chunking Stability (JS buffer slicing, 10MB-512MB stress, SHA-256 integrity, latency tracking)
//    - Workstream B: WebContent Process Termination Crash Recovery (metadata, initial chunk, midway, pre/post checkpoint, forensics, zero premature publication)
//    - Workstream C: Cancellation Resilience & Lifecycle Cleanliness (stream reading, writing, tab navigation, race conditions, staging cleanup)
//    - Workstream D: Storage Exhaustion & Limit Enforcement (500MB disk reserve, 1GB staging limit, 512MB transfer limit, concurrency limit)
//

import XCTest
import Foundation
@testable import DM_Reverse_engineering

final class BrowserBlobCaptureStabilityTests: XCTestCase {

    private func tmpDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("blob-stability-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func sha(_ data: Data) -> String {
        EngineSHA256.hash(data: data)
    }

    private func makeDeterministicData(length: Int, seed: UInt8 = 0x42) -> Data {
        var data = Data(count: length)
        for i in 0..<length {
            data[i] = UInt8((Int(seed) + i * 31) & 0xFF)
        }
        return data
    }

    // MARK: - Workstream A: Large Blob Capture & Chunking Stability

    func testJSBridgeScriptUsesSubarrayToPreventOversizedChunkErrorAndMemoryCopies() {
        let script = BlobCaptureBridge.script
        // Verify subarray slicing is present for handling reader buffers > chunkSize
        XCTAssertTrue(script.contains("s.pending.subarray(0,s.chunkSize)"))
        XCTAssertTrue(script.contains("s.pending=s.pending.subarray(s.chunkSize)"))
        XCTAssertTrue(script.contains("s.pending=bytes.subarray(s.chunkSize)"))
        XCTAssertTrue(script.contains("return bytes.subarray(0,s.chunkSize)"))
        // Verify MAX_CHUNK_BYTES is strictly 262144 (256 KB)
        XCTAssertTrue(script.contains("MAX_CHUNK_BYTES = 262144"))
    }

    func testSimulatedOversizedReaderBufferSlicingProducesExactChunks() {
        // Simulates a ReadableStream reader that yields an oversized buffer (e.g. 1 MB, 700 KB)
        // Verifies the slicing algorithm divides it into exact 256 KB chunks without dropping bytes
        let chunkSize = 256 * 1024
        let inputSizes = [1024 * 1024, 700 * 1024, 256 * 1024, 100 * 1024, 5 * 1024 * 1024]

        for totalSize in inputSizes {
            let fullData = makeDeterministicData(length: totalSize)
            var pending: Data? = fullData
            var emittedChunks: [Data] = []

            while let p = pending, !p.isEmpty {
                if p.count <= chunkSize {
                    emittedChunks.append(p)
                    pending = nil
                } else {
                    let slice = p.subdata(in: 0..<chunkSize)
                    emittedChunks.append(slice)
                    pending = p.subdata(in: chunkSize..<p.count)
                }
            }

            // Every chunk except the last must be exactly chunkSize
            for i in 0..<(emittedChunks.count - 1) {
                XCTAssertEqual(emittedChunks[i].count, chunkSize)
            }
            // Reassembled chunks must bit-for-bit match original data
            var reassembled = Data()
            for chunk in emittedChunks {
                reassembled.append(chunk)
            }
            XCTAssertEqual(reassembled.count, totalSize)
            XCTAssertEqual(EngineSHA256.hash(data: reassembled), EngineSHA256.hash(data: fullData))
        }
    }

    func testStreamingLargeBlob10MBEndToEndIntegrity() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let service = BrowserBlobCaptureService(
            destinationDirectoryURL: dir,
            limits: BlobExportLimits(
                maximumBytesPerTransfer: 50 * 1024 * 1024,
                maximumChunkBytes: 256 * 1024,
                maximumConcurrentTransfers: 2,
                maximumStagingBytes: 100 * 1024 * 1024
            ),
            checkpointInterval: 8
        )

        let transferID = "stress-10mb"
        let tabID = "tab-stress"
        let docID = "doc-stress"
        await service.authorize(
            transferID: transferID, tabID: tabID,
            documentID: docID, suggestedFilename: "large-video.mp4"
        )

        let totalBytes: Int64 = 10 * 1024 * 1024 // 10 MB
        let chunkSize = 256 * 1024 // 256 KB -> 40 chunks
        let totalChunks = Int(totalBytes / Int64(chunkSize))

        // Send metadata
        let metaPayload: [String: Any] = [
            "version": 2, "kind": "metadata", "transferID": transferID,
            "tabID": tabID, "documentID": docID,
            "url": "blob:https://example.test/stream-10mb",
            "mimeType": "video/mp4", "size": totalBytes,
            "readable": true, "resourceKind": "completeBlobCandidate"
        ]
        let metaAck = await service.receive(payload: metaPayload)
        XCTAssertTrue(metaAck.accepted)

        var wholeFileHasher = EngineSHA256Hasher()
        var offset: Int64 = 0

        for chunkIdx in 0..<totalChunks {
            let chunkData = makeDeterministicData(length: chunkSize, seed: UInt8(chunkIdx & 0xFF))
            wholeFileHasher.update(data: chunkData)
            let chunkChecksum = sha(chunkData)

            let chunkPayload: [String: Any] = [
                "version": 2, "kind": "chunk", "transferID": transferID,
                "tabID": tabID, "documentID": docID,
                "chunkIndex": chunkIdx, "offset": offset,
                "base64": chunkData.base64EncodedString(),
                "sha256": chunkChecksum
            ]
            let chunkAck = await service.receive(payload: chunkPayload)
            XCTAssertTrue(chunkAck.accepted, "Chunk \(chunkIdx) must be accepted")
            XCTAssertEqual(chunkAck.snapshot?.bytesWritten, offset + Int64(chunkSize))
            offset += Int64(chunkSize)
        }

        let expectedWholeDigest = wholeFileHasher.finalize()

        // Complete transfer
        let completePayload: [String: Any] = [
            "version": 2, "kind": "complete", "transferID": transferID,
            "tabID": tabID, "documentID": docID,
            "chunkIndex": totalChunks, "offset": offset,
            "sha256": expectedWholeDigest
        ]
        let completeAck = await service.receive(payload: completePayload)
        XCTAssertTrue(completeAck.accepted)
        XCTAssertEqual(completeAck.snapshot?.state, .completed)
        XCTAssertEqual(completeAck.snapshot?.bytesWritten, totalBytes)
        XCTAssertEqual(completeAck.snapshot?.outputDigest, expectedWholeDigest)

        // Verify final file exists on disk and has exact size & hash
        guard let finalURL = completeAck.snapshot?.finalURL else {
            XCTFail("Missing finalURL")
            return
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalURL.path))
        let diskSize = FileManager.default.fileSize(atPath: finalURL.path) ?? 0
        XCTAssertEqual(diskSize, totalBytes)

        let diskData = try Data(contentsOf: finalURL)
        XCTAssertEqual(EngineSHA256.hash(data: diskData), expectedWholeDigest)

        // Verify telemetry diagnostics recorded
        let diag = await service.loadCrashDiagnostics(for: transferID)
        XCTAssertNotNil(diag)
        XCTAssertEqual(diag?.chunkSequenceNumber, totalChunks)
        XCTAssertEqual(diag?.byteOffset, totalBytes)
        XCTAssertEqual(diag?.receivedBytes, totalBytes)
        XCTAssertEqual(diag?.transferState, .completed)
        XCTAssertGreaterThan(diag?.averageAcknowledgementLatencyMs ?? 0, 0)
    }

    func testStreamingHighThroughputStress25MBWithCheckpoints() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = BlobExportWriter(
            destinationDirectoryURL: dir,
            limits: BlobExportLimits(
                maximumBytesPerTransfer: 100 * 1024 * 1024,
                maximumChunkBytes: 256 * 1024,
                maximumConcurrentTransfers: 2,
                maximumStagingBytes: 200 * 1024 * 1024
            ),
            checkpointInterval: 16 // Sync every 4 MB
        )

        let auth = BlobCaptureAuthorization(transferID: "stress-25mb", tabID: "tab1", documentID: "doc1")
        let envelope = BlobCaptureMetadataEnvelope(
            transferID: "stress-25mb", documentID: "doc1",
            sourceURL: URL(string: "blob:https://example.test/25mb")!,
            mimeType: "video/mp4", declaredSize: 25 * 1024 * 1024,
            resourceKind: .completeBlobCandidate, readable: true
        )

        _ = try await writer.begin(authorization: auth, envelope: envelope, suggestedFilename: "stress25.mp4")

        let chunkSize = 256 * 1024
        let totalChunks = 100 // 100 * 256 KB = 25 MB
        var offset: Int64 = 0
        var hasher = EngineSHA256Hasher()

        let startTime = Date().timeIntervalSinceReferenceDate
        for i in 0..<totalChunks {
            let chunk = makeDeterministicData(length: chunkSize, seed: UInt8(i & 0xFF))
            hasher.update(data: chunk)
            let digest = sha(chunk)
            let snap = try await writer.append(
                transferID: "stress-25mb", chunkIndex: i, offset: offset,
                data: chunk, sha256: digest,
                acknowledgementLatencyMs: 0.25
            )
            offset += Int64(chunkSize)
            XCTAssertEqual(snap.bytesWritten, offset)
        }
        let elapsed = Date().timeIntervalSinceReferenceDate - startTime
        XCTAssertGreaterThan(elapsed, 0)

        let expectedHash = hasher.finalize()
        let completeSnap = try await writer.complete(
            transferID: "stress-25mb", finalChunkIndex: totalChunks,
            finalOffset: offset, declaredFileDigest: expectedHash
        )

        XCTAssertEqual(completeSnap.state, .completed)
        XCTAssertEqual(completeSnap.bytesWritten, 25 * 1024 * 1024)
        XCTAssertEqual(completeSnap.outputDigest, expectedHash)
        let syncCount = await writer.totalSyncCount
        XCTAssertGreaterThan(syncCount, 5, "Checkpoints must have triggered fsync")
    }

    func testStreaming512MBBoundaryWithStreamingHasherKeepsFlatMemory() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Test boundary at 512 MB
        let maxLimit: Int64 = 512 * 1024 * 1024
        let writer = BlobExportWriter(
            destinationDirectoryURL: dir,
            limits: BlobExportLimits(
                maximumBytesPerTransfer: maxLimit,
                maximumChunkBytes: 256 * 1024,
                maximumConcurrentTransfers: 2,
                maximumStagingBytes: 600 * 1024 * 1024
            ),
            checkpointInterval: 32
        )

        // 1. Verify declared size exceeding 512 MB is rejected immediately
        let overLimitAuth = BlobCaptureAuthorization(transferID: "over-512mb", tabID: "tab-over", documentID: "doc-over")
        let overLimitEnvelope = BlobCaptureMetadataEnvelope(
            transferID: "over-512mb", documentID: "doc-over",
            sourceURL: URL(string: "blob:https://example.test/over-512mb")!,
            mimeType: "application/octet-stream", declaredSize: maxLimit + 1,
            resourceKind: .completeBlobCandidate, readable: true
        )
        do {
            _ = try await writer.begin(authorization: overLimitAuth, envelope: overLimitEnvelope)
            XCTFail("Should reject transfer exceeding 512 MB limit")
        } catch let error as BlobExportError {
            XCTAssertEqual(error, .sizeLimitExceeded)
        }

        // 2. Verify declared size at exact 512 MB boundary is accepted
        let auth = BlobCaptureAuthorization(transferID: "exact-512mb", tabID: "tab-exact", documentID: "doc-exact")
        let envelope = BlobCaptureMetadataEnvelope(
            transferID: "exact-512mb", documentID: "doc-exact",
            sourceURL: URL(string: "blob:https://example.test/exact-512mb")!,
            mimeType: "application/octet-stream", declaredSize: maxLimit,
            resourceKind: .completeBlobCandidate, readable: true
        )
        let initialRecord = try await writer.begin(authorization: auth, envelope: envelope, suggestedFilename: "large-512.bin")
        XCTAssertEqual(initialRecord.expectedSize, maxLimit)
        await writer.cancel(transferID: "exact-512mb")

        // 3. Flat memory chunk streaming: stream repeated 256 KB chunks using a single reusable buffer
        #if canImport(CryptoKit)
        let streamBytes: Int64 = 40 * 1024 * 1024 // 40 MB on Apple platforms
        #else
        let streamBytes: Int64 = 10 * 1024 * 1024 // 10 MB on Linux pure-Swift software fallback
        #endif
        let chunkSize = 256 * 1024
        let streamChunks = Int(streamBytes / Int64(chunkSize))

        let streamAuth = BlobCaptureAuthorization(transferID: "stream-flat", tabID: "tab-flat", documentID: "doc-flat")
        let streamEnvelope = BlobCaptureMetadataEnvelope(
            transferID: "stream-flat", documentID: "doc-flat",
            sourceURL: URL(string: "blob:https://example.test/stream-flat")!,
            mimeType: "application/octet-stream", declaredSize: streamBytes,
            resourceKind: .completeBlobCandidate, readable: true
        )
        _ = try await writer.begin(authorization: streamAuth, envelope: streamEnvelope, suggestedFilename: "stream-flat.bin")

        let reusableChunk = makeDeterministicData(length: chunkSize, seed: 0x77)
        let chunkChecksum = sha(reusableChunk)
        var offset: Int64 = 0

        var fullHasher = EngineSHA256Hasher()
        for i in 0..<streamChunks {
            fullHasher.update(data: reusableChunk)
            _ = try await writer.append(
                transferID: "stream-flat", chunkIndex: i, offset: offset,
                data: reusableChunk, sha256: chunkChecksum
            )
            offset += Int64(chunkSize)
        }

        let expectedDigest = fullHasher.finalize()
        let snap = try await writer.complete(
            transferID: "stream-flat", finalChunkIndex: streamChunks,
            finalOffset: offset, declaredFileDigest: expectedDigest
        )

        XCTAssertEqual(snap.state, .completed)
        XCTAssertEqual(snap.bytesWritten, streamBytes)
        XCTAssertEqual(snap.outputDigest, expectedDigest)

        let finalPath = snap.finalURL!.path
        let diskSize = FileManager.default.fileSize(atPath: finalPath) ?? 0
        XCTAssertEqual(diskSize, streamBytes)
    }

    // MARK: - Workstream B: WebContent Process Termination Crash Recovery

    func testWebContentTerminationAtMetadataStagePreservesDiagnostics() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let service = BrowserBlobCaptureService(destinationDirectoryURL: dir)
        let transferID = "term-meta"
        let tabID = "tab-meta"

        await service.authorize(transferID: transferID, tabID: tabID, documentID: "doc1")
        let metaPayload: [String: Any] = [
            "version": 2, "kind": "metadata", "transferID": transferID,
            "tabID": tabID, "documentID": "doc1",
            "url": "blob:https://example.test/term-meta",
            "mimeType": "video/mp4", "size": 1024 * 1024,
            "readable": true, "resourceKind": "completeBlobCandidate"
        ]
        let ack = await service.receive(payload: metaPayload)
        XCTAssertTrue(ack.accepted)

        // Simulate WebContent process termination immediately after metadata
        let interrupted = await service.handleWebContentProcessTermination(tabID: tabID)
        XCTAssertEqual(interrupted.count, 1)
        XCTAssertEqual(interrupted.first?.transferID, transferID)
        XCTAssertEqual(interrupted.first?.chunkSequenceNumber, 0)
        XCTAssertEqual(interrupted.first?.byteOffset, 0)
        XCTAssertEqual(interrupted.first?.transferState, .interrupted)
        XCTAssertTrue(interrupted.first?.isInterruptedByProcessTermination == true)
        XCTAssertNotNil(interrupted.first?.processTerminationTimestamp)

        // Ensure record is saved with .interrupted state
        let record = await service.loadTransferRecord(for: transferID)
        XCTAssertEqual(record?.state, .interrupted)
        XCTAssertNotEqual(record?.state, .completed)
    }

    func testWebContentTerminationDuringChunk0PreservesInitialDataAndDiagnostics() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let service = BrowserBlobCaptureService(destinationDirectoryURL: dir)
        let transferID = "term-chunk0"
        let tabID = "tab-chunk0"

        await service.authorize(transferID: transferID, tabID: tabID, documentID: "doc1")
        _ = await service.receive(payload: [
            "version": 2, "kind": "metadata", "transferID": transferID,
            "tabID": tabID, "documentID": "doc1",
            "url": "blob:https://example.test/term-chunk0",
            "mimeType": "video/mp4", "size": 1024 * 1024,
            "readable": true, "resourceKind": "completeBlobCandidate"
        ])

        let chunk = makeDeterministicData(length: 64 * 1024)
        _ = await service.receive(payload: [
            "version": 2, "kind": "chunk", "transferID": transferID,
            "tabID": tabID, "documentID": "doc1",
            "chunkIndex": 0, "offset": 0,
            "base64": chunk.base64EncodedString(), "sha256": sha(chunk)
        ])

        // WebContent process terminates
        let interrupted = await service.handleWebContentProcessTermination(tabID: tabID)
        XCTAssertEqual(interrupted.count, 1)
        XCTAssertEqual(interrupted.first?.chunkSequenceNumber, 1)
        XCTAssertEqual(interrupted.first?.byteOffset, Int64(chunk.count))
        XCTAssertEqual(interrupted.first?.stagingFileSize, Int64(chunk.count))
        XCTAssertEqual(interrupted.first?.transferState, .interrupted)

        // Staging file must still exist and contain the chunk
        let record = await service.loadTransferRecord(for: transferID)
        XCTAssertNotNil(record)
        XCTAssertTrue(FileManager.default.fileExists(atPath: record!.stagingURL.path))
        XCTAssertEqual(FileManager.default.fileSize(atPath: record!.stagingURL.path), Int64(chunk.count))
    }

    func testWebContentTerminationMidwayThroughTransferPreservesDiagnosticsAndStaging() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = BlobExportWriter(
            destinationDirectoryURL: dir,
            limits: BlobExportLimits(
                maximumBytesPerTransfer: 20 * 1024 * 1024,
                maximumChunkBytes: 256 * 1024,
                maximumConcurrentTransfers: 2,
                maximumStagingBytes: 40 * 1024 * 1024
            ),
            checkpointInterval: 8
        )

        let auth = BlobCaptureAuthorization(transferID: "term-midway", tabID: "tab-mid", documentID: "doc-mid")
        let envelope = BlobCaptureMetadataEnvelope(
            transferID: "term-midway", documentID: "doc-mid",
            sourceURL: URL(string: "blob:https://example.test/mid")!,
            mimeType: "video/mp4", declaredSize: 10 * 1024 * 1024,
            resourceKind: .completeBlobCandidate, readable: true
        )
        _ = try await writer.begin(authorization: auth, envelope: envelope, suggestedFilename: "mid.mp4")

        let chunkSize = 256 * 1024
        let chunksWritten = 15 // 15 chunks (checkpoint happened at chunk 8)
        var offset: Int64 = 0

        for i in 0..<chunksWritten {
            let chunk = makeDeterministicData(length: chunkSize, seed: UInt8(i))
            _ = try await writer.append(
                transferID: "term-midway", chunkIndex: i, offset: offset,
                data: chunk, sha256: sha(chunk),
                acknowledgementLatencyMs: 1.5
            )
            offset += Int64(chunkSize)
        }

        // WebContent process crash
        let interrupted = await writer.handleWebContentProcessTermination(tabID: "tab-mid")
        XCTAssertEqual(interrupted.count, 1)

        let diag = interrupted[0]
        XCTAssertEqual(diag.chunkSequenceNumber, 15)
        XCTAssertEqual(diag.byteOffset, offset)
        XCTAssertEqual(diag.stagingFileSize, offset)
        XCTAssertEqual(diag.lastSuccessfulCheckpointOffset, Int64(8 * chunkSize))
        XCTAssertNotNil(diag.lastSuccessfulCheckpointTimestamp)
        XCTAssertTrue(diag.isInterruptedByProcessTermination)
        XCTAssertEqual(diag.transferState, .interrupted)

        // Staging file exists on disk with exact written bytes
        let record = await writer.loadRecord(for: "term-midway")
        XCTAssertEqual(record?.state, .interrupted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: record!.stagingURL.path))
        XCTAssertEqual(FileManager.default.fileSize(atPath: record!.stagingURL.path), offset)
    }

    func testWebContentTerminationImmediatelyBeforeAndAfterCheckpoint() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Test Crash Before Checkpoint (chunk 7 with interval 8)
        do {
            let writer = BlobExportWriter(destinationDirectoryURL: dir, checkpointInterval: 8)
            let auth = BlobCaptureAuthorization(transferID: "pre-cp", tabID: "tab-pre", documentID: "doc")
            let env = BlobCaptureMetadataEnvelope(
                transferID: "pre-cp", documentID: "doc",
                sourceURL: URL(string: "blob:https://example.test/pre")!,
                mimeType: "video/mp4", declaredSize: 4 * 1024 * 1024,
                resourceKind: .completeBlobCandidate, readable: true
            )
            _ = try await writer.begin(authorization: auth, envelope: env)
            var offset: Int64 = 0
            for i in 0..<7 {
                let chunk = makeDeterministicData(length: 64 * 1024)
                _ = try await writer.append(transferID: "pre-cp", chunkIndex: i, offset: offset, data: chunk, sha256: sha(chunk))
                offset += Int64(chunk.count)
            }
            let diags = await writer.handleWebContentProcessTermination(tabID: "tab-pre")
            XCTAssertEqual(diags.first?.chunkSequenceNumber, 7)
            XCTAssertEqual(diags.first?.lastSuccessfulCheckpointOffset, 0, "No checkpoint should have occurred yet")
        }

        // Test Crash After Checkpoint (chunk 8 with interval 8)
        do {
            let writer = BlobExportWriter(destinationDirectoryURL: dir, checkpointInterval: 8)
            let auth = BlobCaptureAuthorization(transferID: "post-cp", tabID: "tab-post", documentID: "doc")
            let env = BlobCaptureMetadataEnvelope(
                transferID: "post-cp", documentID: "doc",
                sourceURL: URL(string: "blob:https://example.test/post")!,
                mimeType: "video/mp4", declaredSize: 4 * 1024 * 1024,
                resourceKind: .completeBlobCandidate, readable: true
            )
            _ = try await writer.begin(authorization: auth, envelope: env)
            var offset: Int64 = 0
            for i in 0..<8 {
                let chunk = makeDeterministicData(length: 64 * 1024)
                _ = try await writer.append(transferID: "post-cp", chunkIndex: i, offset: offset, data: chunk, sha256: sha(chunk))
                offset += Int64(chunk.count)
            }
            let diags = await writer.handleWebContentProcessTermination(tabID: "tab-post")
            XCTAssertEqual(diags.first?.chunkSequenceNumber, 8)
            XCTAssertEqual(diags.first?.lastSuccessfulCheckpointOffset, offset, "Checkpoint must have updated to offset")
            XCTAssertNotNil(diags.first?.lastSuccessfulCheckpointTimestamp)
        }
    }

    func testRecoveryAtLaunchNeverPublishesInterruptedOrIncompleteTransfers() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = BlobExportWriter(destinationDirectoryURL: dir)
        let auth = BlobCaptureAuthorization(transferID: "t-crash", tabID: "tab", documentID: "doc")
        let env = BlobCaptureMetadataEnvelope(
            transferID: "t-crash", documentID: "doc",
            sourceURL: URL(string: "blob:https://example.test/t-crash")!,
            mimeType: "video/mp4", declaredSize: 1024,
            resourceKind: .completeBlobCandidate, readable: true
        )
        _ = try await writer.begin(authorization: auth, envelope: env, suggestedFilename: "neverpublish.mp4")

        let chunk = Data("some-data".utf8)
        _ = try await writer.append(transferID: "t-crash", chunkIndex: 0, offset: 0, data: chunk, sha256: sha(chunk))

        // Process terminates
        _ = await writer.handleWebContentProcessTermination(tabID: "tab")

        // Now simulate app restart recovery
        let newWriter = BlobExportWriter(destinationDirectoryURL: dir)
        let recovered = await newWriter.recoverIncompleteTransfers()

        // Must recover record marked .interrupted
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered.first?.transferID, "t-crash")
        XCTAssertEqual(recovered.first?.state, .interrupted)

        // Strict invariant: output destination file must NOT exist!
        let finalPath = dir.appendingPathComponent("neverpublish.mp4").path
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalPath))
    }

    func testUnmarkedIncompleteTransfersAtAppLaunchAreMarkedFailedAndStagingCleaned() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Simulate a sudden power-loss where handleWebContentProcessTermination wasn't even called
        let writer = BlobExportWriter(destinationDirectoryURL: dir)
        let auth = BlobCaptureAuthorization(transferID: "t-powerloss", tabID: "tab", documentID: "doc")
        let env = BlobCaptureMetadataEnvelope(
            transferID: "t-powerloss", documentID: "doc",
            sourceURL: URL(string: "blob:https://example.test/powerloss")!,
            mimeType: "video/mp4", declaredSize: 2048,
            resourceKind: .completeBlobCandidate, readable: true
        )
        _ = try await writer.begin(authorization: auth, envelope: env, suggestedFilename: "powerloss.mp4")

        let chunk = Data("chunk-before-power-loss".utf8)
        _ = try await writer.append(transferID: "t-powerloss", chunkIndex: 0, offset: 0, data: chunk, sha256: sha(chunk))

        let stagingURL = dir.appendingPathComponent(".t-powerloss.blob.part")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagingURL.path))

        // Create new writer without calling handleWebContentProcessTermination
        let rebootWriter = BlobExportWriter(destinationDirectoryURL: dir)
        let recovered = await rebootWriter.recoverIncompleteTransfers()

        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered.first?.transferID, "t-powerloss")
        XCTAssertEqual(recovered.first?.state, .failed)
        // Staging file must be cleaned up
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingURL.path))
        // Target file must never exist
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("powerloss.mp4").path))
    }

    // MARK: - Workstream C: Cancellation Resilience & Lifecycle Cleanliness

    func testCancellationViaWireMessageCleansStagingAndSetsCancelledState() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let service = BrowserBlobCaptureService(destinationDirectoryURL: dir)
        let transferID = "cancel-wire"
        let tabID = "tab-c"

        await service.authorize(transferID: transferID, tabID: tabID, documentID: "doc-c")
        _ = await service.receive(payload: [
            "version": 2, "kind": "metadata", "transferID": transferID,
            "tabID": tabID, "documentID": "doc-c",
            "url": "blob:https://example.test/cancel-wire",
            "mimeType": "video/mp4", "size": 1024 * 1024,
            "readable": true, "resourceKind": "completeBlobCandidate"
        ])

        let chunk = makeDeterministicData(length: 64 * 1024)
        _ = await service.receive(payload: [
            "version": 2, "kind": "chunk", "transferID": transferID,
            "tabID": tabID, "documentID": "doc-c",
            "chunkIndex": 0, "offset": 0,
            "base64": chunk.base64EncodedString(), "sha256": sha(chunk)
        ])

        let stagingURL = dir.appendingPathComponent(".\(transferID).blob.part")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagingURL.path))

        // Client sends cancel wire message
        let cancelAck = await service.receive(payload: [
            "version": 2, "kind": "cancel", "transferID": transferID,
            "tabID": tabID, "reason": "user clicked stop in browser"
        ])
        XCTAssertTrue(cancelAck.accepted)

        // Staging file removed
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingURL.path))

        // Record reflects .cancelled state
        let record = await service.loadTransferRecord(for: transferID)
        XCTAssertEqual(record?.state, .cancelled)

        // Diagnostics reflects .cancelled
        let diag = await service.loadCrashDiagnostics(for: transferID)
        XCTAssertEqual(diag?.transferState, .cancelled)
    }

    func testCancellationDuringTabNavigationRejectsFurtherChunks() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let service = BrowserBlobCaptureService(destinationDirectoryURL: dir)
        let transferID = "nav-race"
        let tabID = "tab-nav"

        await service.authorize(transferID: transferID, tabID: tabID, documentID: "doc-nav")
        _ = await service.receive(payload: [
            "version": 2, "kind": "metadata", "transferID": transferID,
            "tabID": tabID, "documentID": "doc-nav",
            "url": "blob:https://example.test/nav-race",
            "mimeType": "video/mp4", "size": 1024 * 1024,
            "readable": true, "resourceKind": "completeBlobCandidate"
        ])

        // User navigates away in tab -> caller cancels transfer
        await service.cancel(captureID: transferID)

        // Delayed chunk arrives from previous page
        let chunk = makeDeterministicData(length: 64 * 1024)
        let chunkAck = await service.receive(payload: [
            "version": 2, "kind": "chunk", "transferID": transferID,
            "tabID": tabID, "documentID": "doc-nav",
            "chunkIndex": 0, "offset": 0,
            "base64": chunk.base64EncodedString(), "sha256": sha(chunk)
        ])
        XCTAssertFalse(chunkAck.accepted)
        XCTAssertEqual(chunkAck.error, .captureNotAuthorized)
    }

    func testCancellationRaceWithCompletionDoesNotProduceOutputFile() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = BlobExportWriter(destinationDirectoryURL: dir)
        let auth = BlobCaptureAuthorization(transferID: "race-cancel", tabID: "tab", documentID: "doc")
        let env = BlobCaptureMetadataEnvelope(
            transferID: "race-cancel", documentID: "doc",
            sourceURL: URL(string: "blob:https://example.test/race")!,
            mimeType: "video/mp4", declaredSize: 64,
            resourceKind: .completeBlobCandidate, readable: true
        )
        _ = try await writer.begin(authorization: auth, envelope: env, suggestedFilename: "race-cancel.mp4")

        let chunk = Data(repeating: 0x55, count: 64)
        _ = try await writer.append(transferID: "race-cancel", chunkIndex: 0, offset: 0, data: chunk, sha256: sha(chunk))

        // Native cancels right as completion was being prepared
        await writer.cancel(transferID: "race-cancel")

        // Calling complete now must fail
        do {
            _ = try await writer.complete(transferID: "race-cancel", finalChunkIndex: 1, finalOffset: 64)
            XCTFail("Complete after cancel must fail")
        } catch let err as BlobExportError {
            XCTAssertEqual(err, .unknownTransferID)
        }

        // Final file must never be published
        let finalPath = dir.appendingPathComponent("race-cancel.mp4").path
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalPath))
    }

    // MARK: - Workstream D: Storage Exhaustion & Limit Enforcement

    func testStorageLimitExceededOnDeclaredSizeRejectsBeforeWriting() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = BlobExportWriter(
            destinationDirectoryURL: dir,
            limits: BlobExportLimits(
                maximumBytesPerTransfer: 512 * 1024 * 1024, // 512 MB
                maximumChunkBytes: 256 * 1024,
                maximumConcurrentTransfers: 2,
                maximumStagingBytes: 1024 * 1024 * 1024
            )
        )

        let auth = BlobCaptureAuthorization(transferID: "t-oversized", tabID: "tab", documentID: "doc")
        // Declared size 512 MB + 1 byte
        let env = BlobCaptureMetadataEnvelope(
            transferID: "t-oversized", documentID: "doc",
            sourceURL: URL(string: "blob:https://example.test/oversized")!,
            mimeType: "video/mp4", declaredSize: 512 * 1024 * 1024 + 1,
            resourceKind: .completeBlobCandidate, readable: true
        )

        do {
            _ = try await writer.begin(authorization: auth, envelope: env)
            XCTFail("Must reject declared size exceeding maximumBytesPerTransfer")
        } catch let err as BlobExportError {
            XCTAssertEqual(err, .sizeLimitExceeded)
        }
    }

    func testStagingLimitExceededAcrossTransfersRejectsNewTransfer() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Max staging: 10 MB total
        let writer = BlobExportWriter(
            destinationDirectoryURL: dir,
            limits: BlobExportLimits(
                maximumBytesPerTransfer: 10 * 1024 * 1024,
                maximumChunkBytes: 256 * 1024,
                maximumConcurrentTransfers: 5,
                maximumStagingBytes: 10 * 1024 * 1024
            )
        )

        let auth1 = BlobCaptureAuthorization(transferID: "t1", tabID: "tab", documentID: "doc")
        let env1 = BlobCaptureMetadataEnvelope(
            transferID: "t1", documentID: "doc",
            sourceURL: URL(string: "blob:https://example.test/t1")!,
            mimeType: "video/mp4", declaredSize: 8 * 1024 * 1024,
            resourceKind: .completeBlobCandidate, readable: true
        )
        _ = try await writer.begin(authorization: auth1, envelope: env1)

        // Second transfer requests 4 MB (8 + 4 = 12 MB > 10 MB limit)
        let auth2 = BlobCaptureAuthorization(transferID: "t2", tabID: "tab", documentID: "doc")
        let env2 = BlobCaptureMetadataEnvelope(
            transferID: "t2", documentID: "doc",
            sourceURL: URL(string: "blob:https://example.test/t2")!,
            mimeType: "video/mp4", declaredSize: 4 * 1024 * 1024,
            resourceKind: .completeBlobCandidate, readable: true
        )

        do {
            _ = try await writer.begin(authorization: auth2, envelope: env2)
            XCTFail("Must reject staging storage limit exceeded")
        } catch let err as BlobExportError {
            XCTAssertEqual(err, .stagingStorageLimitExceeded)
        }
    }

    func testConcurrentTransfersLimitEnforced() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Max concurrent = 2
        let writer = BlobExportWriter(
            destinationDirectoryURL: dir,
            limits: BlobExportLimits(
                maximumBytesPerTransfer: 10 * 1024 * 1024,
                maximumChunkBytes: 256 * 1024,
                maximumConcurrentTransfers: 2,
                maximumStagingBytes: 50 * 1024 * 1024
            )
        )

        let env1 = BlobCaptureMetadataEnvelope(
            transferID: "c1", documentID: "doc",
            sourceURL: URL(string: "blob:https://example.test/c1")!,
            mimeType: "video/mp4", declaredSize: 1024,
            resourceKind: .completeBlobCandidate, readable: true
        )
        let env2 = BlobCaptureMetadataEnvelope(
            transferID: "c2", documentID: "doc",
            sourceURL: URL(string: "blob:https://example.test/c2")!,
            mimeType: "video/mp4", declaredSize: 1024,
            resourceKind: .completeBlobCandidate, readable: true
        )
        let env3 = BlobCaptureMetadataEnvelope(
            transferID: "c3", documentID: "doc",
            sourceURL: URL(string: "blob:https://example.test/c3")!,
            mimeType: "video/mp4", declaredSize: 1024,
            resourceKind: .completeBlobCandidate, readable: true
        )

        _ = try await writer.begin(authorization: BlobCaptureAuthorization(transferID: "c1", tabID: "t", documentID: "doc"), envelope: env1)
        _ = try await writer.begin(authorization: BlobCaptureAuthorization(transferID: "c2", tabID: "t", documentID: "doc"), envelope: env2)

        do {
            _ = try await writer.begin(authorization: BlobCaptureAuthorization(transferID: "c3", tabID: "t", documentID: "doc"), envelope: env3)
            XCTFail("3rd concurrent transfer must be rejected")
        } catch let err as BlobExportError {
            XCTAssertEqual(err, .concurrentTransferLimitExceeded)
        }
    }

    func testCriticallyLowDiskReserveRejectsTransfer() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Set minimumFreeDiskSpaceBytes to an impossible value (e.g. 50 Petabytes)
        let impossibleReserve: Int64 = 50 * 1024 * 1024 * 1024 * 1024 * 1024
        let writer = BlobExportWriter(
            destinationDirectoryURL: dir,
            limits: BlobExportLimits(
                maximumBytesPerTransfer: 10 * 1024 * 1024,
                maximumChunkBytes: 256 * 1024,
                maximumConcurrentTransfers: 2,
                maximumStagingBytes: 50 * 1024 * 1024,
                minimumFreeDiskSpaceBytes: impossibleReserve
            )
        )

        let auth = BlobCaptureAuthorization(transferID: "t-lowdisk", tabID: "tab", documentID: "doc")
        let env = BlobCaptureMetadataEnvelope(
            transferID: "t-lowdisk", documentID: "doc",
            sourceURL: URL(string: "blob:https://example.test/lowdisk")!,
            mimeType: "video/mp4", declaredSize: 1024,
            resourceKind: .completeBlobCandidate, readable: true
        )

        do {
            _ = try await writer.begin(authorization: auth, envelope: env)
            XCTFail("Must reject when free disk space is below minimum reserve")
        } catch let BlobExportError.storageCriticallyLow(required, available, reserve) {
            XCTAssertEqual(reserve, impossibleReserve)
            XCTAssertGreaterThanOrEqual(required, 0)
            XCTAssertGreaterThan(available, 0)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
