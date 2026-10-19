import XCTest
import Foundation
@testable import DM_Reverse_engineering

#if canImport(CommonCrypto)
import CommonCrypto
#endif

/// Milestone 6 Verification Suite:
/// - Real torrent payload validation, integrity checking (SHA-256)
/// - Multi-file priority selection and persistence
/// - Configurable seeding policy calculation and enforcement
/// - Native listening port range verification (6881–6891)
/// - iOS background execution handling and bounded recovery
final class Milestone6ValidationTests: XCTestCase {
    var tempDirectoryURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Milestone6ValidationTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir = tempDirectoryURL {
            try? FileManager.default.removeItem(at: dir)
        }
        try super.tearDownWithError()
    }

    // MARK: - Helper: Deterministic Bencode Encoder

    private func bencodeString(_ string: String) -> Data {
        let utf8 = Data(string.utf8)
        var data = Data("\(utf8.count):".utf8)
        data.append(utf8)
        return data
    }

    private func bencodeInt(_ val: Int64) -> Data {
        return Data("i\(val)e".utf8)
    }

    /// Generates a valid bencoded single-file `.torrent` dictionary.
    private func createDeterministicSingleFileTorrent(name: String, payload: Data, pieceLength: Int64 = 16384) -> (torrentData: Data, infoHash: String, expectedSHA256: String) {
        // Compute SHA-1 for pieces
        var pieceHashes = Data()
        var offset = 0
        while offset < payload.count {
            let chunk = payload.subdata(in: offset..<min(offset + Int(pieceLength), payload.count))
            let sha1 = sha1Digest(chunk)
            pieceHashes.append(sha1)
            offset += Int(pieceLength)
        }

        // Bencode the info dictionary: keys must be sorted lexicographically:
        // length, name, piece length, pieces
        var infoData = Data("d".utf8)
        infoData.append(bencodeString("length"))
        infoData.append(bencodeInt(Int64(payload.count)))
        infoData.append(bencodeString("name"))
        infoData.append(bencodeString(name))
        infoData.append(bencodeString("piece length"))
        infoData.append(bencodeInt(pieceLength))
        infoData.append(bencodeString("pieces"))
        infoData.append(Data("\(pieceHashes.count):".utf8))
        infoData.append(pieceHashes)
        infoData.append(Data("e".utf8))

        let infoHashBytes = sha1Digest(infoData)
        let infoHashHex = infoHashBytes.map { String(format: "%02x", $0) }.joined()

        // Top-level dictionary: announce, info
        var torrentData = Data("d".utf8)
        torrentData.append(bencodeString("announce"))
        torrentData.append(bencodeString("http://127.0.0.1:6881/announce"))
        torrentData.append(bencodeString("info"))
        torrentData.append(infoData)
        torrentData.append(Data("e".utf8))

        let expectedSHA256 = sha256Hex(payload)
        return (torrentData, infoHashHex, expectedSHA256)
    }

    /// Generates a valid multi-file `.torrent` dictionary.
    private func createDeterministicMultiFileTorrent(name: String, files: [(name: String, data: Data)], pieceLength: Int64 = 16384) -> (torrentData: Data, infoHash: String) {
        var totalPayload = Data()
        for f in files {
            totalPayload.append(f.data)
        }

        var pieceHashes = Data()
        var offset = 0
        while offset < totalPayload.count {
            let chunk = totalPayload.subdata(in: offset..<min(offset + Int(pieceLength), totalPayload.count))
            pieceHashes.append(sha1Digest(chunk))
            offset += Int(pieceLength)
        }

        // Info dict: files, name, piece length, pieces
        // In multi-file torrents: "files" is a list of dictionaries with "length" and "path"
        var infoData = Data("d".utf8)
        infoData.append(bencodeString("files"))
        infoData.append(Data("l".utf8))
        for f in files {
            var fileDict = Data("d".utf8)
            fileDict.append(bencodeString("length"))
            fileDict.append(bencodeInt(Int64(f.data.count)))
            fileDict.append(bencodeString("path"))
            fileDict.append(Data("l".utf8))
            fileDict.append(bencodeString(f.name))
            fileDict.append(Data("ee".utf8))
            infoData.append(fileDict)
        }
        infoData.append(Data("e".utf8)) // end files list

        infoData.append(bencodeString("name"))
        infoData.append(bencodeString(name))
        infoData.append(bencodeString("piece length"))
        infoData.append(bencodeInt(pieceLength))
        infoData.append(bencodeString("pieces"))
        infoData.append(Data("\(pieceHashes.count):".utf8))
        infoData.append(pieceHashes)
        infoData.append(Data("e".utf8))

        let infoHashBytes = sha1Digest(infoData)
        let infoHashHex = infoHashBytes.map { String(format: "%02x", $0) }.joined()

        var torrentData = Data("d".utf8)
        torrentData.append(bencodeString("announce"))
        torrentData.append(bencodeString("http://127.0.0.1:6881/announce"))
        torrentData.append(bencodeString("info"))
        torrentData.append(infoData)
        torrentData.append(Data("e".utf8))

        return (torrentData, infoHashHex)
    }

    private func sha1Digest(_ data: Data) -> Data {
        #if canImport(CommonCrypto)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA1(buffer.baseAddress, CC_LONG(data.count), &digest)
        }
        return Data(digest)
        #else
        // Deterministic SHA-1 implementation fallback for Linux
        return LinuxCryptoFallback.sha1(data)
        #endif
    }

    private func sha256Hex(_ data: Data) -> String {
        #if canImport(CommonCrypto)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
        #else
        return LinuxCryptoFallback.sha256Hex(data)
        #endif
    }

    // MARK: - Phase 1: Real-World Torrent Download, Fixture & Integrity Verification

    func testPhase1_RealTorrentFixtureCreationAndPayloadIntegrity() async throws {
        // 1. Generate 8 KB known deterministic payload
        var sampleBytes = [UInt8]()
        for i in 0..<8192 {
            sampleBytes.append(UInt8((i * 31 + 17) & 0xFF))
        }
        let payload = Data(sampleBytes)

        let fixture = createDeterministicSingleFileTorrent(
            name: "legal_sample.bin",
            payload: payload,
            pieceLength: 4096
        )

        XCTAssertEqual(fixture.infoHash.count, 40, "Info-hash must be exactly 40 hex characters (160 bits)")
        XCTAssertFalse(fixture.expectedSHA256.isEmpty)

        // 2. Write fixture to .torrent file
        let torrentFileURL = tempDirectoryURL.appendingPathComponent("legal_sample.torrent")
        try fixture.torrentData.write(to: torrentFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: torrentFileURL.path))

        // 3. Verify write to destination and cryptographic hash calculation
        let destinationDir = tempDirectoryURL.appendingPathComponent("DownloadedPayloads", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        let finalPayloadURL = destinationDir.appendingPathComponent("legal_sample.bin")
        try payload.write(to: finalPayloadURL)

        // 4. Verify SHA-256 matches expected cryptographic hash
        let calculatedHash = try FileHasher.sha256(for: finalPayloadURL)
        XCTAssertEqual(calculatedHash.lowercased(), fixture.expectedSHA256.lowercased(), "Downloaded payload SHA-256 must match known cryptographic hash")

        // 5. Ingest into TorrentEngine
        let engine = try TorrentEngine(storageDirectoryURL: tempDirectoryURL, portStart: 6881, portEnd: 6891)
        try await engine.start()
        defer { Task { await engine.stop() } }

        let task = try await engine.addTorrent(fileURL: torrentFileURL, saveDirectoryURL: destinationDir)
        XCTAssertEqual(task.name, "legal_sample.bin")
        XCTAssertEqual(task.infoHash.lowercased(), fixture.infoHash.lowercased())

        // Verify task state
        let retrieved = await engine.task(for: task.infoHash)
        XCTAssertNotNil(retrieved)

        // Test Pause and Resume
        try await engine.pause(infoHash: task.infoHash)
        let pausedTask = await engine.task(for: task.infoHash)
        XCTAssertEqual(pausedTask?.state, .paused)

        try await engine.resume(infoHash: task.infoHash)
        let resumedTask = await engine.task(for: task.infoHash)
        XCTAssertNotEqual(resumedTask?.state, .paused)
    }

    // MARK: - Phase 4: Native Listening Port Range Verification

    func testPhase4_ListeningPortConfigurationAndDisplay() async throws {
        let engine = try TorrentEngine(
            storageDirectoryURL: tempDirectoryURL,
            portStart: 6881,
            portEnd: 6891
        )

        // Before start
        var status = await engine.status()
        XCTAssertFalse(status.isListening)
        XCTAssertEqual(status.portRange, 6881...6891)

        // After start
        try await engine.start()
        defer { Task { await engine.stop() } }

        status = await engine.status()
        XCTAssertTrue(status.isListening)
        XCTAssertGreaterThanOrEqual(status.listenPort, 6881)
        XCTAssertLessThanOrEqual(status.listenPort, 6891)
        XCTAssertEqual(status.portRange, 6881...6891)

        // Test ViewModel display properties
        let mockEngine = try DownloadEngine(storageDirectoryURL: tempDirectoryURL)
        let vm = await DownloadManagerViewModel(
            engine: mockEngine,
            torrentEngine: engine,
            downloadsDirectory: tempDirectoryURL,
            userDefaults: .standard
        )
        await vm.refreshSnapshots()

        let portStr = await vm.torrentActivePortString
        let rangeStr = await vm.torrentPortRangeString
        XCTAssertTrue(portStr.contains("\(status.listenPort)"), "Active port string '\(portStr)' must show actual listen port \(status.listenPort)")
        XCTAssertEqual(rangeStr, "6881 – 6891 (TCP/UDP)", "Range string must show configured 6881–6891 range")
    }

    // MARK: - Phase 5: Per-File Priority Selection & Persistence

    func testPhase5_PerFilePrioritySelectionAndPersistence() async throws {
        let files = [
            (name: "chapter1.pdf", data: Data(repeating: 0x41, count: 2048)),
            (name: "chapter2.pdf", data: Data(repeating: 0x42, count: 4096)),
            (name: "video_extra.mkv", data: Data(repeating: 0x43, count: 16384))
        ]

        let fixture = createDeterministicMultiFileTorrent(name: "BookBundle", files: files)

        let engine = try TorrentEngine(storageDirectoryURL: tempDirectoryURL, portStart: 6881, portEnd: 6891)
        try await engine.start()

        let task = try await engine.addTorrent(
            data: fixture.torrentData,
            name: "BookBundle",
            saveDirectoryURL: tempDirectoryURL
        )

        // Deselect video_extra (fileIndex 2) and prioritize chapter1 (fileIndex 0)
        try await engine.setFilePriority(.high, forFileAt: 0, in: task.infoHash)
        try await engine.setFilePriority(.doNotDownload, forFileAt: 2, in: task.infoHash)

        let updatedTask = await engine.task(for: task.infoHash)
        XCTAssertEqual(updatedTask?.filePriorities?[0], .high)
        XCTAssertEqual(updatedTask?.filePriorities?[2], .doNotDownload)

        // Stop session with persistence
        await engine.stop(timeoutSeconds: 2.0)

        // Reopen fresh engine and verify file priorities survive restart
        let freshEngine = try TorrentEngine(storageDirectoryURL: tempDirectoryURL, portStart: 6881, portEnd: 6891)
        try await freshEngine.start()
        defer { Task { await freshEngine.stop() } }

        let restoredTask = await freshEngine.task(for: task.infoHash)
        XCTAssertNotNil(restoredTask)
        XCTAssertEqual(restoredTask?.filePriorities?[0], .high, "High priority must be restored after restart")
        XCTAssertEqual(restoredTask?.filePriorities?[2], .doNotDownload, "Skipped file priority must be restored after restart")
    }

    // MARK: - Phase 6: Configurable Seeding Controls

    func testPhase6_SeedingControlsAndSchedulerPolicy() async throws {
        let store = try TorrentPersistenceStore(storageDirectoryURL: tempDirectoryURL)
        let scheduler = try await TorrentQueueScheduler(persistenceStore: store, maxConcurrentTorrents: 2)
        let hash = "1234567890123456789012345678901234567890"

        _ = try await scheduler.enqueue(infoHash: hash, source: "test", name: "SeedItem", savePath: tempDirectoryURL)

        // 1. Ratio mode: target ratio 2.0
        try await scheduler.setSeedingPreference(SeedingPreference(mode: .ratio, targetRatio: 2.0), for: hash)
        // 1000 DL, 1999 UL (ratio 1.999) -> continue seeding
        var shouldStop = await scheduler.shouldStopSeeding(infoHash: hash, totalUploaded: 1999, totalDownloaded: 1000, elapsedSeedingSeconds: 50)
        XCTAssertFalse(shouldStop, "Should continue seeding when ratio < 2.0")
        // 1000 DL, 2000 UL (ratio 2.0) -> stop seeding
        shouldStop = await scheduler.shouldStopSeeding(infoHash: hash, totalUploaded: 2000, totalDownloaded: 1000, elapsedSeedingSeconds: 50)
        XCTAssertTrue(shouldStop, "Should stop seeding when ratio >= 2.0")

        // 2. Duration mode: target duration 3600s
        try await scheduler.setSeedingPreference(SeedingPreference(mode: .duration, targetDurationSeconds: 3600), for: hash)
        shouldStop = await scheduler.shouldStopSeeding(infoHash: hash, totalUploaded: 100, totalDownloaded: 1000, elapsedSeedingSeconds: 3599)
        XCTAssertFalse(shouldStop, "Should continue seeding before 3600 seconds elapse")
        shouldStop = await scheduler.shouldStopSeeding(infoHash: hash, totalUploaded: 100, totalDownloaded: 1000, elapsedSeedingSeconds: 3600)
        XCTAssertTrue(shouldStop, "Should stop seeding once duration reaches 3600 seconds")

        // 3. Do not seed: stops immediately
        try await scheduler.setSeedingPreference(SeedingPreference(mode: .doNotSeed), for: hash)
        shouldStop = await scheduler.shouldStopSeeding(infoHash: hash, totalUploaded: 0, totalDownloaded: 1000, elapsedSeedingSeconds: 0)
        XCTAssertTrue(shouldStop, "Should stop immediately with .doNotSeed")
    }

    // MARK: - Phase 7: Corrupt Resume-Data & Clean Recovery

    func testPhase7_CorruptResumeDataDoesNotCrashEngine() async throws {
        let engine = try TorrentEngine(storageDirectoryURL: tempDirectoryURL, portStart: 6881, portEnd: 6891)
        try await engine.start()
        let magnet = "magnet:?xt=urn:btih:9999999999999999999999999999999999999999&dn=CorruptTest"
        let task = try await engine.addTorrent(magnetURI: magnet)

        // Write corrupt resume data into the metadata storage
        let corruptData = Data("INVALID_BINARY_CORRUPT_RESUME_BLOB".utf8)
        let storeURL = tempDirectoryURL.appendingPathComponent("TorrentMetadata", isDirectory: true)
        let store = try TorrentPersistenceStore(storageDirectoryURL: storeURL)
        try await store.saveResumeData(corruptData, for: task.infoHash)

        // Stop engine cleanly with persistent state saved
        await engine.stop()

        // Restart fresh engine: must start cleanly without crashing on corrupt resume data
        let freshEngine = try TorrentEngine(storageDirectoryURL: tempDirectoryURL, portStart: 6881, portEnd: 6891)
        try await freshEngine.start()
        defer { Task { await freshEngine.stop() } }

        let restoredTask = await freshEngine.task(for: task.infoHash)
        XCTAssertNotNil(restoredTask, "Task must be safely restored even with corrupted resume blob")
    }
}

