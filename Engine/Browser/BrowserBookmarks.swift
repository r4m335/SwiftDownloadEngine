import Foundation

public struct BrowserBookmarkItem: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var url: URL
    public var folderID: UUID?
    public var dateAdded: Date

    public init(
        id: UUID = UUID(),
        title: String,
        url: URL,
        folderID: UUID? = nil,
        dateAdded: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.folderID = folderID
        self.dateAdded = dateAdded
    }
}

public struct BrowserBookmarkFolder: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var parentFolderID: UUID?
    public var dateCreated: Date

    public init(
        id: UUID = UUID(),
        title: String,
        parentFolderID: UUID? = nil,
        dateCreated: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.parentFolderID = parentFolderID
        self.dateCreated = dateCreated
    }
}

public enum BrowserBookmarkSort: String, CaseIterable, Identifiable, Sendable {
    case dateAddedDesc = "Newest First"
    case dateAddedAsc = "Oldest First"
    case titleAsc = "Name (A-Z)"
    case titleDesc = "Name (Z-A)"

    public var id: String { rawValue }
}

public final class BrowserBookmarkStore: @unchecked Sendable {
    public static let shared = BrowserBookmarkStore()

    private let lock = NSLock()
    private var folders: [BrowserBookmarkFolder] = []
    private var bookmarks: [BrowserBookmarkItem] = []
    private let storageURL: URL?

    public init(customStorageURL: URL? = nil) {
        if let customStorageURL {
            self.storageURL = customStorageURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            let dir = appSupport?.appendingPathComponent("Browser", isDirectory: true)
            if let dir {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            self.storageURL = dir?.appendingPathComponent("bookmarks.json")
        }
        load()
    }

    private struct BookmarkStoragePayload: Codable {
        var folders: [BrowserBookmarkFolder]
        var bookmarks: [BrowserBookmarkItem]
    }

    public func load() {
        lock.lock()
        defer { lock.unlock() }

        guard let storageURL,
              let data = try? Data(contentsOf: storageURL),
              let payload = try? JSONDecoder().decode(BookmarkStoragePayload.self, from: data) else {
            // Default initial bookmark
            if bookmarks.isEmpty {
                bookmarks = [
                    BrowserBookmarkItem(title: "DuckDuckGo", url: URL(string: "https://duckduckgo.com")!),
                    BrowserBookmarkItem(title: "Wikipedia", url: URL(string: "https://www.wikipedia.org")!)
                ]
            }
            return
        }
        self.folders = payload.folders
        self.bookmarks = payload.bookmarks
    }

    public func save() {
        lock.lock()
        defer { lock.unlock() }

        guard let storageURL else { return }
        let payload = BookmarkStoragePayload(folders: folders, bookmarks: bookmarks)
        if let data = try? JSONEncoder().encode(payload) {
            try? data.write(to: storageURL, options: .atomic)
        }
    }

    // MARK: - Bookmark CRUD

    @discardableResult
    public func addBookmark(title: String, url: URL, folderID: UUID? = nil) -> BrowserBookmarkItem {
        lock.lock()
        let item = BrowserBookmarkItem(title: title, url: url, folderID: folderID)
        bookmarks.append(item)
        lock.unlock()
        save()
        return item
    }

    public func updateBookmark(id: UUID, title: String, url: URL, folderID: UUID?) {
        lock.lock()
        if let index = bookmarks.firstIndex(where: { $0.id == id }) {
            bookmarks[index].title = title
            bookmarks[index].url = url
            bookmarks[index].folderID = folderID
        }
        lock.unlock()
        save()
    }

    public func deleteBookmark(id: UUID) {
        lock.lock()
        bookmarks.removeAll(where: { $0.id == id })
        lock.unlock()
        save()
    }

    public func isBookmarked(url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let clean = url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return bookmarks.contains {
            $0.url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == clean
        }
    }

    public func bookmark(for url: URL) -> BrowserBookmarkItem? {
        lock.lock()
        defer { lock.unlock() }
        let clean = url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return bookmarks.first {
            $0.url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == clean
        }
    }

    // MARK: - Folder CRUD

    @discardableResult
    public func createFolder(title: String, parentFolderID: UUID? = nil) -> BrowserBookmarkFolder {
        lock.lock()
        let folder = BrowserBookmarkFolder(title: title, parentFolderID: parentFolderID)
        folders.append(folder)
        lock.unlock()
        save()
        return folder
    }

    public func updateFolder(id: UUID, title: String, parentFolderID: UUID?) {
        lock.lock()
        if let index = folders.firstIndex(where: { $0.id == id }) {
            folders[index].title = title
            folders[index].parentFolderID = parentFolderID
        }
        lock.unlock()
        save()
    }

    public func deleteFolder(id: UUID) {
        lock.lock()
        // Collect all descendants recursively
        var toDelete: Set<UUID> = [id]
        var addedNew = true
        while addedNew {
            addedNew = false
            for f in folders {
                if let p = f.parentFolderID, toDelete.contains(p), !toDelete.contains(f.id) {
                    toDelete.insert(f.id)
                    addedNew = true
                }
            }
        }

        folders.removeAll(where: { toDelete.contains($0.id) })
        bookmarks.removeAll(where: {
            guard let f = $0.folderID else { return false }
            return toDelete.contains(f)
        })
        lock.unlock()
        save()
    }

    // MARK: - Query & Search

    public func bookmarks(in folderID: UUID?) -> [BrowserBookmarkItem] {
        lock.lock()
        defer { lock.unlock() }
        return bookmarks.filter { $0.folderID == folderID }
    }

    public func subfolders(in parentFolderID: UUID?) -> [BrowserBookmarkFolder] {
        lock.lock()
        defer { lock.unlock() }
        return folders.filter { $0.parentFolderID == parentFolderID }
    }

    public func sortedBookmarks(in folderID: UUID?, by sort: BrowserBookmarkSort) -> [BrowserBookmarkItem] {
        let items = bookmarks(in: folderID)
        switch sort {
        case .dateAddedDesc:
            return items.sorted(by: { $0.dateAdded > $1.dateAdded })
        case .dateAddedAsc:
            return items.sorted(by: { $0.dateAdded < $1.dateAdded })
        case .titleAsc:
            return items.sorted(by: { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending })
        case .titleDesc:
            return items.sorted(by: { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedDescending })
        }
    }

    public func search(query: String) -> [BrowserBookmarkItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }

        lock.lock()
        defer { lock.unlock() }
        return bookmarks.filter {
            $0.title.lowercased().contains(q) || $0.url.absoluteString.lowercased().contains(q)
        }
    }

    public var allBookmarks: [BrowserBookmarkItem] {
        lock.lock()
        defer { lock.unlock() }
        return bookmarks
    }

    public var allFolders: [BrowserBookmarkFolder] {
        lock.lock()
        defer { lock.unlock() }
        return folders
    }
}
