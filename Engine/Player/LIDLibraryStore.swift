import Foundation

#if canImport(Combine)
import Combine
#endif

/// Central store managing the unified media library, playlists, favorites, and filesystem synchronization.
@MainActor
public final class LIDLibraryStore: ObservableObject {

    public static let shared = LIDLibraryStore()

    @Published public private(set) var mediaItems: [LIDMediaItem] = []
    @Published public private(set) var playlists: [LIDPlaylist] = []
    @Published public private(set) var favorites: Set<String> = []
    @Published public private(set) var folders: [LIDFolder] = []
    @Published public private(set) var trashItems: [LIDTrashItem] = []

    private let favoritesStorageURL: URL
    private let playlistsStorageURL: URL
    private let foldersStorageURL: URL
    private let trashStorageURL: URL
    private let trashDirectoryURL: URL
    private let historyStore: LIDPlaybackHistoryStore
    private var isLoaded: Bool = false

    public init(
        storageDirectory: URL? = nil,
        historyStore: LIDPlaybackHistoryStore = .shared
    ) {
        self.historyStore = historyStore

        let baseDir: URL
        if let dir = storageDirectory {
            baseDir = dir
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            baseDir = appSupport.appendingPathComponent("SwiftDownloadEngine/Library", isDirectory: true)
        }

        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        self.favoritesStorageURL = baseDir.appendingPathComponent("library_favorites.json")
        self.playlistsStorageURL = baseDir.appendingPathComponent("library_playlists.json")
        self.foldersStorageURL = baseDir.appendingPathComponent("library_folders.json")
        self.trashStorageURL = baseDir.appendingPathComponent("library_trash.json")
        self.trashDirectoryURL = baseDir.appendingPathComponent(".Trash", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.trashDirectoryURL, withIntermediateDirectories: true)

        loadState()
    }

    // MARK: - Library Scanning & Sync

    /// Scans the provided directory (and category subdirectories) for media files, merging with known transfers.
    public func scanLibrary(
        in baseDirectory: URL,
        knownTransfers: [UnifiedTransfer] = []
    ) async -> [LIDMediaItem] {
        loadState()

        var discoveredURLs: Set<URL> = []

        // 1. Scan filesystem directory and immediate subdirectories (Videos, Music, etc.)
        let fm = FileManager.default
        if let enumerator = fm.enumerator(
            at: baseDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            for case let fileURL as URL in enumerator {
                if fileURL.isPlayableMedia {
                    discoveredURLs.insert(fileURL.resolvingSymlinksInPath().standardizedFileURL)
                }
            }
        }

        // 2. Add completed transfers pointing to existent media files
        for transfer in knownTransfers {
            if transfer.state == .completed || transfer.state == .seeding {
                let dest = transfer.destinationURL.resolvingSymlinksInPath().standardizedFileURL
                if dest.isPlayableMedia && fm.fileExists(atPath: dest.path) {
                    discoveredURLs.insert(dest)
                }
            }
        }

        // 3. Transform to LIDMediaItem with history and metadata
        var items: [LIDMediaItem] = []
        for rawURL in discoveredURLs {
            let url = rawURL.resolvingSymlinksInPath().standardizedFileURL
            // Guard against deleted files
            guard fm.fileExists(atPath: url.path) else { continue }

            let pathID = url.path
            let absID = url.absoluteString

            var size: Int64 = 0
            var date = Date()
            if let attrs = try? fm.attributesOfItem(atPath: url.path) {
                size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                date = (attrs[.creationDate] as? Date) ?? (attrs[.modificationDate] as? Date) ?? Date()
            }

            let type: LIDMediaType = url.isVideoMedia ? .video : (url.isAudioMedia ? .audio : .all)
            let isFav = favorites.contains(pathID) || favorites.contains(absID)

            // History progress
            var lastPos: Double = 0.0
            var prog: Double = 0.0
            var completed = false

            var resume = await historyStore.resumePosition(mediaIdentifier: absID)
            if resume == nil {
                resume = await historyStore.resumePosition(mediaIdentifier: pathID)
            }
            if let validResume = resume {
                lastPos = validResume
            }

            // Check if record exists in history
            let records = await historyStore.historyRecords()
            if let record = records.first(where: { rec in
                if rec.mediaIdentifier == absID || rec.mediaIdentifier == pathID { return true }
                if let u = URL(string: rec.mediaIdentifier) {
                    return u.resolvingSymlinksInPath().standardizedFileURL.path == pathID
                }
                let u = URL(fileURLWithPath: rec.mediaIdentifier).resolvingSymlinksInPath().standardizedFileURL
                return u.path == pathID
            }) {
                prog = record.progressFraction
                completed = record.isCompleted
                if lastPos == 0.0 {
                    lastPos = record.lastPositionSeconds
                }
            }

            let item = LIDMediaItem(
                url: url,
                title: url.deletingPathExtension().lastPathComponent,
                fileSize: size,
                mediaType: type,
                dateAdded: date,
                isFavorite: isFav,
                lastPositionSeconds: lastPos,
                progressFraction: prog,
                isCompleted: completed
            )
            items.append(item)
        }

        // Sort: newest first
        let sorted = items.sorted { $0.dateAdded > $1.dateAdded }
        self.mediaItems = sorted
        return sorted
    }

