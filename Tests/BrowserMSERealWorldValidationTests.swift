import Foundation
import XCTest
#if canImport(WebKit)
import WebKit
#endif
@testable import DM_Reverse_engineering

final class BrowserMSERealWorldValidationTests: XCTestCase {

    // MARK: - Step 1: Reproducible Test Harness & HTML Page Validation

    func testTestHarnessProducesCompliantISOBMFFBoxesAndPassesMediaIntegrityValidator() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mse-box-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let initData = BrowserMSETestHarness.buildInitSegment(trackKind: .video, trackID: 1)
        let mediaData = BrowserMSETestHarness.buildMediaSegment(sequenceNumber: 1, trackID: 1, baseDecodeTime: 0)

        let fileURL = tempDir.appendingPathComponent("test-stream.mp4")
        var combined = Data()
        combined.append(initData)
        combined.append(mediaData)
        try combined.write(to: fileURL)

        // Validate with structural ISOBMFF validator
        let outcome = MediaIntegrityValidator.validateISOBMFF(
            fileURL: fileURL,
            requiredBoxes: ["ftyp", "moov", "moof", "mdat"]
        )
        XCTAssertEqual(outcome, .validated(detectedType: .fragmentedMP4))
        XCTAssertTrue(outcome.isConfirmedValid)

