import Foundation
import XCTest
@testable import DM_Reverse_engineering

final class BrowserMSECapturePrototypeTests: XCTestCase {
    func testSupportClassifierAcceptsClearFMP4AndRejectsWebMAndDRM() {
        let single = BrowserMSECaptureSupportClassifier.evaluate(
            mimeTypes: ["video/mp4; codecs=\"avc1.4d401f\""]
        )
        XCTAssertEqual(single.status, .capturable)
        XCTAssertEqual(single.container, .fragmentedMP4)

        let dual = BrowserMSECaptureSupportClassifier.evaluate(
            mimeTypes: [
                "video/mp4; codecs=\"avc1.4d401f\"",
                "audio/mp4; codecs=\"mp4a.40.2\""
            ]
        )
        XCTAssertEqual(dual.status, .capturable)

        let webm = BrowserMSECaptureSupportClassifier.evaluate(mimeTypes: ["video/webm; codecs=\"vp9\""])
        XCTAssertEqual(webm.status, .unsupported)

        let protected = BrowserMSECaptureSupportClassifier.evaluate(
            mimeTypes: ["video/mp4"],
            isPotentiallyProtected: true
        )
        XCTAssertEqual(protected.status, .protectedMedia)
    }

    func testOrderedFMP4SegmentsReconstructOnlyAfterValidation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mse-capture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let writer = BrowserMSECapturePrototypeWriter(
            destinationDirectoryURL: directory,
            limits: BrowserMSECaptureLimits(maximumBytes: 1024, maximumChunkBytes: 64)
        )
        let metadata = BrowserMSECaptureMetadata(
            captureID: "mse-1",
            mediaSourceURL: "blob:https://video.example/ms-1",
            mimeTypes: ["video/mp4; codecs=\"avc1.4d401f\""]
        )
        _ = try await writer.begin(metadata: metadata)

        let initBytes = isoBox("ftyp", payload: Data([0, 0, 0, 1])) + isoBox("moov", payload: Data([0, 0, 0, 2]))
        let mediaBytes = isoBox("moof", payload: Data([0, 0, 0, 3])) + isoBox("mdat", payload: Data([0, 0, 0, 4]))

        _ = try await writer.appendChunk(
            captureID: "mse-1",
            chunkIndex: 0,
            offset: 0,
            trackIndex: 0,
            segmentIndex: 0,
            data: initBytes,
            sha256: EngineSHA256.hash(data: initBytes),
            isSegmentEnd: true
        )
        _ = try await writer.appendChunk(
            captureID: "mse-1",
            chunkIndex: 1,
            offset: Int64(initBytes.count),
            trackIndex: 0,
            segmentIndex: 1,
            data: mediaBytes,
            sha256: EngineSHA256.hash(data: mediaBytes),
            isSegmentEnd: true
        )

