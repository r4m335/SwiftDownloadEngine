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

@MainActor
public final class BrowserBookmarkStore {
    public static let shared = BrowserBookmarkStore()
    public static let didChangeNotification = Notification.Name("BrowserBookmarkStoreDidChangeNotification")

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

    public struct BookmarkStoragePayload: Codable, SchemaVersioned {
        public static let currentSchemaVersion: Int = 1
        public var schemaVersion: Int
        public var folders: [BrowserBookmarkFolder]
        public var bookmarks: [BrowserBookmarkItem]

        public init(
            schemaVersion: Int = Self.currentSchemaVersion,
            folders: [BrowserBookmarkFolder],
            bookmarks: [BrowserBookmarkItem]
        ) {
            self.schemaVersion = schemaVersion
            self.folders = folders
            self.bookmarks = bookmarks
        }

        private enum CodingKeys: String, CodingKey {
            case schemaVersion, folders, bookmarks
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
            self.folders = try container.decode([BrowserBookmarkFolder].self, forKey: .folders)
            self.bookmarks = try container.decode([BrowserBookmarkItem].self, forKey: .bookmarks)
        }
    }

    public func load() {
        guard let storageURL else {
            setDefaultBookmarksIfNeeded()
            return
        }

        guard FileManager.default.fileExists(atPath: storageURL.path) else {
            setDefaultBookmarksIfNeeded()
            return
        }

        do {
            if let payload = try DurableStorage.load(
                from: storageURL,
                legacyFallback: { data in
                    struct LegacyBookmarkPayload: Codable {
                        var folders: [BrowserBookmarkFolder]
                        var bookmarks: [BrowserBookmarkItem]
                    }
                    let legacy = try JSONDecoder().decode(LegacyBookmarkPayload.self, from: data)
                    return BookmarkStoragePayload(
                        schemaVersion: 0,
                        folders: legacy.folders,
                        bookmarks: legacy.bookmarks
                    )
                }
            ) as BookmarkStoragePayload? {
                self.folders = payload.folders
                self.bookmarks = payload.bookmarks
            } else {
                setDefaultBookmarksIfNeeded()
            }
        } catch {
            PipelineLogger.shared.log(stage: .browser, message: "Failed to load bookmarks at \(storageURL.path): \(error)")
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
        guard let storageURL else {
            return
        }
        let payload = BookmarkStoragePayload(folders: folders, bookmarks: bookmarks)
        do {
            let data = try JSONEncoder().encode(payload)
            try DurableStorage.writeAtomically(data, to: storageURL)
        } catch {
            PipelineLogger.shared.log(stage: .browser, message: "Failed to persist bookmarks: \(error)")
        }

        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    // MARK: - Bookmark CRUD

    @discardableResult
    public func addBookmark(
        title: String,
        url: URL,
        folderID: UUID? = nil,
        dateAdded: Date = Date()
    ) -> BrowserBookmarkItem {
        let item = BrowserBookmarkItem(title: title, url: url, folderID: folderID, dateAdded: dateAdded)
        bookmarks.append(item)
        save()
        return item
    }

    public func updateBookmark(id: UUID, title: String, url: URL, folderID: UUID?) {
        if let index = bookmarks.firstIndex(where: { $0.id == id }) {
            bookmarks[index].title = title
            bookmarks[index].url = url
            bookmarks[index].folderID = folderID
        }
        save()
    }

    public func moveBookmark(id: UUID, toFolderID: UUID?) {
        if let index = bookmarks.firstIndex(where: { $0.id == id }) {
            bookmarks[index].folderID = toFolderID
        }
        save()
    }

    public func deleteBookmark(id: UUID) {
        bookmarks.removeAll(where: { $0.id == id })
        save()
    }

    public func findDuplicate(for url: URL) -> BrowserBookmarkItem? {
        let target = BookmarkURLNormalizer.normalize(url)
        return bookmarks.first {
            BookmarkURLNormalizer.normalize($0.url) == target
        }
    }

    public func isBookmarked(url: URL) -> Bool {
        let target = BookmarkURLNormalizer.normalize(url)
        return bookmarks.contains {
            BookmarkURLNormalizer.normalize($0.url) == target
        }
    }

    public func bookmark(for url: URL) -> BrowserBookmarkItem? {
        let target = BookmarkURLNormalizer.normalize(url)
        return bookmarks.first {
            BookmarkURLNormalizer.normalize($0.url) == target
        }
    }

    // MARK: - Folder CRUD

    @discardableResult
    public func createFolder(title: String, parentFolderID: UUID? = nil) -> BrowserBookmarkFolder {
        let folder = BrowserBookmarkFolder(title: title, parentFolderID: parentFolderID)
        folders.append(folder)
        save()
        return folder
    }

    public func renameFolder(id: UUID, newTitle: String) {
        let clean = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        if let index = folders.firstIndex(where: { $0.id == id }) {
            folders[index].title = clean
        }
        save()
    }

    public func updateFolder(id: UUID, title: String, parentFolderID: UUID?) {
        if let index = folders.firstIndex(where: { $0.id == id }) {
            folders[index].title = title
            folders[index].parentFolderID = parentFolderID
        }
        save()
    }

    public func canMoveFolder(id: UUID, toParentID targetParentID: UUID?) -> Bool {
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
        if let index = folders.firstIndex(where: { $0.id == id }) {
            folders[index].parentFolderID = targetParentID
        }
        save()
    }

    public func deleteFolder(id: UUID) {
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
        save()
    }

    // MARK: - Query & Search

    public func bookmarks(in folderID: UUID?) -> [BrowserBookmarkItem] {
        return bookmarks.filter { $0.folderID == folderID }
    }

    public func subfolders(in parentFolderID: UUID?) -> [BrowserBookmarkFolder] {
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

        return bookmarks.filter {
            $0.title.lowercased().contains(q) || $0.url.absoluteString.lowercased().contains(q)
        }
    }

    public var allBookmarks: [BrowserBookmarkItem] {
        return bookmarks
    }

    public var allFolders: [BrowserBookmarkFolder] {
        return folders
    }
}
