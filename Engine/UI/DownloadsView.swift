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
    @State private var selectedDownloadForDetails: DownloadSnapshot? = nil
    @State private var selectedTransferForDetails: UnifiedTransfer? = nil
    @State private var detectedClipboardURL: URL? = nil
    @State private var showClipboardBanner: Bool = false

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

                // Summary Header
                if let summary = viewModel.queueSummary {
                    QueueSummaryHeader(summary: summary)
                }

                // Clipboard Auto-Detection Banner (1DM+ Architecture)
                if showClipboardBanner, let url = detectedClipboardURL {
                    HStack(spacing: 12) {
                        Image(systemName: "doc.on.clipboard.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.blue)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Link found in clipboard. Download?")
                                .font(.subheadline.bold())
                            Text(url.absoluteString)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        Button {
                            Task { @MainActor in
                                try? await viewModel.addDownload(urlText: url.absoluteString)
                                showClipboardBanner = false
                            }
                        } label: {
                            Text("Download")
                                .font(.caption.bold())
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.blue)
                                .foregroundColor(.white)
                                .cornerRadius(6)
                        }

                        Button {
                            showClipboardBanner = false
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.secondary.opacity(0.12))
                    .cornerRadius(10)
                    .padding(.horizontal)
                    .padding(.top, 4)
                }

                // Error Banner
                if let error = viewModel.errorMessage {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.white)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.white)
                            .lineLimit(2)
                        Spacer()
                        Button {
                            viewModel.clearError()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.white)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.red)
                    .cornerRadius(8)
                    .padding(.horizontal)
                    .padding(.top, 4)
                }

                // Notification / Success Banner
                if let notification = viewModel.userNotificationMessage {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.white)
                        Text(notification)
                            .font(.caption)
                            .bold()
                            .foregroundColor(.white)
                            .lineLimit(2)
                        Spacer()
                        Button {
                            viewModel.clearNotification()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.white)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.green)
                    .cornerRadius(8)
                    .padding(.horizontal)
                    .padding(.top, 4)
                }

                // Filter Chips
                FilterBar(selectedFilter: $viewModel.selectedFilter)
                    .padding(.vertical, 8)

                // Unified Downloads & Torrents List
                if viewModel.filteredTransfers.isEmpty {
                    EmptyDownloadsState(filter: viewModel.selectedFilter)
                } else {
                    List {
                        ForEach(viewModel.filteredTransfers) { transfer in
                            NavigationLink(
                                destination: DownloadDetailsView(viewModel: viewModel, transfer: transfer)
                            ) {
                                UnifiedTransferRowView(
                                    viewModel: viewModel,
                                    transfer: transfer,
                                    onOpen: { openTransferFile(transfer) },
                                    onSaveToFiles: { saveTransferToFiles(transfer) },
                                    onShare: { shareTransferFile(transfer) },
                                    onCopyLink: { copyTransferLink(transfer) },
                                    onShowDetails: { showTransferDetails(transfer) },
                                    onPause: { pauseTransfer(transfer) },
                                    onResume: { resumeTransfer(transfer) },
                                    onRemoveQueue: { removeTransferFromQueue(transfer) },
                                    onDeleteFile: { promptDeleteTransferFile(transfer) }
                                )
                            }
                            .contextMenu {
                                UnifiedTransferMenuContent(
                                    transfer: transfer,
                                    isScheduled: viewModel.isScheduled(transferID: transfer.id),
                                    onOpen: { openTransferFile(transfer) },
                                    onSaveToFiles: { saveTransferToFiles(transfer) },
                                    onShare: { shareTransferFile(transfer) },
                                    onCopyLink: { copyTransferLink(transfer) },
                                    onShowDetails: { showTransferDetails(transfer) },
                                    onPause: { pauseTransfer(transfer) },
                                    onResume: { resumeTransfer(transfer) },
                                    onToggleSchedule: { toggleTransferSchedule(transfer) },
                                    onRemoveQueue: { removeTransferFromQueue(transfer) },
                                    onDeleteFile: { promptDeleteTransferFile(transfer) }
                                )
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    removeTransferFromQueue(transfer)
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }

                                if transfer.canResume {
                                    Button {
                                        resumeTransfer(transfer)
                                    } label: {
                                        Label("Resume", systemImage: "play.fill")
                                    }
                                    .tint(.green)
                                } else if transfer.canPause {
                                    Button {
                                        pauseTransfer(transfer)
                                    } label: {
                                        Label("Pause", systemImage: "pause.fill")
                                    }
                                    .tint(.orange)
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .refreshable {
                        await viewModel.refreshSnapshots()
                        await viewModel.refreshTorrentSnapshots()
                    }
                }
            }
            .navigationTitle("Downloads")
            .searchable(text: $viewModel.filterText, prompt: "Search downloads...")
            .toolbar {
                ToolbarItemGroup(placement: trailingToolbarPlacement) {
                    Menu {
                        Button {
                            Task { @MainActor in await viewModel.pauseAll() }
                        } label: {
                            Label("Pause All", systemImage: "pause.circle")
                        }

                        Button {
                            Task { @MainActor in await viewModel.resumeAll() }
                        } label: {
                            Label("Resume All", systemImage: "play.circle")
                        }

                        Divider()

                        Button {
                            activeSheet = .diagnostics
                        } label: {
                            Label("Pipeline Diagnostics", systemImage: "doc.text.magnifyingglass")
                        }

                        Divider()

                        Button(role: .destructive) {
                            Task { @MainActor in await viewModel.cancelAll(deleteFiles: false) }
                        } label: {
                            Label("Cancel All", systemImage: "stop.circle")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }

                    Button {
                        activeSheet = .addDownload
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                    }
                }
            }
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .addDownload:
                    AddDownloadView(viewModel: viewModel, onDownloadAdded: {
                        activeSheet = nil
                    })
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
                    DiagnosticLogView()
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
                                    try? await viewModel.cancelDownload(id: snap.id, deleteFile: false)
                                }
                                try? await viewModel.removeDownload(id: snap.id, deleteFile: true)
                                try? FileManager.default.removeItem(at: snap.destinationURL)
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
                                try? await viewModel.removeTransfer(id: transfer.id, deleteFiles: true)
                                viewModel.showNotification("Removed '\(transfer.name)' and deleted file")
                            }
                        },
                        secondaryButton: .default(Text("Keep File & Remove")) {
                            Task { @MainActor in
                                try? await viewModel.removeTransfer(id: transfer.id, deleteFiles: false)
                                viewModel.showNotification("Removed '\(transfer.name)' (file kept)")
                            }
                        }
                    )
                }
            }
            .filePreviewSheet(item: $quickLookURL)
            .onAppear {
                checkClipboardForURL()
            }
        }
    }

    private func checkClipboardForURL() {
        #if canImport(UIKit)
        if #available(iOS 14.0, *) {
            UIPasteboard.general.detectPatterns(for: [.probableWebURL]) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let patterns):
                        if patterns.contains(.probableWebURL),
                           let text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                           let url = URL(string: text),
                           let scheme = url.scheme?.lowercased(),
                           (scheme == "http" || scheme == "https"),
                           let host = url.host, !host.isEmpty {
                            self.detectedClipboardURL = url
                            self.showClipboardBanner = true
                        }
                    case .failure:
                        break
                    }
                }
            }
        } else if let text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let url = URL(string: text),
                  let scheme = url.scheme?.lowercased(),
                  (scheme == "http" || scheme == "https"),
                  let host = url.host, !host.isEmpty {
            self.detectedClipboardURL = url
            self.showClipboardBanner = true
        }
        #endif
    }

    // MARK: - Actions

    private func openFile(_ download: DownloadSnapshot) {
        guard FileManager.default.fileExists(atPath: download.destinationURL.path) else {
            viewModel.errorMessage = "File not found at '\(download.destinationURL.lastPathComponent)'."
            return
        }
        quickLookURL = download.destinationURL
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

        Task.detached(priority: .userInitiated) {
            do {
                let sha = try FileHasher.sha256(for: url)
                let attr = try? FileManager.default.attributesOfItem(atPath: url.path)
                let size = (attr?[.size] as? NSNumber)?.int64Value ?? 0
                await MainActor.run {
                    self.activeAlert = .integrity(
                        IntegrityReport(
                            filename: url.lastPathComponent,
                            fileSize: size,
                            sha256: sha,
                            outcome: outcome
                        )
                    )
                }
            } catch {
                await MainActor.run {
                    self.viewModel.errorMessage = "Checksum verification failed: \(error.localizedDescription)"
                }
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
            try? await viewModel.cancelDownload(id: download.id, deleteFile: false)
        }
    }

    private func removeFromQueue(_ download: DownloadSnapshot) {
        Task { @MainActor in
            let name = download.destinationURL.lastPathComponent
            if !download.isTerminal {
                try? await viewModel.cancelDownload(id: download.id, deleteFile: false)
            }
            try? await viewModel.removeDownload(id: download.id, deleteFile: false)
            viewModel.showNotification("Removed '\(name)' from queue (file preserved)")
        }
    }

    private func promptDeleteFile(_ download: DownloadSnapshot) {
        activeAlert = .deleteConfirmation(download)
    }

    // MARK: - Unified Transfer Actions

    private func openTransferFile(_ transfer: UnifiedTransfer) {
        #if canImport(QuickLook)
        quickLookURL = transfer.destinationURL
        #endif
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
            try? await viewModel.removeTransfer(id: transfer.id, deleteFiles: false)
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

// MARK: - Unified Transfer Row View

public struct UnifiedTransferRowView: View {
    public let viewModel: DownloadManagerViewModel
    public let transfer: UnifiedTransfer
    public let onOpen: () -> Void
    public let onSaveToFiles: () -> Void
    public let onShare: () -> Void
    public let onCopyLink: () -> Void
    public let onShowDetails: () -> Void
    public let onPause: () -> Void
    public let onResume: () -> Void
    public let onRemoveQueue: () -> Void
    public let onDeleteFile: () -> Void

    public init(
        viewModel: DownloadManagerViewModel,
        transfer: UnifiedTransfer,
        onOpen: @escaping () -> Void = {},
        onSaveToFiles: @escaping () -> Void = {},
        onShare: @escaping () -> Void = {},
        onCopyLink: @escaping () -> Void = {},
        onShowDetails: @escaping () -> Void = {},
        onPause: @escaping () -> Void = {},
        onResume: @escaping () -> Void = {},
        onRemoveQueue: @escaping () -> Void = {},
        onDeleteFile: @escaping () -> Void = {}
    ) {
        self.viewModel = viewModel
        self.transfer = transfer
        self.onOpen = onOpen
        self.onSaveToFiles = onSaveToFiles
        self.onShare = onShare
        self.onCopyLink = onCopyLink
        self.onShowDetails = onShowDetails
        self.onPause = onPause
        self.onResume = onResume
        self.onRemoveQueue = onRemoveQueue
        self.onDeleteFile = onDeleteFile
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header: Name, Type Badge, Status Badge, 3-Dot Menu
            HStack(alignment: .center, spacing: 6) {
                Text(transfer.name)
                    .font(.headline)
                    .lineLimit(1)

                if viewModel.isScheduled(transferID: transfer.id) {
                    Image(systemName: "clock.fill")
                        .font(.caption2)
                        .foregroundColor(.indigo)
                }

                Spacer()

                TypeBadge(type: transfer.type)
                UnifiedStatusBadge(state: transfer.state)

                Menu {
                    UnifiedTransferMenuContent(
                        transfer: transfer,
                        isScheduled: viewModel.isScheduled(transferID: transfer.id),
                        onOpen: onOpen,
                        onSaveToFiles: onSaveToFiles,
                        onShare: onShare,
                        onCopyLink: onCopyLink,
                        onShowDetails: onShowDetails,
                        onPause: onPause,
                        onResume: onResume,
                        onToggleSchedule: { viewModel.toggleScheduled(transferID: transfer.id) },
                        onRemoveQueue: onRemoveQueue,
                        onDeleteFile: onDeleteFile
                    )
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.bold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(BorderlessButtonStyle())
            }

            // Progress Bar
            if let total = transfer.totalBytes, total > 0 {
                ProgressView(value: transfer.progressFraction)
                    .progressViewStyle(LinearProgressViewStyle(tint: statusColor))
            } else if transfer.state == .downloading {
                ProgressView()
                    .progressViewStyle(LinearProgressViewStyle(tint: statusColor))
            } else {
                ProgressView(value: transfer.progressFraction)
                    .progressViewStyle(LinearProgressViewStyle(tint: statusColor))
            }

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
                    if transfer.isTorrent {
                        Text("↓ \(UIFormatters.formatSpeed(transfer.downloadSpeedBytesPerSecond))  ↑ \(UIFormatters.formatSpeed(transfer.uploadSpeedBytesPerSecond))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text(UIFormatters.formatSpeed(transfer.downloadSpeedBytesPerSecond))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else if transfer.state == .seeding {
                    Text("Seeding • ↑ \(UIFormatters.formatSpeed(transfer.uploadSpeedBytesPerSecond))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("\(Int(transfer.progressFraction * 100))%")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Extra metrics for torrent: Peers & Seeds
            if transfer.isTorrent {
                HStack {
                    Text("Peers: \(transfer.connectedPeers ?? 0) • Seeds: \(transfer.connectedSeeds ?? 0)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    if let prio = transfer.torrentPriority {
                        Spacer()
                        Text("Priority: \(prioLabel(prio))")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }

            // Quick Inline Action Controls
            HStack(spacing: 12) {
                if transfer.canPause {
                    Button(action: onPause) {
                        Label("Pause", systemImage: "pause.fill")
                            .font(.caption2)
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                } else if transfer.canResume {
                    Button(action: onResume) {
                        Label("Resume", systemImage: "play.fill")
                            .font(.caption2)
                    }
                    .buttonStyle(.bordered)
                    .tint(.green)
                } else if transfer.state == .completed {
                    Button(action: onOpen) {
                        Label("Open File", systemImage: "doc.text")
                            .font(.caption2)
                    }
                    .buttonStyle(.bordered)
                    .tint(.blue)
                }
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
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

public struct UnifiedTransferMenuContent: View {
    public let transfer: UnifiedTransfer
    public var isScheduled: Bool = false
    public let onOpen: () -> Void
    public let onSaveToFiles: () -> Void
    public let onShare: () -> Void
    public let onCopyLink: () -> Void
    public let onShowDetails: () -> Void
    public let onPause: () -> Void
    public let onResume: () -> Void
    public var onToggleSchedule: () -> Void = {}
    public let onRemoveQueue: () -> Void
    public let onDeleteFile: () -> Void

    public init(
        transfer: UnifiedTransfer,
        isScheduled: Bool = false,
        onOpen: @escaping () -> Void = {},
        onSaveToFiles: @escaping () -> Void = {},
        onShare: @escaping () -> Void = {},
        onCopyLink: @escaping () -> Void = {},
        onShowDetails: @escaping () -> Void = {},
        onPause: @escaping () -> Void = {},
        onResume: @escaping () -> Void = {},
        onToggleSchedule: @escaping () -> Void = {},
        onRemoveQueue: @escaping () -> Void = {},
        onDeleteFile: @escaping () -> Void = {}
    ) {
        self.transfer = transfer
        self.isScheduled = isScheduled
        self.onOpen = onOpen
        self.onSaveToFiles = onSaveToFiles
        self.onShare = onShare
        self.onCopyLink = onCopyLink
        self.onShowDetails = onShowDetails
        self.onPause = onPause
        self.onResume = onResume
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
        viewModel: DownloadManagerViewModel,
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
        self.viewModel = viewModel
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
        VStack(alignment: .leading, spacing: 6) {
            // Filename, Status Badge, and Three-Dot Menu Button
            HStack(alignment: .center, spacing: 8) {
                Text(download.destinationURL.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)

                Spacer()

                StatusBadge(state: download.state)

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
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.bold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(BorderlessButtonStyle())
            }

            // Progress Bar
            ProgressView(value: download.progressFraction)
                .progressViewStyle(LinearProgressViewStyle(tint: statusColor))

            // Metrics: Size, Progress %, Speed, ETA
            HStack {
                Text("\(UIFormatters.formatBytes(download.completedBytes)) / \(download.totalBytes != nil ? UIFormatters.formatBytes(download.totalBytes!) : "Unknown")")
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
        .padding(.vertical, 4)
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
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(backgroundColor.opacity(0.15))
            .foregroundColor(backgroundColor)
            .cornerRadius(4)
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

// MARK: - Queue Summary Header

public struct QueueSummaryHeader: View {
    public let summary: QueueSnapshot

    public var body: some View {
        HStack(spacing: 16) {
            HeaderStat(label: "Active", count: summary.activeCount, color: .blue)
            HeaderStat(label: "Queued", count: summary.queuedCount, color: .purple)
            HeaderStat(label: "Paused", count: summary.pausedCount, color: .orange)
            HeaderStat(label: "Done", count: summary.completedCount, color: .green)
            HeaderStat(label: "Failed", count: summary.failedCount, color: .red)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.platformSecondaryBackground)
    }
}

private struct HeaderStat: View {
    let label: String
    let count: Int
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text("\(count)")
                .font(.headline)
                .foregroundColor(color)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
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

// MARK: - Empty State

public struct EmptyDownloadsState: View {
    public let filter: DownloadFilter

    public var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("No \(filter == .all ? "" : filter.rawValue) Downloads")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("Tap the + button to enqueue a new download URL.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Spacer()
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
