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

public enum BrowserBookmarkError: LocalizedError, Equatable, Sendable {
    case duplicateURL(existingID: UUID)
    case circularFolderReference
    case folderNotFound
    case bookmarkNotFound

    public var errorDescription: String? {
        switch self {
        case .duplicateURL: return "A bookmark for this URL already exists."
        case .circularFolderReference: return "Cannot move a folder into itself or one of its subfolders."
        case .folderNotFound: return "Target folder not found."
        case .bookmarkNotFound: return "Bookmark not found."
        }
    }
}

public final class BrowserBookmarkStore: @unchecked Sendable {
    public static let shared = BrowserBookmarkStore()
    public static let didChangeNotification = Notification.Name("BrowserBookmarkStoreDidChangeNotification")

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

        guard let storageURL else {
            setDefaultBookmarksIfNeeded()
            return
        }

        guard FileManager.default.fileExists(atPath: storageURL.path) else {
            setDefaultBookmarksIfNeeded()
            return
        }

        do {
            let data = try Data(contentsOf: storageURL)
            let payload = try JSONDecoder().decode(BookmarkStoragePayload.self, from: data)
            self.folders = payload.folders
            self.bookmarks = payload.bookmarks
        } catch {
            let timestamp = Int(Date().timeIntervalSince1970)
            let corruptURL = storageURL.deletingPathExtension()
                .appendingPathExtension("corrupt.\(timestamp).json")
            do {
                try FileManager.default.moveItem(at: storageURL, to: corruptURL)
            } catch {
                PipelineLogger.shared.log(stage: .browser, message: "Failed to quarantine corrupt bookmarks: \(error)")
            }
            self.folders = []
            self.bookmarks = []
            setDefaultBookmarksIfNeeded()
        }
    }

    private func setDefaultBookmarksIfNeeded() {
        if bookmarks.isEmpty {
            bookmarks = [
                BrowserBookmarkItem(title: "DuckDuckGo", url: URL(string: "https://duckduckgo.com")!),
                BrowserBookmarkItem(title: "Wikipedia", url: URL(string: "https://www.wikipedia.org")!)
            ]
        }
    }

    public func save() {
        lock.lock()
        guard let storageURL else {
            lock.unlock()
            return
        }
        let payload = BookmarkStoragePayload(folders: folders, bookmarks: bookmarks)
        do {
            let data = try JSONEncoder().encode(payload)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            PipelineLogger.shared.log(stage: .browser, message: "Failed to persist bookmarks: \(error)")
        }
        lock.unlock()

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    // MARK: - Bookmark CRUD

    @discardableResult
    public func addBookmark(
        title: String,
        url: URL,
        folderID: UUID? = nil,
        dateAdded: Date = Date()
    ) -> BrowserBookmarkItem {
        lock.lock()
        let item = BrowserBookmarkItem(title: title, url: url, folderID: folderID, dateAdded: dateAdded)
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

    public func moveBookmark(id: UUID, toFolderID: UUID?) {
        lock.lock()
        if let index = bookmarks.firstIndex(where: { $0.id == id }) {
            bookmarks[index].folderID = toFolderID
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

    public func findDuplicate(for url: URL) -> BrowserBookmarkItem? {
        lock.lock()
        defer { lock.unlock() }
        let target = BookmarkURLNormalizer.normalize(url)
        return bookmarks.first {
            BookmarkURLNormalizer.normalize($0.url) == target
        }
    }

    public func isBookmarked(url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let target = BookmarkURLNormalizer.normalize(url)
        return bookmarks.contains {
            BookmarkURLNormalizer.normalize($0.url) == target
        }
    }

    public func bookmark(for url: URL) -> BrowserBookmarkItem? {
        lock.lock()
        defer { lock.unlock() }
        let target = BookmarkURLNormalizer.normalize(url)
        return bookmarks.first {
            BookmarkURLNormalizer.normalize($0.url) == target
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

    public func renameFolder(id: UUID, newTitle: String) {
        let clean = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        lock.lock()
        if let index = folders.firstIndex(where: { $0.id == id }) {
            folders[index].title = clean
        }
        lock.unlock()
        save()
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

    public func canMoveFolder(id: UUID, toParentID targetParentID: UUID?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let targetParentID else { return true }
        if id == targetParentID { return false }

        var current: UUID? = targetParentID
        var visited = Set<UUID>()
        while let p = current {
            if p == id { return false }
            if visited.contains(p) { return false }
            visited.insert(p)
            current = folders.first(where: { $0.id == p })?.parentFolderID
        }
        return true
    }

    public func moveFolder(id: UUID, toParentID targetParentID: UUID?) throws {
        guard canMoveFolder(id: id, toParentID: targetParentID) else {
            throw BrowserBookmarkError.circularFolderReference
        }
        lock.lock()
        if let index = folders.firstIndex(where: { $0.id == id }) {
            folders[index].parentFolderID = targetParentID
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
