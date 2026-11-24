import XCTest
@testable import DownloadEngineKit

final class LibraryAndMediaOrganization10OutOf10Tests: XCTestCase {

    private var tempDir: URL!
    private var storageDir: URL!

    override func setUp() {
        super.setUp()
        let root = FileManager.default.temporaryDirectory
        tempDir = root.appendingPathComponent("LIDOrgTests_\(UUID().uuidString)", isDirectory: true)
        storageDir = root.appendingPathComponent("LIDOrgStorage_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        try? FileManager.default.removeItem(at: storageDir)
        super.tearDown()
    }

    // MARK: - 1. Complete Library Views & Filtering Tests

    func testLibraryViewsAndFiltering() async throws {
        let httpTransfer = UnifiedTransfer(
            id: "1",
            name: "document.pdf",
            type: .http,
            state: .downloading,
            completedBytes: 100,
            destinationURL: tempDir.appendingPathComponent("document.pdf"),
            source: "https://example.com/document.pdf"
        )
        let pausedTransfer = UnifiedTransfer(
            id: "2",
            name: "movie.mp4",
            type: .http,
            state: .paused,
            completedBytes: 50,
            destinationURL: tempDir.appendingPathComponent("movie.mp4"),
            source: "https://example.com/movie.mp4"
        )
        let completedTransfer = UnifiedTransfer(
            id: "3",
            name: "song.mp3",
            type: .http,
            state: .completed,
            completedBytes: 1000,
            destinationURL: tempDir.appendingPathComponent("song.mp3"),
            source: "https://example.com/song.mp3"
        )
        let failedTransfer = UnifiedTransfer(
            id: "4",
            name: "broken.zip",
            type: .http,
            state: .failed(reason: "404 Not Found"),
            completedBytes: 0,
            destinationURL: tempDir.appendingPathComponent("broken.zip"),
            source: "https://example.com/broken.zip"
        )
        let torrentTransfer = UnifiedTransfer(
            id: "5",
            name: "ubuntu.iso",
            type: .torrent,
            state: .seeding,
            completedBytes: 2000,
            destinationURL: tempDir.appendingPathComponent("ubuntu.iso"),
            source: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567"
        )
        let hlsTransfer = UnifiedTransfer(
            id: "6",
            name: "stream.m3u8",
            type: .hls,
            state: .downloading,
            completedBytes: 300,
            destinationURL: tempDir.appendingPathComponent("stream.mp4"),
            source: "https://example.com/stream.m3u8"
        )
        let dashTransfer = UnifiedTransfer(
            id: "7",
            name: "stream.mpd",
            type: .dash,
            state: .downloading,
            completedBytes: 400,
            destinationURL: tempDir.appendingPathComponent("stream.mp4"),
            source: "https://example.com/stream.mpd"
        )
        let liveTransfer = UnifiedTransfer(
            id: "8",
            name: "Live Broadcast",
            type: .streaming,
            state: .downloading,
            completedBytes: 800,
            destinationURL: tempDir.appendingPathComponent("live.ts"),
            source: "https://example.com/live.m3u8"
        )
        let archivedTransfer = UnifiedTransfer(
            id: "9",
            name: "old_backup.tar.gz",
            type: .http,
            state: .completed,
            completedBytes: 5000,
            destinationURL: tempDir.appendingPathComponent("old_backup.tar.gz"),
            source: "https://example.com/old_backup.tar.gz",
            isArchived: true
        )

        let all = [httpTransfer, pausedTransfer, completedTransfer, failedTransfer, torrentTransfer, hlsTransfer, dashTransfer, liveTransfer, archivedTransfer]

        // Test filter matching
        XCTAssertTrue(httpTransfer.matchesFilter(.all))
        XCTAssertTrue(httpTransfer.matchesFilter(.active))
        XCTAssertTrue(pausedTransfer.matchesFilter(.paused))
        XCTAssertTrue(completedTransfer.matchesFilter(.completed))
        XCTAssertTrue(failedTransfer.matchesFilter(.failed))
        XCTAssertTrue(torrentTransfer.matchesFilter(.torrents))
        XCTAssertTrue(hlsTransfer.matchesFilter(.hls))
        XCTAssertTrue(dashTransfer.matchesFilter(.dash))
        XCTAssertTrue(liveTransfer.matchesFilter(.liveRecordings))
        XCTAssertTrue(archivedTransfer.matchesFilter(.archived))

        // Test DownloadStatusCounts
        var counts = DownloadStatusCounts(all: 0, active: 0, paused: 0, completed: 0, failed: 0)
        for t in all {
            if t.matchesFilter(.active) { counts.active += 1 }
            if t.matchesFilter(.paused) { counts.paused += 1 }
            if t.matchesFilter(.completed) { counts.completed += 1 }
            if t.matchesFilter(.failed) { counts.failed += 1 }
            if t.matchesFilter(.torrents) { counts.torrents += 1 }
            if t.matchesFilter(.hls) { counts.hls += 1 }
            if t.matchesFilter(.dash) { counts.dash += 1 }
            if t.matchesFilter(.liveRecordings) { counts.liveRecordings += 1 }
            if t.matchesFilter(.archived) { counts.archived += 1 }
        }

        XCTAssertEqual(counts.count(for: .paused), 1)
        XCTAssertEqual(counts.count(for: .completed), 2) // completedTransfer, archivedTransfer
        XCTAssertEqual(counts.count(for: .torrents), 1)
        XCTAssertEqual(counts.count(for: .hls), 1)
        XCTAssertEqual(counts.count(for: .dash), 1)
        XCTAssertEqual(counts.count(for: .liveRecordings), 1)
        XCTAssertEqual(counts.count(for: .archived), 1)
    }

    // MARK: - 2. Sorting & Grouping Tests

    func testSortingAndGroupingOptions() throws {
        let t1 = UnifiedTransfer(
            id: "1",
            name: "B_Alpha",
            type: .http,
            state: .downloading,
            completedBytes: 100,
            totalBytes: 1000,
            progressFraction: 0.1,
            downloadSpeedBytesPerSecond: 100_000,
            destinationURL: tempDir.appendingPathComponent("B_Alpha.mp4"),
            source: "https://alpha.com/video.mp4",
            createdAt: Date().addingTimeInterval(-3600)
        )
        let t2 = UnifiedTransfer(
            id: "2",
            name: "A_Beta",
            type: .torrent,
            state: .downloading,
            completedBytes: 900,
            totalBytes: 1000,
            progressFraction: 0.9,
            downloadSpeedBytesPerSecond: 500_000,
            destinationURL: tempDir.appendingPathComponent("A_Beta.mkv"),
            source: "https://beta.org/film.mkv",
            createdAt: Date()
        )

        // Sorting by speed
        let speedSorted = DownloadManagerViewModel.sortTransfers([t1, t2], by: .speedDesc)
        XCTAssertEqual(speedSorted.first?.id, "2") // 500 KB/s > 100 KB/s

        // Sorting by duration / ETA
        let durationSorted = DownloadManagerViewModel.sortTransfers([t1, t2], by: .durationDesc)
        XCTAssertEqual(durationSorted.first?.id, "1") // 900 bytes remaining at 100KB/s takes longer than 100 bytes at 500KB/s

        // Sorting by name
        let nameSorted = DownloadManagerViewModel.sortTransfers([t1, t2], by: .nameAsc)
        XCTAssertEqual(nameSorted.first?.id, "2") // A_Beta < B_Alpha

        // Grouping by type
        let typeGroups = DownloadManagerViewModel.groupTransfers([t1, t2], by: .type)
        XCTAssertEqual(typeGroups.count, 2)
        XCTAssertTrue(typeGroups.contains { $0.key == "HTTP" })
        XCTAssertTrue(typeGroups.contains { $0.key == "TORRENT" })

        // Grouping by format
        let formatGroups = DownloadManagerViewModel.groupTransfers([t1, t2], by: .format)
        XCTAssertEqual(formatGroups.count, 2)
        XCTAssertTrue(formatGroups.contains { $0.key == "MP4" })
        XCTAssertTrue(formatGroups.contains { $0.key == "MKV" })

        // Grouping by domain
        let domainGroups = DownloadManagerViewModel.groupTransfers([t1, t2], by: .domain)
        XCTAssertEqual(domainGroups.count, 2)
        XCTAssertTrue(domainGroups.contains { $0.key == "alpha.com" })
        XCTAssertTrue(domainGroups.contains { $0.key == "beta.org" })
    }

    // MARK: - 3. Folder Management & Smart Folders Tests

    func testFolderManagementAndSmartFolders() async throws {
        let history = LIDPlaybackHistoryStore(storageURL: storageDir.appendingPathComponent("hist.json"))
        let store = await MainActor.run {
            LIDLibraryStore(storageDirectory: storageDir, historyStore: history)
        }

        await MainActor.run {
            // Verify default smart folders exist
            let smartFolders = store.folders.filter(\.isSmartFolder)
            XCTAssertEqual(smartFolders.count, 4)
            XCTAssertTrue(smartFolders.contains { $0.name == "Videos > 1GB" })
            XCTAssertTrue(smartFolders.contains { $0.name == "Torrents" })
            XCTAssertTrue(smartFolders.contains { $0.name == "Live Recordings" })
            XCTAssertTrue(smartFolders.contains { $0.name == "Recent Downloads" })

            // Create custom user folder
            let parentFolder = store.createFolder(name: "Movies")
            XCTAssertEqual(parentFolder.name, "Movies")
            XCTAssertNil(parentFolder.parentID)

            // Nested folder
            let childFolder = store.createFolder(name: "Sci-Fi", parentID: parentFolder.id)
            XCTAssertEqual(childFolder.parentID, parentFolder.id)

            // Add item to folder
            let itemPath = "/path/to/movie.mp4"
            store.addItemToFolder(folderID: childFolder.id, itemPath: itemPath)
            let updatedChild = store.folders.first { $0.id == childFolder.id }
            XCTAssertTrue(updatedChild?.itemPaths.contains(itemPath) ?? false)

            // Move item between folders
            store.moveItem(itemPath: itemPath, fromFolderID: childFolder.id, toFolderID: parentFolder.id)
            let afterMoveChild = store.folders.first { $0.id == childFolder.id }
            let afterMoveParent = store.folders.first { $0.id == parentFolder.id }
            XCTAssertFalse(afterMoveChild?.itemPaths.contains(itemPath) ?? true)
            XCTAssertTrue(afterMoveParent?.itemPaths.contains(itemPath) ?? false)

            // Rename folder
            store.renameFolder(id: parentFolder.id, newName: "Cinema")
            XCTAssertEqual(store.folders.first { $0.id == parentFolder.id }?.name, "Cinema")

            // Delete folder
            store.deleteFolder(id: parentFolder.id)
            XCTAssertFalse(store.folders.contains { $0.id == parentFolder.id })
            // Orphaned child becomes root folder
            XCTAssertNil(store.folders.first { $0.id == childFolder.id }?.parentID)
        }
    }

    // MARK: - 4. Metadata Enrichment & Editing Tests

    func testMetadataEditing() async throws {
        let history = LIDPlaybackHistoryStore(storageURL: storageDir.appendingPathComponent("hist.json"))
        let store = await MainActor.run {
            LIDLibraryStore(storageDirectory: storageDir, historyStore: history)
        }

        let mediaFile = tempDir.appendingPathComponent("test_track.mp3")
        try "audio_bytes".write(to: mediaFile, atomically: true, encoding: .utf8)
        _ = await store.scanLibrary(in: tempDir)

        await MainActor.run {
            store.updateItemMetadata(
                url: mediaFile,
                tags: ["Rock", "Favorites"],
                notes: "Great guitar solo",
                customTitle: "Epic Solo"
            )

            let item = store.mediaItems.first { $0.url.lastPathComponent == "test_track.mp3" }
            XCTAssertEqual(item?.title, "Epic Solo")
            XCTAssertEqual(item?.tags, ["Rock", "Favorites"])
            XCTAssertEqual(item?.notes, "Great guitar solo")
        }
    }

    // MARK: - 5. File Safety: Conflict Resolution, Safe Trash & Storage Breakdown

    func testFileConflictResolutionPolicies() throws {
        let existingFile = tempDir.appendingPathComponent("sample.txt")
        try "initial".write(to: existingFile, atomically: true, encoding: .utf8)

        // Policy: autoRename (.renameWithNumber)
        let autoRenamed = FileConflictResolver.resolveDestinationURL(
            desiredFilename: "sample.txt",
            directory: tempDir,
            policy: .autoRename
        )
        XCTAssertNotNil(autoRenamed)
        XCTAssertEqual(autoRenamed?.lastPathComponent, "sample (1).txt")

        // Policy: overwrite (.overwritePrompt)
        let overwritten = FileConflictResolver.resolveDestinationURL(
            desiredFilename: "sample.txt",
            directory: tempDir,
            policy: .overwrite
        )
        XCTAssertEqual(overwritten?.lastPathComponent, "sample.txt")

        // Policy: skip
        let skipped = FileConflictResolver.resolveDestinationURL(
            desiredFilename: "sample.txt",
            directory: tempDir,
            policy: .skip
        )
        XCTAssertNil(skipped)
    }

    func testSafeTrashAndRecovery() async throws {
        let history = LIDPlaybackHistoryStore(storageURL: storageDir.appendingPathComponent("hist.json"))
        let store = await MainActor.run {
            LIDLibraryStore(storageDirectory: storageDir, historyStore: history)
        }

        let file = tempDir.appendingPathComponent("delete_me.mp4")
        try "video_content".write(to: file, atomically: true, encoding: .utf8)
        _ = await store.scanLibrary(in: tempDir)

        try await MainActor.run {
            // Delete with moveToTrash = true
            try store.deleteMediaFile(url: file, moveToTrash: true)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
            XCTAssertEqual(store.trashItems.count, 1)

            guard let trashItem = store.trashItems.first else {
                XCTFail("Trash item not found")
                return
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: trashItem.trashURL.path))

            // Restore from trash
            try store.restoreFromTrash(item: trashItem)
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
            XCTAssertEqual(store.trashItems.count, 0)

            // Delete again and empty trash
            try store.deleteMediaFile(url: file, moveToTrash: true)
            XCTAssertEqual(store.trashItems.count, 1)
            try store.emptyTrash()
            XCTAssertEqual(store.trashItems.count, 0)
        }
    }

