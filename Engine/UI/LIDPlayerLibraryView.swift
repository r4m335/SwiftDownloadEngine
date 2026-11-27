import Foundation

#if canImport(SwiftUI)
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

#if canImport(AVFoundation)
import AVFoundation
#endif

/// Tab sections in the unified player library.
public enum LIDLibrarySection: String, CaseIterable, Identifiable {
    case all = "All Media"
    case continueWatching = "Continue Watching"
    case folders = "Folders"
    case playlists = "Playlists"
    case favorites = "Favorites"
    case history = "History"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .all: return "film.stack"
        case .continueWatching: return "play.circle"
        case .folders: return "folder.fill"
        case .playlists: return "music.note.list"
        case .favorites: return "star.fill"
        case .history: return "clock.arrow.circlepath"
        }
    }
}

/// Unified media library interface supporting auto-scanning, continue watching,
/// favorites, playlists, technical media inspection, and file management.
public struct LIDPlayerLibraryView: View {
    public let baseDirectory: URL
    public var knownTransfers: [UnifiedTransfer] = []
    public var onDismiss: (() -> Void)? = nil

    @ObservedObject public var libraryStore: LIDLibraryStore
    public let historyStore: LIDPlaybackHistoryStore

    @State private var selectedSection: LIDLibrarySection = .all
    @State private var mediaFilter: LIDMediaType = .all
    @State private var searchText: String = ""
    @AppStorage("mediaLibraryGridView") private var isGridView: Bool = false

    // Playback presentation
    @State private var activePlaybackURL: URL? = nil
    @State private var activePlaybackTitle: String = ""

    // Modals
    @State private var inspectingMediaURL: URL? = nil
    @State private var itemToAddToPlaylist: LIDMediaItem? = nil
    @State private var itemToAddToFolder: LIDMediaItem? = nil
    @State private var showCreatePlaylistAlert: Bool = false
    @State private var newPlaylistName: String = ""
    @State private var showCreateFolderAlert: Bool = false
    @State private var newFolderName: String = ""
    @State private var itemToRename: LIDMediaItem? = nil
    @State private var renameText: String = ""
    @State private var itemToDelete: LIDMediaItem? = nil
    @State private var itemForMetadataEdit: LIDMediaItem? = nil
    @State private var editTitle: String = ""
    @State private var editTags: String = ""
    @State private var editNotes: String = ""
    @State private var showClearHistoryAlert: Bool = false

    // History state
    @State private var historyRecords: [LIDPlaybackRecord] = []

    @MainActor
    public init(
        baseDirectory: URL,
        knownTransfers: [UnifiedTransfer] = [],
        libraryStore: LIDLibraryStore = .shared,
        historyStore: LIDPlaybackHistoryStore = .shared,
        onDismiss: (() -> Void)? = nil
    ) {
        self.baseDirectory = baseDirectory
        self.knownTransfers = knownTransfers
        self.libraryStore = libraryStore
        self.historyStore = historyStore
        self.onDismiss = onDismiss
    }

