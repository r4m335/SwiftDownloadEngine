import XCTest
import Foundation
@testable import DM_Reverse_engineering

final class TorrentPersistenceTests: XCTestCase {
    var tempDirectoryURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TorrentPersistenceTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir = tempDirectoryURL {
            try? FileManager.default.removeItem(at: dir)
        }
        try super.tearDownWithError()
    }

    func testSaveAndReloadRecords() async throws {
        let store = try TorrentPersistenceStore(storageDirectoryURL: tempDirectoryURL)

        let record1 = TorrentRecord(
            infoHash: "0123456789abcdef0123456789abcdef01234567",
            source: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=DemoFile",
            name: "DemoFile",
            savePath: tempDirectoryURL.appendingPathComponent("Downloads/DemoFile"),
            state: .downloading,
            progress: TorrentProgress(bytesDownloaded: 1024, totalBytes: 2048, progressFraction: 0.5),
            priority: .high,
            sequenceIndex: 1,
            isExplicitlyPaused: false
        )

        try await store.saveRecord(record1)

        // Read back from memory
        let loadedMemory = await store.loadRecord(infoHash: "0123456789abcdef0123456789abcdef01234567")
        XCTAssertNotNil(loadedMemory)
        XCTAssertEqual(loadedMemory?.name, "DemoFile")
        XCTAssertEqual(loadedMemory?.priority, .high)
        XCTAssertEqual(loadedMemory?.state, .downloading)

        // Fresh store instance reading from disk
        let freshStore = try TorrentPersistenceStore(storageDirectoryURL: tempDirectoryURL)
        let loadedDisk = await freshStore.loadRecord(infoHash: "0123456789abcdef0123456789abcdef01234567")
        XCTAssertNotNil(loadedDisk)
        XCTAssertEqual(loadedDisk?.id, record1.id)
        XCTAssertEqual(loadedDisk?.infoHash, record1.infoHash)
        XCTAssertEqual(loadedDisk?.name, "DemoFile")
        XCTAssertEqual(loadedDisk?.priority, .high)
        XCTAssertEqual(loadedDisk?.sequenceIndex, 1)
        XCTAssertEqual(loadedDisk?.state, .downloading)
        XCTAssertEqual(loadedDisk?.progress.bytesDownloaded, 1024)
        XCTAssertEqual(loadedDisk?.progress.totalBytes, 2048)
    }

    func testSaveAndReloadResumeData() async throws {
        let store = try TorrentPersistenceStore(storageDirectoryURL: tempDirectoryURL)
        let hash = "AABBCCDDEEFF00112233445566778899AABBCCDD"
        let sampleData = "d10:sample_key11:sample_val7:versioni2010eee".data(using: .utf8)!

        try await store.saveResumeData(sampleData, for: hash)

        // Load immediately
        let loaded = await store.loadResumeData(for: hash)
        XCTAssertEqual(loaded, sampleData)

        // Load from fresh store instance
        let freshStore = try TorrentPersistenceStore(storageDirectoryURL: tempDirectoryURL)
        let freshLoaded = await freshStore.loadResumeData(for: hash)
        XCTAssertEqual(freshLoaded, sampleData)
    }

    func testNormalizedInfoHashHandling() async throws {
        let store = try TorrentPersistenceStore(storageDirectoryURL: tempDirectoryURL)
        let upperHash = "AABBCCDDEEFF00112233445566778899AABBCCDD"
        let lowerHash = upperHash.lowercased()

        let record = TorrentRecord(
            infoHash: upperHash,
            source: "magnet:?xt=urn:btih:\(upperHash)",
            name: "UpperTest",
            savePath: tempDirectoryURL
        )

        try await store.saveRecord(record)

        // Query with lowercase
        let loadedLower = await store.loadRecord(infoHash: lowerHash)
        XCTAssertNotNil(loadedLower)
        XCTAssertEqual(loadedLower?.infoHash, lowerHash)

        // Query with uppercase
        let loadedUpper = await store.loadRecord(infoHash: upperHash)
        XCTAssertNotNil(loadedUpper)
        XCTAssertEqual(loadedUpper?.infoHash, lowerHash)

        // Save resume data with uppercase, query with lowercase
        let bytes = Data([0x01, 0x02, 0x03, 0x04])
        try await store.saveResumeData(bytes, for: upperHash)
        let loadedBytes = await store.loadResumeData(for: lowerHash)
        XCTAssertEqual(loadedBytes, bytes)
    }

    func testCorruptedManifestRecovery() async throws {
        let manifestURL = tempDirectoryURL.appendingPathComponent("torrent_manifest.json")
        try "{ corrupted_json_syntax: [ missing_brackets".write(to: manifestURL, atomically: true, encoding: .utf8)

        // Creating the store should not crash; it should recover gracefully
        let store = try TorrentPersistenceStore(storageDirectoryURL: tempDirectoryURL)
        let records = await store.loadAllRecords()
        XCTAssertTrue(records.isEmpty, "Corrupt manifest should recover to empty records")

        // Store should remain fully operational
        let newRecord = TorrentRecord(
            infoHash: "1122334455667788990011223344556677889900",
            source: "magnet:?xt=urn:btih:1122334455667788990011223344556677889900",
            name: "RecoveredWrite",
            savePath: tempDirectoryURL
        )
        try await store.saveRecord(newRecord)

        let loaded = await store.loadRecord(infoHash: "1122334455667788990011223344556677889900")
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.name, "RecoveredWrite")
    }

    func testMissingResumeDataReturnsNil() async throws {
        let store = try TorrentPersistenceStore(storageDirectoryURL: tempDirectoryURL)
        let data = await store.loadResumeData(for: "nonexistent_info_hash")
        XCTAssertNil(data)
    }

    func testDeleteRecordAndResumeData() async throws {
        let store = try TorrentPersistenceStore(storageDirectoryURL: tempDirectoryURL)
        let hash = "deadbeefcafebabe0123456789abcdef01234567"

        let record = TorrentRecord(
            infoHash: hash,
            source: "magnet:?xt=urn:btih:\(hash)",
            name: "ToDelete",
            savePath: tempDirectoryURL
        )
        try await store.saveRecord(record)
        try await store.saveResumeData(Data([0xDE, 0xAD, 0xBE, 0xEF]), for: hash)

        let recordBefore = await store.loadRecord(infoHash: hash)
        XCTAssertNotNil(recordBefore)
        let resumeBefore = await store.loadResumeData(for: hash)
        XCTAssertNotNil(resumeBefore)

        try await store.deleteRecord(infoHash: hash)

        let recordAfter = await store.loadRecord(infoHash: hash)
        XCTAssertNil(recordAfter)
        let resumeAfter = await store.loadResumeData(for: hash)
        XCTAssertNil(resumeAfter)
        let allAfter = await store.loadAllRecords()
        XCTAssertEqual(allAfter.count, 0)
    }

    func testUnsupportedSchemaVersionRejection() async throws {
        let manifestURL = tempDirectoryURL.appendingPathComponent("torrent_manifest.json")
        let futureManifest = TorrentQueueManifest(
            schemaVersion: 999,
            maxConcurrentTorrents: 5,
            sequenceCounter: 10,
            records: []
        )
        let data = try JSONEncoder().encode(futureManifest)
        try data.write(to: manifestURL)

        do {
            _ = try TorrentPersistenceStore(storageDirectoryURL: tempDirectoryURL)
            XCTFail("Should throw unsupportedSchemaVersion error for version 999")
        } catch let error as TorrentEngineError {
            XCTAssertEqual(error, .unsupportedSchemaVersion(999))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testBatchSaveRecords() async throws {
        let store = try TorrentPersistenceStore(storageDirectoryURL: tempDirectoryURL)

        let records = (1...5).map { idx in
            let hash = String(repeating: "\(idx)", count: 40)
            return TorrentRecord(
                infoHash: hash,
                source: "magnet:?xt=urn:btih:\(hash)",
                name: "BatchItem_\(idx)",
                savePath: tempDirectoryURL,
                sequenceIndex: Int64(idx)
            )
        }

        try await store.saveRecords(records)

        let loaded = await store.loadAllRecords()
        XCTAssertEqual(loaded.count, 5)
        for idx in 1...5 {
            let hash = String(repeating: "\(idx)", count: 40)
            let item = await store.loadRecord(infoHash: hash)
            XCTAssertNotNil(item)
            XCTAssertEqual(item?.name, "BatchItem_\(idx)")
        }
    }

    func testSaveAndReloadFilePriorities() async throws {
        let store = try TorrentPersistenceStore(storageDirectoryURL: tempDirectoryURL)
        let hash = "abcdef0123456789abcdef0123456789abcdef01"
        let record = TorrentRecord(
            infoHash: hash,
            source: "magnet:?xt=urn:btih:\(hash)&dn=MultiFile",
            name: "MultiFile",
            savePath: tempDirectoryURL,
            sequenceIndex: 1,
            filePriorities: [0: .normal, 1: .doNotDownload, 2: .high]
        )

        try await store.saveRecord(record)

        // Read from fresh store instance
        let freshStore = try TorrentPersistenceStore(storageDirectoryURL: tempDirectoryURL)
        let loaded = await freshStore.loadRecord(infoHash: hash)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.filePriorities?[0], .normal)
        XCTAssertEqual(loaded?.filePriorities?[1], .doNotDownload)
        XCTAssertEqual(loaded?.filePriorities?[2], .high)
    }

    func testSaveAndReloadSeedingPreference() async throws {
        let store = try TorrentPersistenceStore(storageDirectoryURL: tempDirectoryURL)
        let hash = "fedcba9876543210fedcba9876543210fedcba98"
        let pref = SeedingPreference(mode: .ratio, targetRatio: 2.5)
        let record = TorrentRecord(
            infoHash: hash,
            source: "magnet:?xt=urn:btih:\(hash)&dn=SeedingItem",
            name: "SeedingItem",
            savePath: tempDirectoryURL,
            sequenceIndex: 2,
            seedingPreference: pref
        )

        try await store.saveRecord(record)

        let freshStore = try TorrentPersistenceStore(storageDirectoryURL: tempDirectoryURL)
        let loaded = await freshStore.loadRecord(infoHash: hash)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.seedingPreference?.mode, .ratio)
        XCTAssertEqual(loaded?.seedingPreference?.targetRatio, 2.5)
    }
}
