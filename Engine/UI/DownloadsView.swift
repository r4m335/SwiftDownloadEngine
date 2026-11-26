#if canImport(SwiftUI)
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

#if canImport(QuickLook)
import QuickLook
#endif

/// Formatter helpers for UI representation of byte counts, speeds, and times.
public enum UIFormatters {
    public static func formatBytes(_ bytes: Int64) -> String {
        let bcf = ByteCountFormatter()
        bcf.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        bcf.countStyle = .file
        return bcf.string(fromByteCount: bytes)
    }

    public static func formatSpeed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0 else { return "0 B/s" }
        let formatted = formatBytes(Int64(bytesPerSecond))
        return "\(formatted)/s"
    }

    public static func formatTimeInterval(_ seconds: TimeInterval?) -> String {
        guard let s = seconds, s > 0, !s.isInfinite, !s.isNaN else { return "--:--" }
        let total = Int(s)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%02d:%02d", minutes, secs)
        }
    }
}

// MARK: - Navigation & Modal State Enums

public enum ActiveSheet: Identifiable {
    case addDownload
    case saveToFiles(URL)
    case shareFile(URL)
    case diagnostics
    case mediaLibrary
    case updateDownloadLink(UnifiedTransfer)

    public var id: String {
        switch self {
        case .addDownload:
            return "addDownload"
        case .saveToFiles(let url):
            return "saveToFiles_\(url.path)"
        case .shareFile(let url):
            return "shareFile_\(url.path)"
        case .diagnostics:
            return "diagnostics"
        case .mediaLibrary:
            return "mediaLibrary"
        case .updateDownloadLink(let transfer):
            return "updateDownloadLink_\(transfer.id)"
        }
    }
}

public enum ActiveAlert: Identifiable {
    case integrity(IntegrityReport)
    case deleteConfirmation(DownloadSnapshot)
    case deleteTransferConfirmation(UnifiedTransfer)

    public var id: String {
        switch self {
        case .integrity(let report):
            return "integrity_\(report.id.uuidString)"
        case .deleteConfirmation(let snap):
            return "delete_\(snap.id)"
        case .deleteTransferConfirmation(let transfer):
            return "delete_transfer_\(transfer.id)"
        }
    }
}

public struct IntegrityReport: Identifiable {
    public let id = UUID()
    public let filename: String
    public let fileSize: Int64
    public let sha256: String
    public let outcome: ChecksumOutcome

    public var statusDescription: String {
        switch outcome {
        case .verified(let expected):
            if expected.caseInsensitiveCompare(sha256) == .orderedSame {
                return "Matches expected SHA-256."
            } else {
                return "Verified by engine."
            }
        case .mismatch(let expected, _):
            return "Mismatch with expected hash (\(expected.prefix(8))...)."
        case .notChecked:
            return "Calculated directly from file contents."
        }
    }
}

/// Screen 1: Displays all managed downloads with progress, speeds, and lifecycle controls.
public struct DownloadsView: View {
    @ObservedObject public var viewModel: DownloadManagerViewModel
    @State private var activeSheet: ActiveSheet? = nil
    @State private var activeAlert: ActiveAlert? = nil
    @State private var quickLookURL: URL? = nil
    @State private var playerMediaURL: URL? = nil
    @State private var playerMediaTitle: String = ""
    @State private var playerSource: LIDPlayerSource? = nil
    @State private var selectedDownloadForDetails: DownloadSnapshot? = nil
    @State private var selectedTransferForDetails: UnifiedTransfer? = nil

    // MARK: Multi-Select State
    /// Whether the list is currently in multi-select mode (activated by long-press).
    @State private var isSelectingMultiple: Bool = false
    /// IDs of currently selected transfers.
    @State private var selectedIDs: Set<String> = []
    /// Controls the bulk-delete confirmation alert.
    @State private var showBulkDeleteAlert: Bool = false
    /// Toggles between rich card layout and high-density compact rows.
    @AppStorage("downloadsCompactMode") private var isCompactMode: Bool = false

    private var trailingToolbarPlacement: ToolbarItemPlacement {
        #if os(iOS)
        return .navigationBarTrailing
        #else
        return .primaryAction
        #endif
    }