    public var body: some View {
        applyLibraryModals(
            NavigationView {
                VStack(spacing: 0) {
                    // Top Section Horizontal Pill Bar
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(LIDLibrarySection.allCases) { sec in
                                let isSelected = selectedSection == sec
                                Button {
                                    withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                                        selectedSection = sec
                                    }
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: sec.icon)
                                            .scaledFont(size: 12, weight: .semibold)
                                        Text(sec.rawValue)
                                            .font(.caption.weight(.semibold))
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(
                                        ZStack {
                                            if isSelected {
                                                Capsule().fill(Color.blue)
                                            } else {
                                                Capsule().fill(.regularMaterial)
                                            }
                                        }
                                    )
                                    .foregroundColor(isSelected ? .white : .primary)
                                    .clipShape(Capsule())
                                    .overlay(
                                        Capsule()
                                            .stroke(isSelected ? Color.clear : Color.primary.opacity(0.08), lineWidth: 1)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                    }

                    // Sub-filter for All Media
                    if selectedSection == .all {
                        allMediaFilterBar
                    }

                    // Main Content
                    switch selectedSection {
                    case .all:
                        allMediaListView
                    case .continueWatching:
                        continueWatchingListView
                    case .folders:
                        foldersListView
                    case .playlists:
                        playlistsListView
                    case .favorites:
                        favoritesListView
                    case .history:
                        historyListView
                    }
                }
                .navigationTitle("Media Library")
                #if os(iOS)
                .navigationBarTitleDisplayMode(onDismiss == nil ? .large : .inline)
                #endif
                .searchable(text: $searchText, prompt: "Search videos & audio...")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        if let dismiss = onDismiss {
                            Button("Done") { dismiss() }
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        HStack(spacing: 12) {
                            if selectedSection == .all {
                                Button {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                        isGridView.toggle()
                                    }
                                } label: {
                                    Image(systemName: isGridView ? "list.bullet" : "square.grid.2x2")
                                        .scaledFont(size: 15, weight: .semibold)
                                }
                                .accessibilityLabel(isGridView ? "Switch to List View" : "Switch to Grid View")
                            }

                            Button {
                                Task { await refreshLibrary() }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                    }
                }
                .task {
                    await refreshLibrary()
                }
            }
            #if os(iOS)
            .navigationViewStyle(.stack)
            #endif
        )
    }

