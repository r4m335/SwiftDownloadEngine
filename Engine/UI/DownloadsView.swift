#if canImport(SwiftUI)
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
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

/// Screen 1: Displays all managed downloads with progress, speeds, and lifecycle controls.
public struct DownloadsView: View {
    @ObservedObject public var viewModel: DownloadManagerViewModel
    @State private var showingAddSheet = false

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
                // Summary Header
                if let summary = viewModel.queueSummary {
                    QueueSummaryHeader(summary: summary)
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

                // Downloads List
                if viewModel.filteredDownloads.isEmpty {
                    EmptyDownloadsState(filter: viewModel.selectedFilter)
                } else {
                    List {
                        ForEach(viewModel.filteredDownloads) { download in
                            NavigationLink(
                                destination: DownloadDetailsView(viewModel: viewModel, download: download)
                            ) {
                                DownloadRowView(viewModel: viewModel, download: download)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    Task { @MainActor in
                                        try? await viewModel.removeDownload(id: download.id, deleteFile: false)
                                    }
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }

                                if download.state.canResume {
                                    Button {
                                        Task { @MainActor in
                                            try? await viewModel.resumeDownload(id: download.id)
                                        }
                                    } label: {
                                        Label("Resume", systemImage: "play.fill")
                                    }
                                    .tint(.green)
                                } else if download.state == .downloading {
                                    Button {
                                        Task { @MainActor in
                                            try? await viewModel.pauseDownload(id: download.id)
                                        }
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

                        Button(role: .destructive) {
                            Task { @MainActor in await viewModel.cancelAll(deleteFiles: false) }
                        } label: {
                            Label("Cancel All", systemImage: "stop.circle")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }

                    Button {
                        showingAddSheet = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                    }
                }
            }
            .sheet(isPresented: $showingAddSheet) {
                AddDownloadView(viewModel: viewModel)
            }
        }
    }
}

// MARK: - Row View

public struct DownloadRowView: View {
    public let viewModel: DownloadManagerViewModel
    public let download: DownloadSnapshot

    public init(viewModel: DownloadManagerViewModel, download: DownloadSnapshot) {
        self.viewModel = viewModel
        self.download = download
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Filename and Status Badge
            HStack {
                Text(download.destinationURL.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)

                Spacer()

                StatusBadge(state: download.state)
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
                if download.state == .downloading {
                    Button {
                        Task { @MainActor in try? await viewModel.pauseDownload(id: download.id) }
                    } label: {
                        Label("Pause", systemImage: "pause.fill")
                            .font(.caption2)
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                } else if download.canResume {
                    Button {
                        Task { @MainActor in try? await viewModel.resumeDownload(id: download.id) }
                    } label: {
                        Label("Resume", systemImage: "play.fill")
                            .font(.caption2)
                    }
                    .buttonStyle(.bordered)
                    .tint(.green)
                } else if download.isFailed {
                    Button {
                        Task { @MainActor in try? await viewModel.retryDownload(id: download.id) }
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                            .font(.caption2)
                    }
                    .buttonStyle(.bordered)
                    .tint(.blue)
                }

                if !download.isTerminal {
                    Button(role: .destructive) {
                        Task { @MainActor in try? await viewModel.cancelDownload(id: download.id, deleteFile: false) }
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