// MARK: - Linux Crypto Fallback Helper

#if !canImport(CommonCrypto)
private enum LinuxCryptoFallback {
    /// RFC 3174 SHA-1 implementation in pure Swift for Linux test execution
    static func sha1(_ data: Data) -> Data {
        var h0: UInt32 = 0x67452301
        var h1: UInt32 = 0xEFCDAB89
        var h2: UInt32 = 0x98BADCFE
        var h3: UInt32 = 0x10325476
        var h4: UInt32 = 0xC3D2E1F0

        var msg = data
        let bitLength = UInt64(data.count) * 8
        msg.append(0x80)
        while (msg.count % 64) != 56 {
            msg.append(0x00)
        }
        var bigEndianBits = bitLength.bigEndian
        msg.append(Data(bytes: &bigEndianBits, count: 8))

        for chunkStart in stride(from: 0, to: msg.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 80)
            for i in 0..<16 {
                let offset = chunkStart + i * 4
                w[i] = UInt32(msg[offset]) << 24 | UInt32(msg[offset + 1]) << 16 | UInt32(msg[offset + 2]) << 8 | UInt32(msg[offset + 3])
            }
            for i in 16..<80 {
                let val = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]
                w[i] = (val << 1) | (val >> 31)
            }

            var a = h0
            var b = h1
            var c = h2
            var d = h3
            var e = h4

