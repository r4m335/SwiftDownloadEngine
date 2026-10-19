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

/// Screen 3: Download Details Screen displaying URL/Info-hash, swarm metrics, progress, speed, status, and error details.
public struct DownloadDetailsView: View {
    @ObservedObject public var viewModel: DownloadManagerViewModel
    public let transferID: String

    @Environment(\.presentationMode) private var presentationMode
    @State private var showingDeleteAlert = false
    @State private var isCalculatingHash = false
    @State private var hashProgress: Double = 0.0
    @State private var calculatedHash: String? = nil
    @State private var hashError: String? = nil
    @State private var quickLookURL: URL? = nil

    public init(viewModel: DownloadManagerViewModel, transfer: UnifiedTransfer) {
        self.viewModel = viewModel
        self.transferID = transfer.id
    }

    public init(viewModel: DownloadManagerViewModel, download: DownloadSnapshot) {
        self.viewModel = viewModel
        self.transferID = download.id
    }

    public init(viewModel: DownloadManagerViewModel, torrent: TorrentTask) {
        self.viewModel = viewModel
        self.transferID = torrent.id.uuidString
    }

    private var currentTransfer: UnifiedTransfer? {
        if let found = viewModel.unifiedTransfers.first(where: { $0.id == transferID }) {
            return found
        }
        if let snap = viewModel.downloads.first(where: { $0.id == transferID }) {
            return UnifiedTransfer(from: snap)
        }
        if let task = viewModel.torrentTasks.first(where: { $0.id.uuidString == transferID || $0.infoHash.caseInsensitiveCompare(transferID) == .orderedSame }) {
            return UnifiedTransfer(from: task)
        }
        return nil
    }

    private var currentSnapshot: DownloadSnapshot? {
        viewModel.downloads.first { $0.id == transferID }
    }