        let completed = try await writer.complete(captureID: "mse-1")
        XCTAssertTrue(completed.isSuccessfullyReconstructed)
        let output = try XCTUnwrap(completed.reconstructedURL)
        XCTAssertEqual(try Data(contentsOf: output), initBytes + mediaBytes)
        XCTAssertEqual(completed.lifecycle, .completed)
        XCTAssertEqual(completed.bufferMetadata, [
            BrowserMSECaptureBufferMetadata(
                trackIndex: 0,
                mimeType: "video/mp4; codecs=\"avc1.4d401f\"",
                codecs: ["avc1.4d401f"],
                kind: .video
            )
        ])
        XCTAssertEqual(completed.appendSequence, [
            BrowserMSECaptureAppendEvent(chunkIndex: 0, trackIndex: 0, segmentIndex: 0, byteCount: Int64(initBytes.count)),
            BrowserMSECaptureAppendEvent(chunkIndex: 1, trackIndex: 0, segmentIndex: 1, byteCount: Int64(mediaBytes.count))
        ])
    }

    func testProtectedAndUnsupportedSessionsNeverOpenWriters() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mse-capture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = BrowserMSECapturePrototypeWriter(destinationDirectoryURL: directory)

        do {
            _ = try await writer.begin(metadata: BrowserMSECaptureMetadata(
                captureID: "mse-drm",
                mediaSourceURL: "blob:https://video.example/ms-drm",
                mimeTypes: ["video/mp4"],
                isPotentiallyProtected: true
            ))
            XCTFail("Expected protected media rejection")
        } catch let error as BrowserMSECapturePrototypeError {
            XCTAssertEqual(error, .protectedMedia)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        do {
            _ = try await writer.begin(metadata: BrowserMSECaptureMetadata(
                captureID: "mse-webm",
                mediaSourceURL: "blob:https://video.example/ms-webm",
                mimeTypes: ["video/webm"]
            ))
            XCTFail("Expected unsupported rejection")
        } catch let error as BrowserMSECapturePrototypeError {
            XCTAssertEqual(error, .unsupportedSession)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCancelRemovesPartialCaptureWithoutPublishingOutput() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mse-capture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = BrowserMSECapturePrototypeWriter(destinationDirectoryURL: directory)
        _ = try await writer.begin(metadata: BrowserMSECaptureMetadata(
            captureID: "mse-cancel",
            mediaSourceURL: "blob:https://video.example/ms-cancel",
            mimeTypes: ["video/mp4"]
        ))
        let initBytes = isoBox("ftyp", payload: Data([1])) + isoBox("moov", payload: Data([2]))
        _ = try await writer.appendChunk(
            captureID: "mse-cancel",
            chunkIndex: 0,
            offset: 0,
            trackIndex: 0,
            segmentIndex: 0,
            data: initBytes,
            sha256: EngineSHA256.hash(data: initBytes),
            isSegmentEnd: true
        )
        await writer.cancel(captureID: "mse-cancel")

        let staging = directory.appendingPathComponent("MSECaptures/mse-cancel", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        let published = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
            .filter { $0.hasSuffix(".mp4") || $0.hasSuffix(".ts") } ?? []
        XCTAssertTrue(published.isEmpty)
    }

    func testReceiverRejectsDocumentMismatchAndDecodesKindAlias() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mse-capture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = BrowserMSECapturePrototypeWriter(destinationDirectoryURL: directory)
        let receiver = BrowserMSECapturePrototypeReceiver(writer: writer)
        await receiver.register(captureID: "mse-doc", documentID: "document-a")

        let mismatched: [String: Any] = [
            "kind": "metadata",
            "captureID": "mse-doc",
            "documentID": "document-b",
            "mediaSourceURL": "blob:https://video.example/ms",
            "mimeTypes": ["video/mp4"]
        ]
        let mismatchAck = await receiver.receive(payload: mismatched)
        XCTAssertFalse(mismatchAck.accepted)
        XCTAssertEqual(mismatchAck.error, .documentMismatch)

        let payload: [String: Any] = [
            "type": "metadata",
            "captureID": "mse-alias",
            "documentID": "document-a",
            "mediaSourceURL": "blob:https://video.example/ms-2",
            "mimeTypes": ["video/webm"]
        ]
        await receiver.register(captureID: "mse-alias", documentID: "document-a")
        let unsupported = await receiver.receive(payload: payload)
        XCTAssertFalse(unsupported.accepted)
        XCTAssertEqual(unsupported.error, .unsupportedSession)
    }

    func testReceiverRejectsUnregisteredAndLateMessages() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mse-capture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = BrowserMSECapturePrototypeWriter(destinationDirectoryURL: directory)
        let receiver = BrowserMSECapturePrototypeReceiver(writer: writer)
        let metadata: [String: Any] = [
            "kind": "metadata",
            "captureID": "mse-unauthorized",
            "mediaSourceURL": "blob:https://video.example/ms",
            "mimeTypes": ["video/mp4"]
        ]

        let unregistered = await receiver.receive(payload: metadata)
        XCTAssertFalse(unregistered.accepted)
        XCTAssertEqual(unregistered.error, .captureNotAuthorized)

        await receiver.register(captureID: "mse-unauthorized", documentID: nil)
        let started = await receiver.receive(payload: metadata)
        XCTAssertTrue(started.accepted)
        await receiver.cancel(captureID: "mse-unauthorized")

        let late = await receiver.receive(payload: metadata)
        XCTAssertFalse(late.accepted)
        XCTAssertEqual(late.error, .captureNotAuthorized)
    }

    func testBridgeScriptCopiesBytesOnlyWhileCaptureIsActive() {
        let script = BrowserMSECapturePrototypeBridge.script
        XCTAssertTrue(script.contains("browserMSECapture"))
        XCTAssertTrue(script.contains("appendBuffer"))
        XCTAssertTrue(script.contains("activeCaptureForMediaSourceURL"))
        XCTAssertTrue(script.contains("protectionObserved"))
        XCTAssertFalse(script.contains("document.cookie"))
        XCTAssertTrue(script.contains("__lidMSECapture"))
    }

    func testInitOnlyCaptureDoesNotPublishAPlayableFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mse-capture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = BrowserMSECapturePrototypeWriter(destinationDirectoryURL: directory)
        _ = try await writer.begin(metadata: BrowserMSECaptureMetadata(
            captureID: "mse-init-only",
            mediaSourceURL: "blob:https://video.example/ms-init",
            mimeTypes: ["video/mp4"]
        ))
        let initBytes = isoBox("ftyp", payload: Data([1])) + isoBox("moov", payload: Data([2]))
        _ = try await writer.appendChunk(
            captureID: "mse-init-only",
            chunkIndex: 0,
            offset: 0,
            trackIndex: 0,
            segmentIndex: 0,
            data: initBytes,
            sha256: EngineSHA256.hash(data: initBytes),
            isSegmentEnd: true
        )
        do {
            _ = try await writer.complete(captureID: "mse-init-only")
            XCTFail("Expected incomplete capture rejection")
        } catch let error as BrowserMSECapturePrototypeError {
            XCTAssertTrue(
                error == .incompleteCapture ||
                error == .missingInitializationSegment ||
                error == .reconstructionFailed
            )
        }
        let published = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
            .filter { $0.hasSuffix(".mp4") } ?? []
        XCTAssertTrue(published.isEmpty)
    }

    private func isoBox(_ type: String, payload: Data) -> Data {
        let typeBytes = Array(type.utf8)
        precondition(typeBytes.count == 4)
        let size = UInt32(8 + payload.count)
        var data = Data([
            UInt8((size >> 24) & 0xff),
            UInt8((size >> 16) & 0xff),
            UInt8((size >> 8) & 0xff),
            UInt8(size & 0xff)
        ])
        data.append(contentsOf: typeBytes)
        data.append(payload)
        return data
    }
}