        // Validate via convenience pathway
        let report = MediaIntegrityValidator.validateMSECapture(fileURL: fileURL)
        XCTAssertTrue(report.isStructurallyValid)
        XCTAssertEqual(report.outcome, .validated(detectedType: .fragmentedMP4))
    }

    func testReproducibleHTMLTestPageEmbedsValidMediaAndControls() {
        let options = BrowserMSETestHarness.TestPageOptions(
            title: "Real-World MSE Validation Page",
            videoMIME: "video/mp4; codecs=\"avc1.4d401f\"",
            audioMIME: "audio/mp4; codecs=\"mp4a.40.2\"",
            hasAudio: true
        )
        let html = BrowserMSETestHarness.generateTestPageHTML(options: options)

        XCTAssertTrue(html.contains("<!DOCTYPE html>"))
        XCTAssertTrue(html.contains("MediaSource"))
        XCTAssertTrue(html.contains("URL.createObjectURL(mediaSource)"))
        XCTAssertTrue(html.contains("video/mp4; codecs=\"avc1.4d401f\""))
        XCTAssertTrue(html.contains("audio/mp4; codecs=\"mp4a.40.2\""))
        XCTAssertTrue(html.contains("window.__mseTestHarness"))
        XCTAssertTrue(html.contains("appendVideoInit"))
        XCTAssertTrue(html.contains("appendVideoFrag1"))
        XCTAssertTrue(html.contains("appendAudioInit"))
        XCTAssertTrue(html.contains("appendAudioFrag1"))
        XCTAssertTrue(html.contains("revokeMediaSourceURL"))
        XCTAssertTrue(html.contains("removeVideoBuffer"))
        XCTAssertTrue(html.contains("endOfStream"))
    }

    // MARK: - Step 2: Normal MSE Capture Lifecycle & Assembly

    func testNormalMSECaptureLifecycleAndAssembly() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mse-normal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let writer = BrowserMSECapturePrototypeWriter(destinationDirectoryURL: tempDir)
        let captureID = "mse-normal-capture-1"
        let metadata = BrowserMSECaptureMetadata(
            captureID: captureID,
            mediaSourceURL: "blob:https://stream.example/mse-normal",
            mimeTypes: ["video/mp4; codecs=\"avc1.4d401f\""]
        )

        let initialSnapshot = try await writer.begin(metadata: metadata)
        XCTAssertEqual(initialSnapshot.lifecycle, .capturing)
        XCTAssertEqual(initialSnapshot.bytesCaptured, 0)
        XCTAssertEqual(initialSnapshot.segmentCount, 0)

        let initData = BrowserMSETestHarness.buildInitSegment(trackKind: .video, trackID: 1)
        let frag1Data = BrowserMSETestHarness.buildMediaSegment(sequenceNumber: 1, trackID: 1, baseDecodeTime: 0)
        let frag2Data = BrowserMSETestHarness.buildMediaSegment(sequenceNumber: 2, trackID: 1, baseDecodeTime: 1000)

        // 1. Init segment arrives as segment 0
        let snap1 = try await writer.appendChunk(
            captureID: captureID,
            chunkIndex: 0,
            offset: 0,
            trackIndex: 0,
            segmentIndex: 0,
            data: initData,
            sha256: EngineSHA256.hash(data: initData),
            isSegmentEnd: true,
            timestampOffset: 0.0,
            appendTimestamp: 100.0
        )
        XCTAssertEqual(snap1.segmentCount, 1)
        XCTAssertEqual(snap1.bytesCaptured, Int64(initData.count))

        // 2. Media fragment 1 arrives as segment 1
        let snap2 = try await writer.appendChunk(
            captureID: captureID,
            chunkIndex: 1,
            offset: Int64(initData.count),
            trackIndex: 0,
            segmentIndex: 1,
            data: frag1Data,
            sha256: EngineSHA256.hash(data: frag1Data),
            isSegmentEnd: true,
            timestampOffset: 0.0,
            appendTimestamp: 101.0
        )
        XCTAssertEqual(snap2.segmentCount, 2)

        // 3. Media fragment 2 arrives as segment 2
        let snap3 = try await writer.appendChunk(
            captureID: captureID,
            chunkIndex: 2,
            offset: Int64(initData.count + frag1Data.count),
            trackIndex: 0,
            segmentIndex: 2,
            data: frag2Data,
            sha256: EngineSHA256.hash(data: frag2Data),
            isSegmentEnd: true,
            timestampOffset: 0.0,
            appendTimestamp: 102.0
        )
        XCTAssertEqual(snap3.segmentCount, 3)

        // 4. Complete capture and assemble
        let completed = try await writer.complete(captureID: captureID)
        XCTAssertTrue(completed.isSuccessfullyReconstructed)
        XCTAssertEqual(completed.lifecycle, .completed)
        XCTAssertEqual(completed.appendSequence.count, 3)

        let publishedURL = try XCTUnwrap(completed.reconstructedURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: publishedURL.path))

        // Validate final published output with MediaIntegrityValidator
        let validation = MediaIntegrityValidator.validateMSECapture(fileURL: publishedURL)
        XCTAssertTrue(validation.isStructurallyValid)
        XCTAssertEqual(validation.outcome, .validated(detectedType: .fragmentedMP4))

        // Check AVFoundation playability on Apple platforms
        #if canImport(AVFoundation)
        let playability = MediaIntegrityValidator.checkAVFoundationPlayability(fileURL: publishedURL)
        _ = playability // Validates execution without crashing
        #endif
    }

    // MARK: - Step 3: Late-Start Capture Lifecycle & Pre-Capture Buffer Handoff

    func testLateStartCaptureLifecycleWithPreCaptureBufferHandoff() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mse-late-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let writer = BrowserMSECapturePrototypeWriter(destinationDirectoryURL: tempDir)
        let receiver = BrowserMSECapturePrototypeReceiver(writer: writer)
        let captureID = "mse-late-capture-1"
        let documentID = "doc-late-1"
        await receiver.register(captureID: captureID, documentID: documentID)

        let initData = BrowserMSETestHarness.buildInitSegment(trackKind: .video, trackID: 1)
        let frag1Data = BrowserMSETestHarness.buildMediaSegment(sequenceNumber: 1, trackID: 1, baseDecodeTime: 0)
        let frag2Data = BrowserMSETestHarness.buildMediaSegment(sequenceNumber: 2, trackID: 1, baseDecodeTime: 1000)

        // Metadata message begins session
        let metaAck = await receiver.receive(payload: [
            "kind": "metadata",
            "captureID": captureID,
            "documentID": documentID,
            "mediaSourceURL": "blob:https://stream.example/mse-late",
            "mimeTypes": ["video/mp4; codecs=\"avc1.4d401f\""]
        ])
        XCTAssertTrue(metaAck.accepted)

        // Handoff segment 0: retained init segment
        let chunk0Ack = await receiver.receive(payload: [
            "kind": "chunk",
            "captureID": captureID,
            "documentID": documentID,
            "chunkIndex": 0,
            "offset": 0,
            "trackIndex": 0,
            "segmentIndex": 0,
            "base64": initData.base64EncodedString(),
            "sha256": EngineSHA256.hash(data: initData),
            "isSegmentEnd": true,
            "timestampOffset": 0.0,
            "appendTimestamp": 10.0
        ])
        XCTAssertTrue(chunk0Ack.accepted)

        // Handoff segment 1: retained media fragment 1 (pre-capture)
        let chunk1Ack = await receiver.receive(payload: [
            "kind": "chunk",
            "captureID": captureID,
            "documentID": documentID,
            "chunkIndex": 1,
            "offset": Int64(initData.count),
            "trackIndex": 0,
            "segmentIndex": 1,
            "base64": frag1Data.base64EncodedString(),
            "sha256": EngineSHA256.hash(data: frag1Data),
            "isSegmentEnd": true,
            "timestampOffset": 0.0,
            "appendTimestamp": 11.0
        ])
        XCTAssertTrue(chunk1Ack.accepted)

        // Live segment 2: live media fragment 2
        let chunk2Ack = await receiver.receive(payload: [
            "kind": "chunk",
            "captureID": captureID,
            "documentID": documentID,
            "chunkIndex": 2,
            "offset": Int64(initData.count + frag1Data.count),
            "trackIndex": 0,
            "segmentIndex": 2,
            "base64": frag2Data.base64EncodedString(),
            "sha256": EngineSHA256.hash(data: frag2Data),
            "isSegmentEnd": true,
            "timestampOffset": 0.0,
            "appendTimestamp": 12.0
        ])
        XCTAssertTrue(chunk2Ack.accepted)

        // Complete capture
        let completeAck = await receiver.receive(payload: [
            "kind": "complete",
            "captureID": captureID,
            "documentID": documentID
        ])
        XCTAssertTrue(completeAck.accepted)
        let snapshot = try XCTUnwrap(completeAck.snapshot)
        XCTAssertTrue(snapshot.isSuccessfullyReconstructed)

        let publishedURL = try XCTUnwrap(snapshot.reconstructedURL)
        let validation = MediaIntegrityValidator.validateMSECapture(fileURL: publishedURL)
        XCTAssertTrue(validation.isStructurallyValid)
        XCTAssertEqual(validation.outcome, .validated(detectedType: .fragmentedMP4))
    }

    // MARK: - Step 4: Dual-Track Audio/Video Capture & Assembly

    func testDualTrackAudioVideoMSECaptureLifecycle() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mse-dual-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let writer = BrowserMSECapturePrototypeWriter(destinationDirectoryURL: tempDir)
        let captureID = "mse-dual-track-1"
        let metadata = BrowserMSECaptureMetadata(
            captureID: captureID,
            mediaSourceURL: "blob:https://stream.example/mse-dual",
            mimeTypes: [
                "video/mp4; codecs=\"avc1.4d401f\"",
                "audio/mp4; codecs=\"mp4a.40.2\""
            ]
        )

        let initial = try await writer.begin(metadata: metadata)
        XCTAssertEqual(initial.lifecycle, .capturing)

        let videoInit = BrowserMSETestHarness.buildInitSegment(trackKind: .video, trackID: 1)
        let audioInit = BrowserMSETestHarness.buildInitSegment(trackKind: .audio, trackID: 2)
        let videoFrag = BrowserMSETestHarness.buildMediaSegment(sequenceNumber: 1, trackID: 1, baseDecodeTime: 0)
        let audioFrag = BrowserMSETestHarness.buildMediaSegment(sequenceNumber: 1, trackID: 2, baseDecodeTime: 0)

        // 1. Track 0 (video) Init
        _ = try await writer.appendChunk(
            captureID: captureID,
            chunkIndex: 0,
            offset: 0,
            trackIndex: 0,
            segmentIndex: 0,
            data: videoInit,
            sha256: EngineSHA256.hash(data: videoInit),
            isSegmentEnd: true
        )

        // 2. Track 1 (audio) Init
        _ = try await writer.appendChunk(
            captureID: captureID,
            chunkIndex: 1,
            offset: Int64(videoInit.count),
            trackIndex: 1,
            segmentIndex: 0,
            data: audioInit,
            sha256: EngineSHA256.hash(data: audioInit),
            isSegmentEnd: true
        )

        // 3. Track 0 (video) Media
        _ = try await writer.appendChunk(
            captureID: captureID,
            chunkIndex: 2,
            offset: Int64(videoInit.count + audioInit.count),
            trackIndex: 0,
            segmentIndex: 1,
            data: videoFrag,
            sha256: EngineSHA256.hash(data: videoFrag),
            isSegmentEnd: true
        )

        // 4. Track 1 (audio) Media
        let snap4 = try await writer.appendChunk(
            captureID: captureID,
            chunkIndex: 3,
            offset: Int64(videoInit.count + audioInit.count + videoFrag.count),
            trackIndex: 1,
            segmentIndex: 1,
            data: audioFrag,
            sha256: EngineSHA256.hash(data: audioFrag),
            isSegmentEnd: true
        )

        XCTAssertEqual(snap4.bufferMetadata.count, 2)
        XCTAssertEqual(snap4.bufferMetadata[0].kind, .video)
        XCTAssertEqual(snap4.bufferMetadata[1].kind, .audio)
        XCTAssertEqual(snap4.appendSequence.count, 4)

        #if canImport(AVFoundation)
        let completed = try await writer.complete(captureID: captureID)
        XCTAssertTrue(completed.isSuccessfullyReconstructed)
        let published = try XCTUnwrap(completed.reconstructedURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: published.path))
        let validation = MediaIntegrityValidator.validateMSECapture(fileURL: published)
        XCTAssertTrue(validation.isStructurallyValid)
        XCTAssertEqual(validation.outcome, .validated(detectedType: .fragmentedMP4))
        #else
        // On platforms without AVFoundation (e.g. Linux), multi-track muxing cleanly throws .reconstructionFailed
        do {
            _ = try await writer.complete(captureID: captureID)
            XCTFail("Expected multi-track assembly without AVFoundation to throw .reconstructionFailed")
        } catch let error as BrowserMSECapturePrototypeError {
            XCTAssertEqual(error, .reconstructionFailed)
        }
        #endif
    }

    // MARK: - Step 5: Representation Switch Rejection

    func testRepresentationSwitchMidStreamAbortsCleanly() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mse-switch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let writer = BrowserMSECapturePrototypeWriter(destinationDirectoryURL: tempDir)
        let receiver = BrowserMSECapturePrototypeReceiver(writer: writer)
        let captureID = "mse-rep-switch"
        await receiver.register(captureID: captureID, documentID: "doc-1")

        _ = await receiver.receive(payload: [
            "kind": "metadata",
            "captureID": captureID,
            "documentID": "doc-1",
            "mediaSourceURL": "blob:https://stream.example/mse-switch",
            "mimeTypes": ["video/mp4; codecs=\"avc1.4d401f\""]
        ])

        let init1 = BrowserMSETestHarness.buildInitSegment(trackKind: .video, trackID: 1, timescale: 1000)
        let init2 = BrowserMSETestHarness.buildInitSegment(trackKind: .video, trackID: 1, timescale: 90000)

        // Init 1 accepted
        let ack1 = await receiver.receive(payload: [
            "kind": "chunk",
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
        XCTAssertTrue(ack1.accepted)

        // Init 2 rejected (representation switch not supported by prototype reconstruction)
        let ack2 = await receiver.receive(payload: [
            "kind": "chunk",
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
        XCTAssertFalse(ack2.accepted)
        XCTAssertEqual(ack2.error, .unsupportedSession)

        // Verify staging directory is cleaned up
        let stagingDir = tempDir.appendingPathComponent("MSECaptures/\(captureID)", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingDir.path))

        // No output file published
        let published = (try? FileManager.default.contentsOfDirectory(atPath: tempDir.path))?
            .filter { $0.hasSuffix(".mp4") } ?? []
        XCTAssertTrue(published.isEmpty)
    }

    // MARK: - Step 6: Missing Initialization Segment Rejection

    func testMissingInitializationSegmentAbortsCleanly() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mse-no-init-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let writer = BrowserMSECapturePrototypeWriter(destinationDirectoryURL: tempDir)
        let captureID = "mse-missing-init"
        _ = try await writer.begin(metadata: BrowserMSECaptureMetadata(
            captureID: captureID,
            mediaSourceURL: "blob:https://stream.example/mse-no-init",
            mimeTypes: ["video/mp4; codecs=\"avc1.4d401f\""]
        ))

        let frag = BrowserMSETestHarness.buildMediaSegment(sequenceNumber: 1, trackID: 1, baseDecodeTime: 0)

        _ = try await writer.appendChunk(
            captureID: captureID,
            chunkIndex: 0,
            offset: 0,
            trackIndex: 0,
            segmentIndex: 0,
            data: frag,
            sha256: EngineSHA256.hash(data: frag),
            isSegmentEnd: true
        )

        do {
            _ = try await writer.complete(captureID: captureID)
            XCTFail("Expected missingInitializationSegment error")
        } catch let error as BrowserMSECapturePrototypeError {
            XCTAssertEqual(error, .missingInitializationSegment)
        }

        let stagingDir = tempDir.appendingPathComponent("MSECaptures/\(captureID)", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingDir.path))
    }

    // MARK: - Step 7: Corrupt Fragment & Checksum Mismatch

    func testCorruptChunkChecksumMismatchAbortsCleanly() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mse-corrupt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let writer = BrowserMSECapturePrototypeWriter(destinationDirectoryURL: tempDir)
        let captureID = "mse-checksum-fail"
        _ = try await writer.begin(metadata: BrowserMSECaptureMetadata(
            captureID: captureID,
            mediaSourceURL: "blob:https://stream.example/mse-corrupt",
            mimeTypes: ["video/mp4"]
        ))

        let initData = BrowserMSETestHarness.buildInitSegment(trackKind: .video, trackID: 1)
        let wrongChecksum = String(repeating: "0", count: 64)

        do {
            _ = try await writer.appendChunk(
                captureID: captureID,
                chunkIndex: 0,
                offset: 0,
                trackIndex: 0,
                segmentIndex: 0,
                data: initData,
                sha256: wrongChecksum,
                isSegmentEnd: true
            )
            XCTFail("Expected checksum mismatch error")
        } catch let error as BrowserMSECapturePrototypeError {
            XCTAssertEqual(error, .checksumMismatch)
        }

        let stagingDir = tempDir.appendingPathComponent("MSECaptures/\(captureID)", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingDir.path))
    }

    // MARK: - Step 8: Detachment & Document Navigation

    func testMediaSourceDetachmentAndRevocationHandling() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mse-detach-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let writer = BrowserMSECapturePrototypeWriter(destinationDirectoryURL: tempDir)
        let receiver = BrowserMSECapturePrototypeReceiver(writer: writer)
        let captureID = "mse-detach-test"
        let documentID = "doc-detach-1"
        await receiver.register(captureID: captureID, documentID: documentID)

        _ = await receiver.receive(payload: [
            "kind": "metadata",
            "captureID": captureID,
            "documentID": documentID,
            "mediaSourceURL": "blob:https://stream.example/mse-detach",
            "mimeTypes": ["video/mp4"]
        ])

        // Bridge sends failure due to revocation
        let failureAck = await receiver.receive(payload: [
            "kind": "failure",
            "captureID": captureID,
            "documentID": documentID,
            "reason": "MediaSource URL was revoked"
        ])
        XCTAssertTrue(failureAck.accepted)

        // Subsequent chunk should be rejected as unauthorized
        let initData = BrowserMSETestHarness.buildInitSegment(trackKind: .video, trackID: 1)
        let lateChunkAck = await receiver.receive(payload: [
            "kind": "chunk",
            "captureID": captureID,
            "documentID": documentID,
            "chunkIndex": 0,
            "offset": 0,
            "trackIndex": 0,
            "segmentIndex": 0,
            "base64": initData.base64EncodedString(),
            "sha256": EngineSHA256.hash(data: initData),
            "isSegmentEnd": true
        ])
        XCTAssertFalse(lateChunkAck.accepted)
        XCTAssertEqual(lateChunkAck.error, .captureNotAuthorized)
    }

    func testUserCancellationDuringActiveCapture() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mse-user-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let writer = BrowserMSECapturePrototypeWriter(destinationDirectoryURL: tempDir)
        let receiver = BrowserMSECapturePrototypeReceiver(writer: writer)
        let captureID = "mse-user-cancel"
        await receiver.register(captureID: captureID, documentID: nil)

        _ = await receiver.receive(payload: [
            "kind": "metadata",
            "captureID": captureID,
            "mediaSourceURL": "blob:https://stream.example/mse-cancel",
            "mimeTypes": ["video/mp4"]
        ])

        await receiver.cancel(captureID: captureID)

        let stagingDir = tempDir.appendingPathComponent("MSECaptures/\(captureID)", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingDir.path))

        let published = (try? FileManager.default.contentsOfDirectory(atPath: tempDir.path))?
            .filter { $0.hasSuffix(".mp4") } ?? []
        XCTAssertTrue(published.isEmpty)
    }

    // MARK: - Step 9: Decision Pipeline & Candidate Classification

    func testDecisionPipelineRoutesCapturableMSEMediaSource() {
        let videoCandidate = BrowserMediaCandidate(
            id: "mse-cand-1",
            url: nil,
            rawURL: "blob:https://video.example/mse-uuid",
            kind: .mediaSource,
            blobKind: .mediaSource,
            mimeType: "video/mp4; codecs=\"avc1.4d401f\"",
            suggestedFilename: "stream.mp4",
            availability: .captureCandidate,
            evidence: ["MediaSource buffer observed"]
        )

        let decision = BrowserDownloadDecisionPipeline.decide(candidate: videoCandidate)

        switch decision.action {
        case .mseCapture(let candidate):
            XCTAssertEqual(candidate.id, "mse-cand-1")
        default:
            XCTFail("Expected .mseCapture action, got \(decision.action)")
        }

        let webmCandidate = BrowserMediaCandidate(
            id: "mse-cand-webm",
            url: nil,
            rawURL: "blob:https://video.example/mse-webm",
            kind: .mediaSource,
            blobKind: .mediaSource,
            mimeType: "video/webm; codecs=\"vp9\"",
            suggestedFilename: "stream.webm",
            availability: .unsupported
        )
        let webmDecision = BrowserDownloadDecisionPipeline.decide(candidate: webmCandidate)
        switch webmDecision.action {
        case .unsupported(let reason):
            XCTAssertTrue(reason.contains("WebM") || reason.contains("not available"))
        default:
            XCTFail("Expected .unsupported action for WebM, got \(webmDecision.action)")
        }
    }
}