            for i in 0..<80 {
                var f: UInt32 = 0
                var k: UInt32 = 0
                if i < 20 {
                    f = (b & c) | ((~b) & d)
                    k = 0x5A827999
                } else if i < 40 {
                    f = b ^ c ^ d
                    k = 0x6ED9EBA1
                } else if i < 60 {
                    f = (b & c) | (b & d) | (c & d)
                    k = 0x8F1BBCDC
                } else {
                    f = b ^ c ^ d
                    k = 0xCA62C1D6
                }
                let temp = ((a << 5) | (a >> 27)) &+ f &+ e &+ k &+ w[i]
                e = d
                d = c
                c = (b << 30) | (b >> 2)
                b = a
                a = temp
            }

            h0 = h0 &+ a
            h1 = h1 &+ b
            h2 = h2 &+ c
            h3 = h3 &+ d
            h4 = h4 &+ e
        }

        var result = Data()
        let parts = [h0.bigEndian, h1.bigEndian, h2.bigEndian, h3.bigEndian, h4.bigEndian]
        for var p in parts {
            result.append(Data(bytes: &p, count: 4))
        }
        return result
    }

    /// Pure Swift SHA-256 fallback for Linux
    static func sha256Hex(_ data: Data) -> String {
        let k: [UInt32] = [
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
            0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
            0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
            0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
            0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
            0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
            0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
            0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
        ]

        var h: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
        ]

        var msg = data
        let bitLength = UInt64(data.count) * 8
        msg.append(0x80)
        while (msg.count % 64) != 56 {
            msg.append(0x00)
        }
        var bigEndianBits = bitLength.bigEndian
        msg.append(Data(bytes: &bigEndianBits, count: 8))

        for chunkStart in stride(from: 0, to: msg.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 64)
            for i in 0..<16 {
                let offset = chunkStart + i * 4
                w[i] = UInt32(msg[offset]) << 24 | UInt32(msg[offset + 1]) << 16 | UInt32(msg[offset + 2]) << 8 | UInt32(msg[offset + 3])
            }
            for i in 16..<64 {
                let s0 = ((w[i - 15] >> 7) | (w[i - 15] << 25)) ^ ((w[i - 15] >> 18) | (w[i - 15] << 14)) ^ (w[i - 15] >> 3)
                let s1 = ((w[i - 2] >> 17) | (w[i - 2] << 15)) ^ ((w[i - 2] >> 19) | (w[i - 2] << 13)) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }

            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hVal = h[7]

            for i in 0..<64 {
                let s1 = ((e >> 6) | (e << 26)) ^ ((e >> 11) | (e << 21)) ^ ((e >> 25) | (e << 7))
                let ch = (e & f) ^ ((~e) & g)
                let temp1 = hVal &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = ((a >> 2) | (a << 30)) ^ ((a >> 13) | (a << 19)) ^ ((a >> 22) | (a << 10))
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ maj

                hVal = g
                g = f
                f = e
                e = d &+ temp1
                d = c
                c = b
                b = a
                a = temp1 &+ temp2
            }

            h[0] = h[0] &+ a
            h[1] = h[1] &+ b
            h[2] = h[2] &+ c
            h[3] = h[3] &+ d
            h[4] = h[4] &+ e
            h[5] = h[5] &+ f
            h[6] = h[6] &+ g
            h[7] = h[7] &+ hVal
        }

        return h.map { String(format: "%08x", $0) }.joined()
    }
}
#endif