    @ViewBuilder
    private func applyLibraryModals<Content: View>(_ content: Content) -> some View {
        content
            .lidPlayerPresentation(url: $activePlaybackURL, title: activePlaybackTitle)
            .sheet(item: Binding<IdentifiableURL?>(
                get: { inspectingMediaURL.map { IdentifiableURL(url: $0) } },
                set: { inspectingMediaURL = $0?.url }
            )) { item in
                LIDMediaInfoSheet(url: item.url)
            }
            .sheet(item: Binding<IdentifiableItemWrapper?>(
                get: { itemToAddToPlaylist.map { IdentifiableItemWrapper(item: $0) } },
                set: { itemToAddToPlaylist = $0?.item }
            )) { wrapper in
                addToPlaylistSheet(item: wrapper.item)
            }
            .sheet(item: Binding<IdentifiableItemWrapper?>(
                get: { itemToAddToFolder.map { IdentifiableItemWrapper(item: $0) } },
                set: { itemToAddToFolder = $0?.item }
            )) { wrapper in
                addToFolderSheet(item: wrapper.item)
            }
            .sheet(item: Binding<IdentifiableItemWrapper?>(
                get: { itemForMetadataEdit.map { IdentifiableItemWrapper(item: $0) } },
                set: { itemForMetadataEdit = $0?.item }
            )) { wrapper in
                metadataEditSheet(item: wrapper.item)
            }
            .alert("Create Folder", isPresented: $showCreateFolderAlert) {
                TextField("Folder Name", text: $newFolderName)
                Button("Cancel", role: .cancel) { newFolderName = "" }
                Button("Create") {
                    if !newFolderName.trimmingCharacters(in: .whitespaces).isEmpty {
                        _ = libraryStore.createFolder(name: newFolderName)
                        newFolderName = ""
                    }
                }
            }
            .alert("Create Playlist", isPresented: $showCreatePlaylistAlert) {
                TextField("Playlist Name", text: $newPlaylistName)
                Button("Cancel", role: .cancel) { newPlaylistName = "" }
                Button("Create") {
                    if !newPlaylistName.trimmingCharacters(in: .whitespaces).isEmpty {
                        _ = libraryStore.createPlaylist(name: newPlaylistName)
                        newPlaylistName = ""
                    }
                }
            }
            .alert("Rename File", isPresented: Binding(
                get: { itemToRename != nil },
                set: { if !$0 { itemToRename = nil } }
            )) {
                TextField("New Name", text: $renameText)
                Button("Cancel", role: .cancel) { itemToRename = nil }
                Button("Rename") {
                    if let item = itemToRename, !renameText.trimmingCharacters(in: .whitespaces).isEmpty {
                        try? libraryStore.renameMediaFile(url: item.url, newFileName: renameText)
                        itemToRename = nil
                    }
                }
            }
            .alert("Delete File", isPresented: Binding(
                get: { itemToDelete != nil },
                set: { if !$0 { itemToDelete = nil } }
            )) {
                Button("Cancel", role: .cancel) { itemToDelete = nil }
                Button("Move to Trash", role: .destructive) {
                    if let item = itemToDelete {
                        try? libraryStore.deleteMediaFile(url: item.url, moveToTrash: true)
                        itemToDelete = nil
                    }
                }
                Button("Delete Permanently", role: .destructive) {
                    if let item = itemToDelete {
                        try? libraryStore.deleteMediaFile(url: item.url, moveToTrash: false)
                        itemToDelete = nil
                    }
                }
            } message: {
                Text("Choose whether to move '\(itemToDelete?.title ?? "")' to Trash for safe recovery or delete permanently.")
            }
            .alert("Clear Playback History", isPresented: $showClearHistoryAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Clear All", role: .destructive) {
                    Task {
                        await historyStore.clearAllHistory()
                        await refreshHistory()
                    }
                }
            } message: {
                Text("Are you sure you want to clear your entire watch history?")
            }
    }

    // MARK: - Sub-Filter Bar

    private var allMediaFilterBar: some View {
        HStack(spacing: 8) {
            ForEach([LIDMediaType.all, .video, .audio], id: \.self) { type in
                let isSelected = mediaFilter == type
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
                        mediaFilter = type
                    }
                } label: {
                    Text(type.rawValue)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(isSelected ? Color.blue.opacity(0.16) : Color.secondary.opacity(0.1))
                        )
                        .foregroundColor(isSelected ? .blue : .secondary)
                        .overlay(
                            Capsule()
                                .stroke(isSelected ? Color.blue.opacity(0.35) : Color.clear, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    // MARK: - Sections

    private var allMediaListView: some View {
        let filtered = libraryStore.mediaItems.filter { item in
            let matchesFilter = (mediaFilter == .all) || (item.mediaType == mediaFilter)
            let matchesSearch = searchText.isEmpty || item.title.localizedCaseInsensitiveContains(searchText)
            return matchesFilter && matchesSearch
        }

        return Group {
            if filtered.isEmpty {
                emptyStateView(icon: "film", title: "No Media Found", message: "Completed video and audio downloads will appear here.")
            } else if isGridView {
                ScrollView {
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: 14),
                            GridItem(.flexible(), spacing: 14)
                        ],
                        spacing: 16
                    ) {
                        ForEach(filtered) { item in
                            mediaGridCard(for: item)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
            } else {
                List {
                    ForEach(filtered) { item in
                        mediaRow(for: item)
                    }
                }
                .listStyle(PlainListStyle())
            }
        }
    }

    private var continueWatchingListView: some View {
        let inProgress = libraryStore.continueWatchingItems()
        return Group {
            if inProgress.isEmpty {
                emptyStateView(icon: "play.circle", title: "No In-Progress Media", message: "Videos you start watching will appear here with saved progress.")
            } else {
                List {
                    ForEach(inProgress) { item in
                        mediaRow(for: item, showResumeBadge: true)
                    }
                }
                .listStyle(PlainListStyle())
            }
        }
    }

    private var playlistsListView: some View {
        List {
            Section {
                Button {
                    showCreatePlaylistAlert = true
                } label: {
                    Label("Create New Playlist", systemImage: "plus.circle.fill")
                        .foregroundColor(.blue)
                }
            }

            if libraryStore.playlists.isEmpty {
                Text("No playlists yet. Tap 'Create New Playlist' to create one.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(libraryStore.playlists) { playlist in
                    NavigationLink(destination: playlistDetailView(playlist: playlist)) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(playlist.name)
                                .font(.headline)
                            Text("\(playlist.itemPaths.count) item\(playlist.itemPaths.count == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .onDelete { indexSet in
                    for idx in indexSet {
                        let id = libraryStore.playlists[idx].id
                        libraryStore.deletePlaylist(id: id)
                    }
                }
            }
        }
        .libraryListStyle()
    }

    private var favoritesListView: some View {
        let favs = libraryStore.favoriteItems()
        return Group {
            if favs.isEmpty {
                emptyStateView(icon: "star", title: "No Favorites", message: "Star videos or audio tracks to easily find them here.")
            } else {
                List {
                    ForEach(favs) { item in
                        mediaRow(for: item)
                    }
                }
                .listStyle(PlainListStyle())
            }
        }
    }

    private var historyListView: some View {
        Group {
            if historyRecords.isEmpty {
                emptyStateView(icon: "clock.arrow.circlepath", title: "No History", message: "Your playback history will be tracked here.")
            } else {
                List {
                    Section {
                        Button(role: .destructive) {
                            showClearHistoryAlert = true
                        } label: {
                            Label("Clear All History", systemImage: "trash")
                        }
                    }

                    ForEach(historyRecords) { record in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.title)
                                .font(.headline)
                                .lineLimit(1)

                            HStack {
                                Text(record.isCompleted ? "Completed" : String(format: "Watched %d%%", Int(record.progressFraction * 100)))
                                    .font(.caption.bold())
                                    .foregroundColor(record.isCompleted ? .green : .blue)

                                Spacer()

                                Text(record.lastPlayedAt, style: .date)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }

                            if !record.isCompleted && record.durationSeconds > 0 {
                                ProgressView(value: record.progressFraction)
                                    .accentColor(.blue)
                            }
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if let item = libraryStore.mediaItems.first(where: {
                                $0.url.absoluteString == record.mediaIdentifier || $0.url.path == record.mediaIdentifier
                            }) {
                                playMedia(item)
                            }
                        }
                    }
                    .onDelete { indexSet in
                        for idx in indexSet {
                            let rec = historyRecords[idx]
                            Task {
                                await historyStore.deleteRecord(mediaIdentifier: rec.mediaIdentifier)
                                await refreshHistory()
                            }
                        }
                    }
                }
                .libraryListStyle()
            }
        }
    }

    // MARK: - Media Row & Grid Components

    @ViewBuilder
    private func mediaGridCard(for item: LIDMediaItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                LIDMediaThumbnailView(url: item.url, mediaType: item.mediaType)
                    .frame(height: 112)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                HStack(spacing: 4) {
                    if item.isFavorite {
                        Image(systemName: "star.fill")
                            .scaledFont(size: 10, weight: .bold)
                            .foregroundColor(.yellow)
                            .padding(4)
                            .background(.ultraThinMaterial, in: Circle())
                    }

                    Text(item.url.pathExtension.uppercased())
                        .scaledFont(size: 9, weight: .bold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.65))
                        .clipShape(Capsule())
                }
                .padding(6)

                if item.progressFraction > 0.02 && !item.isCompleted {
                    VStack {
                        Spacer()
                        ProgressView(value: item.progressFraction)
                            .frame(height: 3)
                            .tint(.blue)
                            .background(Color.black.opacity(0.4))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.primary)
                    .lineLimit(2)

                Text(ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 4)
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            playMedia(item)
        }
        .contextMenu {
            mediaContextMenuItems(for: item)
        }
    }

    @ViewBuilder
    private func mediaContextMenuItems(for item: LIDMediaItem) -> some View {
        Button {
            playMedia(item)
        } label: {
            Label("Play in LID Player", systemImage: "play.fill")
        }

        Button {
            libraryStore.toggleFavorite(for: item)
        } label: {
            Label(item.isFavorite ? "Remove from Favorites" : "Add to Favorites", systemImage: item.isFavorite ? "star.slash" : "star.fill")
        }

        Button {
            itemToAddToPlaylist = item
        } label: {
            Label("Add to Playlist", systemImage: "text.badge.plus")
        }

        Button {
            itemToAddToFolder = item
        } label: {
            Label("Add to Folder", systemImage: "folder.badge.plus")
        }

        Button {
            itemForMetadataEdit = item
            editTitle = item.title
            editTags = item.tags.joined(separator: ", ")
            editNotes = item.notes ?? ""
        } label: {
            Label("Edit Metadata", systemImage: "tag")
        }

        Button {
            inspectingMediaURL = item.url
        } label: {
            Label("Media Info", systemImage: "info.circle")
        }

        #if canImport(UIKit)
        Button {
            shareMediaFile(url: item.url)
        } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        #endif

        Button {
            itemToRename = item
            renameText = item.title
        } label: {
            Label("Rename", systemImage: "pencil")
        }

        Button(role: .destructive) {
            itemToDelete = item
        } label: {
            Label("Delete File", systemImage: "trash")
        }
    }

    private func mediaRow(for item: LIDMediaItem, showResumeBadge: Bool = false) -> some View {
        HStack(spacing: 12) {
            // Widescreen Media Thumbnail with progress overlay
            ZStack(alignment: .bottom) {
                LIDMediaThumbnailView(url: item.url, mediaType: item.mediaType)
                    .frame(width: 76, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 0.8)
                    )

                if item.progressFraction > 0.02 && !item.isCompleted {
                    GeometryReader { geo in
                        VStack {
                            Spacer()
                            ZStack(alignment: .leading) {
                                Rectangle()
                                    .fill(Color.black.opacity(0.45))
                                    .frame(height: 3)
                                Rectangle()
                                    .fill(Color.blue)
                                    .frame(width: geo.size.width * min(1, max(0, item.progressFraction)), height: 3)
                            }
                        }
                    }
                    .frame(width: 76, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }

            // Title & Details
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(item.url.pathExtension.uppercased())
                        .scaledFont(size: 10, weight: .bold)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12), in: Capsule())

                    Text(ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file))
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    if showResumeBadge && item.lastPositionSeconds > 0 {
                        Text("Resume \(formatTime(item.lastPositionSeconds))")
                            .scaledFont(size: 10, weight: .semibold)
                            .foregroundColor(.blue)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.12), in: Capsule())
                    }
                }
            }

            Spacer(minLength: 4)

            // Favorite Button
            Button {
                libraryStore.toggleFavorite(for: item)
            } label: {
                Image(systemName: item.isFavorite ? "star.fill" : "star")
                    .scaledFont(size: 15)
                    .foregroundColor(item.isFavorite ? .yellow : .secondary.opacity(0.45))
            }
            .buttonStyle(BorderlessButtonStyle())

            // Context Menu Actions
            Menu {
                mediaContextMenuItems(for: item)
            } label: {
                Image(systemName: "ellipsis")
                    .scaledFont(size: 16, weight: .semibold)
                    .foregroundColor(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            playMedia(item)
        }
        .padding(.vertical, 5)
    }

    // MARK: - Playlist Detail View

    private func playlistDetailView(playlist: LIDPlaylist) -> some View {
        let items: [LIDMediaItem] = playlist.itemPaths.compactMap { path in
            libraryStore.mediaItems.first(where: { $0.url.path == path })
        }

        return List {
            Section {
                HStack(spacing: 16) {
                    Button {
                        if let first = items.first {
                            playMedia(first)
                        }
                    } label: {
                        HStack {
                            Image(systemName: "play.fill")
                            Text("Play All")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(items.isEmpty)

                    Button {
                        if let randomItem = items.randomElement() {
                            playMedia(randomItem)
                        }
                    } label: {
                        HStack {
                            Image(systemName: "shuffle")
                            Text("Shuffle")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(items.isEmpty)
                }
            }

            Section(header: Text("Tracks (\(items.count))")) {
                if items.isEmpty {
                    Text("No media added to this playlist yet.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(items) { item in
                        mediaRow(for: item)
                    }
                    .onDelete { indexSet in
                        for idx in indexSet {
                            libraryStore.removeItemFromPlaylist(playlistID: playlist.id, itemPath: items[idx].url.path)
                        }
                    }
                    .onMove { indices, newOffset in
                        libraryStore.reorderPlaylist(playlistID: playlist.id, fromIndices: indices, toOffset: newOffset)
                    }
                }
            }
        }
        .libraryListStyle()
        .navigationTitle(playlist.name)
        .toolbar {
            #if os(iOS)
            EditButton()
            #endif
        }
    }

    // MARK: - Add To Playlist Modal Sheet

    private func addToPlaylistSheet(item: LIDMediaItem) -> some View {
        NavigationView {
            List {
                if libraryStore.playlists.isEmpty {
                    Text("No playlists yet. Create one in the Playlists tab.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(libraryStore.playlists) { pl in
                        Button {
                            libraryStore.addItemToPlaylist(playlistID: pl.id, item: item)
                            itemToAddToPlaylist = nil
                        } label: {
                            HStack {
                                Text(pl.name)
                                Spacer()
                                if pl.itemPaths.contains(item.url.path) {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add to Playlist")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { itemToAddToPlaylist = nil }
                }
            }
        }
    }

    // MARK: - Folders View Components

    private var foldersListView: some View {
        List {
            Section("Smart Folders") {
                ForEach(libraryStore.folders.filter(\.isSmartFolder)) { folder in
                    NavigationLink(destination: folderDetailView(folder: folder)) {
                        HStack(spacing: 12) {
                            Image(systemName: smartFolderIcon(for: folder.smartCriteria))
                                .foregroundColor(.purple)
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(folder.name)
                                    .font(.headline)
                                Text("\(libraryStore.items(in: folder).count) items")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            Section {
                Button {
                    showCreateFolderAlert = true
                } label: {
                    Label("Create New Folder", systemImage: "folder.badge.plus")
                        .foregroundColor(.blue)
                }
            } header: {
                Text("Custom Folders")
            }

            let userFolders = libraryStore.folders.filter { !$0.isSmartFolder }
            if userFolders.isEmpty {
                Text("No custom folders yet.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(userFolders) { folder in
                    NavigationLink(destination: folderDetailView(folder: folder)) {
                        HStack(spacing: 12) {
                            Image(systemName: "folder.fill")
                                .foregroundColor(.blue)
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(folder.name)
                                    .font(.headline)
                                Text("\(libraryStore.items(in: folder).count) items")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .onDelete { indexSet in
                    for idx in indexSet {
                        let id = userFolders[idx].id
                        libraryStore.deleteFolder(id: id)
                    }
                }
            }
        }
        .libraryListStyle()
    }

    private func smartFolderIcon(for criteria: LIDSmartFolderCriteria?) -> String {
        switch criteria {
        case .videosOver1GB: return "film.stack.fill"
        case .torrents: return "arrow.down.circle.fill"
        case .liveRecordings: return "record.circle.fill"
        case .recentDownloads: return "clock.fill"
        case .none: return "folder.fill"
        }
    }

    private func folderDetailView(folder: LIDFolder) -> some View {
        let items = libraryStore.items(in: folder)
        return Group {
            if items.isEmpty {
                emptyStateView(icon: "folder", title: "Folder Empty", message: "Items added to this folder will appear here.")
            } else {
                List {
                    ForEach(items) { item in
                        mediaRow(for: item)
                    }
                }
                .listStyle(PlainListStyle())
            }
        }
        .navigationTitle(folder.name)
    }

    // MARK: - Add To Folder Modal Sheet

    private func addToFolderSheet(item: LIDMediaItem) -> some View {
        NavigationView {
            List {
                let userFolders = libraryStore.folders.filter { !$0.isSmartFolder }
                if userFolders.isEmpty {
                    Text("No custom folders yet. Create one in the Folders tab.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(userFolders) { f in
                        Button {
                            libraryStore.addItemToFolder(folderID: f.id, itemPath: item.url.path)
                            itemToAddToFolder = nil
                        } label: {
                            HStack {
                                Text(f.name)
                                Spacer()
                                if f.itemPaths.contains(item.url.path) {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add to Folder")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { itemToAddToFolder = nil }
                }
            }
        }
    }

    // MARK: - Metadata Edit Modal Sheet

    private func metadataEditSheet(item: LIDMediaItem) -> some View {
        NavigationView {
            Form {
                Section("Title") {
                    TextField("Title", text: $editTitle)
                }
                Section("Tags") {
                    TextField("Tags (comma separated)", text: $editTags)
                }
                Section("Notes") {
                    TextEditor(text: $editNotes)
                        .frame(minHeight: 80)
                }
            }
            .navigationTitle("Edit Metadata")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { itemForMetadataEdit = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let parsedTags = editTags.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        libraryStore.updateItemMetadata(
                            url: item.url,
                            tags: parsedTags,
                            notes: editNotes.trimmingCharacters(in: .whitespaces).isEmpty ? nil : editNotes,
                            customTitle: editTitle.trimmingCharacters(in: .whitespaces).isEmpty ? nil : editTitle
                        )
                        itemForMetadataEdit = nil
                    }
                }
            }
        }
    }

    // MARK: - Empty State View

    private func emptyStateView(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 14) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.12))
                    .frame(width: 72, height: 72)
                Image(systemName: icon)
                    .scaledFont(size: 30, weight: .semibold)
                    .foregroundColor(.blue)
            }
            Text(title)
                .font(.title3.bold())
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions & Helpers

    private func playMedia(_ item: LIDMediaItem) {
        activePlaybackTitle = item.title
        activePlaybackURL = item.url
    }

    private func refreshLibrary() async {
        _ = await libraryStore.scanLibrary(in: baseDirectory, knownTransfers: knownTransfers)
        await refreshHistory()
    }

    private func refreshHistory() async {
        let recs = await historyStore.historyRecords()
        self.historyRecords = recs
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && !seconds.isNaN && seconds >= 0 else { return "00:00" }
        let total = Int(seconds)
        let s = total % 60
        let m = (total / 60) % 60
        let h = total / 3600
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        } else {
            return String(format: "%02d:%02d", m, s)
        }
    }

    #if canImport(UIKit) && !os(watchOS)
    @MainActor
    private func shareMediaFile(url: URL) {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = windowScene.windows.first?.rootViewController else { return }
        let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        rootVC.present(activityVC, animated: true)
    }
    #endif
}

/// Helper wrapper for Identifiable sheet presentation.
public struct IdentifiableItemWrapper: Identifiable {
    public var id: String { item.id }
    public let item: LIDMediaItem
}

/// Detailed technical media inspector sheet displaying container, codecs, resolution, bitrate, etc.
public struct LIDMediaInfoSheet: View {
    public let url: URL
    @Environment(\.presentationMode) private var presentationMode
    @State private var detail: LIDMediaDetailInfo? = nil
    @State private var isLoading: Bool = true

    public init(url: URL) {
        self.url = url
    }

    public var body: some View {
        NavigationView {
            Group {
                if isLoading {
                    ProgressView("Inspecting media metadata...")
                } else if let info = detail {
                    List {
                        Section(header: Text("File Properties")) {
                            detailRow(title: "Filename", value: info.fileName)
                            detailRow(title: "Container", value: info.containerFormat)
                            detailRow(title: "File Size", value: info.formattedFileSize)
                            if let dur = info.durationSeconds, dur > 0 {
                                detailRow(title: "Duration", value: info.formattedDuration)
                            }
                            if let bitrate = info.bitrateBps, bitrate > 0 {
                                detailRow(title: "Bitrate", value: info.formattedBitrate)
                            }
                            detailRow(title: "Path", value: info.fileURL.path)
                        }

                        if info.videoResolution != nil || info.videoCodec != nil {
                            Section(header: Text("Video Stream")) {
                                if let res = info.videoResolution {
                                    detailRow(title: "Resolution", value: res)
                                }
                                if let codec = info.videoCodec {
                                    detailRow(title: "Codec", value: codec)
                                }
                                if let fps = info.frameRateFps {
                                    detailRow(title: "Frame Rate", value: String(format: "%.2f fps", fps))
                                }
                            }
                        }

                        if info.audioCodec != nil || info.audioChannels != nil {
                            Section(header: Text("Audio Stream")) {
                                if let codec = info.audioCodec {
                                    detailRow(title: "Codec", value: codec)
                                }
                                if let ch = info.audioChannels {
                                    detailRow(title: "Channels", value: "\(ch) (\(ch == 2 ? "Stereo" : (ch > 2 ? "\(ch).1 Surround" : "Mono")))")
                                }
                                if let rate = info.audioSampleRateHz {
                                    detailRow(title: "Sample Rate", value: String(format: "%.1f kHz", rate / 1000.0))
                                }
                                if !info.audioLanguages.isEmpty {
                                    detailRow(title: "Languages", value: info.audioLanguages.joined(separator: ", "))
                                }
                            }
                        }

                        if !info.subtitleLanguages.isEmpty {
                            Section(header: Text("Subtitles")) {
                                detailRow(title: "Tracks", value: info.subtitleLanguages.joined(separator: ", "))
                            }
                        }
                    }
                    .libraryListStyle()
                } else {
                    Text("Unable to read media properties.")
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Media Information")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
            .task {
                let inspector = LIDMediaInspector()
                self.detail = await inspector.inspect(url: url)
                self.isLoading = false
            }
        }
    }

    private func detailRow(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.subheadline)
        }
        .padding(.vertical, 2)
    }
}

extension View {
    @ViewBuilder
    fileprivate func libraryListStyle() -> some View {
        #if os(iOS)
        self.listStyle(InsetGroupedListStyle())
        #else
        self.listStyle(PlainListStyle())
        #endif
    }
}

// MARK: - Asynchronous Media Thumbnail Loader & View

#if canImport(UIKit)
private final class LIDThumbnailCache {
    static let shared = LIDThumbnailCache()
    private let cache = NSCache<NSURL, UIImage>()

    func image(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func setImage(_ image: UIImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL)
    }
}
#endif

private struct LIDMediaThumbnailView: View {
    let url: URL
    let mediaType: LIDMediaType

    #if canImport(UIKit)
    @State private var thumbnail: UIImage? = nil
    #endif

    var body: some View {
        ZStack {
            LinearGradient(
                colors: mediaType == .video
                    ? [Color.blue.opacity(0.24), Color.indigo.opacity(0.18)]
                    : [Color.orange.opacity(0.24), Color.pink.opacity(0.18)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            #if canImport(UIKit)
            if let image = thumbnail {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                fallbackIcon
            }
            #else
            fallbackIcon
            #endif
        }
        .task(id: url) {
            await loadThumbnailIfNeeded()
        }
    }

    private var fallbackIcon: some View {
        Image(systemName: mediaType == .video ? "film.fill" : "music.note")
            .scaledFont(size: 20, weight: .semibold)
            .foregroundColor(mediaType == .video ? .blue : .orange)
    }

    private func loadThumbnailIfNeeded() async {
        guard mediaType == .video else { return }
        #if canImport(UIKit) && canImport(AVFoundation)
        if let cached = LIDThumbnailCache.shared.image(for: url) {
            self.thumbnail = cached
            return
        }
        let targetURL = url
        let image: UIImage? = await Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: targetURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 320, height: 180)
            let time = CMTime(seconds: 1.5, preferredTimescale: 600)
            if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
                return UIImage(cgImage: cgImage)
            }
            let zeroTime = CMTime.zero
            if let cgImage = try? generator.copyCGImage(at: zeroTime, actualTime: nil) {
                return UIImage(cgImage: cgImage)
            }
            return nil
        }.value

        if let generated = image {
            LIDThumbnailCache.shared.setImage(generated, for: url)
            await MainActor.run {
                self.thumbnail = generated
            }
        }
        #endif
    }
}
#endif
