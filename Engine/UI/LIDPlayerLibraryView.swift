import Foundation

#if canImport(SwiftUI)
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// Tab sections in the unified player library.
public enum LIDLibrarySection: String, CaseIterable, Identifiable {
    case all = "All Media"
    case continueWatching = "Continue Watching"
    case playlists = "Playlists"
    case favorites = "Favorites"
    case history = "History"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .all: return "film.stack"
        case .continueWatching: return "play.circle"
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

    @StateObject private var libraryStore = LIDLibraryStore.shared
    @StateObject private var historyStore = LIDPlaybackHistoryStore.shared

    @State private var selectedSection: LIDLibrarySection = .all
    @State private var mediaFilter: LIDMediaType = .all
    @State private var searchText: String = ""

    // Playback presentation
    @State private var activePlaybackURL: URL? = nil
    @State private var activePlaybackTitle: String = ""

    // Modals
    @State private var inspectingMediaURL: URL? = nil
    @State private var itemToAddToPlaylist: LIDMediaItem? = nil
    @State private var showCreatePlaylistAlert: Bool = false
    @State private var newPlaylistName: String = ""
    @State private var itemToRename: LIDMediaItem? = nil
    @State private var renameText: String = ""
    @State private var itemToDelete: LIDMediaItem? = nil
    @State private var showClearHistoryAlert: Bool = false

    // History state
    @State private var historyRecords: [LIDPlaybackRecord] = []

    public init(
        baseDirectory: URL,
        knownTransfers: [UnifiedTransfer] = [],
        onDismiss: (() -> Void)? = nil
    ) {
        self.baseDirectory = baseDirectory
        self.knownTransfers = knownTransfers
        self.onDismiss = onDismiss
    }

    public var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Top Section Picker
                Picker("Section", selection: $selectedSection) {
                    ForEach(LIDLibrarySection.allCases) { sec in
                        Text(sec.rawValue).tag(sec)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
                .padding(.horizontal)
                .padding(.vertical, 8)

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
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if let dismiss = onDismiss {
                        Button("Done") { dismiss() }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await refreshLibrary() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .task {
                await refreshLibrary()
            }
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
                Button("Delete", role: .destructive) {
                    if let item = itemToDelete {
                        try? libraryStore.deleteMediaFile(url: item.url)
                        itemToDelete = nil
                    }
                }
            } message: {
                Text("Are you sure you want to delete '\(itemToDelete?.title ?? "")'? This cannot be undone.")
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
    }

    // MARK: - Sub-Filter Bar

    private var allMediaFilterBar: some View {
        HStack(spacing: 8) {
            ForEach([LIDMediaType.all, .video, .audio], id: \.self) { type in
                Button {
                    mediaFilter = type
                } label: {
                    Text(type.rawValue)
                        .font(.caption.bold())
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(mediaFilter == type ? Color.blue : Color.secondary.opacity(0.15))
                        .foregroundColor(mediaFilter == type ? .white : .primary)
                        .cornerRadius(16)
                }
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.bottom, 6)
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
        .listStyle(InsetGroupedListStyle())
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
                .listStyle(InsetGroupedListStyle())
            }
        }
    }

    // MARK: - Media Row Component

    private func mediaRow(for item: LIDMediaItem, showResumeBadge: Bool = false) -> some View {
        HStack(spacing: 12) {
            // Media Icon
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(item.mediaType == .video ? Color.blue.opacity(0.15) : Color.orange.opacity(0.15))
                    .frame(width: 44, height: 44)

                Image(systemName: item.mediaType == .video ? "film" : "music.note")
                    .font(.system(size: 20))
                    .foregroundColor(item.mediaType == .video ? .blue : .orange)
            }

            // Title & Details
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.subheadline.bold())
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file))
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    Text("•")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    Text(item.url.pathExtension.uppercased())
                        .font(.caption2.bold())
                        .foregroundColor(.secondary)

                    if showResumeBadge && item.lastPositionSeconds > 0 {
                        Text("•")
                            .font(.caption2)
                            .foregroundColor(.secondary)

                        Text("Resume at \(formatTime(item.lastPositionSeconds))")
                            .font(.caption2.bold())
                            .foregroundColor(.blue)
                    }
                }

                if item.progressFraction > 0.02 && !item.isCompleted {
                    ProgressView(value: item.progressFraction)
                        .frame(height: 3)
                        .accentColor(.blue)
                        .padding(.top, 2)
                }
            }

            Spacer()

            // Favorite Button
            Button {
                libraryStore.toggleFavorite(for: item)
            } label: {
                Image(systemName: item.isFavorite ? "star.fill" : "star")
                    .font(.system(size: 16))
                    .foregroundColor(item.isFavorite ? .yellow : .gray.opacity(0.5))
            }
            .buttonStyle(BorderlessButtonStyle())

            // Context Menu Actions
            Menu {
                Button {
                    playMedia(item)
                } label: {
                    Label("Play in LID Player", systemImage: "play.fill")
                }

                Button {
                    itemToAddToPlaylist = item
                } label: {
                    Label("Add to Playlist", systemImage: "text.badge.plus")
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
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18))
                    .foregroundColor(.secondary)
                    .padding(8)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            playMedia(item)
        }
        .padding(.vertical, 4)
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
        .listStyle(InsetGroupedListStyle())
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

    // MARK: - Empty State View

    private func emptyStateView(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
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

    #if canImport(UIKit)
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
                    .listStyle(InsetGroupedListStyle())
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
#endif
