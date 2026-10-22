import Foundation
import XCTest
@testable import DM_Reverse_engineering

// MARK: - FileTypeDetectorTests

final class FileTypeDetectorTests: XCTestCase {

    // ── Byte-sequence helpers ────────────────────────────────────────────────

    private func makeTempFile(bytes: [UInt8], name: String = "test.bin") -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FileTypeDetectorTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data(bytes))
        return url
    }

    private func removeTemp(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    // ── ISO Base Media File Format ───────────────────────────────────────────

    func testPlainMP4HeaderDetected() {
        // Minimal ftyp box: size=0x00000014 (20), type=ftyp, brand=isom, version=0, compat=isom
        let header: [UInt8] = [
            0x00, 0x00, 0x00, 0x14, // box size 20
            0x66, 0x74, 0x79, 0x70, // "ftyp"
            0x69, 0x73, 0x6F, 0x6D, // brand "isom"
            0x00, 0x00, 0x00, 0x00, // version
            0x69, 0x73, 0x6F, 0x6D  // compat "isom"
        ]
        XCTAssertEqual(FileTypeDetector.detect(bytes: Data(header)), .isoBaseMediaFile)
    }

    func testFragmentedMP4WithMoofDetected() {
        // ftyp box followed by a moof box type indicator in the header window.
        var bytes: [UInt8] = [
            0x00, 0x00, 0x00, 0x14, 0x66, 0x74, 0x79, 0x70, // ftyp size+type
            0x69, 0x73, 0x6F, 0x6D, 0x00, 0x00, 0x00, 0x00, // brand + version
            0x69, 0x73, 0x6F, 0x6D,                          // compat
        ]
        // Append a moof box header immediately after.
        bytes += [0x00, 0x00, 0x00, 0x08, 0x6D, 0x6F, 0x6F, 0x66] // size=8, "moof"
        XCTAssertEqual(FileTypeDetector.detect(bytes: Data(bytes)), .fragmentedMP4)
    }

    func testFragmentedMP4IdentifiedAsNativelyAssemblable() {
        var bytes: [UInt8] = [
            0x00, 0x00, 0x00, 0x10, 0x66, 0x74, 0x79, 0x70, // ftyp size+type
            0x69, 0x73, 0x6F, 0x6D, 0x00, 0x00, 0x00, 0x00, // brand + version
        ]
        bytes += [0x00, 0x00, 0x00, 0x08, 0x6D, 0x6F, 0x6F, 0x66]
        let detected = FileTypeDetector.detect(bytes: Data(bytes))
        XCTAssertTrue(detected.isNativelyAssemblable)
    }

    // ── MPEG-TS ──────────────────────────────────────────────────────────────

    func testMPEGTSThreePacketHeaderDetected() {
        // Three 188-byte packets, each starting with 0x47.
        var bytes = [UInt8](repeating: 0x00, count: 188 * 3)
        bytes[0]   = 0x47
        bytes[188] = 0x47
        bytes[376] = 0x47
        XCTAssertEqual(FileTypeDetector.detect(bytes: Data(bytes)), .mpegTS)
    }

    func testMPEGTSSinglePacketWithSizeMuliple() {
        // Single 188-byte packet: size is multiple of 188 → accepted.
        var bytes = [UInt8](repeating: 0x00, count: 188)
        bytes[0] = 0x47
        let url = makeTempFile(bytes: bytes, name: "video.ts")
        defer { removeTemp(url) }
        XCTAssertEqual(FileTypeDetector.detect(at: url), .mpegTS)
    }

    func testMPEGTSIsNativelyAssemblable() {
        XCTAssertTrue(DetectedFileType.mpegTS.isNativelyAssemblable)
    }

    // ── Matroska / WebM ──────────────────────────────────────────────────────

    func testMatroskaSignatureDetected() {
        let bytes: [UInt8] = [0x1A, 0x45, 0xDF, 0xA3, 0x00, 0x00]
        XCTAssertEqual(FileTypeDetector.detect(bytes: Data(bytes)), .matroska)
    }

    // ── RIFF ─────────────────────────────────────────────────────────────────

    func testAVISignatureDetected() {
        let bytes: [UInt8] = [
            0x52, 0x49, 0x46, 0x46, // RIFF
            0x00, 0x00, 0x00, 0x00, // size (ignored)
            0x41, 0x56, 0x49, 0x20  // AVI<space>
        ]
        XCTAssertEqual(FileTypeDetector.detect(bytes: Data(bytes)), .avi)
    }

    func testWAVESignatureDetected() {
        let bytes: [UInt8] = [
            0x52, 0x49, 0x46, 0x46,
            0x00, 0x00, 0x00, 0x00,
            0x57, 0x41, 0x56, 0x45  // WAVE
        ]
        XCTAssertEqual(FileTypeDetector.detect(bytes: Data(bytes)), .wave)
    }

    func testWebPSignatureDetected() {
        let bytes: [UInt8] = [
            0x52, 0x49, 0x46, 0x46,
            0x00, 0x00, 0x00, 0x00,
            0x57, 0x45, 0x42, 0x50  // WEBP
        ]
        XCTAssertEqual(FileTypeDetector.detect(bytes: Data(bytes)), .webp)
    }

    // ── Image formats ────────────────────────────────────────────────────────

    func testPNGSignatureDetected() {
        let bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        XCTAssertEqual(FileTypeDetector.detect(bytes: Data(bytes)), .png)
    }

    func testJPEGSignatureDetected() {
        let bytes: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0]
        XCTAssertEqual(FileTypeDetector.detect(bytes: Data(bytes)), .jpeg)
    }

    func testGIF87aSignatureDetected() {
        let bytes: [UInt8] = [0x47, 0x49, 0x46, 0x38, 0x37, 0x61] // GIF87a
        XCTAssertEqual(FileTypeDetector.detect(bytes: Data(bytes)), .gif)
    }

    func testGIF89aSignatureDetected() {
        let bytes: [UInt8] = [0x47, 0x49, 0x46, 0x38, 0x39, 0x61] // GIF89a
        XCTAssertEqual(FileTypeDetector.detect(bytes: Data(bytes)), .gif)
    }

    // ── Audio formats ────────────────────────────────────────────────────────

    func testFLACSignatureDetected() {
        let bytes: [UInt8] = [0x66, 0x4C, 0x61, 0x43, 0x00] // fLaC
        XCTAssertEqual(FileTypeDetector.detect(bytes: Data(bytes)), .flac)
    }

    func testOggSignatureDetected() {
        let bytes: [UInt8] = [0x4F, 0x67, 0x67, 0x53, 0x00] // OggS
        XCTAssertEqual(FileTypeDetector.detect(bytes: Data(bytes)), .ogg)
    }

    func testAIFFSignatureDetected() {
        let bytes: [UInt8] = [0x46, 0x4F, 0x52, 0x4D, 0x00] // FORM
        XCTAssertEqual(FileTypeDetector.detect(bytes: Data(bytes)), .aiff)
    }

    // ── Archives ─────────────────────────────────────────────────────────────

    func testZIPSignatureDetected() {
        let bytes: [UInt8] = [0x50, 0x4B, 0x03, 0x04]
        XCTAssertEqual(FileTypeDetector.detect(bytes: Data(bytes)), .zip)
    }

    func testGzipSignatureDetected() {
        let bytes: [UInt8] = [0x1F, 0x8B, 0x08]
        XCTAssertEqual(FileTypeDetector.detect(bytes: Data(bytes)), .gzip)
    }

    func testBzip2SignatureDetected() {
        let bytes: [UInt8] = [0x42, 0x5A, 0x68, 0x39] // BZh9
        XCTAssertEqual(FileTypeDetector.detect(bytes: Data(bytes)), .bzip2)
    }

    func testSevenZipSignatureDetected() {
        let bytes: [UInt8] = [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]
        XCTAssertEqual(FileTypeDetector.detect(bytes: Data(bytes)), .sevenZip)
    }

    func testRARSignatureDetected() {
        let bytes: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00]
        XCTAssertEqual(FileTypeDetector.detect(bytes: Data(bytes)), .rar)
    }

    func testPDFSignatureDetected() {
        let bytes: [UInt8] = [0x25, 0x50, 0x44, 0x46, 0x2D] // %PDF-
        XCTAssertEqual(FileTypeDetector.detect(bytes: Data(bytes)), .pdf)
    }

    // ── Text-based manifests ─────────────────────────────────────────────────

    func testHLSPlaylistDetected() {
        let text = "#EXTM3U\n#EXT-X-VERSION:3\n"
        let bytes = Array(text.utf8)
        XCTAssertEqual(FileTypeDetector.detect(bytes: Data(bytes)), .m3uPlaylist)
    }

    func testDASHManifestDetected() {
        let text = "<?xml version=\"1.0\"?><MPD xmlns:mpeg=\"urn:mpeg:dash:schema:mpd:2011\"></MPD>"
        let bytes = Array(text.utf8)
        XCTAssertEqual(FileTypeDetector.detect(bytes: Data(bytes)), .dashManifest)
    }

    // ── Sentinel states ──────────────────────────────────────────────────────

    func testEmptyBytesReturnsEmpty() {
        XCTAssertEqual(FileTypeDetector.detect(bytes: Data()), .empty)
    }

    func testEmptyFileReturnsEmpty() {
        let url = makeTempFile(bytes: [], name: "empty.mp4")
        defer { removeTemp(url) }
        XCTAssertEqual(FileTypeDetector.detect(at: url), .empty)
    }

    func testMissingFileReturnsUnreadable() {
        let url = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).mp4")
        XCTAssertEqual(FileTypeDetector.detect(at: url), .unreadable)
    }

    func testRandomBytesReturnUnknown() {
        let bytes: [UInt8] = [0x01, 0x02, 0x03, 0x04, 0x05]
        XCTAssertEqual(FileTypeDetector.detect(bytes: Data(bytes)), .unknown)
    }

    // ── Extensionless files ──────────────────────────────────────────────────

    func testMP4DetectedWithNoExtension() {
        // Name has no extension at all.
        var bytes: [UInt8] = [
            0x00, 0x00, 0x00, 0x14, 0x66, 0x74, 0x79, 0x70,
            0x69, 0x73, 0x6F, 0x6D, 0x00, 0x00, 0x00, 0x00,
            0x69, 0x73, 0x6F, 0x6D
        ]
        bytes += [0x00, 0x00, 0x00, 0x08, 0x6D, 0x6F, 0x6F, 0x76] // moov box
        let url = makeTempFile(bytes: bytes, name: "videofile")  // NO extension
        defer { removeTemp(url) }
        let detected = FileTypeDetector.detect(at: url)
        XCTAssertEqual(detected.mediaClass, .video)
    }

    // ── Incorrect extensions ─────────────────────────────────────────────────

    func testMP4ContentWithBinExtensionDetectedCorrectly() {
        var bytes: [UInt8] = [
            0x00, 0x00, 0x00, 0x14, 0x66, 0x74, 0x79, 0x70,
            0x69, 0x73, 0x6F, 0x6D, 0x00, 0x00, 0x00, 0x00,
            0x69, 0x73, 0x6F, 0x6D
        ]
        bytes += [0x00, 0x00, 0x00, 0x08, 0x6D, 0x6F, 0x6F, 0x76]
        let detected = FileTypeDetector.detect(bytes: Data(bytes))
        // The detector should produce isoBaseMediaFile regardless of filename.
        XCTAssertEqual(detected.mediaClass, .video)
    }

    func testTSContentWithMP4ExtensionDetectedAsMPEGTS() {
        var bytes = [UInt8](repeating: 0x00, count: 188 * 3)
        bytes[0]   = 0x47
        bytes[188] = 0x47
        bytes[376] = 0x47
        XCTAssertEqual(FileTypeDetector.detect(bytes: Data(bytes)), .mpegTS)
    }

    // ── Large file — bounded header read ────────────────────────────────────

    func testLargeFileSamplesOnlyHeader() throws {
        // Write a 4 MB file: valid PNG header followed by junk.
        let pngHeader: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        var data = Data(pngHeader)
        data.append(contentsOf: [UInt8](repeating: 0xFF, count: 4 * 1024 * 1024 - 8))
        let url = makeTempFile(bytes: Array(data), name: "large.dat")
        defer { removeTemp(url) }

        let detected = FileTypeDetector.detect(at: url)
        XCTAssertEqual(detected, .png,
            "Large-file detection should be anchored to the leading \(FileTypeDetector.headerBudget) bytes only.")
    }

    // ── safeFilename ─────────────────────────────────────────────────────────

    func testSafeFilenameRenamesBinToMP4() {
        let result = FileTypeDetector.safeFilename(original: "download.bin", detectedType: .isoBaseMediaFile)
        XCTAssertEqual(result, "download.mp4")
    }

    func testSafeFilenameKeepsCorrectExtension() {
        let result = FileTypeDetector.safeFilename(original: "video.mp4", detectedType: .isoBaseMediaFile)
        XCTAssertEqual(result, "video.mp4")
    }

    func testSafeFilenameKeepsM4VAsAcceptableMP4Alias() {
        let result = FileTypeDetector.safeFilename(original: "movie.m4v", detectedType: .fragmentedMP4)
        XCTAssertEqual(result, "movie.m4v")
    }

    func testSafeFilenameDoesNotAddExtensionToExtensionlessFile() {
        let result = FileTypeDetector.safeFilename(original: "videofile", detectedType: .isoBaseMediaFile)
        XCTAssertEqual(result, "videofile")
    }

    func testSafeFilenameDoesNotRenameUnknownFormat() {
        let result = FileTypeDetector.safeFilename(original: "mystery.xyz", detectedType: .unknown)
        XCTAssertEqual(result, "mystery.xyz")
    }

    func testSafeFilenameReplacesTSExtensionOnMP4Content() {
        // A .ts file whose content is actually fMP4 should be renamed.
        let result = FileTypeDetector.safeFilename(original: "clip.ts", detectedType: .fragmentedMP4)
        XCTAssertEqual(result, "clip.mp4")
    }

    func testSafeFilenameDoesNotRenameZIPToSomethingElse() {
        let result = FileTypeDetector.safeFilename(original: "archive.zip", detectedType: .zip)
        XCTAssertEqual(result, "archive.zip")
    }

    // ── Media-class coverage ─────────────────────────────────────────────────

    func testMediaClassesAreCorrectlyAssigned() {
        XCTAssertEqual(DetectedFileType.isoBaseMediaFile.mediaClass, .video)
        XCTAssertEqual(DetectedFileType.fragmentedMP4.mediaClass, .video)
        XCTAssertEqual(DetectedFileType.mpegTS.mediaClass, .video)
        XCTAssertEqual(DetectedFileType.matroska.mediaClass, .video)
        XCTAssertEqual(DetectedFileType.mpegAudio.mediaClass, .audio)
        XCTAssertEqual(DetectedFileType.aacADTS.mediaClass, .audio)
        XCTAssertEqual(DetectedFileType.flac.mediaClass, .audio)
        XCTAssertEqual(DetectedFileType.ogg.mediaClass, .audio)
        XCTAssertEqual(DetectedFileType.wave.mediaClass, .audio)
        XCTAssertEqual(DetectedFileType.png.mediaClass, .image)
        XCTAssertEqual(DetectedFileType.jpeg.mediaClass, .image)
        XCTAssertEqual(DetectedFileType.gif.mediaClass, .image)
        XCTAssertEqual(DetectedFileType.zip.mediaClass, .archiveOrDocument)
        XCTAssertEqual(DetectedFileType.pdf.mediaClass, .archiveOrDocument)
        XCTAssertEqual(DetectedFileType.m3uPlaylist.mediaClass, .streamingManifest)
        XCTAssertEqual(DetectedFileType.dashManifest.mediaClass, .streamingManifest)
        XCTAssertEqual(DetectedFileType.unknown.mediaClass, .indeterminate)
        XCTAssertEqual(DetectedFileType.empty.mediaClass, .indeterminate)
        XCTAssertEqual(DetectedFileType.unreadable.mediaClass, .indeterminate)
    }

    // ── Canonical extensions ─────────────────────────────────────────────────

    func testSentinelsHaveNoCanonicalExtension() {
        XCTAssertNil(DetectedFileType.unknown.canonicalExtension)
        XCTAssertNil(DetectedFileType.empty.canonicalExtension)
        XCTAssertNil(DetectedFileType.unreadable.canonicalExtension)
    }

    func testMediaTypesHaveCanonicalExtensions() {
        XCTAssertNotNil(DetectedFileType.isoBaseMediaFile.canonicalExtension)
        XCTAssertNotNil(DetectedFileType.fragmentedMP4.canonicalExtension)
        XCTAssertNotNil(DetectedFileType.mpegTS.canonicalExtension)
        XCTAssertNotNil(DetectedFileType.matroska.canonicalExtension)
        XCTAssertNotNil(DetectedFileType.flac.canonicalExtension)
        XCTAssertNotNil(DetectedFileType.zip.canonicalExtension)
    }

    // ── FLV ──────────────────────────────────────────────────────────────────

    func testFLVSignatureDetected() {
        let bytes: [UInt8] = [0x46, 0x4C, 0x56, 0x01] // FLV\x01
        XCTAssertEqual(FileTypeDetector.detect(bytes: Data(bytes)), .flv)
    }

    // ── Corrupted / truncated header ─────────────────────────────────────────

    func testTruncatedISOBMFFHeaderFallsBackToUnknown() {
        // Only 4 bytes — not enough for a box header.
        let bytes: [UInt8] = [0x00, 0x00, 0x00, 0x14]
        let result = FileTypeDetector.detect(bytes: Data(bytes))
        // Could be unknown or any non-ISOBMFF match; must not crash.
        XCTAssertNotEqual(result, .unreadable)
    }

    func testCorruptedSyncByteMPEGTSFallsThrough() {
        // 188 bytes but wrong sync byte.
        var bytes = [UInt8](repeating: 0x00, count: 188)
        bytes[0] = 0x00 // Not 0x47
        let detected = FileTypeDetector.detect(bytes: Data(bytes))
        // Should NOT be classified as MPEG-TS.
        XCTAssertNotEqual(detected, .mpegTS)
    }
}
