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

    private let favoritesStorageURL: URL
    private let playlistsStorageURL: URL
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

    /// Deletes a media file from disk and prunes it from library, playlists, favorites, and history.
    public func deleteMediaFile(url: URL) throws {
        let path = url.path
        let abs = url.absoluteString

        if FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(at: url)
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

        // Prune History
        Task {
            await historyStore.deleteRecord(mediaIdentifier: abs)
            await historyStore.deleteRecord(mediaIdentifier: path)
        }

        // Prune in-memory items
        mediaItems.removeAll { $0.url.path == path || $0.url.absoluteString == abs }
    }

    // MARK: - Persistence Internals

    private func loadState() {
        guard !isLoaded else { return }
        isLoaded = true

        // Load Favorites
        if FileManager.default.fileExists(atPath: favoritesStorageURL.path) {
            if let data = try? Data(contentsOf: favoritesStorageURL),
               let loaded = try? JSONDecoder().decode([String].self, from: data) {
                self.favorites = Set(loaded)
            }
        }

        // Load Playlists
        if FileManager.default.fileExists(atPath: playlistsStorageURL.path) {
            if let data = try? Data(contentsOf: playlistsStorageURL),
               let loaded = try? JSONDecoder().decode([LIDPlaylist].self, from: data) {
                self.playlists = loaded
            }
        }
    }

    private func persistFavorites() {
        let list = Array(favorites)
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: favoritesStorageURL, options: .atomic)
        }
    }

    private func persistPlaylists() {
        if let data = try? JSONEncoder().encode(playlists) {
            try? data.write(to: playlistsStorageURL, options: .atomic)
        }
    }

    private func updateItemFavoriteState(path: String, isFavorite: Bool) {
        if let idx = mediaItems.firstIndex(where: { $0.url.path == path }) {
            mediaItems[idx].isFavorite = isFavorite
        }
    }
}
