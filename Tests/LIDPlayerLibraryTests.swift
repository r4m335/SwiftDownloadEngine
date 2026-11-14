import XCTest
@testable import DM_Reverse_engineering

final class LIDPlayerLibraryTests: XCTestCase {

    private var tempDir: URL!
    private var storageDir: URL!

    override func setUp() {
        super.setUp()
        let root = FileManager.default.temporaryDirectory
        tempDir = root.appendingPathComponent("LIDLibTests_\(UUID().uuidString)", isDirectory: true)
        storageDir = root.appendingPathComponent("LIDLibStorage_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        try? FileManager.default.removeItem(at: storageDir)
        super.tearDown()
    }

    // MARK: - 1. Library Scanning & Media Discovery Tests

    func testLibraryScanningDiscoversPlayableMedia() async throws {
        let videoFile = tempDir.appendingPathComponent("sample_movie.mp4")
        let audioFile = tempDir.appendingPathComponent("track01.mp3")
        let docFile = tempDir.appendingPathComponent("readme.txt")
        let zipFile = tempDir.appendingPathComponent("archive.zip")

        try "fake_video_data".write(to: videoFile, atomically: true, encoding: .utf8)
        try "fake_audio_data".write(to: audioFile, atomically: true, encoding: .utf8)
        try "fake_document".write(to: docFile, atomically: true, encoding: .utf8)
        try "fake_zip".write(to: zipFile, atomically: true, encoding: .utf8)

        let history = LIDPlaybackHistoryStore(storageURL: storageDir.appendingPathComponent("hist.json"))
        let store = await MainActor.run {
            LIDLibraryStore(storageDirectory: storageDir, historyStore: history)
        }

        let items = await store.scanLibrary(in: tempDir)
        XCTAssertEqual(items.count, 2)

        let paths = items.map(\.url.lastPathComponent)
        XCTAssertTrue(paths.contains("sample_movie.mp4"))
        XCTAssertTrue(paths.contains("track01.mp3"))
        XCTAssertFalse(paths.contains("readme.txt"))
        XCTAssertFalse(paths.contains("archive.zip"))

        let movieItem = items.first { $0.url.lastPathComponent == "sample_movie.mp4" }
        XCTAssertEqual(movieItem?.mediaType, .video)

        let audioItem = items.first { $0.url.lastPathComponent == "track01.mp3" }
        XCTAssertEqual(audioItem?.mediaType, .audio)
    }

    // MARK: - 2. Continue Watching & History Integration

    func testContinueWatchingFilter() async throws {
        let videoFile = tempDir.appendingPathComponent("series_ep1.mp4").resolvingSymlinksInPath().standardizedFileURL
        try "movie_bytes".write(to: videoFile, atomically: true, encoding: .utf8)

        let historyURL = storageDir.appendingPathComponent("hist.json")
        let history = LIDPlaybackHistoryStore(storageURL: historyURL)

        // Record 50% watched
        await history.recordPosition(
            mediaIdentifier: videoFile.absoluteString,
            title: "series_ep1",
            positionSeconds: 50.0,
            durationSeconds: 100.0
        )

        let store = await MainActor.run {
            LIDLibraryStore(storageDirectory: storageDir, historyStore: history)
        }

        _ = await store.scanLibrary(in: tempDir)
        let continueWatching = await store.continueWatchingItems()
        XCTAssertEqual(continueWatching.count, 1)
        XCTAssertEqual(continueWatching.first?.title, "series_ep1")
        XCTAssertEqual(continueWatching.first?.progressFraction ?? 0, 0.5, accuracy: 0.01)

        // Now simulate completing playback (98%)
        await history.recordPosition(
            mediaIdentifier: videoFile.absoluteString,
            title: "series_ep1",
            positionSeconds: 98.0,
            durationSeconds: 100.0
        )

        _ = await store.scanLibrary(in: tempDir)
        let completedCW = await store.continueWatchingItems()
        XCTAssertTrue(completedCW.isEmpty, "Completed items must not appear in Continue Watching")
    }

    // MARK: - 3. Favorites Persistence

    func testFavoritesAddAndPersistence() async throws {
        let videoFile = tempDir.appendingPathComponent("star_video.mov")
        try "data".write(to: videoFile, atomically: true, encoding: .utf8)

        let history = LIDPlaybackHistoryStore(storageURL: storageDir.appendingPathComponent("hist.json"))
        let store = await MainActor.run {
            LIDLibraryStore(storageDirectory: storageDir, historyStore: history)
        }

        let items = await store.scanLibrary(in: tempDir)
        XCTAssertEqual(items.count, 1)
        let item = items[0]

        let isFavInitial = await store.isFavorite(mediaIdentifier: item.url.path)
        XCTAssertFalse(isFavInitial)

        await store.toggleFavorite(for: item)
        let isFavAfter = await store.isFavorite(mediaIdentifier: item.url.path)
        XCTAssertTrue(isFavAfter)

        let favItems = await store.favoriteItems()
        XCTAssertEqual(favItems.count, 1)

        // Instantiate fresh store to verify persistence
        let store2 = await MainActor.run {
            LIDLibraryStore(storageDirectory: storageDir, historyStore: history)
        }
        _ = await store2.scanLibrary(in: tempDir)
        let isFavPersisted = await store2.isFavorite(mediaIdentifier: item.url.path)
        XCTAssertTrue(isFavPersisted)

        // Toggle off
        await store2.toggleFavorite(for: item)
        let isFavCleared = await store2.isFavorite(mediaIdentifier: item.url.path)
        XCTAssertFalse(isFavCleared)
    }

    // MARK: - 4. Playlists Management & Reordering

    func testPlaylistCreationAndReordering() async throws {
        let vid1 = tempDir.appendingPathComponent("clip1.mp4")
        let vid2 = tempDir.appendingPathComponent("clip2.mp4")
        let vid3 = tempDir.appendingPathComponent("clip3.mp4")
        try "1".write(to: vid1, atomically: true, encoding: .utf8)
        try "2".write(to: vid2, atomically: true, encoding: .utf8)
        try "3".write(to: vid3, atomically: true, encoding: .utf8)

        let history = LIDPlaybackHistoryStore(storageURL: storageDir.appendingPathComponent("hist.json"))
        let store = await MainActor.run {
            LIDLibraryStore(storageDirectory: storageDir, historyStore: history)
        }

        let items = await store.scanLibrary(in: tempDir)
        let item1 = items.first { $0.url.lastPathComponent == "clip1.mp4" }!
        let item2 = items.first { $0.url.lastPathComponent == "clip2.mp4" }!
        let item3 = items.first { $0.url.lastPathComponent == "clip3.mp4" }!

        // Create
        let playlist = await store.createPlaylist(name: "Workout Mix")
        XCTAssertEqual(playlist.name, "Workout Mix")

        // Add items
        await store.addItemToPlaylist(playlistID: playlist.id, item: item1)
        await store.addItemToPlaylist(playlistID: playlist.id, item: item2)
        await store.addItemToPlaylist(playlistID: playlist.id, item: item3)

        let current = await store.playlists.first { $0.id == playlist.id }!
        XCTAssertEqual(current.itemPaths, [item1.url.path, item2.url.path, item3.url.path])

        // Rename
        await store.renamePlaylist(id: playlist.id, newName: "Cardio Mix")
        let renamedName = await store.playlists.first?.name
        XCTAssertEqual(renamedName, "Cardio Mix")

        // Remove one
        await store.removeItemFromPlaylist(playlistID: playlist.id, itemPath: item2.url.path)
        let pathsAfterRemove = await store.playlists.first?.itemPaths
        XCTAssertEqual(pathsAfterRemove, [item1.url.path, item3.url.path])

        // Reorder
        await store.reorderPlaylist(playlistID: playlist.id, fromIndices: IndexSet(integer: 1), toOffset: 0)
        let pathsAfterReorder = await store.playlists.first?.itemPaths
        XCTAssertEqual(pathsAfterReorder, [item3.url.path, item1.url.path])

        // Delete playlist
        await store.deletePlaylist(id: playlist.id)
        let playlistsCount = await store.playlists.count
        XCTAssertEqual(playlistsCount, 0)
    }

    // MARK: - 5. File Operations: Rename and Delete

    func testFileRenameAndUpdateStores() async throws {
        let vid = tempDir.appendingPathComponent("orig_video.mp4")
        try "data".write(to: vid, atomically: true, encoding: .utf8)

        let history = LIDPlaybackHistoryStore(storageURL: storageDir.appendingPathComponent("hist.json"))
        let store = await MainActor.run {
            LIDLibraryStore(storageDirectory: storageDir, historyStore: history)
        }

        let items = await store.scanLibrary(in: tempDir)
        let item = items[0]
        await store.toggleFavorite(for: item)
        let playlist = await store.createPlaylist(name: "Favorites Playlist")
        await store.addItemToPlaylist(playlistID: playlist.id, item: item)

        // Rename
        let newURL = try await store.renameMediaFile(url: item.url, newFileName: "renamed_video")
        XCTAssertTrue(FileManager.default.fileExists(atPath: newURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: vid.path))

        // Verify favorite updated to new path
        let isFavNew = await store.isFavorite(mediaIdentifier: newURL.path)
        let isFavOld = await store.isFavorite(mediaIdentifier: vid.path)
        XCTAssertTrue(isFavNew)
        XCTAssertFalse(isFavOld)

        // Verify playlist updated to new path
        let pl = await store.playlists.first!
        XCTAssertTrue(pl.itemPaths.contains(newURL.path))
        XCTAssertFalse(pl.itemPaths.contains(vid.path))

        // Now test deleting file
        try await store.deleteMediaFile(url: newURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: newURL.path))
        let isFavAfterDelete = await store.isFavorite(mediaIdentifier: newURL.path)
        XCTAssertFalse(isFavAfterDelete)

        let plAfterDelete = await store.playlists.first!
        XCTAssertFalse(plAfterDelete.itemPaths.contains(newURL.path))
    }

    // MARK: - 6. Media Inspector Tests

    func testMediaInspectorMetadata() async throws {
        let vid = tempDir.appendingPathComponent("sample_inspect.mp4")
        let dummyContent = "Test inspect payload for file size verification."
        try dummyContent.write(to: vid, atomically: true, encoding: .utf8)

        let inspector = LIDMediaInspector()
        let detail = await inspector.inspect(url: vid)

        XCTAssertEqual(detail.fileName, "sample_inspect.mp4")
        XCTAssertEqual(detail.fileURL, vid)
        XCTAssertEqual(detail.containerFormat, "MP4 Media")
        XCTAssertEqual(detail.fileSizeBytes, Int64(dummyContent.utf8.count))
        XCTAssertFalse(detail.formattedFileSize.isEmpty)
    }
}
