import Foundation
import XCTest
@testable import DM_Reverse_engineering

final class HLSSegmentDecryptorTests: XCTestCase {

    func testHexIVParsing() {
        // Standard 32-character hex with 0x prefix
        let iv1 = HLSSegmentDecryptor.parseIV("0x0102030405060708090a0b0c0d0e0f10")
        XCTAssertEqual(iv1?.count, 16)
        XCTAssertEqual(iv1, Data([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]))

        // Uppercase without prefix
        let iv2 = HLSSegmentDecryptor.parseIV("A1B2C3D4E5F60718293A4B5C6D7E8F90")
        XCTAssertEqual(iv2?.count, 16)
        XCTAssertEqual(iv2, Data([0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0xF6, 0x07, 0x18, 0x29, 0x3A, 0x4B, 0x5C, 0x6D, 0x7E, 0x8F, 0x90]))

        // Invalid hex returns nil
        let iv3 = HLSSegmentDecryptor.parseIV("0xZZZZ")
        XCTAssertNil(iv3)

        // Short hex is zero-padded on the left to 16 bytes
        let iv4 = HLSSegmentDecryptor.parseIV("0x01")
        XCTAssertEqual(iv4?.count, 16)
        XCTAssertEqual(iv4?.last, 0x01)
        XCTAssertEqual(iv4?.first, 0x00)
    }

    func testSequenceNumberIVDerivationMatchesRFC8216() {
        // Sequence number 0 -> all zeroes
        let iv0 = HLSSegmentDecryptor.ivForSequenceNumber(0)
        XCTAssertEqual(iv0, Data(repeating: 0, count: 16))

        // Sequence number 1 -> 15 zeroes followed by 0x01
        let iv1 = HLSSegmentDecryptor.ivForSequenceNumber(1)
        var expected1 = Data(repeating: 0, count: 15)
        expected1.append(0x01)
        XCTAssertEqual(iv1, expected1)

        // Sequence number 0x0100 (256) -> big endian byte at index 14
        let iv256 = HLSSegmentDecryptor.ivForSequenceNumber(256)
        var expected256 = Data(repeating: 0, count: 14)
        expected256.append(contentsOf: [0x01, 0x00])
        XCTAssertEqual(iv256, expected256)
    }

    func testAES128DecryptionRoundTrip() throws {
        #if canImport(CommonCrypto)
        let key = Data((0..<16).map { UInt8($0 * 7) })
        let iv = Data((0..<16).map { UInt8($0 * 13) })
        let plaintext = "Hello HLS AES-128 Decryption! This is a test chunk containing binary video data.".data(using: .utf8)!

        let ciphertext = try HLSSegmentDecryptor.encrypt(data: plaintext, key: key, iv: iv)
        XCTAssertNotEqual(ciphertext, plaintext)

        let decrypted = try HLSSegmentDecryptor.decrypt(data: ciphertext, key: key, iv: iv)
        XCTAssertEqual(decrypted, plaintext)
        #endif
    }

    func testAES128DecryptionWithSequenceNumberIV() throws {
        #if canImport(CommonCrypto)
        let key = Data((0..<16).map { UInt8(100 + $0) })
        let sequenceNumber: Int64 = 42
        let iv = HLSSegmentDecryptor.ivForSequenceNumber(sequenceNumber)
        let plaintext = "Segment 42 clear payload bytes.".data(using: .utf8)!

        let ciphertext = try HLSSegmentDecryptor.encrypt(data: plaintext, key: key, iv: iv)
        let decrypted = try HLSSegmentDecryptor.decrypt(data: ciphertext, key: key, iv: iv)
        XCTAssertEqual(decrypted, plaintext)
        #endif
    }

    func testFileDecryptionRoundTrip() throws {
        #if canImport(CommonCrypto)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let key = Data((0..<16).map { UInt8($0 + 1) })
        let iv = HLSSegmentDecryptor.ivForSequenceNumber(1)
        let clearData = Data(repeating: 0x47, count: 188 * 5) // 5 MPEG-TS packets

        let cipherData = try HLSSegmentDecryptor.encrypt(data: clearData, key: key, iv: iv)
        let encryptedFile = tempDir.appendingPathComponent("encrypted.ts")
        let decryptedFile = tempDir.appendingPathComponent("decrypted.ts")

        try cipherData.write(to: encryptedFile)
        try HLSSegmentDecryptor.decryptFile(at: encryptedFile, to: decryptedFile, key: key, iv: iv)

        let recovered = try Data(contentsOf: decryptedFile)
        XCTAssertEqual(recovered, clearData)
        #endif
    }

