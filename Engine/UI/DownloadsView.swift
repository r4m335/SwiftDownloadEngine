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
            let chunkSize = 256 * 1024
            for part in parts {
                guard let reader = try? FileHandle(forReadingFrom: part) else { continue }
                defer { try? reader.close() }
                while let chunk = try? reader.read(upToCount: chunkSize), !chunk.isEmpty {
                    handle.write(chunk)
                    totalWritten += Int64(chunk.count)
                }
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

#endif