    func testStorageBreakdownAndOrphanDetection() async throws {
        let videoFile = tempDir.appendingPathComponent("vid.mp4")
        let audioFile = tempDir.appendingPathComponent("aud.mp3")
        let torrentFile = tempDir.appendingPathComponent("linux.torrent")
        let scratchFile = tempDir.appendingPathComponent("part1.tmp")
        let orphanFile = tempDir.appendingPathComponent("unknown_orphan.bin")

        try "video".write(to: videoFile, atomically: true, encoding: .utf8)
        try "audio".write(to: audioFile, atomically: true, encoding: .utf8)
        try "torrent".write(to: torrentFile, atomically: true, encoding: .utf8)
        try "scratch".write(to: scratchFile, atomically: true, encoding: .utf8)
        try "orphan".write(to: orphanFile, atomically: true, encoding: .utf8)

        let history = LIDPlaybackHistoryStore(storageURL: storageDir.appendingPathComponent("hist.json"))
        let store = await MainActor.run {
            LIDLibraryStore(storageDirectory: storageDir, historyStore: history)
        }

        let breakdown = await store.calculateStorageBreakdown(in: tempDir)
        XCTAssertGreaterThan(breakdown.videoBytes, 0)
        XCTAssertGreaterThan(breakdown.audioBytes, 0)
        XCTAssertGreaterThan(breakdown.torrentBytes, 0)
        XCTAssertGreaterThan(breakdown.scratchBytes, 0)
        XCTAssertGreaterThan(breakdown.totalBytes, 0)

        // Known transfers contains vid.mp4 and aud.mp3, but not orphanFile
        let known = [
            UnifiedTransfer(id: "1", name: "vid.mp4", type: .http, state: .completed, completedBytes: 5, destinationURL: videoFile, source: "http://example.com"),
            UnifiedTransfer(id: "2", name: "aud.mp3", type: .http, state: .completed, completedBytes: 5, destinationURL: audioFile, source: "http://example.com"),
            UnifiedTransfer(id: "3", name: "linux.torrent", type: .torrent, state: .seeding, completedBytes: 7, destinationURL: torrentFile, source: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567")
        ]

        let orphans = await store.detectOrphanFiles(in: tempDir, knownTransfers: known)
        XCTAssertTrue(orphans.contains(where: { $0.lastPathComponent == "unknown_orphan.bin" }))

        // Cleanup orphan
        let freed = try await MainActor.run {
            try store.cleanupOrphanFiles(urls: orphans.filter { $0.lastPathComponent == "unknown_orphan.bin" })
        }
        XCTAssertGreaterThan(freed, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanFile.path))
    }

