import XCTest
@testable import DownloadEngineKit

@MainActor
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

    // MARK: - Bookmark URL Normalization & Duplicate Detection

    func testBookmarkDuplicateDetectionAndURLNormalization() {
        let storageURL = tempDirectory.appendingPathComponent("test_dup_bookmarks.json")
        let store = BrowserBookmarkStore(customStorageURL: storageURL)

        let originalURL = URL(string: "https://apple.com/iphone/")!
        store.addBookmark(title: "Apple iPhone", url: originalURL)

        // Trailing slash difference
        let trailingSlashVariant = URL(string: "https://apple.com/iphone")!
        XCTAssertTrue(store.isBookmarked(url: trailingSlashVariant))
        XCTAssertEqual(store.findDuplicate(for: trailingSlashVariant)?.title, "Apple iPhone")

        // Host casing difference
        let uppercaseVariant = URL(string: "HTTPS://APPLE.COM/iphone/")!
        XCTAssertTrue(store.isBookmarked(url: uppercaseVariant))
        XCTAssertEqual(store.findDuplicate(for: uppercaseVariant)?.title, "Apple iPhone")

        // Different path -> not duplicate
        let differentURL = URL(string: "https://apple.com/mac")!
        XCTAssertFalse(store.isBookmarked(url: differentURL))
        XCTAssertNil(store.findDuplicate(for: differentURL))
    }

    // MARK: - Folder Movement, Rename & Circular Hierarchy Protection

    func testFolderRenameMovementAndCircularProtection() throws {
        let storageURL = tempDirectory.appendingPathComponent("test_folder_hierarchy.json")
        let store = BrowserBookmarkStore(customStorageURL: storageURL)

        let rootA = store.createFolder(title: "Root A")
        let rootB = store.createFolder(title: "Root B")
        let childB1 = store.createFolder(title: "Child B1", parentFolderID: rootB.id)
        let subChildB2 = store.createFolder(title: "SubChild B2", parentFolderID: childB1.id)

        // Test rename
        store.renameFolder(id: rootA.id, newTitle: "Engineering")
        XCTAssertEqual(store.allFolders.first(where: { $0.id == rootA.id })?.title, "Engineering")

        // Moving to self must be disallowed
        XCTAssertFalse(store.canMoveFolder(id: rootB.id, toParentID: rootB.id))

        // Moving into descendant (circular) must be disallowed
        XCTAssertFalse(store.canMoveFolder(id: rootB.id, toParentID: childB1.id))
        XCTAssertFalse(store.canMoveFolder(id: rootB.id, toParentID: subChildB2.id))

        // Moving to unrelated or ancestor must be allowed
        XCTAssertTrue(store.canMoveFolder(id: childB1.id, toParentID: rootA.id))
        XCTAssertTrue(store.canMoveFolder(id: childB1.id, toParentID: nil))

        // Throw on circular move
        XCTAssertThrowsError(try store.moveFolder(id: rootB.id, toParentID: subChildB2.id)) { error in
            XCTAssertEqual(error as? BrowserBookmarkError, BrowserBookmarkError.circularFolderReference)
        }

        // Valid move
        try store.moveFolder(id: childB1.id, toParentID: rootA.id)
        XCTAssertEqual(store.allFolders.first(where: { $0.id == childB1.id })?.parentFolderID, rootA.id)
    }

    // MARK: - Netscape Bookmark HTML Export & Import

    func testBookmarkNetscapeHTMLExport() {
        let storageURL = tempDirectory.appendingPathComponent("test_export_bookmarks.json")
        let store = BrowserBookmarkStore(customStorageURL: storageURL)

        let folder = store.createFolder(title: "Development & Tools")
        store.addBookmark(title: "Google <Search> & More", url: URL(string: "https://google.com?q=test&lang=en")!, folderID: folder.id)

        let html = BrowserBookmarkExporter.exportToHTML(store: store)

        XCTAssertTrue(html.contains("<!DOCTYPE NETSCAPE-Bookmark-file-1>"))
        XCTAssertTrue(html.contains("<TITLE>Bookmarks</TITLE>"))
        XCTAssertTrue(html.contains("<H1>Bookmarks</H1>"))
        XCTAssertTrue(html.contains("<DL><p>"))
        XCTAssertTrue(html.contains("Development &amp; Tools"))
        XCTAssertTrue(html.contains("Google &lt;Search&gt; &amp; More"))
        XCTAssertTrue(html.contains("https://google.com?q=test&amp;lang=en"))
    }

    func testBookmarkNetscapeHTMLImport() {
        let storageURL = tempDirectory.appendingPathComponent("test_import_bookmarks.json")
        let store = BrowserBookmarkStore(customStorageURL: storageURL)

        let rawHTML = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <TITLE>Bookmarks</TITLE>
        <H1>Bookmarks</H1>
        <DL><p>
            <DT><H3 ADD_DATE="1600000000">Imported Dev</H3>
            <DL><p>
                <DT><A HREF="https://swift.org" ADD_DATE="1600000001">Swift Language</A>
                <DT><A HREF="https://rust-lang.org">Rust &amp; Systems</A>
            </DL><p>
            <DT><A HREF="https://www.wikipedia.org">Wikipedia</A>
            <DT><A HREF="javascript:alert(1)">Invalid Scheme Script</A>
        </DL><p>
        """

        let summary = BrowserBookmarkImporter.importHTMLString(rawHTML, store: store, skipDuplicates: true)

        XCTAssertEqual(summary.totalFound, 4)
        XCTAssertEqual(summary.importedFoldersCount, 1)
        XCTAssertEqual(summary.importedBookmarksCount, 2) // swift.org, rust-lang.org. www.wikipedia.org is default duplicate
        XCTAssertEqual(summary.duplicateCount, 1) // www.wikipedia.org
        XCTAssertEqual(summary.skippedCount, 2) // 1 invalid javascript: scheme + 1 duplicate wikipedia

        XCTAssertTrue(store.isBookmarked(url: URL(string: "https://swift.org")!))
        XCTAssertTrue(store.isBookmarked(url: URL(string: "https://rust-lang.org")!))
        XCTAssertEqual(store.allBookmarks.first(where: { $0.url.absoluteString == "https://rust-lang.org" })?.title, "Rust & Systems")
    }

    func testBookmarkRoundTripExportAndImport() {
        let storeAURL = tempDirectory.appendingPathComponent("storeA.json")
        let storeBURL = tempDirectory.appendingPathComponent("storeB.json")

        let storeA = BrowserBookmarkStore(customStorageURL: storeAURL)
        for b in storeA.allBookmarks { storeA.deleteBookmark(id: b.id) }
        let f1 = storeA.createFolder(title: "Favorites")
        storeA.addBookmark(title: "GitHub", url: URL(string: "https://github.com")!, folderID: f1.id)
        storeA.addBookmark(title: "Substack", url: URL(string: "https://substack.com")!, folderID: nil)

        let exportedHTML = BrowserBookmarkExporter.exportToHTML(store: storeA)

        // Fresh store B (clear default bookmarks for clean comparison)
        let storeB = BrowserBookmarkStore(customStorageURL: storeBURL)
        for b in storeB.allBookmarks { storeB.deleteBookmark(id: b.id) }

        let summary = BrowserBookmarkImporter.importHTMLString(exportedHTML, store: storeB, skipDuplicates: false)

        XCTAssertEqual(summary.importedBookmarksCount, 2)
        XCTAssertEqual(summary.importedFoldersCount, 1)
        XCTAssertTrue(storeB.isBookmarked(url: URL(string: "https://github.com")!))
        XCTAssertTrue(storeB.isBookmarked(url: URL(string: "https://substack.com")!))
    }

    // MARK: - Corrupt JSON Recovery Tests

    func testHistoryCorruptFileRecovery() {
        let storageURL = tempDirectory.appendingPathComponent("corrupt_history.json")
        try? "INVALID_JSON_CORRUPTED_BYTES{{{".data(using: .utf8)?.write(to: storageURL)

        let store = BrowserHistoryStore(customStorageURL: storageURL)
        XCTAssertEqual(store.allEntries.count, 0, "Corrupt history file must load cleanly as empty")

        // Verify that the corrupt file was renamed
        let files = (try? FileManager.default.contentsOfDirectory(atPath: tempDirectory.path)) ?? []
        XCTAssertTrue(files.contains(where: { $0.contains("corrupt_history.corrupt") }), "Corrupt file should be backed up with timestamp suffix")
    }

    func testBookmarkCorruptFileRecovery() {
        let storageURL = tempDirectory.appendingPathComponent("corrupt_bookmarks.json")
        try? "NOT_A_VALID_BOOKMARK_JSON_PAYLOAD".data(using: .utf8)?.write(to: storageURL)

        let store = BrowserBookmarkStore(customStorageURL: storageURL)
        // Corrupt file recovered: default initial bookmarks restored
        XCTAssertFalse(store.allBookmarks.isEmpty)
        XCTAssertTrue(store.allBookmarks.contains(where: { $0.title == "DuckDuckGo" }))

        let files = (try? FileManager.default.contentsOfDirectory(atPath: tempDirectory.path)) ?? []
        XCTAssertTrue(files.contains(where: { $0.contains("corrupt_bookmarks.corrupt") }))
    }

    // MARK: - History Time-Range Selective Clearing

    func testHistoryTimeRangeClearing() {
        let storageURL = tempDirectory.appendingPathComponent("test_time_clear_history.json")
        let store = BrowserHistoryStore(customStorageURL: storageURL)

        let calendar = Calendar.current
        let now = Date()
        let halfHourAgo = calendar.date(byAdding: .minute, value: -30, to: now)!
        let threeHoursAgo = calendar.date(byAdding: .hour, value: -3, to: now)!
        let twoDaysAgo = calendar.date(byAdding: .day, value: -2, to: now)!

        let entry1 = BrowserHistoryEntry(title: "Recent", url: URL(string: "https://recent.com")!, visitDate: halfHourAgo)
        let entry2 = BrowserHistoryEntry(title: "Earlier Today", url: URL(string: "https://earlier.com")!, visitDate: threeHoursAgo)
        let entry3 = BrowserHistoryEntry(title: "Old", url: URL(string: "https://old.com")!, visitDate: twoDaysAgo)

        // Seed entries directly via persistence payload
        if let data = try? JSONEncoder().encode([entry1, entry2, entry3]) {
            try? data.write(to: storageURL)
        }
        store.load()
        XCTAssertEqual(store.allEntries.count, 3)

        // 1. Clear last hour -> entry1 removed
        let oneHourCutoff = calendar.date(byAdding: .hour, value: -1, to: now)!
        store.clearHistory(since: oneHourCutoff)
        XCTAssertEqual(store.allEntries.count, 2)
        XCTAssertFalse(store.allEntries.contains(where: { $0.title == "Recent" }))
        XCTAssertTrue(store.allEntries.contains(where: { $0.title == "Earlier Today" }))

        // 2. Clear today -> entry2 removed, entry3 remains
        let startOfToday = calendar.startOfDay(for: now)
        store.clearHistory(since: startOfToday)
        XCTAssertEqual(store.allEntries.count, 1)
        XCTAssertEqual(store.allEntries.first?.title, "Old")

        // 3. Clear all -> entry3 removed
        store.clearAllHistory()
        XCTAssertEqual(store.allEntries.count, 0)
    }

    // MARK: - Desktop Mode Per-Tab State Retention

    func testDesktopModePerTabStateRetention() {
        var manager = BrowserTabManager()
        let tab1ID = manager.tabs[0].id
        XCTAssertFalse(manager.activeTab?.isDesktopMode ?? true)

        let tab2ID = manager.createTab(select: true, isDesktopMode: true)
        XCTAssertTrue(manager.activeTab?.isDesktopMode ?? false)

        _ = manager.selectTab(tab1ID)
        XCTAssertFalse(manager.activeTab?.isDesktopMode ?? true)

        _ = manager.selectTab(tab2ID)
        XCTAssertTrue(manager.activeTab?.isDesktopMode ?? false)
    }

    // MARK: - Store Change Notification Broadcast

    func testStoreChangeNotificationsBroadcast() {
        let bURL = tempDirectory.appendingPathComponent("notif_b.json")
        let hURL = tempDirectory.appendingPathComponent("notif_h.json")

        let bStore = BrowserBookmarkStore(customStorageURL: bURL)
        let hStore = BrowserHistoryStore(customStorageURL: hURL)

        let bExpectation = expectation(description: "Bookmark didChangeNotification")
        bExpectation.assertForOverFulfill = false
        var bFulfilled = false
        let bObserver = NotificationCenter.default.addObserver(
            forName: BrowserBookmarkStore.didChangeNotification,
            object: bStore,
            queue: .main
        ) { _ in
            if !bFulfilled {
                bFulfilled = true
                bExpectation.fulfill()
            }
        }

        bStore.addBookmark(title: "Test", url: URL(string: "https://test.org")!)
        wait(for: [bExpectation], timeout: 2.0)
        NotificationCenter.default.removeObserver(bObserver)

        let hExpectation = expectation(description: "History didChangeNotification")
        hExpectation.assertForOverFulfill = false
        var hFulfilled = false
        let hObserver = NotificationCenter.default.addObserver(
            forName: BrowserHistoryStore.didChangeNotification,
            object: hStore,
            queue: .main
        ) { _ in
            if !hFulfilled {
                hFulfilled = true
                hExpectation.fulfill()
            }
        }

        hStore.recordVisit(url: URL(string: "https://test.org")!, title: "Test", isIncognito: false)
        wait(for: [hExpectation], timeout: 2.0)
        NotificationCenter.default.removeObserver(hObserver)
    }
}
