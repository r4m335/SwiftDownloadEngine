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
        XCTAssertTrue(script.contains("SourceBuffer error"))
        XCTAssertTrue(script.contains("MediaSource was detached"))
        XCTAssertTrue(script.contains("Document navigation interrupted MSE capture"))
        XCTAssertTrue(script.contains("sourceended"))
        XCTAssertTrue(script.contains("updateend"))
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

    func testLateStartCaptureReconstructsSuccessfullyFromRetainedInitAndMedia() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mse-capture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let writer = BrowserMSECapturePrototypeWriter(destinationDirectoryURL: directory)
        let captureID = "mse-late-start"
        _ = try await writer.begin(metadata: BrowserMSECaptureMetadata(
            captureID: captureID,
            mediaSourceURL: "blob:https://video.example/ms-late",
            mimeTypes: ["video/mp4; codecs=\"avc1.4d401f\""]
        ))

        let initBytes = isoBox("ftyp", payload: Data([0, 0, 0, 1])) + isoBox("moov", payload: Data([0, 0, 0, 2]))
        let mediaBytes1 = isoBox("moof", payload: Data([0, 0, 0, 3])) + isoBox("mdat", payload: Data([0, 0, 0, 4]))
        let mediaBytes2 = isoBox("moof", payload: Data([0, 0, 0, 5])) + isoBox("mdat", payload: Data([0, 0, 0, 6]))

        // Replay retained init segment (segment 0) enqueued during late-start handoff
        _ = try await writer.appendChunk(
            captureID: captureID,
            chunkIndex: 0,
            offset: 0,
            trackIndex: 0,
            segmentIndex: 0,
            data: initBytes,
            sha256: EngineSHA256.hash(data: initBytes),
            isSegmentEnd: true,
            timestampOffset: 0.0,
            appendTimestamp: 1000.0
        )

        // Replay retained media segment (segment 1)
        _ = try await writer.appendChunk(
            captureID: captureID,
            chunkIndex: 1,
            offset: Int64(initBytes.count),
            trackIndex: 0,
            segmentIndex: 1,
            data: mediaBytes1,
            sha256: EngineSHA256.hash(data: mediaBytes1),
            isSegmentEnd: true,
            timestampOffset: 0.0,
            appendTimestamp: 1001.0
        )

        // Live media segment (segment 2)
        _ = try await writer.appendChunk(
            captureID: captureID,
            chunkIndex: 2,
            offset: Int64(initBytes.count + mediaBytes1.count),
            trackIndex: 0,
            segmentIndex: 2,
            data: mediaBytes2,
            sha256: EngineSHA256.hash(data: mediaBytes2),
            isSegmentEnd: true,
            timestampOffset: 0.0,
            appendTimestamp: 1002.0
        )

        let completed = try await writer.complete(captureID: captureID)
        XCTAssertTrue(completed.isSuccessfullyReconstructed)
        let output = try XCTUnwrap(completed.reconstructedURL)
        XCTAssertEqual(try Data(contentsOf: output), initBytes + mediaBytes1 + mediaBytes2)
        XCTAssertEqual(completed.lifecycle, .completed)
        XCTAssertEqual(completed.appendSequence.count, 3)
        XCTAssertEqual(completed.appendSequence[0].timestampOffset, 0.0)
        XCTAssertEqual(completed.appendSequence[0].appendTimestamp, 1000.0)
        XCTAssertEqual(completed.appendSequence[1].timestampOffset, 0.0)
        XCTAssertEqual(completed.appendSequence[1].appendTimestamp, 1001.0)
        XCTAssertEqual(completed.appendSequence[2].timestampOffset, 0.0)
        XCTAssertEqual(completed.appendSequence[2].appendTimestamp, 1002.0)
    }

    func testInitializationDataRetainedIndependentlyPerSourceBuffer() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mse-capture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let writer = BrowserMSECapturePrototypeWriter(destinationDirectoryURL: directory)
        let captureID = "mse-dual-track"
        _ = try await writer.begin(metadata: BrowserMSECaptureMetadata(
            captureID: captureID,
            mediaSourceURL: "blob:https://video.example/ms-dual",
            mimeTypes: [
                "video/mp4; codecs=\"avc1.4d401f\"",
                "audio/mp4; codecs=\"mp4a.40.2\""
            ]
        ))

        let videoInit = isoBox("ftyp", payload: Data([1, 0, 0, 0])) + isoBox("moov", payload: Data([1, 0, 0, 1]))
        let audioInit = isoBox("ftyp", payload: Data([2, 0, 0, 0])) + isoBox("moov", payload: Data([2, 0, 0, 1]))
        let videoMedia = isoBox("moof", payload: Data([1, 0, 0, 2])) + isoBox("mdat", payload: Data([1, 0, 0, 3]))
        let audioMedia = isoBox("moof", payload: Data([2, 0, 0, 2])) + isoBox("mdat", payload: Data([2, 0, 0, 3]))

        // Track 0 (video) init
        _ = try await writer.appendChunk(
            captureID: captureID,
            chunkIndex: 0,
            offset: 0,
            trackIndex: 0,
            segmentIndex: 0,
            data: videoInit,
            sha256: EngineSHA256.hash(data: videoInit),
            isSegmentEnd: true,
            timestampOffset: 0.0,
            appendTimestamp: 10.0
        )

        // Track 1 (audio) init
        _ = try await writer.appendChunk(
            captureID: captureID,
            chunkIndex: 1,
            offset: Int64(videoInit.count),
            trackIndex: 1,
            segmentIndex: 0,
            data: audioInit,
            sha256: EngineSHA256.hash(data: audioInit),
            isSegmentEnd: true,
            timestampOffset: 0.0,
            appendTimestamp: 10.1
        )

        // Track 0 (video) media
        _ = try await writer.appendChunk(
            captureID: captureID,
            chunkIndex: 2,
            offset: Int64(videoInit.count + audioInit.count),
            trackIndex: 0,
            segmentIndex: 1,
            data: videoMedia,
            sha256: EngineSHA256.hash(data: videoMedia),
            isSegmentEnd: true,
            timestampOffset: 0.0,
            appendTimestamp: 10.2
        )

        // Track 1 (audio) media
        let snapshot = try await writer.appendChunk(
            captureID: captureID,
            chunkIndex: 3,
            offset: Int64(videoInit.count + audioInit.count + videoMedia.count),
            trackIndex: 1,
            segmentIndex: 1,
            data: audioMedia,
            sha256: EngineSHA256.hash(data: audioMedia),
            isSegmentEnd: true,
            timestampOffset: 0.0,
            appendTimestamp: 10.3
        )

        XCTAssertEqual(snapshot.bufferMetadata.count, 2)
        XCTAssertEqual(snapshot.bufferMetadata[0].kind, .video)
        XCTAssertEqual(snapshot.bufferMetadata[1].kind, .audio)
        XCTAssertEqual(snapshot.appendSequence.count, 4)
        XCTAssertEqual(snapshot.appendSequence.map(\.trackIndex), [0, 1, 0, 1])
    }

    func testMultipleInitializationSegmentsDetectedAndRejected() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mse-capture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let writer = BrowserMSECapturePrototypeWriter(destinationDirectoryURL: directory)
        let captureID = "mse-multi-init"
        _ = try await writer.begin(metadata: BrowserMSECaptureMetadata(
            captureID: captureID,
            mediaSourceURL: "blob:https://video.example/ms-multi",
            mimeTypes: ["video/mp4; codecs=\"avc1.4d401f\""]
        ))

        let init1 = isoBox("ftyp", payload: Data([1])) + isoBox("moov", payload: Data([1]))
        let init2 = isoBox("ftyp", payload: Data([2])) + isoBox("moov", payload: Data([2]))

        _ = try await writer.appendChunk(
            captureID: captureID,
            chunkIndex: 0,
            offset: 0,
            trackIndex: 0,
            segmentIndex: 0,
            data: init1,
            sha256: EngineSHA256.hash(data: init1),
            isSegmentEnd: true
        )

        do {
            _ = try await writer.appendChunk(
                captureID: captureID,
                chunkIndex: 1,
                offset: Int64(init1.count),
                trackIndex: 0,
                segmentIndex: 1,
                data: init2,
                sha256: EngineSHA256.hash(data: init2),
                isSegmentEnd: true
            )
            XCTFail("Expected unsupportedSession rejection on second initialization segment")
        } catch let error as BrowserMSECapturePrototypeError {
            XCTAssertEqual(error, .unsupportedSession)
        }

        // Staging directory should be cleaned up after error abort
        let staging = directory.appendingPathComponent("MSECaptures/\(captureID)", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    func testAudioVideoAppendOrderingPreservedInAppendSequence() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mse-capture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let writer = BrowserMSECapturePrototypeWriter(destinationDirectoryURL: directory)
        let captureID = "mse-order"
        _ = try await writer.begin(metadata: BrowserMSECaptureMetadata(
            captureID: captureID,
            mediaSourceURL: "blob:https://video.example/ms-order",
            mimeTypes: ["video/mp4", "audio/mp4"]
        ))

        let vInit = isoBox("ftyp", payload: Data([1])) + isoBox("moov", payload: Data([1]))
        let aInit = isoBox("ftyp", payload: Data([2])) + isoBox("moov", payload: Data([2]))

        _ = try await writer.appendChunk(
            captureID: captureID,
            chunkIndex: 0,
            offset: 0,
            trackIndex: 0,
            segmentIndex: 0,
            data: vInit,
            sha256: EngineSHA256.hash(data: vInit),
            isSegmentEnd: true,
            timestampOffset: 0.25,
            appendTimestamp: 42.1
        )
        let snap2 = try await writer.appendChunk(
            captureID: captureID,
            chunkIndex: 1,
            offset: Int64(vInit.count),
            trackIndex: 1,
            segmentIndex: 0,
            data: aInit,
            sha256: EngineSHA256.hash(data: aInit),
            isSegmentEnd: true,
            timestampOffset: 0.25,
            appendTimestamp: 42.2
        )

        XCTAssertEqual(snap2.appendSequence.count, 2)
        XCTAssertEqual(snap2.appendSequence[0], BrowserMSECaptureAppendEvent(
            chunkIndex: 0,
            trackIndex: 0,
            segmentIndex: 0,
            byteCount: Int64(vInit.count),
            timestampOffset: 0.25,
            appendTimestamp: 42.1
        ))
        XCTAssertEqual(snap2.appendSequence[1], BrowserMSECaptureAppendEvent(
            chunkIndex: 1,
            trackIndex: 1,
            segmentIndex: 0,
            byteCount: Int64(aInit.count),
            timestampOffset: 0.25,
            appendTimestamp: 42.2
        ))
    }

    func testMissingInitializationDataPreventsPublication() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mse-capture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let writer = BrowserMSECapturePrototypeWriter(destinationDirectoryURL: directory)
        let captureID = "mse-no-init"
        _ = try await writer.begin(metadata: BrowserMSECaptureMetadata(
            captureID: captureID,
            mediaSourceURL: "blob:https://video.example/ms-no-init",
            mimeTypes: ["video/mp4; codecs=\"avc1.4d401f\""]
        ))

        // Only append media segment without an initialization segment
        let mediaBytes = isoBox("moof", payload: Data([1])) + isoBox("mdat", payload: Data([2]))
        _ = try await writer.appendChunk(
            captureID: captureID,
            chunkIndex: 0,
            offset: 0,
            trackIndex: 0,
            segmentIndex: 0,
            data: mediaBytes,
            sha256: EngineSHA256.hash(data: mediaBytes),
            isSegmentEnd: true
        )

        do {
            _ = try await writer.complete(captureID: captureID)
            XCTFail("Expected missingInitializationSegment rejection")
        } catch let error as BrowserMSECapturePrototypeError {
            XCTAssertEqual(error, .missingInitializationSegment)
        }

        // Staging directory must be cleaned up and no output published
        let staging = directory.appendingPathComponent("MSECaptures/\(captureID)", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        let published = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
            .filter { $0.hasSuffix(".mp4") } ?? []
        XCTAssertTrue(published.isEmpty)
    }

    func testMemoryLimitsAndBridgePreCaptureLifecycleInScript() {
        let script = BrowserMSECapturePrototypeBridge.script
        XCTAssertTrue(script.contains("maxMediaBytesPerTrack: 10 * 1024 * 1024"))
        XCTAssertTrue(script.contains("maxTotalMediaBytes: 20 * 1024 * 1024"))
        XCTAssertTrue(script.contains("isInitializationSegment"))
        XCTAssertTrue(script.contains("getPreCaptureState"))
        XCTAssertTrue(script.contains("setPreCaptureLimits"))
        XCTAssertTrue(script.contains("URL.revokeObjectURL"))
        XCTAssertTrue(script.contains("sourceclose"))
        XCTAssertTrue(script.contains("removeSourceBuffer"))
        XCTAssertTrue(script.contains("pagehide"))
        XCTAssertTrue(script.contains("beforeunload"))
    }

    func testReceiverRejectsMultipleInitSegmentsInStream() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mse-capture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let writer = BrowserMSECapturePrototypeWriter(destinationDirectoryURL: directory)
        let receiver = BrowserMSECapturePrototypeReceiver(writer: writer)
        let captureID = "mse-rx-multi-init"
        await receiver.register(captureID: captureID, documentID: "doc-1")

        let metaAck = await receiver.receive(payload: [
            "type": "metadata",
            "captureID": captureID,
            "documentID": "doc-1",
            "mediaSourceURL": "blob:https://video.example/ms",
            "mimeTypes": ["video/mp4; codecs=\"avc1.4d401f\""]
        ])
        XCTAssertTrue(metaAck.accepted)

        let init1 = isoBox("ftyp", payload: Data([1])) + isoBox("moov", payload: Data([1]))
        let chunk1Ack = await receiver.receive(payload: [
            "type": "chunk",
            "captureID": captureID,
            "documentID": "doc-1",
            "chunkIndex": 0,
            "offset": 0,
            "trackIndex": 0,
            "segmentIndex": 0,
            "base64": init1.base64EncodedString(),
            "sha256": EngineSHA256.hash(data: init1),
            "isSegmentEnd": true
        ])
        XCTAssertTrue(chunk1Ack.accepted)

        let init2 = isoBox("ftyp", payload: Data([2])) + isoBox("moov", payload: Data([2]))
        let chunk2Ack = await receiver.receive(payload: [
            "type": "chunk",
            "captureID": captureID,
            "documentID": "doc-1",
            "chunkIndex": 1,
            "offset": Int64(init1.count),
            "trackIndex": 0,
            "segmentIndex": 1,
            "base64": init2.base64EncodedString(),
            "sha256": EngineSHA256.hash(data: init2),
            "isSegmentEnd": true
        ])
        XCTAssertFalse(chunk2Ack.accepted)
        XCTAssertEqual(chunk2Ack.error, .unsupportedSession)
    }

    func testReceiverLifecycleCancellationAbortsSession() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mse-capture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let writer = BrowserMSECapturePrototypeWriter(destinationDirectoryURL: directory)
        let receiver = BrowserMSECapturePrototypeReceiver(writer: writer)
        let captureID = "mse-rx-cancel"
        await receiver.register(captureID: captureID, documentID: "doc-1")

        let metaAck = await receiver.receive(payload: [
            "type": "metadata",
            "captureID": captureID,
            "documentID": "doc-1",
            "mediaSourceURL": "blob:https://video.example/ms",
            "mimeTypes": ["video/mp4; codecs=\"avc1.4d401f\""]
        ])
        XCTAssertTrue(metaAck.accepted)

        let cancelAck = await receiver.receive(payload: [
            "type": "cancel",
            "captureID": captureID,
            "documentID": "doc-1",
            "reason": "MediaSource was detached"
        ])
        XCTAssertTrue(cancelAck.accepted)

        // Subsequent chunk should be rejected as unauthorized
        let initBytes = isoBox("ftyp", payload: Data([1])) + isoBox("moov", payload: Data([1]))
        let lateChunkAck = await receiver.receive(payload: [
            "type": "chunk",
            "captureID": captureID,
            "documentID": "doc-1",
            "chunkIndex": 0,
            "offset": 0,
            "trackIndex": 0,
            "segmentIndex": 0,
            "base64": initBytes.base64EncodedString(),
            "sha256": EngineSHA256.hash(data: initBytes),
            "isSegmentEnd": true
        ])
        XCTAssertFalse(lateChunkAck.accepted)
        XCTAssertEqual(lateChunkAck.error, .captureNotAuthorized)
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