    func testInvalidKeyOrIVLengthThrows() {
        #if canImport(CommonCrypto)
        let shortKey = Data([1, 2, 3])
        let validIV = Data(repeating: 0, count: 16)
        let data = Data([10, 20, 30])

        XCTAssertThrowsError(try HLSSegmentDecryptor.decrypt(data: data, key: shortKey, iv: validIV)) { error in
            XCTAssertEqual(error as? HLSSegmentDecryptionError, .invalidKeyLength(expected: 16, actual: 3))
        }

        let validKey = Data(repeating: 0, count: 16)
        let shortIV = Data([1, 2, 3])
        XCTAssertThrowsError(try HLSSegmentDecryptor.decrypt(data: data, key: validKey, iv: shortIV)) { error in
            XCTAssertEqual(error as? HLSSegmentDecryptionError, .invalidIVLength(expected: 16, actual: 3))
        }
        #endif
    }

    func testHLSVODReconstructorAssemblesAES128EncryptedStream() throws {
        #if canImport(CommonCrypto)
        let manifestURL = URL(string: "https://video.example/vod/encrypted.m3u8")!
        let playlist = """
        #EXTM3U
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXT-X-KEY:METHOD=AES-128,URI="https://video.example/vod/key.bin"
        #EXTINF:2,
        segment1.ts
        #EXTINF:2,
        segment2.ts
        #EXT-X-ENDLIST
        """
        let manifest = try HLSManifestParser.parse(playlist, baseURL: manifestURL)
        let transferPlan = try HLSTransferPlanner.makeVODPlan(from: manifest)

        XCTAssertEqual(transferPlan.resources.count, 3)
        XCTAssertEqual(transferPlan.resources[0].kind, .encryptionKey)
        XCTAssertEqual(transferPlan.resources[1].kind, .mediaSegment)
        XCTAssertEqual(transferPlan.resources[2].kind, .mediaSegment)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let key = Data((0..<16).map { UInt8($0 + 42) })
        let keyFile = tempDir.appendingPathComponent("key.bin")
        try key.write(to: keyFile)

        // Make two valid MPEG-TS packets (188 bytes starting with 0x47 sync byte)
        var packet1 = Data([0x47]) + Data(repeating: 0x11, count: 187)
        var packet2 = Data([0x47]) + Data(repeating: 0x22, count: 187)

        let iv1 = HLSSegmentDecryptor.ivForSequenceNumber(transferPlan.resources[1].sequenceNumber ?? 0)
        let iv2 = HLSSegmentDecryptor.ivForSequenceNumber(transferPlan.resources[2].sequenceNumber ?? 1)

        let cipher1 = try HLSSegmentDecryptor.encrypt(data: packet1, key: key, iv: iv1)
        let cipher2 = try HLSSegmentDecryptor.encrypt(data: packet2, key: key, iv: iv2)

        let seg1File = tempDir.appendingPathComponent("seg1.ts")
        let seg2File = tempDir.appendingPathComponent("seg2.ts")
        try cipher1.write(to: seg1File)
        try cipher2.write(to: seg2File)

        let completed = [
            HLSCompletedResource(resource: transferPlan.resources[0], fileURL: keyFile),
            HLSCompletedResource(resource: transferPlan.resources[1], fileURL: seg1File),
            HLSCompletedResource(resource: transferPlan.resources[2], fileURL: seg2File)
        ]

        let outputURL = tempDir.appendingPathComponent("output.ts")
        let result = try HLSVODReconstructor.assemble(
            transferPlan: transferPlan,
            completedResources: completed,
            destinationURL: outputURL,
            temporaryDirectoryURL: tempDir.appendingPathComponent("assembly_temp")
        )

        XCTAssertEqual(result.container, .mpegTS)
        let assembledData = try Data(contentsOf: outputURL)
        XCTAssertEqual(assembledData, packet1 + packet2)
        #endif
    }
}
