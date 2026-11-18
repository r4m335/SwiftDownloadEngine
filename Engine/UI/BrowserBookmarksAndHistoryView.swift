#if canImport(SwiftUI)
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

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
    @State private var changeToken: UUID = UUID()

    // Folder creation & rename
    @State private var isShowingNewFolderDialog: Bool = false
    @State private var newFolderTitle: String = ""
    @State private var isShowingRenameFolderDialog: Bool = false
    @State private var folderToRename: BrowserBookmarkFolder? = nil
    @State private var renameFolderTitle: String = ""

    // Folder move
    @State private var isShowingMoveFolderSheet: Bool = false
    @State private var folderToMove: BrowserBookmarkFolder? = nil
    @State private var moveTargetParentID: UUID? = nil

    // Folder delete alert
    @State private var isShowingDeleteFolderAlert: Bool = false
    @State private var folderToDelete: BrowserBookmarkFolder? = nil

    // Bookmark edit
    @State private var isShowingEditBookmarkSheet: Bool = false
    @State private var bookmarkToEdit: BrowserBookmarkItem? = nil
    @State private var editBookmarkTitle: String = ""
    @State private var editBookmarkURLString: String = ""
    @State private var editBookmarkFolderID: UUID? = nil

    // Duplicate bookmark prompt
    @State private var isShowingDuplicateAlert: Bool = false
    @State private var pendingBookmark: (title: String, url: URL, folderID: UUID?)? = nil
    @State private var duplicateExistingTitle: String = ""

    // History clear
    @State private var isShowingClearHistoryDialog: Bool = false

    // Share Sheet
    @State private var isShowingShareSheet: Bool = false
    @State private var shareItems: [Any] = []

    // Import / Export
    @State private var isShowingImportSheet: Bool = false
    @State private var importHTMLText: String = ""
    @State private var isShowingImportSummaryAlert: Bool = false
    @State private var importSummary: BookmarkImportSummary = BookmarkImportSummary()

    public init(viewModel: BrowserViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        let _ = changeToken
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
            // Listen for reactive store changes
            .onReceive(NotificationCenter.default.publisher(for: BrowserBookmarkStore.didChangeNotification)) { _ in
                changeToken = UUID()
            }
            .onReceive(NotificationCenter.default.publisher(for: BrowserHistoryStore.didChangeNotification)) { _ in
                changeToken = UUID()
            }
            // New Folder dialog
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
            // Rename Folder dialog
            .alert("Rename Folder", isPresented: $isShowingRenameFolderDialog) {
                TextField("Folder name", text: $renameFolderTitle)
                Button("Cancel", role: .cancel) { }
                Button("Save") {
                    guard let folder = folderToRename else { return }
                    let title = renameFolderTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !title.isEmpty else { return }
                    BrowserBookmarkStore.shared.renameFolder(id: folder.id, newTitle: title)
                    if let index = folderPath.firstIndex(where: { $0.id == folder.id }) {
                        folderPath[index].title = title
                    }
                }
            } message: {
                Text("Enter a new name for '\(folderToRename?.title ?? "Folder")'.")
            }
            // Delete Folder confirmation
            .alert("Delete Folder?", isPresented: $isShowingDeleteFolderAlert) {
                Button("Cancel", role: .cancel) { folderToDelete = nil }
                Button("Delete", role: .destructive) {
                    if let f = folderToDelete {
                        BrowserBookmarkStore.shared.deleteFolder(id: f.id)
                        folderToDelete = nil
                    }
                }
            } message: {
                Text("Deleting '\(folderToDelete?.title ?? "this folder")' will permanently remove all of its subfolders and bookmarks.")
            }
            // Duplicate Bookmark Alert
            .alert("Bookmark Already Exists", isPresented: $isShowingDuplicateAlert) {
                Button("Cancel", role: .cancel) { pendingBookmark = nil }
                Button("Add Anyway") {
                    if let p = pendingBookmark {
                        BrowserBookmarkStore.shared.addBookmark(
                            title: p.title,
                            url: p.url,
                            folderID: p.folderID
                        )
                    }
                    pendingBookmark = nil
                }
            } message: {
                Text("A bookmark for this URL already exists ('\(duplicateExistingTitle)'). Would you like to add it anyway?")
            }
            // Clear History Dialog
            .confirmationDialog("Clear Browsing History", isPresented: $isShowingClearHistoryDialog, titleVisibility: .visible) {
                Button("Last Hour", role: .destructive) {
                    let cutoff = Calendar.current.date(byAdding: .hour, value: -1, to: Date())
                    BrowserHistoryStore.shared.clearHistory(since: cutoff)
                }
                Button("Today", role: .destructive) {
                    let cutoff = Calendar.current.startOfDay(for: Date())
                    BrowserHistoryStore.shared.clearHistory(since: cutoff)
                }
                Button("All Time", role: .destructive) {
                    BrowserHistoryStore.shared.clearAllHistory()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Select the time range of browsing history to remove.")
            }
            // Import Summary Alert
            .alert("Bookmarks Imported", isPresented: $isShowingImportSummaryAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Found: \(importSummary.totalFound)\nImported: \(importSummary.importedBookmarksCount) bookmarks, \(importSummary.importedFoldersCount) folders\nSkipped: \(importSummary.skippedCount) (\(importSummary.duplicateCount) duplicates)")
            }
            // Edit Bookmark Sheet
            .sheet(isPresented: $isShowingEditBookmarkSheet) {
                editBookmarkSheetView
            }
            // Move Folder Sheet
            .sheet(isPresented: $isShowingMoveFolderSheet) {
                moveFolderSheetView
            }
            // Import Bookmarks Sheet
            .sheet(isPresented: $isShowingImportSheet) {
                importBookmarksSheetView
            }
            // Share Sheet
            .sheet(isPresented: $isShowingShareSheet) {
                BrowserShareSheet(items: shareItems)
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

                Divider()

                Button {
                    exportBookmarks()
                } label: {
                    Label("Export Bookmarks (HTML)...", systemImage: "square.and.arrow.up")
                }

                Button {
                    importHTMLText = ""
                    isShowingImportSheet = true
                } label: {
                    Label("Import Bookmarks (HTML)...", systemImage: "square.and.arrow.down")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        } else {
            Button {
                isShowingClearHistoryDialog = true
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
                    message: "Tap the options menu at the top to bookmark the active page, create a folder, or import bookmarks."
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
                                folderRow(folder)
                            }
                            .onDelete { indexSet in
                                for i in indexSet {
                                    folderToDelete = subfolders[i]
                                    isShowingDeleteFolderAlert = true
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
    private func folderRow(_ folder: BrowserBookmarkFolder) -> some View {
        let store = BrowserBookmarkStore.shared
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
        .contextMenu {
            Button {
                folderToRename = folder
                renameFolderTitle = folder.title
                isShowingRenameFolderDialog = true
            } label: {
                Label("Rename", systemImage: "pencil")
            }

            Button {
                folderToMove = folder
                moveTargetParentID = folder.parentFolderID
                isShowingMoveFolderSheet = true
            } label: {
                Label("Move Folder...", systemImage: "folder.badge.gearshape")
            }

            Divider()

            Button(role: .destructive) {
                folderToDelete = folder
                isShowingDeleteFolderAlert = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func bookmarkRow(_ item: BrowserBookmarkItem) -> some View {
        let store = BrowserBookmarkStore.shared
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
        .contextMenu {
            Button {
                viewModel.load(url: item.url)
                dismiss()
            } label: {
                Label("Open", systemImage: "arrow.up.right")
            }

            Button {
                _ = viewModel.createNewTab(with: item.url)
                dismiss()
            } label: {
                Label("Open in New Tab", systemImage: "plus.rectangle.on.rectangle")
            }

            Button {
                bookmarkToEdit = item
                editBookmarkTitle = item.title
                editBookmarkURLString = item.url.absoluteString
                editBookmarkFolderID = item.folderID
                isShowingEditBookmarkSheet = true
            } label: {
                Label("Edit Bookmark", systemImage: "pencil")
            }

            Button {
                #if canImport(UIKit)
                UIPasteboard.general.string = item.url.absoluteString
                #endif
            } label: {
                Label("Copy URL", systemImage: "doc.on.doc")
            }

            Button {
                shareItems = [item.url]
                isShowingShareSheet = true
            } label: {
                Label("Share Link", systemImage: "square.and.arrow.up")
            }

            Divider()

            Button(role: .destructive) {
                store.deleteBookmark(id: item.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func addCurrentPageBookmark() {
        guard let url = viewModel.currentURL else { return }
        let title = viewModel.pageTitle.isEmpty ? (url.host ?? "Bookmark") : viewModel.pageTitle
        let store = BrowserBookmarkStore.shared
        if let existing = store.findDuplicate(for: url) {
            duplicateExistingTitle = existing.title
            pendingBookmark = (title: title, url: url, folderID: currentFolderID)
            isShowingDuplicateAlert = true
        } else {
            store.addBookmark(
                title: title,
                url: url,
                folderID: currentFolderID
            )
        }
    }

    private func exportBookmarks() {
        let store = BrowserBookmarkStore.shared
        let html = BrowserBookmarkExporter.exportToHTML(store: store)
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("bookmarks.html")
        try? html.write(to: tempURL, atomically: true, encoding: .utf8)
        shareItems = [tempURL]
        isShowingShareSheet = true
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
        let store = BrowserHistoryStore.shared
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
        .contextMenu {
            Button {
                viewModel.load(url: entry.url)
                dismiss()
            } label: {
                Label("Open", systemImage: "arrow.up.right")
            }

            Button {
                _ = viewModel.createNewTab(with: entry.url)
                dismiss()
            } label: {
                Label("Open in New Tab", systemImage: "plus.rectangle.on.rectangle")
            }

            Button {
                #if canImport(UIKit)
                UIPasteboard.general.string = entry.url.absoluteString
                #endif
            } label: {
                Label("Copy URL", systemImage: "doc.on.doc")
            }

            Button {
                shareItems = [entry.url]
                isShowingShareSheet = true
            } label: {
                Label("Share Link", systemImage: "square.and.arrow.up")
            }

            Divider()

            Button(role: .destructive) {
                store.deleteEntry(id: entry.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
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

    // MARK: - Subviews & Sheets

    @ViewBuilder
    private var editBookmarkSheetView: some View {
        NavigationView {
            Form {
                Section("Bookmark Details") {
                    TextField("Title", text: $editBookmarkTitle)
                    TextField("URL", text: $editBookmarkURLString)
                        #if canImport(UIKit)
                        .autocapitalization(.none)
                        .keyboardType(.URL)
                        #endif
                        .disableAutocorrection(true)
                }

                Section("Folder") {
                    Picker("Folder", selection: $editBookmarkFolderID) {
                        Text("Root / Bookmarks").tag(UUID?.none)
                        ForEach(BrowserBookmarkStore.shared.allFolders) { folder in
                            Text(folder.title).tag(UUID?.some(folder.id))
                        }
                    }
                }
            }
            .navigationTitle("Edit Bookmark")
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isShowingEditBookmarkSheet = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let item = bookmarkToEdit,
                              let url = URL(string: editBookmarkURLString.trimmingCharacters(in: .whitespacesAndNewlines)),
                              !editBookmarkTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            return
                        }
                        BrowserBookmarkStore.shared.updateBookmark(
                            id: item.id,
                            title: editBookmarkTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                            url: url,
                            folderID: editBookmarkFolderID
                        )
                        isShowingEditBookmarkSheet = false
                    }
                    .disabled(
                        editBookmarkTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        URL(string: editBookmarkURLString.trimmingCharacters(in: .whitespacesAndNewlines)) == nil
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var moveFolderSheetView: some View {
        let store = BrowserBookmarkStore.shared
        let candidateFolders = store.allFolders.filter { f in
            guard let moving = folderToMove else { return true }
            return f.id != moving.id && store.canMoveFolder(id: moving.id, toParentID: f.id)
        }

        NavigationView {
            Form {
                Section("Target Location") {
                    Picker("Move To", selection: $moveTargetParentID) {
                        Text("Top Level / Root").tag(UUID?.none)
                        ForEach(candidateFolders) { folder in
                            Text(folder.title).tag(UUID?.some(folder.id))
                        }
                    }
                }
            }
            .navigationTitle("Move Folder")
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isShowingMoveFolderSheet = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Move") {
                        if let moving = folderToMove {
                            try? store.moveFolder(id: moving.id, toParentID: moveTargetParentID)
                        }
                        isShowingMoveFolderSheet = false
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var importBookmarksSheetView: some View {
        NavigationView {
            VStack(spacing: 16) {
                Text("Paste Netscape Bookmark HTML below or tap 'Paste from Clipboard'.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
                    .padding(.top, 8)

                #if canImport(UIKit)
                Button {
                    if let string = UIPasteboard.general.string {
                        importHTMLText = string
                    }
                } label: {
                    Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)
                #endif

                TextEditor(text: $importHTMLText)
                    .padding(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
                    .padding(.horizontal)

                Spacer()
            }
            .navigationTitle("Import Bookmarks")
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isShowingImportSheet = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        let store = BrowserBookmarkStore.shared
                        let summary = BrowserBookmarkImporter.importHTMLString(
                            importHTMLText,
                            intoFolderID: currentFolderID,
                            store: store,
                            skipDuplicates: true
                        )
                        importSummary = summary
                        isShowingImportSheet = false
                        isShowingImportSummaryAlert = true
                    }
                    .disabled(importHTMLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
#endif