    /// Items actively in-progress (watched between 2% and 97%).
    public func continueWatchingItems() -> [LIDMediaItem] {
        mediaItems.filter { item in
            !item.isCompleted && item.progressFraction > 0.02 && item.progressFraction < 0.97
        }
    }

    /// Items marked as favorite.
    public func favoriteItems() -> [LIDMediaItem] {
        mediaItems.filter { item in
            favorites.contains(item.url.path) || favorites.contains(item.url.absoluteString)
        }
    }

    /// Recently played items matching existing library entries, sorted by watch date.
    public func recentlyPlayedItems() async -> [LIDMediaItem] {
        let records = await historyStore.historyRecords()
        var results: [LIDMediaItem] = []

        for record in records {
            if let item = mediaItems.first(where: {
                $0.url.absoluteString == record.mediaIdentifier || $0.url.path == record.mediaIdentifier
            }) {
                results.append(item)
            }
        }
        return results
    }

    // MARK: - Favorites Management

    public func toggleFavorite(for item: LIDMediaItem) {
        let key = item.url.resolvingSymlinksInPath().standardizedFileURL.path
        if favorites.contains(key) {
            favorites.remove(key)
        } else {
            favorites.insert(key)
        }
        persistFavorites()
        updateItemFavoriteState(path: key, isFavorite: favorites.contains(key))
    }

    public func isFavorite(mediaIdentifier: String) -> Bool {
        if favorites.contains(mediaIdentifier) { return true }
        let canonical = URL(fileURLWithPath: mediaIdentifier).resolvingSymlinksInPath().standardizedFileURL.path
        if favorites.contains(canonical) { return true }
        if let u = URL(string: mediaIdentifier) {
            return favorites.contains(u.resolvingSymlinksInPath().standardizedFileURL.path)
        }
        return false
    }

    // MARK: - Folders & Smart Folders Management

    public func createFolder(name: String, parentID: UUID? = nil) -> LIDFolder {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = LIDFolder(
            name: trimmed.isEmpty ? "New Folder" : trimmed,
            parentID: parentID
        )
        folders.append(folder)
        persistFolders()
        return folder
    }

    public func renameFolder(id: UUID, newName: String) {
        guard let idx = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[idx].name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        folders[idx].updatedAt = Date()
        persistFolders()
    }

    public func deleteFolder(id: UUID) {
        folders.removeAll { $0.id == id }
        // Orphan children become root folders
        for i in 0..<folders.count {
            if folders[i].parentID == id {
                folders[i].parentID = nil
                folders[i].updatedAt = Date()
            }
        }
        persistFolders()
    }

    public func moveFolder(id: UUID, toParentID: UUID?) {
        guard let idx = folders.firstIndex(where: { $0.id == id }), id != toParentID else { return }
        folders[idx].parentID = toParentID
        folders[idx].updatedAt = Date()
        persistFolders()
    }

    public func addItemToFolder(folderID: UUID, itemPath: String) {
        guard let idx = folders.firstIndex(where: { $0.id == folderID }) else { return }
        if !folders[idx].itemPaths.contains(itemPath) {
            folders[idx].itemPaths.append(itemPath)
            folders[idx].updatedAt = Date()
            persistFolders()
        }
        if let mIdx = mediaItems.firstIndex(where: { $0.url.path == itemPath }) {
            mediaItems[mIdx].folderID = folderID
        }
    }

