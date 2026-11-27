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


public struct QueueSummaryHeader: View {
    @ObservedObject public var viewModel: DownloadManagerViewModel

    public init(viewModel: DownloadManagerViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        let counts = viewModel.statusCounts
        HStack(spacing: 4) {
            HeaderStat(
                label: L10n.tr("All"),
                count: counts.all,
                color: DownloadFilter.all.accentColor,
                isSelected: viewModel.selectedFilter == .all
            ) {
                withAnimation(.easeInOut(duration: 0.15)) {
                    viewModel.selectedFilter = .all
                }
            }

            HeaderStat(
                label: L10n.tr("Active"),
                count: counts.active,
                color: DownloadFilter.active.accentColor,
                isSelected: viewModel.selectedFilter == .active
            ) {
                withAnimation(.easeInOut(duration: 0.15)) {
                    viewModel.selectedFilter = .active
                }
            }

            HeaderStat(
                label: L10n.tr("Paused"),
                count: counts.paused,
                color: DownloadFilter.paused.accentColor,
                isSelected: viewModel.selectedFilter == .paused
            ) {
                withAnimation(.easeInOut(duration: 0.15)) {
                    viewModel.selectedFilter = .paused
                }
            }

            HeaderStat(
                label: L10n.tr("Completed"),
                count: counts.completed,
                color: DownloadFilter.completed.accentColor,
                isSelected: viewModel.selectedFilter == .completed
            ) {
                withAnimation(.easeInOut(duration: 0.15)) {
                    viewModel.selectedFilter = .completed
                }
            }

            HeaderStat(
                label: L10n.tr("Failed"),
                count: counts.failed,
                color: DownloadFilter.failed.accentColor,
                isSelected: viewModel.selectedFilter == .failed
            ) {
                withAnimation(.easeInOut(duration: 0.15)) {
                    viewModel.selectedFilter = .failed
                }
            }
        }
        .padding(4)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .stroke(Color.primary.opacity(0.14), lineWidth: 0.75)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 4)
        .padding(.horizontal, 14)
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
            VStack(spacing: 1) {
                Text("\(count)")
                    .font(.subheadline.weight(isSelected ? .bold : .semibold))
                    .foregroundColor(isSelected ? color : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Text(label)
                    .scaledFont(size: 10, weight: isSelected ? .bold : .medium)
                    .foregroundColor(isSelected ? color : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity, minHeight: 40)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(isSelected ? color.opacity(0.16) : Color.clear)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.tr("%@, %d downloads", label, count))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
        .accessibilityHint(L10n.tr("Filter downloads by %@", label))
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
                            .scaledFont(size: 11)
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
                                .scaledFont(size: 11)
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
                    .scaledFont(size: 40, weight: .semibold)
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
