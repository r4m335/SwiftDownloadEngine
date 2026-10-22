import Foundation
import XCTest
@testable import DM_Reverse_engineering

// MARK: - MediaIntegrityValidatorTests

/// Tests for `MediaIntegrityValidator` covering every acceptance criterion
/// in milestone 7H.5.
final class MediaIntegrityValidatorTests: XCTestCase {

    // ── Helpers ──────────────────────────────────────────────────────────────

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MIVTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func writeFile(bytes: [UInt8], name: String) -> URL {
        let url = tempDir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data(bytes))
        return url
    }

    // Minimal ftyp + moov box header (plain ISO-BMFF / MP4).
    private var minimalMP4Header: [UInt8] {
        var b: [UInt8] = [
            0x00, 0x00, 0x00, 0x14, 0x66, 0x74, 0x79, 0x70, // ftyp size+type
            0x69, 0x73, 0x6F, 0x6D, 0x00, 0x00, 0x00, 0x00, // brand "isom" + version
            0x69, 0x73, 0x6F, 0x6D,                          // compat "isom"
        ]
        b += [0x00, 0x00, 0x00, 0x08, 0x6D, 0x6F, 0x6F, 0x76] // moov (empty)
        return b
    }

    // ftyp + moov + moof + mdat — minimal fragmented MP4.
    private var minimalFMP4Header: [UInt8] {
        var b: [UInt8] = [
            0x00, 0x00, 0x00, 0x14, 0x66, 0x74, 0x79, 0x70,
            0x69, 0x73, 0x6F, 0x6D, 0x00, 0x00, 0x00, 0x00,
            0x69, 0x73, 0x6F, 0x6D,
        ]
        b += [0x00, 0x00, 0x00, 0x08, 0x6D, 0x6F, 0x6F, 0x76] // moov
        b += [0x00, 0x00, 0x00, 0x08, 0x6D, 0x6F, 0x6F, 0x66] // moof
        b += [0x00, 0x00, 0x00, 0x08, 0x6D, 0x64, 0x61, 0x74] // mdat
        return b
    }

    // Three full 188-byte MPEG-TS packets.
    private func makeTSData(packetCount: Int = 3) -> [UInt8] {
        var bytes = [UInt8](repeating: 0x00, count: 188 * packetCount)
        for i in 0..<packetCount { bytes[i * 188] = 0x47 }
        return bytes
    }

    // ── AC: Empty file ───────────────────────────────────────────────────────

    func testEmptyFileReportsEmptyFileOutcome() {
        let url = writeFile(bytes: [], name: "empty.mp4")
        let report = MediaIntegrityValidator.validateDirectDownload(fileURL: url)
        XCTAssertEqual(report.outcome, .emptyFile)
        XCTAssertFalse(report.outcome.fileIsPresent)
        XCTAssertFalse(report.outcome.isConfirmedValid)
    }

    // ── AC: Missing / unreadable file ────────────────────────────────────────

    func testMissingFileReportsUnreadableOutcome() {
        let url = tempDir.appendingPathComponent("nonexistent-\(UUID().uuidString).mp4")
        let report = MediaIntegrityValidator.validateDirectDownload(fileURL: url)
        XCTAssertEqual(report.outcome, .unreadable)
        XCTAssertFalse(report.outcome.fileIsPresent)
    }

    // ── AC: Unknown format ───────────────────────────────────────────────────

    func testRandomBytesReportUnknownFormat() {
        let url = writeFile(bytes: [0x01, 0x02, 0x03, 0x04, 0x05], name: "mystery.bin")
        let report = MediaIntegrityValidator.validateDirectDownload(fileURL: url)
        XCTAssertEqual(report.outcome, .unknownFormat)
        XCTAssertFalse(report.outcome.isConfirmedValid)
        XCTAssertTrue(report.outcome.fileIsPresent)
    }

    // ── AC: Non-media format not rejected ────────────────────────────────────

    func testZIPPreservedAsNonMediaFormat() {
        let bytes: [UInt8] = [0x50, 0x4B, 0x03, 0x04, 0x00, 0x00]
        let url = writeFile(bytes: bytes, name: "archive.zip")
        let report = MediaIntegrityValidator.validateDirectDownload(fileURL: url)
        if case .nonMediaFormat(let t) = report.outcome {
            XCTAssertEqual(t, .zip)
        } else {
            XCTFail("ZIP should be reported as nonMediaFormat, got: \(report.outcome)")
        }
        XCTAssertFalse(report.outcome.isConfirmedValid,
            "Non-media formats must not be labelled as confirmed-valid media.")
    }

    func testPDFPreservedAsNonMediaFormat() {
        let bytes: [UInt8] = [0x25, 0x50, 0x44, 0x46, 0x2D, 0x31] // %PDF-1
        let url = writeFile(bytes: bytes, name: "document.pdf")
        let report = MediaIntegrityValidator.validateDirectDownload(fileURL: url)
        if case .nonMediaFormat(let t) = report.outcome {
            XCTAssertEqual(t, .pdf)
        } else {
            XCTFail("PDF should be reported as nonMediaFormat, got: \(report.outcome)")
        }
    }

    func testImagePreservedAsNonMediaFormat() {
        let bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let url = writeFile(bytes: bytes, name: "thumbnail.png")
        let report = MediaIntegrityValidator.validateDirectDownload(fileURL: url)
        if case .nonMediaFormat(let t) = report.outcome {
            XCTAssertEqual(t, .png)
        } else {
            XCTFail("PNG should be reported as nonMediaFormat, got: \(report.outcome)")
        }
    }

    // ── AC: Valid MPEG-TS (direct download) ──────────────────────────────────

    func testValidMPEGTSDirectDownloadValidated() {
        let url = writeFile(bytes: makeTSData(packetCount: 5), name: "video.ts")
        let report = MediaIntegrityValidator.validateDirectDownload(fileURL: url)
        XCTAssertEqual(report.outcome, .validated(detectedType: .mpegTS))
        XCTAssertTrue(report.outcome.isConfirmedValid)
    }

    // ── AC: Valid MPEG-TS (HLS output) ───────────────────────────────────────

    func testValidHLSMPEGTSOutputValidated() {
        let url = writeFile(bytes: makeTSData(packetCount: 10), name: "stream.ts")
        let report = MediaIntegrityValidator.validateHLSOutput(fileURL: url)
        XCTAssertEqual(report.outcome, .validated(detectedType: .mpegTS))
    }

    // ── AC: Truncated MPEG-TS ────────────────────────────────────────────────

    func testTruncatedMPEGTSReportsIntegrityFailure() {
        // 3 full packets + 10 extra bytes = not a multiple of 188.
        var bytes = makeTSData(packetCount: 3)
        bytes += [UInt8](repeating: 0x00, count: 10)
        let url = writeFile(bytes: bytes, name: "truncated.ts")
        let report = MediaIntegrityValidator.validateDirectDownload(fileURL: url)
        if case .integrityFailure(let t, _) = report.outcome {
            XCTAssertEqual(t, .mpegTS)
        } else {
            XCTFail("Truncated MPEG-TS should be integrityFailure, got: \(report.outcome)")
        }
        XCTAssertFalse(report.outcome.isConfirmedValid)
    }

    func testMPEGTSWithCorruptSyncByteReportsIntegrityFailure() {
        var bytes = makeTSData(packetCount: 3)
        bytes[188] = 0x00 // Corrupt the second packet's sync byte.
        let url = writeFile(bytes: bytes, name: "corrupt.ts")
        let report = MediaIntegrityValidator.validateDirectDownload(fileURL: url)
        if case .integrityFailure(let t, _) = report.outcome {
            XCTAssertEqual(t, .mpegTS)
        } else {
            XCTFail("MPEG-TS with bad sync byte should be integrityFailure, got: \(report.outcome)")
        }
    }

    // ── AC: Valid MP4 (direct download) ─────────────────────────────────────

    func testValidPlainMP4Validated() {
        let url = writeFile(bytes: minimalMP4Header, name: "movie.mp4")
        let report = MediaIntegrityValidator.validateDirectDownload(fileURL: url)
        XCTAssertTrue(report.outcome.isConfirmedValid,
            "Well-formed plain MP4 with ftyp+moov must be validated. Got: \(report.outcome)")
    }

    // ── AC: Valid fragmented MP4 (HLS/DASH/MSE output) ───────────────────────

    func testValidFMP4HLSOutputValidated() {
        let url = writeFile(bytes: minimalFMP4Header, name: "hls-output.mp4")
        let report = MediaIntegrityValidator.validateHLSOutput(fileURL: url)
        XCTAssertTrue(report.outcome.isConfirmedValid,
            "Well-formed fMP4 with ftyp+moov+moof+mdat must be validated by HLS path. Got: \(report.outcome)")
    }

    func testValidFMP4DASHOutputValidated() {
        let url = writeFile(bytes: minimalFMP4Header, name: "dash-output.mp4")
        let report = MediaIntegrityValidator.validateDASHOutput(fileURL: url)
        XCTAssertTrue(report.outcome.isConfirmedValid,
            "Well-formed fMP4 must be validated by DASH path. Got: \(report.outcome)")
    }

    func testValidFMP4MSEOutputValidated() {
        let url = writeFile(bytes: minimalFMP4Header, name: "mse-output.mp4")
        let report = MediaIntegrityValidator.validateMSECapture(fileURL: url)
        XCTAssertTrue(report.outcome.isConfirmedValid,
            "Well-formed fMP4 must be validated by MSE path. Got: \(report.outcome)")
    }

    // ── AC: Truncated MP4 ────────────────────────────────────────────────────

    func testTruncatedMP4ByteCountMismatchReportsIntegrityFailure() {
        let url = writeFile(bytes: minimalMP4Header, name: "truncated.mp4")
        let actualSize = Int64(minimalMP4Header.count)
        let expectedSize = actualSize + 1024  // Simulate Content-Length > actual.
        let report = MediaIntegrityValidator.validateDirectDownload(
            fileURL: url, expectedByteCount: expectedSize
        )
        if case .integrityFailure(_, let reason) = report.outcome {
            XCTAssertTrue(reason.contains("truncated"), "Reason should mention truncation.")
        } else {
            XCTFail("Byte-count mismatch should yield integrityFailure, got: \(report.outcome)")
        }
    }

    func testFMP4MissingMoofInHLSPathReportsIntegrityFailure() {
        // Plain MP4 (no moof) validated as an HLS output — must fail because
        // HLS requires moov+moof+mdat.
        let url = writeFile(bytes: minimalMP4Header, name: "nofmp4.mp4")
        let report = MediaIntegrityValidator.validateHLSOutput(fileURL: url)
        if case .integrityFailure(_, let reason) = report.outcome {
            XCTAssertTrue(reason.lowercased().contains("moof"),
                "Failure reason must mention the missing moof box.")
        } else {
            XCTFail("MP4 without moof must fail HLS validation, got: \(report.outcome)")
        }
    }

    // ── AC: Corrupted header / invalid container ──────────────────────────────

    func testCorruptedFMP4BoxOverrunsEOFReportsIntegrityFailure() {
        // Write a box header whose declared size extends past EOF.
        let bytes: [UInt8] = [
            0x00, 0x00, 0x00, 0x14, 0x66, 0x74, 0x79, 0x70, // ftyp (size 20)
            0x69, 0x73, 0x6F, 0x6D, 0x00, 0x00, 0x00, 0x00,
            0x69, 0x73, 0x6F, 0x6D,
            // Next box: claims size=9999 but file ends here.
            0x00, 0x00, 0x27, 0x0F, 0x6D, 0x6F, 0x6F, 0x76  // "moov" size=9999
        ]
        let url = writeFile(bytes: bytes, name: "corrupt.mp4")
        let report = MediaIntegrityValidator.validateDirectDownload(fileURL: url)
        if case .integrityFailure(_, _) = report.outcome {
            // Expected — overrun box detected.
        } else {
            XCTFail("Box overrunning EOF must yield integrityFailure, got: \(report.outcome)")
        }
    }

    // ── AC: Blob capture validation ───────────────────────────────────────────

    func testValidBlobCaptureMP4Validated() {
        let url = writeFile(bytes: minimalMP4Header, name: "blob.mp4")
        let report = MediaIntegrityValidator.validateBlobCapture(fileURL: url)
        XCTAssertTrue(report.outcome.isConfirmedValid,
            "Well-formed MP4 blob capture must be validated. Got: \(report.outcome)")
    }

    // ── AC: Matroska identified but not structurally validated ───────────────

    func testMatroskaIdentifiedWithNoValidator() {
        let bytes: [UInt8] = [0x1A, 0x45, 0xDF, 0xA3, 0x00, 0x00, 0x00, 0x00]
        let url = writeFile(bytes: bytes, name: "video.mkv")
        let report = MediaIntegrityValidator.validateDirectDownload(fileURL: url)
        if case .identifiedNoValidator(let t) = report.outcome {
            XCTAssertEqual(t, .matroska)
        } else {
            XCTFail("Matroska must be identifiedNoValidator, got: \(report.outcome)")
        }
        XCTAssertFalse(report.outcome.isConfirmedValid)
        XCTAssertTrue(report.outcome.fileIsPresent)
    }

    // ── AC: Mismatched extension / MIME doesn't affect outcome ───────────────

    func testMP4ContentWithBinExtensionValidated() {
        // File named .bin but contains a well-formed MP4.
        let url = writeFile(bytes: minimalMP4Header, name: "video.bin")
        let report = MediaIntegrityValidator.validateDirectDownload(fileURL: url)
        XCTAssertTrue(report.outcome.isConfirmedValid,
            "Content detection must override the misleading .bin extension. Got: \(report.outcome)")
        XCTAssertEqual(report.recommendedFilename, "video.mp4",
            "safeFilename should correct .bin to .mp4.")
    }

    func testTSContentWithMP4ExtensionValidatedAsMPEGTS() {
        let url = writeFile(bytes: makeTSData(packetCount: 5), name: "stream.mp4")
        let report = MediaIntegrityValidator.validateDirectDownload(fileURL: url)
        // Content detection sees MPEG-TS; structural validation runs.
        XCTAssertTrue(report.outcome.isConfirmedValid,
            "Valid MPEG-TS content with .mp4 extension should still validate. Got: \(report.outcome)")
        XCTAssertEqual(report.recommendedFilename, "stream.ts",
            "safeFilename should correct .mp4 to .ts for MPEG-TS content.")
    }

    // ── AC: Large file — validation does not load file into memory ───────────

    func testLargeValidMPEGTSValidatedWithBoundedMemory() {
        // 50 000 packets = ~9 MB. All valid.
        let packetCount = 50_000
        var bytes = [UInt8](repeating: 0x00, count: 188 * packetCount)
        for i in 0..<packetCount { bytes[i * 188] = 0x47 }
        let url = writeFile(bytes: bytes, name: "large.ts")
        let report = MediaIntegrityValidator.validateDirectDownload(fileURL: url)
        XCTAssertEqual(report.outcome, .validated(detectedType: .mpegTS),
            "Large valid MPEG-TS must validate successfully.")
        // Memory constraint is structural — this test just confirms no crash/failure.
    }

    // ── AC: Outcome state machine ─────────────────────────────────────────────

    func testOutcomePredicatesAreConsistent() {
        // validated → isConfirmedValid=true, fileIsPresent=true
        let v = MediaIntegrityValidationOutcome.validated(detectedType: .mpegTS)
        XCTAssertTrue(v.isConfirmedValid)
        XCTAssertTrue(v.fileIsPresent)

        // identifiedNoValidator → isConfirmedValid=false, fileIsPresent=true
        let i = MediaIntegrityValidationOutcome.identifiedNoValidator(detectedType: .matroska)
        XCTAssertFalse(i.isConfirmedValid)
        XCTAssertTrue(i.fileIsPresent)

        // integrityFailure → isConfirmedValid=false, fileIsPresent=true
        let f = MediaIntegrityValidationOutcome.integrityFailure(detectedType: .mpegTS, reason: "bad")
        XCTAssertFalse(f.isConfirmedValid)
        XCTAssertTrue(f.fileIsPresent)

        // unknownFormat → isConfirmedValid=false, fileIsPresent=true
        let u = MediaIntegrityValidationOutcome.unknownFormat
        XCTAssertFalse(u.isConfirmedValid)
        XCTAssertTrue(u.fileIsPresent)

        // emptyFile → isConfirmedValid=false, fileIsPresent=false
        let e = MediaIntegrityValidationOutcome.emptyFile
        XCTAssertFalse(e.isConfirmedValid)
        XCTAssertFalse(e.fileIsPresent)

        // unreadable → isConfirmedValid=false, fileIsPresent=false
        let r = MediaIntegrityValidationOutcome.unreadable
        XCTAssertFalse(r.isConfirmedValid)
        XCTAssertFalse(r.fileIsPresent)

        // nonMediaFormat → isConfirmedValid=false, fileIsPresent=true
        let n = MediaIntegrityValidationOutcome.nonMediaFormat(detectedType: .zip)
        XCTAssertFalse(n.isConfirmedValid)
        XCTAssertTrue(n.fileIsPresent)
    }

    // ── AC: detectedType accessor ────────────────────────────────────────────

    func testOutcomeDetectedTypeAccessorReturnsCorrectType() {
        let v = MediaIntegrityValidationOutcome.validated(detectedType: .mpegTS)
        XCTAssertEqual(v.detectedType, .mpegTS)

        let i = MediaIntegrityValidationOutcome.identifiedNoValidator(detectedType: .matroska)
        XCTAssertEqual(i.detectedType, .matroska)

        let f = MediaIntegrityValidationOutcome.integrityFailure(detectedType: .fragmentedMP4, reason: "x")
        XCTAssertEqual(f.detectedType, .fragmentedMP4)

        XCTAssertNil(MediaIntegrityValidationOutcome.unknownFormat.detectedType)
        XCTAssertNil(MediaIntegrityValidationOutcome.emptyFile.detectedType)
        XCTAssertNil(MediaIntegrityValidationOutcome.unreadable.detectedType)
    }

    // ── AC: Transfer complete but content invalid ────────────────────────────

    func testTransferCompletedButCorruptedOutputNotLabelledValid() {
        // Bytes that look like random data despite coming from a "completed" transfer.
        let url = writeFile(bytes: [0x01, 0x02, 0x03], name: "bad.mp4")
        // Pretend the transfer reported exactly this byte count.
        let report = MediaIntegrityValidator.validateDirectDownload(
            fileURL: url, expectedByteCount: 3
        )
        // The file matched no known signature → unknown format, NOT validated.
        XCTAssertFalse(report.outcome.isConfirmedValid,
            "A transfer that completed at the HTTP level but produced junk must never be marked valid.")
    }

    // ── AC: HLS playlist not validated as media ───────────────────────────────

    func testHLSManifestDetectedAsNonMedia() {
        let text = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:6\n"
        let url = writeFile(bytes: Array(text.utf8), name: "playlist.m3u8")
        let report = MediaIntegrityValidator.validateDirectDownload(fileURL: url)
        if case .nonMediaFormat(let t) = report.outcome {
            XCTAssertEqual(t, .m3uPlaylist)
        } else {
            XCTFail("HLS playlist must be non-media, got: \(report.outcome)")
        }
    }

    // ── AC: DASH manifest not validated as media ──────────────────────────────

    func testDASHManifestDetectedAsNonMedia() {
        let text = "<?xml version=\"1.0\"?><MPD xmlns=\"urn:mpeg:dash:schema:mpd:2011\"></MPD>"
        let url = writeFile(bytes: Array(text.utf8), name: "manifest.mpd")
        let report = MediaIntegrityValidator.validateDirectDownload(fileURL: url)
        if case .nonMediaFormat(let t) = report.outcome {
            XCTAssertEqual(t, .dashManifest)
        } else {
            XCTFail("DASH manifest must be non-media, got: \(report.outcome)")
        }
    }

    // ── AC: Recommended filename reflects detected type ───────────────────────

    func testReportContainsRecommendedFilenameForMisnamedFile() {
        let url = writeFile(bytes: makeTSData(packetCount: 3), name: "video.bin")
        let report = MediaIntegrityValidator.validateDirectDownload(fileURL: url)
        XCTAssertEqual(report.recommendedFilename, "video.ts",
            "Recommended filename must reflect the detected MPEG-TS type, not the .bin extension.")
    }

    func testReportRetainsOriginalFilenameForUnknownType() {
        let url = writeFile(bytes: [0xAB, 0xCD, 0xEF], name: "weird.xyz")
        let report = MediaIntegrityValidator.validateDirectDownload(fileURL: url)
        XCTAssertEqual(report.recommendedFilename, "weird.xyz",
            "Filename must not be altered when the format is unknown.")
    }

    // ── AC: Actual/expected byte counts surfaced in report ────────────────────

    func testReportSurfacesActualAndExpectedByteCounts() {
        let url = writeFile(bytes: minimalMP4Header, name: "sized.mp4")
        let expectedSize = Int64(minimalMP4Header.count)
        let report = MediaIntegrityValidator.validateDirectDownload(
            fileURL: url, expectedByteCount: expectedSize
        )
        XCTAssertEqual(report.expectedByteCount, expectedSize)
        XCTAssertEqual(report.actualByteCount, expectedSize)
    }
}