    public func removeItemFromFolder(folderID: UUID, itemPath: String) {
        guard let idx = folders.firstIndex(where: { $0.id == folderID }) else { return }
        folders[idx].itemPaths.removeAll { $0 == itemPath }
        folders[idx].updatedAt = Date()
        persistFolders()
        if let mIdx = mediaItems.firstIndex(where: { $0.url.path == itemPath && $0.folderID == folderID }) {
            mediaItems[mIdx].folderID = nil
        }
    }

    public func moveItem(itemPath: String, fromFolderID: UUID?, toFolderID: UUID?) {
        if let from = fromFolderID {
            removeItemFromFolder(folderID: from, itemPath: itemPath)
        }
        if let to = toFolderID {
            addItemToFolder(folderID: to, itemPath: itemPath)
        }
    }

    public func items(in folder: LIDFolder) -> [LIDMediaItem] {
        if folder.isSmartFolder, let criteria = folder.smartCriteria {
            return smartFolderItems(for: criteria)
        }
        let set = Set(folder.itemPaths)
        return mediaItems.filter { set.contains($0.url.path) || set.contains($0.url.resolvingSymlinksInPath().path) }
    }

    public func smartFolderItems(for criteria: LIDSmartFolderCriteria) -> [LIDMediaItem] {
        switch criteria {
        case .videosOver1GB:
            return mediaItems.filter { $0.mediaType == .video && $0.fileSize >= 1_000_000_000 }
        case .torrents:
            return mediaItems.filter { $0.url.pathExtension.lowercased() == "torrent" || $0.url.path.contains("Torrent") }
        case .liveRecordings:
            return mediaItems.filter { $0.url.pathExtension.lowercased() == "ts" || $0.title.lowercased().contains("live") }
        case .recentDownloads:
            let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date.distantPast
            return mediaItems.filter { $0.dateAdded >= weekAgo }
        }
    }

    // MARK: - Playlists Management

    public func createPlaylist(name: String) -> LIDPlaylist {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let playlist = LIDPlaylist(
            name: trimmed.isEmpty ? "New Playlist" : trimmed,
            itemPaths: []
        )
        playlists.append(playlist)
        persistPlaylists()
        return playlist
    }

    public func renamePlaylist(id: UUID, newName: String) {
        guard let idx = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[idx].name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        playlists[idx].updatedAt = Date()
        persistPlaylists()
    }

    public func deletePlaylist(id: UUID) {
        playlists.removeAll { $0.id == id }
        persistPlaylists()
    }

    public func addItemToPlaylist(playlistID: UUID, item: LIDMediaItem) {
        guard let idx = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        let path = item.url.resolvingSymlinksInPath().standardizedFileURL.path
        if !playlists[idx].itemPaths.contains(path) {
            playlists[idx].itemPaths.append(path)
            playlists[idx].updatedAt = Date()
            persistPlaylists()
        }
    }

    public func removeItemFromPlaylist(playlistID: UUID, itemPath: String) {
        guard let idx = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[idx].itemPaths.removeAll { $0 == itemPath }
        playlists[idx].updatedAt = Date()
        persistPlaylists()
    }

    public func reorderPlaylist(playlistID: UUID, fromIndices: IndexSet, toOffset: Int) {
        guard let idx = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        var list = playlists[idx].itemPaths
        var moving: [String] = []
        for i in fromIndices.sorted() {
            if i < list.count {
                moving.append(list[i])
            }
        }
        for i in fromIndices.sorted(by: >) {
            if i < list.count {
                list.remove(at: i)
            }
        }
        let insertIndex = min(toOffset, list.count)
        list.insert(contentsOf: moving, at: insertIndex)
        playlists[idx].itemPaths = list
        playlists[idx].updatedAt = Date()
        persistPlaylists()
    }

    // MARK: - File Management Operations

