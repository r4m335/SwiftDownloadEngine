import XCTest
@testable import DM_Reverse_engineering

final class QuickAccessTests: XCTestCase {

    private var temporaryDirectory: URL!
    private var customStoreURL: URL!
    private var customUserDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        customStoreURL = temporaryDirectory.appendingPathComponent("quick_access.json")
        customUserDefaults = UserDefaults(suiteName: "test.quickaccess.\(UUID().uuidString)")!
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: temporaryDirectory)
        customUserDefaults.removePersistentDomain(forName: customUserDefaults.description)
        super.tearDown()
    }

    // MARK: - 1. URL Validation & Normalization

    func testURLValidator_NormalizesValidDomains() {
        let result1 = QuickAccessURLValidator.validate(name: "GitHub", urlString: "github.com")
        switch result1 {
        case .success(let val):
            XCTAssertEqual(val.name, "GitHub")
            XCTAssertEqual(val.url.absoluteString, "https://github.com")
        case .failure(let err):
            XCTFail("Expected success, got \(err)")
        }

        let result2 = QuickAccessURLValidator.validate(name: "Subdomain", urlString: "sub.example.co.uk/path?q=1")
        switch result2 {
        case .success(let val):
            XCTAssertEqual(val.name, "Subdomain")
            XCTAssertEqual(val.url.absoluteString, "https://sub.example.co.uk/path?q=1")
        case .failure(let err):
            XCTFail("Expected success, got \(err)")
        }

        let result3 = QuickAccessURLValidator.validate(name: "Localhost", urlString: "http://localhost:8080")
        switch result3 {
        case .success(let val):
            XCTAssertEqual(val.name, "Localhost")
            XCTAssertEqual(val.url.absoluteString, "http://localhost:8080")
        case .failure(let err):
            XCTFail("Expected success, got \(err)")
        }
    }

    func testURLValidator_RejectsInvalidInputs() {
        // Empty Name
        let r1 = QuickAccessURLValidator.validate(name: "  ", urlString: "https://example.com")
        XCTAssertEqual(r1, .failure(.emptyName))

        // Empty URL
        let r2 = QuickAccessURLValidator.validate(name: "Example", urlString: "   ")
        XCTAssertEqual(r2, .failure(.emptyURL))

        // Insecure / Disallowed Schemes
        let r3 = QuickAccessURLValidator.validate(name: "FTP", urlString: "ftp://files.example.com")
        XCTAssertEqual(r3, .failure(.invalidScheme))

        let r4 = QuickAccessURLValidator.validate(name: "JS", urlString: "javascript:alert(1)")
        XCTAssertEqual(r4, .failure(.invalidScheme))

        // Invalid Domain / No Dot
        let r5 = QuickAccessURLValidator.validate(name: "Invalid", urlString: "randomwordwithoutdot")
        XCTAssertEqual(r5, .failure(.invalidURL))
    }

    // MARK: - 2. Default Shortcuts & Persistence

    func testQuickAccessStore_LoadsSensibleDefaultsWhenEmpty() {
        let store = QuickAccessStore(defaults: customUserDefaults, customStorageURL: customStoreURL)
        let loaded = store.load()

        XCTAssertFalse(loaded.isEmpty)
        XCTAssertGreaterThanOrEqual(loaded.count, 6)
        XCTAssertEqual(loaded[0].name, "DuckDuckGo")
        XCTAssertEqual(loaded[0].url.absoluteString, "https://duckduckgo.com")
        XCTAssertEqual(loaded[1].name, "Wikipedia")
        XCTAssertEqual(loaded[2].name, "GitHub")
    }

    func testQuickAccessStore_AddEditDeletePersistence() {
        let store = QuickAccessStore(defaults: customUserDefaults, customStorageURL: customStoreURL)

        // 1. Add Shortcut
        let added = store.add(name: "Rust Lang", url: URL(string: "https://www.rust-lang.org")!)
        XCTAssertEqual(added.name, "Rust Lang")
        XCTAssertEqual(added.url.absoluteString, "https://www.rust-lang.org")

        var shortcuts = store.load()
        XCTAssertTrue(shortcuts.contains(where: { $0.id == added.id }))

        // 2. Edit Shortcut
        var modified = added
        modified.name = "Rust Official"
        modified.url = URL(string: "https://rust-lang.org")!
        store.update(modified)

        let reloaded = store.load()
        let fetched = reloaded.first(where: { $0.id == added.id })
        XCTAssertEqual(fetched?.name, "Rust Official")
        XCTAssertEqual(fetched?.url.absoluteString, "https://rust-lang.org")

        // 3. Delete Shortcut
        store.delete(id: added.id)
        let afterDelete = store.load()
        XCTAssertFalse(afterDelete.contains(where: { $0.id == added.id }))

        // 4. Persistence across fresh store instance
        let freshStore = QuickAccessStore(defaults: customUserDefaults, customStorageURL: customStoreURL)
        let freshLoaded = freshStore.load()
        XCTAssertFalse(freshLoaded.contains(where: { $0.id == added.id }))
    }

    // MARK: - 3. Reordering

    func testQuickAccessStore_Reordering() {
        let store = QuickAccessStore(defaults: customUserDefaults, customStorageURL: customStoreURL)
        let initial = store.load()
        guard initial.count >= 3 else {
            XCTFail("Expected at least 3 default shortcuts")
            return
        }

        let firstID = initial[0].id
        let secondID = initial[1].id

        // Move first item right
        store.move(id: firstID, direction: .right)
        let afterMove = store.load()

        XCTAssertEqual(afterMove[0].id, secondID)
        XCTAssertEqual(afterMove[1].id, firstID)
        XCTAssertEqual(afterMove[0].displayOrder, 0)
        XCTAssertEqual(afterMove[1].displayOrder, 1)

        // Move back left
        store.move(id: firstID, direction: .left)
        let restored = store.load()
        XCTAssertEqual(restored[0].id, firstID)
        XCTAssertEqual(restored[1].id, secondID)
    }

    // MARK: - 4. Independence from Bookmarks and History

    func testQuickAccess_IsCompletelyIndependentFromBookmarksAndHistory() {
        let bookmarkStoreURL = temporaryDirectory.appendingPathComponent("bookmarks.json")
        let historyStoreURL = temporaryDirectory.appendingPathComponent("history.json")

        let bookmarkStore = BrowserBookmarkStore(customStorageURL: bookmarkStoreURL)
        let historyStore = BrowserHistoryStore(customStorageURL: historyStoreURL)
        let quickAccessStore = QuickAccessStore(defaults: customUserDefaults, customStorageURL: customStoreURL)

        let initialBookmarkCount = bookmarkStore.allBookmarks().count
        let initialHistoryCount = historyStore.allHistory().count

        // Add Quick Access shortcut
        let shortcut = quickAccessStore.add(name: "Standalone", url: URL(string: "https://standalone.example.org")!)

        // Assert Bookmarks and History are untouched
        XCTAssertEqual(bookmarkStore.allBookmarks().count, initialBookmarkCount)
        XCTAssertEqual(historyStore.allHistory().count, initialHistoryCount)

        // Delete Quick Access shortcut
        quickAccessStore.delete(id: shortcut.id)

        // Assert Bookmarks and History still untouched
        XCTAssertEqual(bookmarkStore.allBookmarks().count, initialBookmarkCount)
        XCTAssertEqual(historyStore.allHistory().count, initialHistoryCount)
    }

    // MARK: - 5. Favicon Retrieval & Caching Service

    func testFaviconService_DefaultURLAndCaching() {
        let service = FaviconService.shared
        let host = "github.com"

        let expectedFaviconURL = URL(string: "https://icons.duckduckgo.com/ip3/github.com.ico")
        XCTAssertEqual(FaviconService.defaultFaviconURL(for: host), expectedFaviconURL)

        // Simulate caching data
        let dummyData = "mock-favicon-bytes".data(using: .utf8)!
        service.setCachedFaviconData(dummyData, for: host)

        let cached = service.cachedFaviconData(for: host)
        XCTAssertEqual(cached, dummyData)
    }

    // MARK: - 6. BrowserViewModel Quick Access Integration & Navigation

    @MainActor
    func testBrowserViewModel_QuickAccessNavigation() {
        let viewModel = BrowserViewModel()
        let shortcuts = viewModel.quickAccessShortcuts
        XCTAssertFalse(shortcuts.isEmpty)

        // Verify initial state has no active URL (Start/Home page)
        XCTAssertNil(viewModel.currentURL)

        // Tap a shortcut: loads in current active tab
        let target = shortcuts[0]
        viewModel.load(url: target.url)

        XCTAssertEqual(viewModel.currentURL, target.url)

        // Add a shortcut via view model
        let newURL = URL(string: "https://swift.org")!
        viewModel.addQuickAccessShortcut(name: "Swift Org", url: newURL)
        XCTAssertTrue(viewModel.quickAccessShortcuts.contains(where: { $0.url == newURL }))

        // Clean up
        if let created = viewModel.quickAccessShortcuts.first(where: { $0.url == newURL }) {
            viewModel.deleteQuickAccessShortcut(id: created.id)
            XCTAssertFalse(viewModel.quickAccessShortcuts.contains(where: { $0.url == newURL }))
        }
    }
}
