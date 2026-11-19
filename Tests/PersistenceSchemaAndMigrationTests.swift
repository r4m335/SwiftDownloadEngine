import XCTest
@testable import DM_Reverse_engineering

final class PersistenceSchemaAndMigrationTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersistenceSchemaMigrationTests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    // MARK: - 1. DurableStorage Primitives

    func testDurableStorageAtomicWriteAndLoad() throws {
        let testURL = tempDirectory.appendingPathComponent("atomic_test.json")
        let data = "{\"message\":\"hello durable storage\"}".data(using: .utf8)!

        try DurableStorage.writeAtomically(data, to: testURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: testURL.path))

        let readData = try Data(contentsOf: testURL)
        XCTAssertEqual(readData, data)

        // Ensure no leftover temporary files in directory
        let files = try FileManager.default.contentsOfDirectory(atPath: tempDirectory.path)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first, "atomic_test.json")
    }

    func testDurableStorageQuarantine() throws {
        let corruptURL = tempDirectory.appendingPathComponent("corrupted_manifest.json")
        try "GARBAGE_PAYLOAD{{{".data(using: .utf8)!.write(to: corruptURL)

        let quarantinedURL = DurableStorage.quarantineCorruptFile(
            at: corruptURL,
            error: NSError(domain: "test", code: -1, userInfo: [NSLocalizedDescriptionKey: "Simulated corruption"])
        )

        XCTAssertNotNil(quarantinedURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: corruptURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantinedURL!.path))
        XCTAssertTrue(quarantinedURL!.lastPathComponent.hasPrefix("corrupted_manifest.corrupt."))
        XCTAssertTrue(quarantinedURL!.lastPathComponent.hasSuffix(".json"))
    }

    func testDurableStorageFutureSchemaRejection() throws {
        struct TestVersionedModel: Codable, SchemaVersioned {
            static let currentSchemaVersion: Int = 1
            var schemaVersion: Int
            var title: String
        }

        let futureURL = tempDirectory.appendingPathComponent("future_model.json")
        let futureJSON = "{\"schemaVersion\": 99, \"title\": \"Future Feature\"}".data(using: .utf8)!
        try futureJSON.write(to: futureURL)

        XCTAssertThrowsError(try DurableStorage.load(from: futureURL) as TestVersionedModel?) { error in
            guard let storageErr = error as? PersistenceStorageError else {
                XCTFail("Expected PersistenceStorageError, got \(error)")
                return
            }
            if case let .unsupportedFutureVersion(found, supported) = storageErr {
                XCTAssertEqual(found, 99)
                XCTAssertEqual(supported, 1)
            } else {
                XCTFail("Expected unsupportedFutureVersion, got \(storageErr)")
            }
        }

        // Future version must NOT be quarantined (to protect future app versions)
        XCTAssertTrue(FileManager.default.fileExists(atPath: futureURL.path))
    }

    // MARK: - 2. QueueManifest Schema & Migration

    func testQueueManifestSchemaRoundtripAndLegacyMigration() throws {
        let manifest = QueueManifest(
            schemaVersion: 1,
            maxConcurrentDownloads: 4,
            sequenceCounter: 10,
            items: []
        )
        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(QueueManifest.self, from: data)
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.maxConcurrentDownloads, 4)
        XCTAssertEqual(decoded.sequenceCounter, 10)

        // Test migration of legacy unversioned v0 JSON
        let legacyJSON = "{\"maxConcurrentDownloads\": 2, \"sequenceCounter\": 5, \"items\": []}".data(using: .utf8)!
        let migrated = try JSONDecoder().decode(QueueManifest.self, from: legacyJSON)
        XCTAssertEqual(migrated.schemaVersion, 0)
        XCTAssertEqual(migrated.maxConcurrentDownloads, 2)
        XCTAssertEqual(migrated.sequenceCounter, 5)
    }

    // MARK: - 3. HLSTransferRecord Schema & Migration

    func testHLSTransferRecordSchemaRoundtripAndLegacyMigration() throws {
        let record = HLSTransferRecord(
            schemaVersion: 1,
            id: "hls-test-1",
            manifestURL: URL(string: "https://example.com/stream.m3u8")!,
            outputFilename: "stream.mp4",
            outputDestinationURL: tempDirectory.appendingPathComponent("stream.mp4"),
            segmentDirectoryURL: tempDirectory.appendingPathComponent("segments"),
            totalSegments: 10,
            completedSegmentOrders: [0, 1, 2],
            state: .downloading,
            assemblyState: .notStarted
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(HLSTransferRecord.self, from: data)
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.id, "hls-test-1")
        XCTAssertEqual(decoded.completedSegmentOrders, [0, 1, 2])

        // Test migration of legacy v0 record without schemaVersion
        let legacyJSON = """
        {
            "id": "hls-legacy-0",
            "manifestURL": "https://example.com/legacy.m3u8",
            "outputFilename": "legacy.mp4",
            "outputDestinationURL": "file:///tmp/legacy.mp4",
            "segmentDirectoryURL": "file:///tmp/segments",
            "totalSegments": 5,
            "completedSegmentOrders": [0, 1],
            "state": "paused",
            "assemblyState": "notStarted",
            "createdAt": "2026-01-01T00:00:00Z",
            "updatedAt": "2026-01-01T00:00:00Z"
        }
        """.data(using: .utf8)!

        let migrated = try decoder.decode(HLSTransferRecord.self, from: legacyJSON)
        XCTAssertEqual(migrated.schemaVersion, 0)
        XCTAssertEqual(migrated.id, "hls-legacy-0")
        XCTAssertEqual(migrated.completedSegmentOrders, [0, 1])
    }

    // MARK: - 4. DownloadRecord Schema & Migration

    func testDownloadRecordSchemaRoundtripAndLegacyMigration() throws {
        let record = DownloadRecord(
            schemaVersion: 1,
            id: "dl-test-1",
            originalURL: URL(string: "https://example.com/file.zip")!,
            destinationURL: tempDirectory.appendingPathComponent("file.zip"),
            totalSize: 1024
        )

        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(DownloadRecord.self, from: data)
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.id, "dl-test-1")

        // Test legacy unversioned record
        let legacyJSON = """
        {
            "id": "dl-legacy-0",
            "originalURL": "https://example.com/legacy.zip",
            "destinationURL": "file:///tmp/legacy.zip",
            "totalSize": 2048,
            "state": "pending",
            "storageMode": "directSeek",
            "headers": {},
            "createdAt": 0,
            "updatedAt": 0,
            "segments": []
        }
        """.data(using: .utf8)!

        let migrated = try JSONDecoder().decode(DownloadRecord.self, from: legacyJSON)
        XCTAssertEqual(migrated.schemaVersion, 0)
        XCTAssertEqual(migrated.id, "dl-legacy-0")
        XCTAssertEqual(migrated.totalSize, 2048)
    }

    // MARK: - 5. ScheduleRule Schema & Migration

    func testScheduleRuleSchemaRoundtripAndLegacyMigration() throws {
        let rule = ScheduleRule(
            schemaVersion: 1,
            id: "schedule-1",
            name: "Night Schedule",
            isEnabled: true
        )

        let data = try JSONEncoder().encode(rule)
        let decoded = try JSONDecoder().decode(ScheduleRule.self, from: data)
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.name, "Night Schedule")

        // Test legacy unversioned schedule rule
        let legacyJSON = """
        {
            "id": "schedule-legacy",
            "name": "Legacy Rule",
            "isEnabled": false,
            "startTime": {"hour": 3, "minute": 0},
            "weekdays": [1, 2, 3],
            "wifiOnly": true,
            "targetDownloadIDs": ["dl-1"],
            "createdAt": 0,
            "updatedAt": 0
        }
        """.data(using: .utf8)!

        let migrated = try JSONDecoder().decode(ScheduleRule.self, from: legacyJSON)
        XCTAssertEqual(migrated.schemaVersion, 0)
        XCTAssertEqual(migrated.name, "Legacy Rule")
        XCTAssertEqual(migrated.targetDownloadIDs, ["dl-1"])
    }

    // MARK: - 6. Browser Storage Envelopes & Migrations

    func testBrowserBookmarksAndHistoryPayloads() throws {
        // Bookmarks
        let bookmarkPayload = BrowserBookmarkStore.BookmarkStoragePayload(
            schemaVersion: 1,
            folders: [],
            bookmarks: [BrowserBookmarkItem(title: "DuckDuckGo", url: URL(string: "https://duckduckgo.com")!)]
        )
        let bData = try JSONEncoder().encode(bookmarkPayload)
        let bDecoded = try JSONDecoder().decode(BrowserBookmarkStore.BookmarkStoragePayload.self, from: bData)
        XCTAssertEqual(bDecoded.schemaVersion, 1)
        XCTAssertEqual(bDecoded.bookmarks.count, 1)

        // Legacy unversioned Bookmarks payload
        let legacyBJSON = "{\"folders\": [], \"bookmarks\": [{\"id\":\"00000000-0000-0000-0000-000000000001\",\"title\":\"Google\",\"url\":\"https://google.com\",\"dateAdded\":0}]}".data(using: .utf8)!
        let bMigrated = try JSONDecoder().decode(BrowserBookmarkStore.BookmarkStoragePayload.self, from: legacyBJSON)
        XCTAssertEqual(bMigrated.schemaVersion, 0)
        XCTAssertEqual(bMigrated.bookmarks.first?.title, "Google")

        // History
        let historyPayload = BrowserHistoryStore.BrowserHistoryPayload(
            schemaVersion: 1,
            entries: [BrowserHistoryEntry(title: "Swift", url: URL(string: "https://swift.org")!)]
        )
        let hData = try JSONEncoder().encode(historyPayload)
        let hDecoded = try JSONDecoder().decode(BrowserHistoryStore.BrowserHistoryPayload.self, from: hData)
        XCTAssertEqual(hDecoded.schemaVersion, 1)
        XCTAssertEqual(hDecoded.entries.count, 1)

        // Legacy bare array History payload
        let legacyHJSON = "[{\"id\":\"00000000-0000-0000-0000-000000000002\",\"title\":\"Legacy Visit\",\"url\":\"https://legacy.org\",\"visitDate\":0,\"visitCount\":1}]".data(using: .utf8)!
        let hMigrated = try JSONDecoder().decode([BrowserHistoryEntry].self, from: legacyHJSON)
        XCTAssertEqual(hMigrated.count, 1)
        XCTAssertEqual(hMigrated.first?.title, "Legacy Visit")
    }

    func testLIDLibraryAndPlaybackHistoryPayloads() throws {
        // Favorites
        let favPayload = LIDLibraryStore.LIDFavoritesPayload(schemaVersion: 1, favorites: ["id-1", "id-2"])
        let favData = try JSONEncoder().encode(favPayload)
        let favDecoded = try JSONDecoder().decode(LIDLibraryStore.LIDFavoritesPayload.self, from: favData)
        XCTAssertEqual(favDecoded.schemaVersion, 1)
        XCTAssertEqual(favDecoded.favorites, ["id-1", "id-2"])

        // Legacy bare array Favorites
        let legacyFavJSON = "[\"fav-a\", \"fav-b\"]".data(using: .utf8)!
        let favLegacy = try JSONDecoder().decode([String].self, from: legacyFavJSON)
        XCTAssertEqual(favLegacy, ["fav-a", "fav-b"])

        // Playlists
        let playPayload = LIDLibraryStore.LIDPlaylistsPayload(schemaVersion: 1, playlists: [])
        let playData = try JSONEncoder().encode(playPayload)
        let playDecoded = try JSONDecoder().decode(LIDLibraryStore.LIDPlaylistsPayload.self, from: playData)
        XCTAssertEqual(playDecoded.schemaVersion, 1)
        XCTAssertEqual(playDecoded.playlists.count, 0)

        // Playback History
        let rec = LIDPlaybackRecord(mediaIdentifier: "m-1", title: "Test Video", lastPositionSeconds: 42.0, durationSeconds: 100.0)
        let histPayload = LIDPlaybackHistoryStore.LIDPlaybackHistoryPayload(schemaVersion: 1, records: ["m-1": rec])
        let histData = try JSONEncoder().encode(histPayload)
        let histDecoded = try JSONDecoder().decode(LIDPlaybackHistoryStore.LIDPlaybackHistoryPayload.self, from: histData)
        XCTAssertEqual(histDecoded.schemaVersion, 1)
        XCTAssertEqual(histDecoded.records["m-1"]?.lastPositionSeconds, 42.0)
    }

    func testBrowserSessionAndSitePermissionsPayloads() throws {
        // Session
        let session = BrowserSavedSession(schemaVersion: 1, activeTabID: nil, tabs: [])
        let sData = try JSONEncoder().encode(session)
        let sDecoded = try JSONDecoder().decode(BrowserSavedSession.self, from: sData)
        XCTAssertEqual(sDecoded.schemaVersion, 1)

        // Site permissions
        let perm = BrowserSitePermissionEntry(domain: "example.com", permissionType: .camera, decision: .grant)
        let permPayload = BrowserSitePermissionsStore.BrowserSitePermissionsPayload(schemaVersion: 1, entries: [perm])
        let pData = try JSONEncoder().encode(permPayload)
        let pDecoded = try JSONDecoder().decode(BrowserSitePermissionsStore.BrowserSitePermissionsPayload.self, from: pData)
        XCTAssertEqual(pDecoded.schemaVersion, 1)
        XCTAssertEqual(pDecoded.entries.first?.domain, "example.com")
    }

    func testMSEAndBlobCapturePayloads() throws {
        // MSE Recovery
        let mseRecord = BrowserMSECaptureRecoveryRecord(
            schemaVersion: 1,
            captureID: "mse-1",
            mediaSourceURL: "blob:https://example.com/uuid",
            mimeTypes: ["video/mp4"],
            stagingDirectoryURL: tempDirectory.appendingPathComponent("mse")
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let mseData = try encoder.encode(mseRecord)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let mseDecoded = try decoder.decode(BrowserMSECaptureRecoveryRecord.self, from: mseData)
        XCTAssertEqual(mseDecoded.schemaVersion, 1)
        XCTAssertEqual(mseDecoded.captureID, "mse-1")

        // Blob Export Record
        let blobRecord = BlobExportTransferRecord(
            schemaVersion: 1,
            transferID: "blob-1",
            tabID: "tab-1",
            documentID: nil,
            stagingURL: tempDirectory.appendingPathComponent("stage.blob"),
            finalURL: tempDirectory.appendingPathComponent("final.blob"),
            expectedSize: 512
        )
        let blobData = try JSONEncoder().encode(blobRecord)
        let blobDecoded = try JSONDecoder().decode(BlobExportTransferRecord.self, from: blobData)
        XCTAssertEqual(blobDecoded.schemaVersion, 1)
        XCTAssertEqual(blobDecoded.transferID, "blob-1")

        // QuickAccess
        let qaPayload = QuickAccessStore.QuickAccessPayload(schemaVersion: 1, shortcuts: [])
        let qaData = try JSONEncoder().encode(qaPayload)
        let qaDecoded = try JSONDecoder().decode(QuickAccessStore.QuickAccessPayload.self, from: qaData)
        XCTAssertEqual(qaDecoded.schemaVersion, 1)

        // Quarantine info
        let qRecord = MediaQuarantineRecord(
            schemaVersion: 1,
            timestamp: "2026-01-01T00:00:00Z",
            reason: "validation failed",
            destinationURL: "/path/video.mp4",
            container: "mp4",
            expectedTrackKinds: ["video", "audio"],
            quarantinedFiles: ["file1"]
        )
        let qData = try JSONEncoder().encode(qRecord)
        let qDecoded = try JSONDecoder().decode(MediaQuarantineRecord.self, from: qData)
        XCTAssertEqual(qDecoded.schemaVersion, 1)
        XCTAssertEqual(qDecoded.reason, "validation failed")
    }
}
