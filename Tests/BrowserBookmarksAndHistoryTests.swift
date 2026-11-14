import XCTest
@testable import DM_Reverse_engineering

final class BrowserBookmarksAndHistoryTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("BookmarksHistoryTests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    // MARK: - Bookmarks Tests

    func testBookmarkCRUDAndFolderHierarchy() {
        let storageURL = tempDirectory.appendingPathComponent("test_bookmarks.json")
        let store = BrowserBookmarkStore(customStorageURL: storageURL)

        // Create root folders
        let workFolder = store.createFolder(title: "Work")
        let personalFolder = store.createFolder(title: "Personal")

        // Create subfolder
        let devFolder = store.createFolder(title: "Development", parentFolderID: workFolder.id)

        XCTAssertEqual(store.subfolders(in: nil).count, 2)
        XCTAssertEqual(store.subfolders(in: workFolder.id).count, 1)
        XCTAssertEqual(store.subfolders(in: workFolder.id).first?.title, "Development")

        // Add bookmarks
        let b1 = store.addBookmark(title: "GitHub", url: URL(string: "https://github.com")!, folderID: devFolder.id)
        let b2 = store.addBookmark(title: "Google", url: URL(string: "https://google.com")!, folderID: personalFolder.id)
        _ = store.addBookmark(title: "Apple Developer", url: URL(string: "https://developer.apple.com")!, folderID: devFolder.id)

        XCTAssertTrue(store.isBookmarked(url: URL(string: "https://github.com")!))
        XCTAssertFalse(store.isBookmarked(url: URL(string: "https://nonexistent.com")!))

        let devBookmarks = store.bookmarks(in: devFolder.id)
        XCTAssertEqual(devBookmarks.count, 2)

        // Test sorting
        let sortedAZ = store.sortedBookmarks(in: devFolder.id, by: .titleAsc)
        XCTAssertEqual(sortedAZ.first?.title, "Apple Developer")
        XCTAssertEqual(sortedAZ.last?.title, "GitHub")

        // Test search
        let searchResults = store.search(query: "git")
        XCTAssertEqual(searchResults.count, 1)
        XCTAssertEqual(searchResults.first?.id, b1.id)

        // Test update
        store.updateBookmark(id: b2.id, title: "Google Search", url: URL(string: "https://google.com/search")!, folderID: personalFolder.id)
        XCTAssertEqual(store.bookmark(for: URL(string: "https://google.com/search")!)?.title, "Google Search")

        // Test recursive folder deletion
        store.deleteFolder(id: workFolder.id)
        XCTAssertEqual(store.subfolders(in: workFolder.id).count, 0)
        XCTAssertEqual(store.bookmarks(in: devFolder.id).count, 0)
        XCTAssertFalse(store.isBookmarked(url: URL(string: "https://github.com")!))

        // Reload from disk to verify persistence
        let reloadedStore = BrowserBookmarkStore(customStorageURL: storageURL)
        XCTAssertTrue(reloadedStore.isBookmarked(url: URL(string: "https://google.com/search")!))
        XCTAssertEqual(reloadedStore.subfolders(in: nil).count, 1)
    }

    // MARK: - History Tests & Incognito Invariant

    func testHistoryRecordingAndIncognitoExclusion() {
        let storageURL = tempDirectory.appendingPathComponent("test_history.json")
        let store = BrowserHistoryStore(customStorageURL: storageURL)

        let normalURL1 = URL(string: "https://swift.org")!
        let normalURL2 = URL(string: "https://news.ycombinator.com")!
        let incognitoURL = URL(string: "https://secret-bank.example.com")!

        // Normal visits are recorded
        store.recordVisit(url: normalURL1, title: "Swift.org", isIncognito: false)
        store.recordVisit(url: normalURL2, title: "Hacker News", isIncognito: false)

        // Second visit to swift.org updates visit count
        store.recordVisit(url: normalURL1, title: "Swift Programming Language", isIncognito: false)

        // INCOGNITO INVARIANT: Must strictly NOT be recorded
        store.recordVisit(url: incognitoURL, title: "Secret Bank", isIncognito: true)

        XCTAssertEqual(store.allEntries.count, 2, "Incognito visit must not be recorded in persistent history")
        XCTAssertNil(store.allEntries.first(where: { $0.url == incognitoURL }))

        let swiftEntry = store.allEntries.first(where: { $0.url == normalURL1 })
        XCTAssertNotNil(swiftEntry)
        XCTAssertEqual(swiftEntry?.visitCount, 2)
        XCTAssertEqual(swiftEntry?.title, "Swift Programming Language")

        // Test search
        let results = store.searchHistory(query: "hacker")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.url, normalURL2)

        // Test chronological grouping
        let groups = store.groupedChronologically()
        XCTAssertFalse(groups.isEmpty)
        XCTAssertEqual(groups.first?.sectionTitle, "Today")

        // Test delete entry
        if let id = swiftEntry?.id {
            store.deleteEntry(id: id)
            XCTAssertEqual(store.allEntries.count, 1)
        }

        // Test clear all
        store.clearAllHistory()
        XCTAssertEqual(store.allEntries.count, 0)
    }

    // MARK: - Tab Preview Cache Tests & Privacy Invariant

    func testTabPreviewCacheDiskVsIncognito() {
        let previewDir = tempDirectory.appendingPathComponent("TabPreviews")
        let cache = BrowserTabPreviewCache(customCacheDirectoryURL: previewDir)

        let normalTabID = UUID()
        let incognitoTabID = UUID()
        let sampleData = Data([0xDE, 0xAD, 0xBE, 0xEF])

        // Store normal tab preview -> should exist in memory and on disk
        cache.setPreview(sampleData, for: normalTabID, isIncognito: false)
        XCTAssertEqual(cache.preview(for: normalTabID), sampleData)

        let diskFileURL = previewDir.appendingPathComponent("\(normalTabID.uuidString).jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: diskFileURL.path), "Normal preview must be persisted to disk")

        // Store incognito tab preview -> should exist in memory BUT NEVER ON DISK
        cache.setPreview(sampleData, for: incognitoTabID, isIncognito: true)
        XCTAssertEqual(cache.preview(for: incognitoTabID), sampleData, "Must be available in memory while open")

        let incognitoDiskFileURL = previewDir.appendingPathComponent("\(incognitoTabID.uuidString).jpg")
        XCTAssertFalse(FileManager.default.fileExists(atPath: incognitoDiskFileURL.path), "Incognito preview must NEVER be written to disk")

        // Remove on tab close
        cache.removePreview(for: normalTabID)
        XCTAssertNil(cache.preview(for: normalTabID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: diskFileURL.path))

        cache.removePreview(for: incognitoTabID)
        XCTAssertNil(cache.preview(for: incognitoTabID))
    }

    // MARK: - Brave Search Engine & URL Resolver Tests

    func testBraveSearchEngineQueryResolution() {
        let query = "swift download engine"
        let resolved = BrowserURLResolver.resolve(input: query, searchEngine: .brave)

        XCTAssertNotNil(resolved)
        XCTAssertTrue(resolved?.absoluteString.hasPrefix("https://search.brave.com/search?q=") ?? false)
        XCTAssertTrue(resolved?.absoluteString.contains("swift%20download%20engine") ?? false)
    }

    // MARK: - AppSettings Persistence Tests

    func testAppSettingsSearchEnginePersistence() {
        var settings = AppSettings.default
        XCTAssertEqual(settings.browserSearchEngine, .duckDuckGo)

        settings.browserSearchEngine = .brave
        let encoded = try? JSONEncoder().encode(settings)
        XCTAssertNotNil(encoded)

        if let encoded {
            let decoded = try? JSONDecoder().decode(AppSettings.self, from: encoded)
            XCTAssertEqual(decoded?.browserSearchEngine, .brave)
            XCTAssertEqual(decoded?.version, AppSettings.currentVersion)
        }
    }
}
