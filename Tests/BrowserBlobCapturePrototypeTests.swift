import Foundation
import XCTest
@testable import DM_Reverse_engineering

final class BrowserBlobCapturePrototypeTests: XCTestCase {
    func testChunkedBlobPrototypeWritesOrderedChunksAndFinalizesOnlyAfterCompletion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }

        let writer = BrowserBlobCapturePrototypeWriter(
            destinationDirectoryURL: directory,
            limits: BrowserBlobCaptureLimits(maximumBytes: 64, maximumChunkBytes: 8)
        )
        let metadata = BrowserBlobCaptureMetadata(
            captureID: "capture-1",
            sourceURL: URL(string: "blob:https://video.example/1")!,
            mimeType: "audio/mpeg",
            expectedSize: 11,
            kind: .completeBlobCandidate,
            readable: true
        )
        _ = try await writer.begin(metadata: metadata, filename: "episode.mp3")

        let first = Data("hello ".utf8)
        let second = Data("world".utf8)
        _ = try await writer.append(
            captureID: "capture-1",
            chunkIndex: 0,
            offset: 0,
            data: first,
            sha256: EngineSHA256.hash(data: first)
        )
        _ = try await writer.append(
            captureID: "capture-1",
            chunkIndex: 1,
            offset: Int64(first.count),
            data: second,
            sha256: EngineSHA256.hash(data: second)
        )
        let completed = try await writer.complete(captureID: "capture-1", finalChunkIndex: 2, finalOffset: 11)

        XCTAssertTrue(completed.isComplete)
        let output = try XCTUnwrap(completed.finalURL)
        XCTAssertEqual(try Data(contentsOf: output), Data("hello world".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".capture-1.blob.part").path))
    }

    func testPrototypeRejectsWrongOrderChecksumAndStreamingMetadata() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = BrowserBlobCapturePrototypeWriter(
            destinationDirectoryURL: directory,
            limits: BrowserBlobCaptureLimits(maximumBytes: 64, maximumChunkBytes: 8)
        )

        let streaming = BrowserBlobCaptureMetadata(
            captureID: "stream-1",
            sourceURL: URL(string: "blob:https://video.example/stream")!,
            expectedSize: nil,
            kind: .streamOrUnknown,
            readable: true
        )
        do {
            _ = try await writer.begin(metadata: streaming, filename: "stream.mp4")
            XCTFail("Expected stream classification to be rejected")
        } catch let error as BrowserBlobCapturePrototypeError {
            XCTAssertEqual(error, .incompleteOrStreamingResource)
        }

        let metadata = BrowserBlobCaptureMetadata(
            captureID: "capture-2",
            sourceURL: URL(string: "blob:https://video.example/2")!,
            expectedSize: 4,
            kind: .completeBlobCandidate,
            readable: true
        )
        _ = try await writer.begin(metadata: metadata, filename: "file.bin")
        let data = Data("data".utf8)
        do {
            _ = try await writer.append(captureID: "capture-2", chunkIndex: 1, offset: 0, data: data, sha256: EngineSHA256.hash(data: data))
            XCTFail("Expected out-of-order chunk to be rejected")
        } catch let error as BrowserBlobCapturePrototypeError {
            XCTAssertEqual(error, .invalidChunkIndex)
        }

        _ = try await writer.begin(
            metadata: BrowserBlobCaptureMetadata(
                captureID: "capture-3",
                sourceURL: URL(string: "blob:https://video.example/3")!,
                expectedSize: 4,
                kind: .completeBlobCandidate,
                readable: true
            ),
            filename: "bad.bin"
        )
        do {
            _ = try await writer.append(captureID: "capture-3", chunkIndex: 0, offset: 0, data: data, sha256: String(repeating: "0", count: 64))
            XCTFail("Expected checksum mismatch")
        } catch let error as BrowserBlobCapturePrototypeError {
            XCTAssertEqual(error, .checksumMismatch)
        }
    }

    func testPrototypeReceiverUsesSameMessageEnvelopeAndCleansUpCancellation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = BrowserBlobCapturePrototypeWriter(destinationDirectoryURL: directory)
        let receiver = BrowserBlobCapturePrototypeReceiver(writer: writer)
        let metadata: [String: Any] = [
            "kind": "metadata",
            "captureID": "capture-4",
            "url": "blob:https://video.example/4",
            "mimeType": "video/mp4",
            "size": 3,
            "readable": true,
            "resourceKind": "completeBlobCandidate"
        ]
        let begin = await receiver.receive(payload: metadata)
        XCTAssertTrue(begin.accepted)

        let cancel = await receiver.receive(payload: [
            "kind": "cancel",
            "captureID": "capture-4"
        ])
        XCTAssertTrue(cancel.accepted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".capture-4.blob.part").path))
    }

    func testPrototypeScriptUsesBoundedReaderAndAcknowledgements() {
        let script = BrowserBlobCapturePrototypeBridge.script
        XCTAssertTrue(script.contains("getReader"))
        XCTAssertTrue(script.contains("__lidBlobRegistry"))
        XCTAssertTrue(script.contains(".slice(session.offset"))
        XCTAssertTrue(script.contains("captureID"))
        XCTAssertTrue(script.contains("documentID"))
        XCTAssertTrue(script.contains("acknowledge"))
        XCTAssertTrue(script.contains("crypto.subtle.digest"))
        XCTAssertTrue(script.contains("MAX_CHUNK_BYTES"))
        XCTAssertFalse(script.contains("response.blob()"))
        XCTAssertFalse(script.contains("FileReader"))

        let command = BrowserBlobCapturePrototypeBridge.startCommand(
            blobURL: URL(string: "blob:https://video.example/1")!,
            captureID: "capture-1",
            chunkSize: 512 * 1024
        )
        XCTAssertTrue(command.contains("262144"))
        XCTAssertTrue(command.contains("blob:https://video.example/1"))
    }

    func testReceiverBindsCaptureToTheRegisteredBrowserDocument() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }

        let service = BrowserBlobCaptureService(destinationDirectoryURL: directory)
        await service.register(captureID: "capture-doc", documentID: "document-a")

        let rejected = await service.receive(payload: [
            "kind": "metadata",
            "captureID": "capture-doc",
            "documentID": "document-b",
            "url": "blob:https://video.example/doc",
            "mimeType": "video/mp4",
            "size": 0,
            "readable": true,
            "resourceKind": "completeBlobCandidate"
        ])

        XCTAssertFalse(rejected.accepted)
        XCTAssertEqual(rejected.error, .documentMismatch)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".capture-doc.blob.part").path))
    }

    func testExpectedSizeLimitAndIncompleteCaptureNeverPublishOutput() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }

        let writer = BrowserBlobCapturePrototypeWriter(
            destinationDirectoryURL: directory,
            limits: BrowserBlobCaptureLimits(maximumBytes: 8, maximumChunkBytes: 4)
        )
        _ = try await writer.begin(
            metadata: BrowserBlobCaptureMetadata(
                captureID: "limited",
                sourceURL: URL(string: "blob:https://video.example/limited")!,
                expectedSize: 5,
                kind: .completeBlobCandidate,
                readable: true
            ),
            filename: "../unsafe.mp4"
        )

        let part = Data("123".utf8)
        _ = try await writer.append(
            captureID: "limited",
            chunkIndex: 0,
            offset: 0,
            data: part,
            sha256: EngineSHA256.hash(data: part)
        )
        do {
            _ = try await writer.complete(captureID: "limited", finalChunkIndex: 1, finalOffset: 3)
            XCTFail("Expected incomplete capture")
        } catch let error as BrowserBlobCapturePrototypeError {
            XCTAssertEqual(error, .incompleteCapture)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".._unsafe.mp4").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".limited.blob.part").path))
    }

    func testConcurrentCapturesRemainOrderedAndIsolated() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = BrowserBlobCapturePrototypeWriter(
            destinationDirectoryURL: directory,
            limits: BrowserBlobCaptureLimits(maximumBytes: 32, maximumChunkBytes: 8)
        )
        for id in ["one", "two"] {
            _ = try await writer.begin(
                metadata: BrowserBlobCaptureMetadata(
                    captureID: id,
                    sourceURL: URL(string: "blob:https://video.example/\(id)")!,
                    expectedSize: 3,
                    kind: .completeBlobCandidate,
                    readable: true
                ),
                filename: "\(id).bin"
            )
        }

        let one = Data("one".utf8)
        let two = Data("two".utf8)
        _ = try await writer.append(captureID: "one", chunkIndex: 0, offset: 0, data: one, sha256: EngineSHA256.hash(data: one))
        _ = try await writer.append(captureID: "two", chunkIndex: 0, offset: 0, data: two, sha256: EngineSHA256.hash(data: two))
        let first = try await writer.complete(captureID: "one", finalChunkIndex: 1, finalOffset: 3)
        let second = try await writer.complete(captureID: "two", finalChunkIndex: 1, finalOffset: 3)

        let firstURL = try XCTUnwrap(first.finalURL)
        let secondURL = try XCTUnwrap(second.finalURL)
        XCTAssertEqual(try Data(contentsOf: firstURL), one)
        XCTAssertEqual(try Data(contentsOf: secondURL), two)
    }
}