    public var body: some View {
        Group {
            if let transfer = currentTransfer {
                if transfer.isTorrent {
                    torrentDetailsView(transfer)
                } else {
                    httpDetailsView(transfer, snapshot: currentSnapshot)
                }
            } else {
                VStack(spacing: 12) {
                    Text("Transfer Not Found")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text("This transfer may have been removed.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .navigationTitle("Details")
            }
        }
    }

    // MARK: - BitTorrent Details View

    @ViewBuilder
    private func torrentDetailsView(_ transfer: UnifiedTransfer) -> some View {
        List {
            // Header Status & Progress
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(transfer.name)
                            .font(.title3.bold())
                            .lineLimit(2)
                        Spacer()
                        TypeBadge(type: .torrent)
                        UnifiedStatusBadge(state: transfer.state)
                    }

                    if let total = transfer.totalBytes, total > 0 {
                        ProgressView(value: transfer.progressFraction)
                            .progressViewStyle(LinearProgressViewStyle())

                        HStack {
                            Text("\(Int(transfer.progressFraction * 100))% Complete")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("\(UIFormatters.formatBytes(transfer.completedBytes)) of \(UIFormatters.formatBytes(total))")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        HStack {
                            ProgressView()
                                .padding(.trailing, 6)
                            Text("Fetching torrent metadata...")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            // Failure Diagnostics
            if let reason = transfer.failureReason {
                Section(header: Text("Error Information")) {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text(reason)
                            .font(.body)
                            .foregroundColor(.red)
                    }
                }
            }

            // Swarm & Transfer Metrics
            Section(header: Text("BitTorrent Swarm Metrics")) {
                DetailRow(label: "Download Speed", value: UIFormatters.formatSpeed(transfer.downloadSpeedBytesPerSecond))
                DetailRow(label: "Upload Speed", value: UIFormatters.formatSpeed(transfer.uploadSpeedBytesPerSecond))
                DetailRow(label: "Connected Peers", value: "\(transfer.connectedPeers ?? 0)")
                DetailRow(label: "Active Seeds", value: "\(transfer.connectedSeeds ?? 0)")

                if let currentPriority = transfer.torrentPriority, let hash = transfer.infoHash {
                    HStack {
                        Text("Queue Priority")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Picker("Priority", selection: Binding(
                            get: { currentPriority },
                            set: { newPrio in
                                Task { @MainActor in
                                    try? await viewModel.setTorrentPriority(newPrio, for: hash)
                                }
                            }
                        )) {
                            Text("Low").tag(TorrentPriority.low)
                            Text("Normal").tag(TorrentPriority.normal)
                            Text("High").tag(TorrentPriority.high)
                        }
                        .pickerStyle(SegmentedPickerStyle())
                        .frame(maxWidth: 180)
                    }
                    .padding(.vertical, 2)
                }
            }

            // Identity & File Details
            Section(header: Text("Torrent Identity")) {
                if let hash = transfer.infoHash {
                    HStack {
                        DetailRow(label: "Info Hash", value: hash)
                        Spacer()
                        Button {
                            copyToClipboard(hash, message: "Info-hash copied")
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .foregroundColor(.blue)
                        }
                        .buttonStyle(BorderlessButtonStyle())
                    }
                }

                HStack {
                    DetailRow(label: "Source", value: transfer.source)
                    Spacer()
                    Button {
                        copyToClipboard(transfer.source, message: "Source URI copied")
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(BorderlessButtonStyle())
                }

                DetailRow(label: "Save Destination", value: transfer.destinationURL.path)
                DetailRow(label: "Added At", value: transfer.createdAt.formatted())
            }

            // Control Operations
            Section {
                if transfer.state == .downloading || transfer.state == .seeding {
                    Button {
                        Task { @MainActor in
                            try? await viewModel.pauseTransfer(id: transfer.id)
                        }
                    } label: {
                        Label("Pause Torrent", systemImage: "pause.fill")
                            .foregroundColor(.orange)
                    }
                } else if transfer.state == .paused || transfer.state == .queued {
                    Button {
                        Task { @MainActor in
                            try? await viewModel.resumeTransfer(id: transfer.id)
                        }
                    } label: {
                        Label("Resume Torrent", systemImage: "play.fill")
                            .foregroundColor(.green)
                    }
                }

                Button(role: .destructive) {
                    showingDeleteAlert = true
                } label: {
                    Label("Remove Torrent", systemImage: "trash")
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationTitle("Torrent Details")
        .alert("Remove Torrent", isPresented: $showingDeleteAlert) {
            Button("Remove Task Only", role: .none) {
                Task { @MainActor in
                    try? await viewModel.removeTransfer(id: transfer.id, deleteFiles: false)
                    presentationMode.wrappedValue.dismiss()
                }
            }
            Button("Delete Files from Disk", role: .destructive) {
                Task { @MainActor in
                    try? await viewModel.removeTransfer(id: transfer.id, deleteFiles: true)
                    presentationMode.wrappedValue.dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Do you want to remove only the torrent task or delete its downloaded payload files from disk?")
        }
    }

    // MARK: - HTTP Details View

    @ViewBuilder
    private func httpDetailsView(_ transfer: UnifiedTransfer, snapshot: DownloadSnapshot?) -> some View {
        List {
            // Header Status & Progress
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(transfer.name)
                            .font(.title3.bold())
                        Spacer()
                        TypeBadge(type: .http)
                        if let snap = snapshot {
                            StatusBadge(state: snap.state)
                        } else {
                            UnifiedStatusBadge(state: transfer.state)
                        }
                    }

                    ProgressView(value: transfer.progressFraction)
                        .progressViewStyle(LinearProgressViewStyle())

                    HStack {
                        Text("\(Int(transfer.progressFraction * 100))% Complete")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(UIFormatters.formatBytes(transfer.completedBytes)) of \(transfer.totalBytes != nil ? UIFormatters.formatBytes(transfer.totalBytes!) : "Unknown")")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            // Failure Diagnostics
            if let reason = transfer.failureReason {
                Section(header: Text("Error Information")) {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text(reason)
                            .font(.body)
                            .foregroundColor(.red)
                    }
                }
            }

            // Transfer Metrics
            Section(header: Text("Transfer Metrics")) {
                DetailRow(label: "Current Speed", value: UIFormatters.formatSpeed(transfer.downloadSpeedBytesPerSecond))
                if let snap = snapshot {
                    DetailRow(label: "Average Speed", value: UIFormatters.formatSpeed(snap.averageBytesPerSecond))
                    DetailRow(label: "Time Remaining", value: UIFormatters.formatTimeInterval(snap.estimatedTimeRemaining))
                    DetailRow(label: "Elapsed Time", value: UIFormatters.formatTimeInterval(snap.elapsedTime))
                    DetailRow(label: "Priority", value: priorityLabel(for: snap.priority))
                }
            }

            // Integrity & Checksums
            if let snap = snapshot {
                Section(header: Text("Integrity Verification")) {
                    DetailRow(label: "Verification Status", value: checksumString(snap.checksumOutcome))

                    if let hash = calculatedHash {
                        DetailRow(label: "Calculated SHA-256", value: hash)
                    }

                    if let err = hashError {
                        Text(err)
                            .font(.caption)
                            .foregroundColor(.red)
                    }

                    if isCalculatingHash {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Calculating SHA-256... \(Int(hashProgress * 100))%")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            ProgressView(value: hashProgress)
                                .progressViewStyle(LinearProgressViewStyle())
                        }
                        .padding(.vertical, 4)
                    } else if FileManager.default.fileExists(atPath: snap.destinationURL.path) {
                        Button {
                            runChecksumVerification(for: snap)
                        } label: {
                            Label(calculatedHash == nil ? "Verify File Integrity (SHA-256)" : "Recalculate SHA-256", systemImage: "checkmark.shield")
                        }
                    }
                }
            }

            // File & Location Details
            Section(header: Text("File Details")) {
                DetailRow(label: "Destination", value: transfer.destinationURL.path)
                DetailRow(label: "Source URL", value: transfer.source)
                DetailRow(label: "Download ID", value: transfer.id)
                DetailRow(label: "Enqueued At", value: transfer.createdAt.formatted())
            }

            // Control Operations
            Section {
                if transfer.state == .downloading {
                    Button {
                        Task { @MainActor in try? await viewModel.pauseTransfer(id: transfer.id) }
                    } label: {
                        Label("Pause Download", systemImage: "pause.fill")
                            .foregroundColor(.orange)
                    }
                } else if transfer.state == .paused {
                    Button {
                        Task { @MainActor in try? await viewModel.resumeTransfer(id: transfer.id) }
                    } label: {
                        Label("Resume Download", systemImage: "play.fill")
                            .foregroundColor(.green)
                    }
                } else if transfer.state == .completed {
                    Button {
                        quickLookURL = transfer.destinationURL
                    } label: {
                        Label("Open File", systemImage: "doc.text")
                            .foregroundColor(.blue)
                    }
                }

                Button(role: .destructive) {
                    showingDeleteAlert = true
                } label: {
                    Label("Remove from Queue", systemImage: "trash")
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationTitle("Details")
        #if canImport(QuickLook)
        .quickLookPreview($quickLookURL)
        #endif
        .alert("Remove Download", isPresented: $showingDeleteAlert) {
            Button("Remove Entry Only", role: .none) {
                Task { @MainActor in
                    try? await viewModel.removeTransfer(id: transfer.id, deleteFiles: false)
                    presentationMode.wrappedValue.dismiss()
                }
            }
            Button("Delete File from Disk", role: .destructive) {
                Task { @MainActor in
                    try? await viewModel.removeTransfer(id: transfer.id, deleteFiles: true)
                    presentationMode.wrappedValue.dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Do you want to keep or delete the downloaded file from disk?")
        }
    }

    private func copyToClipboard(_ text: String, message: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
        viewModel.showNotification(message)
    }

    private func priorityLabel(for priority: DownloadPriority) -> String {
        switch priority {
        case .low:
            return "Low"
        case .normal:
            return "Normal"
        case .high:
            return "High"
        }
    }

    private func checksumString(_ outcome: ChecksumOutcome) -> String {
        switch outcome {
        case .notChecked:
            return "Not Verified"
        case .verified(let sha):
            return "Verified (\(sha.prefix(8))...)"
        case .mismatch(let expected, _):
            return "Mismatch (Expected \(expected.prefix(8))...)"
        }
    }

    private func runChecksumVerification(for download: DownloadSnapshot) {
        guard !isCalculatingHash else { return }
        isCalculatingHash = true
        hashProgress = 0.0
        hashError = nil
        let url = download.destinationURL

        Task.detached(priority: .userInitiated) {
            do {
                let hash = try FileHasher.sha256(for: url) { progress in
                    Task { @MainActor in
                        self.hashProgress = progress
                    }
                }
                await MainActor.run {
                    self.calculatedHash = hash
                    self.isCalculatingHash = false
                }
            } catch {
                await MainActor.run {
                    self.hashError = "Verification error: \(error.localizedDescription)"
                    self.isCalculatingHash = false
                }
            }
        }
    }
}

private struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.subheadline)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }
}
#endif