    /// Renames a media file on disk and updates library, playlists, and history stores.
    @discardableResult
    public func renameMediaFile(url: URL, newFileName: String) throws -> URL {
        let oldPath = url.path
        let ext = url.pathExtension
        var sanitized = newFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sanitized.hasSuffix(".\(ext)") && !ext.isEmpty {
            sanitized = "\(sanitized).\(ext)"
        }

        let newURL = url.deletingLastPathComponent().appendingPathComponent(sanitized)
        guard newURL != url else { return url }

        try FileManager.default.moveItem(at: url, to: newURL)

        let newPath = newURL.path
        let oldAbs = url.absoluteString

        // 1. Update Favorites
        if favorites.contains(oldPath) {
            favorites.remove(oldPath)
            favorites.insert(newPath)
            persistFavorites()
        }

        // 2. Update Playlists
        for i in 0..<playlists.count {
            if let pIdx = playlists[i].itemPaths.firstIndex(of: oldPath) {
                playlists[i].itemPaths[pIdx] = newPath
                playlists[i].updatedAt = Date()
            }
        }
        persistPlaylists()

        // 3. Update History
        Task {
            await historyStore.deleteRecord(mediaIdentifier: oldAbs)
            await historyStore.deleteRecord(mediaIdentifier: oldPath)
        }

        // 4. Update in-memory items
        if let idx = mediaItems.firstIndex(where: { $0.url.path == oldPath }) {
            mediaItems[idx] = LIDMediaItem(
                url: newURL,
                title: newURL.deletingPathExtension().lastPathComponent,
                fileSize: mediaItems[idx].fileSize,
                mediaType: mediaItems[idx].mediaType,
                dateAdded: mediaItems[idx].dateAdded,
                isFavorite: favorites.contains(newPath),
                lastPositionSeconds: mediaItems[idx].lastPositionSeconds,
                progressFraction: mediaItems[idx].progressFraction,
                isCompleted: mediaItems[idx].isCompleted
            )
        }

        return newURL
    }

    /// Deletes a media file from disk or moves it safely to the trash, pruning from library, playlists, favorites, and history.
    public func deleteMediaFile(url: URL, moveToTrash: Bool = true) throws {
        let path = url.path
        let abs = url.absoluteString
        let fm = FileManager.default

        if fm.fileExists(atPath: path) {
            if moveToTrash {
                try? fm.createDirectory(at: trashDirectoryURL, withIntermediateDirectories: true)
                let trashDest = FileConflictResolver.uniqueDestinationURL(desiredFilename: url.lastPathComponent, directory: trashDirectoryURL)
                let size = (try? fm.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
                try fm.moveItem(at: url, to: trashDest)
                let trashRecord = LIDTrashItem(originalURL: url, trashURL: trashDest, dateDeleted: Date(), fileSize: size)
                trashItems.append(trashRecord)
                persistTrash()
            } else {
                try fm.removeItem(at: url)
            }
        }

        // Prune Favorites
        favorites.remove(path)
        favorites.remove(abs)
        persistFavorites()

        // Prune Playlists
        for i in 0..<playlists.count {
            playlists[i].itemPaths.removeAll { $0 == path }
        }
        persistPlaylists()

        // Prune Folders
        for i in 0..<folders.count {
            folders[i].itemPaths.removeAll { $0 == path }
        }
        persistFolders()

        // Prune History
        Task {
            await historyStore.deleteRecord(mediaIdentifier: abs)
            await historyStore.deleteRecord(mediaIdentifier: path)
        }

        // Prune in-memory items
        mediaItems.removeAll { $0.url.path == path || $0.url.absoluteString == abs }
    }

    /// Restores a deleted item from trash back to its original location (or safe sibling if occupied).
    public func restoreFromTrash(item: LIDTrashItem) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: item.trashURL.path) else {
            trashItems.removeAll { $0.id == item.id }
            persistTrash()
            return
        }

        let originalDir = item.originalURL.deletingLastPathComponent()
        try? fm.createDirectory(at: originalDir, withIntermediateDirectories: true)
        let restoreURL = FileConflictResolver.uniqueDestinationURL(desiredFilename: item.originalURL.lastPathComponent, directory: originalDir)
        try fm.moveItem(at: item.trashURL, to: restoreURL)