    // MARK: - 6. Bulk Operations Tests

    func testBulkOperations() async throws {
        let history = LIDPlaybackHistoryStore(storageURL: storageDir.appendingPathComponent("hist.json"))
        let store = await MainActor.run {
            LIDLibraryStore(storageDirectory: storageDir, historyStore: history)
        }

        let f1 = tempDir.appendingPathComponent("b1.mp4")
        let f2 = tempDir.appendingPathComponent("b2.mp4")
        try "1".write(to: f1, atomically: true, encoding: .utf8)
        try "2".write(to: f2, atomically: true, encoding: .utf8)

        _ = await store.scanLibrary(in: tempDir)

        await MainActor.run {
            let folder = store.createFolder(name: "BulkFolder")
            store.bulkMoveToFolder(itemPaths: [f1.path, f2.path], toFolderID: folder.id)
            let updatedFolder = store.folders.first { $0.id == folder.id }
            XCTAssertEqual(updatedFolder?.itemPaths.count, 2)

            store.bulkAddTag(itemPaths: [f1.path, f2.path], tag: "Series")
            let item1 = store.mediaItems.first { $0.url.path == f1.path }
            let item2 = store.mediaItems.first { $0.url.path == f2.path }
            XCTAssertTrue(item1?.tags.contains("Series") ?? false)
            XCTAssertTrue(item2?.tags.contains("Series") ?? false)
        }
    }
}
