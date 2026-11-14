#if canImport(SwiftUI)
import SwiftUI

public struct BrowserBookmarksAndHistoryView: View {
    @ObservedObject public var viewModel: BrowserViewModel
    @Environment(\.dismiss) private var dismiss

    public enum DisplayMode: String, CaseIterable, Identifiable {
        case bookmarks = "Bookmarks"
        case history = "History"
        public var id: String { rawValue }
    }

    @State private var selectedMode: DisplayMode = .bookmarks
    @State private var searchQuery: String = ""
    @State private var currentFolderID: UUID? = nil
    @State private var folderPath: [BrowserBookmarkFolder] = []
    @State private var bookmarkSort: BrowserBookmarkSort = .dateAddedDesc
    @State private var isShowingNewFolderDialog: Bool = false
    @State private var newFolderTitle: String = ""
    @State private var isShowingClearHistoryAlert: Bool = false

    public init(viewModel: BrowserViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Picker("View", selection: $selectedMode) {
                    ForEach(DisplayMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                searchField

                Divider()

                if selectedMode == .bookmarks {
                    bookmarksView
                } else {
                    historyView
                }
            }
            .navigationTitle(navigationTitle)
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    trailingToolbarItem
                }
            }
            .alert("New Folder", isPresented: $isShowingNewFolderDialog) {
                TextField("Folder name", text: $newFolderTitle)
                Button("Cancel", role: .cancel) { }
                Button("Create") {
                    let title = newFolderTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !title.isEmpty else { return }
                    BrowserBookmarkStore.shared.createFolder(title: title, parentFolderID: currentFolderID)
                }
            } message: {
                Text("Enter a name for the new bookmark folder.")
            }
            .alert("Clear Browsing History?", isPresented: $isShowingClearHistoryAlert) {
                Button("Cancel", role: .cancel) { }
                Button("Clear All", role: .destructive) {
                    BrowserHistoryStore.shared.clearAllHistory()
                }
            } message: {
                Text("This action will permanently delete all recorded browsing history. It cannot be undone.")
            }
        }
    }

    private var navigationTitle: String {
        if selectedMode == .history {
            return "History"
        }
        if let last = folderPath.last {
            return last.title
        }
        return "Bookmarks"
    }

    @ViewBuilder
    private var trailingToolbarItem: some View {
        if selectedMode == .bookmarks {
            Menu {
                Button {
                    addCurrentPageBookmark()
                } label: {
                    Label("Bookmark Current Page", systemImage: "star")
                }
                .disabled(viewModel.currentURL == nil)

                Button {
                    newFolderTitle = ""
                    isShowingNewFolderDialog = true
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }

                Menu("Sort By") {
                    ForEach(BrowserBookmarkSort.allCases) { sort in
                        Button {
                            bookmarkSort = sort
                        } label: {
                            HStack {
                                Text(sort.rawValue)
                                if bookmarkSort == sort {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        } else {
            Button {
                isShowingClearHistoryAlert = true
            } label: {
                Text("Clear")
                    .foregroundColor(.red)
            }
            .disabled(BrowserHistoryStore.shared.allEntries.isEmpty)
        }
    }

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField(selectedMode == .bookmarks ? "Search bookmarks" : "Search history", text: $searchQuery)
            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(8)
        #if canImport(UIKit)
        .background(Color(UIColor.secondarySystemBackground))
        #else
        .background(Color.secondary.opacity(0.15))
        #endif
        .cornerRadius(10)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: - Bookmarks View

    @ViewBuilder
    private var bookmarksView: some View {
        let store = BrowserBookmarkStore.shared
        if !searchQuery.isEmpty {
            let results = store.search(query: searchQuery)
            if results.isEmpty {
                emptyState(icon: "star.slash", title: "No Bookmarks Found", message: "No bookmarks matched '\(searchQuery)'.")
            } else {
                List {
                    ForEach(results) { item in
                        bookmarkRow(item)
                    }
                    .onDelete { indexSet in
                        for i in indexSet {
                            store.deleteBookmark(id: results[i].id)
                        }
                    }
                }
                .listStyle(.plain)
            }
        } else {
            let subfolders = store.subfolders(in: currentFolderID)
            let items = store.sortedBookmarks(in: currentFolderID, by: bookmarkSort)

            if subfolders.isEmpty && items.isEmpty {
                emptyState(
                    icon: "star",
                    title: "No Bookmarks",
                    message: "Tap the options menu at the top to bookmark the active page or create a folder."
                )
            } else {
                List {
                    if !folderPath.isEmpty {
                        Button {
                            _ = folderPath.popLast()
                            currentFolderID = folderPath.last?.id
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "chevron.backward")
                                    .font(.caption.bold())
                                Text("Back to \(folderPath.dropLast().last?.title ?? "Bookmarks")")
                                    .font(.subheadline)
                            }
                            .foregroundColor(.blue)
                        }
                    }

                    if !subfolders.isEmpty {
                        Section("Folders") {
                            ForEach(subfolders) { folder in
                                Button {
                                    folderPath.append(folder)
                                    currentFolderID = folder.id
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "folder.fill")
                                            .foregroundColor(.yellow)
                                        Text(folder.title)
                                            .foregroundColor(.primary)
                                        Spacer()
                                        Text("\(store.bookmarks(in: folder.id).count)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        Image(systemName: "chevron.forward")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                            .onDelete { indexSet in
                                for i in indexSet {
                                    store.deleteFolder(id: subfolders[i].id)
                                }
                            }
                        }
                    }

                    if !items.isEmpty {
                        Section("Bookmarks") {
                            ForEach(items) { item in
                                bookmarkRow(item)
                            }
                            .onDelete { indexSet in
                                for i in indexSet {
                                    store.deleteBookmark(id: items[i].id)
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func bookmarkRow(_ item: BrowserBookmarkItem) -> some View {
        Button {
            viewModel.load(url: item.url)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "globe")
                    .foregroundColor(.blue)
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.body)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Text(item.url.host ?? item.url.absoluteString)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func addCurrentPageBookmark() {
        guard let url = viewModel.currentURL else { return }
        let title = viewModel.pageTitle.isEmpty ? (url.host ?? "Bookmark") : viewModel.pageTitle
        BrowserBookmarkStore.shared.addBookmark(
            title: title,
            url: url,
            folderID: currentFolderID
        )
    }

    // MARK: - History View

    @ViewBuilder
    private var historyView: some View {
        let store = BrowserHistoryStore.shared
        if !searchQuery.isEmpty {
            let results = store.searchHistory(query: searchQuery)
            if results.isEmpty {
                emptyState(icon: "clock.badge.xmark", title: "No History Found", message: "No entries matched '\(searchQuery)'.")
            } else {
                List {
                    ForEach(results) { entry in
                        historyRow(entry)
                    }
                    .onDelete { indexSet in
                        for i in indexSet {
                            store.deleteEntry(id: results[i].id)
                        }
                    }
                }
                .listStyle(.plain)
            }
        } else {
            let groups = store.groupedChronologically()
            if groups.isEmpty {
                emptyState(icon: "clock", title: "No Browsing History", message: "Webpages you visit in standard tabs will appear here.")
            } else {
                List {
                    ForEach(groups) { group in
                        Section(group.sectionTitle) {
                            ForEach(group.entries) { entry in
                                historyRow(entry)
                            }
                            .onDelete { indexSet in
                                for i in indexSet {
                                    store.deleteEntry(id: group.entries[i].id)
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func historyRow(_ entry: BrowserHistoryEntry) -> some View {
        Button {
            viewModel.load(url: entry.url)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "clock")
                    .foregroundColor(.secondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.title)
                        .font(.body)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Text(entry.url.absoluteString)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if entry.visitCount > 1 {
                    Text("×\(entry.visitCount)")
                        .font(.caption2.bold())
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        #if canImport(UIKit)
                        .background(Color(UIColor.tertiarySystemFill))
                        #else
                        .background(Color.secondary.opacity(0.12))
                        #endif
                        .clipShape(Capsule())
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func emptyState(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundColor(.secondary.opacity(0.6))
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
}
#endif
