import Foundation
import XCTest
@testable import DM_Reverse_engineering

// MARK: - Production Blob Export Service Tests (7H.3P)
//
// Organized by failure-mode domain as specified in the 7H.3P definition of done.
// Tests that exercise disk I/O use a unique temporary directory, always cleaned up.

final class BrowserBlobCaptureServiceTests: XCTestCase {

    // MARK: - Helpers

    private func tmpDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func makeWriter(dir: URL, maxBytes: Int64 = 1024, maxChunk: Int = 64, maxConcurrent: Int = 2) -> BlobExportWriter {
        BlobExportWriter(
            destinationDirectoryURL: dir,
            limits: BlobExportLimits(
                maximumBytesPerTransfer: maxBytes,
                maximumChunkBytes: maxChunk,
                maximumConcurrentTransfers: maxConcurrent,
                maximumStagingBytes: maxBytes * 2
            ),
            checkpointInterval: 2
        )
    }

    private func makeAuth(transferID: String = "t1", tabID: String = "tab-A",
                          docID: String? = "doc-1", expiry: Date = Date().addingTimeInterval(300)) -> BlobCaptureAuthorization {
        BlobCaptureAuthorization(transferID: transferID, tabID: tabID, documentID: docID, expiresAt: expiry)
    }

    private func makeEnvelope(transferID: String = "t1", docID: String? = "doc-1",
                               size: Int64? = nil, kind: BlobCaptureResourceKind = .completeBlobCandidate) -> BlobCaptureMetadataEnvelope {
        BlobCaptureMetadataEnvelope(
            transferID: transferID, documentID: docID,
            sourceURL: URL(string: "blob:https://example.test/\(transferID)")!,
            mimeType: "video/mp4", declaredSize: size,
            resourceKind: kind, readable: true
        )
    }

    private func sha(_ data: Data) -> String { EngineSHA256.hash(data: data) }

    func testIncrementalHasherMatchesKnownVectorsAcrossChunkBoundaries() {
        let vectors: [(Data, String)] = [
            (Data(), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
            (Data(repeating: 0x61, count: 65), "635361c48bb9eab14198e76ea8ab7f1a41685d6ad62aa9146d301d4f17eb0ae0"),
        ]
        for (data, expected) in vectors {
            var hasher = EngineSHA256Hasher()
            for byte in data {
                hasher.update(data: Data([byte]))
            }
            XCTAssertEqual(hasher.finalize(), expected)
        }
    }

    // MARK: - 1. Happy path

    func testCompleteTransferWritesCorrectBytesAndReturnsDigest() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = makeWriter(dir: dir)
        let auth = makeAuth()
        let a = Data("hello ".utf8)
        let b = Data("world".utf8)

        _ = try await writer.begin(authorization: auth, envelope: makeEnvelope(size: 11), suggestedFilename: "out.mp4")
        _ = try await writer.append(transferID: "t1", chunkIndex: 0, offset: 0, data: a, sha256: sha(a))
        _ = try await writer.append(transferID: "t1", chunkIndex: 1, offset: 6, data: b, sha256: sha(b))
        let snap = try await writer.complete(transferID: "t1", finalChunkIndex: 2, finalOffset: 11)

        XCTAssertEqual(snap.state, .completed)
        let finalURL = try XCTUnwrap(snap.finalURL)
        XCTAssertEqual(try Data(contentsOf: finalURL), Data("hello world".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(".t1.blob.part").path))
        XCTAssertNotNil(snap.outputDigest)
        XCTAssertEqual(snap.outputDigest!.count, 64)
        XCTAssertTrue(snap.isComplete)
    }

    func testTwoConcurrentTransfersRemainingOrderedAndIsolated() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = makeWriter(dir: dir, maxBytes: 256, maxConcurrent: 2)