        trashItems.removeAll { $0.id == item.id }
        persistTrash()
    }

    /// Empties all items permanently from the application trash.
    public func emptyTrash() throws {
        let fm = FileManager.default
        for item in trashItems {
            try? fm.removeItem(at: item.trashURL)
        }
        if fm.fileExists(atPath: trashDirectoryURL.path) {
            try? fm.removeItem(at: trashDirectoryURL)
            try? fm.createDirectory(at: trashDirectoryURL, withIntermediateDirectories: true)
        }
        trashItems.removeAll()
        persistTrash()
    }

    // MARK: - Metadata Enrichment & Editing

    /// Updates custom metadata (title, tags, notes) for a media item.
    public func updateItemMetadata(
        url: URL,
        tags: [String]? = nil,
        notes: String? = nil,
        customTitle: String? = nil
    ) {
        if let idx = mediaItems.firstIndex(where: { $0.url.path == url.path || $0.url.absoluteString == url.absoluteString }) {
            if let customTitle = customTitle {
                mediaItems[idx].title = customTitle
            }
            if let tags = tags {
                mediaItems[idx].tags = tags
            }
            if let notes = notes {
                mediaItems[idx].notes = notes
            }
        }
    }

    // MARK: - Storage Breakdown & Diagnostics

    /// Computes the precise storage breakdown (video, audio, torrent, scratch, other) across the directory.
    public func calculateStorageBreakdown(in baseDirectory: URL) async -> StorageBreakdown {
        var videoBytes: Int64 = 0
        var audioBytes: Int64 = 0
        var torrentBytes: Int64 = 0
        var scratchBytes: Int64 = 0
        var otherBytes: Int64 = 0

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: baseDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            options: []
        ) else {
            return StorageBreakdown()
        }

        for case let fileURL as URL in enumerator {
            guard let attrs = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]),
                  !(attrs.isDirectory ?? false),
                  let size = attrs.fileSize.map(Int64.init) else { continue }

            let ext = fileURL.pathExtension.lowercased()
            let path = fileURL.path.lowercased()

            if path.contains(".trash") || path.contains(".tmp") || ext == "part" || ext == "tmp" {
                scratchBytes += size
            } else if ext == "torrent" || path.contains("torrent") {
                torrentBytes += size
            } else if fileURL.isVideoMedia || ["mp4", "m4v", "mov", "mkv", "avi", "webm", "ts"].contains(ext) {
                videoBytes += size
            } else if fileURL.isAudioMedia || ["mp3", "m4a", "aac", "flac", "wav", "ogg", "opus"].contains(ext) {
                audioBytes += size
            } else {
                otherBytes += size
            }
        }

        return StorageBreakdown(
            videoBytes: videoBytes,
            audioBytes: audioBytes,
            torrentBytes: torrentBytes,
            scratchBytes: scratchBytes,
            otherBytes: otherBytes
        )
    }

    // MARK: - Orphan File Detection & Cleanup

    /// Identifies files present in the base directory that do not belong to active/known transfers, media library, or trash.
    public func detectOrphanFiles(
        in baseDirectory: URL,
        knownTransfers: [UnifiedTransfer] = []
    ) async -> [URL] {
        var knownPaths: Set<String> = []
        for transfer in knownTransfers {
            knownPaths.insert(transfer.destinationURL.resolvingSymlinksInPath().path)
        }
        for item in mediaItems {
            knownPaths.insert(item.url.resolvingSymlinksInPath().path)
        }
        for trash in trashItems {
            knownPaths.insert(trash.trashURL.resolvingSymlinksInPath().path)
        }

        var orphans: [URL] = []
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: baseDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        for case let fileURL as URL in enumerator {
            guard let isRegular = (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile, isRegular else {
                continue
            }
            let canonical = fileURL.resolvingSymlinksInPath().path
            if !knownPaths.contains(canonical) && !canonical.contains(".Trash") {
                orphans.append(fileURL)
            }
        }

        return orphans
    }

    /// Deletes the specified orphan files and returns total bytes recovered.
    public func cleanupOrphanFiles(urls: [URL]) throws -> Int64 {
        let fm = FileManager.default
        var totalFreed: Int64 = 0
        for url in urls {
            if let attrs = try? fm.attributesOfItem(atPath: url.path),
               let size = (attrs[.size] as? NSNumber)?.int64Value {
                totalFreed += size
            }
            try? fm.removeItem(at: url)
        }
        return totalFreed
    }

    // MARK: - Bulk Operations

    /// Bulk moves multiple media items to a destination folder.
    public func bulkMoveToFolder(itemPaths: [String], toFolderID: UUID) {
        for path in itemPaths {
            addItemToFolder(folderID: toFolderID, itemPath: path)
        }
    }

    /// Bulk assigns a tag to multiple media items.
    public func bulkAddTag(itemPaths: [String], tag: String) {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        for path in itemPaths {
            if let idx = mediaItems.firstIndex(where: { $0.url.path == path }) {
                if !mediaItems[idx].tags.contains(trimmed) {
                    mediaItems[idx].tags.append(trimmed)
                }
            }
        }
    }

    /// Bulk deletes multiple media items.
    public func bulkDelete(itemPaths: [String], moveToTrash: Bool = true) throws {
        for path in itemPaths {
            try deleteMediaFile(url: URL(fileURLWithPath: path), moveToTrash: moveToTrash)
        }
    }

    // MARK: - Persistence Internals

    public struct LIDFavoritesPayload: Codable, SchemaVersioned {
        public static let currentSchemaVersion: Int = 1
        public var schemaVersion: Int
        public var favorites: [String]

        public init(schemaVersion: Int = Self.currentSchemaVersion, favorites: [String]) {
            self.schemaVersion = schemaVersion
            self.favorites = favorites
        }

        private enum CodingKeys: String, CodingKey {
            case schemaVersion, favorites
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
            self.favorites = try container.decode([String].self, forKey: .favorites)
        }
    }

    public struct LIDPlaylistsPayload: Codable, SchemaVersioned {
        public static let currentSchemaVersion: Int = 1
        public var schemaVersion: Int
        public var playlists: [LIDPlaylist]

        public init(schemaVersion: Int = Self.currentSchemaVersion, playlists: [LIDPlaylist]) {
            self.schemaVersion = schemaVersion
            self.playlists = playlists
        }

        private enum CodingKeys: String, CodingKey {
            case schemaVersion, playlists
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
            self.playlists = try container.decode([LIDPlaylist].self, forKey: .playlists)
        }
    }

    public struct LIDFoldersPayload: Codable, SchemaVersioned {
        public static let currentSchemaVersion: Int = 1
        public var schemaVersion: Int
        public var folders: [LIDFolder]

        public init(schemaVersion: Int = Self.currentSchemaVersion, folders: [LIDFolder]) {
            self.schemaVersion = schemaVersion
            self.folders = folders
        }

        private enum CodingKeys: String, CodingKey {
            case schemaVersion, folders
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
            self.folders = try container.decode([LIDFolder].self, forKey: .folders)
        }
    }

    public struct LIDTrashPayload: Codable, SchemaVersioned {
        public static let currentSchemaVersion: Int = 1
        public var schemaVersion: Int
        public var items: [LIDTrashItem]

        public init(schemaVersion: Int = Self.currentSchemaVersion, items: [LIDTrashItem]) {
            self.schemaVersion = schemaVersion
            self.items = items
        }

        private enum CodingKeys: String, CodingKey {
            case schemaVersion, items
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
            self.items = try container.decode([LIDTrashItem].self, forKey: .items)
        }
    }

    private func loadState() {
        guard !isLoaded else { return }
        isLoaded = true

        // Load Favorites
        if FileManager.default.fileExists(atPath: favoritesStorageURL.path) {
            do {
                if let payload = try DurableStorage.load(
                    from: favoritesStorageURL,
                    legacyFallback: { data in
                        let list = try JSONDecoder().decode([String].self, from: data)
                        return LIDFavoritesPayload(schemaVersion: 0, favorites: list)
                    }
                ) as LIDFavoritesPayload? {
                    self.favorites = Set(payload.favorites)
                }
            } catch {
                PipelineLogger.shared.log(stage: .persistence, message: "[LIDLibraryStore] Corrupt favorites file at \(favoritesStorageURL.path) was quarantined: \(error)")
            }
        }

        // Load Playlists
        if FileManager.default.fileExists(atPath: playlistsStorageURL.path) {
            do {
                if let payload = try DurableStorage.load(
                    from: playlistsStorageURL,
                    legacyFallback: { data in
                        let list = try JSONDecoder().decode([LIDPlaylist].self, from: data)
                        return LIDPlaylistsPayload(schemaVersion: 0, playlists: list)
                    }
                ) as LIDPlaylistsPayload? {
                    self.playlists = payload.playlists
                }
            } catch {
                PipelineLogger.shared.log(stage: .persistence, message: "[LIDLibraryStore] Corrupt playlists file at \(playlistsStorageURL.path) was quarantined: \(error)")
            }
        }

        // Load Folders
        if FileManager.default.fileExists(atPath: foldersStorageURL.path) {
            do {
                if let payload = try DurableStorage.load(
                    from: foldersStorageURL,
                    legacyFallback: { data in
                        let list = try JSONDecoder().decode([LIDFolder].self, from: data)
                        return LIDFoldersPayload(schemaVersion: 0, folders: list)
                    }
                ) as LIDFoldersPayload? {
                    self.folders = payload.folders
                }
            } catch {
                PipelineLogger.shared.log(stage: .persistence, message: "[LIDLibraryStore] Corrupt folders file at \(foldersStorageURL.path) was quarantined: \(error)")
            }
        }

        // Initialize default Smart Folders if not present
        if !self.folders.contains(where: { $0.isSmartFolder }) {
            let smartFolders: [LIDFolder] = [
                LIDFolder(name: "Videos > 1GB", isSmartFolder: true, smartCriteria: .videosOver1GB),
                LIDFolder(name: "Torrents", isSmartFolder: true, smartCriteria: .torrents),
                LIDFolder(name: "Live Recordings", isSmartFolder: true, smartCriteria: .liveRecordings),
                LIDFolder(name: "Recent Downloads", isSmartFolder: true, smartCriteria: .recentDownloads)
            ]
            self.folders.append(contentsOf: smartFolders)
            persistFolders()
        }

        // Load Trash
        if FileManager.default.fileExists(atPath: trashStorageURL.path) {
            do {
                if let payload = try DurableStorage.load(
                    from: trashStorageURL,
                    legacyFallback: { data in
                        let list = try JSONDecoder().decode([LIDTrashItem].self, from: data)
                        return LIDTrashPayload(schemaVersion: 0, items: list)
                    }
                ) as LIDTrashPayload? {
                    self.trashItems = payload.items
                }
            } catch {
                PipelineLogger.shared.log(stage: .persistence, message: "[LIDLibraryStore] Corrupt trash file at \(trashStorageURL.path) was quarantined: \(error)")
            }
        }
    }

    private func persistFavorites() {
        let payload = LIDFavoritesPayload(favorites: Array(favorites))
        do {
            let data = try JSONEncoder().encode(payload)
            try DurableStorage.writeAtomically(data, to: favoritesStorageURL)
        } catch {
            PipelineLogger.shared.log(stage: .persistence, message: "Failed to persist favorites: \(error)")
        }
    }

    private func persistPlaylists() {
        let payload = LIDPlaylistsPayload(playlists: playlists)
        do {
            let data = try JSONEncoder().encode(payload)
            try DurableStorage.writeAtomically(data, to: playlistsStorageURL)
        } catch {
            PipelineLogger.shared.log(stage: .persistence, message: "Failed to persist playlists: \(error)")
        }
    }

    private func persistFolders() {
        let payload = LIDFoldersPayload(folders: folders)
        do {
            let data = try JSONEncoder().encode(payload)
            try DurableStorage.writeAtomically(data, to: foldersStorageURL)
        } catch {
            PipelineLogger.shared.log(stage: .persistence, message: "Failed to persist folders: \(error)")
        }
    }

    private func persistTrash() {
        let payload = LIDTrashPayload(items: trashItems)
        do {
            let data = try JSONEncoder().encode(payload)
            try DurableStorage.writeAtomically(data, to: trashStorageURL)
        } catch {
            PipelineLogger.shared.log(stage: .persistence, message: "Failed to persist trash: \(error)")
        }
    }

    private func updateItemFavoriteState(path: String, isFavorite: Bool) {
        if let idx = mediaItems.firstIndex(where: { $0.url.path == path }) {
            mediaItems[idx].isFavorite = isFavorite
        }
    }
}
