#if canImport(SwiftUI)
import SwiftUI

/// Screen 3: Download Details Screen displaying URL, progress, speed, status, and error details.
public struct DownloadDetailsView: View {
    @ObservedObject public var viewModel: DownloadManagerViewModel
    public let downloadID: DownloadID

    @Environment(\.presentationMode) private var presentationMode
    @State private var showingDeleteAlert = false

    public init(viewModel: DownloadManagerViewModel, download: DownloadSnapshot) {
        self.viewModel = viewModel
        self.downloadID = download.id
    }

    private var currentSnapshot: DownloadSnapshot? {
        viewModel.downloads.first { $0.id == downloadID }
    }

    public var body: some View {
        Group {
            if let download = currentSnapshot {
                List {
                    // Header Status & Progress
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(download.destinationURL.lastPathComponent)
                                    .font(.title3.bold())
                                Spacer()
                                StatusBadge(state: download.state)
                            }

                            ProgressView(value: download.progressFraction)
                                .progressViewStyle(LinearProgressViewStyle())

                            HStack {
                                Text("\(Int(download.progressFraction * 100))% Complete")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("\(UIFormatters.formatBytes(download.completedBytes)) of \(download.totalBytes != nil ? UIFormatters.formatBytes(download.totalBytes!) : "Unknown")")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    // Failure Diagnostics (if failed)
                    if let reason = download.failureReason {
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
                        DetailRow(label: "Current Speed", value: UIFormatters.formatSpeed(download.currentBytesPerSecond))
                        DetailRow(label: "Average Speed", value: UIFormatters.formatSpeed(download.averageBytesPerSecond))
                        DetailRow(label: "Time Remaining", value: UIFormatters.formatTimeInterval(download.estimatedTimeRemaining))
                        DetailRow(label: "Elapsed Time", value: UIFormatters.formatTimeInterval(download.elapsedTime))
                        DetailRow(label: "Priority", value: priorityLabel(for: download.priority))
                    }

                    // Integrity & Checksums
                    Section(header: Text("Integrity Verification")) {
                        DetailRow(label: "Checksum Outcome", value: checksumString(download.checksumOutcome))
                    }

                    // File & Location Details
                    Section(header: Text("File Details")) {
                        DetailRow(label: "Destination", value: download.destinationURL.path)
                        DetailRow(label: "Source URL", value: download.url.absoluteString)
                        DetailRow(label: "Download ID", value: download.id)
                        DetailRow(label: "Enqueued At", value: download.enqueuedAt.formatted())
                    }

                    // Control Operations
                    Section {
                        if download.state == .downloading {
                            Button {
                                Task { @MainActor in try? await viewModel.pauseDownload(id: download.id) }
                            } label: {
                                Label("Pause Download", systemImage: "pause.fill")
                                    .foregroundColor(.orange)
                            }
                        } else if download.canResume {
                            Button {
                                Task { @MainActor in try? await viewModel.resumeDownload(id: download.id) }
                            } label: {
                                Label("Resume Download", systemImage: "play.fill")
                                    .foregroundColor(.green)
                            }
                        } else if download.isFailed {
                            Button {
                                Task { @MainActor in try? await viewModel.retryDownload(id: download.id) }
                            } label: {
                                Label("Retry Download", systemImage: "arrow.clockwise")
                                    .foregroundColor(.blue)
                            }
                        }

                        if !download.isTerminal {
                            Button(role: .destructive) {
                                Task { @MainActor in try? await viewModel.cancelDownload(id: download.id, deleteFile: false) }
                            } label: {
                                Label("Cancel Download", systemImage: "xmark.circle")
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
                .alert("Remove Download", isPresented: $showingDeleteAlert) {
                    Button("Remove Entry Only", role: .none) {
                        Task { @MainActor in
                            try? await viewModel.removeDownload(id: download.id, deleteFile: false)
                            presentationMode.wrappedValue.dismiss()
                        }
                    }
                    Button("Delete File from Disk", role: .destructive) {
                        Task { @MainActor in
                            try? await viewModel.removeDownload(id: download.id, deleteFile: true)
                            presentationMode.wrappedValue.dismiss()
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Do you want to keep or delete the downloaded file from disk?")
                }
            } else {
                VStack(spacing: 12) {
                    Text("Download Not Found")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text("This download may have been removed.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .navigationTitle("Details")
            }
        }
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