        let a = Data("alpha".utf8), b = Data("beta-".utf8)
        _ = try await writer.begin(authorization: makeAuth(transferID: "x1", docID: nil), envelope: makeEnvelope(transferID: "x1", docID: nil, size: 5), suggestedFilename: "x1.mp4")
        _ = try await writer.begin(authorization: makeAuth(transferID: "x2", docID: nil), envelope: makeEnvelope(transferID: "x2", docID: nil, size: 5), suggestedFilename: "x2.mp4")
        _ = try await writer.append(transferID: "x1", chunkIndex: 0, offset: 0, data: a, sha256: sha(a))
        _ = try await writer.append(transferID: "x2", chunkIndex: 0, offset: 0, data: b, sha256: sha(b))
        let snap1 = try await writer.complete(transferID: "x1", finalChunkIndex: 1, finalOffset: 5)
        let snap2 = try await writer.complete(transferID: "x2", finalChunkIndex: 1, finalOffset: 5)

        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(snap1.finalURL)), a)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(snap2.finalURL)), b)
        XCTAssertNotEqual(snap1.finalURL, snap2.finalURL)
    }

    func testWholeFileDigestIsVerifiedWhenProvided() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = makeWriter(dir: dir)
        let data = Data("digest-check".utf8)
        _ = try await writer.begin(authorization: makeAuth(), envelope: makeEnvelope(size: Int64(data.count)), suggestedFilename: "d.mp4")
        _ = try await writer.append(transferID: "t1", chunkIndex: 0, offset: 0, data: data, sha256: sha(data))
        let correct = sha(data)
        let snap = try await writer.complete(transferID: "t1", finalChunkIndex: 1, finalOffset: Int64(data.count), declaredFileDigest: correct)
        XCTAssertEqual(snap.state, .completed)
        XCTAssertEqual(snap.outputDigest, correct)
    }

    // MARK: - 2. Protocol validation

    func testChunkBeforeMetadataIsRejected() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let receiver = BrowserBlobCaptureReceiver(writer: makeWriter(dir: dir))
        await receiver.authorize(transferID: "nmd", tabID: "tab", documentID: nil, candidateID: nil)
        // No metadata sent first — send a chunk directly
        let chunkPayload: [String: Any] = [
            "kind": "chunk", "transferID": "nmd",
            "chunkIndex": 0, "offset": 0,
            "base64": Data("x".utf8).base64EncodedString(),
            "sha256": sha(Data("x".utf8))
        ]
        let ack = await receiver.receive(payload: chunkPayload)
        XCTAssertFalse(ack.accepted)
        XCTAssertEqual(ack.error, .tabMismatch)
    }

    func testUnknownTransferIDIsRejected() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let service = BrowserBlobCaptureService(destinationDirectoryURL: dir)
        let ack = await service.receive(payload: [
            "kind": "metadata", "transferID": "unknown-99",
            "url": "blob:https://x.test/1", "readable": true,
            "resourceKind": "completeBlobCandidate"
        ])
        XCTAssertFalse(ack.accepted)
        XCTAssertEqual(ack.error, .captureNotAuthorized)
    }

    func testUnsupportedProtocolVersionIsRejected() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let service = BrowserBlobCaptureService(destinationDirectoryURL: dir)
        await service.register(captureID: "ver-t", documentID: nil)
        let ack = await service.receive(payload: [
            "version": 99, "kind": "metadata", "transferID": "ver-t",
            "url": "blob:https://x.test/v", "readable": true,
            "resourceKind": "completeBlobCandidate"
        ])
        XCTAssertFalse(ack.accepted)
        if case .unsupportedProtocolVersion(99) = ack.error! { } else {
            XCTFail("Expected unsupportedProtocolVersion(99), got \(String(describing: ack.error))")
        }
    }

    func testWrongDocumentIDIsRejected() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let service = BrowserBlobCaptureService(destinationDirectoryURL: dir)
        await service.register(captureID: "doc-t", documentID: "expected-doc")
        let ack = await service.receive(payload: [
            "kind": "metadata", "transferID": "doc-t", "documentID": "wrong-doc",
            "url": "blob:https://x.test/d", "readable": true,
            "resourceKind": "completeBlobCandidate"
        ])
        XCTAssertFalse(ack.accepted)
        XCTAssertEqual(ack.error, .documentMismatch)
    }

    func testExpiredAuthorizationIsRejected() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = makeWriter(dir: dir)
        let auth = makeAuth(expiry: Date().addingTimeInterval(-1)) // already expired
        do {
            _ = try await writer.begin(authorization: auth, envelope: makeEnvelope(), suggestedFilename: "e.mp4")
            XCTFail("Expected authorizationExpired")
        } catch let e as BlobExportError {
            XCTAssertEqual(e, .authorizationExpired)
        }
    }

    func testDuplicateTransferIDIsRejected() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = makeWriter(dir: dir, maxConcurrent: 2)
        _ = try await writer.begin(authorization: makeAuth(), envelope: makeEnvelope(), suggestedFilename: "dup.mp4")
        do {
            _ = try await writer.begin(authorization: makeAuth(), envelope: makeEnvelope(), suggestedFilename: "dup2.mp4")
            XCTFail("Expected duplicateTransfer")
        } catch let e as BlobExportError {
            XCTAssertEqual(e, .duplicateTransfer)
        }
    }

    func testStreamingResourceIsRejected() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = makeWriter(dir: dir)
        do {
            _ = try await writer.begin(
                authorization: makeAuth(),
                envelope: makeEnvelope(kind: .streamOrUnknown),
                suggestedFilename: "stream.mp4"
            )
            XCTFail("Expected streamingResourceNotSupported")
        } catch let e as BlobExportError {
            XCTAssertEqual(e, .streamingResourceNotSupported)
        }
    }

    func testCompletionMessageBeforeAllChunksIsRejected() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = makeWriter(dir: dir)
        let data = Data("abc".utf8)
        _ = try await writer.begin(authorization: makeAuth(), envelope: makeEnvelope(size: 6), suggestedFilename: "c.mp4")
        _ = try await writer.append(transferID: "t1", chunkIndex: 0, offset: 0, data: data, sha256: sha(data))
        do {
            _ = try await writer.complete(transferID: "t1", finalChunkIndex: 1, finalOffset: 3)
            XCTFail("Expected incompleteTransfer")
        } catch let e as BlobExportError {
            XCTAssertEqual(e, .incompleteTransfer)
        }
        // Staging must be removed after abort
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(".t1.blob.part").path))
    }

    func testOutOfOrderChunkIndexIsRejected() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = makeWriter(dir: dir)
        _ = try await writer.begin(authorization: makeAuth(), envelope: makeEnvelope(), suggestedFilename: "o.mp4")
        let data = Data("ab".utf8)
        do {
            _ = try await writer.append(transferID: "t1", chunkIndex: 1, offset: 0, data: data, sha256: sha(data))
            XCTFail("Expected invalidChunkIndex")
        } catch let e as BlobExportError { XCTAssertEqual(e, .invalidChunkIndex) }
    }

    func testWrongOffsetIsRejected() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = makeWriter(dir: dir)
        _ = try await writer.begin(authorization: makeAuth(), envelope: makeEnvelope(), suggestedFilename: "oo.mp4")
        let data = Data("ab".utf8)
        do {
            _ = try await writer.append(transferID: "t1", chunkIndex: 0, offset: 99, data: data, sha256: sha(data))
            XCTFail("Expected invalidChunkOffset")
        } catch let e as BlobExportError { XCTAssertEqual(e, .invalidChunkOffset) }
    }

    func testInvalidChecksumFormatIsRejected() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = makeWriter(dir: dir)
        _ = try await writer.begin(authorization: makeAuth(), envelope: makeEnvelope(), suggestedFilename: "ic.mp4")
        let data = Data("x".utf8)
        do {
            _ = try await writer.append(transferID: "t1", chunkIndex: 0, offset: 0, data: data, sha256: "not-hex!!")
            XCTFail("Expected invalidChecksum")
        } catch let e as BlobExportError { XCTAssertEqual(e, .invalidChecksum) }
    }

    func testChecksumMismatchIsRejectedAndStagingRemoved() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = makeWriter(dir: dir)
        _ = try await writer.begin(authorization: makeAuth(), envelope: makeEnvelope(), suggestedFilename: "cm.mp4")
        let data = Data("real".utf8)
        let wrongHash = String(repeating: "0", count: 64)
        do {
            _ = try await writer.append(transferID: "t1", chunkIndex: 0, offset: 0, data: data, sha256: wrongHash)
            XCTFail("Expected checksumMismatch")
        } catch let e as BlobExportError { XCTAssertEqual(e, .checksumMismatch) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(".t1.blob.part").path))
    }

    func testWrongWholeFileDigestIsRejected() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = makeWriter(dir: dir)
        let data = Data("wd".utf8)
        _ = try await writer.begin(authorization: makeAuth(), envelope: makeEnvelope(size: Int64(data.count)), suggestedFilename: "wd.mp4")
        _ = try await writer.append(transferID: "t1", chunkIndex: 0, offset: 0, data: data, sha256: sha(data))
        do {
            _ = try await writer.complete(
                transferID: "t1", finalChunkIndex: 1, finalOffset: Int64(data.count),
                declaredFileDigest: String(repeating: "a", count: 64)
            )
            XCTFail("Expected wholeFileDigestMismatch")
        } catch let e as BlobExportError { XCTAssertEqual(e, .wholeFileDigestMismatch) }
    }

    func testMalformedWholeFileDigestIsRejected() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = makeWriter(dir: dir)
        let data = Data("malformed".utf8)
        _ = try await writer.begin(authorization: makeAuth(), envelope: makeEnvelope(size: Int64(data.count)), suggestedFilename: "malformed.mp4")
        _ = try await writer.append(transferID: "t1", chunkIndex: 0, offset: 0, data: data, sha256: sha(data))
        do {
            _ = try await writer.complete(
                transferID: "t1", finalChunkIndex: 1, finalOffset: Int64(data.count),
                declaredFileDigest: "not-a-sha256"
            )
            XCTFail("Expected invalidWholeFileDigest")
        } catch let error as BlobExportError {
            XCTAssertEqual(error, .invalidWholeFileDigest)
        }
    }

    func testChunkExceedingMaxChunkBytesIsRejected() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = makeWriter(dir: dir, maxChunk: 4)
        _ = try await writer.begin(authorization: makeAuth(), envelope: makeEnvelope(), suggestedFilename: "big.mp4")
        let big = Data(repeating: 0x42, count: 5)
        do {
            _ = try await writer.append(transferID: "t1", chunkIndex: 0, offset: 0, data: big, sha256: sha(big))
            XCTFail("Expected chunkTooLarge")
        } catch let e as BlobExportError { XCTAssertEqual(e, .chunkTooLarge) }
    }

    func testPerTransferSizeLimitIsEnforced() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = makeWriter(dir: dir, maxBytes: 4, maxChunk: 8)
        _ = try await writer.begin(authorization: makeAuth(), envelope: makeEnvelope(size: 3), suggestedFilename: "sl.mp4")
        let d1 = Data("abc".utf8)
        _ = try await writer.append(transferID: "t1", chunkIndex: 0, offset: 0, data: d1, sha256: sha(d1))
        let d2 = Data("xyz".utf8)
        do {
            _ = try await writer.append(transferID: "t1", chunkIndex: 1, offset: 3, data: d2, sha256: sha(d2))
            XCTFail("Expected sizeLimitExceeded")
        } catch let e as BlobExportError { XCTAssertEqual(e, .sizeLimitExceeded) }
    }

    func testConcurrentTransferLimitIsEnforced() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = makeWriter(dir: dir, maxConcurrent: 1)
        _ = try await writer.begin(authorization: makeAuth(transferID: "c1", docID: nil), envelope: makeEnvelope(transferID: "c1", docID: nil), suggestedFilename: "c1.mp4")
        do {
            _ = try await writer.begin(authorization: makeAuth(transferID: "c2", docID: nil), envelope: makeEnvelope(transferID: "c2", docID: nil), suggestedFilename: "c2.mp4")
            XCTFail("Expected concurrentTransferLimitExceeded")
        } catch let e as BlobExportError { XCTAssertEqual(e, .concurrentTransferLimitExceeded) }
    }

    // MARK: - 3. Storage and filename safety

    func testUnsafeFilenamesAreSanitized() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = makeWriter(dir: dir)
        _ = try await writer.begin(
            authorization: makeAuth(),
            envelope: makeEnvelope(),
            suggestedFilename: "../../../etc/passwd"
        )
        let data = Data("x".utf8)
        _ = try await writer.append(transferID: "t1", chunkIndex: 0, offset: 0, data: data, sha256: sha(data))
        let snap = try await writer.complete(transferID: "t1", finalChunkIndex: 1, finalOffset: 1)
        let finalURL = try XCTUnwrap(snap.finalURL)
        // The path must stay inside the destination dir
        XCTAssertTrue(finalURL.path.hasPrefix(dir.path))
        // Path traversal component must not appear
        XCTAssertFalse(finalURL.path.contains("etc/passwd"))
    }

    func testEmptyFilenameUsesFallback() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = makeWriter(dir: dir)
        _ = try await writer.begin(authorization: makeAuth(), envelope: makeEnvelope(), suggestedFilename: "   ")
        let data = Data("y".utf8)
        _ = try await writer.append(transferID: "t1", chunkIndex: 0, offset: 0, data: data, sha256: sha(data))
        let snap = try await writer.complete(transferID: "t1", finalChunkIndex: 1, finalOffset: 1)
        let name = snap.finalURL?.lastPathComponent ?? ""
        XCTAssertFalse(name.isEmpty)
        XCTAssertFalse(name.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    func testCollisionHandledWithUniqueFilename() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Pre-create the target file
        let preexisting = dir.appendingPathComponent("out.mp4")
        FileManager.default.createFile(atPath: preexisting.path, contents: Data("pre".utf8))

        let writer = makeWriter(dir: dir, maxConcurrent: 2)
        let d = Data("new".utf8)
        _ = try await writer.begin(authorization: makeAuth(transferID: "col", docID: nil), envelope: makeEnvelope(transferID: "col", docID: nil, size: 3), suggestedFilename: "out.mp4")
        _ = try await writer.append(transferID: "col", chunkIndex: 0, offset: 0, data: d, sha256: sha(d))
        let snap = try await writer.complete(transferID: "col", finalChunkIndex: 1, finalOffset: 3)

        let finalURL = try XCTUnwrap(snap.finalURL)
        XCTAssertNotEqual(finalURL, preexisting)
        XCTAssertEqual(try Data(contentsOf: finalURL), d)
        XCTAssertEqual(try Data(contentsOf: preexisting), Data("pre".utf8))
    }

    func testStagingFileIsRemovedAfterCancel() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = makeWriter(dir: dir)
        _ = try await writer.begin(authorization: makeAuth(), envelope: makeEnvelope(), suggestedFilename: "cancel.mp4")
        let staging = dir.appendingPathComponent(".t1.blob.part")
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path))
        await writer.cancel(transferID: "t1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    func testStagingFileIsRemovedAfterChecksumFailure() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = makeWriter(dir: dir)
        _ = try await writer.begin(authorization: makeAuth(), envelope: makeEnvelope(), suggestedFilename: "fail.mp4")
        let data = Data("zz".utf8)
        do {
            _ = try await writer.append(transferID: "t1", chunkIndex: 0, offset: 0, data: data, sha256: String(repeating: "f", count: 64))
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(".t1.blob.part").path))
    }

    // MARK: - 4. Transfer record persistence

    func testTransferRecordIsWrittenOnBegin() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = makeWriter(dir: dir)
        _ = try await writer.begin(authorization: makeAuth(), envelope: makeEnvelope(size: 10), suggestedFilename: "rec.mp4")
        let recordsDir = dir.appendingPathComponent(".transfer-records")
        let items = try FileManager.default.contentsOfDirectory(atPath: recordsDir.path)
        XCTAssertTrue(items.contains(where: { $0.hasSuffix(".json") }))
    }

    func testRecoveryMarksIncompleteStagingFilesAsFailed() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = makeWriter(dir: dir)
        // Begin but never complete
        _ = try await writer.begin(authorization: makeAuth(), envelope: makeEnvelope(size: 5), suggestedFilename: "rec2.mp4")
        // Simulate a second launch by calling recovery
        let recovered = await writer.recoverIncompleteTransfers()
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered.first?.state, .failed)
        XCTAssertNotNil(recovered.first?.failureReason)
        // Staging file must be cleaned up
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(".t1.blob.part").path))
    }

    // MARK: - 5. Receiver and service authorization

    func testCancelFromReceiverCleansUpWriter() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let service = BrowserBlobCaptureService(destinationDirectoryURL: dir)
        await service.register(captureID: "svc-cancel", documentID: nil)
        let ack = await service.receive(payload: [
            "kind": "metadata", "transferID": "svc-cancel",
            "url": "blob:https://x.test/sc", "readable": true,
            "resourceKind": "completeBlobCandidate"
        ])
        XCTAssertTrue(ack.accepted)
        await service.cancel(captureID: "svc-cancel")
        // Sending a chunk after cancel must fail
        let chunkAck = await service.receive(payload: [
            "kind": "chunk", "transferID": "svc-cancel",
            "chunkIndex": 0, "offset": 0,
            "base64": Data("x".utf8).base64EncodedString(),
            "sha256": sha(Data("x".utf8))
        ])
        XCTAssertFalse(chunkAck.accepted)
    }

    func testCancelAndCompletionRaceDoesNotProduceOutput() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = makeWriter(dir: dir, maxConcurrent: 2)
        let data = Data("race".utf8)
        _ = try await writer.begin(authorization: makeAuth(transferID: "race", docID: nil), envelope: makeEnvelope(transferID: "race", docID: nil, size: 4), suggestedFilename: "race.mp4")
        _ = try await writer.append(transferID: "race", chunkIndex: 0, offset: 0, data: data, sha256: sha(data))
        // Cancel before completing
        await writer.cancel(transferID: "race")
        // Now complete should fail (unknown)
        do {
            _ = try await writer.complete(transferID: "race", finalChunkIndex: 1, finalOffset: 4)
            XCTFail("Expected unknownTransferID")
        } catch let e as BlobExportError { XCTAssertEqual(e, .unknownTransferID) }
    }

    func testTabNavigationCancelsActiveCaptureViaService() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let service = BrowserBlobCaptureService(destinationDirectoryURL: dir)
        await service.register(captureID: "nav-cancel", documentID: "doc-nav")
        _ = await service.receive(payload: [
            "kind": "metadata", "transferID": "nav-cancel", "documentID": "doc-nav",
            "url": "blob:https://x.test/nc", "readable": true,
            "resourceKind": "completeBlobCandidate"
        ])
        // Simulate tab navigation — caller cancels
        await service.cancel(captureID: "nav-cancel")
        let afterCancel = await service.receive(payload: [
            "kind": "chunk", "transferID": "nav-cancel", "documentID": "doc-nav",
            "chunkIndex": 0, "offset": 0,
            "base64": Data("z".utf8).base64EncodedString(),
            "sha256": sha(Data("z".utf8))
        ])
        XCTAssertFalse(afterCancel.accepted)
    }

    // MARK: - 6. JS Bridge v2 properties

    func testBridgeScriptContainsProductionV2Markers() {
        let script = BlobCaptureBridge.script
        XCTAssertTrue(script.contains("PROTOCOL_VERSION = 2"))
        XCTAssertTrue(script.contains("transferID"))
        XCTAssertTrue(script.contains("rollingDigest"))
        XCTAssertTrue(script.contains("getReader"))
        XCTAssertTrue(script.contains("__lidBlobRegistry"))
        XCTAssertTrue(script.contains("crypto.subtle.digest"))
        XCTAssertTrue(script.contains("MAX_CHUNK_BYTES"))
        XCTAssertTrue(script.contains("awaitingAck"))
        XCTAssertFalse(script.contains("response.blob()"))
        XCTAssertFalse(script.contains("FileReader"))
        XCTAssertFalse(script.contains("captureID:"))  // must use transferID
    }

    func testStartCommandContainsBoundedChunkSize() {
        let cmd = BlobCaptureBridge.startCommand(
            blobURL: URL(string: "blob:https://video.example/1")!,
            transferID: "t-start",
            chunkSize: 1024 * 1024  // over limit, should be clamped
        )
        XCTAssertTrue(cmd.contains("262144"))   // clamped to MAX_CHUNK_BYTES
        XCTAssertTrue(cmd.contains("video.example"))
        XCTAssertTrue(cmd.contains("t-start"))
    }

    func testJavaScriptRollingDigestUsesStandardSHA256Constants() {
        XCTAssertTrue(BlobCaptureBridge.script.contains("0x3956c25b"))
        XCTAssertFalse(BlobCaptureBridge.script.contains("0x3956c25,"))
    }

    func testAcknowledgeAndCancelCommandsAreWellFormed() {
        let ackTrue = BlobCaptureBridge.acknowledgeCommand(transferID: "tid", accepted: true)
        let ackFalse = BlobCaptureBridge.acknowledgeCommand(transferID: "tid", accepted: false)
        let cancel = BlobCaptureBridge.cancelCommand(transferID: "tid")
        XCTAssertTrue(ackTrue.contains("true"))
        XCTAssertTrue(ackFalse.contains("false"))
        XCTAssertTrue(cancel.contains("cancel"))
        for cmd in [ackTrue, ackFalse, cancel] {
            XCTAssertFalse(cmd.isEmpty)
        }
    }

    // MARK: - 7. Backward compatibility aliases

    func testTypealiasesKeepOldCallSitesCompiling() {
        // These just need to resolve at compile time.
        let _: BrowserBlobCaptureLimits = .default
        let _: BlobTransferState = .requested
        let _: BlobCaptureResourceKind = .completeBlobCandidate
        XCTAssertEqual(BlobCaptureBridge.messageName, "browserBlobCapture")
    }

    func testSnapshotPredicatesAreCorrect() {
        let completed = BlobExportSnapshot(transferID: "x", state: .completed, bytesWritten: 10,
                                           expectedSize: 10, chunksReceived: 1, finalURL: URL(string: "file:///out.mp4"))
        let failed = BlobExportSnapshot(transferID: "x", state: .failed, bytesWritten: 0, expectedSize: nil, chunksReceived: 0)
        let cancelled = BlobExportSnapshot(transferID: "x", state: .cancelled, bytesWritten: 0, expectedSize: nil, chunksReceived: 0)
        XCTAssertTrue(completed.isComplete)
        XCTAssertFalse(completed.isFailed)
        XCTAssertTrue(failed.isFailed)
        XCTAssertTrue(cancelled.isCancelled)
    }

    func testTransferStateTerminalPredicate() {
        XCTAssertTrue(BlobTransferState.completed.isTerminal)
        XCTAssertTrue(BlobTransferState.cancelled.isTerminal)
        XCTAssertTrue(BlobTransferState.failed.isTerminal)
        XCTAssertFalse(BlobTransferState.requested.isTerminal)
        XCTAssertFalse(BlobTransferState.receivingChunks.isTerminal)
        XCTAssertFalse(BlobTransferState.finalizing.isTerminal)
    }

    // MARK: - 8. Large transfer / checkpointing

    func testLargeTransferWithCheckpointFlushing() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let chunkSize = 8
        let chunkCount = 20
        let total = chunkSize * chunkCount
        let writer = BlobExportWriter(
            destinationDirectoryURL: dir,
            limits: BlobExportLimits(maximumBytesPerTransfer: Int64(total + 64), maximumChunkBytes: chunkSize, maximumConcurrentTransfers: 1, maximumStagingBytes: Int64(total + 128)),
            checkpointInterval: 4
        )
        _ = try await writer.begin(authorization: makeAuth(), envelope: makeEnvelope(size: Int64(total)), suggestedFilename: "large.mp4")
        var expectedContent = Data()
        for i in 0..<chunkCount {
            let chunk = Data(repeating: UInt8(i % 256), count: chunkSize)
            _ = try await writer.append(
                transferID: "t1", chunkIndex: i,
                offset: Int64(i * chunkSize), data: chunk, sha256: sha(chunk)
            )
            expectedContent.append(chunk)
        }
        let snap = try await writer.complete(transferID: "t1", finalChunkIndex: chunkCount, finalOffset: Int64(total))
        XCTAssertEqual(snap.state, .completed)
        let output = try XCTUnwrap(snap.finalURL)
        XCTAssertEqual(try Data(contentsOf: output), expectedContent)
    }
}