    public init(viewModel: DownloadManagerViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationView {
            applyDownloadsToolbar(
                VStack(spacing: 0) {
                // Programmatic Navigation Link for "Show Details"
                NavigationLink(
                    destination: Group {
                        if let transfer = selectedTransferForDetails {
                            DownloadDetailsView(viewModel: viewModel, transfer: transfer)
                        } else if let target = selectedDownloadForDetails {
                            DownloadDetailsView(viewModel: viewModel, download: target)
                        }
                    },
                    isActive: Binding(
                        get: { selectedTransferForDetails != nil || selectedDownloadForDetails != nil },
                        set: { if !$0 { selectedTransferForDetails = nil; selectedDownloadForDetails = nil } }
                    )
                ) {
                    EmptyView()
                }
                .hidden()

                // Bandwidth Dashboard (Milestone 4.3)
                BandwidthDashboardSection(viewModel: viewModel)

                // Live Stream Recording Status & Recovery Banners
                LiveRecordingRecoverySection()

                // Row 1: Clickable Download Status Counters (Merged Statistics & Status Filters)
                QueueSummaryHeader(viewModel: viewModel)
                    .padding(.top, 6)
                    .padding(.bottom, 2)
                    .gesture(
                        DragGesture(minimumDistance: 20, coordinateSpace: .local)
                            .onEnded { value in
                                if value.translation.width < -30 {
                                    if let next = viewModel.selectedFilter.next {
                                        withAnimation(.easeInOut(duration: 0.25)) {
                                            viewModel.selectedFilter = next
                                        }
                                    }
                                } else if value.translation.width > 30 {
                                    if let prev = viewModel.selectedFilter.previous {
                                        withAnimation(.easeInOut(duration: 0.25)) {
                                            viewModel.selectedFilter = prev
                                        }
                                    }
                                }
                            }
                    )

                // Secondary Category Filter Chips (Phase 3 Milestone 3.3)
                CategoryFilterBar(selectedCategory: $viewModel.selectedCategory)
                    .padding(.bottom, 6)

                // Horizontally Swipeable Category Pager for Downloads
                #if os(iOS)
                TabView(selection: $viewModel.selectedFilter) {
                    ForEach(DownloadFilter.allCases) { filter in
                        transferListView(for: filter)
                            .tag(filter)
                    }
                }
                .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
                #else
                transferListView(for: viewModel.selectedFilter)
                    .gesture(
                        DragGesture(minimumDistance: 30)
                            .onEnded { value in
                                if value.translation.width < -40 {
                                    if let next = viewModel.selectedFilter.next {
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            viewModel.selectedFilter = next
                                        }
                                    }
                                } else if value.translation.width > 40 {
                                    if let prev = viewModel.selectedFilter.previous {
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            viewModel.selectedFilter = prev
                                        }
                                    }
                                }
                            }
                    )
                #endif
            }
            .navigationTitle(isSelectingMultiple
                ? (selectedIDs.isEmpty ? "Select Items" : "\(selectedIDs.count) Selected")
                : "Downloads")
            .searchable(text: $viewModel.filterText, prompt: "Search downloads...")
            .overlay(alignment: .top) {
                VStack(spacing: 6) {
                    if let error = viewModel.errorMessage {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                                .font(.caption)
                            Text(error)
                                .font(.caption.weight(.medium))
                                .foregroundColor(.primary)
                                .lineLimit(2)
                            Button {
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                    viewModel.clearError()
                                }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().stroke(Color.red.opacity(0.3), lineWidth: 1))
                        .shadow(color: .black.opacity(0.1), radius: 6, y: 2)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    if let notification = viewModel.userNotificationMessage {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.caption)
                            Text(notification)
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().stroke(Color.green.opacity(0.3), lineWidth: 1))
                        .shadow(color: .black.opacity(0.1), radius: 6, y: 2)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    viewModel.clearNotification()
                                }
                            }
                        }
                    }
                }
                .padding(.top, 6)
                .padding(.horizontal, 16)
                .animation(.spring(response: 0.25, dampingFraction: 0.85), value: viewModel.errorMessage)
                .animation(.spring(response: 0.25, dampingFraction: 0.85), value: viewModel.userNotificationMessage)
            }
            )
            .sheet(item: $activeSheet, onDismiss: {
                viewModel.showAddDownloadSheet = false
                viewModel.addDownloadPrefilledURL = nil
            }) { sheet in
                switch sheet {
                case .addDownload:
                    AddDownloadView(
                        viewModel: viewModel,
                        onDownloadAdded: {
                            activeSheet = nil
                            viewModel.showAddDownloadSheet = false
                            viewModel.addDownloadPrefilledURL = nil
                        },
                        prefilledURL: viewModel.addDownloadPrefilledURL
                    )
                case .saveToFiles(let url):
                    #if canImport(UIKit)
                    DocumentExporterSheet(url: url)
                    #else
                    VStack(spacing: 12) {
                        Text("Save to Files").font(.headline)
                        Text(url.path).font(.caption).foregroundColor(.secondary)
                    }
                    .padding()
                    #endif
                case .shareFile(let url):
                    #if canImport(UIKit)
                    ShareSheetView(items: [url])
                    #else
                    VStack(spacing: 12) {
                        Text("Share File").font(.headline)
                        Text(url.path).font(.caption).foregroundColor(.secondary)
                    }
                    .padding()
                    #endif
                case .diagnostics:
                    DiagnosticLogView(configuration: viewModel.activeEngineConfiguration)
                case .mediaLibrary:
                    LIDPlayerLibraryView(
                        baseDirectory: viewModel.downloadsDirectoryURL,
                        knownTransfers: viewModel.unifiedTransfers,
                        onDismiss: {
                            activeSheet = nil
                        }
                    )
                case .updateDownloadLink(let transfer):
                    UpdateDownloadLinkSheet(
                        viewModel: viewModel,
                        transfer: transfer,
                        onDismiss: {
                            activeSheet = nil
                        }
                    )
                }
            }
            .onChange(of: viewModel.showAddDownloadSheet) { show in
                if show {
                    activeSheet = .addDownload
                }
            }
            .alert(item: $activeAlert) { alert in
                switch alert {
                case .integrity(let report):
                    return Alert(
                        title: Text("Integrity Verification"),
                        message: Text(
                            """
                            File: \(report.filename)
                            Size: \(UIFormatters.formatBytes(report.fileSize))
                            
                            SHA-256:
                            \(report.sha256)
                            
                            Status: \(report.statusDescription)
                            """
                        ),
                        primaryButton: .default(Text("Copy SHA-256")) {
                            #if canImport(UIKit)
                            UIPasteboard.general.string = report.sha256
                            #elseif canImport(AppKit)
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(report.sha256, forType: .string)
                            #endif
                            viewModel.showNotification("SHA-256 hash copied to clipboard")
                        },
                        secondaryButton: .cancel(Text("Done"))
                    )
                case .deleteConfirmation(let snap):
                    return Alert(
                        title: Text("Delete \(snap.destinationURL.lastPathComponent)?"),
                        message: Text("This will permanently delete the downloaded file from disk. This action cannot be undone."),
                        primaryButton: .destructive(Text("Delete File")) {
                            Task { @MainActor in
                                let name = snap.destinationURL.lastPathComponent
                                if !snap.isTerminal {
                                    do {
                                        try await viewModel.cancelDownload(id: snap.id, deleteFile: false)
                                    } catch {
                                        PipelineLogger.shared.log(stage: .ui, message: "Failed to cancel download \(snap.id): \(error)")
                                    }
                                }
                                do {
                                    try await viewModel.removeDownload(id: snap.id, deleteFile: true)
                                } catch {
                                    PipelineLogger.shared.log(stage: .ui, message: "Failed to remove download \(snap.id): \(error)")
                                }
                                do {
                                    try FileManager.default.removeItem(at: snap.destinationURL)
                                } catch {
                                    PipelineLogger.shared.log(stage: .ui, message: "Failed to remove destination file \(snap.destinationURL.path): \(error)")
                                }
                                viewModel.showNotification("Permanently deleted '\(name)' from disk")
                            }
                        },
                        secondaryButton: .cancel()
                    )
                case .deleteTransferConfirmation(let transfer):
                    return Alert(
                        title: Text("Remove \(transfer.name)?"),
                        message: Text("Do you want to delete the downloaded file from disk as well?"),
                        primaryButton: .destructive(Text("Delete File & Remove")) {
                            Task { @MainActor in
                                do {
                                    try await viewModel.removeTransfer(id: transfer.id, deleteFiles: true)
                                } catch {
                                    PipelineLogger.shared.log(stage: .ui, message: "Failed to remove transfer \(transfer.id): \(error)")
                                }
                                do {
                                    try LIDLibraryStore.shared.deleteMediaFile(url: transfer.destinationURL)
                                } catch {
                                    PipelineLogger.shared.log(stage: .ui, message: "Failed to delete media file from library: \(error)")
                                }
                                viewModel.showNotification("Removed '\(transfer.name)' and deleted file")
                            }
                        },
                        secondaryButton: .default(Text("Keep File & Remove")) {
                            Task { @MainActor in
                                do {
                                    try await viewModel.removeTransfer(id: transfer.id, deleteFiles: false)
                                } catch {
                                    PipelineLogger.shared.log(stage: .ui, message: "Failed to remove transfer \(transfer.id): \(error)")
                                }
                                viewModel.showNotification("Removed '\(transfer.name)' (file kept)")
                            }
                        }
                    )
                }
            }
            .filePreviewSheet(item: $quickLookURL)
            .lidPlayerPresentation(url: $playerMediaURL, title: playerMediaTitle)
            .lidPlayerPresentation(source: $playerSource)
            // MARK: Bulk Delete Confirmation Alert
            .alert("Delete \(selectedIDs.count) Item\(selectedIDs.count == 1 ? "" : "s")?",
                   isPresented: $showBulkDeleteAlert) {
                Button("Remove from Queue", role: .none) {
                    deleteSelectedTransfers(deleteFiles: false)
                }
                Button("Delete Files from Disk", role: .destructive) {
                    deleteSelectedTransfers(deleteFiles: true)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Remove \(selectedIDs.count) selected item\(selectedIDs.count == 1 ? "" : "s") from the queue. Choose whether to also delete the downloaded files from disk.")
            }
        }
        .modernStackNavigation()
    }

    // MARK: - Toolbar Construction (macOS 12 / iOS 15 Compatibility)

    @ViewBuilder
    private func applyDownloadsToolbar<Content: View>(_ content: Content) -> some View {
        if isSelectingMultiple {
            #if os(iOS)
            content.toolbar {
                ToolbarItem(placement: trailingToolbarPlacement) {
                    cancelToolbarButton
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    iOSSelectionBottomBar
                }
            }
            #else
            content.toolbar {
                ToolbarItem(placement: trailingToolbarPlacement) {
                    cancelToolbarButton
                }
                ToolbarItemGroup(placement: .navigation) {
                    macOSSelectionLeadingBar
                }
            }
            #endif
        } else {
            content.toolbar {
                ToolbarItemGroup(placement: trailingToolbarPlacement) {
                    normalToolbarContent
                }
            }
        }
    }

    private var cancelToolbarButton: some View {
        Button("Cancel") {
            withAnimation(.easeInOut(duration: 0.2)) {
                exitSelectionMode()
            }
        }
    }

    #if os(iOS)
    @ViewBuilder
    private var iOSSelectionBottomBar: some View {
        // Select All / Deselect All
        Button {
            let filteredIDs = Set(viewModel.filteredTransfers.map(\.id))
            withAnimation {
                if filteredIDs.isSubset(of: selectedIDs) {
                    selectedIDs.subtract(filteredIDs)
                } else {
                    selectedIDs.formUnion(filteredIDs)
                }
            }
        } label: {
            let allSelected = !viewModel.filteredTransfers.isEmpty && Set(viewModel.filteredTransfers.map(\.id)).isSubset(of: selectedIDs)
            Text(allSelected ? "Deselect All" : "Select All")
        }

        Spacer()

        // Delete selected
        Button(role: .destructive) {
            if !selectedIDs.isEmpty {
                showBulkDeleteAlert = true
            }
        } label: {
            Label("Delete", systemImage: "trash")
                .foregroundColor(selectedIDs.isEmpty ? .secondary : .red)
        }
        .disabled(selectedIDs.isEmpty)
    }
    #endif

    #if !os(iOS)
    @ViewBuilder
    private var macOSSelectionLeadingBar: some View {
        // macOS: show Select All and Delete in the leading navigation area
        Button {
            let filteredIDs = Set(viewModel.filteredTransfers.map(\.id))
            withAnimation {
                if filteredIDs.isSubset(of: selectedIDs) {
                    selectedIDs.subtract(filteredIDs)
                } else {
                    selectedIDs.formUnion(filteredIDs)
                }
            }
        } label: {
            let allSelected = !viewModel.filteredTransfers.isEmpty && Set(viewModel.filteredTransfers.map(\.id)).isSubset(of: selectedIDs)
            Text(allSelected ? "Deselect All" : "Select All")
        }

        Button(role: .destructive) {
            if !selectedIDs.isEmpty {
                showBulkDeleteAlert = true
            }
        } label: {
            Label("Delete", systemImage: "trash")
        }
        .disabled(selectedIDs.isEmpty)
    }
    #endif

    @ViewBuilder
    private var normalToolbarContent: some View {
        sortOrderMenu
        groupingOptionMenu

        DownloadsToolbarOverflowMenu(
            isCompactMode: isCompactMode,
            onToggleCompact: {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    isCompactMode.toggle()
                }
                triggerHaptic(.light)
            },
            onPauseAll: {
                triggerHaptic(.medium)
                Task { @MainActor in await viewModel.pauseAll() }
            },
            onResumeAll: {
                triggerHaptic(.medium)
                Task { @MainActor in await viewModel.resumeAll() }
            },
            onShowDiagnostics: {
                activeSheet = .diagnostics
            },
            onCancelAll: {
                triggerHaptic(.heavy)
                Task { @MainActor in await viewModel.cancelAll(deleteFiles: false) }
            }
        )
        .equatable()

        Button {
            triggerHaptic(.light)
            viewModel.addDownloadPrefilledURL = nil
            viewModel.showAddDownloadSheet = true
            activeSheet = .addDownload
        } label: {
            Image(systemName: "plus.circle.fill")
                .font(.title3)
        }
    }

    private struct DownloadsToolbarOverflowMenu: View, Equatable {
        let isCompactMode: Bool
        let onToggleCompact: () -> Void
        let onPauseAll: () -> Void
        let onResumeAll: () -> Void
        let onShowDiagnostics: () -> Void
        let onCancelAll: () -> Void

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.isCompactMode == rhs.isCompactMode
        }

        var body: some View {
            Menu {
                Button(action: onToggleCompact) {
                    Label(
                        isCompactMode ? "Switch to Card View" : "Switch to Compact Rows",
                        systemImage: isCompactMode ? "rectangle.grid.1x2" : "list.bullet"
                    )
                }

                Divider()

                Button(action: onPauseAll) {
                    Label("Pause All", systemImage: "pause.circle")
                }

                Button(action: onResumeAll) {
                    Label("Resume All", systemImage: "play.circle")
                }

                Divider()

                Button(action: onShowDiagnostics) {
                    Label("Pipeline Diagnostics", systemImage: "doc.text.magnifyingglass")
                }

                Divider()

                Button(role: .destructive, action: onCancelAll) {
                    Label("Cancel All", systemImage: "stop.circle")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    private var sortOrderMenu: some View {
        Menu {
            Section("Sort By") {
                ForEach(DownloadSortOrder.allCases) { order in
                    Button {
                        viewModel.updateSortOrder(order)
                    } label: {
                        if viewModel.selectedSortOrder == order {
                            Label(order.displayName, systemImage: "checkmark")
                        } else {
                            Text(order.displayName)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .accessibilityLabel("Sort Transfers")
        }
    }

    private var groupingOptionMenu: some View {
        Menu {
            Section("Group By") {
                ForEach(DownloadGroupingOption.allCases) { opt in
                    Button {
                        viewModel.updateGroupingOption(opt)
                    } label: {
                        if viewModel.selectedGroupingOption == opt {
                            Label(opt.displayName, systemImage: "checkmark")
                        } else {
                            Text(opt.displayName)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "rectangle.3.group")
                .accessibilityLabel("Group Transfers")
        }
    }

    // MARK: - Category Pager Transfer List

    @ViewBuilder
    private func transferListView(for filter: DownloadFilter) -> some View {
        let transfers = viewModel.filteredTransfers(for: filter)
        if transfers.isEmpty {
            EmptyDownloadsState(
                filter: filter,
                category: viewModel.selectedCategory,
                onAddDownload: {
                    triggerHaptic(.light)
                    viewModel.addDownloadPrefilledURL = nil
                    viewModel.showAddDownloadSheet = true
                    activeSheet = .addDownload
                },
                onOpenBrowser: {
                    triggerHaptic(.light)
                    viewModel.selectedTab = 1
                }
            )
        } else if viewModel.selectedGroupingOption == .none {
            List {
                ForEach(transfers) { transfer in
                    transferRow(transfer)
                }
            }
            .listStyle(.plain)
            .refreshable {
                await viewModel.refreshSnapshots()
                await viewModel.refreshTorrentSnapshots()
            }
            .onChange(of: viewModel.unifiedTransfers.map(\.id)) { currentIDs in
                guard isSelectingMultiple else { return }
                let currentSet = Set(currentIDs)
                let remaining = selectedIDs.intersection(currentSet)
                if !selectedIDs.isEmpty && remaining.isEmpty {
                    withAnimation { exitSelectionMode() }
                } else {
                    selectedIDs = remaining
                }
            }
        } else {
            let groups = DownloadManagerViewModel.groupTransfers(transfers, by: viewModel.selectedGroupingOption)
            List {
                ForEach(groups, id: \.key) { group in
                    Section(header: Text(group.key).font(.subheadline).bold().foregroundColor(.secondary)) {
                        ForEach(group.transfers) { transfer in
                            transferRow(transfer)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .refreshable {
                await viewModel.refreshSnapshots()
                await viewModel.refreshTorrentSnapshots()
            }
            .onChange(of: viewModel.unifiedTransfers.map(\.id)) { currentIDs in
                guard isSelectingMultiple else { return }
                let currentSet = Set(currentIDs)
                let remaining = selectedIDs.intersection(currentSet)
                if !selectedIDs.isEmpty && remaining.isEmpty {
                    withAnimation { exitSelectionMode() }
                } else {
                    selectedIDs = remaining
                }
            }
        }
    }

    @ViewBuilder
    private func transferRow(_ transfer: UnifiedTransfer) -> some View {
        HStack(spacing: 12) {
            if isSelectingMultiple {
                Image(systemName: selectedIDs.contains(transfer.id)
                      ? "checkmark.circle.fill"
                      : "circle")
                    .font(.title3)
                    .foregroundColor(selectedIDs.contains(transfer.id) ? .blue : .secondary)
                    .animation(.spring(response: 0.25, dampingFraction: 0.75), value: selectedIDs.contains(transfer.id))
                    .transition(.scale.combined(with: .opacity))
                    .onTapGesture {
                        toggleSelection(for: transfer.id)
                    }
            }

            UnifiedTransferRowView(
                viewModel: viewModel,
                transfer: transfer,
                isSelectingMultiple: isSelectingMultiple,
                isCompact: isCompactMode,
                onTapContent: {
                    if isSelectingMultiple {
                        toggleSelection(for: transfer.id)
                    } else {
                        showTransferDetails(transfer)
                    }
                },
                onOpen: { triggerHaptic(.light); openTransferFile(transfer) },
                onStreamOnline: { triggerHaptic(.light); streamTransferOnline(transfer) },
                onOpenInPlayer: { triggerHaptic(.light); openTransferInPlayer(transfer) },
                onSaveToFiles: { triggerHaptic(.light); saveTransferToFiles(transfer) },
                onShare: { triggerHaptic(.light); shareTransferFile(transfer) },
                onCopyLink: { triggerHaptic(.light); copyTransferLink(transfer) },
                onShowDetails: { showTransferDetails(transfer) },
                onPause: { triggerHaptic(.medium); pauseTransfer(transfer) },
                onResume: { triggerHaptic(.medium); resumeTransfer(transfer) },
                onRetry: {
                    triggerHaptic(.medium)
                    Task { await viewModel.retryTransfer(transfer) }
                },
                onUpdateLink: { activeSheet = .updateDownloadLink(transfer) },
                onRefreshFromBrowser: { viewModel.startBrowserLinkRefresh(for: transfer) },
                onRemoveQueue: { triggerHaptic(.medium); removeTransferFromQueue(transfer) },
                onDeleteFile: { triggerHaptic(.heavy); promptDeleteTransferFile(transfer) }
            )
        }
        .onLongPressGesture(minimumDuration: 0.45) {
            guard !isSelectingMultiple else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                isSelectingMultiple = true
                selectedIDs = [transfer.id]
            }
            triggerHaptic(.medium)
        }
        #if os(iOS)
        .listRowSeparator(isCompactMode ? .visible : .hidden)
        #endif
        .listRowInsets(EdgeInsets(
            top: isCompactMode ? 6 : 6,
            leading: isCompactMode ? 16 : 14,
            bottom: isCompactMode ? 6 : 6,
            trailing: isCompactMode ? 16 : 14
        ))
        .listRowBackground(
            isSelectingMultiple && selectedIDs.contains(transfer.id)
                ? Color.blue.opacity(0.08)
                : Color.clear
        )
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if !isSelectingMultiple {
                if transfer.state == .completed {
                    Button {
                        triggerHaptic(.light)
                        shareTransferFile(transfer)
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .tint(.blue)
                } else {
                    Button {
                        triggerHaptic(.light)
                        showTransferDetails(transfer)
                    } label: {
                        Label("Details", systemImage: "info.circle")
                    }
                    .tint(.indigo)
                }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !isSelectingMultiple {
                Button(role: .destructive) {
                    triggerHaptic(.medium)
                    removeTransferFromQueue(transfer)
                } label: {
                    Label("Remove", systemImage: "trash")
                }

                if transfer.canResume {
                    Button {
                        triggerHaptic(.medium)
                        resumeTransfer(transfer)
                    } label: {
                        Label("Resume", systemImage: "play.fill")
                    }
                    .tint(.green)
                } else if transfer.canPause {
                    Button {
                        triggerHaptic(.medium)
                        pauseTransfer(transfer)
                    } label: {
                        Label("Pause", systemImage: "pause.fill")
                    }
                    .tint(.orange)
                }
            }
        }
    }

    private enum HapticStyle {
        case light, medium, heavy
    }

    private func triggerHaptic(_ style: HapticStyle) {
        #if canImport(UIKit)
        let uiStyle: UIImpactFeedbackGenerator.FeedbackStyle
        switch style {
        case .light: uiStyle = .light
        case .medium: uiStyle = .medium
        case .heavy: uiStyle = .heavy
        }
        UIImpactFeedbackGenerator(style: uiStyle).impactOccurred()
        #endif
    }

    // MARK: - Multi-Select Helpers

    private func toggleSelection(for id: String) {
        triggerHaptic(.light)
        withAnimation(.easeInOut(duration: 0.1)) {
            if selectedIDs.contains(id) {
                selectedIDs.remove(id)
            } else {
                selectedIDs.insert(id)
            }
        }
    }

    private func exitSelectionMode() {
        isSelectingMultiple = false
        selectedIDs.removeAll()
    }

    private func deleteSelectedTransfers(deleteFiles: Bool) {
        let ids = selectedIDs
        withAnimation(.easeInOut(duration: 0.2)) {
            exitSelectionMode()
        }
        Task { @MainActor in
            var deletedCount = 0
            for id in ids {
                do {
                    try await viewModel.removeTransfer(id: id, deleteFiles: deleteFiles)
                    deletedCount += 1
                } catch {
                    // Skip failed deletions so deletedCount accurately reflects successful removals
                }
            }
            if deletedCount > 0 {
                let noun = deletedCount == 1 ? "item" : "items"
                let action = deleteFiles ? "deleted" : "removed"
                viewModel.showNotification("\(deletedCount) \(noun) \(action).")
            }
        }
    }

    // MARK: - Actions

    private func openFile(_ download: DownloadSnapshot) {
        guard FileManager.default.fileExists(atPath: download.destinationURL.path) else {
            viewModel.errorMessage = "File not found at '\(download.destinationURL.lastPathComponent)'."
            return
        }
        if download.destinationURL.isPlayableMedia {
            playerMediaTitle = download.destinationURL.lastPathComponent
            playerMediaURL = download.destinationURL
        } else {
            quickLookURL = download.destinationURL
        }
    }

    private func saveToFiles(_ download: DownloadSnapshot) {
        guard FileManager.default.fileExists(atPath: download.destinationURL.path) else {
            viewModel.errorMessage = "File not found at '\(download.destinationURL.lastPathComponent)'."
            return
        }
        activeSheet = .saveToFiles(download.destinationURL)
    }

    private func shareFile(_ download: DownloadSnapshot) {
        guard FileManager.default.fileExists(atPath: download.destinationURL.path) else {
            viewModel.errorMessage = "File not found at '\(download.destinationURL.lastPathComponent)'."
            return
        }
        activeSheet = .shareFile(download.destinationURL)
    }

    private func copyDownloadLink(_ download: DownloadSnapshot) {
        #if canImport(UIKit)
        UIPasteboard.general.string = download.url.absoluteString
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(download.url.absoluteString, forType: .string)
        #endif
        viewModel.showNotification("Download link copied to clipboard")
    }

    private func verifyIntegrity(_ download: DownloadSnapshot) {
        guard FileManager.default.fileExists(atPath: download.destinationURL.path) else {
            viewModel.errorMessage = "Cannot verify integrity: file not found on disk."
            return
        }
        let url = download.destinationURL
        let outcome = download.checksumOutcome
        viewModel.showNotification("Calculating SHA-256 for \(url.lastPathComponent)...")

        Task(priority: .userInitiated) {
            do {
                let sha = try await FileHasher.computeSHA256(for: url)
                let attr = try? FileManager.default.attributesOfItem(atPath: url.path)
                let size = (attr?[.size] as? NSNumber)?.int64Value ?? 0
                self.activeAlert = .integrity(
                    IntegrityReport(
                        filename: url.lastPathComponent,
                        fileSize: size,
                        sha256: sha,
                        outcome: outcome
                    )
                )
            } catch {
                self.viewModel.errorMessage = "Checksum verification failed: \(error.localizedDescription)"
            }
        }
    }

    private func showDetails(_ download: DownloadSnapshot) {
        selectedDownloadForDetails = download
    }

    private func pauseDownload(_ download: DownloadSnapshot) {
        Task { @MainActor in
            try? await viewModel.pauseDownload(id: download.id)
        }
    }

    private func resumeDownload(_ download: DownloadSnapshot) {
        Task { @MainActor in
            try? await viewModel.resumeDownload(id: download.id)
        }
    }

    private func retryDownload(_ download: DownloadSnapshot) {
        Task { @MainActor in
            try? await viewModel.retryDownload(id: download.id)
        }
    }

    private func restartDownload(_ download: DownloadSnapshot) {
        Task { @MainActor in
            try? await viewModel.restartDownload(id: download.id)
        }
    }

    private func cancelDownload(_ download: DownloadSnapshot) {
        Task { @MainActor in
            do {
                try await viewModel.cancelDownload(id: download.id, deleteFile: false)
            } catch {
                PipelineLogger.shared.log(stage: .ui, message: "Failed to cancel download \(download.id): \(error)")
            }
        }
    }

    private func removeFromQueue(_ download: DownloadSnapshot) {
        Task { @MainActor in
            let name = download.destinationURL.lastPathComponent
            if !download.isTerminal {
                do {
                    try await viewModel.cancelDownload(id: download.id, deleteFile: false)
                } catch {
                    PipelineLogger.shared.log(stage: .ui, message: "Failed to cancel download \(download.id): \(error)")
                }
            }
            do {
                try await viewModel.removeDownload(id: download.id, deleteFile: false)
            } catch {
                PipelineLogger.shared.log(stage: .ui, message: "Failed to remove download \(download.id): \(error)")
            }
            viewModel.showNotification("Removed '\(name)' from queue (file preserved)")
        }
    }

    private func promptDeleteFile(_ download: DownloadSnapshot) {
        activeAlert = .deleteConfirmation(download)
    }

    // MARK: - Unified Transfer Actions

    private func openTransferFile(_ transfer: UnifiedTransfer) {
        if transfer.destinationURL.isPlayableMedia {
            playerMediaTitle = transfer.name
            if transfer.isTorrent && !FileManager.default.fileExists(atPath: transfer.destinationURL.path) {
                playerMediaURL = URL(string: "lidtorrent://\(transfer.id)/0")
            } else {
                playerMediaURL = transfer.destinationURL
            }
        } else if transfer.isTorrent && (transfer.name.hasSuffix(".mp4") || transfer.name.hasSuffix(".mkv") || transfer.name.hasSuffix(".mov") || transfer.name.hasSuffix(".mp3")) {
            playerMediaTitle = transfer.name
            playerMediaURL = URL(string: "lidtorrent://\(transfer.id)/0")
        } else {
            #if canImport(QuickLook)
            quickLookURL = transfer.destinationURL
            #endif
        }
    }

    private func streamTransferOnline(_ transfer: UnifiedTransfer) {
        if transfer.isTorrent {
            playerSource = .torrentSwarm(
                infoHash: transfer.infoHash ?? transfer.id,
                fileIndex: 0,
                title: transfer.name
            )
            return
        }
        guard let url = URL(string: transfer.source) else {
            viewModel.showNotification("Invalid stream URL")
            return
        }
        Task { @MainActor in
            let record = try? await viewModel.engine.persistenceStore.fetch(tag: transfer.id)
            let headers = record?.headers ?? [:]
            let context = BrowserRequestContext(
                url: url,
                userAgent: headers["User-Agent"],
                customHeaders: headers
            )
            if transfer.type == .hls || url.pathExtension.lowercased() == "m3u8" {
                playerSource = .hlsStream(
                    url: url,
                    variantPreferences: nil,
                    title: transfer.name,
                    requestContext: context
                )
            } else if transfer.type == .dash || url.pathExtension.lowercased() == "mpd" {
                playerSource = .dashStream(
                    manifestURL: url,
                    selectedRepresentationID: nil,
                    title: transfer.name,
                    requestContext: context
                )
            } else {
                playerSource = .networkStream(
                    url: url,
                    headers: headers,
                    title: transfer.name
                )
            }
        }
    }

    private func openTransferInPlayer(_ transfer: UnifiedTransfer) {
        if transfer.state == .completed && FileManager.default.fileExists(atPath: transfer.destinationURL.path) {
            playerSource = .localFile(url: transfer.destinationURL, title: transfer.name)
            return
        }
        if transfer.isTorrent {
            playerSource = .torrentSwarm(
                infoHash: transfer.infoHash ?? transfer.id,
                fileIndex: 0,
                title: transfer.name
            )
            return
        }

        Task { @MainActor in
            let fm = FileManager.default
            if fm.fileExists(atPath: transfer.destinationURL.path),
               (fm.fileSize(atPath: transfer.destinationURL.path) ?? 0) > 0 {
                playerSource = .partialDownload(
                    fileURL: transfer.destinationURL,
                    totalExpectedBytes: transfer.totalBytes,
                    title: transfer.name
                )
                return
            }

            // Check HLS persisted segment directory for downloaded segments
            if let hlsStore = try? HLSPersistenceStore(storageDirectoryURL: viewModel.engine.persistenceStore.storageDirectoryURL),
               let hlsRecord = try? await hlsStore.load(id: transfer.id) {
                let segDir = hlsRecord.segmentDirectoryURL
                let partFiles = (try? fm.contentsOfDirectory(
                    at: segDir,
                    includingPropertiesForKeys: [.creationDateKey, .fileSizeKey],
                    options: [.skipsHiddenFiles]
                ))?
                .filter { $0.pathExtension.lowercased() == "part" && (fm.fileSize(atPath: $0.path) ?? 0) > 0 }
                .sorted { lhs, rhs in
                    let lDate = (try? lhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                    let rDate = (try? rhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                    if lDate != rDate { return lDate < rDate }
                    return lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
                } ?? []

                if !partFiles.isEmpty {
                    let previewTS = fm.temporaryDirectory.appendingPathComponent("partial_\(transfer.id).ts")
                    if let assembled = await Self.assemblePartialTS(parts: partFiles, to: previewTS) {
                        playerSource = .partialDownload(
                            fileURL: assembled,
                            totalExpectedBytes: transfer.totalBytes,
                            title: transfer.name
                        )
                        return
                    }
                }
            }

            // Check foreground segmented download `.tmp/segment-0.part`
            let seg0 = transfer.destinationURL.deletingLastPathComponent()
                .appendingPathComponent(".tmp_\(transfer.id)", isDirectory: true)
                .appendingPathComponent("segment-0.part")
            if fm.fileExists(atPath: seg0.path), (fm.fileSize(atPath: seg0.path) ?? 0) > 0 {
                playerSource = .partialDownload(
                    fileURL: seg0,
                    totalExpectedBytes: transfer.totalBytes,
                    title: transfer.name
                )
                return
            }

            viewModel.showNotification("No downloaded media on disk yet. Try 'Stream Online'.")
        }
    }

    private static func assemblePartialTS(parts: [URL], to outputURL: URL) async -> URL? {
        await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            if fm.fileExists(atPath: outputURL.path) {
                try? fm.removeItem(at: outputURL)
            }
            guard fm.createFile(atPath: outputURL.path, contents: nil),
                  let handle = try? FileHandle(forWritingTo: outputURL) else {
                return nil
            }
            defer { try? handle.close() }
            var totalWritten: Int64 = 0
            for part in parts {
                guard let data = try? Data(contentsOf: part), !data.isEmpty else { continue }
                handle.write(data)
                totalWritten += Int64(data.count)
            }
            return totalWritten > 0 ? outputURL : nil
        }.value
    }

    private func saveTransferToFiles(_ transfer: UnifiedTransfer) {
        guard FileManager.default.fileExists(atPath: transfer.destinationURL.path) else {
            viewModel.errorMessage = "File not found at '\(transfer.destinationURL.lastPathComponent)'."
            return
        }
        activeSheet = .saveToFiles(transfer.destinationURL)
    }

    private func shareTransferFile(_ transfer: UnifiedTransfer) {
        guard FileManager.default.fileExists(atPath: transfer.destinationURL.path) else {
            viewModel.errorMessage = "File not found at '\(transfer.destinationURL.lastPathComponent)'."
            return
        }
        activeSheet = .shareFile(transfer.destinationURL)
    }

    private func copyTransferLink(_ transfer: UnifiedTransfer) {
        #if canImport(UIKit)
        UIPasteboard.general.string = transfer.source
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transfer.source, forType: .string)
        #endif
        viewModel.showNotification("Link copied to clipboard")
    }

    private func showTransferDetails(_ transfer: UnifiedTransfer) {
        selectedTransferForDetails = transfer
    }

    private func pauseTransfer(_ transfer: UnifiedTransfer) {
        Task { @MainActor in
            try? await viewModel.pauseTransfer(id: transfer.id)
        }
    }

    private func resumeTransfer(_ transfer: UnifiedTransfer) {
        Task { @MainActor in
            try? await viewModel.resumeTransfer(id: transfer.id)
        }
    }

    private func removeTransferFromQueue(_ transfer: UnifiedTransfer) {
        Task { @MainActor in
            do {
                try await viewModel.removeTransfer(id: transfer.id, deleteFiles: false)
            } catch {
                PipelineLogger.shared.log(stage: .ui, message: "Failed to remove transfer \(transfer.id): \(error)")
            }
            viewModel.showNotification("Removed '\(transfer.name)' from queue (file preserved)")
        }
    }

    private func promptDeleteTransferFile(_ transfer: UnifiedTransfer) {
        activeAlert = .deleteTransferConfirmation(transfer)
    }

    private func toggleTransferSchedule(_ transfer: UnifiedTransfer) {
        viewModel.toggleScheduled(transferID: transfer.id)
        let isNow = viewModel.isScheduled(transferID: transfer.id)
        viewModel.showNotification(isNow ? "Added '\(transfer.name)' to schedule" : "Removed '\(transfer.name)' from schedule")
    }
}

// MARK: - Download Menu Content (Shared for 3-Dot Menu and Long-Press Context Menu)

public struct DownloadMenuContent: View {
    public let download: DownloadSnapshot
    public let onOpen: () -> Void
    public let onSaveToFiles: () -> Void
    public let onShare: () -> Void
    public let onCopyLink: () -> Void
    public let onVerifyIntegrity: () -> Void
    public let onShowDetails: () -> Void
    public let onPause: () -> Void
    public let onResume: () -> Void
    public let onRetry: () -> Void
    public let onRestart: () -> Void
    public let onCancel: () -> Void
    public let onRemoveQueue: () -> Void
    public let onDeleteFile: () -> Void

    public init(
        download: DownloadSnapshot,
        onOpen: @escaping () -> Void = {},
        onSaveToFiles: @escaping () -> Void = {},
        onShare: @escaping () -> Void = {},
        onCopyLink: @escaping () -> Void = {},
        onVerifyIntegrity: @escaping () -> Void = {},
        onShowDetails: @escaping () -> Void = {},
        onPause: @escaping () -> Void = {},
        onResume: @escaping () -> Void = {},
        onRetry: @escaping () -> Void = {},
        onRestart: @escaping () -> Void = {},
        onCancel: @escaping () -> Void = {},
        onRemoveQueue: @escaping () -> Void = {},
        onDeleteFile: @escaping () -> Void = {}
    ) {
        self.download = download
        self.onOpen = onOpen
        self.onSaveToFiles = onSaveToFiles
        self.onShare = onShare
        self.onCopyLink = onCopyLink
        self.onVerifyIntegrity = onVerifyIntegrity
        self.onShowDetails = onShowDetails
        self.onPause = onPause
        self.onResume = onResume
        self.onRetry = onRetry
        self.onRestart = onRestart
        self.onCancel = onCancel
        self.onRemoveQueue = onRemoveQueue
        self.onDeleteFile = onDeleteFile
    }

    public var body: some View {
        switch download.state {
        case .completed:
            Button(action: onOpen) {
                Label("Open File", systemImage: "doc.text")
            }
            Button(action: onSaveToFiles) {
                Label("Save to Files", systemImage: "folder")
            }
            Button(action: onShare) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            Button(action: onCopyLink) {
                Label("Copy Download Link", systemImage: "doc.on.doc")
            }
            Button(action: onVerifyIntegrity) {
                Label("Verify Integrity", systemImage: "checkmark.shield")
            }
            Button(action: onShowDetails) {
                Label("Show Details", systemImage: "info.circle")
            }
            Divider()
            Button(action: onRemoveQueue) {
                Label("Remove from Queue", systemImage: "minus.circle")
            }
            Button(role: .destructive, action: onDeleteFile) {
                Label("Delete File", systemImage: "trash")
            }

        case .downloading, .probing:
            Button(action: onPause) {
                Label("Pause", systemImage: "pause.fill")
            }
            Button(action: onCopyLink) {
                Label("Copy Download Link", systemImage: "doc.on.doc")
            }
            Button(action: onShowDetails) {
                Label("Show Details", systemImage: "info.circle")
            }
            Divider()
            Button(action: onCancel) {
                Label("Cancel Transfer", systemImage: "xmark.circle")
            }
            Button(action: onRemoveQueue) {
                Label("Remove from Queue", systemImage: "minus.circle")
            }

        case .paused:
            Button(action: onResume) {
                Label("Resume", systemImage: "play.fill")
            }
            Button(action: onCopyLink) {
                Label("Copy Download Link", systemImage: "doc.on.doc")
            }
            Button(action: onShowDetails) {
                Label("Show Details", systemImage: "info.circle")
            }
            Divider()
            Button(action: onRemoveQueue) {
                Label("Remove from Queue", systemImage: "minus.circle")
            }
            Button(role: .destructive, action: onDeleteFile) {
                Label("Delete File", systemImage: "trash")
            }

        case .failed:
            if download.isNonResumable {
                Button(action: onRestart) {
                    Label("Restart Download", systemImage: "arrow.counterclockwise")
                }
            } else if download.isRateLimited {
                Button(action: onRetry) {
                    Label("Retry when eligible", systemImage: "clock.arrow.circlepath")
                }
            } else {
                Button(action: onResume) {
                    Label("Resume", systemImage: "play.fill")
                }
            }
            Button(action: onCopyLink) {
                Label("Copy Download Link", systemImage: "doc.on.doc")
            }
            Button(action: onShowDetails) {
                Label("Show Details", systemImage: "info.circle")
            }
            Divider()
            Button(action: onRemoveQueue) {
                Label("Remove from Queue", systemImage: "minus.circle")
            }
            Button(role: .destructive, action: onDeleteFile) {
                Label("Delete File", systemImage: "trash")
            }

        case .cancelled, .pending:
            if download.canResume {
                Button(action: onResume) {
                    Label("Resume", systemImage: "play.fill")
                }
            }
            Button(action: onCopyLink) {
                Label("Copy Download Link", systemImage: "doc.on.doc")
            }
            Button(action: onShowDetails) {
                Label("Show Details", systemImage: "info.circle")
            }
            Divider()
            Button(action: onRemoveQueue) {
                Label("Remove from Queue", systemImage: "minus.circle")
            }
            Button(role: .destructive, action: onDeleteFile) {
                Label("Delete File", systemImage: "trash")
            }
        }
    }
}

// MARK: - Vertical Three-Dot Action Icon

public struct VerticalThreeDotsButtonLabel: View {
    public init() {}

    public var body: some View {
        ZStack {
            Circle()
                .fill(Color.secondary.opacity(0.22))
                .frame(width: 32, height: 32)

            Image(systemName: "ellipsis")
                .rotationEffect(.degrees(90))
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.primary)
        }
        .frame(width: 32, height: 32)
        .contentShape(Circle())
    }
}

// MARK: - Unified Transfer Row View

private struct GradientTransferProgressBar: View {
    let progress: Double
    let isIndeterminate: Bool
    let gradientColors: [Color]
    let height: CGFloat

    @State private var shimmerOffset: CGFloat = -0.5

    init(progress: Double, isIndeterminate: Bool, gradientColors: [Color], height: CGFloat = 6) {
        self.progress = progress
        self.isIndeterminate = isIndeterminate
        self.gradientColors = gradientColors
        self.height = height
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.16))
                    .frame(height: height)

                if isIndeterminate {
                    Capsule()
                        .fill(LinearGradient(colors: gradientColors, startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(36, geo.size.width * 0.35), height: height)
                        .offset(x: shimmerOffset * geo.size.width)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                                shimmerOffset = 0.65
                            }
                        }
                } else {
                    let clamped = max(0.0, min(progress, 1.0))
                    Capsule()
                        .fill(LinearGradient(colors: gradientColors, startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(clamped > 0 ? height : 0, geo.size.width * clamped), height: height)
                        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: clamped)
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: height)
    }
}

public struct UnifiedTransferRowView: View {
    public let viewModel: DownloadManagerViewModel
    public let transfer: UnifiedTransfer
    public var isSelectingMultiple: Bool
    public var isCompact: Bool = false
    public var onTapContent: (() -> Void)?
    public let onOpen: () -> Void
    public var onStreamOnline: () -> Void = {}
    public var onOpenInPlayer: () -> Void = {}
    public let onSaveToFiles: () -> Void
    public let onShare: () -> Void
    public let onCopyLink: () -> Void
    public let onShowDetails: () -> Void
    public let onPause: () -> Void
    public let onResume: () -> Void
    public var onRetry: () -> Void = {}
    public var onUpdateLink: () -> Void = {}
    public var onRefreshFromBrowser: () -> Void = {}
    public let onRemoveQueue: () -> Void
    public let onDeleteFile: () -> Void

    public init(
        viewModel: DownloadManagerViewModel,
        transfer: UnifiedTransfer,
        isSelectingMultiple: Bool = false,
        isCompact: Bool = false,
        onTapContent: (() -> Void)? = nil,
        onOpen: @escaping () -> Void = {},
        onStreamOnline: @escaping () -> Void = {},
        onOpenInPlayer: @escaping () -> Void = {},
        onSaveToFiles: @escaping () -> Void = {},
        onShare: @escaping () -> Void = {},
        onCopyLink: @escaping () -> Void = {},
        onShowDetails: @escaping () -> Void = {},
        onPause: @escaping () -> Void = {},
        onResume: @escaping () -> Void = {},
        onRetry: @escaping () -> Void = {},
        onUpdateLink: @escaping () -> Void = {},
        onRefreshFromBrowser: @escaping () -> Void = {},
        onRemoveQueue: @escaping () -> Void = {},
        onDeleteFile: @escaping () -> Void = {}
    ) {
        self.viewModel = viewModel
        self.transfer = transfer
        self.isSelectingMultiple = isSelectingMultiple
        self.isCompact = isCompact
        self.onTapContent = onTapContent
        self.onOpen = onOpen
        self.onStreamOnline = onStreamOnline
        self.onOpenInPlayer = onOpenInPlayer
        self.onSaveToFiles = onSaveToFiles
        self.onShare = onShare
        self.onCopyLink = onCopyLink
        self.onShowDetails = onShowDetails
        self.onPause = onPause
        self.onResume = onResume
        self.onRetry = onRetry
        self.onUpdateLink = onUpdateLink
        self.onRefreshFromBrowser = onRefreshFromBrowser
        self.onRemoveQueue = onRemoveQueue
        self.onDeleteFile = onDeleteFile
    }

    public var body: some View {
        let content = VStack(alignment: .leading, spacing: isCompact ? 5 : 8) {
            // Header: Media Icon Badge, Name, clock icon, TypeBadge, UnifiedStatusBadge, and visible Three-Dot (⋮) Menu
            HStack(alignment: .center, spacing: isCompact ? 8 : 10) {
                if !isCompact {
                    transferIconBadge
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(transfer.name)
                            .font(isCompact ? .subheadline.weight(.semibold) : .headline)
                            .lineLimit(1)

                        if viewModel.isScheduled(transferID: transfer.id) {
                            Image(systemName: "clock.fill")
                                .font(.caption2)
                                .foregroundColor(.indigo)
                        }
                    }

                    if !isCompact {
                        HStack(spacing: 5) {
                            TypeBadge(type: transfer.type)
                            UnifiedStatusBadge(state: transfer.state)
                        }
                    }
                }

                Spacer(minLength: 4)

                if isCompact {
                    TypeBadge(type: transfer.type)
                    UnifiedStatusBadge(state: transfer.state)
                }

                if !isSelectingMultiple {
                    quickActionCircleButton

                    StableTransferRowMenu(
                        transfer: transfer,
                        isScheduled: viewModel.isScheduled(transferID: transfer.id),
                        onOpen: onOpen,
                        onStreamOnline: onStreamOnline,
                        onOpenInPlayer: onOpenInPlayer,
                        onSaveToFiles: onSaveToFiles,
                        onShare: onShare,
                        onCopyLink: onCopyLink,
                        onShowDetails: onShowDetails,
                        onPause: onPause,
                        onResume: onResume,
                        onRetry: onRetry,
                        onUpdateLink: onUpdateLink,
                        onRefreshFromBrowser: onRefreshFromBrowser,
                        onToggleSchedule: { viewModel.toggleScheduled(transferID: transfer.id) },
                        onRemoveQueue: onRemoveQueue,
                        onDeleteFile: onDeleteFile
                    )
                    .equatable()
                }
            }

            // Sleek Gradient Progress Bar
            let isIndeterminate = (transfer.totalBytes ?? 0) <= 0 && transfer.state == .downloading
            GradientTransferProgressBar(
                progress: transfer.progressFraction,
                isIndeterminate: isIndeterminate,
                gradientColors: progressGradientColors,
                height: isCompact ? 4 : 6
            )

            // Metrics: Size & Speed
            HStack {
                if let total = transfer.totalBytes, total > 0 {
                    let totalStr: String = {
                        if transfer.isStreaming && transfer.state == .downloading {
                            return "~\(UIFormatters.formatBytes(total)) (Estimated)"
                        } else {
                            return UIFormatters.formatBytes(total)
                        }
                    }()
                    Text("\(UIFormatters.formatBytes(transfer.completedBytes)) / \(totalStr)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("\(UIFormatters.formatBytes(transfer.completedBytes)) (Size pending)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if transfer.state == .downloading {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.blue)
                            .frame(width: 6, height: 6)
                        if transfer.isTorrent {
                            Text("↓ \(UIFormatters.formatSpeed(transfer.downloadSpeedBytesPerSecond))  ↑ \(UIFormatters.formatSpeed(transfer.uploadSpeedBytesPerSecond))")
                                .font(.caption.weight(.medium))
                                .foregroundColor(.blue)
                        } else {
                            Text(UIFormatters.formatSpeed(transfer.downloadSpeedBytesPerSecond))
                                .font(.caption.weight(.medium))
                                .foregroundColor(.blue)
                        }
                    }
                } else if transfer.state == .seeding {
                    Text("Seeding • ↑ \(UIFormatters.formatSpeed(transfer.uploadSpeedBytesPerSecond))")
                        .font(.caption.weight(.medium))
                        .foregroundColor(.teal)
                } else {
                    Text("\(Int(transfer.progressFraction * 100))%")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                }
            }

            // Extra metrics for torrent: Peers & Seeds (hidden in compact mode)
            if !isCompact && transfer.isTorrent {
                HStack {
                    Text("Peers: \(transfer.connectedPeers ?? 0) • Seeds: \(transfer.connectedSeeds ?? 0)")
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.secondary)
                    if let prio = transfer.torrentPriority {
                        Spacer()
                        Text("Priority: \(prioLabel(prio))")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }

        Group {
            if isCompact {
                content
                    .padding(.vertical, 4)
            } else {
                content
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(statusColor.opacity(0.18), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.04), radius: 5, x: 0, y: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onTapContent?()
        }
        .contextMenu {
            UnifiedTransferMenuContent(
                transfer: transfer,
                isScheduled: viewModel.isScheduled(transferID: transfer.id),
                onOpen: onOpen,
                onStreamOnline: onStreamOnline,
                onOpenInPlayer: onOpenInPlayer,
                onSaveToFiles: onSaveToFiles,
                onShare: onShare,
                onCopyLink: onCopyLink,
                onShowDetails: onShowDetails,
                onPause: onPause,
                onResume: onResume,
                onRetry: onRetry,
                onUpdateLink: onUpdateLink,
                onRefreshFromBrowser: onRefreshFromBrowser,
                onToggleSchedule: { viewModel.toggleScheduled(transferID: transfer.id) },
                onRemoveQueue: onRemoveQueue,
                onDeleteFile: onDeleteFile
            )
        }
    }

    @ViewBuilder
    private var quickActionCircleButton: some View {
        if transfer.canPause {
            circularIconButton(icon: "pause.fill", color: .orange, label: "Pause \(transfer.name)", action: onPause)
        } else if transfer.canResume {
            circularIconButton(icon: "play.fill", color: .green, label: "Resume \(transfer.name)", action: onResume)
        } else if transfer.canRetry {
            circularIconButton(icon: "arrow.clockwise", color: .blue, label: "Retry \(transfer.name)", action: onRetry)
        } else if transfer.state == .completed {
            circularIconButton(icon: "arrow.up.forward.square", color: .blue, label: "Open \(transfer.name)", action: onOpen)
        }
    }

    private func circularIconButton(icon: String, color: Color, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.15))
                    .frame(width: 32, height: 32)
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(color)
            }
        }
        .buttonStyle(BorderlessButtonStyle())
        .accessibilityLabel(label)
    }

    private var transferIconBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(statusColor.opacity(0.14))
                .frame(width: 38, height: 38)

            Image(systemName: iconNameForTransfer)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(statusColor)
        }
    }

    private var iconNameForTransfer: String {
        switch transfer.type {
        case .torrent: return "arrow.triangle.2.circlepath"
        case .hls, .dash, .streaming: return "dot.radiowaves.left.and.right"
        case .http:
            return transfer.category.iconName
        }
    }

    private var progressGradientColors: [Color] {
        switch transfer.state {
        case .downloading: return [.blue, .cyan]
        case .completed: return [.green, .mint]
        case .paused: return [.orange, .yellow]
        case .failed: return [.red, .pink]
        case .queued: return [.gray, .secondary]
        case .seeding: return [.purple, .indigo]
        }
    }

    private func prioLabel(_ p: TorrentPriority) -> String {
        switch p {
        case .low: return "Low"
        case .normal: return "Normal"
        case .high: return "High"
        }
    }

    private var statusColor: Color {
        switch transfer.state {
        case .downloading: return .blue
        case .completed: return .green
        case .paused: return .orange
        case .failed: return .red
        case .queued: return .gray
        case .seeding: return .teal
        }
    }
}

// MARK: - Unified Transfer Menu Content

private struct StableTransferRowMenu: View, Equatable {
    let transfer: UnifiedTransfer
    let isScheduled: Bool
    let onOpen: () -> Void
    let onStreamOnline: () -> Void
    let onOpenInPlayer: () -> Void
    let onSaveToFiles: () -> Void
    let onShare: () -> Void
    let onCopyLink: () -> Void
    let onShowDetails: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void
    let onRetry: () -> Void
    let onUpdateLink: () -> Void
    let onRefreshFromBrowser: () -> Void
    let onToggleSchedule: () -> Void
    let onRemoveQueue: () -> Void
    let onDeleteFile: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.transfer.id == rhs.transfer.id &&
        lhs.transfer.name == rhs.transfer.name &&
        lhs.transfer.state == rhs.transfer.state &&
        lhs.transfer.isTorrent == rhs.transfer.isTorrent &&
        lhs.isScheduled == rhs.isScheduled
    }

    var body: some View {
        Menu {
            UnifiedTransferMenuContent(
                transfer: transfer,
                isScheduled: isScheduled,
                onOpen: onOpen,
                onStreamOnline: onStreamOnline,
                onOpenInPlayer: onOpenInPlayer,
                onSaveToFiles: onSaveToFiles,
                onShare: onShare,
                onCopyLink: onCopyLink,
                onShowDetails: onShowDetails,
                onPause: onPause,
                onResume: onResume,
                onRetry: onRetry,
                onUpdateLink: onUpdateLink,
                onRefreshFromBrowser: onRefreshFromBrowser,
                onToggleSchedule: onToggleSchedule,
                onRemoveQueue: onRemoveQueue,
                onDeleteFile: onDeleteFile
            )
        } label: {
            VerticalThreeDotsButtonLabel()
        }
        .buttonStyle(BorderlessButtonStyle())
        .accessibilityLabel("Transfer actions for \(transfer.name)")
    }
}

public struct UnifiedTransferMenuContent: View {
    public let transfer: UnifiedTransfer
    public var isScheduled: Bool = false
    public let onOpen: () -> Void
    public var onStreamOnline: () -> Void = {}
    public var onOpenInPlayer: () -> Void = {}
    public let onSaveToFiles: () -> Void
    public let onShare: () -> Void
    public let onCopyLink: () -> Void
    public let onShowDetails: () -> Void
    public let onPause: () -> Void
    public let onResume: () -> Void
    public var onRetry: () -> Void = {}
    public var onUpdateLink: () -> Void = {}
    public var onRefreshFromBrowser: () -> Void = {}
    public var onToggleSchedule: () -> Void = {}
    public let onRemoveQueue: () -> Void
    public let onDeleteFile: () -> Void

    public init(
        transfer: UnifiedTransfer,
        isScheduled: Bool = false,
        onOpen: @escaping () -> Void = {},
        onStreamOnline: @escaping () -> Void = {},
        onOpenInPlayer: @escaping () -> Void = {},
        onSaveToFiles: @escaping () -> Void = {},
        onShare: @escaping () -> Void = {},
        onCopyLink: @escaping () -> Void = {},
        onShowDetails: @escaping () -> Void = {},
        onPause: @escaping () -> Void = {},
        onResume: @escaping () -> Void = {},
        onRetry: @escaping () -> Void = {},
        onUpdateLink: @escaping () -> Void = {},
        onRefreshFromBrowser: @escaping () -> Void = {},
        onToggleSchedule: @escaping () -> Void = {},
        onRemoveQueue: @escaping () -> Void = {},
        onDeleteFile: @escaping () -> Void = {}
    ) {
        self.transfer = transfer
        self.isScheduled = isScheduled
        self.onOpen = onOpen
        self.onStreamOnline = onStreamOnline
        self.onOpenInPlayer = onOpenInPlayer
        self.onSaveToFiles = onSaveToFiles
        self.onShare = onShare
        self.onCopyLink = onCopyLink
        self.onShowDetails = onShowDetails
        self.onPause = onPause
        self.onResume = onResume
        self.onRetry = onRetry
        self.onUpdateLink = onUpdateLink
        self.onRefreshFromBrowser = onRefreshFromBrowser
        self.onToggleSchedule = onToggleSchedule
        self.onRemoveQueue = onRemoveQueue
        self.onDeleteFile = onDeleteFile
    }

    public var body: some View {
        Group {
            Button(action: onToggleSchedule) {
                Label(
                    isScheduled ? "Remove from Schedule" : "Add to Schedule",
                    systemImage: isScheduled ? "clock.badge.xmark" : "clock.badge"
                )
            }

            if transfer.canPause {
                Button(action: onPause) {
                    Label("Pause", systemImage: "pause.fill")
                }
            } else if transfer.canResume {
                Button(action: onResume) {
                    Label("Resume", systemImage: "play.fill")
                }
            }

            if transfer.canRetry {
                Button(action: onRetry) {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
            }

            if transfer.canRetry || transfer.canResume {
                Button(action: onUpdateLink) {
                    Label("Update Download Link", systemImage: "link")
                }
                if !transfer.isTorrent {
                    Button(action: onRefreshFromBrowser) {
                        Label("Refresh Link from Browser", systemImage: "safari")
                    }
                }
            }

            if transfer.state == .completed {
                Button(action: onOpen) {
                    Label("Open File", systemImage: "doc.text")
                }
                Button(action: onSaveToFiles) {
                    Label("Save to Files", systemImage: "folder")
                }
                Button(action: onShare) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }

            if transfer.destinationURL.isPlayableMedia || transfer.type == .hls || transfer.type == .dash {
                if URL(string: transfer.source) != nil || transfer.isTorrent {
                    Button(action: onStreamOnline) {
                        Label("Stream Online", systemImage: "play.tv")
                    }
                }
                if transfer.state != .completed {
                    Button(action: onOpenInPlayer) {
                        Label("Open in Player", systemImage: "play.circle")
                    }
                }
            }

            Button(action: onCopyLink) {
                Label(transfer.isTorrent ? "Copy Torrent Source" : "Copy Download Link", systemImage: "doc.on.doc")
            }

            Button(action: onShowDetails) {
                Label("Show Details", systemImage: "info.circle")
            }

            Divider()

            Button(action: onRemoveQueue) {
                Label("Remove from Queue", systemImage: "minus.circle")
            }

            Button(role: .destructive, action: onDeleteFile) {
                Label("Delete Files from Disk", systemImage: "trash")
            }
        }
    }
}

// MARK: - Row View

public struct DownloadRowView: View {
    public let viewModel: DownloadManagerViewModel
    public let download: DownloadSnapshot
    public var isSelectingMultiple: Bool
    public var onTapContent: (() -> Void)?
    public let onOpen: () -> Void
    public var onStreamOnline: () -> Void = {}
    public var onOpenInPlayer: () -> Void = {}
    public let onSaveToFiles: () -> Void
    public let onShare: () -> Void
    public let onCopyLink: () -> Void
    public let onVerifyIntegrity: () -> Void
    public let onShowDetails: () -> Void
    public let onPause: () -> Void
    public let onResume: () -> Void
    public let onRetry: () -> Void
    public let onRestart: () -> Void
    public let onCancel: () -> Void
    public let onRemoveQueue: () -> Void
    public let onDeleteFile: () -> Void

    public init(
        viewModel: DownloadManagerViewModel,
        download: DownloadSnapshot,
        isSelectingMultiple: Bool = false,
        onTapContent: (() -> Void)? = nil,
        onOpen: @escaping () -> Void = {},
        onStreamOnline: @escaping () -> Void = {},
        onOpenInPlayer: @escaping () -> Void = {},
        onSaveToFiles: @escaping () -> Void = {},
        onShare: @escaping () -> Void = {},
        onCopyLink: @escaping () -> Void = {},
        onVerifyIntegrity: @escaping () -> Void = {},
        onShowDetails: @escaping () -> Void = {},
        onPause: @escaping () -> Void = {},
        onResume: @escaping () -> Void = {},
        onRetry: @escaping () -> Void = {},
        onRestart: @escaping () -> Void = {},
        onCancel: @escaping () -> Void = {},
        onRemoveQueue: @escaping () -> Void = {},
        onDeleteFile: @escaping () -> Void = {}
    ) {
        self.viewModel = viewModel
        self.download = download
        self.isSelectingMultiple = isSelectingMultiple
        self.onTapContent = onTapContent
        self.onOpen = onOpen
        self.onStreamOnline = onStreamOnline
        self.onOpenInPlayer = onOpenInPlayer
        self.onSaveToFiles = onSaveToFiles
        self.onShare = onShare
        self.onCopyLink = onCopyLink
        self.onVerifyIntegrity = onVerifyIntegrity
        self.onShowDetails = onShowDetails
        self.onPause = onPause
        self.onResume = onResume
        self.onRetry = onRetry
        self.onRestart = onRestart
        self.onCancel = onCancel
        self.onRemoveQueue = onRemoveQueue
        self.onDeleteFile = onDeleteFile
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Filename, Status Badge, and visible Three-Dot (⋮) Menu
            HStack(alignment: .center, spacing: 8) {
                Text(download.destinationURL.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)

                Spacer(minLength: 4)

                StatusBadge(state: download.state)

                if !isSelectingMultiple {
                    Menu {
                        DownloadMenuContent(
                            download: download,
                            onOpen: onOpen,
                            onSaveToFiles: onSaveToFiles,
                            onShare: onShare,
                            onCopyLink: onCopyLink,
                            onVerifyIntegrity: onVerifyIntegrity,
                            onShowDetails: onShowDetails,
                            onPause: onPause,
                            onResume: onResume,
                            onRetry: onRetry,
                            onRestart: onRestart,
                            onCancel: onCancel,
                            onRemoveQueue: onRemoveQueue,
                            onDeleteFile: onDeleteFile
                        )
                    } label: {
                        VerticalThreeDotsButtonLabel()
                    }
                    .buttonStyle(BorderlessButtonStyle())
                    .accessibilityLabel("Download actions for \(download.destinationURL.lastPathComponent)")
                }
            }

            // Progress Bar
            ProgressView(value: download.progressFraction)
                .progressViewStyle(LinearProgressViewStyle(tint: statusColor))

            // Metrics: Size, Progress %, Speed, ETA
            HStack {
                Text("\(UIFormatters.formatBytes(download.completedBytes)) / \(download.totalBytes.map(UIFormatters.formatBytes) ?? "Unknown")")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                if download.state == .downloading {
                    Text("\(UIFormatters.formatSpeed(download.currentBytesPerSecond)) • ETA: \(UIFormatters.formatTimeInterval(download.estimatedTimeRemaining))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("\(Int(download.progressFraction * 100))%")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Quick Inline Action Controls
            HStack(spacing: 12) {
                if download.state == .downloading || download.state == .probing {
                    Button {
                        onPause()
                    } label: {
                        Label("Pause", systemImage: "pause.fill")
                            .font(.caption2)
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                } else if download.state == .paused {
                    Button {
                        onResume()
                    } label: {
                        Label("Resume", systemImage: "play.fill")
                            .font(.caption2)
                    }
                    .buttonStyle(.bordered)
                    .tint(.green)
                } else if download.state == .completed {
                    Button {
                        onOpen()
                    } label: {
                        Label("Open File", systemImage: "doc.text")
                            .font(.caption2)
                    }
                    .buttonStyle(.bordered)
                    .tint(.blue)
                } else if download.isFailed {
                    if download.isNonResumable {
                        Button {
                            onRestart()
                        } label: {
                            Label("Restart", systemImage: "arrow.counterclockwise")
                                .font(.caption2)
                        }
                        .buttonStyle(.bordered)
                        .tint(.orange)
                    } else if download.isRateLimited {
                        Button {
                            onRetry()
                        } label: {
                            Label("Retry when eligible", systemImage: "clock.arrow.circlepath")
                                .font(.caption2)
                        }
                        .buttonStyle(.bordered)
                        .tint(.purple)
                    } else {
                        Button {
                            onResume()
                        } label: {
                            Label("Resume", systemImage: "play.fill")
                                .font(.caption2)
                        }
                        .buttonStyle(.bordered)
                        .tint(.green)
                    }
                }

                if !download.isTerminal {
                    Button(role: .destructive) {
                        onCancel()
                    } label: {
                        Label("Cancel", systemImage: "xmark")
                            .font(.caption2)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.top, 2)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onTapContent?()
        }
        .padding(.vertical, 4)
        .contextMenu {
            DownloadMenuContent(
                download: download,
                onOpen: onOpen,
                onSaveToFiles: onSaveToFiles,
                onShare: onShare,
                onCopyLink: onCopyLink,
                onVerifyIntegrity: onVerifyIntegrity,
                onShowDetails: onShowDetails,
                onPause: onPause,
                onResume: onResume,
                onRetry: onRetry,
                onRestart: onRestart,
                onCancel: onCancel,
                onRemoveQueue: onRemoveQueue,
                onDeleteFile: onDeleteFile
            )
        }
    }

    private var statusColor: Color {
        switch download.state {
        case .downloading, .probing:
            return .blue
        case .completed:
            return .green
        case .paused:
            return .orange
        case .failed:
            return .red
        case .cancelled, .pending:
            return .gray
        }
    }
}

// MARK: - Status Badge

public struct StatusBadge: View {
    public let state: DownloadState

    public var body: some View {
        Text(statusText)
            .font(.caption2.bold())
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(backgroundColor.opacity(0.15))
            .foregroundColor(backgroundColor)
            .clipShape(Capsule())
    }

    private var statusText: String {
        switch state {
        case .pending: return "Queued"
        case .probing: return "Probing"
        case .downloading: return "Downloading"
        case .paused: return "Paused"
        case .completed: return "Done"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    private var backgroundColor: Color {
        switch state {
        case .pending: return .gray
        case .probing, .downloading: return .blue
        case .paused: return .orange
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        }
    }
}

// MARK: - Queue Summary Header & Download Status Counters

public typealias QueueStatsHeader = QueueSummaryHeader

extension DownloadFilter {
    public var accentColor: Color {
        switch self {
        case .all: return .primary
        case .active: return .blue
        case .paused: return .orange
        case .completed: return .green
        case .failed: return .red
        case .liveRecordings: return .purple
        case .torrents: return .teal
        case .http: return .blue
        case .hls: return .indigo
        case .dash: return .cyan
        case .archived: return .gray
        }
    }
}

public struct QueueSummaryHeader: View {
    @ObservedObject public var viewModel: DownloadManagerViewModel

    public init(viewModel: DownloadManagerViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        let counts = viewModel.statusCounts
        HStack(spacing: 4) {
            HeaderStat(
                label: "All",
                count: counts.all,
                color: DownloadFilter.all.accentColor,
                isSelected: viewModel.selectedFilter == .all
            ) {
                withAnimation(.easeInOut(duration: 0.15)) {
                    viewModel.selectedFilter = .all
                }
            }

            HeaderStat(
                label: "Active",
                count: counts.active,
                color: DownloadFilter.active.accentColor,
                isSelected: viewModel.selectedFilter == .active
            ) {
                withAnimation(.easeInOut(duration: 0.15)) {
                    viewModel.selectedFilter = .active
                }
            }

            HeaderStat(
                label: "Paused",
                count: counts.paused,
                color: DownloadFilter.paused.accentColor,
                isSelected: viewModel.selectedFilter == .paused
            ) {
                withAnimation(.easeInOut(duration: 0.15)) {
                    viewModel.selectedFilter = .paused
                }
            }

            HeaderStat(
                label: "Completed",
                count: counts.completed,
                color: DownloadFilter.completed.accentColor,
                isSelected: viewModel.selectedFilter == .completed
            ) {
                withAnimation(.easeInOut(duration: 0.15)) {
                    viewModel.selectedFilter = .completed
                }
            }

            HeaderStat(
                label: "Failed",
                count: counts.failed,
                color: DownloadFilter.failed.accentColor,
                isSelected: viewModel.selectedFilter == .failed
            ) {
                withAnimation(.easeInOut(duration: 0.15)) {
                    viewModel.selectedFilter = .failed
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .padding(.horizontal)
    }
}

public struct HeaderStat: View {
    public let label: String
    public let count: Int
    public let color: Color
    public let isSelected: Bool
    public let action: (() -> Void)?

    public init(
        label: String,
        count: Int,
        color: Color,
        isSelected: Bool = false,
        action: (() -> Void)? = nil
    ) {
        self.label = label
        self.count = count
        self.color = color
        self.isSelected = isSelected
        self.action = action
    }

    public var body: some View {
        Button {
            action?()
        } label: {
            VStack(spacing: 2) {
                Text("\(count)")
                    .font(.headline.weight(isSelected ? .bold : .semibold))
                    .foregroundColor(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Text(label)
                    .font(.caption2.weight(isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? .primary : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                // Subtle underline indicator
                Capsule()
                    .fill(isSelected ? color : Color.clear)
                    .frame(height: 2.5)
                    .padding(.horizontal, 4)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? color.opacity(0.12) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(count) items")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
        .accessibilityHint("Filter downloads by \(label)")
    }
}

// MARK: - Bandwidth Dashboard Section (Milestone 4.3)

public struct BandwidthDashboardSection: View {
    @ObservedObject public var viewModel: DownloadManagerViewModel
    @State private var isExpanded: Bool = false

    public init(viewModel: DownloadManagerViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "waveform.path.ecg")
                        .foregroundColor(.blue)
                        .font(.subheadline)

                    if viewModel.currentTotalDownloadSpeed > 0 || viewModel.currentTotalUploadSpeed > 0 {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 7, height: 7)
                    }

                    Text("Bandwidth Throughput")
                        .font(.caption.bold())
                        .foregroundColor(.primary)

                    Spacer()

                    // Compact preview when collapsed
                    HStack(spacing: 8) {
                        Text("↓ \(UIFormatters.formatSpeed(viewModel.currentTotalDownloadSpeed))")
                            .font(.caption.weight(.medium))
                            .foregroundColor(.blue)

                        Text("↑ \(UIFormatters.formatSpeed(viewModel.currentTotalUploadSpeed))")
                            .font(.caption.weight(.medium))
                            .foregroundColor(.green)
                    }

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal)
                .padding(.top, 4)
            }
            .buttonStyle(PlainButtonStyle())

            if isExpanded {
                SpeedChartView(
                    history: viewModel.bandwidthHistory,
                    currentDownloadSpeed: viewModel.currentTotalDownloadSpeed,
                    currentUploadSpeed: viewModel.currentTotalUploadSpeed,
                    peakDownloadSpeed: viewModel.peakDownloadSpeed,
                    peakUploadSpeed: viewModel.peakUploadSpeed
                )
                .padding(.horizontal)
                .padding(.bottom, 6)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

// MARK: - Filter Bar

public struct FilterBar: View {
    @Binding public var selectedFilter: DownloadFilter

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(DownloadFilter.allCases) { filter in
                    Button {
                        selectedFilter = filter
                    } label: {
                        Text(filter.rawValue)
                            .font(.caption.bold())
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(selectedFilter == filter ? Color.blue : Color.platformSecondaryBackground)
                            .foregroundColor(selectedFilter == filter ? .white : .primary)
                            .cornerRadius(16)
                    }
                }
            }
            .padding(.horizontal)
        }
    }
}

// MARK: - Category Filter Bar

public struct CategoryFilterBar: View {
    @Binding public var selectedCategory: DownloadCategory?

    public init(selectedCategory: Binding<DownloadCategory?>) {
        self._selectedCategory = selectedCategory
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // "All" chip
                Button {
                    selectedCategory = nil
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 11))
                        Text("All")
                            .font(.caption.bold())
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(selectedCategory == nil ? Color.blue : Color.platformSecondaryBackground)
                    .foregroundColor(selectedCategory == nil ? .white : .primary)
                    .cornerRadius(14)
                }

                // Category chips: Videos, Audio, Documents, Archives, Torrents, Others
                ForEach(DownloadCategory.allCases) { category in
                    Button {
                        selectedCategory = category
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: category.iconName)
                                .font(.system(size: 11))
                            Text(category.displayName)
                                .font(.caption.bold())
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(selectedCategory == category ? Color.blue : Color.platformSecondaryBackground)
                        .foregroundColor(selectedCategory == category ? .white : .primary)
                        .cornerRadius(14)
                    }
                }
            }
            .padding(.horizontal)
        }
    }
}

// MARK: - Empty State

public struct EmptyDownloadsState: View {
    public let filter: DownloadFilter
    public var category: DownloadCategory? = nil
    public var onAddDownload: (() -> Void)? = nil
    public var onOpenBrowser: (() -> Void)? = nil

    public init(
        filter: DownloadFilter,
        category: DownloadCategory? = nil,
        onAddDownload: (() -> Void)? = nil,
        onOpenBrowser: (() -> Void)? = nil
    ) {
        self.filter = filter
        self.category = category
        self.onAddDownload = onAddDownload
        self.onOpenBrowser = onOpenBrowser
    }

    public var body: some View {
        VStack(spacing: 16) {
            Spacer()
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.blue.opacity(0.18), Color.cyan.opacity(0.10)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 90, height: 90)

                Image(systemName: category?.iconName ?? "arrow.down.circle.fill")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundColor(.blue)
            }

            VStack(spacing: 6) {
                Text(emptyTitle)
                    .font(.title3.weight(.semibold))
                    .foregroundColor(.primary)
                Text("Add a direct link, magnet URI, or browse sites with automatic media capture.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            if onAddDownload != nil || onOpenBrowser != nil {
                HStack(spacing: 12) {
                    if let onAddDownload = onAddDownload {
                        Button(action: onAddDownload) {
                            Label("Add Link", systemImage: "plus.circle.fill")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .background(Color.blue)
                                .foregroundColor(.white)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }

                    if let onOpenBrowser = onOpenBrowser {
                        Button(action: onOpenBrowser) {
                            Label("Open Browser", systemImage: "globe")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .background(.regularMaterial, in: Capsule())
                                .overlay(Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 4)
            }
            Spacer()
        }
    }

    private var emptyTitle: String {
        let catText = category?.displayName ?? ""
        let filterText = filter == .all ? "" : filter.rawValue
        if !catText.isEmpty && !filterText.isEmpty {
            return "No \(filterText) \(catText)"
        } else if !catText.isEmpty {
            return "No \(catText)"
        } else if !filterText.isEmpty {
            return "No \(filterText) Downloads"
        } else {
            return "No Downloads"
        }
    }
}

// MARK: - Platform Sheets (Export & Share)

#if canImport(UIKit)
public struct DocumentExporterSheet: UIViewControllerRepresentable {
    public let url: URL
    @Environment(\.presentationMode) private var presentationMode

    public init(url: URL) {
        self.url = url
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator { [presentationMode] in
            presentationMode.wrappedValue.dismiss()
        }
    }

    public func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    public func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    public class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onDismiss: () -> Void

        init(onDismiss: @escaping () -> Void) {
            self.onDismiss = onDismiss
        }

        public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onDismiss()
        }

        public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onDismiss()
        }
    }
}

public struct ShareSheetView: UIViewControllerRepresentable {
    public let items: [Any]
    @Environment(\.presentationMode) private var presentationMode

    public init(items: [Any]) {
        self.items = items
    }

    public func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        let mode = presentationMode
        controller.completionWithItemsHandler = { _, _, _, _ in
            mode.wrappedValue.dismiss()
        }
        if let popover = controller.popoverPresentationController {
            popover.sourceRect = CGRect(x: UIScreen.main.bounds.midX, y: UIScreen.main.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        return controller
    }

    public func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif

public struct LiveRecordingRecoverySection: View {
    @ObservedObject private var recorder = LiveStreamRecorder.shared

    public init() {}

    public var body: some View {
        VStack(spacing: 8) {
            if case .recording(let duration, let count, let bytes) = recorder.state {
                HStack(spacing: 12) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 10, height: 10)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Live Recording: \(recorder.activeRequest?.title ?? "Stream")")
                            .font(.subheadline.bold())
                        Text("\(count) segments (\(String(format: "%.1f", duration))s) • \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Button("Pause") {
                        recorder.pauseRecording()
                    }
                    .buttonStyle(.bordered)
                    .font(.caption)

                    Button("Stop") {
                        Task { @MainActor in
                            _ = try? await recorder.stopRecording()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .font(.caption.bold())
                }
                .padding(10)
                .background(Color.red.opacity(0.08))
                .cornerRadius(8)
                .padding(.horizontal)
            } else if case .paused(let duration, let count, _) = recorder.state {
                HStack(spacing: 12) {
                    Image(systemName: "pause.circle.fill")
                        .foregroundColor(.orange)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Live Recording Paused: \(recorder.activeRequest?.title ?? "Stream")")
                            .font(.subheadline.bold())
                        Text("\(count) segments (\(String(format: "%.1f", duration))s)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Button("Resume") {
                        recorder.resumeRecording()
                    }
                    .buttonStyle(.borderedProminent)
                    .font(.caption.bold())

                    Button("Stop") {
                        Task { @MainActor in
                            _ = try? await recorder.stopRecording()
                        }
                    }
                    .buttonStyle(.bordered)
                    .font(.caption)
                }
                .padding(10)
                .background(Color.orange.opacity(0.08))
                .cornerRadius(8)
                .padding(.horizontal)
            }

            ForEach(recorder.interruptedRecordings) { item in
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.yellow)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Interrupted Recording: \(item.title)")
                            .font(.subheadline.bold())
                        Text("\(item.recordedSegmentCount) segments (\(String(format: "%.1f", item.recordedDurationSeconds))s) saved on disk")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Button("Resume") {
                        Task { @MainActor in
                            try? await recorder.resumeInterruptedRecording(sessionID: item.id)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .font(.caption.bold())

                    Button("Save") {
                        Task { @MainActor in
                            _ = try? await recorder.finalizeInterruptedRecording(sessionID: item.id)
                        }
                    }
                    .buttonStyle(.bordered)
                    .font(.caption)

                    Button(action: {
                        Task { @MainActor in
                            await recorder.discardInterruptedRecording(sessionID: item.id)
                        }
                    }) {
                        Image(systemName: "xmark.circle")
                            .foregroundColor(.secondary)
                    }
                }
                .padding(10)
                .background(Color.yellow.opacity(0.12))
                .cornerRadius(8)
                .padding(.horizontal)
            }
        }
    }
}

private extension Color {
    static var platformSecondaryBackground: Color {
        #if canImport(UIKit)
        return Color(uiColor: .secondarySystemBackground)
        #elseif canImport(AppKit)
        return Color(nsColor: .windowBackgroundColor)
        #else
        return Color.secondary.opacity(0.15)
        #endif
    }
}
#endif
